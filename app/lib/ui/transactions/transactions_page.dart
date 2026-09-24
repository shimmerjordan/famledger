import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/shell.dart';
import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../../data/repos/transactions_repo.dart';
import '../widgets/widgets.dart';
import 'tx_bulk_dialogs.dart';
import 'tx_filter_sheet.dart';
import 'tx_providers.dart';
import 'tx_table.dart';
import 'tx_tile.dart';

/// 账单：按日分组的无限滚动列表 + 搜索 + 筛选。
///
/// 宽屏（≥ 840）换成表格：可多选批量改类别/基金、批量删除，并响应快捷键
/// N 记一笔、/ 搜索、Delete 删除所选、Esc 取消选择。
class TransactionsPage extends ConsumerStatefulWidget {
  const TransactionsPage({super.key});

  @override
  ConsumerState<TransactionsPage> createState() => _TransactionsPageState();
}

class _TransactionsPageState extends ConsumerState<TransactionsPage> {
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: '账单搜索');
  final ScrollController _scroll = ScrollController();

  /// 快捷键挂在一个自有的焦点域上：搜索框失焦（默认退回最近的焦点域）后
  /// 焦点落在这里，按键仍然先经过这个页面，而不是直接冒到路由外面。
  final FocusScopeNode _keys = FocusScopeNode(debugLabel: '账单快捷键');
  Timer? _debounce;

  /// 宽屏表格里勾选的流水 id。
  final Set<String> _selected = {};
  bool _busy = false;

  /// 批量操作失败的说明；[retry] 是原样再发一次（选择、弹窗里选的都不用重来）。
  ({String message, VoidCallback? retry})? _bulkError;

  /// 这个 Tab 当前是否在前台（外壳把其余分支放在 Offstage 里，焦点可能还留着）。
  bool _active = true;

  @override
  void initState() {
    super.initState();
    _search.text = ref.read(txFilterProvider).q ?? '';
    _scroll.addListener(_onScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = TickerMode.of(context);
    // 从别的 Tab 切回来时焦点多半还在那边，拿回来快捷键才灵。
    if (active && !_active && widthClassOf(context) == WidthClass.expanded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_keys.hasFocus) _keys.requestFocus();
      });
    }
    _active = active;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.dispose();
    _search.dispose();
    _searchFocus.dispose();
    _keys.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    // 离底还有一屏半就去拿下一页，别让用户看见「转圈等」。
    if (position.pixels >= position.maxScrollExtent - 400) {
      unawaited(ref.read(txListProvider.notifier).loadMore());
    }
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      final current = ref.read(txFilterProvider);
      unawaited(
        ref.read(txListProvider.notifier).setFilter(current.copyWith(q: value)),
      );
    });
  }

  Future<void> _openFilter(LedgerData ledger) async {
    final next = await showTxFilterSheet(
      context,
      initial: ref.read(txFilterProvider),
      ledger: ledger,
    );
    if (next == null) return;
    await ref.read(txListProvider.notifier).setFilter(next);
  }

  Future<void> _clearFilter() async {
    _search.clear();
    await ref
        .read(txListProvider.notifier)
        .setFilter(const TxFilter(limit: TxListController.pageSize));
  }

  /// 当前列表里被勾上的那些（换了筛选、删掉了的不算）。
  List<Transaction> _chosen() {
    final items = ref.read(txListProvider).valueOrNull?.items ?? const [];
    return [
      for (final tx in items)
        if (_selected.contains(tx.id)) tx,
    ];
  }

  void _toggle(Transaction tx, bool on) => setState(() {
    _bulkError = null;
    on ? _selected.add(tx.id) : _selected.remove(tx.id);
  });

  void _toggleAll(bool on) => setState(() {
    _bulkError = null;
    _selected.clear();
    if (on) {
      final items = ref.read(txListProvider).valueOrNull?.items ?? const [];
      _selected.addAll(items.map((tx) => tx.id));
    }
  });

  void _clearSelection() => setState(() {
    _selected.clear();
    _bulkError = null;
  });

  /// 一次最多 [TransactionsRepo.maxBulk] 笔；超了先说，别等确认完才失败。
  bool _withinLimit(int count) {
    if (count <= TransactionsRepo.maxBulk) return true;
    setState(
      () => _bulkError = (
        message: '一次最多 ${TransactionsRepo.maxBulk} 笔，先少选一些',
        retry: null,
      ),
    );
    return false;
  }

  Future<void> _changeCategory(LedgerData ledger) async {
    final chosen = _chosen();
    final plain = chosen.where((tx) => !tx.isTransfer).toList();
    if (plain.isEmpty || !_withinLimit(plain.length)) return;
    final id = await showBulkCategoryDialog(
      context,
      categories: plain.first.isIncome
          ? ledger.incomeCategories()
          : ledger.expenseCategories(),
      count: plain.length,
    );
    if (id == null || !mounted) return;
    await _runBulk(
      [for (final tx in plain) tx.id],
      patch: {'categoryId': id},
      done: _doneText(plain.length, chosen.length - plain.length, '类别'),
    );
  }

  Future<void> _changeFund(LedgerData ledger) async {
    final chosen = _chosen();
    final plain = chosen.where((tx) => !tx.isTransfer).toList();
    if (plain.isEmpty || !_withinLimit(plain.length)) return;
    final id = await showBulkFundDialog(
      context,
      funds: ledger.activeFunds,
      count: plain.length,
      indexOf: (fund) {
        final index = ledger.fundIndex(fund.id);
        return index < 0 ? 0 : index;
      },
    );
    if (id == null || !mounted) return;
    await _runBulk(
      [for (final tx in plain) tx.id],
      patch: {'fundId': id},
      done: _doneText(plain.length, chosen.length - plain.length, '基金'),
    );
  }

  /// 转账不参与改类别/基金（没有类别，基金又是成对的），这里不发给服务端，
  /// 提示里也说清楚哪几笔没动。
  static String _doneText(int changed, int transfers, String what) =>
      transfers == 0
      ? '改好了 $changed 笔'
      : '改好了 $changed 笔，$transfers 笔转账不改$what';

  Future<void> _deleteSelected() async {
    if (_busy) return;
    final chosen = _chosen();
    if (chosen.isEmpty || !_withinLimit(chosen.length)) return;
    final ok = await confirmBulkDelete(context, count: chosen.length);
    if (!ok || !mounted) return;
    await _runBulk(
      [for (final tx in chosen) tx.id],
      delete: true,
      done: '删掉了 ${chosen.length} 笔',
    );
  }

  /// 走 `POST /transactions/bulk`：成功就刷新、清空选择；失败把服务端的那句
  /// 中文贴在表头下面，选择原样留着好重试。
  Future<void> _runBulk(
    List<String> ids, {
    Map<String, dynamic>? patch,
    bool delete = false,
    required String done,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _bulkError = null;
    });
    try {
      await ref
          .read(transactionsRepoProvider)
          .bulk(ids, patch: patch, delete: delete);
      ref.invalidate(txListProvider);
      ref.invalidate(txDetailProvider);
      ref.invalidate(recentTxProvider);
      ref.invalidate(pendingTxProvider);
      ref.invalidate(statsProvider);
      if (!mounted) return;
      setState(_selected.clear);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _bulkError = (
          message: '${delete ? '没删成' : '没改成'}：${describeError(error)}',
          retry: () => _runBulk(ids, patch: patch, delete: delete, done: done),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || !_active) return KeyEventResult.ignored;
    // 输入框自己不认 Esc；不放开的话纯键盘用户按了 / 就回不到快捷键。
    // 输入法还在拼字时这个 Esc 是给输入法取消候选的，不抢。
    if (event.logicalKey == LogicalKeyboardKey.escape &&
        _searchFocus.hasFocus &&
        !_search.value.composing.isValid) {
      _searchFocus.unfocus();
      return KeyEventResult.handled;
    }
    if (widthClassOf(context) != WidthClass.expanded || _typing()) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    // Ctrl+N、⌘N 这些留给浏览器/系统。
    if (keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        keyboard.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.keyN) {
      context.push('/transactions/new');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.slash) {
      _searchFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape && _selected.isNotEmpty) {
      _clearSelection();
      return KeyEventResult.handled;
    }
    // Mac 键盘没有独立的 Delete 键，退格也认；反正都要二次确认。
    if ((key == LogicalKeyboardKey.delete ||
            key == LogicalKeyboardKey.backspace) &&
        _chosen().isNotEmpty) {
      unawaited(_deleteSelected());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 焦点在任何输入框里（不只是搜索框）时字母键是在打字，不是快捷键。
  static bool _typing() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    return context.widget is EditableText ||
        context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  Widget _selectionBar(LedgerData? ledger) {
    final chosen = _chosen();
    final plain = chosen.where((tx) => !tx.isTransfer);
    final kinds = plain.map((tx) => tx.type).toSet();
    final categoryHint = plain.isEmpty
        ? '转账没有类别'
        : (kinds.length > 1 ? '支出和收入的类别不通用，分开改' : null);
    final fundHint = plain.isEmpty ? '转账的基金是成对的，去详情里改' : null;
    final ready = !_busy && ledger != null;
    return TxSelectionBar(
      count: chosen.length,
      onCategory: ready && categoryHint == null
          ? () => _changeCategory(ledger)
          : null,
      categoryHint: categoryHint,
      onFund: ready && fundHint == null ? () => _changeFund(ledger) : null,
      fundHint: fundHint,
      onDelete: _busy ? null : _deleteSelected,
      onCancel: _clearSelection,
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(txListProvider);
    final ledger = ref.watch(ledgerProvider).valueOrNull;
    final filter = ref.watch(txFilterProvider);
    final activeCount = filter.activeCount - (filter.q?.isEmpty ?? true ? 0 : 1);
    final hasRange = filter.from != null || filter.to != null;
    final wide = widthClassOf(context) == WidthClass.expanded;

    // 换了条件，勾着的那些多半已经不在眼前了；留着只会误删看不见的行。
    ref.listen<TxFilter>(txFilterProvider, (_, _) {
      if (_selected.isNotEmpty || _bulkError != null) _clearSelection();
    });

    return FocusScope(
      node: _keys,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('账单'),
          actions: [
            IconButton(
              tooltip: '导入',
              onPressed: () => context.push('/import'),
              icon: const Icon(Icons.upload_file_outlined),
            ),
            IconButton(
              tooltip: '筛选',
              onPressed: ledger == null ? null : () => _openFilter(ledger),
              icon: Badge(
                isLabelVisible: activeCount > 0 || hasRange,
                label: Text('${activeCount + (hasRange ? 1 : 0)}'),
                child: const Icon(Icons.filter_list),
              ),
            ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(60),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                LedgerLayout.pagePadding,
                0,
                LedgerLayout.pagePadding,
                12,
              ),
              child: TextField(
                controller: _search,
                focusNode: _searchFocus,
                onChanged: _onSearchChanged,
                // 网页上点别处默认不失焦，快捷键就一直被输入框吞着。
                onTapOutside: wide ? (_) => _searchFocus.unfocus() : null,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: wide ? '搜商户或备注（按 /）' : '搜商户或备注',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _search,
                    builder: (context, value, _) => value.text.isEmpty
                        ? const SizedBox.shrink()
                        : IconButton(
                            tooltip: '清空搜索',
                            icon: const Icon(Icons.close, size: 20),
                            onPressed: () {
                              _search.clear();
                              _onSearchChanged('');
                            },
                          ),
                  ),
                  isDense: true,
                ),
              ),
            ),
          ),
        ),
        body: Column(
          children: [
            // 换筛选条件时列表是「带旧数据的 reload」，AsyncValueView 会跳过骨架
            // （不闪屏是对的），但总得让人知道在重拉 —— 一条 2dp 的进度条。
            // 高度恒定，出现/消失不会把下面的内容顶一下。
            SizedBox(
              height: 2,
              child: list.isReloading || _busy
                  ? const LinearProgressIndicator(minHeight: 2)
                  : null,
            ),
            if (wide && _bulkError != null)
              TxBulkError(
                message: _bulkError!.message,
                onRetry: _bulkError!.retry,
                onClose: () => setState(() => _bulkError = null),
              ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () => ref.read(txListProvider.notifier).refresh(),
                child: AsyncValueView<TxListState>(
                  value: list,
                  loading: const SkeletonList(rows: 8),
                  onRetry: () => ref.read(txListProvider.notifier).refresh(),
                  errorPadding: const EdgeInsets.all(LedgerLayout.pagePadding),
                  data: (state) => wide && state.items.isNotEmpty
                      ? TxTable(
                          items: state.items,
                          ledger: ledger,
                          scroll: _scroll,
                          selected: _selected,
                          onToggle: _toggle,
                          onToggleAll: _toggleAll,
                          onOpen: (tx) => context.push('/transactions/${tx.id}'),
                          selectionBar: _selectionBar(ledger),
                          footer: _Footer(
                            state: state,
                            onRetry: () =>
                                ref.read(txListProvider.notifier).loadMore(),
                          ),
                        )
                      : _List(
                          state: state,
                          ledger: ledger,
                          scroll: _scroll,
                          filtered: !filter.isEmpty,
                          onClearFilter: _clearFilter,
                          onRetryMore: () =>
                              ref.read(txListProvider.notifier).loadMore(),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _List extends StatelessWidget {
  const _List({
    required this.state,
    required this.scroll,
    required this.filtered,
    required this.onClearFilter,
    required this.onRetryMore,
    this.ledger,
  });

  final TxListState state;
  final LedgerData? ledger;
  final ScrollController scroll;
  final bool filtered;
  final VoidCallback onClearFilter;
  final VoidCallback onRetryMore;

  @override
  Widget build(BuildContext context) {
    if (state.items.isEmpty) {
      // 空列表也要能下拉刷新，所以套一层可滚动的。
      return ListView(
        controller: scroll,
        children: [
          const SizedBox(height: 40),
          filtered
              ? EmptyState(
                  title: '没有符合条件的流水',
                  message: '换个条件，或者把筛选清掉看全部。',
                  icon: Icons.filter_list_off,
                  actionLabel: '清除筛选',
                  onAction: onClearFilter,
                )
              : EmptyState(
                  title: '还没有流水',
                  message: '记一笔，或者打开自动记账让它自己进来。',
                  icon: Icons.receipt_long_outlined,
                  actionLabel: '记一笔',
                  onAction: () => context.push('/transactions/new'),
                ),
        ],
      );
    }

    final rows = <Object>[];
    for (final group in groupByDay(state.items)) {
      rows.add(group);
      rows.addAll(group.items);
    }

    return ListView.builder(
      controller: scroll,
      padding: const EdgeInsets.only(bottom: 96),
      itemCount: rows.length + 1,
      itemBuilder: (context, index) {
        if (index == rows.length) {
          return _Footer(state: state, onRetry: onRetryMore);
        }
        final row = rows[index];
        if (row is TxDayGroup) return _DayHeader(group: row);
        final tx = row as Transaction;
        return TxTile(
          tx: tx,
          ledger: ledger,
          onTap: () => context.push('/transactions/${tx.id}'),
        );
      },
    );
  }
}

/// 日期 + 当天合计。合计只算「已经加载出来的」那些，翻页到下一段会补上。
class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.group});

  final TxDayGroup group;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LedgerLayout.pagePadding,
        LedgerLayout.pagePadding,
        LedgerLayout.pagePadding,
        4,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              Dates.dayLabel(group.date),
              style: theme.textTheme.titleSmall,
            ),
          ),
          if (group.incomeCents > 0) ...[
            Text('收 ', style: theme.textTheme.bodySmall),
            MoneyText(group.incomeCents, size: MoneySize.small, signed: true),
            const SizedBox(width: 10),
          ],
          if (group.expenseCents > 0) ...[
            Text('支 ', style: theme.textTheme.bodySmall),
            MoneyText(-group.expenseCents, size: MoneySize.small),
          ],
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.state, required this.onRetry});

  final TxListState state;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (state.moreError != null) {
      return InlineError(
        message: describeError(state.moreError!),
        onRetry: onRetry,
        padding: const EdgeInsets.all(LedgerLayout.pagePadding),
      );
    }
    if (state.loadingMore) {
      return const Padding(
        padding: EdgeInsets.all(LedgerLayout.pagePadding),
        child: SkeletonList(rows: 2, padding: EdgeInsets.zero),
      );
    }
    if (state.hasMore) return const SizedBox(height: 48);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: LedgerLayout.groupGap),
      child: Center(child: Text('没有更多了', style: theme.textTheme.bodySmall)),
    );
  }
}
