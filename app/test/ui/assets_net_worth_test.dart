import 'package:famledger/app/providers.dart';
import 'package:famledger/data/models/models.dart';
import 'package:famledger/ui/assets/net_worth_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assets_harness.dart';

/// 账户 1 万 − 微信欠 200 = 9800；投资补 520（没挂账户，整份市值）；实物估值 8819.99，
/// 其中按类别该计入 5895.88。
AssetsBackend worthBackend({List<Map<String, dynamic>> assets = const []}) =>
    AssetsBackend(assets: assets)
      ..accountBalances = {'bank': 1000000, 'wx': -20000}
      ..investNetCents = 52000
      ..investMarketCents = 52000
      ..physical = {'valueCents': 881999, 'includedCents': 589588, 'count': 2};

Future<void> expand(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('net-worth-strip')));
  await settle(tester);
}

SwitchListTile switchTile(WidgetTester tester) =>
    tester.widget<SwitchListTile>(find.byKey(const ValueKey('net-worth-switch')));

Finder get _breakdown => find.byKey(const ValueKey('net-worth-breakdown'));

String breakdownText(WidgetTester tester) => tester.widget<Text>(_breakdown).data!;

void main() {
  group('资产页的净资产总览', () {
    testWidgets('折叠：净资产 + 一行分项（标签说清口径）；点开是现金流、可支配、投资、实物各一行带说明，和开关', (tester) async {
      await pumpAssetsAt(tester, bootAssets(worthBackend()), '/assets?tab=items');

      expect(find.text('净资产'), findsOneWidget);
      expect(find.text('¥16,215.88'), findsOneWidget);
      // 没有目标/储备基金攒着钱：可支配就是现金流，折叠行不重复写。
      expect(breakdownText(tester), '现金流 ¥9,800.00 · 理财 ¥520.00 · 实物计入 ¥5,895.88');
      expect(find.byKey(const ValueKey('net-worth-details')), findsNothing);
      expect(
        tester.getBottomLeft(find.byKey(const ValueKey('net-worth-strip'))).dy,
        lessThanOrEqualTo(tester.getTopLeft(find.byType(TabBar)).dy),
        reason: 'Tab 在总览下面',
      );

      await expand(tester);
      expect(find.byKey(const ValueKey('net-worth-details')), findsOneWidget);
      expect(find.text('现金流'), findsOneWidget);
      expect(find.text('现金、银行卡、支付宝……已减信用卡欠款'), findsOneWidget);
      expect(find.text('可支配现金流'), findsOneWidget);
      expect(find.text('目标、储备基金没攒着钱，和现金流一样'), findsOneWidget);
      expect(find.text('¥9,800.00'), findsNWidgets(2), reason: '现金流、可支配各一个');
      expect(find.text('理财'), findsWidgets);
      expect(find.text('¥520.00'), findsOneWidget);
      expect(find.text('各品类估值合计 ¥520.00'), findsOneWidget, reason: '没挂账户：估值就是这个数');
      expect(find.text('实物计入'), findsOneWidget);
      expect(find.text('¥5,895.88'), findsOneWidget);
      expect(find.text('估值 ¥8,819.99，按类别计入'), findsOneWidget);
      expect(switchTile(tester).value, isTrue);
    });

    testWidgets('目标/储备基金攒着钱：可支配 = 现金流 − 专款，折叠行、展开的说明都写出来', (tester) async {
      final backend = worthBackend()
        ..extraFunds = [
          {'id': 'f3', 'name': '应急', 'kind': 'reserve', 'sortOrder': 2},
          {'id': 'f4', 'name': '旅行', 'kind': 'goal', 'sortOrder': 3},
        ]
        // 家庭公共 2000 是日常开销、不扣；应急 3000 扣；旅行超支 −500 的钱早花出去了，不再减。
        ..fundBalances = {'f1': 200000, 'f3': 300000, 'f4': -50000};
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=items');

      expect(
        breakdownText(tester),
        '现金流 ¥9,800.00 · 可支配 ¥6,800.00 · 理财 ¥520.00 · 实物计入 ¥5,895.88',
      );
      await expand(tester);
      expect(find.text('¥6,800.00'), findsOneWidget);
      expect(find.text('已扣目标、储备基金攒着的 ¥3,000.00'), findsOneWidget);
    });

    testWidgets('宽屏（≥ 840）：总览和下面的四段一样宽，分项排成一行格子带口径，不用展开；展开只剩动作', (tester) async {
      await pumpAssetsAt(
        tester,
        bootAssets(
          worthBackend()
            ..investMarketCents = 1512000
            ..accountBalances['inv'] = 1460000,
          session: await sessionAs('admin'),
        ),
        '/assets?tab=items',
        size: const Size(1400, 900),
      );

      for (final key in ['total', 'cash', 'disposable', 'invest', 'physical']) {
        expect(find.byKey(ValueKey('net-worth-figure-$key')), findsOneWidget, reason: key);
      }
      expect(find.byKey(const ValueKey('net-worth-breakdown')), findsNothing, reason: '格子代替了那一行小字');
      expect(find.text('现金流 + 理财 + 实物计入'), findsOneWidget);
      expect(find.text('现金、银行卡、支付宝……已减信用卡欠款'), findsOneWidget);
      expect(find.text('各品类估值合计 ¥15,120.00'), findsOneWidget);
      expect(find.text('估值 ¥8,819.99，按类别计入'), findsOneWidget);
      expect(find.byKey(const ValueKey('net-worth-details')), findsNothing);
      // 整行：第一格和 Tab 一样靠左，箭头顶在右边，不是收窄居中。
      final strip = find.byKey(const ValueKey('net-worth-strip'));
      final tabs = find.byType(TabBar);
      expect(tester.getTopLeft(strip).dx, tester.getTopLeft(tabs).dx);
      expect(tester.getTopRight(strip).dx, tester.getTopRight(tabs).dx);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('net-worth-figure-total'))).dx,
        lessThan(tester.getTopLeft(tabs).dx + 24),
      );
      expect(
        tester.getTopRight(find.byIcon(Icons.expand_more)).dx,
        greaterThan(tester.getTopRight(tabs).dx - 40),
      );

      await expand(tester);
      expect(find.byKey(const ValueKey('net-worth-details')), findsOneWidget);
      expect(find.byKey(const ValueKey('net-worth-accounts')), findsOneWidget);
      // 宽屏的开关是行内的：说明紧挨着开关，整块顶在右边；「管理账户」顶在左边（两端对齐）。
      final toggle = find.byKey(const ValueKey('net-worth-switch'));
      expect(tester.widget<Switch>(toggle).value, isTrue);
      expect(tester.getTopRight(toggle).dx, greaterThan(tester.getTopRight(tabs).dx - 40));
      expect(
        tester.getTopRight(find.text('实物计入净资产')).dx,
        greaterThan(tester.getTopLeft(toggle).dx - 480),
        reason: '说明和开关之间不隔半个屏',
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('net-worth-accounts'))).dx,
        lessThan(tester.getTopLeft(tabs).dx + 24),
      );
      expect(find.text('现金流'), findsOneWidget, reason: '格子还在，没有再列一遍');
      // 点说明文字也能翻开关。
      await tester.tap(find.text('实物计入净资产'));
      await tester.pump();
      expect(tester.widget<Switch>(toggle).value, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('持仓挂了账户：成本在投资账户里，理财 = 投资账户 + 浮盈 = 估值；现金流不含投资账户', (tester) async {
      // 市值 15120、成本 14600 早以转账进了证券户（账户余额里），净资产只补浮盈 520。
      final backend = worthBackend()
        ..investMarketCents = 1512000
        ..accountBalances['inv'] = 1460000;
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=items');

      expect(breakdownText(tester), '现金流 ¥9,800.00 · 理财 ¥15,120.00 · 实物计入 ¥5,895.88');
      expect(find.text('¥30,815.88'), findsOneWidget, reason: '9800 + 15120 + 5895.88');
      await expand(tester);
      expect(find.text('各品类估值合计 ¥15,120.00'), findsOneWidget);
    });

    testWidgets('老服务端没有分项：现金流是全部账户、理财只剩补差，照样能看', (tester) async {
      final backend = worthBackend()..legacyOverview = true;
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=items');
      expect(breakdownText(tester), '现金流 ¥9,800.00 · 理财 ¥520.00 · 实物计入 ¥5,895.88');
      await expand(tester);
      expect(find.text('账户余额合计，已减信用卡欠款'), findsOneWidget);
      expect(find.text('账户余额以外的那部分'), findsOneWidget);
    });

    testWidgets('管理员关掉「实物计入净资产」：开关先翻、等总览回来才放开；净资产和分项跟着变', (tester) async {
      final backend = worthBackend();
      await pumpAssetsAt(tester, bootAssets(backend, session: await sessionAs('admin')), '/assets?tab=items');
      await expand(tester);

      backend.delayNext['GET /stats/overview'] = const Duration(seconds: 2);
      final toggle = find.byKey(const ValueKey('net-worth-switch'));
      await tester.ensureVisible(toggle);
      await tester.pump();
      await tester.tap(toggle);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // PATCH 回来了，总览还在路上：开关已经是新值、先不让再点，数字还是旧的。
      expect(backend.lastBody('PATCH', '/settings'), {
        'assets': {'netWorthIncludesPhysical': false},
      });
      expect(switchTile(tester).value, isFalse);
      expect(switchTile(tester).onChanged, isNull);
      expect(find.text('¥16,215.88'), findsOneWidget);

      await tester.pump(const Duration(seconds: 2));
      await settle(tester);
      expect(find.text('¥10,320.00'), findsOneWidget);
      expect(breakdownText(tester), '现金流 ¥9,800.00 · 理财 ¥520.00 · 不含实物');
      expect(find.text('实物估值'), findsOneWidget);
      expect(find.text('不计入净资产，打开开关后计入 ¥5,895.88'), findsOneWidget);
      expect(switchTile(tester).value, isFalse);
      expect(switchTile(tester).onChanged, isNotNull);
    });

    testWidgets('成员：开关是灰的，写明只有管理员能改，不发请求', (tester) async {
      final backend = worthBackend();
      await pumpAssetsAt(tester, bootAssets(backend, session: await sessionAs('member')), '/assets?tab=items');
      await expand(tester);

      expect(switchTile(tester).onChanged, isNull);
      expect(find.text('只有管理员能改这个开关。'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('net-worth-switch')));
      await settle(tester);
      expect(backend.requests('PATCH', '/settings'), isEmpty);
    });

    testWidgets('改开关失败：说出原因，开关和数字都不动', (tester) async {
      final backend = worthBackend()
        ..failNext['PATCH /settings'] = (500, 'boom', '服务器开小差了');
      await pumpAssetsAt(tester, bootAssets(backend, session: await sessionAs('admin')), '/assets?tab=items');
      await expand(tester);

      await tapVisible(tester, find.byKey(const ValueKey('net-worth-switch')));
      expect(find.text('服务器开小差了'), findsOneWidget);
      expect(find.text('¥16,215.88'), findsOneWidget);
      expect(switchTile(tester).value, isTrue);
      expect(switchTile(tester).onChanged, isNotNull);
    });

    testWidgets('老服务端没给 physical：分项不写实物，也没有开关', (tester) async {
      final backend = worthBackend()..physical = null;
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=items');

      expect(find.text('¥10,320.00'), findsOneWidget);
      expect(breakdownText(tester), '现金流 ¥9,800.00 · 理财 ¥520.00');
      await expand(tester);
      expect(find.byKey(const ValueKey('net-worth-switch')), findsNothing);
    });

    testWidgets('ledger seq 变了（同步拉到新数据）就重取', (tester) async {
      final backend = worthBackend();
      final container = bootAssets(backend);
      await pumpAssetsAt(tester, container, '/assets?tab=items');
      expect(find.text('¥16,215.88'), findsOneWidget);

      backend.physical = {'valueCents': 900000, 'includedCents': 600000, 'count': 2};
      final before = backend.requests('GET', '/stats/overview').length;
      // 不经下拉刷新：别处（保存物品后）触发的同步也得让总览跟上。
      await container.read(ledgerProvider.notifier).sync();
      await settle(tester);

      expect(backend.requests('GET', '/stats/overview').length, greaterThan(before));
      expect(find.text('¥16,320.00'), findsOneWidget);
    });

    testWidgets('下拉刷新：没拉到新数据也重取；别的设备关了总开关，总览和详情页都跟上', (tester) async {
      final backend = worthBackend(assets: [assetJson('a1')]);
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=items');
      await tapVisible(tester, find.byKey(const ValueKey('asset-a1')));
      expect(find.text('计入（跟随类别）'), findsOneWidget);
      await tester.pageBack();
      await settle(tester);

      backend
        ..frozenSeq = true
        ..settings['assets'] = {'netWorthIncludesPhysical': false};
      final before = backend.requests('GET', '/stats/overview').length;
      await tester.fling(find.byType(ListView).last, const Offset(0, 400), 1000);
      await settle(tester);

      expect(backend.requests('GET', '/stats/overview').length, greaterThan(before));
      expect(find.text('¥10,320.00'), findsOneWidget);
      expect(breakdownText(tester), endsWith('不含实物'));
      await tapVisible(tester, find.byKey(const ValueKey('asset-a1')));
      expect(find.text('暂不计入（总开关已关）'), findsOneWidget);
    });

    testWidgets('总览取不到（服务器出错）：一行说清是净资产没算出来 + 行内重试；下面的物品照常', (tester) async {
      final backend = worthBackend(assets: [assetJson('a1')])
        ..failAlways['GET /stats/overview'] = (500, 'boom', '服务器开小差了');
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=items');

      expect(find.byKey(const ValueKey('net-worth-error')), findsOneWidget);
      expect(find.text('净资产'), findsOneWidget);
      expect(find.text('暂时算不出来：服务器开小差了'), findsOneWidget);
      expect(find.byType(OutlinedButton), findsNothing, reason: '不用通用的大块报错');
      expect(find.byKey(const ValueKey('asset-a1')), findsOneWidget);
      expect(find.byType(TabBar), findsOneWidget);

      backend.failAlways.clear();
      await tapVisible(tester, find.widgetWithText(TextButton, '重试'));
      expect(find.byKey(const ValueKey('net-worth-error')), findsNothing);
      expect(find.text('¥16,215.88'), findsOneWidget);
    });

    testWidgets('离线：写「连不上服务器」，不把异常原文糊上来；联网后重试就好', (tester) async {
      final backend = worthBackend(assets: [assetJson('a1')])..offline.add('GET /stats/overview');
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=items');

      expect(find.text('暂时算不出来：连不上服务器'), findsOneWidget);
      expect(find.textContaining('Exception'), findsNothing);
      expect(find.byKey(const ValueKey('asset-a1')), findsOneWidget);

      backend.offline.clear();
      await tapVisible(tester, find.widgetWithText(TextButton, '重试'));
      expect(find.text('¥16,215.88'), findsOneWidget);
    });

    testWidgets('取到过、再刷新失败：留着旧数字，旁边说没刷新上，重试好了提示就收起', (tester) async {
      final backend = worthBackend(assets: [assetJson('a1')]);
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=items');
      expect(find.text('¥16,215.88'), findsOneWidget);

      backend.failAlways['GET /stats/overview'] = (500, 'boom', '服务器开小差了');
      await tester.fling(find.byType(ListView).last, const Offset(0, 400), 1000);
      await settle(tester);

      expect(find.text('¥16,215.88'), findsOneWidget);
      expect(find.text('没刷新上（服务器开小差了），先显示之前的数'), findsOneWidget);
      expect(find.byKey(const ValueKey('net-worth-error')), findsNothing);

      backend.failAlways.clear();
      await tapVisible(tester, find.widgetWithText(TextButton, '重试'));
      expect(find.byKey(const ValueKey('net-worth-stale')), findsNothing);
      expect(find.text('¥16,215.88'), findsOneWidget);
    });

    group('展开后三种宽度都不溢出', () {
      for (final size in kWidths) {
        testWidgets('@${size.width.toInt()}', (tester) async {
          await pumpAssetsAt(tester, bootAssets(worthBackend()..investMarketCents = 1512000), '/assets?tab=items', size: size);
          await expand(tester);
          expect(find.byKey(const ValueKey('net-worth-details')), findsOneWidget);
          expect(tester.takeException(), isNull);
        });
      }
    });

    testWidgets('矮屏（手机横放、分屏）：加载那一下不溢出；展开也不把下面的 Tab 挤没', (tester) async {
      await pumpAssetsAt(
        tester,
        bootAssets(worthBackend(assets: [assetJson('a1')]), session: await sessionAs('admin')),
        '/assets?tab=items',
        size: const Size(800, 420),
      );
      // 从第一帧（总览和物品页都是骨架）起就不许有溢出。
      expect(tester.takeException(), isNull);
      await expand(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(TabBar), findsOneWidget);
      // 明细在总览自己的区域里滚，开关照样够得着。
      await tapVisible(tester, find.byKey(const ValueKey('net-worth-switch')));
      expect(switchTile(tester).value, isFalse);
    });

    testWidgets('系统关了动画：点开明细下一帧就完全展开', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await pumpAssetsAt(tester, bootAssets(worthBackend()), '/assets?tab=items');

      await tester.tap(find.byKey(const ValueKey('net-worth-strip')));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(AnimatedSize), findsNothing);
      final details = find.byKey(const ValueKey('net-worth-details'));
      expect(details, findsOneWidget);
      final height = tester.getSize(details).height;
      await settle(tester);
      expect(tester.getSize(details).height, height, reason: '下一帧就是最终高度');
    });

    testWidgets('动画开着：第一帧还在展开（和上一条对照）', (tester) async {
      await pumpAssetsAt(tester, bootAssets(worthBackend()), '/assets?tab=items');

      await tester.tap(find.byKey(const ValueKey('net-worth-strip')));
      await tester.pump();
      final full = tester.getSize(find.byKey(const ValueKey('net-worth-details'))).height;
      expect(tester.getSize(find.byType(AnimatedSize)).height, lessThan(full));
      await settle(tester);
      expect(tester.getSize(find.byType(AnimatedSize)).height, full);
    });
  });

  test('netWorthBreakdown：没有持仓影响不写投资；没有在用的物品不写实物', () {
    const accountsOnly = StatsOverview(
      netWorthCents: 500000,
      assetsCents: 500000,
      liabilitiesCents: 0,
      month: MonthStats(),
      accounts: [AccountBalance(accountId: 'bank', balanceCents: 500000)],
      netWorthExPhysicalCents: 500000,
      physical: PhysicalSummary(counted: true),
    );
    expect(netWorthBreakdown(accountsOnly), '现金流 ¥5,000.00');
    expect(netWorthBreakdown(accountsOnly, reservedCents: 100000), '现金流 ¥5,000.00 · 可支配 ¥4,000.00');
  });

  test('可支配现金流 = 账户净额 − 目标/储备基金的正余额；超支的、日常的基金都不扣', () {
    const funds = [
      Fund(id: 'daily', name: '家庭公共', kind: 'shared'),
      Fund(id: 'trip', name: '旅行', kind: 'goal'),
      Fund(id: 'safe', name: '应急', kind: 'reserve'),
      Fund(id: 'kid', name: '育儿', kind: 'goal'),
    ];
    const o = StatsOverview(
      netWorthCents: 980000,
      assetsCents: 1000000,
      liabilitiesCents: 20000,
      month: MonthStats(),
      accounts: [
        AccountBalance(accountId: 'bank', balanceCents: 1000000),
        AccountBalance(accountId: 'card', balanceCents: -20000),
      ],
      funds: [
        FundBalance(fundId: 'daily', balanceCents: 600000),
        FundBalance(fundId: 'trip', balanceCents: 150000),
        FundBalance(fundId: 'safe', balanceCents: 200000),
        FundBalance(fundId: 'kid', balanceCents: -30000),
        FundBalance(fundId: 'gone', balanceCents: 99999),
      ],
    );
    expect(cashFlowCents(o), 980000);
    expect(reservedCents(o, funds), 350000, reason: '旅行 + 应急；育儿超支不算，已删的基金不认');
    expect(disposableCents(o, funds), 630000);
    expect(disposableCents(o, const []), 980000, reason: '主数据还没到：先按没有专款算');
  });
}
