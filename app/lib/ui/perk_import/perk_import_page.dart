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
import 'perk_import_draft.dart';
import 'perk_import_providers.dart';

/// AI 智能导入的输入页（`/assets/import`，spec §6）：粘贴材料、识别范围、AI 渠道、发送前的 token 估算；
/// 点「开始识别」后原地换成进度（SSE，已识别 N 条，可以取消），识别完把草稿交给预览页。
///
/// 本阶段只有「粘贴」一种来源（截图 P5、网址和从流水 P7 加上），所以不画来源的分段按钮，
/// 等第二种来源来了再加（[PerkImportPage.sources] 超过一种时画）。
class PerkImportPage extends ConsumerStatefulWidget {
  const PerkImportPage({super.key, this.want = ImportWant.auto, this.targetMembershipId});

  /// 识别范围的预选：物品 tab 进来是「只要实物」，会员权益 tab 进来是「只要会员权益」。
  final ImportWant want;

  /// 会员详情的「AI 补充权益」：识别出的权益都归到这张卡（识别范围固定为会员权益）。
  final String? targetMembershipId;

  /// 这一版开放的来源。
  static const List<String> sources = ['paste'];

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
    if (_text.text.trim().isEmpty) {
      setState(() => _error = '先粘点东西进来');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _extracting = true;
      _count = 0;
      _stage = '正在请模型识别…';
      _error = null;
    });
    _sub = ref
        .read(assetImportRepoProvider)
        .extract(text: _text.text, want: _want, targetMembershipId: widget.targetMembershipId, providerId: provider?.id)
        .listen(_onEvent, onError: _onError);
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
        ref.read(pendingPerkImportProvider.notifier).state = PerkImportDraft.fromJson(draft);
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
              Text(
                _count == 0 ? _stage : '已识别 $_count 条',
                key: const ValueKey('import-progress'),
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 4),
              Text('长材料要一两分钟。取消就不再花 token，粘贴的内容都还在。', style: theme.textTheme.bodySmall),
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
          if (widget.targetMembershipId != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, LedgerLayout.itemGap, LedgerLayout.pagePadding, 0),
              child: Text(
                '识别出的权益都归到「${target?.title ?? '这张卡'}」，导入前可以逐条改。',
                key: const ValueKey('import-target'),
                style: theme.textTheme.bodyMedium,
              ),
            ),
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

  List<AiProvider> _usable(List<AiProvider> all) => [
    for (final p in all)
      if (p.enabled) p,
  ];

  AiProvider? _chosen(List<AiProvider> all) {
    final usable = _usable(all);
    return usable.where((p) => p.id == _providerId).firstOrNull ?? defaultProviderOf(usable);
  }

  Widget _providerPicker(BuildContext context, List<AiProvider> all) {
    final usable = _usable(all);
    if (usable.isEmpty) {
      final isAdmin = ref.watch(sessionProvider)?.me.isAdmin ?? false;
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
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, LedgerLayout.groupGap, LedgerLayout.pagePadding, 0),
        child: Text(
          text.trim().isEmpty ? '识别完先在预览里逐条核对，确认了才会落库。' : '预计输入约 ${estimateImportTokens(text)} token，最多输出 $maxOut token。',
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
          onPressed: chosen == null ? null : () => _start(chosen),
          child: const Text('开始识别'),
        ),
      ),
    ];
  }
}
