import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assets_harness.dart';

/// 金镯子：锁定在 1.2 万的手动估值上，锚点是 13 个月前（testNow = 2026-09-23）。
Map<String, dynamic> bracelet() => assetJson(
  'a9',
  name: '金镯子',
  category: 'jewelry',
  price: 1000000,
  purchasedOn: '2020-05-01',
  manualValueCents: 1200000,
  manualValueOn: '2025-08-01',
  netWorth: 'include',
);

void main() {
  group('物品详情 · 估值', () {
    testWidgets('在用：现在估值、较原价、怎么算的、1/2/3 年后、计入净资产', (tester) async {
      await pumpAssetsAt(
        tester,
        bootAssets(AssetsBackend(assets: [assetJson('a1', expectedDays: 1095)])),
        '/assets/items/a1',
      );

      expect(find.text('现在估值'), findsOneWidget);
      expect(find.text('¥5,895.88'), findsOneWidget);
      expect(find.text('−2%'), findsOneWidget);
      expect(find.text('跟随「数码」：每年打七五折，最低到原价的 10%'), findsOneWidget);
      expect(find.text('1 年后'), findsOneWidget);
      expect(find.text('¥4,421.91'), findsOneWidget);
      expect(find.text('2 年后'), findsOneWidget);
      expect(find.text('¥3,316.43'), findsOneWidget);
      expect(find.text('3 年后'), findsOneWidget);
      expect(find.text('¥2,487.32'), findsOneWidget);
      expect(find.text('计入（跟随类别）'), findsOneWidget);
      expect(find.text('估值不确定'), findsNothing);
      // 日均那一套照旧：估值不影响每天花多少。
      expect(find.text('¥260.83/天', findRichText: true), findsOneWidget);
    });

    testWidgets('手动估值高过原价：写「+20% 未实现」；锚点一年多没改就提醒、直接给去改的入口；不折旧不列几年后', (tester) async {
      await pumpAssetsAt(
        tester,
        bootAssets(AssetsBackend(assets: [bracelet()])),
        '/assets/items/a9',
      );

      expect(find.text('¥12,000.00'), findsOneWidget);
      expect(find.text('+20% 未实现'), findsOneWidget);
      expect(find.text('跟随「首饰/贵金属」：不折旧，按手动估值'), findsOneWidget);
      expect(find.text('估值已 13 个月没更新'), findsOneWidget);
      expect(find.text('1 年后'), findsNothing);
      expect(find.text('计入'), findsOneWidget);

      await tapVisible(tester, find.widgetWithText(TextButton, '更新估值'));
      expect(find.text('编辑物品'), findsOneWidget);
      expect(find.byKey(const ValueKey('valuation-manual')), findsOneWidget, reason: '有手动估值，估值一段直接展开');
    });

    testWidgets('家里关了「实物计入净资产」：本该计入的写「暂不计入」并说在哪打开', (tester) async {
      final backend = AssetsBackend(assets: [assetJson('a1')]);
      backend.settings['assets'] = {'netWorthIncludesPhysical': false};
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/items/a1');

      expect(find.text('暂不计入（总开关已关）'), findsOneWidget);
      expect(find.text('计入（跟随类别）'), findsNothing);
      expect(find.byKey(const ValueKey('valuation-networth-switch-off')), findsOneWidget);
    });

    testWidgets('家里关了总开关、这件本来就不计入：照旧写「不计入」，不多说', (tester) async {
      final backend = AssetsBackend(
        assets: [assetJson('a2', name: '洗衣机', category: 'appliance', price: 320000)],
      );
      backend.settings['assets'] = {'netWorthIncludesPhysical': false};
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/items/a2');

      expect(find.text('不计入（跟随类别）'), findsOneWidget);
      expect(find.byKey(const ValueKey('valuation-networth-switch-off')), findsNothing);
    });

    testWidgets('箱包：标「估值不确定」', (tester) async {
      await pumpAssetsAt(
        tester,
        bootAssets(
          AssetsBackend(
            assets: [
              assetJson('a8', name: '托特包', category: 'luxury', price: 1500000),
            ],
          ),
        ),
        '/assets/items/a8',
      );

      expect(find.text('估值不确定'), findsOneWidget);
      expect(find.text('跟随「箱包/奢侈品」：每年打八五折，最低到原价的 30%'), findsOneWidget);
    });

    testWidgets('已卖出：估值归零、不预估，只给处置盈亏（只展示，不记账）', (tester) async {
      await pumpAssetsAt(
        tester,
        bootAssets(
          AssetsBackend(
            assets: [
              assetJson(
                'a3',
                name: '旧手机',
                price: 300000,
                purchasedOn: '2026-01-01',
                status: 'sold',
                endedOn: '2026-09-10',
                saleCents: 80000,
              ),
            ],
          ),
        ),
        '/assets/items/a3',
      );

      expect(find.text('处置盈亏'), findsOneWidget);
      expect(find.text('−¥1,659.59'), findsOneWidget);
      expect(find.text('卖出价 − 卖出那天的估值 ¥2,459.59，只展示，不记账'), findsOneWidget);
      expect(find.text('现在估值'), findsNothing);
      expect(find.text('1 年后'), findsNothing);
    });

    testWidgets('已退役：没卖钱，处置盈亏是负的退役那天估值，说人话', (tester) async {
      await pumpAssetsAt(
        tester,
        bootAssets(
          AssetsBackend(
            assets: [
              assetJson(
                'a4',
                name: '旧平板',
                price: 300000,
                purchasedOn: '2026-01-01',
                status: 'retired',
                endedOn: '2026-09-10',
              ),
            ],
          ),
        ),
        '/assets/items/a4',
      );

      expect(find.text('处置盈亏'), findsOneWidget);
      expect(find.text('−¥2,459.59'), findsOneWidget);
      expect(find.text('退役没卖钱：少了退役那天的估值 ¥2,459.59，只展示，不记账'), findsOneWidget);
      expect(find.text('现在估值'), findsNothing);
      expect(find.text('1 年后'), findsNothing);
      expect(find.text('计入净资产'), findsNothing);
    });
  });

  testWidgets('长辈大字号（2 倍）：提醒折行、按钮还在，不溢出', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final backend = AssetsBackend(assets: [bracelet()]);
    backend.settings['assets'] = {'netWorthIncludesPhysical': false};
    await pumpAssetsAt(tester, bootAssets(backend), '/assets/items/a9', size: const Size(400, 1600));

    expect(find.text('估值已 13 个月没更新'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '更新估值'), findsOneWidget);
    expect(find.text('暂不计入（总开关已关）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('长辈大字号（2 倍）：箱包的「估值不确定」、较原价和金额放不下一行就折行', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpAssetsAt(
      tester,
      bootAssets(
        AssetsBackend(
          assets: [
            assetJson('a8', name: '托特包', category: 'luxury', price: 1500000, purchasedOn: '2025-01-01'),
          ],
        ),
      ),
      '/assets/items/a8',
    );

    expect(find.text('估值不确定'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('带提醒的估值卡三种宽度都不溢出', () {
    for (final size in kWidths) {
      testWidgets('@${size.width.toInt()}', (tester) async {
        await pumpAssetsAt(
          tester,
          bootAssets(AssetsBackend(assets: [bracelet()])),
          '/assets/items/a9',
          size: size,
        );
        expect(find.text('现在估值'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
