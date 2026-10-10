import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/repos/assets_repo.dart';
import '../../data/repos/debts_repo.dart';
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

final debtsRepoProvider = Provider<DebtsRepo>(
  (ref) => DebtsRepo(
    api: ref.watch(apiProvider),
    ledger: ref.watch(ledgerRepoProvider),
  ),
);

/// 宽屏「债务」段右栏选中的那一笔。
final selectedDebtProvider = StateProvider<String?>((ref) => null);

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

/// 物品、投资页下拉刷新（同步成功后）顺带刷资产页顶上的净资产：总览重取，家庭设置也重拉 ——
/// 「实物计入净资产」的总开关不走 /changes，别的设备改了只能靠这一下。同步拉到新数据时总览
/// 本来就会作废（NetWorthStrip 盯着 seq），和这里落在同一帧，只取一遍。
void refreshNetWorth(WidgetRef ref) {
  ref.invalidate(statsProvider);
  ref.invalidate(settingsProvider);
}

/// 宽屏（≥ 840）右栏正在看的那一条；null = 默认看列表里第一条（各段画出来后会把它写回这里）。
/// 会员权益的在 perk_providers.dart（selectedMembershipProvider）。
final selectedFundProvider = StateProvider<String?>((ref) => null);
final selectedAssetProvider = StateProvider<String?>((ref) => null);
final selectedHoldingProvider = StateProvider<String?>((ref) => null);
