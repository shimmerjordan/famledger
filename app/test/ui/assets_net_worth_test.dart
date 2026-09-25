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
    testWidgets('折叠：净资产 + 一行分项（标签说清口径）；点开是账户、投资、实物明细和开关', (tester) async {
      await pumpAssetsAt(tester, bootAssets(worthBackend()), '/assets');

      expect(find.text('净资产'), findsOneWidget);
      expect(find.text('¥16,215.88'), findsOneWidget);
      expect(breakdownText(tester), '账户 ¥9,800.00 · 投资（账户外）¥520.00 · 实物计入 ¥5,895.88');
      expect(find.byKey(const ValueKey('net-worth-details')), findsNothing);
      expect(
        tester.getBottomLeft(find.byKey(const ValueKey('net-worth-strip'))).dy,
        lessThanOrEqualTo(tester.getTopLeft(find.byType(TabBar)).dy),
        reason: 'Tab 在总览下面',
      );

      await expand(tester);
      expect(find.byKey(const ValueKey('net-worth-details')), findsOneWidget);
      expect(find.text('¥9,800.00'), findsOneWidget);
      expect(find.text('投资（账户外）'), findsOneWidget);
      expect(find.text('¥520.00'), findsOneWidget);
      expect(find.byKey(const ValueKey('net-worth-invest-note')), findsNothing, reason: '没挂账户：市值就是这个数');
      expect(find.text('实物估值'), findsOneWidget);
      expect(find.text('¥8,819.99'), findsOneWidget);
      expect(find.text('其中计入净资产'), findsOneWidget);
      expect(find.text('¥5,895.88'), findsOneWidget);
      expect(switchTile(tester).value, isTrue);
    });

    testWidgets('持仓挂了账户：分项只算账户外的浮盈，明细写出市值和已在账户里的成本', (tester) async {
      // 市值 15120、成本 14600 早以转账进了证券户（账户余额里），净资产只补浮盈 520。
      final backend = worthBackend()..investMarketCents = 1512000;
      await pumpAssetsAt(tester, bootAssets(backend), '/assets');

      expect(breakdownText(tester), contains('投资（账户外）¥520.00'));
      expect(find.text('¥16,215.88'), findsOneWidget);
      await expand(tester);
      expect(
        find.text('持仓市值 ¥15,120.00；挂了账户的持仓成本 ¥14,600.00 已在账户余额里，这里不再算'),
        findsOneWidget,
      );
    });

    testWidgets('管理员关掉「实物计入净资产」：开关先翻、等总览回来才放开；净资产和分项跟着变', (tester) async {
      final backend = worthBackend();
      await pumpAssetsAt(tester, bootAssets(backend, session: await sessionAs('admin')), '/assets');
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
      expect(breakdownText(tester), '账户 ¥9,800.00 · 投资（账户外）¥520.00 · 不含实物');
      expect(find.text('打开开关后计入'), findsOneWidget);
      expect(switchTile(tester).value, isFalse);
      expect(switchTile(tester).onChanged, isNotNull);
    });

    testWidgets('成员：开关是灰的，写明只有管理员能改，不发请求', (tester) async {
      final backend = worthBackend();
      await pumpAssetsAt(tester, bootAssets(backend, session: await sessionAs('member')), '/assets');
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
      await pumpAssetsAt(tester, bootAssets(backend, session: await sessionAs('admin')), '/assets');
      await expand(tester);

      await tapVisible(tester, find.byKey(const ValueKey('net-worth-switch')));
      expect(find.text('服务器开小差了'), findsOneWidget);
      expect(find.text('¥16,215.88'), findsOneWidget);
      expect(switchTile(tester).value, isTrue);
      expect(switchTile(tester).onChanged, isNotNull);
    });

    testWidgets('老服务端没给 physical：分项不写实物，也没有开关', (tester) async {
      final backend = worthBackend()..physical = null;
      await pumpAssetsAt(tester, bootAssets(backend), '/assets');

      expect(find.text('¥10,320.00'), findsOneWidget);
      expect(breakdownText(tester), '账户 ¥9,800.00 · 投资（账户外）¥520.00');
      await expand(tester);
      expect(find.byKey(const ValueKey('net-worth-switch')), findsNothing);
    });

    testWidgets('ledger seq 变了（同步拉到新数据）就重取', (tester) async {
      final backend = worthBackend();
      final container = bootAssets(backend);
      await pumpAssetsAt(tester, container, '/assets');
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
      await pumpAssetsAt(tester, bootAssets(backend), '/assets');
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
      await pumpAssetsAt(tester, bootAssets(backend), '/assets');

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
      await pumpAssetsAt(tester, bootAssets(backend), '/assets');

      expect(find.text('暂时算不出来：连不上服务器'), findsOneWidget);
      expect(find.textContaining('Exception'), findsNothing);
      expect(find.byKey(const ValueKey('asset-a1')), findsOneWidget);

      backend.offline.clear();
      await tapVisible(tester, find.widgetWithText(TextButton, '重试'));
      expect(find.text('¥16,215.88'), findsOneWidget);
    });

    testWidgets('取到过、再刷新失败：留着旧数字，旁边说没刷新上，重试好了提示就收起', (tester) async {
      final backend = worthBackend(assets: [assetJson('a1')]);
      await pumpAssetsAt(tester, bootAssets(backend), '/assets');
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
          await pumpAssetsAt(tester, bootAssets(worthBackend()..investMarketCents = 1512000), '/assets', size: size);
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
        '/assets',
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
      await pumpAssetsAt(tester, bootAssets(worthBackend()), '/assets');

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
      await pumpAssetsAt(tester, bootAssets(worthBackend()), '/assets');

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
    expect(netWorthBreakdown(accountsOnly), '账户 ¥5,000.00');
  });
}
