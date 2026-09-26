import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/api/api_client.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../assets/asset_widgets.dart';
import '../widgets/widgets.dart';
import 'claim_mapping_sheet.dart';
import 'draft_store.dart';
import 'import_batch_sheets.dart';
import 'import_node_form.dart';
import 'import_node_tile.dart';
import 'import_undo.dart';
import 'perk_import_draft.dart';
import 'perk_import_providers.dart';

/// 核对页的路由：草稿由输入页交过来（pendingPerkImportProvider）。网页刷新后交过来的那份没了：本机存着核对到一半的
/// （draft_store.dart）就原地接着核对；也没有，才请人回导入页重新识别。
class PerkImportPreviewRoute extends ConsumerStatefulWidget {
  const PerkImportPreviewRoute({super.key});

  @override
  ConsumerState<PerkImportPreviewRoute> createState() => _PerkImportPreviewRouteState();
}

class _PerkImportPreviewRouteState extends ConsumerState<PerkImportPreviewRoute> {
  PerkImportDraft? _draft;
  Future<SavedPerkImport?>? _saved;

  @override
  Widget build(BuildContext context) {
    // 接到手就自己拿着：导完会把交过来的那份清掉，这一页的结果不能跟着变空。
    final draft = _draft ??= ref.watch(pendingPerkImportProvider);
    if (draft != null) return PerkImportPreviewPage(key: ObjectKey(draft), draft: draft);
    final saved = _saved ??= ref.read(perkImportDraftStoreProvider).load();
    return FutureBuilder<SavedPerkImport?>(
      future: saved,
      builder: (context, snap) {
        final restored = snap.data?.draft;
        if (restored != null) {
          _draft = restored;
          return PerkImportPreviewPage(key: ObjectKey(restored), draft: restored);
        }
        return Scaffold(
          appBar: AppBar(title: const Text('核对识别结果')),
          body: snap.connectionState != ConnectionState.done
              ? const SkeletonList()
              : EmptyState(
                  key: const ValueKey('perk-import-preview-lost'),
                  icon: Icons.auto_awesome_outlined,
                  title: '没有要核对的识别结果',
                  message: '页面刷新过，本机也没存着核对到一半的，回导入页重新识别一次',
                  actionLabel: '回导入页',
                  onAction: () => context.go('/assets/import'),
                ),
        );
      },
    );
  }
}

enum _Stage { review, submitting, done }

const double _treeMaxWidth = 880;
const double _paneWidth = 420;

/// AI 导入的预览（spec §6）：树形列表（平台 → 会员 → 权益，外加「补充到已有的卡」「未归属」「实物」「单独的平台」）、徽章、
/// 带计数的筛选、勾选联动、「领取平台」映射视图、长按多选的批量操作；宽屏（≥ 840）左边树、右边表单（顶上原文依据高亮）。
/// 导入只被两类情况拦住：同名多张卡没选、缺必填项。失败留在这一页，改过的都在，错误标到对应节点上。
/// 草稿每改一次（防抖 [saveDelay]）存一份到本机（draft_store.dart），意外关闭后能在输入页恢复；导入成功、选了「不导了」就清掉。
class PerkImportPreviewPage extends ConsumerStatefulWidget {
  const PerkImportPreviewPage({super.key, required this.draft});

  final PerkImportDraft draft;

  static const Duration saveDelay = Duration(milliseconds: 400);

  @override
  ConsumerState<PerkImportPreviewPage> createState() => _PerkImportPreviewPageState();
}

class _PerkImportPreviewPageState extends ConsumerState<PerkImportPreviewPage> {
  PerkImportDraft get draft => widget.draft;
  _Stage _stage = _Stage.review;
  ImportFilter _filter = ImportFilter.all;
  bool _selecting = false;
  final Set<String> _selected = {};

  /// 宽屏右栏正在改的节点。
  String? _current;
  PerkImportResult? _result;
  String? _submitError;

  late final PerkImportDraftStore _store = ref.read(perkImportDraftStoreProvider);
  Timer? _saveTimer;

  /// 导完了或者选了「不导了」：本机那份已经清掉，别再存回去。
  bool _settled = false;

  @override
  void initState() {
    super.initState();
    if (draft.all.isEmpty) return; // 什么都没识别出来，没什么可丢的
    draft.addListener(_scheduleSave);
    unawaited(_store.save(draft));
  }

  @override
  void dispose() {
    draft.removeListener(_scheduleSave);
    // 还有没落盘的改动（防抖没到点就离开了）：走之前补一次。
    if (_saveTimer?.isActive ?? false) {
      _saveTimer!.cancel();
      if (!_settled) unawaited(_store.save(draft));
    }
    super.dispose();
  }

  void _scheduleSave() {
    if (_settled) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(PerkImportPreviewPage.saveDelay, () {
      if (!_settled) unawaited(_store.save(draft));
    });
  }

  /// 这份草稿用完了（导进去了、放弃了、服务端说已经导过或撤销了）：本机那份清掉。
  void _settle() {
    _settled = true;
    _saveTimer?.cancel();
    unawaited(_store.clear());
  }

  static const Map<ImportFilter, String> _filterLabels = {
    ImportFilter.all: '全部',
    ImportFilter.attention: '需确认',
    ImportFilter.create: '新建',
    ImportFilter.update: '更新',
    ImportFilter.unchecked: '未勾选',
  };

  bool _onPopBlocked() {
    if (_stage == _Stage.submitting) return true;
    if (_selecting) {
      _stopSelecting();
      return true;
    }
    return false;
  }

  void _stopSelecting() => setState(() {
    _selecting = false;
    _selected.clear();
  });

  void _onTap(ImportNode n, LedgerData ledger, bool wide) {
    if (_selecting) {
      if (n.t != ImportNode.benefit) return;
      setState(() => _selected.contains(n.key) ? _selected.remove(n.key) : _selected.add(n.key));
      return;
    }
    if (wide) {
      setState(() => _current = n.key);
    } else {
      showImportNodeSheet(context, draft: draft, nodeKey: n.key, ledger: ledger);
    }
  }

  void _startSelecting(ImportNode n) {
    if (n.t != ImportNode.benefit) return;
    setState(() {
      _selecting = true;
      _selected.add(n.key);
    });
  }

  Future<void> _submit() async {
    setState(() {
      _stage = _Stage.submitting;
      _submitError = null;
    });
    try {
      final result = await ref.read(assetImportRepoProvider).apply(draft.toApplyBody());
      if (!mounted) return;
      // 导完就把交过来的那份清掉：浏览器后退再回到这一页，不能原样再导一次。
      ref.read(pendingPerkImportProvider.notifier).state = null;
      _settle();
      setState(() {
        _result = result;
        _stage = _Stage.done;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.review;
        _submitError = switch (e) {
          ApiException(code: 'import_invalid', :final details) => () {
            final errors = jsonMapList(details['errors']);
            draft.setErrors(errors);
            return '有 ${errors.length} 处要改，已经标在对应的项上；一条都没导入。';
          }(),
          ApiException(isNetwork: true, maybeSent: true) => '没等到服务器回应，不确定导进去没有。再点一次也不会重复导入。',
          ApiException(code: 'import_used') => () {
            _settle();
            return '这批识别结果已经导入过了，去看看有没有；要重来得重新识别一次。';
          }(),
          ApiException(code: 'import_undone') => () {
            _settle();
            return '这批导入已经撤销了；要再导得重新识别一次。';
          }(),
          ApiException(code: 'not_found') => () {
            _settle();
            return '这批识别结果在服务器上找不到了（超过 90 天会清掉），重新识别一次吧。';
          }(),
          _ => describeError(e),
        };
      });
    }
  }

  /// 「不导了？」的说明：「直接生成」没问模型，不说 token。
  String get _discardMessage => switch ((draft.fromTransactions, draft.usedAi)) {
    (true, false) => '生成的结果和刚才的修改都会丢掉，要再导得回去重新勾选、生成（不花 token）。',
    (true, true) => '整理出的结果和刚才的修改都会丢掉，要再导得重新整理（会再花一次 token），或者回去点「直接生成」。',
    _ => '识别结果和刚才的修改都会丢掉，要再导得重新识别（会再花一次 token）。',
  };

  @override
  Widget build(BuildContext context) {
    final ledger = ref.watch(ledgerProvider).valueOrNull ?? const LedgerData();
    // 什么都没识别出来：没什么可丢的，不问「不导了？」，也不画导入按钮，给一句说明和「回去改材料」。
    final nothing = draft.all.isEmpty;
    return ListenableBuilder(
      listenable: draft,
      builder: (context, _) => DiscardGuard(
        canPop: _stage == _Stage.done || nothing,
        title: '不导了？',
        message: _discardMessage,
        stayLabel: '接着核对',
        leaveLabel: '不导了',
        onBlocked: _onPopBlocked,
        onDiscard: _settle,
        child: Scaffold(
          appBar: _appBar(),
          body: switch (_stage) {
            _Stage.review when nothing => EmptyState(
              key: const ValueKey('perk-import-nothing'),
              icon: Icons.search_off_outlined,
              title: draft.fromImages ? '截图里没找到会员、权益或买的东西' : '材料里没找到会员、权益或买的东西',
              message: _nothingMessage,
              actionLabel: draft.fromImages ? '回去换截图' : '回去改一下材料',
              onAction: () => context.canPop() ? context.pop() : context.go('/assets/import'),
            ),
            _Stage.review => _review(context, ledger),
            _Stage.submitting => const _Submitting(),
            _Stage.done => _ResultView(result: _result!, draft: draft),
          },
          bottomNavigationBar: _stage == _Stage.review && !nothing ? (_selecting ? _selectionBar(ledger) : _submitBar()) : null,
        ),
      ),
    );
  }

  /// 什么都没识别出来时的说明：服务端的提示（去掉和标题重复的那句），没有就给个下一步的建议。
  String get _nothingMessage {
    final notes = draft.notices.where((n) => !n.startsWith('材料里没找到')).join('\n');
    if (notes.isNotEmpty) return notes;
    return draft.fromImages ? '换几张更清楚、带权益说明或订单详情的截图再试' : '换一段更完整的权益说明或订单详情再试';
  }

  PreferredSizeWidget _appBar() {
    if (_stage == _Stage.done) return AppBar(title: const Text('导入结果'));
    if (_selecting) {
      return AppBar(
        leading: IconButton(tooltip: '退出多选', icon: const Icon(Icons.close), onPressed: _stopSelecting),
        title: Text('选了 ${_selected.length} 项'),
        actions: [
          TextButton(
            onPressed: () => setState(() => _selected.addAll(_visible().where((n) => n.t == ImportNode.benefit).map((n) => n.key))),
            child: const Text('全选'),
          ),
        ],
      );
    }
    return AppBar(title: const Text('核对识别结果'));
  }

  /// 筛选不是「全部」时平铺的节点。
  List<ImportNode> _visible() => [
    for (final n in draft.all)
      if (draft.matches(n, _filter)) n,
  ];

  Widget _review(BuildContext context, LedgerData ledger) {
    return LayoutBuilder(
      builder: (context, box) {
        final wide = LedgerLayout.isExpanded(box.maxWidth);
        final tree = _tree(context, ledger, wide, box.maxWidth - (wide ? _paneWidth + 1 : 0));
        if (!wide) return tree;
        final current = _current == null ? null : draft.node(_current!);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: tree),
            VerticalDivider(width: 1, color: Theme.of(context).colorScheme.outlineVariant),
            SizedBox(
              width: _paneWidth,
              child: current == null
                  ? EmptyState(
                      title: '点左边一项，在这里改',
                      message: draft.fromImages
                          ? '顶上会显示它出自的那片截图'
                          : draft.fromTransactions
                              ? '顶上会写它来自哪几笔扣费'
                              : '顶上会高亮原文里的依据',
                      compact: true,
                    )
                  : ImportNodeForm(key: ValueKey('node-form-${current.key}'), draft: draft, nodeKey: current.key, ledger: ledger),
            ),
          ],
        );
      },
    );
  }

  Widget _tree(BuildContext context, LedgerData ledger, bool wide, double width) {
    final theme = Theme.of(context);
    Widget tile(ImportNode n, int depth, {String? where}) => ImportNodeTile(
      key: ValueKey('import-tile-${n.key}'),
      draft: draft,
      node: n,
      ledger: ledger,
      depth: depth,
      selecting: _selecting,
      selected: _selected.contains(n.key),
      current: wide && _current == n.key,
      where: where,
      onTap: () => _onTap(n, ledger, wide),
      onLongPress: _selecting ? null : () => _startSelecting(n),
    );
    List<Widget> benefitRows(String ref, int depth) => [
      for (final b in draft.benefitsOf(ref)) ...[
        tile(b, depth),
        for (final o in draft.optionsOf(b)) tile(o, depth + 1),
      ],
    ];

    final counts = [
      if (draft.platforms.isNotEmpty) '平台 ${draft.platforms.length} 个',
      if (draft.memberships.isNotEmpty) '会员卡 ${draft.memberships.length} 张',
      if (draft.benefits.isNotEmpty) '权益 ${draft.benefits.length} 项',
      if (draft.items.isNotEmpty) '物品 ${draft.items.length} 件',
    ];
    final claimRows = draft.claimRows;
    final claimPending = claimRows.where((r) => r.node.badges.contains('maybe_dup') || r.benefits.any((b) => b.badges.contains('claim_unsure'))).length;
    return ListView(
      padding: (wide ? EdgeInsets.zero : readableInsets(width, maxWidth: _treeMaxWidth)).copyWith(bottom: 24),
      children: [
        if (draft.truncated)
          Container(
            key: const ValueKey('import-truncated'),
            margin: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, LedgerLayout.itemGap, LedgerLayout.pagePadding, 0),
            padding: const EdgeInsets.all(LedgerLayout.itemGap),
            decoration: BoxDecoration(color: LedgerColors.of(context).warningContainer, borderRadius: BorderRadius.circular(LedgerShapes.control)),
            child: Text(_truncatedText, style: theme.textTheme.bodyMedium),
          ),
        // 截图来源：整批说一次「没法逐字核对」，不给每一条挂「依据未核实」（那样「需确认」就是全部，分不出轻重）。
        if (draft.fromImages)
          Container(
            key: const ValueKey('import-image-hint'),
            margin: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, LedgerLayout.itemGap, LedgerLayout.pagePadding, 0),
            padding: const EdgeInsets.all(LedgerLayout.itemGap),
            decoration: BoxDecoration(color: LedgerColors.of(context).surface2, borderRadius: BorderRadius.circular(LedgerShapes.control)),
            child: ImportNote(
              '这批是从截图识别的：截图里的字没法逐字核对，点开每一项对照截图检查。价格、日期、领取平台这些导进去会标「AI 推断」，确认过再点掉。',
              icon: Icons.image_search_outlined,
              padding: EdgeInsets.zero,
            ),
          ),
        for (final notice in draft.notices)
          Padding(
            padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 8, LedgerLayout.pagePadding, 0),
            child: Text(notice, style: theme.textTheme.bodySmall),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, LedgerLayout.itemGap, LedgerLayout.pagePadding, 4),
          child: Text(
            counts.isEmpty
                ? '材料里没找到会员、权益或买的东西。'
                : '${draft.fromTransactions ? '从流水生成了' : '识别出'} ${counts.join('、')}，勾了 ${draft.includedCount} 项。',
            key: const ValueKey('import-summary'),
            style: theme.textTheme.bodyMedium,
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 4, LedgerLayout.pagePadding, 8),
          child: Row(
            children: [
              for (final f in ImportFilter.values)
                if (f == ImportFilter.all || f == _filter || draft.countOf(f) > 0)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: CountFilterChip(
                      key: ValueKey('import-filter-${f.name}'),
                      label: _filterLabels[f]!,
                      count: draft.countOf(f),
                      selected: _filter == f,
                      onSelected: () => setState(() {
                        _filter = f;
                        _selected.removeWhere((k) => !draft.matches(draft.node(k)!, f));
                      }),
                    ),
                  ),
            ],
          ),
        ),
        if (claimRows.isNotEmpty && _filter == ImportFilter.all)
          ListTile(
            key: const ValueKey('claim-mapping-entry'),
            contentPadding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
            leading: const Icon(Icons.storefront_outlined),
            title: Text('领取平台 · ${claimRows.length} 个'),
            subtitle: Text(claimPending == 0 ? '什么权益去哪领，点开能并入已有的平台' : '$claimPending 个要确认：是新平台，还是账本里已有的'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showClaimMappingSheet(context, draft: draft, ledger: ledger),
          ),
        Divider(height: 1, color: theme.colorScheme.outlineVariant),
        if (_filter != ImportFilter.all) ...[
          if (_visible().isEmpty) const EmptyState(compact: true, title: '这一类没有了'),
          for (final n in _visible()) tile(n, 0, where: _whereOf(n, ledger)),
        ] else ...[
          for (final p in draft.rootPlatforms) ...[
            tile(p, 0),
            for (final m in draft.membershipsOf(p)) ...[
              tile(m, 1),
              ...benefitRows('key:${m.key}', 2),
            ],
          ],
          if (draft.homelessMemberships.isNotEmpty) ...[
            const SizedBox(height: LedgerLayout.itemGap),
            const SectionHeader('没写平台的卡'),
            for (final m in draft.homelessMemberships) ...[
              tile(m, 0),
              ...benefitRows('key:${m.key}', 1),
            ],
          ],
          for (final ref in draft.existingCardRefs) ...[
            const SizedBox(height: LedgerLayout.itemGap),
            SectionHeader('补充到「${ledger.membership(ref.substring(3))?.title ?? '已有的卡'}」', key: ValueKey('import-existing-$ref')),
            ...benefitRows(ref, 0),
          ],
          for (final ref in draft.existingPlatformRefs) ...[
            const SizedBox(height: LedgerLayout.itemGap),
            SectionHeader('挂到账本里的「${ledger.platform(ref.substring(3))?.name ?? '已有平台'}」', key: ValueKey('import-platform-$ref')),
            for (final m in draft.membershipsOfRef(ref)) ...[
              tile(m, 0),
              ...benefitRows('key:${m.key}', 1),
            ],
          ],
          if (draft.unowned.isNotEmpty) ...[
            const SizedBox(height: LedgerLayout.itemGap),
            SectionHeader('未归属 · ${draft.unowned.length} 项', key: const ValueKey('import-unowned')),
            Padding(
              padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 0, LedgerLayout.pagePadding, 4),
              child: Text('找不到属于哪张卡，默认不导。长按多选后「移到卡」，或点开改。', style: theme.textTheme.bodySmall),
            ),
            for (final b in draft.unowned) ...[
              tile(b, 0),
              for (final o in draft.optionsOf(b)) tile(o, 1),
            ],
          ],
          if (draft.items.isNotEmpty) ...[
            const SizedBox(height: LedgerLayout.itemGap),
            SectionHeader('实物 · ${draft.items.length} 件', key: const ValueKey('import-items')),
            for (final i in draft.items) tile(i, 0),
          ],
          if (draft.standalonePlatforms.isNotEmpty) ...[
            const SizedBox(height: LedgerLayout.itemGap),
            SectionHeader('单独的平台 · ${draft.standalonePlatforms.length} 个', key: const ValueKey('import-standalone')),
            Padding(
              padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 0, LedgerLayout.pagePadding, 4),
              child: Text('下面没挂会员卡、也没有权益去它那领，默认不导；要导就勾上。', style: theme.textTheme.bodySmall),
            ),
            for (final p in draft.standalonePlatforms) tile(p, 0),
          ],
        ],
      ],
    );
  }

  /// 截断横幅：三种情形各说各的 —— 没续写、续写了还没写完、续写那次出错了；截图的「分段」是只选后面那几片。
  String get _truncatedText {
    final head = draft.continueFailed
        ? '材料太长，模型只写了一部分，让它接着写时出错了'
        : (draft.continued ? '材料太长，模型续写了一次还是没写完' : '材料太长，模型只写了一部分');
    final tail = draft.fromImages ? '没识别到的部分，只选后面那几片截图再导一次。' : '剩下的建议分段再粘一次。';
    return '$head（下面是已经收到的 ${draft.all.length} 条）。$tail';
  }

  /// 平铺时的「在哪」：权益写它的卡，会员写它的平台。
  String? _whereOf(ImportNode n, LedgerData ledger) {
    final ref = switch (n.t) {
      ImportNode.benefit => n.fields['membership'],
      ImportNode.membership => n.fields['platform'],
      _ => null,
    };
    if (ref is! String) return null;
    if (ref.startsWith('id:')) return ledger.membership(ref.substring(3))?.title;
    final parent = draft.refNode(ref);
    return parent == null ? null : '在 ${parent.name} 下';
  }

  Widget _submitBar() {
    final theme = Theme.of(context);
    final blockers = draft.blockers;
    final n = draft.includedCount;
    final error = _submitError;
    return ConstrainedBottomBar(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (error != null)
            InlineError(
              key: const ValueKey('perk-import-submit-error'),
              message: error,
              padding: const EdgeInsets.only(bottom: 8),
            ),
          if (blockers.isNotEmpty)
            Row(
              key: const ValueKey('perk-import-blockers'),
              children: [
                Expanded(
                  child: Text(
                    '还有 ${blockers.length} 处要处理：${blockers.first.reason}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: LedgerColors.of(context).warning),
                  ),
                ),
                TextButton(onPressed: () => setState(() => _filter = ImportFilter.attention), child: const Text('看看')),
              ],
            ),
          FilledButton(
            key: const ValueKey('perk-import-submit'),
            onPressed: draft.canSubmit ? _submit : null,
            child: Text(n > 0 ? '导入 $n 项' : '一项都没勾'),
          ),
        ],
      ),
    );
  }

  Future<void> _move(List<String> keys, LedgerData ledger) async {
    final skipped = await showBatchMoveSheet(context, draft: draft, keys: keys, ledger: ledger);
    if (!mounted || skipped == 0) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('有 $skipped 项是账本里已有的权益，导入不换卡，没移；要移去会员详情里改。')),
    );
  }

  Widget _selectionBar(LedgerData ledger) {
    final keys = _selected.toList();
    final any = keys.isNotEmpty;
    return ConstrainedBottomBar(
      child: Row(
        children: [
          _BarAction(
            key: const ValueKey('batch-claim'),
            icon: Icons.storefront_outlined,
            label: '领取平台',
            onTap: any ? () => showBatchClaimSheet(context, draft: draft, keys: keys, ledger: ledger) : null,
          ),
          _BarAction(
            key: const ValueKey('batch-quota'),
            icon: Icons.event_repeat_outlined,
            label: '周期',
            onTap: any ? () => showBatchQuotaSheet(context, draft: draft, keys: keys) : null,
          ),
          _BarAction(
            key: const ValueKey('batch-value'),
            icon: Icons.sell_outlined,
            label: '价值',
            onTap: any ? () => showBatchValueSheet(context, draft: draft, keys: keys) : null,
          ),
          _BarAction(
            key: const ValueKey('batch-move'),
            icon: Icons.drive_file_move_outline,
            label: '移到卡',
            onTap: any ? () => _move(keys, ledger) : null,
          ),
          _BarAction(
            key: const ValueKey('batch-uncheck'),
            icon: Icons.check_box_outline_blank,
            label: '不导入',
            onTap: any ? () => draft.batchUncheck(keys) : null,
          ),
        ],
      ),
    );
  }
}

/// 提交中：限宽、进度条（不知道还要多久，用不确定的那种）、一句「别关」，和账单导入的进度页一个样子。
class _Submitting extends StatelessWidget {
  const _Submitting();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(LedgerLayout.widePagePadding),
          child: Column(
            key: const ValueKey('perk-import-submitting'),
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('正在导入…', style: theme.textTheme.titleMedium),
              const SizedBox(height: LedgerLayout.itemGap),
              const LinearProgressIndicator(),
              const SizedBox(height: LedgerLayout.itemGap),
              Text('别关这个页面，导完会告诉你结果；回应丢了再点一次也不会重复导入。', style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}

class _BarAction extends StatelessWidget {
  const _BarAction({super.key, required this.icon, required this.label, this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = onTap == null ? theme.colorScheme.onSurface.withValues(alpha: 0.38) : theme.colorScheme.onSurface;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(LedgerShapes.control),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color),
              const SizedBox(height: 4),
              Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelMedium?.copyWith(color: color)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 结果页：新建 / 更新了什么、自动并入的平台、随物品记的流水；「去看看」按导入的内容去物品 tab、会员详情或会员权益的本期。
/// 「撤销本次导入」（spec §4 undo）：确认后整批撤掉，结果原地换成撤了什么、改回了什么、哪些没动。
class _ResultView extends ConsumerStatefulWidget {
  const _ResultView({required this.result, required this.draft});

  final PerkImportResult result;
  final PerkImportDraft draft;

  @override
  ConsumerState<_ResultView> createState() => _ResultViewState();
}

class _ResultViewState extends ConsumerState<_ResultView> {
  PerkImportResult get result => widget.result;
  PerkImportDraft get draft => widget.draft;

  bool _undoing = false;
  PerkImportUndoResult? _undone;
  String? _undoError;

  /// 「去看看」去哪：只导了物品 → 物品 tab；补充到某张卡 → 那张卡的详情；其余 → 会员权益的本期。
  String get _destination {
    final perks = result.createdOf('memberships') + result.createdOf('benefits') + result.updatedOf('memberships') + result.updatedOf('benefits');
    if (perks == 0 && result.createdOf('items') > 0) return '/assets';
    final target = draft.targetMembershipId;
    if (target != null) return '/assets/memberships/$target';
    return '/assets?tab=perks&view=current';
  }

  Future<void> _undo() async {
    if (!await confirmImportUndo(context) || !mounted) return;
    setState(() {
      _undoing = true;
      _undoError = null;
    });
    try {
      final undone = await ref.read(assetImportRepoProvider).undo(draft.importId);
      if (!mounted) return;
      setState(() {
        _undone = undone;
        _undoing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _undoing = false;
        _undoError = describeUndoError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final undone = _undone;
    return ListView(
      padding: readableInsets(width, maxWidth: 720).add(const EdgeInsets.all(LedgerLayout.pagePadding)),
      children: undone == null ? _imported(context) : _reverted(context, undone),
    );
  }

  List<Widget> _imported(BuildContext context) {
    final theme = Theme.of(context);
    final created = importCountLine(result.created);
    final updated = importCountLine(result.updated);
    return [
      Text('导入好了', key: const ValueKey('perk-import-result-title'), style: theme.textTheme.titleLarge),
      const SizedBox(height: LedgerLayout.itemGap),
      Text(created.isEmpty ? '没有新建的' : '新建：$created', key: const ValueKey('perk-import-created'), style: theme.textTheme.bodyLarge),
      if (updated.isNotEmpty) Text('更新：$updated', style: theme.textTheme.bodyLarge),
      if (result.createdOf('transactions') > 0) Text('同时记了 ${result.createdOf('transactions')} 笔支出', style: theme.textTheme.bodyMedium),
      if (result.autoMerged.isNotEmpty) ...[
        const SizedBox(height: 8),
        // 原因不止「家里别人刚建了」：同名多张卡选定后卡里已有的权益、并入已有平台后那边已有的卡也会走到这里。
        Text(
          '${result.autoMerged.map((m) => '「${m['name']}」').join('')}账本里已经有了，并进了原来那条，没有重复建。',
          key: const ValueKey('perk-import-auto-merged'),
          style: theme.textTheme.bodySmall,
        ),
      ],
      const SizedBox(height: 8),
      Text(
        // 从流水来的卡不标「AI 推断」（价格、日期都是流水里看到的），不提那个小点。
        '${draft.fromTransactions ? '' : '标着「AI 推断」的字段，点一下能确认或修改。'}导错了可以整批撤销：现在点下面的「撤销本次导入」，'
        '或者 7 天内到资产页右上角的「最近的 AI 导入」里撤。',
        key: const ValueKey('perk-import-undo-hint'),
        style: theme.textTheme.bodySmall,
      ),
      if (_undoError != null)
        InlineError(key: const ValueKey('perk-import-undo-error'), message: _undoError!, padding: const EdgeInsets.only(top: LedgerLayout.itemGap)),
      const SizedBox(height: LedgerLayout.groupGap),
      Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          FilledButton(key: const ValueKey('perk-import-go'), onPressed: _undoing ? null : () => context.go(_destination), child: const Text('去看看')),
          OutlinedButton(onPressed: _undoing ? null : () => context.canPop() ? context.pop() : context.go('/assets/import'), child: const Text('再导一段')),
          TextButton(
            key: const ValueKey('perk-import-undo'),
            onPressed: _undoing ? null : _undo,
            style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
            child: Text(_undoing ? '正在撤销…' : '撤销本次导入'),
          ),
        ],
      ),
    ];
  }

  List<Widget> _reverted(BuildContext context, PerkImportUndoResult undone) {
    final theme = Theme.of(context);
    return [
      Text('已撤销', key: const ValueKey('perk-import-undone-title'), style: theme.textTheme.titleLarge),
      const SizedBox(height: LedgerLayout.itemGap),
      ImportUndoSummary(undone: undone),
      const SizedBox(height: LedgerLayout.groupGap),
      OutlinedButton(
        key: const ValueKey('perk-import-again'),
        onPressed: () => context.canPop() ? context.pop() : context.go('/assets/import'),
        child: const Text('再导一段'),
      ),
    ];
  }
}
