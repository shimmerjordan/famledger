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

/// AI 智能导入的输入页（`/assets/import`，spec §6）：来源分段（粘贴 / 截图）、识别范围、AI 渠道、发送前的 token 估算；
/// 点「开始识别」后原地换成进度（SSE，已识别 N 条，可以取消），识别完把草稿交给预览页。
/// 截图模式只列没被测出「看不了图」的渠道（vision != false）；切片、缩放在本机做（screenshots.dart）。
/// 本机有上次没导完的草稿（意外关闭）时，顶上给「继续核对 / 不要了」。
///
/// 网址和从流水 P7 加进 [PerkImportPage.sources]。
class PerkImportPage extends ConsumerStatefulWidget {
  const PerkImportPage({super.key, this.want = ImportWant.auto, this.targetMembershipId});

  /// 识别范围的预选：物品 tab 进来是「只要实物」，会员权益 tab 进来是「只要会员权益」。
  final ImportWant want;

  /// 会员详情的「AI 补充权益」：识别出的权益都归到这张卡（识别范围固定为会员权益）。
  final String? targetMembershipId;

  /// 这一版开放的来源。
  static const List<String> sources = ['paste', 'image'];

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

  /// 来源：paste | image。
  String _source = 'paste';
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
    if (_imageMode ? !_batch.sendable : _text.text.trim().isEmpty) {
      setState(() => _error = _imageMode ? '先选几张截图' : '先粘点东西进来');
      return;
    }
    FocusScope.of(context).unfocus();
    _sentImages = _imageMode ? [for (final s in _batch.slices) s.png] : const [];
    _sentLabels = _imageMode ? [for (final s in _batch.slices) s.label] : const [];
    setState(() {
      _extracting = true;
      _count = 0;
      _stage = _imageMode ? '正在请模型看图…' : '正在请模型识别…';
      _error = null;
      _saved = null; // 新识别出来的会盖掉本机那份
    });
    _sub = ref
        .read(assetImportRepoProvider)
        .extract(
          text: _imageMode ? '' : _text.text,
          images: _sentImages,
          want: _want,
          targetMembershipId: widget.targetMembershipId,
          providerId: provider?.id,
        )
        .listen(_onEvent, onError: _onError);
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
    setState(() {
      _extracting = false;
      _error = switch (e) {
        ApiException(code: 'no_provider') => '还没有可用的 AI 渠道，先去设置里加一个。',
        ApiException(code: 'import_in_progress') => '你还有一次识别没结束（可能在另一台设备上），等它结束再试。',
        ApiException(code: 'provider_no_vision') => '这个渠道看不了图片，换一个支持看图的渠道。',
        ApiException(code: 'body_too_large') => '截图合计太大了，删掉几片再试。',
        _ => describeError(e),
      };
    });
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
              Text('正在识别…', style: theme.textTheme.titleMedium),
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
                _imageMode ? '截图多的要一两分钟。取消就不再花 token，选的截图都还在。' : '长材料要一两分钟。取消就不再花 token，粘贴的内容都还在。',
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
              segments: const [
                ButtonSegment(value: 'paste', icon: Icon(Icons.content_paste), label: Text('粘贴', key: ValueKey('import-source-paste'))),
                ButtonSegment(value: 'image', icon: Icon(Icons.image_outlined), label: Text('截图', key: ValueKey('import-source-image'))),
              ],
              selected: {_source},
              onSelectionChanged: (v) => setState(() {
                _source = v.first;
                _error = null;
              }),
            ),
          ),
          if (_imageMode)
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
          if (widget.targetMembershipId == null)
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
            label: '用哪个 AI 渠道',
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
    final theme = Theme.of(context);
    final chosen = _chosen(all);
    final error = _error;
    final text = _text.text;
    final maxOut = chosen?.importMaxTokens ?? 12000;
    final empty = _imageMode ? _batch.slices.isEmpty : text.trim().isEmpty;
    final input = _imageMode ? _batch.estimatedTokens : estimateImportTokens(text);
    final ready = chosen != null && (!_imageMode || (_batch.sendable && !_preparing));
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
}
