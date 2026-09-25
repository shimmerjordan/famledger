import 'package:famledger/core/dates.dart';
import 'package:famledger/data/models/models.dart';
import 'package:famledger/ui/assets/asset_widgets.dart';
import 'package:famledger/ui/assets/valuation_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assets_harness.dart';

TextEditingController controllerOf(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey(key))).controller!;

/// 估值展开后表单很长，ListView 只建看得见的那一截：窗口拉高，整张表单都建出来。
const Size tall = Size(400, 2400);

void main() {
  group('ValuationEditor.read', () {
    final bought = DateTime(2026, 9, 1);
    final today = DateTime(2026, 9, 23);

    test('全空：方式和三态是 auto，其余 null；新建时一个键都不带', () {
      final e = ValuationEditor();
      addTearDown(e.dispose);
      final r = e.read(category: 'digital', purchasedOn: bought, today: today);
      expect(r.error, isNull);
      expect(r.input!.toPatchJson(), {
        'valuationMethod': 'auto',
        'rateBp': null,
        'residualBp': null,
        'manualValueCents': null,
        'manualValueOn': null,
        'netWorth': 'auto',
      });
      expect(r.input!.toCreateJson(), isEmpty);
    });

    test('百分数：25、12.5、「12.5%」都认；超范围、乱填、负数、Infinity 都算填错', () {
      expect(parsePercentBp('25', maxBp: 9000), 2500);
      expect(parsePercentBp('12.5', maxBp: 9000), 1250);
      expect(parsePercentBp(' 12.5% ', maxBp: 9000), 1250);
      expect(parsePercentBp('', maxBp: 9000), isNull);
      expect(parsePercentBp('95', maxBp: 9000), -1);
      expect(parsePercentBp('100', maxBp: 10000), 10000);
      expect(parsePercentBp('abc', maxBp: 9000), -1);
      expect(parsePercentBp('-1', maxBp: 9000), -1);
      expect(parsePercentBp('Infinity', maxBp: 9000), -1);
    });

    test('手动估值：填了金额没挑日子就记今天；早于买入日期、金额填错都不让存', () {
      final e = ValuationEditor()..manualValue.text = '5000';
      addTearDown(e.dispose);
      final ok = e.read(category: 'digital', purchasedOn: bought, today: today);
      expect(ok.input!.manualValueCents, 500000);
      expect(ok.input!.manualValueOn, '2026-09-23');

      e.setManualOn(DateTime(2026, 8, 31));
      expect(
        e.read(category: 'digital', purchasedOn: bought, today: today).error,
        '估值日期不能早于买入日期',
      );
      e.manualValue.text = '5k';
      expect(
        e.read(category: 'digital', purchasedOn: bought, today: today).error,
        '手动估值填得不对，例如 4000',
      );
    });

    test('已有锚点只改金额：日期换成今天；改回原金额日期也回去；自己挑过日子就不替他换', () {
      final e = ValuationEditor()
        ..bind(
          Asset.fromJson(
            assetJson('a1', purchasedOn: '2024-06-01', manualValueCents: 400000, manualValueOn: '2025-01-01'),
          ),
        );
      addTearDown(e.dispose);
      expect(e.manualOn, DateTime(2025, 1, 1));

      e.manualValue.text = '3000';
      e.manualEdited();
      expect(e.manualOn, isNull, reason: '没挑日子 = 今天');
      final r = e.read(category: 'digital', purchasedOn: DateTime(2024, 6, 1), today: today);
      expect(r.input!.manualValueCents, 300000);
      expect(r.input!.manualValueOn, '2026-09-23');

      e.manualValue.text = '4000';
      e.manualEdited();
      expect(e.manualOn, DateTime(2025, 1, 1), reason: '改回原金额，还是原来那天估的');

      e.setManualOn(DateTime(2026, 3, 1));
      e.manualValue.text = '3500';
      e.manualEdited();
      expect(e.manualOn, DateTime(2026, 3, 1), reason: '自己挑的日子不动');

      // 清掉以后重填：是新的一次估值，按今天。
      e.clearManual();
      e.manualValue.text = '4000';
      e.manualEdited();
      expect(e.manualOn, isNull);
    });

    test('看不见的字段不校验也不发：不折旧时不管折率和残值；匀速折旧不管折率', () {
      final e = ValuationEditor()
        ..rate.text = '95'
        ..residual.text = 'abc';
      addTearDown(e.dispose);
      e.setMethod(Asset.methodLocked);
      final locked = e.read(category: 'digital', purchasedOn: bought, today: today);
      expect(locked.error, isNull);
      expect(locked.input!.rateBp, isNull);
      expect(locked.input!.residualBp, isNull);

      e
        ..setMethod(Asset.methodAuto)
        ..residual.text = '5';
      // 家电跟随类别 = 匀速折旧：折率那格压根不显示。
      final straight = e.read(category: 'appliance', purchasedOn: bought, today: today);
      expect(straight.error, isNull);
      expect(straight.input!.rateBp, isNull);
      expect(straight.input!.residualBp, 500);
    });

    test('套预设：保值款清掉折率和残值，之后认得出是这个预设', () {
      final e = ValuationEditor()..rate.text = '20';
      addTearDown(e.dispose);
      e.applyPreset(presetByKey('keep_value')!);
      expect(e.method, Asset.methodLocked);
      expect(e.rate.text, '');
      expect(e.residual.text, '');
      expect(e.matches(presetByKey('keep_value')!), isTrue);
      expect(e.matches(presetByKey('watch')!), isFalse);
    });
  });

  group('表单里的估值', () {
    testWidgets('新建：买入日期默认是（注入时钟的）今天；套「苹果设备」预设、改成不计入；只带改过的估值字段', (tester) async {
      final backend = AssetsBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/items/new', size: tall);

      await tester.enterText(find.byKey(const ValueKey('asset-name')), 'MacBook');
      await tester.enterText(find.byKey(const ValueKey('asset-price')), '12999.5');
      await tester.pump();
      // 今天买的：估值 = 原价。
      expect(find.text('现在约 ¥12,999.50'), findsOneWidget);

      await tapVisible(tester, find.text('估值'));
      expect(find.text('跟随「数码」：每年打七五折，最低到原价的 10%'), findsOneWidget);
      await tapVisible(tester, find.byKey(const ValueKey('valuation-preset-apple')));
      expect(controllerOf(tester, 'valuation-rate').text, '20');
      expect(controllerOf(tester, 'valuation-residual').text, '10');
      expect(find.text('每年打八折，最低到原价的 10%'), findsOneWidget);
      await tapVisible(tester, find.byKey(const ValueKey('valuation-networth-exclude')));

      await tapVisible(tester, find.byKey(const ValueKey('asset-record')));
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));

      expect(backend.lastBody('POST', '/assets'), {
        'name': 'MacBook',
        'category': 'digital',
        'priceCents': 1299950,
        'purchasedOn': '2026-09-23',
        'valuationMethod': 'declining',
        'rateBp': 2000,
        'residualBp': 1000,
        'netWorth': 'exclude',
        'clientId': isA<String>(),
      });
    });

    testWidgets('编辑：填手动估值（日期默认今天），说明文字跟着变，PATCH 带上六个估值字段', (tester) async {
      final backend = AssetsBackend(assets: [assetJson('a1')]);
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/items/a1/edit', size: tall);

      await tapVisible(tester, find.text('估值'));
      await tester.enterText(find.byKey(const ValueKey('valuation-manual')), '5000');
      await tester.pump();
      expect(find.byKey(const ValueKey('valuation-manual-on')), findsOneWidget);
      expect(
        find.text('跟随「数码」：每年打七五折，最低到原价的 10%；从 2026-09-23 的手动估值 ¥5,000.00 起算'),
        findsOneWidget,
      );
      expect(find.text('现在约 ¥5,000.00'), findsOneWidget);

      await tapVisible(tester, find.widgetWithText(FilledButton, '保存'));
      expect(backend.lastBody('PATCH', '/assets/a1'), {
        'name': 'iPhone 16',
        'category': 'digital',
        'priceCents': 599900,
        'purchasedOn': '2026-09-01',
        'expectedDays': null,
        'note': null,
        'valuationMethod': 'auto',
        'rateBp': null,
        'residualBp': null,
        'manualValueCents': 500000,
        'manualValueOn': '2026-09-23',
        'netWorth': 'auto',
      });
    });

    testWidgets('新建时填手动估值、不挑日子：估值日期就是今天，不会被当成早于买入日期', (tester) async {
      final backend = AssetsBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/items/new', size: tall);

      await tester.enterText(find.byKey(const ValueKey('asset-name')), '二手相机');
      await tester.enterText(find.byKey(const ValueKey('asset-price')), '5000');
      await tapVisible(tester, find.text('估值'));
      await tester.enterText(find.byKey(const ValueKey('valuation-manual')), '4200');
      await tester.pump();
      expect(find.text('现在约 ¥4,200.00'), findsOneWidget);

      await tapVisible(tester, find.byKey(const ValueKey('asset-record')));
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      final body = backend.lastBody('POST', '/assets');
      expect(body['purchasedOn'], '2026-09-23');
      expect(body['manualValueCents'], 420000);
      expect(body['manualValueOn'], '2026-09-23');
    });

    testWidgets('编辑：已有手动估值只改金额 —— PATCH 的估值日期是今天，新值不被旧日期打折', (tester) async {
      final backend = AssetsBackend(
        assets: [
          assetJson('a5', purchasedOn: '2024-06-01', manualValueCents: 400000, manualValueOn: '2025-01-01'),
        ],
      );
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/items/a5/edit', size: tall);

      expect(controllerOf(tester, 'valuation-manual').text, '4000.00');
      await tester.enterText(find.byKey(const ValueKey('valuation-manual')), '3000');
      await tester.pump();
      expect(find.text('现在约 ¥3,000.00'), findsOneWidget);
      final day = tester
          .widget<DayButton>(
            find.descendant(of: find.byKey(const ValueKey('valuation-manual-on')), matching: find.byType(DayButton)),
          )
          .day;
      expect(Dates.isoDate(day), '2026-09-23', reason: '日期按钮跟着变成今天');

      await tapVisible(tester, find.widgetWithText(FilledButton, '保存'));
      final body = backend.lastBody('PATCH', '/assets/a5');
      expect(body['manualValueCents'], 300000);
      expect(body['manualValueOn'], '2026-09-23');
    });

    testWidgets('编辑：点估值日期挑一天，保存带上挑的那天', (tester) async {
      final backend = AssetsBackend(assets: [assetJson('a1')]);
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/items/a1/edit', size: tall);

      await tapVisible(tester, find.text('估值'));
      await tester.enterText(find.byKey(const ValueKey('valuation-manual')), '5000');
      await tester.pump();
      await tapVisible(tester, find.byKey(const ValueKey('valuation-manual-on')));
      final picker = find.byType(DatePickerDialog);
      expect(picker, findsOneWidget);
      await tester.tap(find.descendant(of: picker, matching: find.text('15')));
      await tester.pump();
      await tester.tap(find.text('OK'));
      await settle(tester);

      await tapVisible(tester, find.widgetWithText(FilledButton, '保存'));
      final body = backend.lastBody('PATCH', '/assets/a1');
      expect(body['manualValueCents'], 500000);
      expect(body['manualValueOn'], '2026-09-15');
    });

    testWidgets('编辑已卖出的：估值标题下写「估值归零」，不写现在约多少', (tester) async {
      final backend = AssetsBackend(
        assets: [
          assetJson('a3', price: 300000, purchasedOn: '2026-01-01', status: 'sold', endedOn: '2026-09-10', saleCents: 80000),
        ],
      );
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/items/a3/edit', size: tall);

      expect(find.text('已卖出，估值归零（处置盈亏见详情）'), findsOneWidget);
      expect(find.textContaining('现在约'), findsNothing);
    });

    testWidgets('家里关了总开关：三态下面说一句「怎么选都暂不计入」；开着时不说', (tester) async {
      final backend = AssetsBackend(assets: [assetJson('a1')]);
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/items/a1/edit', size: tall);
      await tapVisible(tester, find.text('估值'));
      expect(find.byKey(const ValueKey('valuation-networth-switch-off')), findsNothing);

      final off = AssetsBackend(assets: [assetJson('a1')]);
      off.settings['assets'] = {'netWorthIncludesPhysical': false};
      await pumpAssetsAt(tester, bootAssets(off), '/assets/items/a1/edit', size: tall);
      await tapVisible(tester, find.text('估值'));
      expect(find.byKey(const ValueKey('valuation-networth-switch-off')), findsOneWidget);
    });

    testWidgets('「打算用多久」：匀速折旧的类别写明年限也按它；每年打折的不写', (tester) async {
      await pumpAssetsAt(tester, bootAssets(AssetsBackend()), '/assets/items/new', size: tall);
      final hint = find.byKey(const ValueKey('asset-expected-life-hint'));
      expect(hint, findsNothing, reason: '数码默认每年打折');

      await tapVisible(tester, find.byKey(const ValueKey('asset-category-appliance')));
      expect(tester.widget<Text>(hint).data, '这件按匀速折旧估值，折旧年限也按这个天数算；不填按类别默认 8 年');

      // 单件改成每年打折，提示就收起。
      await tapVisible(tester, find.text('估值'));
      await tapVisible(tester, find.byKey(const ValueKey('valuation-method-declining')));
      expect(hint, findsNothing);
    });

    testWidgets('系统关了动画：估值一段点开下一帧就完全展开', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await pumpAssetsAt(tester, bootAssets(AssetsBackend(assets: [assetJson('a1')])), '/assets/items/a1/edit', size: tall);

      await tester.tap(find.text('估值'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('valuation-manual')).hitTestable(), findsOneWidget);
    });

    testWidgets('动画开着：估值一段第一帧还没展开（和上一条对照）', (tester) async {
      await pumpAssetsAt(tester, bootAssets(AssetsBackend(assets: [assetJson('a1')])), '/assets/items/a1/edit', size: tall);

      await tester.tap(find.text('估值'));
      await tester.pump();
      expect(find.byKey(const ValueKey('valuation-manual')).hitTestable(), findsNothing);
      await settle(tester);
      expect(find.byKey(const ValueKey('valuation-manual')).hitTestable(), findsOneWidget);
    });

    testWidgets('编辑：原来的估值设置带出来、这一段直接展开；「清掉」手动估值发两个 null', (tester) async {
      final backend = AssetsBackend(
        assets: [
          assetJson(
            'a9',
            name: '金镯子',
            category: 'jewelry',
            price: 1000000,
            purchasedOn: '2020-05-01',
            valuationMethod: 'locked',
            manualValueCents: 1200000,
            manualValueOn: '2025-08-01',
            netWorth: 'include',
          ),
        ],
      );
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/items/a9/edit', size: tall);

      expect(find.byKey(const ValueKey('valuation-manual')), findsOneWidget, reason: '有自定义估值就直接展开');
      expect(controllerOf(tester, 'valuation-manual').text, '12000.00');
      expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('valuation-method-locked'))).selected, isTrue);
      expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('valuation-networth-include'))).selected, isTrue);
      expect(find.byKey(const ValueKey('valuation-rate')), findsNothing, reason: '不折旧就没有折率可填');

      await tapVisible(tester, find.byKey(const ValueKey('valuation-manual-clear')));
      expect(find.byKey(const ValueKey('valuation-manual-on')), findsNothing);
      await tapVisible(tester, find.widgetWithText(FilledButton, '保存'));

      final body = backend.lastBody('PATCH', '/assets/a9');
      expect(body.containsKey('manualValueCents'), isTrue);
      expect(body['manualValueCents'], isNull);
      expect(body['manualValueOn'], isNull);
      expect(body['valuationMethod'], 'locked');
      expect(body['netWorth'], 'include');
    });

    testWidgets('高级参数填错：行内说清楚、不发请求；留空就是跟随类别（发 null）', (tester) async {
      final backend = AssetsBackend(assets: [assetJson('a1')]);
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/items/a1/edit', size: tall);
      await tapVisible(tester, find.text('估值'));

      await tester.enterText(find.byKey(const ValueKey('valuation-rate')), '95');
      await tapVisible(tester, find.widgetWithText(FilledButton, '保存'));
      expect(find.text('年折率填 0 到 90 之间的数，例如 25'), findsOneWidget);
      expect(backend.requests('PATCH', '/assets/a1'), isEmpty);

      await tester.enterText(find.byKey(const ValueKey('valuation-rate')), '');
      await tester.enterText(find.byKey(const ValueKey('valuation-residual')), 'abc');
      await tapVisible(tester, find.widgetWithText(FilledButton, '保存'));
      expect(find.text('残值/保底填 0 到 100 之间的数，例如 10'), findsOneWidget);
      expect(backend.requests('PATCH', '/assets/a1'), isEmpty);

      await tester.enterText(find.byKey(const ValueKey('valuation-residual')), '12.5%');
      await tapVisible(tester, find.widgetWithText(FilledButton, '保存'));
      final body = backend.lastBody('PATCH', '/assets/a1');
      expect(body['rateBp'], isNull);
      expect(body['residualBp'], 1250);
    });

    group('估值展开后三种宽度都不溢出', () {
      for (final size in kWidths) {
        testWidgets('@${size.width.toInt()}', (tester) async {
          await pumpAssetsAt(
            tester,
            bootAssets(AssetsBackend(assets: [assetJson('a1')])),
            '/assets/items/a1/edit',
            size: size,
          );
          await tapVisible(tester, find.text('估值'));
          await tester.enterText(find.byKey(const ValueKey('valuation-manual')), '5000');
          await tester.pump();
          await tester.drag(find.byType(ListView).first, const Offset(0, -2000));
          await settle(tester);
          expect(tester.takeException(), isNull);
        });
      }
    });
  });
}
