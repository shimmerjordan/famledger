import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../widgets/widgets.dart';
import 'tx_filter_sheet.dart';
import 'tx_providers.dart';
import 'tx_tile.dart';

/// 账单：按日分组的无限滚动列表 + 搜索 + 筛选。
class TransactionsPage extends ConsumerStatefulWidget {
  const TransactionsPage({super.key});

  @override
  ConsumerState<TransactionsPage> createState() => _TransactionsPageState();
}

class _TransactionsPageState extends ConsumerState<TransactionsPage> {
  final TextEditingController _search = TextEditingController();
  final ScrollController _scroll = ScrollController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _search.text = ref.read(txFilterProvider).q ?? '';
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.dispose();
    _search.dispose();
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

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(txListProvider);
    final ledger = ref.watch(ledgerProvider).valueOrNull;
    final filter = ref.watch(txFilterProvider);
    final activeCount = filter.activeCount - (filter.q?.isEmpty ?? true ? 0 : 1);
    final hasRange = filter.from != null || filter.to != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('账单'),
        actions: [
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
              onChanged: _onSearchChanged,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: '搜商户或备注',
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
            child: list.isReloading
                ? const LinearProgressIndicator(minHeight: 2)
                : null,
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => ref.read(txListProvider.notifier).refresh(),
              child: AsyncValueView<TxListState>(
                value: list,
                loading: const SkeletonList(rows: 8),
                onRetry: () => ref.read(txListProvider.notifier).refresh(),
                errorPadding: const EdgeInsets.all(LedgerLayout.pagePadding),
                data: (state) => _List(
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
          return _Footer(
            state: state,
            onRetry: onRetryMore,
          );
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
            MoneyText(
              group.incomeCents,
              size: MoneySize.small,
              signed: true,
            ),
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
      child: Center(
        child: Text('没有更多了', style: theme.textTheme.bodySmall),
      ),
    );
  }
}
