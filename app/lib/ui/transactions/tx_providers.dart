import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/models/models.dart';
import '../../data/repos/transactions_repo.dart';

/// 首页「待确认」：自动记账抓到但还没人点头的几笔。
final pendingTxProvider = FutureProvider.autoDispose<List<Transaction>>((
  ref,
) async {
  final page = await ref
      .watch(transactionsRepoProvider)
      .list(const TxFilter(status: 'pending', limit: 5));
  return page.items;
});

/// 首页「最近流水」：服务端最近 10 条 + 还压在 outbox 里没发出去的本地条目。
final recentTxProvider = FutureProvider.autoDispose<List<Transaction>>((
  ref,
) async {
  final repo = ref.watch(transactionsRepoProvider);
  final local = await repo.pendingLocal();
  final page = await repo.list(const TxFilter(limit: 10));
  if (local.isEmpty) return page.items;
  final ids = {for (final tx in page.items) tx.clientId};
  return [
    ...local.where((tx) => !ids.contains(tx.clientId)),
    ...page.items,
  ]..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
});

/// 单条流水（详情页）。
final txDetailProvider = FutureProvider.autoDispose
    .family<Transaction, String>(
      (ref, id) => ref.watch(transactionsRepoProvider).get(id),
    );

/// 账单页的一页页流水：首屏 + 游标翻页 + 当前筛选条件。
class TxListState {
  const TxListState({
    this.items = const [],
    this.cursor,
    this.loadingMore = false,
    this.moreError,
  });

  final List<Transaction> items;

  /// 下一页游标；为空表示到底了。
  final String? cursor;

  /// 正在加载下一页（首屏加载看外层的 `AsyncValue`）。
  final bool loadingMore;

  /// 翻页失败：首屏还在，行内提示重试就行。
  final Object? moreError;

  bool get hasMore => cursor != null && cursor!.isNotEmpty;

  TxListState copyWith({
    List<Transaction>? items,
    String? cursor,
    bool? loadingMore,
    Object? moreError,
    bool clearCursor = false,
    bool clearError = false,
  }) => TxListState(
    items: items ?? this.items,
    cursor: clearCursor ? null : (cursor ?? this.cursor),
    loadingMore: loadingMore ?? this.loadingMore,
    moreError: clearError ? null : (moreError ?? this.moreError),
  );
}

/// 账单页当前的筛选条件。**独立于列表存放**：记完一笔 / 改完一笔 / 拨完款都会
/// `ref.invalidate(txListProvider)`，那只该让列表重拉，不该顺手把用户挑的条件
/// 清掉（搜索框和筛选角标还显示着旧条件，列表却已经是全部了）。
final txFilterProvider = StateProvider<TxFilter>(
  (ref) => const TxFilter(limit: TxListController.pageSize),
);

final txListProvider = AsyncNotifierProvider<TxListController, TxListState>(
  TxListController.new,
);

class TxListController extends AsyncNotifier<TxListState> {
  /// 一页 30 条：够填满一屏还能预读一点，又不至于让弱网等太久。
  static const int pageSize = 30;

  TxFilter get filter => ref.read(txFilterProvider);

  @override
  Future<TxListState> build() {
    // watch：条件一变就自动重拉第一页；invalidate 列表时条件原样还在。
    ref.watch(txFilterProvider);
    return _firstPage();
  }

  /// 换筛选条件。改的是 [txFilterProvider]，[build] 会自己跑一遍。
  Future<void> setFilter(TxFilter filter) async {
    final next = filter.copyWith(limit: pageSize);
    ref.read(txFilterProvider.notifier).state = next;
  }

  /// 下拉刷新：保留旧内容，失败了才换成错误。
  Future<void> refresh() async {
    state = const AsyncLoading<TxListState>().copyWithPrevious(state);
    state = await AsyncValue.guard(_firstPage);
  }

  /// 滚到底再拿一页。失败只记在 [TxListState.moreError] 里，列表不塌。
  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || !current.hasMore || current.loadingMore) return;
    state = AsyncData(current.copyWith(loadingMore: true, clearError: true));
    try {
      final page = await ref
          .read(transactionsRepoProvider)
          .list(filter, cursor: current.cursor);
      state = AsyncData(
        TxListState(
          items: [...current.items, ...page.items],
          cursor: page.nextCursor,
        ),
      );
    } catch (error) {
      state = AsyncData(current.copyWith(loadingMore: false, moreError: error));
    }
  }

  Future<TxListState> _firstPage() async {
    final page = await ref.read(transactionsRepoProvider).list(filter);
    return TxListState(items: page.items, cursor: page.nextCursor);
  }
}

/// 一天的流水 + 当天合计（只统计已加载的那些，翻页边界上会先少后补）。
class TxDayGroup {
  const TxDayGroup({
    required this.date,
    required this.items,
    required this.expenseCents,
    required this.incomeCents,
  });

  final DateTime date;
  final List<Transaction> items;
  final int expenseCents;
  final int incomeCents;
}

/// 按自然日切段，顺序沿用传入的顺序（服务端已按时间倒序）。
List<TxDayGroup> groupByDay(List<Transaction> items) {
  final groups = <String, List<Transaction>>{};
  final order = <String>[];
  for (final tx in items) {
    final key = tx.dayKey;
    final day = groups[key];
    if (day == null) {
      groups[key] = [tx];
      order.add(key);
    } else {
      day.add(tx);
    }
  }
  return [
    for (final key in order)
      TxDayGroup(
        date: groups[key]!.first.occurredAt,
        items: groups[key]!,
        expenseCents: groups[key]!
            .where((tx) => tx.isExpense && tx.status != 'void')
            .fold(0, (sum, tx) => sum + tx.amountCents),
        incomeCents: groups[key]!
            .where((tx) => tx.isIncome && tx.status != 'void')
            .fold(0, (sum, tx) => sum + tx.amountCents),
      ),
  ];
}

/// 跑一个「不抛异常、但可能悄悄落进 outbox」的写操作（confirm / delete），
/// 用队列长度的变化判断这一次到底有没有真的发出去。
///
/// `TransactionsRepo.confirm/delete` 返回的是 `void`，断网时只是入队 —— 不这么
/// 看一眼，UI 就会理直气壮地说「已确认」，而服务器上什么都没发生。
Future<bool> wentToOutbox(
  TransactionsRepo repo,
  Future<void> Function() action,
) async {
  final before = await repo.pendingCount();
  await action();
  return await repo.pendingCount() > before;
}
