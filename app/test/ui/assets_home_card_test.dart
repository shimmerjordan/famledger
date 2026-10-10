import 'package:famledger/app/providers.dart';
import 'package:famledger/app/theme.dart';
import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/data/local/secure_store.dart';
import 'package:famledger/data/models/models.dart';
import 'package:famledger/data/repos/ledger_repo.dart';
import 'package:famledger/data/repos/session_repo.dart';
import 'package:famledger/ui/assets/asset_providers.dart';
import 'package:famledger/ui/assets/asset_routes.dart';
import 'package:famledger/ui/home/home_page.dart';
import 'package:famledger/ui/transactions/tx_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'assets_harness.dart';

class FakeLedger extends LedgerController {
  FakeLedger(this.data);

  final LedgerData data;

  @override
  Future<LedgerData> build() async => data;

  @override
  Future<void> sync({bool full = false}) async {}
}

class FakeStats extends StatsController {
  FakeStats(this.overview, {this.fail = false});

  final StatsOverview overview;
  final bool fail;

  @override
  Future<StatsOverview> build(String month) async {
    if (fail) throw Exception('服务器开小差了');
    return overview;
  }

  @override
  Future<void> refresh() async {}
}

/// 净资产 1.5 万：现金流 1 万、理财补差、债务净额 +3000（别人欠 5000、欠别人 2000）。
const StatsOverview baseOverview = StatsOverview(
  netWorthCents: 1500000,
  assetsCents: 1700000,
  liabilitiesCents: 200000,
  month: MonthStats(expenseCents: 0),
  cashCents: 1000000,
  investAccountsCents: 0,
  serverInvestNetCents: 200000,
  debts: DebtSummary(
    receivableCents: 500000,
    payableCents: 200000,
    countedReceivableCents: 500000,
    countedPayableCents: 200000,
    count: 2,
  ),
);

final List<Debt> someDebts = [
  const Debt(id: 'd1', accountId: 'da1', direction: Debt.lend, counterparty: '张三', amountCents: 500000, startedOn: '2026-09-01'),
  const Debt(id: 'd2', accountId: 'da2', direction: Debt.borrow, counterparty: '李四', amountCents: 200000, startedOn: '2026-09-01'),
];

final List<Asset> someAssets = [
  Asset.fromJson(assetJson('a1', expectedDays: 1095)),
  Asset.fromJson(
    assetJson(
      'a2',
      name: '洗衣机',
      price: 320000,
      purchasedOn: '2026-01-01',
      status: 'idle',
    ),
  ),
];

final List<Holding> someHoldings = [
  Holding.fromJson(holdingJson('h1')),
  Holding.fromJson(
    holdingJson(
      'h3',
      name: '贵州茅台',
      code: '600519',
      market: 'sh',
      qty: 1000000,
      cost: 15000000,
      price: 15000000,
      prev: 14900000,
    ),
  ),
];

Future<void> pumpHome(
  WidgetTester tester,
  LedgerData data, {
  Size size = const Size(400, 900),
  StatsOverview overview = baseOverview,
  bool statsFail = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    initialLocation: '/home',
    routes: [
      GoRoute(path: '/home', builder: (context, state) => const HomePage()),
      assetsTabRoute(),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        localStoreProvider.overrideWithValue(MemoryLocalStore()),
        secureStoreProvider.overrideWithValue(MemorySecureStore()),
        sessionRepoProvider.overrideWithValue(
          SessionRepo(secure: MemorySecureStore()),
        ),
        ledgerProvider.overrideWith(() => FakeLedger(data)),
        statsProvider.overrideWith(() => FakeStats(overview, fail: statsFail)),
        pendingTxProvider.overrideWith((ref) async => const []),
        recentTxProvider.overrideWith((ref) async => const []),
        assetClockProvider.overrideWithValue(() => testNow),
      ],
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light),
        routerConfig: router,
      ),
    ),
  );
  await settle(tester);
}

void main() {
  Finder inTile(String key, Finder f) => find.descendant(of: find.byKey(ValueKey(key)), matching: f);

  testWidgets('净资产一行 + 五格：现金流、理财、债务、物品、会员权益，各写一句', (tester) async {
    await pumpHome(tester, LedgerData(assets: someAssets, holdings: someHoldings, debts: someDebts));

    expect(find.byKey(const ValueKey('assets-card')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('home-net-worth')), matching: find.text('¥15,000.00')), findsOneWidget);
    expect(inTile('home-asset-cash', find.text('¥10,000.00')), findsOneWidget);
    expect(inTile('home-asset-cash', find.text('可支配 ¥10,000.00')), findsOneWidget);
    // 理财：白酒 ¥1,200（成本 1000）+ 茅台 ¥150,000（平价）；基金、股票两类。
    expect(inTile('home-asset-invest', find.text('¥151,200.00')), findsOneWidget);
    expect(inTile('home-asset-invest', find.text('浮动 +¥200.00 · 2 类')), findsOneWidget);
    expect(inTile('home-asset-debts', find.text('+¥3,000.00')), findsOneWidget);
    expect(inTile('home-asset-debts', find.text('别人欠 ¥5,000.00 · 欠别人 ¥2,000.00')), findsOneWidget);
    // 物品：估值 iPhone ¥5,895.88 + 洗衣机（闲置也算）¥2,596.82；每天 ¥272.86。
    expect(inTile('home-asset-items', find.text('¥8,492.70')), findsOneWidget);
    expect(inTile('home-asset-items', find.text('每天 ¥272.86')), findsOneWidget);
    expect(inTile('home-asset-perks', find.text('还没记')), findsOneWidget);
  });

  testWidgets('什么都没记：净资产、现金流照写，其余几格「还没记」并说能记什么；点理财进理财段', (tester) async {
    await pumpHome(tester, const LedgerData(), overview: const StatsOverview(
      netWorthCents: 1000000,
      assetsCents: 1000000,
      liabilitiesCents: 0,
      month: MonthStats(),
      cashCents: 1000000,
    ));
    for (final key in ['home-asset-invest', 'home-asset-debts', 'home-asset-items', 'home-asset-perks']) {
      expect(inTile(key, find.text('还没记')), findsOneWidget, reason: key);
    }
    expect(inTile('home-asset-invest', find.text('基金、定期、活期……')), findsOneWidget);
    expect(inTile('home-asset-debts', find.text('借出、借入、人情')), findsOneWidget);
    await tapVisible(tester, find.byKey(const ValueKey('home-asset-invest')));
    expect(find.text('还没有理财'), findsOneWidget);
  });

  testWidgets('总览取不到：净资产、现金流写一道杠，不一直闪骨架', (tester) async {
    await pumpHome(tester, LedgerData(assets: someAssets), statsFail: true);
    expect(inTile('home-net-worth', find.text('—')), findsOneWidget);
    expect(inTile('home-asset-cash', find.text('—')), findsOneWidget);
    expect(inTile('home-asset-items', find.text('¥8,492.70')), findsOneWidget, reason: '物品是本地算的，照样有');
  });

  testWidgets('物品全卖掉了：物品那格说都退役或卖掉了', (tester) async {
    await pumpHome(tester, LedgerData(assets: [Asset.fromJson(assetJson('a1', status: 'sold', endedOn: '2026-09-01', saleCents: 100000))]));
    expect(inTile('home-asset-items', find.text('都退役或卖掉了')), findsOneWidget);
  });

  testWidgets('不用 Card：卡片只留给基金横滑和待确认（DESIGN.md）', (tester) async {
    await pumpHome(tester, LedgerData(assets: someAssets, holdings: someHoldings));
    expect(find.descendant(of: find.byKey(const ValueKey('assets-card')), matching: find.byType(Card)), findsNothing);
  });

  testWidgets('宽屏：资产概览在主栏本月合计下面，五格一行', (tester) async {
    await pumpHome(tester, LedgerData(assets: someAssets, holdings: someHoldings, debts: someDebts), size: const Size(1400, 1000));
    final cash = tester.getTopLeft(find.byKey(const ValueKey('home-asset-cash')));
    final perks = tester.getTopLeft(find.byKey(const ValueKey('home-asset-perks')));
    expect(perks.dy, cash.dy, reason: '一行排完');
    expect(cash.dx, lessThan(800), reason: '在主栏，不在右栏');
  });

  group('三种宽度都不溢出', () {
    for (final size in kWidths) {
      testWidgets('@${size.width.toInt()}', (tester) async {
        await pumpHome(tester, LedgerData(assets: someAssets, holdings: someHoldings, debts: someDebts), size: size);
        expect(tester.takeException(), isNull);
      });

      testWidgets('什么都没记 @${size.width.toInt()}', (tester) async {
        await pumpHome(tester, const LedgerData(), size: size);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
