import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/api/api_client.dart';
import '../../data/models/models.dart';
import '../../data/repos/ai_repo.dart';
import '../add_tx/picker_field.dart';
import '../assets/asset_widgets.dart';
import '../widgets/widgets.dart';
import 'draft_store.dart';
import 'import_undo.dart' show ImportNote;
import 'perk_import_draft.dart';
import 'perk_import_providers.dart';
import 'screenshot_pane.dart';
import 'screenshots.dart';
import 'transactions_pane.dart';
import 'url_pane.dart';

/// AI 智能导入的输入页（`/assets/import`，spec §6）：来源分段（粘贴 / 截图 / 网址 / 从流水）、识别范围、AI 渠道、发送前的 token 估算；
/// 点「开始识别」后原地换成进度（SSE，已识别 N 条，可以取消），识别完把草稿交给预览页。
/// 截图模式只列没被测出「看不了图」的渠道（vision != false）；切片、缩放在本机做（screenshots.dart）。
/// 网址：先抓取、正文放进框里改，再按文字识别（url_pane.dart）。从流水：进分段就取候选分组（纯规则），「直接生成」不调 AI、
/// 没有渠道也能用，「AI 整理名称」只发商户、金额、周期、次数（transactions_pane.dart）；从流水只出会员卡，不给识别范围。
/// 本机有上次没导完的草稿（意外关闭）时，顶上给「继续核对 / 不要了」。
class PerkImportPage extends ConsumerStatefulWidget {
  const PerkImportPage({super.key, this.want = ImportWant.auto, this.targetMembershipId});

  /// 识别范围的预选：物品 tab 进来是「只要实物」，会员权益 tab 进来是「只要会员权益」。
  final ImportWant want;

  /// 会员详情的「AI 补充权益」：识别出的权益都归到这张卡（识别范围固定为会员权益）。
  final String? targetMembershipId;

  /// 开放的来源。会员详情的「AI 补充权益」（指定卡）不给从流水：那里识别的是权益，从流水只出会员卡。
  static const List<String> sources = ['paste', 'image', 'url', 'transactions'];

  @override
  ConsumerState<PerkImportPage> createState() => _PerkImportPageState();
}

class _PerkImportPageState extends ConsumerState<PerkImportPage> {
  final TextEditingController _text = TextEditingController();
  late ImportWant _want = widget.targetMembershipId != null ? ImportWant.virtual : widget.want;
  String? _providerId;
  bool _extracting = false;
  int _count = 0;
  String _stage = '';
  String? _error;
  StreamSubscription<ImportEvent>? _sub;

  /// 来源：paste | image | url | transactions。
  String _source = 'paste';

  /// 网址：地址、抓到的正文（可以改）、抓取结果和失败原因。
  final TextEditingController _url = TextEditingController();
  final TextEditingController _urlText = TextEditingController();
  FetchedPage? _page;
  bool _fetching = false;
  String? _fetchError;

  /// 从流水：候选分组（进分段时取一次）和勾了哪几组；这次点的是不是「AI 整理名称」（进度页、出错时的说法跟着它走）。
  SubscriptionCandidates? _candidates;
  bool _loadingCandidates = false;
  String? _candidatesError;
  Set<String> _picked = const {};
  bool _txUseAi = false;
  List<PickedScreenshot> _shots = const [];
  Set<String> _removed = const {};
  ScreenshotBatch _batch = const ScreenshotBatch();
  bool _preparing = false;
  int _prepareGen = 0;
  (int, int)? _prepareProgress;
  String? _shotNote;

  /// 这次发出去的切片（按块号顺序）和它们的叫法（「图 2 的第 1/3 片」）：交给预览页的草稿，依据块显示对应那片。
  List<Uint8List> _sentImages = const [];
  List<String> _sentLabels = const [];

  /// 本机存着的上次没导完的草稿。开始新的识别、继续或丢掉之后就不再提示。
  SavedPerkImport? _saved;

  bool get _imageMode => _source == 'image';
  bool get _urlMode => _source == 'url';
  bool get _txMode => _source == 'transactions';

  @override
  void initState() {
    super.initState();
    ref.read(perkImportDraftStoreProvider).load().then((saved) {
      if (mounted && saved != null && !_extracting) setState(() => _saved = saved);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _text.dispose();
    _url.dispose();
    _urlText.dispose();
    super.dispose();
  }

  Future<void> _pasteClipboard() async {
    String? text;
    try {
      text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } catch (_) {
      if (mounted) setState(() => _error = kIsWeb ? '浏览器不让读剪贴板，直接在框里按 Ctrl+V（手机上长按粘贴）' : '读不到剪贴板，直接在框里长按粘贴');
      return;
    }
    if (!mounted) return;
    if (text == null || text.trim().isEmpty) {
      setState(() => _error = '剪贴板是空的');
      return;
    }
    final current = _text.text.trimRight();
    final joined = current.isEmpty ? text : '$current\n\n$text';
    _text.text = joined.length > importMaxChars ? joined.substring(0, importMaxChars) : joined;
    setState(() => _error = null);
  }

  void _start(AiProvider? provider) {
    final empty = _imageMode ? !_batch.sendable : (_urlMode ? _urlText.text : _text.text).trim().isEmpty;
    if (empty) {
      // 网址分段只有抓到正文才有框可改，没东西时指向「改用粘贴」，不说「粘进来」（没地方粘）。
      setState(() => _error = _imageMode ? '先选几张截图' : (_urlMode ? '先抓取网页；抓不到就点「改用粘贴」' : '先粘点东西进来'));
      return;
    }
    _sentImages = _imageMode ? [for (final s in _batch.slices) s.png] : const [];
    _sentLabels = _imageMode ? [for (final s in _batch.slices) s.label] : const [];
    final repo = ref.read(assetImportRepoProvider);
    final Stream<ImportEvent> events;
    if (_urlMode) {
      events = repo.extractUrl(
        text: _urlText.text,
        sourceUrl: _page?.finalUrl ?? _url.text.trim(),
        want: _want,
        targetMembershipId: widget.targetMembershipId,
        providerId: provider?.id,
      );
    } else {
      events = repo.extract(
        text: _imageMode ? '' : _text.text,
        images: _sentImages,
        want: _want,
        targetMembershipId: widget.targetMembershipId,
        providerId: provider?.id,
      );
    }
    _run(events, _imageMode ? '正在请模型看图…' : '正在请模型识别…');
  }

  /// 从流水：「直接生成」（[useAi] 假，不带渠道）或「AI 整理名称」。勾的组按名单里的顺序发。
  void _startTransactions({required bool useAi, AiProvider? provider}) {
    final c = _candidates;
    final groups = [
      for (final item in c?.items ?? const <SubscriptionCandidate>[])
        if (_picked.contains(item.key)) item.key,
    ];
    if (c == null || groups.isEmpty) {
      setState(() => _error = '先勾几组');
      return;
    }
    _sentImages = const [];
    _sentLabels = const [];
    _txUseAi = useAi;
    _run(
      ref.read(assetImportRepoProvider).extractTransactions(groups: groups, useAi: useAi, months: c.months, providerId: provider?.id),
      useAi ? '正在请模型整理名称…' : '正在按商户名生成…',
    );
  }

  /// 开始识别（换成进度页）并听事件流。
  void _run(Stream<ImportEvent> events, String stage) {
    FocusScope.of(context).unfocus();
    setState(() {
      _extracting = true;
      _count = 0;
      _stage = stage;
      _error = null;
      _saved = null; // 新识别出来的会盖掉本机那份
    });
    _sub = events.listen(_onEvent, onError: _onError);
  }

  /// 换来源分段；第一次进「从流水」时取候选。
  void _switchSource(String source) {
    setState(() {
      _source = source;
      _error = null;
    });
    if (source == 'transactions' && _candidates == null && !_loadingCandidates) _loadCandidates();
  }

  /// 取候选。[refetch]（勾的组对不上了、重新取）时保留用户手动改过的勾选：key 对得上的组照旧（勾了的还勾着、取消了的还空着），
  /// 对不上的（新出现的、金额档变了的）按服务端的默认勾选。
  Future<void> _loadCandidates({bool refetch = false}) async {
    final before = _candidates;
    final kept = _picked;
    setState(() {
      _loadingCandidates = true;
      _candidatesError = null;
    });
    try {
      final c = await ref.read(assetImportRepoProvider).candidates();
      if (!mounted) return;
      final known = {for (final item in before?.items ?? const <SubscriptionCandidate>[]) item.key};
      setState(() {
        _candidates = c;
        _picked = {
          for (final item in c.items)
            if (refetch && known.contains(item.key) ? kept.contains(item.key) : item.checked) item.key,
        };
        _loadingCandidates = false;
        if (refetch) _error = '重新取好了：还在的组保留了你的勾选，新出现的按默认勾。看一眼再生成。';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _candidatesError = '没取到流水里像订阅的扣费：${describeError(e)}';
        _loadingCandidates = false;
        if (refetch) _error = null; // 取失败的说明和「重试」在列表那里
      });
    }
  }

  void _toggle(String key) => setState(() {
    _picked = _picked.contains(key) ? ({..._picked}..remove(key)) : {..._picked, key};
    _error = null;
  });

  /// 抓网页：正文放进可编辑的框里；失败的说明（被拦、超时、打不开）留在分段里，给「改用截图 / 改用粘贴」。
  /// 每次点「抓取」（地址是空的也一样）先收起上一次抓到的页面和说明：上一次的正文不能冒充这一次的，也不能和新的说明摆在一起。
  Future<void> _fetch() async {
    final url = _url.text.trim();
    _urlText.clear();
    if (url.isEmpty) {
      setState(() {
        _page = null;
        _fetchError = '先填一个网址';
        _error = null;
      });
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _page = null;
      _fetching = true;
      _fetchError = null;
      _error = null;
    });
    try {
      final page = await ref.read(assetImportRepoProvider).fetchPage(url);
      if (!mounted) return;
      _urlText.text = page.text;
      setState(() {
        _page = page;
        _fetching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _fetchError = _fetchErrorText(e);
        _fetching = false;
      });
    }
  }

  /// 抓取失败的说明。被当成 fake-ip 拦下的（details.fakeIp）按角色说：管理员看服务端给的完整步骤和代价；成员改不了服务端，
  /// 只说请管理员看看、现在先换方式。
  String _fetchErrorText(Object e) {
    if (e is ApiException && e.code == 'url_blocked' && e.details['fakeIp'] == true) {
      final isAdmin = ref.read(sessionProvider)?.me.isAdmin ?? false;
      if (!isAdmin) return '服务端的网络走了 fake-ip 代理，这个网址被当成内网地址拦下了。要放开得请管理员改服务端的设置；现在可以先改用截图或粘贴。';
    }
    return describeError(e);
  }

  Future<void> _pickShots() async {
    final List<PickedScreenshot> picked;
    try {
      picked = await ref.read(screenshotPickerProvider)();
    } catch (e) {
      if (mounted) setState(() => _error = '打不开相册：${describeError(e)}');
      return;
    }
    if (!mounted || picked.isEmpty) return;
    final room = kMaxScreenshots - _shots.length;
    final taken = picked.take(room < 0 ? 0 : room).toList();
    setState(() {
      _shots = [..._shots, ...taken];
      _shotNote = picked.length > taken.length ? '一次最多 $kMaxScreenshots 张，只加了前 ${taken.length} 张' : null;
      _error = null;
    });
    await _prepareShots();
  }

  /// 重新切一遍（加图之后）；中途又加了图、清空了，旧的那次结果不要。
  Future<void> _prepareShots() async {
    final gen = ++_prepareGen;
    setState(() {
      _preparing = true;
      _prepareProgress = null;
    });
    ScreenshotBatch batch;
    try {
      batch = await ref.read(screenshotPreparerProvider)(_shots, _removed, (done, total) {
        if (mounted && gen == _prepareGen) setState(() => _prepareProgress = (done, total));
      });
    } catch (e) {
      batch = ScreenshotBatch(failed: ['处理截图出错了：${describeError(e)}']);
    }
    if (!mounted || gen != _prepareGen) return;
    setState(() {
      _batch = batch;
      _preparing = false;
    });
  }

  /// 删掉一片：记下它的编号（以后加图重切也跳过它），当前结果里直接拿掉，不用重切。
  /// 一张原图的片全删光了：这张原图也拿掉（不再占 6 张的名额），后面原图的编号往前挪一位。
  void _removeSlice(ScreenshotSlice slice) => setState(() {
    final left = [
      for (final s in _batch.slices)
        if (s.id != slice.id) s,
    ];
    final gone = slice.source;
    if (left.any((s) => s.source == gone)) {
      _removed = {..._removed, slice.id};
      _batch = _batch.withSlices(left);
      return;
    }
    (int, String) parse(String id) {
      final dash = id.indexOf('-');
      return (int.parse(id.substring(0, dash)), id.substring(dash + 1));
    }

    _shots = [
      for (var i = 0; i < _shots.length; i++)
        if (i != gone) _shots[i],
    ];
    _removed = {
      for (final id in _removed)
        if (parse(id) case (final src, final rest) when src != gone) '${src > gone ? src - 1 : src}-$rest',
    };
    _batch = _batch.withSlices([for (final s in left) s.source > gone ? s.withSource(s.source - 1) : s]);
    _shotNote = null;
  });

  void _clearShots() => setState(() {
    _prepareGen++;
    _shots = const [];
    _removed = const {};
    _batch = const ScreenshotBatch();
    _preparing = false;
    _prepareProgress = null;
    _shotNote = null;
  });

  /// 继续核对本机存着的那份：交给预览页（截图没存，依据块里说明一下）。
  void _resume(SavedPerkImport saved) {
    setState(() => _saved = null);
    ref.read(pendingPerkImportProvider.notifier).state = saved.draft;
    context.push('/assets/import/preview');
  }

  Future<void> _dropSaved() async {
    setState(() => _saved = null);
    await ref.read(perkImportDraftStoreProvider).clear();
  }

  void _onEvent(ImportEvent e) {
    if (!mounted) return;
    switch (e) {
      case ImportStage(:final message):
        setState(() => _stage = message);
      case ImportProgress(:final count):
        setState(() => _count = count);
      case ImportDone(:final draft):
        _sub = null;
        setState(() => _extracting = false);
        // 读的时候人已经走到别处去了，就别把预览硬叠上去。
        if (ModalRoute.of(context)?.isCurrent == false) return;
        ref.read(pendingPerkImportProvider.notifier).state = PerkImportDraft.fromJson(draft, images: _sentImages, imageLabels: _sentLabels);
        context.push('/assets/import/preview');
    }
  }

  void _onError(Object e) {
    if (!mounted) return;
    _sub = null;
    final stale = e is ApiException && e.code == 'groups_stale';
    setState(() {
      _extracting = false;
      final message = switch (e) {
        ApiException(code: 'no_provider') => '还没有可用的 AI 渠道，先去设置里加一个。',
        ApiException(code: 'import_in_progress') => '你还有一次识别没结束（可能在另一台设备上），等它结束再试。',
        ApiException(code: 'provider_no_vision') => '这个渠道看不了图片，换一个支持看图的渠道。',
        ApiException(code: 'body_too_large') => '截图合计太大了，删掉几片再试。',
        ApiException(code: 'groups_stale') => '勾的几组和现在的流水对不上了（刚记了新流水？），正在重新取…',
        _ => describeError(e),
      };
      // 「AI 整理名称」出错（上游出错、超时、限流……）：「直接生成」不受这些影响，马上就能用。
      _error = _txMode && _txUseAi && !stale ? '$message 可以先点「直接生成」（不用 AI），名字导入前能改。' : message;
    });
    if (stale) _loadCandidates(refetch: true);
  }

  /// 取消 = 断开连接，服务端随即中止上游，不再花 token。粘贴的内容都还在。
  void _cancel() {
    _sub?.cancel();
    _sub = null;
    setState(() => _extracting = false);
  }

  @override
  Widget build(BuildContext context) {
    // 输入页压在预览页底下，要替预览页把交过去的草稿留住（autoDispose）。
    ref.watch(pendingPerkImportProvider);
    final target = widget.targetMembershipId == null
        ? null
        : ref.watch(ledgerProvider).valueOrNull?.membership(widget.targetMembershipId!);
    return PopScope(
      canPop: !_extracting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: Scaffold(
        appBar: AppBar(title: Text(widget.targetMembershipId == null ? '智能导入' : '补充权益')),
        body: _extracting ? _progress(context) : _input(context, target),
      ),
    );
  }

  Widget _progress(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(LedgerLayout.widePagePadding),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                switch ((_source, _txUseAi)) {
                  ('transactions', false) => '正在生成…',
                  ('transactions', true) => '正在整理名称…',
                  _ => '正在识别…',
                },
                key: const ValueKey('import-progress-title'),
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: LedgerLayout.itemGap),
              const LinearProgressIndicator(),
              const SizedBox(height: LedgerLayout.itemGap),
              // 进行到哪一步（续写时「正在让它接着写…」）和已识别几条分两行：条数出来之后阶段那句也要看得到，
              // 不然续写那一两分钟只看到一个不动的数，像卡死了。
              Text(_stage, key: const ValueKey('import-stage'), style: theme.textTheme.bodyMedium),
              if (_count > 0)
                Text('已识别 $_count 条', key: const ValueKey('import-progress'), style: theme.textTheme.bodyMedium),
              const SizedBox(height: 4),
              Text(
                switch (_source) {
                  'image' => '截图多的要一两分钟。取消就不再花 token，选的截图都还在。',
                  'url' => '长材料要一两分钟。取消就不再花 token，抓到的正文都还在。',
                  'transactions' when !_txUseAi => '按商户名生成，不用 AI，很快就好。勾的组都还在。',
                  'transactions' => '只是整理名称，很快就好。取消就不再花 token，勾的组都还在。',
                  _ => '长材料要一两分钟。取消就不再花 token，粘贴的内容都还在。',
                },
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: LedgerLayout.groupGap),
              OutlinedButton(key: const ValueKey('import-cancel'), onPressed: _cancel, child: const Text('取消')),
            ],
          ),
        ),
      ),
    );
  }

  Widget _input(BuildContext context, Membership? target) {
    final theme = Theme.of(context);
    final providers = ref.watch(aiProvidersProvider);
    final length = _text.text.length;
    // 四段来源在手机上挤：窄屏只写字（带图标时「从流水」会折成两行）。
    final compact = MediaQuery.sizeOf(context).width < 480;
    return LayoutBuilder(
      builder: (context, box) => ListView(
        padding: readableInsets(box.maxWidth, maxWidth: 720).copyWith(bottom: 32),
        children: [
          if (_saved case final saved?) _savedBanner(context, saved),
          if (widget.targetMembershipId != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, LedgerLayout.itemGap, LedgerLayout.pagePadding, 0),
              child: Text(
                '识别出的权益都归到「${target?.title ?? '这张卡'}」，导入前可以逐条改。',
                key: const ValueKey('import-target'),
                style: theme.textTheme.bodyMedium,
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, LedgerLayout.itemGap, LedgerLayout.pagePadding, 0),
            child: SegmentedButton<String>(
              key: const ValueKey('import-source'),
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: 'paste', icon: compact ? null : const Icon(Icons.content_paste), label: const Text('粘贴', key: ValueKey('import-source-paste'))),
                ButtonSegment(value: 'image', icon: compact ? null : const Icon(Icons.image_outlined), label: const Text('截图', key: ValueKey('import-source-image'))),
                ButtonSegment(value: 'url', icon: compact ? null : const Icon(Icons.link), label: const Text('网址', key: ValueKey('import-source-url'))),
                if (widget.targetMembershipId == null)
                  ButtonSegment(
                    value: 'transactions',
                    icon: compact ? null : const Icon(Icons.receipt_long_outlined),
                    label: const Text('从流水', key: ValueKey('import-source-transactions')),
                  ),
              ],
              selected: {_source},
              onSelectionChanged: (v) => _switchSource(v.first),
            ),
          ),
          if (_urlMode)
            UrlPane(
              url: _url,
              text: _urlText,
              page: _page,
              fetching: _fetching,
              error: _fetchError,
              onFetch: _fetch,
              onUseImage: () => _switchSource('image'),
              onUsePaste: () => _switchSource('paste'),
              onTextChanged: (_) => setState(() {}),
            )
          else if (_txMode)
            TransactionsPane(
              candidates: _candidates,
              loading: _loadingCandidates,
              error: _candidatesError,
              picked: _picked,
              onToggle: _toggle,
              onRetry: _loadCandidates,
              onUsePaste: () => _switchSource('paste'),
            )
          else if (_imageMode)
            ScreenshotPane(
              sourceCount: _shots.length,
              batch: _batch,
              preparing: _preparing,
              progress: _prepareProgress,
              note: _shotNote,
              onPick: _pickShots,
              onRemove: _removeSlice,
              onClear: _clearShots,
            )
          else ...[
            PickerField(
              label: '粘贴会员权益说明或订单详情',
              topGap: LedgerLayout.itemGap,
              trailing: TextButton.icon(
                key: const ValueKey('import-paste'),
                onPressed: _pasteClipboard,
                icon: const Icon(Icons.content_paste, size: 18),
                label: const Text('从剪贴板粘贴'),
              ),
              child: TextField(
                key: const ValueKey('import-text'),
                controller: _text,
                minLines: 6,
                maxLines: 14,
                maxLength: importMaxChars,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  hintText: '把 88VIP、京东 PLUS 的权益说明，或者订单详情整段复制过来',
                ),
              ),
            ),
            if (length > importPickLimit)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
                child: Text(
                  '超过 $importPickLimit 字，只会挑最相关的段落发给模型。',
                  key: const ValueKey('import-long'),
                  style: theme.textTheme.bodySmall?.copyWith(color: LedgerColors.of(context).warning),
                ),
              ),
          ],
          if (widget.targetMembershipId == null && !_txMode)
            PickerField(
              label: '识别范围',
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final w in ImportWant.values)
                    ChoiceChip(
                      key: ValueKey('import-want-${w.wire}'),
                      label: Text(w.label),
                      selected: _want == w,
                      onSelected: (_) => setState(() => _want = w),
                    ),
                ],
              ),
            ),
          PickerField(
            // 从流水下「直接生成」不用渠道，只有「AI 整理名称」用。
            label: _txMode ? '「AI 整理名称」用哪个渠道' : '用哪个 AI 渠道',
            child: providers.when(
              loading: () => const Skeleton(height: 40, radius: 8),
              error: (e, _) => InlineError(message: describeError(e), onRetry: () => ref.invalidate(aiProvidersProvider), padding: EdgeInsets.zero),
              data: (items) => _providerPicker(context, items),
            ),
          ),
          ..._footer(context, providers.valueOrNull ?? const []),
        ],
      ),
    );
  }

  /// 「上次还有一份没导完」：继续核对 / 不要了。
  Widget _savedBanner(BuildContext context, SavedPerkImport saved) {
    final theme = Theme.of(context);
    final at = saved.savedAt;
    final when = at == null ? '' : '（${at.month} 月 ${at.day} 日 ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}）';
    return Container(
      key: const ValueKey('import-saved'),
      margin: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, LedgerLayout.itemGap, LedgerLayout.pagePadding, 0),
      padding: const EdgeInsets.all(LedgerLayout.itemGap),
      decoration: BoxDecoration(color: LedgerColors.of(context).surface2, borderRadius: BorderRadius.circular(LedgerShapes.control)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('上次还有一份没导完的识别结果$when，勾了 ${saved.draft.includedCount} 项。', style: theme.textTheme.bodyMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.tonal(key: const ValueKey('import-saved-resume'), onPressed: () => _resume(saved), child: const Text('继续核对')),
              TextButton(key: const ValueKey('import-saved-drop'), onPressed: _dropSaved, child: const Text('不要了')),
            ],
          ),
        ],
      ),
    );
  }

  /// 能选的渠道：启用的；截图模式再去掉测出来看不了图的。
  List<AiProvider> _usable(List<AiProvider> all) => [
    for (final p in all)
      if (p.enabled && (!_imageMode || p.maybeVision)) p,
  ];

  AiProvider? _chosen(List<AiProvider> all) {
    final usable = _usable(all);
    return usable.where((p) => p.id == _providerId).firstOrNull ?? defaultProviderOf(usable);
  }

  Widget _providerPicker(BuildContext context, List<AiProvider> all) {
    final usable = _usable(all);
    final isAdmin = ref.watch(sessionProvider)?.me.isAdmin ?? false;
    if (usable.isEmpty && _imageMode && all.any((p) => p.enabled)) {
      // 渠道都测出来看不了图：成员去不了渠道页（测看图只有管理员能点），各说各的；两种都给一键改用粘贴。
      return Column(
        key: const ValueKey('import-no-vision'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isAdmin
                ? '现有的 AI 渠道都测出来看不了图。换过模型的，去「设置 → AI 渠道」重新点「测看图」；或者加一个能看图的（Claude、Qwen-VL、GLM-4V 这类）。'
                : '家里现有的 AI 渠道都看不了图，请管理员加一个能看图的渠道。现在可以先把文字复制过来，改用粘贴。',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonal(
                key: const ValueKey('import-no-vision-paste'),
                onPressed: () => setState(() {
                  _source = 'paste';
                  _error = null;
                }),
                child: const Text('改用粘贴'),
              ),
              if (isAdmin)
                OutlinedButton(
                  key: const ValueKey('import-no-vision-settings'),
                  onPressed: () => context.push('/settings/ai'),
                  child: const Text('去设置 AI 渠道'),
                ),
            ],
          ),
        ],
      );
    }
    if (usable.isEmpty && _txMode) {
      return Column(
        key: const ValueKey('import-no-provider-tx'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isAdmin ? '还没有可用的 AI 渠道。「直接生成」不用 AI，照样能用；想让 AI 整理名称，先加一个渠道。' : '还没有可用的 AI 渠道。「直接生成」不用 AI，照样能用。',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (isAdmin) ...[
            const SizedBox(height: 8),
            OutlinedButton(
              key: const ValueKey('import-no-provider-tx-settings'),
              onPressed: () => context.push('/settings/ai'),
              child: const Text('去设置 AI 渠道'),
            ),
          ],
        ],
      );
    }
    if (usable.isEmpty) {
      return Column(
        key: const ValueKey('import-no-provider'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isAdmin ? '还没有可用的 AI 渠道。加一个（自建 cc-trans、硅基流动、DeepSeek 都行）就能用。' : '还没有可用的 AI 渠道，请管理员在「设置 → AI 渠道」里加一个。',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (isAdmin) ...[
            const SizedBox(height: 8),
            FilledButton.tonal(onPressed: () => context.push('/settings/ai'), child: const Text('去设置 AI 渠道')),
          ],
        ],
      );
    }
    final chosen = _chosen(all);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final p in usable)
          ChoiceChip(
            key: ValueKey('import-provider-${p.id}'),
            label: Text(p.name),
            selected: p.id == chosen?.id,
            onSelected: (_) => setState(() => _providerId = p.id),
          ),
      ],
    );
  }

  List<Widget> _footer(BuildContext context, List<AiProvider> all) {
    if (_txMode) return _txFooter(context, all);
    final theme = Theme.of(context);
    final chosen = _chosen(all);
    final error = _error;
    final text = _urlMode ? _urlText.text : _text.text;
    final maxOut = chosen?.importMaxTokens ?? 12000;
    final empty = _imageMode ? _batch.slices.isEmpty : text.trim().isEmpty;
    final input = _imageMode ? _batch.estimatedTokens : estimateImportTokens(text);
    // 网址抓取中不给点：框里还是空的（上一次的已经收起），点了只会拿不到正文。
    final ready = chosen != null && (!_imageMode || (_batch.sendable && !_preparing)) && !(_urlMode && _fetching);
    // 截图挡住发送的原因放在按钮旁边（缩略图多的时候上面的提示离按钮很远，只看到一个灰掉的按钮和 token 估算）。
    final blocked = !_imageMode || empty || _preparing
        ? null
        : _batch.overCount
            ? '切出了 ${_batch.slices.length} 片，一次最多 $kMaxSlices 片：先删掉 ${_batch.slices.length - kMaxSlices} 片再开始识别。'
            : _batch.overBytes
                ? '截图合计 ${ScreenshotPane.mb(_batch.totalBytes)}MB 太大了，删掉几片再开始识别。'
                : null;
    return [
      if (blocked != null)
        ImportNote(
          blocked,
          key: const ValueKey('import-blocked'),
          padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, LedgerLayout.groupGap, LedgerLayout.pagePadding, 0),
        )
      else
        Padding(
          padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, LedgerLayout.groupGap, LedgerLayout.pagePadding, 0),
          child: Text(
            empty ? '识别完先在预览里逐条核对，确认了才会落库。' : '预计输入约 $input token，最多输出 $maxOut token。',
            key: const ValueKey('import-estimate'),
            style: theme.textTheme.bodySmall,
          ),
        ),
      if (error != null)
        InlineError(
          key: const ValueKey('import-error'),
          message: error,
          padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, LedgerLayout.itemGap, LedgerLayout.pagePadding, 0),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, LedgerLayout.itemGap, LedgerLayout.pagePadding, 0),
        child: FilledButton(
          key: const ValueKey('import-start'),
          onPressed: ready ? () => _start(chosen) : null,
          child: const Text('开始识别'),
        ),
      ),
    ];
  }

  /// 从流水的底栏：「直接生成」不要渠道；「AI 整理名称」要渠道。没勾、候选还在取（勾的组对不上了、正在重新取）时都点不了。
  /// 没东西可勾（还在取、取失败、一组都没有）时不写「先勾几组」。
  List<Widget> _txFooter(BuildContext context, List<AiProvider> all) {
    final theme = Theme.of(context);
    final chosen = _chosen(all);
    final count = _picked.length;
    final error = _error;
    final pickable = !_loadingCandidates && _candidatesError == null && (_candidates?.items.isNotEmpty ?? false);
    final ready = pickable && count > 0;
    return [
      if (pickable)
        Padding(
          padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, LedgerLayout.groupGap, LedgerLayout.pagePadding, 0),
          child: Text(
            count == 0 ? '先勾几组。生成之后先在预览里逐条核对，确认了才会落库。' : '勾了 $count 组。直接生成不花 token；AI 整理名称预计输入约 ${estimateNamingTokens(count)} token。',
            key: const ValueKey('import-estimate'),
            style: theme.textTheme.bodySmall,
          ),
        ),
      if (error != null)
        InlineError(
          key: const ValueKey('import-error'),
          message: error,
          padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, LedgerLayout.itemGap, LedgerLayout.pagePadding, 0),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, LedgerLayout.itemGap, LedgerLayout.pagePadding, 0),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(
              key: const ValueKey('import-tx-direct'),
              onPressed: ready ? () => _startTransactions(useAi: false) : null,
              child: const Text('直接生成'),
            ),
            OutlinedButton(
              key: const ValueKey('import-tx-ai'),
              onPressed: ready && chosen != null ? () => _startTransactions(useAi: true, provider: chosen) : null,
              child: const Text('AI 整理名称'),
            ),
          ],
        ),
      ),
    ];
  }
}
