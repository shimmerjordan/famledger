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
  @override
  Future<StatsOverview> build(String month) async => const StatsOverview(
    netWorthCents: 0,
    assetsCents: 0,
    liabilitiesCents: 0,
    month: MonthStats(expenseCents: 0),
  );

  @override
  Future<void> refresh() async {}
}

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
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    initialLocation: '/home',
    routes: [
      GoRoute(path: '/home', builder: (context, state) => const HomePage()),
      assetsRoute(),
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
        statsProvider.overrideWith(FakeStats.new),
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
  testWidgets('物品每天花多少 + 投资市值与今日涨跌', (tester) async {
    await pumpHome(
      tester,
      LedgerData(assets: someAssets, holdings: someHoldings),
    );

    expect(find.byKey(const ValueKey('assets-card')), findsOneWidget);
    expect(find.text('物品每天'), findsOneWidget);
    expect(find.text('¥272.86/天', findRichText: true), findsOneWidget);
    // 副标题是估值合计：iPhone ¥5,895.88 + 洗衣机（数码，闲置也算）¥2,596.82。
    expect(find.text('估值 ¥8,492.70'), findsOneWidget);
    expect(find.text('投资市值'), findsOneWidget);
    expect(find.text('¥151,200.00'), findsOneWidget);
    expect(find.text('+¥1,100.00'), findsOneWidget);
    expect(find.byKey(const ValueKey('assets-entry')), findsNothing);
  });

  testWidgets('两边都空：只留一行「记录资产」，点进去是资产页', (tester) async {
    await pumpHome(tester, const LedgerData());

    expect(find.byKey(const ValueKey('assets-card')), findsNothing);
    expect(find.text('记录资产'), findsOneWidget);
    final entry = tester.getSize(find.byKey(const ValueKey('assets-entry')));
    expect(entry.height, lessThan(90));

    await tester.ensureVisible(find.text('记录资产'));
    await tester.tap(find.text('记录资产'));
    await settle(tester);
    expect(find.text('还没记物品'), findsOneWidget);
  });

  testWidgets('只有持仓：物品那半边给入口', (tester) async {
    await pumpHome(tester, LedgerData(holdings: someHoldings));

    expect(find.text('还没记'), findsOneWidget);
    expect(find.text('点这里记一件'), findsOneWidget);
    expect(find.text('¥151,200.00'), findsOneWidget);
  });

  testWidgets('副标题是估值合计：闲置的也算进去，不再数几件在用', (tester) async {
    await pumpHome(tester, LedgerData(assets: [someAssets[1]]));

    expect(find.text('估值 ¥2,596.82'), findsOneWidget);
    expect(find.textContaining('在用'), findsNothing);
  });

  testWidgets('物品全退役了、有持仓：物品那半边说都退役了，不再引导「记一件」', (tester) async {
    await pumpHome(
      tester,
      LedgerData(
        assets: [
          Asset.fromJson(
            assetJson('a1', status: 'retired', endedOn: '2026-09-20'),
          ),
        ],
        holdings: someHoldings,
      ),
    );

    expect(find.text('还没记'), findsNothing);
    expect(find.text('点这里记一件'), findsNothing);
    expect(find.text('都退役或卖掉了'), findsOneWidget);
    expect(find.text('¥151,200.00'), findsOneWidget);
  });

  testWidgets('物品全卖掉了、没有持仓：照样是资产块，不退化成「记录资产」入口', (tester) async {
    await pumpHome(
      tester,
      LedgerData(
        assets: [
          Asset.fromJson(
            assetJson('a1', status: 'sold', endedOn: '2026-09-20', saleCents: 100000),
          ),
        ],
      ),
    );

    expect(find.text('记录资产'), findsNothing);
    expect(find.byKey(const ValueKey('assets-card')), findsOneWidget);
    expect(find.text('都退役或卖掉了'), findsOneWidget);
    expect(find.text('点这里添加'), findsOneWidget);
  });

  testWidgets('不用 Card：卡片只留给基金横滑和待确认（DESIGN.md）', (tester) async {
    await pumpHome(
      tester,
      LedgerData(assets: someAssets, holdings: someHoldings),
    );

    expect(find.byKey(const ValueKey('assets-card')), findsOneWidget);
    expect(find.byType(Card), findsNothing);
  });

  testWidgets('持仓全清了：说「都清仓了」，不显示今日涨跌', (tester) async {
    await pumpHome(
      tester,
      LedgerData(
        assets: someAssets,
        holdings: [Holding.fromJson(holdingJson('h9', qty: 0, cost: 0))],
      ),
    );

    expect(find.text('都清仓了'), findsOneWidget);
    expect(find.text('今日 '), findsNothing);
  });

  testWidgets('持仓都还没价格：写「还没有价格」而不是 ¥0.00，也不摆今日涨跌', (tester) async {
    await pumpHome(
      tester,
      LedgerData(
        holdings: [
          Holding.fromJson(
            holdingJson('h9', price: null, prev: null, source: 'manual', cost: 1000000),
          ),
        ],
      ),
    );

    expect(find.text('还没有价格'), findsOneWidget);
    expect(find.text('1 只还没有价格'), findsOneWidget);
    // 首页别处（本月合计）的 ¥0.00 不算，只看资产这一块。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('assets-card')),
        matching: find.text('¥0.00'),
      ),
      findsNothing,
    );
    expect(find.text('今日 '), findsNothing);
  });

  testWidgets('一部分没价格：市值照写有价的那些，并说另有几只没算进来', (tester) async {
    await pumpHome(
      tester,
      LedgerData(
        holdings: [
          ...someHoldings,
          Holding.fromJson(
            holdingJson('h9', price: null, prev: null, source: 'manual', cost: 1000000),
          ),
        ],
      ),
    );

    expect(find.text('¥151,200.00'), findsOneWidget);
    expect(find.text('+¥1,100.00'), findsOneWidget);
    expect(find.text('另有 1 只没价格，没算进来'), findsOneWidget);
  });

  group('三种宽度都不溢出', () {
    for (final size in kWidths) {
      testWidgets('@${size.width.toInt()}', (tester) async {
        await pumpHome(
          tester,
          LedgerData(assets: someAssets, holdings: someHoldings),
          size: size,
        );
        await tester.ensureVisible(find.byKey(const ValueKey('assets-card')));
        await tester.pump();
        expect(find.text('¥272.86/天', findRichText: true), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('有没价格的持仓 @${size.width.toInt()}', (tester) async {
        await pumpHome(
          tester,
          LedgerData(
            assets: someAssets,
            holdings: [
              ...someHoldings,
              Holding.fromJson(holdingJson('h9', price: null, prev: null)),
            ],
          ),
          size: size,
        );
        await tester.ensureVisible(find.byKey(const ValueKey('assets-card')));
        await tester.pump();
        expect(find.byKey(const ValueKey('assets-invest-unpriced')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('空入口 @${size.width.toInt()}', (tester) async {
        await pumpHome(tester, const LedgerData(), size: size);
        expect(find.text('记录资产'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
