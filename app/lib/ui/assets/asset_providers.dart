import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/repos/assets_repo.dart';
import '../../data/repos/holdings_repo.dart';
import '../transactions/tx_providers.dart';

final assetsRepoProvider = Provider<AssetsRepo>(
  (ref) => AssetsRepo(
    api: ref.watch(apiProvider),
    ledger: ref.watch(ledgerRepoProvider),
  ),
);

final holdingsRepoProvider = Provider<HoldingsRepo>(
  (ref) => HoldingsRepo(
    api: ref.watch(apiProvider),
    ledger: ref.watch(ledgerRepoProvider),
    store: ref.watch(localStoreProvider),
  ),
);

/// 天数、日均、价格过期都跟「现在」有关；测试里换成固定时刻。
final assetClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// 这次打开 App 以来最近一次刷新行情的结果，投资页顶上说「几点更新、几只失败」。
final quoteRefreshProvider = StateProvider<QuoteRefresh?>((ref) => null);

/// 「同时记一笔」会新建流水：统计、最近流水、账单列表都得重取。
void refreshMoneyViews(WidgetRef ref) {
  ref.invalidate(statsProvider);
  ref.invalidate(recentTxProvider);
  ref.invalidate(txListProvider);
}
