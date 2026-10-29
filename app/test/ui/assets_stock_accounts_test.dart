import 'package:famledger/core/dates.dart';
import 'package:famledger/data/models/models.dart';
import 'package:famledger/ui/assets/holding_form_page.dart';
import 'package:famledger/ui/assets/invest_tab.dart' show holdingSubtitle;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assets_harness.dart';
import 'assets_invest_test.dart' show portfolio;

/// 股票账户：股票按整户市值记（不逐只记持仓）。理财段第一组列出每个股票账户，详情页只有更新市值 / 转入 / 转出；
/// 逐只记的老股票能并进股票账户；账户表单的「当前市值」。

/// 华泰 10 万投入、市值 12.12 万（9/20 填的）；东财 5000 投入、还没填市值。
List<Map<String, dynamic>> stockAccounts({String valueOn = '2026-09-20'}) => [
  ...defaultAccounts,
  {
    'id': 'stk',
    'name': '华泰证券',
    'kind': 'stock',
    'sortOrder': 3,
    'valueCents': 12120000,
    'valueOn': valueOn,
    'valueLog': [
      {'on': '2026-09-10', 'valueCents': 11850000},
      {'on': valueOn, 'valueCents': 12120000},
    ],
  },
  {'id': 'stk2', 'name': '东财证券', 'kind': 'stock', 'sortOrder': 4},
];

AssetsBackend withStocks({List<Map<String, dynamic>> holdings = const [], String valueOn = '2026-09-20'}) =>
    AssetsBackend(holdings: holdings, accounts: stockAccounts(valueOn: valueOn))
      ..accountBalances = {'bank': 1000000, 'stk': 10000000, 'stk2': 500000};

Finder tile(String id) => find.byKey(ValueKey('stock-account-$id'));

void main() {
  group('理财段', () {
    testWidgets('第一组是股票账户：市值、投入、浮盈和收益率；没填市值的按投入算并提醒；估值合计含股票账户', (tester) async {
      await pumpAssetsAt(tester, bootAssets(withStocks(holdings: portfolio())), '/assets?tab=invest');

      expect(find.text('股票账户'), findsOneWidget);
      expect(find.descendant(of: tile('stk'), matching: find.text('¥121,200.00')), findsOneWidget);
      expect(find.descendant(of: tile('stk'), matching: find.text('+¥21,200.00')), findsOneWidget);
      expect(find.descendant(of: tile('stk'), matching: find.text('+21.20%')), findsOneWidget);
      expect(find.descendant(of: tile('stk'), matching: find.text(holdingSubtitle(['投入 ¥100,000.00', '9月20日 更新']))), findsOneWidget);
      expect(find.descendant(of: tile('stk2'), matching: find.text('¥5,000.00')), findsOneWidget);
      expect(find.descendant(of: tile('stk2'), matching: find.text(holdingSubtitle(['投入 ¥5,000.00', '按投入算', '填一下市值']))), findsOneWidget);
      expect(find.text('1 个股票账户还没填市值，先按投入算'), findsOneWidget);
      // 理财估值 = 持仓 156,300 + 华泰 121,200 + 东财 5,000
      expect(find.text('¥282,500.00'), findsOneWidget);
      // 浮动收益 = 持仓 +300 + 华泰 +21,200
      expect(find.text('+¥21,500.00'), findsOneWidget);
      expect(find.text('持仓'), findsOneWidget, reason: '两组都有时持仓也有个组头');
      expect(find.byKey(const ValueKey('invest-kind-fund')), findsNothing, reason: '持仓不再按品类分组');
    });

    testWidgets('市值超过 31 天没更新：标「该更新了」', (tester) async {
      await pumpAssetsAt(tester, bootAssets(withStocks(valueOn: '2026-08-01')), '/assets?tab=invest');
      expect(find.descendant(of: tile('stk'), matching: find.text('该更新了')), findsOneWidget);
    });

    testWidgets('还有逐只记的股票：提示能并进股票账户；合并 sheet 默认勾股票、市值预填其合计，提交 absorb', (tester) async {
      final backend = withStocks(holdings: portfolio());
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=invest');

      expect(find.byKey(const ValueKey('stock-merge-hint')), findsOneWidget);
      await tapVisible(tester, find.byKey(const ValueKey('stock-merge-hint-action')));
      // 茅台是股票；「银行理财」这行老数据没写 kind、市场是 other，按老规矩也推成股票（同服务端迁移 009）。
      expect(tester.widget<CheckboxListTile>(find.byKey(const ValueKey('absorb-h-h3'))).value, isTrue, reason: '茅台是股票，默认勾上');
      expect(tester.widget<CheckboxListTile>(find.byKey(const ValueKey('absorb-h-h2'))).value, isTrue);
      expect(tester.widget<CheckboxListTile>(find.byKey(const ValueKey('absorb-h-h1'))).value, isFalse, reason: '基金默认不勾');
      expect(find.byKey(const ValueKey('absorb-h-h4')), findsNothing, reason: '清了仓的不在候选里');
      // 茅台 100 股 × 1500 = 150,000，银行理财 5,100
      expect(tester.widget<TextField>(find.byKey(const ValueKey('absorb-value'))).controller!.text, '155100.00');

      await tapVisible(tester, find.byKey(const ValueKey('absorb-submit')));

      final body = backend.lastBody('POST', '/accounts/stk/absorb');
      expect(body['holdingIds'], ['h2', 'h3']);
      expect(body['valueCents'], 15510000);
      expect(body['valueOn'], '2026-09-23');
      expect(backend.holdings['h3']!['archived'], isTrue);
      expect(find.text('贵州茅台'), findsNothing, reason: '并进去的持仓归档了');
      expect(find.byKey(const ValueKey('stock-merge-hint')), findsNothing);
      expect(find.descendant(of: tile('stk'), matching: find.text('¥155,100.00')), findsOneWidget, reason: '市值按并进去后的数');
    });

    testWidgets('合并 sheet 换成美元户：只列、只预填、只提交同币种的持仓，看不见的不会跟着交上去', (tester) async {
      final backend = withStocks(holdings: [
        ...portfolio(),
        // 10 股 × 120.0000 = 1,200.00 美元。
        {...holdingJson('h5', name: '苹果', code: 'AAPL', market: 'other', qty: 100000, cost: 100000, price: 1200000, accountId: null), 'currency': 'USD'},
      ]);
      backend.accounts.add({'id': 'stk-usd', 'name': '美元券商', 'kind': 'stock', 'currency': 'USD', 'sortOrder': 5});
      backend.accountBalances['stk-usd'] = 0;
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=invest');
      await tapVisible(tester, find.byKey(const ValueKey('stock-merge-hint-action')));
      expect(find.byKey(const ValueKey('absorb-h-h5')), findsNothing, reason: '默认选的华泰是人民币户，美股不在列');

      await tapVisible(tester, find.byKey(const ValueKey('absorb-account-stk-usd')));
      expect(find.byKey(const ValueKey('absorb-h-h5')), findsOneWidget);
      expect(find.byKey(const ValueKey('absorb-h-h3')), findsNothing, reason: '茅台是人民币的');
      expect(tester.widget<TextField>(find.byKey(const ValueKey('absorb-value'))).controller!.text, '1200.00', reason: '预填只算看得见的');

      await tapVisible(tester, find.byKey(const ValueKey('absorb-submit')));
      final body = backend.lastBody('POST', '/accounts/stk-usd/absorb');
      expect(body['holdingIds'], ['h5'], reason: '勾着但被币种筛掉的茅台、银行理财不交');
      expect(body['valueCents'], 120000);
    });

    testWidgets('一笔都没有：空态多一个「新建股票账户」入口，弹出的账户表单预选股票账户并有市值栏', (tester) async {
      final backend = AssetsBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=invest');

      expect(find.text('还没有理财'), findsOneWidget);
      await tapVisible(tester, find.byKey(const ValueKey('invest-empty-stock')));
      expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('account-kind-stock'))).selected, isTrue);
      expect(find.byKey(const ValueKey('account-value')), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, '华泰证券');
      await tester.enterText(find.byKey(const ValueKey('account-initial-balance')), '100000');
      await tester.enterText(find.byKey(const ValueKey('account-value')), '121200');
      await tapVisible(tester, find.widgetWithText(FilledButton, '保存'));

      final body = backend.lastBody('POST', '/accounts');
      expect(body['kind'], 'stock');
      expect(body['name'], '华泰证券');
      expect(body['initialBalanceCents'], 10000000);
      expect(body['valueCents'], 12120000);
      expect(body['valueOn'], Dates.isoDate(DateTime.now()));
      // 建好就列出来了（市值 12.12 万）。
      expect(find.text('股票账户'), findsOneWidget);
      expect(find.text('¥121,200.00'), findsWidgets);
    });

    testWidgets('顶栏「添加理财」弹选择：记一笔理财进表单，新建股票账户弹账户表单', (tester) async {
      await pumpAssetsAt(tester, bootAssets(withStocks()), '/assets?tab=invest');

      await tester.tap(find.byTooltip('添加理财'));
      await settle(tester);
      expect(find.byKey(const ValueKey('invest-add-holding')), findsOneWidget);
      await tapVisible(tester, find.byKey(const ValueKey('invest-add-stock')));
      expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('account-kind-stock'))).selected, isTrue);
    });

    testWidgets('宽屏：右栏默认嵌第一个股票账户的详情；点持仓换成持仓详情', (tester) async {
      await pumpAssetsAt(tester, bootAssets(withStocks(holdings: portfolio())), '/assets?tab=invest', size: const Size(1400, 900));

      expect(find.byKey(const ValueKey('stock-pane-stk')), findsOneWidget);
      await tapVisible(tester, find.byKey(const ValueKey('holding-h1')));
      expect(find.byKey(const ValueKey('holding-pane-h1')), findsOneWidget);
      expect(find.byKey(const ValueKey('stock-pane-stk')), findsNothing);
      await tapVisible(tester, tile('stk2'));
      expect(find.byKey(const ValueKey('stock-pane-stk2')), findsOneWidget);
    });
  });

  group('股票账户详情', () {
    testWidgets('市值、投入、浮盈，历次市值带差额；更新市值 → PATCH valueCents/valueOn，记录多一条', (tester) async {
      final backend = withStocks();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/accounts/stk');

      expect(find.text('市值'), findsOneWidget);
      expect(find.text('¥121,200.00'), findsWidgets);
      expect(find.text('¥100,000.00'), findsOneWidget);
      expect(find.text('+¥21,200.00'), findsOneWidget);
      expect(find.text('市值 9月20日 更新 · 投入 = 转进去的本金'), findsOneWidget);
      expect(find.byKey(const ValueKey('stock-value-2026-09-20')), findsOneWidget);
      expect(find.text('+¥2,700.00'), findsOneWidget, reason: '9/20 比 9/10 多 2700');

      await tapVisible(tester, find.byKey(const ValueKey('stock-set-value')));
      expect(tester.widget<TextField>(find.byKey(const ValueKey('stock-value-amount'))).controller!.text, '121200.00');
      await tester.enterText(find.byKey(const ValueKey('stock-value-amount')), '130000');
      await tapVisible(tester, find.byKey(const ValueKey('stock-value-submit')));

      expect(backend.lastBody('PATCH', '/accounts/stk'), {'valueCents': 13000000, 'valueOn': '2026-09-23'});
      expect(find.text('¥130,000.00'), findsWidgets);
      expect(find.byKey(const ValueKey('stock-value-2026-09-23')), findsOneWidget);
      expect(find.text('+¥8,800.00'), findsOneWidget, reason: '9/23 比 9/20 多 8800');
    });

    testWidgets('转入：从别的账户记一笔转账到这个账户；投入跟着变', (tester) async {
      final backend = withStocks();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/accounts/stk');

      await tapVisible(tester, find.byKey(const ValueKey('stock-transfer-in')));
      await tester.enterText(find.byKey(const ValueKey('stock-transfer-amount')), '20000');
      await tapVisible(tester, find.byKey(const ValueKey('stock-transfer-submit')));
      expect(find.text('钱从哪个账户转进来？'), findsOneWidget);
      expect(find.byKey(const ValueKey('stock-transfer-account-stk')), findsNothing, reason: '不能转给自己');
      await tapVisible(tester, find.byKey(const ValueKey('stock-transfer-account-bank')));
      await tapVisible(tester, find.byKey(const ValueKey('stock-transfer-submit')));

      final body = backend.lastBody('POST', '/transactions');
      expect(body['type'], 'transfer');
      expect(body['amountCents'], 2000000);
      expect(body['accountId'], 'bank');
      expect(body['toAccountId'], 'stk');
      expect(body['merchant'], '转入 华泰证券');
      expect(body['occurredAt'], startsWith('2026-09-23T12:00'));
      expect(find.text('¥120,000.00'), findsOneWidget, reason: '投入 10 万 + 2 万');
      expect(find.text('转入 华泰证券'), findsWidgets, reason: '最近流水里有它');
    });

    testWidgets('没填过市值：按投入算，说清；转出到别的账户', (tester) async {
      final backend = withStocks();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/accounts/stk2');

      expect(find.text('投入（还没填市值）'), findsOneWidget);
      expect(find.text('还没填过市值'), findsOneWidget);

      await tapVisible(tester, find.byKey(const ValueKey('stock-transfer-out')));
      await tester.enterText(find.byKey(const ValueKey('stock-transfer-amount')), '1000');
      await tapVisible(tester, find.byKey(const ValueKey('stock-transfer-account-bank')));
      await tapVisible(tester, find.byKey(const ValueKey('stock-transfer-submit')));

      final body = backend.lastBody('POST', '/transactions');
      expect(body['accountId'], 'stk2');
      expect(body['toAccountId'], 'bank');
      expect(body['merchant'], '转出到 工行卡');
    });

    testWidgets('编辑股票账户：有市值栏、没有「现在余额」校准栏（余额是投入，不是照券商 App 抄的数）', (tester) async {
      await pumpAssetsAt(tester, bootAssets(withStocks(holdings: portfolio())), '/assets/accounts/stk');
      await tapVisible(tester, find.byKey(const ValueKey('stock-edit')));
      expect(find.byKey(const ValueKey('account-value')), findsOneWidget);
      expect(find.byKey(const ValueKey('account-initial-balance')), findsOneWidget);
      expect(find.byKey(const ValueKey('account-current-balance')), findsNothing);
    });

    for (final size in kWidths) {
      testWidgets('不溢出 @${size.width.toInt()}', (tester) async {
        await pumpAssetsAt(tester, bootAssets(withStocks(holdings: portfolio())), '/assets/accounts/stk', size: size);
        expect(find.text('¥121,200.00'), findsWidgets);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('模型', () {
    test('Account 的市值字段来回；股票账户算投资类', () {
      final json = stockAccounts()[3];
      final a = Account.fromJson(json);
      expect(a.isStock, isTrue);
      expect(a.isInvestLike, isTrue);
      expect(a.valueCents, 12120000);
      expect(a.valueOn, '2026-09-20');
      expect(a.valueLog.map((e) => e.valueCents), [11850000, 12120000]);
      final back = Account.fromJson(a.toJson());
      expect(back.valueCents, a.valueCents);
      expect(back.valueLog.length, 2);
      expect(const Account(id: 'b', name: '卡', kind: 'bank').isInvestLike, isFalse);
      expect(const Account(id: 'i', name: '户', kind: 'invest').isInvestLike, isTrue);
    });

    test('stockAccountMetrics / summarizeStockAccounts：浮盈、收益率、过期、按币种合计', () {
      final a = Account.fromJson(stockAccounts()[3]);
      final m = stockAccountMetrics(a, 10000000, testNow);
      expect(m.marketCents, 12120000);
      expect(m.investedCents, 10000000);
      expect(m.gainCents, 2120000);
      expect(m.gainRate, closeTo(0.212, 1e-9));
      expect(m.stale, isFalse);
      expect(m.unvalued, isFalse);
      final old = stockAccountMetrics(Account.fromJson(stockAccounts(valueOn: '2026-08-01')[3]), 10000000, testNow);
      expect(old.stale, isTrue);
      final none = stockAccountMetrics(Account.fromJson(stockAccounts()[4]), 500000, testNow);
      expect(none.unvalued, isTrue);
      expect(none.marketCents, 500000);
      expect(none.gainCents, isNull);
      // 总览没回来：按初始余额当投入
      expect(stockAccountMetrics(const Account(id: 'x', name: 'x', kind: 'stock', initialBalanceCents: 300), null, testNow).investedCents, 300);

      final usd = Account.fromJson({...stockAccounts()[3], 'id': 'us', 'currency': 'USD', 'valueCents': 2000});
      final summary = summarizeStockAccounts(
        [a, Account.fromJson(stockAccounts()[4]), usd, const Account(id: 'arch', name: '旧', kind: 'stock', archived: true, valueCents: 1)],
        (id) => {'stk': 10000000, 'stk2': 500000, 'us': 1500}[id],
        testNow,
      );
      expect(summary.keys, unorderedEquals(['CNY', 'USD']));
      expect(summary['CNY']!.marketCents, 12120000 + 500000);
      expect(summary['CNY']!.investedCents, 10500000);
      expect(summary['CNY']!.valuedInvestedCents, 10000000);
      expect(summary['CNY']!.gainCents, 2120000);
      expect(summary['CNY']!.count, 2);
      expect(summary['CNY']!.unvaluedCount, 1);
      expect(summary['USD']!.gainCents, 500);
      expect(summary['USD']!.count, 1, reason: '归档的不算');
    });

    test('holding_form_page 还在（逐笔记的理财照旧）', () {
      expect(HoldingFormPage, isNotNull);
    });
  });
}
