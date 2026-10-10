import 'package:famledger/data/models/models.dart';
import 'package:famledger/ui/assets/invest_tab.dart' show holdingSubtitle;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assets_harness.dart';

/// 白酒基金（份额类）+ 已到期的半年定期 10 万（2.15%）+ 余额宝（本金 1 万，现在 1.01 万）。
List<Map<String, dynamic>> mixed() => [
  holdingJson('h1'),
  {
    ...holdingJson('h5', name: '招行半年定期', code: null, market: 'other', qty: 10000, cost: 10000000, price: null, prev: null, source: 'manual', accountId: null, openedOn: '2025-01-01', sort: 1),
    'kind': 'fixed',
    'institution': '招商银行',
    'rateE6': 21500,
    'maturesOn': '2025-07-01',
  },
  {
    ...holdingJson('h6', name: '余额宝', code: null, market: 'other', qty: 10000, cost: 1000000, price: null, prev: null, source: 'manual', accountId: null, openedOn: '2026-01-01', sort: 2),
    'kind': 'demand',
    'institution': '支付宝',
    'rateE6': 18000,
    'valueCents': 1010000,
    'valueOn': '2026-09-01',
  },
];

Finder tile(String id) => find.byKey(ValueKey('holding-$id'));

void main() {
  group('理财按品类分组', () {
    testWidgets('组头带小计；定期写利率和到期、到期了标出来；活期写年化和更新日期', (tester) async {
      await pumpAssetsAt(tester, bootAssets(AssetsBackend(holdings: mixed())), '/assets?tab=invest');

      for (final kind in ['fund', 'fixed', 'demand']) {
        expect(find.byKey(ValueKey('invest-kind-$kind')), findsOneWidget, reason: kind);
      }
      // 定期：本金 10 万 + 181 天利息 1066.16（到期日停）
      expect(find.descendant(of: tile('h5'), matching: find.text('¥101,066.16')), findsOneWidget);
      expect(find.descendant(of: tile('h5'), matching: find.text('已到期')), findsOneWidget);
      expect(find.descendant(of: tile('h5'), matching: find.text(holdingSubtitle(['招商银行', '2.15%', '已到期 449 天']))), findsOneWidget);
      expect(find.descendant(of: tile('h6'), matching: find.text('¥10,100.00')), findsOneWidget);
      expect(find.descendant(of: tile('h6'), matching: find.text(holdingSubtitle(['支付宝', '年化 1.80%', '9月1日 更新']))), findsOneWidget);
      // 理财估值 = 1200 + 101066.16 + 10100
      expect(find.text('¥112,366.16'), findsOneWidget);
    });

    testWidgets('只有定期活期、没有基金股票：不出「刷新行情」和今日涨跌', (tester) async {
      await pumpAssetsAt(tester, bootAssets(AssetsBackend(holdings: mixed().sublist(1))), '/assets?tab=invest');
      expect(find.text('刷新行情'), findsNothing);
      expect(find.textContaining('今日涨跌'), findsNothing);
    });
  });

  group('添加理财', () {
    testWidgets('定期：先挑品类，填本金、年利率、点「3 年」定到期日；不带份额和市场', (tester) async {
      final backend = AssetsBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/holdings/new');

      await tapVisible(tester, find.byKey(const ValueKey('holding-kind-fixed')));
      expect(find.text(Holding.kindHints[Holding.kindFixed]!), findsOneWidget);
      expect(find.byKey(const ValueKey('holding-code')), findsNothing, reason: '定期没有代码、份额、现价');
      expect(find.byKey(const ValueKey('holding-quantity')), findsNothing);

      await tester.enterText(find.byKey(const ValueKey('holding-name')), '招行三年定期');
      await tester.enterText(find.byKey(const ValueKey('holding-institution')), '招商银行');
      await tester.enterText(find.byKey(const ValueKey('holding-cost')), '50000');
      await tester.enterText(find.byKey(const ValueKey('holding-rate')), '2.75');
      await tapVisible(tester, find.byKey(const ValueKey('holding-record')));
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      expect(find.text('选一下到期日'), findsOneWidget);

      await tapVisible(tester, find.byKey(const ValueKey('holding-term-36')));
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));

      final body = backend.lastBody('POST', '/holdings');
      final today = DateTime.now();
      final due = DateTime(today.year + 3, today.month, today.day);
      expect(body['kind'], 'fixed');
      expect(body['market'], 'other');
      expect(body['costCents'], 5000000);
      expect(body['rateE6'], 27500);
      expect(body['institution'], '招商银行');
      expect(body['maturesOn'], '${due.year}-${due.month.toString().padLeft(2, '0')}-${due.day.toString().padLeft(2, '0')}');
      expect(body.containsKey('quantityE4'), isFalse);
      expect(body['priceSource'], 'manual');
    });

    testWidgets('活期：本金 + 当前金额（选填）；结构性存款要两个年化、最高不能低于保底', (tester) async {
      final backend = AssetsBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/holdings/new');
      await tapVisible(tester, find.byKey(const ValueKey('holding-kind-structured')));
      await tester.enterText(find.byKey(const ValueKey('holding-name')), '结构性');
      await tester.enterText(find.byKey(const ValueKey('holding-cost')), '10000');
      await tester.enterText(find.byKey(const ValueKey('holding-rate')), '3');
      await tester.enterText(find.byKey(const ValueKey('holding-rate-max')), '1.5');
      await tapVisible(tester, find.byKey(const ValueKey('holding-term-3')));
      await tapVisible(tester, find.byKey(const ValueKey('holding-record')));
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      expect(find.text('最高年化不能低于保底'), findsOneWidget);

      await tapVisible(tester, find.byKey(const ValueKey('holding-kind-demand')));
      expect(find.byKey(const ValueKey('holding-rate-max')), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('holding-name')), '余额宝');
      await tester.enterText(find.byKey(const ValueKey('holding-value')), '10023.5');
      await tester.enterText(find.byKey(const ValueKey('holding-rate')), '');
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      final body = backend.lastBody('POST', '/holdings');
      expect(body['kind'], 'demand');
      expect(body['costCents'], 1000000);
      expect(body['valueCents'], 1002350);
      expect(body.containsKey('maturesOn'), isFalse);
    });
  });

  group('理财详情按记法', () {
    testWidgets('到期的定期：主按钮是「到期取出」，先填好本息；取出后结清', (tester) async {
      final backend = AssetsBackend(holdings: mixed());
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/holdings/h5');
      expect(find.text('本息'), findsOneWidget);
      expect(find.text('已到期 449 天'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '到期取出'), findsOneWidget);
      expect(find.text('加仓'), findsNothing);

      await tapVisible(tester, find.widgetWithText(FilledButton, '到期取出'));
      final amount = find.byKey(const ValueKey('trade-amount'));
      expect(tester.widget<TextField>(amount).controller!.text, '101066.16');
      expect(find.byKey(const ValueKey('trade-quantity')), findsNothing);
      expect(find.text('+¥1,066.16'), findsWidgets, reason: '预计收益');
      await tapVisible(tester, find.descendant(of: find.byType(BottomSheet), matching: find.widgetWithText(FilledButton, '到期取出')));
      final body = backend.lastBody('POST', '/holdings/h5/trade');
      expect(body['side'], 'sell');
      expect(body['amountCents'], 10106616);
      expect(body.containsKey('quantityE4'), isFalse);
      expect(backend.holdings['h5']!['quantityE4'], 0);
    });

    testWidgets('活期：「更新金额」改当前金额；存入、取出只填金额', (tester) async {
      final backend = AssetsBackend(holdings: mixed());
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/holdings/h6');
      expect(find.text('当前金额'), findsWidgets);
      await tapVisible(tester, find.widgetWithText(FilledButton, '更新金额'));
      await tester.enterText(find.byKey(const ValueKey('value-input')), '10200');
      await tapVisible(tester, find.widgetWithText(FilledButton, '改好了'));
      expect(backend.lastBody('PATCH', '/holdings/h6'), {'valueCents': 1020000});

      await tapVisible(tester, find.widgetWithText(OutlinedButton, '取出'));
      expect(find.byKey(const ValueKey('trade-quantity')), findsNothing);
      expect(find.text('全部 ¥10,200.00'), findsOneWidget);
    });

    testWidgets('基金：多一个「分红」，只填金额，记一笔收入到选的账户', (tester) async {
      final backend = AssetsBackend(holdings: mixed());
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/holdings/h1');
      await tapVisible(tester, find.widgetWithText(OutlinedButton, '分红'));
      expect(find.byKey(const ValueKey('trade-quantity')), findsNothing);
      expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('trade-record'))).value, isTrue);
      await tester.enterText(find.byKey(const ValueKey('trade-amount')), '12');
      await tapVisible(tester, find.byKey(const ValueKey('trade-account-inv')));
      await tapVisible(tester, find.descendant(of: find.byType(BottomSheet), matching: find.widgetWithText(FilledButton, '分红')));
      final body = backend.lastBody('POST', '/holdings/h1/trade');
      expect(body['side'], 'income');
      expect(body['amountCents'], 1200);
      expect(body['recordTransaction'], {'accountId': 'inv'});
    });
  });

  test('估值：定期按天计息到期停、付出来的利息扣掉；活期按金额；和服务端同一组数', () {
    final now = DateTime(2026, 10, 9, 10);
    const deposit = Holding(
      id: 'x',
      kind: Holding.kindFixed,
      quantityE4: 10000,
      costCents: 10000000,
      rateE6: 21500,
      openedOn: '2025-01-01',
      maturesOn: '2025-07-01',
    );
    expect(accruedCents(10000000, 21500, '2025-01-01', '2025-07-01'), 106616);
    expect(holdingValueCents(deposit, now), 10106616);
    expect(holdingMetrics(deposit, now).matured, isTrue);
    expect(holdingValueCents(const Holding(id: 'x', kind: Holding.kindFixed, quantityE4: 10000, costCents: 10000000, rateE6: 21500, openedOn: '2025-01-01', maturesOn: '2025-07-01', realizedCents: 50000), now), 10056616);
    expect(holdingValueCents(const Holding(id: 'y', kind: Holding.kindDemand, quantityE4: 10000, costCents: 500, openedOn: '2026-01-01'), now), 500);
    expect(holdingValueCents(const Holding(id: 'y', kind: Holding.kindDemand, quantityE4: 10000, costCents: 500, valueCents: 520, openedOn: '2026-01-01'), now), 520);
    expect(Holding.fromJson({'id': 'z', 'market': 'fund', 'openedOn': '2026-01-01'}).kind, Holding.kindFund, reason: '老数据按市场推');
    expect(Holding.fromJson({'id': 'z', 'market': 'sh', 'openedOn': '2026-01-01'}).kind, Holding.kindStock);
    expect(parseRateE6('2.15'), 21500);
    expect(parseRateE6('2.15%'), 21500);
    expect(parseRateE6('abc'), isNull);
    expect(formatRateE6(21500), '2.15%');
    expect(formatRateE6(18000), '1.80%');
    final w = previewWithdraw(
      const Holding(id: 'w', kind: Holding.kindDemand, quantityE4: 10000, costCents: 1100000, valueCents: 1110000, openedOn: '2026-01-01'),
      555000,
    )!;
    expect(w.costCents, 550000);
    expect(w.realizedCents, 5000);
  });

  group('三种宽度都不溢出', () {
    for (final size in kWidths) {
      testWidgets('理财列表 @${size.width.toInt()}', (tester) async {
        await pumpAssetsAt(tester, bootAssets(AssetsBackend(holdings: mixed())), '/assets?tab=invest', size: size);
        expect(tester.takeException(), isNull);
      });

      testWidgets('添加定期 @${size.width.toInt()}', (tester) async {
        await pumpAssetsAt(tester, bootAssets(AssetsBackend()), '/assets/holdings/new', size: size);
        await tapVisible(tester, find.byKey(const ValueKey('holding-kind-structured')));
        expect(tester.takeException(), isNull);
      });

      testWidgets('定期详情 @${size.width.toInt()}', (tester) async {
        await pumpAssetsAt(tester, bootAssets(AssetsBackend(holdings: mixed())), '/assets/holdings/h5', size: size);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
