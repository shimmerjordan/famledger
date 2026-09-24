import 'dart:convert';

import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/data/repos/holdings_repo.dart';
import 'package:famledger/ui/assets/trade_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assets_harness.dart';

/// 白酒基金（自动行情、新鲜）、银行理财（手动价）、茅台（行情三天没更新）、清了仓的一只。
List<Map<String, dynamic>> portfolio() => [
  holdingJson('h1'),
  holdingJson(
    'h2',
    name: '银行理财',
    code: null,
    market: 'other',
    qty: 10000,
    cost: 500000,
    price: 51000000,
    prev: null,
    source: 'manual',
    accountId: null,
    sort: 1,
  ),
  holdingJson(
    'h3',
    name: '贵州茅台',
    code: '600519',
    market: 'sh',
    qty: 1000000,
    cost: 15000000,
    price: 15000000,
    prev: 14900000,
    priceAt: testNow.subtract(const Duration(days: 3)),
    sort: 2,
  ),
  holdingJson(
    'h4',
    name: '易方达蓝筹',
    code: '005827',
    qty: 0,
    cost: 0,
    realized: 12345,
    sort: 3,
  ),
];

double topOf(WidgetTester tester, String text) =>
    tester.getTopLeft(find.text(text)).dy;

Future<void> openInvestTab(WidgetTester tester) async {
  await tester.tap(find.text('投资'));
  await settle(tester);
}

void main() {
  group('投资列表', () {
    testWidgets('顶部：总市值、总收益与收益率、今日涨跌；只算有价格、没清仓的', (tester) async {
      await pumpAssetsAt(
        tester,
        bootAssets(AssetsBackend(holdings: portfolio())),
        '/assets?tab=invest',
      );

      expect(find.text('总市值'), findsOneWidget);
      expect(find.text('¥156,300.00'), findsOneWidget);
      expect(find.text('+¥300.00'), findsOneWidget);
      expect(find.text('+0.19%'), findsOneWidget);
      expect(find.text('+¥1,100.00'), findsOneWidget);
      expect(find.text('刷新行情'), findsOneWidget);
    });

    testWidgets('持仓行：代码、持有天数、日均收益、收益率；手动价与过期行情标出来', (tester) async {
      await pumpAssetsAt(
        tester,
        bootAssets(AssetsBackend(holdings: portfolio())),
        '/assets?tab=invest',
      );

      expect(find.text('招商中证白酒'), findsOneWidget);
      expect(find.text('161725 · 持有 10 天 · 日均 +¥20.00'), findsOneWidget);
      expect(find.text('¥1,200.00'), findsOneWidget);
      expect(find.text('+20.00%'), findsOneWidget);

      expect(find.text('银行理财'), findsOneWidget);
      expect(find.text('手动价'), findsOneWidget);
      expect(find.text('行情过期'), findsOneWidget);
    });

    testWidgets('清了仓的分组放在最后，只看已实现盈亏', (tester) async {
      await pumpAssetsAt(
        tester,
        bootAssets(AssetsBackend(holdings: portfolio())),
        '/assets?tab=invest',
      );

      expect(find.text('已清仓'), findsOneWidget);
      expect(find.text('005827 · 已清仓'), findsOneWidget);
      expect(find.text('+¥123.45'), findsOneWidget);
      expect(topOf(tester, '易方达蓝筹'), greaterThan(topOf(tester, '贵州茅台')));
    });

    testWidgets('一只都没有：说一句并给「添加持仓」', (tester) async {
      await pumpAssetsAt(tester, bootAssets(AssetsBackend()), '/assets?tab=invest');

      expect(find.text('还没有持仓'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '添加持仓'), findsOneWidget);
    });
  });

  group('进投资页自动刷新行情', () {
    testWidgets('切到投资标签刷一次；一小时内再进来不刷', (tester) async {
      final backend = AssetsBackend(holdings: portfolio());
      await pumpAssetsAt(tester, bootAssets(backend), '/assets');
      expect(backend.requests('POST', '/holdings/refresh'), isEmpty);

      await openInvestTab(tester);
      expect(backend.requests('POST', '/holdings/refresh'), hasLength(1));

      await tester.tap(find.text('物品'));
      await settle(tester);
      await openInvestTab(tester);
      expect(backend.requests('POST', '/holdings/refresh'), hasLength(1));
    });

    testWidgets('直接打开投资页、本地还没缓存：等同步回来再判，照样刷', (tester) async {
      final backend = AssetsBackend(holdings: portfolio());
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=invest');
      expect(backend.requests('POST', '/holdings/refresh'), hasLength(1));
    });

    testWidgets('本机半小时前刷过：不刷', (tester) async {
      final store = MemoryLocalStore();
      await store.write(
        HoldingsRepo.lastRefreshKey,
        testNow.subtract(const Duration(minutes: 30)).toIso8601String(),
      );
      final backend = AssetsBackend(holdings: portfolio());
      await pumpAssetsAt(
        tester,
        bootAssets(backend, store: store),
        '/assets?tab=invest',
      );
      expect(backend.requests('POST', '/holdings/refresh'), isEmpty);
    });

    testWidgets('没有开自动行情的持仓：不刷', (tester) async {
      final backend = AssetsBackend(holdings: [portfolio()[1]]);
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=invest');
      expect(backend.requests('POST', '/holdings/refresh'), isEmpty);
    });

    testWidgets('被节流 / 出错都安静处理，不冒红字', (tester) async {
      final backend = AssetsBackend(holdings: portfolio())
        ..refreshResult = {
          'updated': 0,
          'failed': <Object>[],
          'refreshedAt': testNow.toUtc().toIso8601String(),
          'throttled': true,
        };
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=invest');
      expect(backend.requests('POST', '/holdings/refresh'), hasLength(1));
      expect(find.textContaining('刷新失败'), findsNothing);
      expect(find.text('刚刷过，过几分钟再刷'), findsNothing);

      final broken = AssetsBackend(holdings: portfolio())
        ..failNext['POST /holdings/refresh'] = (500, 'boom', '行情挂了');
      await pumpAssetsAt(tester, bootAssets(broken), '/assets?tab=invest');
      expect(broken.requests('POST', '/holdings/refresh'), hasLength(1));
      expect(find.textContaining('行情挂了'), findsNothing);
    });
  });

  group('手动刷新行情', () {
    testWidgets('被节流：说一声「刚刷过」', (tester) async {
      final store = MemoryLocalStore();
      await store.write(HoldingsRepo.lastRefreshKey, testNow.toIso8601String());
      final backend = AssetsBackend(holdings: portfolio())
        ..refreshResult = {
          'updated': 0,
          'failed': <Object>[],
          'refreshedAt': testNow.toUtc().toIso8601String(),
          'throttled': true,
        };
      await pumpAssetsAt(
        tester,
        bootAssets(backend, store: store),
        '/assets?tab=invest',
      );

      await tester.tap(find.text('刷新行情'));
      await settle(tester);
      expect(backend.requests('POST', '/holdings/refresh'), hasLength(1));
      expect(find.text('刚刷过，过几分钟再刷'), findsOneWidget);
    });

    testWidgets('有几只没拿到行情：点名说出来', (tester) async {
      final store = MemoryLocalStore();
      await store.write(HoldingsRepo.lastRefreshKey, testNow.toIso8601String());
      final backend = AssetsBackend(holdings: portfolio())
        ..refreshResult = {
          'updated': 1,
          'failed': [
            {'id': 'h3', 'code': '600519', 'message': '请求超时'},
          ],
          'refreshedAt': testNow.toUtc().toIso8601String(),
          'throttled': false,
        };
      await pumpAssetsAt(
        tester,
        bootAssets(backend, store: store),
        '/assets?tab=invest',
      );

      await tester.tap(find.text('刷新行情'));
      await settle(tester);
      expect(find.text('1 只没拿到行情：贵州茅台 请求超时'), findsOneWidget);
      expect(find.text('更新了 1 只'), findsOneWidget);
    });

    testWidgets('请求失败：红字说原因', (tester) async {
      final store = MemoryLocalStore();
      await store.write(HoldingsRepo.lastRefreshKey, testNow.toIso8601String());
      final backend = AssetsBackend(holdings: portfolio())
        ..failNext['POST /holdings/refresh'] = (502, 'bad_gateway', '行情源连不上');
      await pumpAssetsAt(
        tester,
        bootAssets(backend, store: store),
        '/assets?tab=invest',
      );

      await tester.tap(find.text('刷新行情'));
      await settle(tester);
      expect(find.text('刷新失败：行情源连不上'), findsOneWidget);
    });
  });

  group('新建持仓', () {
    testWidgets('默认「同时记一笔转账」：选投资账户与转出账户；存完列表里有、并顺手拉行情', (
      tester,
    ) async {
      final backend = AssetsBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=invest');

      await tester.tap(find.byTooltip('添加持仓'));
      await settle(tester);
      expect(find.text('添加持仓'), findsWidgets);
      final record = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('holding-record')),
      );
      expect(record.value, isTrue);

      await tester.enterText(find.byKey(const ValueKey('holding-name')), '沪深300ETF');
      await tester.enterText(find.byKey(const ValueKey('holding-code')), '510300');
      await tester.tap(find.byKey(const ValueKey('holding-market-sh')));
      await tester.pump();
      final auto = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('holding-auto')),
      );
      expect(auto.value, isTrue);
      // 开着自动行情就不用填现价。
      expect(find.byKey(const ValueKey('holding-price')), findsNothing);

      await tester.enterText(find.byKey(const ValueKey('holding-quantity')), '1000');
      await tester.enterText(find.byKey(const ValueKey('holding-cost')), '3,850.5');
      await tapVisible(tester, find.byKey(const ValueKey('invest-account-inv')));
      // 投资账户不会出现在「转出」里。
      expect(find.byKey(const ValueKey('from-account-inv')), findsNothing);
      await tapVisible(tester, find.byKey(const ValueKey('from-account-bank')));
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));

      final body = backend.lastBody('POST', '/holdings');
      expect(body['name'], '沪深300ETF');
      expect(body['code'], '510300');
      expect(body['market'], 'sh');
      expect(body['quantityE4'], 10000000);
      expect(body['costCents'], 385050);
      expect(body['priceSource'], 'auto');
      expect(body['accountId'], 'inv');
      expect(body['recordTransaction'], {'fromAccountId': 'bank'});
      expect(body.containsKey('priceE4'), isFalse);

      expect(find.text('沪深300ETF'), findsOneWidget);
      expect(backend.requests('POST', '/holdings/refresh'), isNotEmpty);
    });

    testWidgets('刚进页刷过、新建的自动行情持仓被节流：没价格，说一声几分钟后再刷', (tester) async {
      final backend = AssetsBackend(holdings: [holdingJson('h1')]);
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=invest');
      expect(backend.requests('POST', '/holdings/refresh'), hasLength(1));

      backend.refreshResult = {
        'updated': 0,
        'failed': <Object>[],
        'refreshedAt': testNow.toUtc().toIso8601String(),
        'throttled': true,
      };
      await tester.tap(find.byTooltip('添加持仓'));
      await settle(tester);
      await tester.enterText(find.byKey(const ValueKey('holding-name')), '沪深300ETF');
      await tester.enterText(find.byKey(const ValueKey('holding-code')), '510300');
      await tester.tap(find.byKey(const ValueKey('holding-market-sh')));
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('holding-quantity')), '1000');
      await tester.enterText(find.byKey(const ValueKey('holding-cost')), '3850');
      await tapVisible(tester, find.byKey(const ValueKey('holding-record')));
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      await settle(tester);

      expect(backend.requests('POST', '/holdings/refresh'), hasLength(2));
      expect(find.text('沪深300ETF'), findsOneWidget);
      expect(find.text('没有价格'), findsOneWidget);
      expect(find.text('1 只还没有价格，没算进市值；行情刚刷过，几分钟后再点「刷新行情」'), findsOneWidget);
    });

    testWidgets('手动价：没代码就开不了自动行情，现价照填', (tester) async {
      final backend = AssetsBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/holdings/new');

      await tester.enterText(find.byKey(const ValueKey('holding-name')), '银行理财');
      await tester.tap(find.byKey(const ValueKey('holding-market-other')));
      await tester.pump();
      final auto = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('holding-auto')),
      );
      expect(auto.value, isFalse);
      expect(auto.onChanged, isNull);

      await tester.enterText(find.byKey(const ValueKey('holding-price')), '1.0230');
      await tester.enterText(find.byKey(const ValueKey('holding-quantity')), '5000');
      await tester.enterText(find.byKey(const ValueKey('holding-cost')), '5000');
      await tapVisible(tester, find.byKey(const ValueKey('holding-record')));
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));

      final body = backend.lastBody('POST', '/holdings');
      expect(body['priceSource'], 'manual');
      expect(body['priceE4'], 10230);
      expect(body.containsKey('recordTransaction'), isFalse);
      expect(body.containsKey('code'), isFalse);
      expect(backend.requests('POST', '/holdings/refresh'), isEmpty);
    });

    testWidgets('没有投资账户：提示去建；开着记转账就不让存', (tester) async {
      final backend = AssetsBackend(
        accounts: const [
          {'id': 'bank', 'name': '工行卡', 'kind': 'bank', 'sortOrder': 0},
        ],
      );
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/holdings/new');

      expect(find.text('还没有「投资」类型的账户，建一个才能记转账'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('holding-code')), '161725');
      await tester.enterText(find.byKey(const ValueKey('holding-quantity')), '100');
      await tester.enterText(find.byKey(const ValueKey('holding-cost')), '100');
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      expect(find.text('选一个投资账户，或关掉「同时记一笔转账」'), findsOneWidget);
      expect(backend.requests('POST', '/holdings'), isEmpty);

      await tapVisible(tester, find.widgetWithText(TextButton, '去建一个'));
      expect(find.text('账户管理页'), findsOneWidget);
    });

    testWidgets('关掉「同时记一笔转账」就不挂投资账户：请求里不带 accountId', (tester) async {
      final backend = AssetsBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/holdings/new');

      await tester.enterText(find.byKey(const ValueKey('holding-name')), '老仓位');
      await tester.tap(find.byKey(const ValueKey('holding-market-other')));
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('holding-quantity')), '100');
      await tester.enterText(find.byKey(const ValueKey('holding-cost')), '5000');
      // 先选了投资账户，再关掉开关：挂了账户的持仓净资产只补浮盈，成本没转进来就会凭空少一份。
      await tapVisible(tester, find.byKey(const ValueKey('invest-account-inv')));
      await tapVisible(tester, find.byKey(const ValueKey('holding-record')));
      expect(find.byKey(const ValueKey('invest-account-inv')), findsNothing);
      expect(find.text('不记就不挂投资账户，市值整份算进净资产'), findsOneWidget);
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));

      final body = backend.lastBody('POST', '/holdings');
      expect(body.containsKey('accountId'), isFalse);
      expect(body.containsKey('recordTransaction'), isFalse);
      expect(backend.holdings.values.single['accountId'], isNull);
    });

    testWidgets('名称代码都空、份额填错：行内说清楚', (tester) async {
      final backend = AssetsBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/holdings/new');

      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      expect(find.text('名称和代码至少填一个'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('holding-code')), '16 1725');
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      expect(find.text('代码只能是字母和数字，例如 161725'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('holding-code')), '161725');
      await tester.enterText(find.byKey(const ValueKey('holding-quantity')), '0');
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      expect(find.text('份额填得不对，例如 1000'), findsOneWidget);
      expect(backend.requests('POST', '/holdings'), isEmpty);
    });
  });

  group('持仓详情与加减仓', () {
    testWidgets('详情：市值、收益、今日涨跌、明细', (tester) async {
      await pumpAssetsAt(
        tester,
        bootAssets(AssetsBackend(holdings: portfolio())),
        '/assets/holdings/h1',
      );

      expect(find.text('市值'), findsOneWidget);
      expect(find.text('¥1,200.00'), findsOneWidget);
      expect(find.text('+¥200.00'), findsOneWidget);
      expect(find.text('+20.00%'), findsOneWidget);
      expect(find.text('+¥100.00'), findsOneWidget);
      expect(find.text('1,000 份'), findsOneWidget);
      expect(find.text('10 天'), findsOneWidget);
      expect(find.text('证券户'), findsOneWidget);
    });

    testWidgets('减仓：显示预计已实现盈亏，选账户后提交；回来份额变了', (tester) async {
      final backend = AssetsBackend(holdings: portfolio());
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/holdings/h1');

      await tapVisible(tester, find.widgetWithText(OutlinedButton, '减仓'));
      final sheet = find.byType(TradeSheet);
      expect(sheet, findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('trade-quantity')), '500');
      await tester.enterText(find.byKey(const ValueKey('trade-amount')), '700');
      await tester.pump();
      // 成本 1000 摊一半 = 500，卖 700 → 赚 200。
      expect(find.byKey(const ValueKey('trade-preview')), findsOneWidget);
      expect(
        find.descendant(of: sheet, matching: find.text('+¥200.00')),
        findsOneWidget,
      );
      expect(find.text('按平均成本摊 ¥500.00，剩 500 份'), findsOneWidget);

      // 投资账户自己不在「转回」的候选里。
      expect(find.byKey(const ValueKey('trade-account-inv')), findsNothing);
      await tapVisible(tester, find.byKey(const ValueKey('trade-account-bank')));
      await tapVisible(
        tester,
        find.descendant(of: sheet, matching: find.widgetWithText(FilledButton, '减仓')),
      );

      expect(backend.lastBody('POST', '/holdings/h1/trade'), {
        'side': 'sell',
        'quantityE4': 5000000,
        'amountCents': 70000,
        'occurredOn': '2026-09-23',
        'recordTransaction': {'accountId': 'bank'},
        'clientId': isA<String>(),
      });
      expect(find.byType(TradeSheet), findsNothing);
      expect(find.text('500 份'), findsOneWidget);
      expect(find.text('+¥200.00'), findsWidgets); // 已实现盈亏
    });

    testWidgets('卖超了：行内拦下，不发请求', (tester) async {
      final backend = AssetsBackend(holdings: portfolio());
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/holdings/h1');

      await tapVisible(tester, find.widgetWithText(OutlinedButton, '减仓'));
      await tester.enterText(find.byKey(const ValueKey('trade-quantity')), '1001');
      await tester.enterText(find.byKey(const ValueKey('trade-amount')), '100');
      await tester.pump();
      expect(find.byKey(const ValueKey('trade-preview')), findsNothing);
      await tapVisible(
        tester,
        find.descendant(
          of: find.byType(TradeSheet),
          matching: find.widgetWithText(FilledButton, '减仓'),
        ),
      );
      expect(find.text('最多能卖 1,000 份'), findsOneWidget);
      expect(backend.requests('POST', '/holdings/h1/trade'), isEmpty);
    });

    testWidgets('加仓：关掉记转账也能提交', (tester) async {
      final backend = AssetsBackend(holdings: portfolio());
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/holdings/h1');

      await tapVisible(tester, find.widgetWithText(FilledButton, '加仓'));
      final sheet = find.byType(TradeSheet);
      await tester.enterText(find.byKey(const ValueKey('trade-quantity')), '100.5');
      await tester.enterText(find.byKey(const ValueKey('trade-amount')), '120');
      await tapVisible(tester, find.byKey(const ValueKey('trade-record')));
      await tapVisible(
        tester,
        find.descendant(of: sheet, matching: find.widgetWithText(FilledButton, '加仓')),
      );

      expect(backend.lastBody('POST', '/holdings/h1/trade'), {
        'side': 'buy',
        'quantityE4': 1005000,
        'amountCents': 12000,
        'occurredOn': '2026-09-23',
        'clientId': isA<String>(),
      });
      expect(find.text('1,100.5 份'), findsOneWidget);
    });

    testWidgets('没挂投资账户的持仓：记转账开关关着且不能开', (tester) async {
      await pumpAssetsAt(
        tester,
        bootAssets(AssetsBackend(holdings: portfolio())),
        '/assets/holdings/h2',
      );

      await tapVisible(tester, find.widgetWithText(FilledButton, '加仓'));
      final record = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('trade-record')),
      );
      expect(record.value, isFalse);
      expect(record.onChanged, isNull);
      expect(find.text('这笔持仓没挂投资账户，编辑挂上才能记'), findsOneWidget);
    });

    testWidgets('编辑没挂账户、有成本的持仓：挂上要选成本从哪转进来，请求带 recordTransaction', (tester) async {
      final backend = AssetsBackend(holdings: portfolio());
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/holdings/h2/edit');

      expect(find.text('成本从哪个账户转进来'), findsNothing);
      await tapVisible(tester, find.byKey(const ValueKey('invest-account-inv')));
      expect(find.text('成本从哪个账户转进来'), findsOneWidget);
      expect(
        find.text('挂上会补记一笔 ¥5,000.00 的转账，把成本从下面选的账户转进来。早就持有、钱不是从账本里的账户出的，就别挂'),
        findsOneWidget,
      );
      // 投资账户自己不在「转进来」的候选里
      expect(find.byKey(const ValueKey('from-account-inv')), findsNothing);

      await tapVisible(tester, find.widgetWithText(FilledButton, '保存'));
      expect(find.text('挂上投资账户要选成本从哪个账户转进来'), findsOneWidget);
      expect(backend.requests('PATCH', '/holdings/h2'), isEmpty);

      await tapVisible(tester, find.byKey(const ValueKey('from-account-bank')));
      await tapVisible(tester, find.widgetWithText(FilledButton, '保存'));
      final body = backend.lastBody('PATCH', '/holdings/h2');
      expect(body['accountId'], 'inv');
      expect(body['recordTransaction'], {'fromAccountId': 'bank'});
      expect(find.text('已保存，也记了一笔 ¥5,000.00 的转账'), findsOneWidget);
    });

    testWidgets('编辑挂着账户、有成本的持仓：再点选中的账户不会解绑，保存不补转账', (tester) async {
      final backend = AssetsBackend(holdings: portfolio());
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/holdings/h1/edit');

      expect(find.text('成本记在这个账户里，不能直接解绑，可以换一个投资账户'), findsOneWidget);
      await tapVisible(tester, find.byKey(const ValueKey('invest-account-inv')));
      final chip = tester.widget<ChoiceChip>(find.byKey(const ValueKey('invest-account-inv')));
      expect(chip.selected, isTrue);

      await tapVisible(tester, find.widgetWithText(FilledButton, '保存'));
      final body = backend.lastBody('PATCH', '/holdings/h1');
      expect(body['accountId'], 'inv');
      expect(body.containsKey('recordTransaction'), isFalse);
      expect(find.text('已保存'), findsOneWidget);
    });

    testWidgets('加仓回应丢了：说不确定记上没有；再点一次沿用同一个 clientId，份额只加一次', (tester) async {
      final backend = AssetsBackend(holdings: portfolio());
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/holdings/h1');

      await tapVisible(tester, find.widgetWithText(FilledButton, '加仓'));
      final sheet = find.byType(TradeSheet);
      await tester.enterText(find.byKey(const ValueKey('trade-quantity')), '100.5');
      await tester.enterText(find.byKey(const ValueKey('trade-amount')), '120');
      await tapVisible(tester, find.byKey(const ValueKey('trade-record')));
      backend.dropResponseNext.add('POST /holdings/h1/trade');
      final submit = find.descendant(of: sheet, matching: find.widgetWithText(FilledButton, '加仓'));
      await tapVisible(tester, submit);

      expect(find.text('没等到服务器回应，不确定记上没有。再点一次也不会重复记。'), findsOneWidget);
      expect(sheet, findsOneWidget, reason: '表单留着，好让人再点一次');
      expect(backend.holdings['h1']!['quantityE4'], 11005000, reason: '其实已经落库了');

      await tapVisible(tester, submit);
      final sent = backend.requests('POST', '/holdings/h1/trade');
      expect(sent, hasLength(2));
      final ids = sent.map((r) => (jsonDecode(r.body) as Map)['clientId']).toSet();
      expect(ids, hasLength(1), reason: '重试沿用同一个 clientId');
      expect(backend.holdings['h1']!['quantityE4'], 11005000, reason: '服务端认出是重发，没再加一次');
      expect(find.byType(TradeSheet), findsNothing);
      expect(find.text('刚才那次其实已经记上了，没有重复记'), findsOneWidget);
      expect(find.text('1,100.5 份'), findsOneWidget);
    });

    testWidgets('手动改价：只发 priceE4', (tester) async {
      final backend = AssetsBackend(holdings: portfolio());
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/holdings/h2');

      await tapVisible(tester, find.widgetWithText(OutlinedButton, '改价'));
      await tester.enterText(find.byKey(const ValueKey('price-input')), '5200');
      await tester.tap(find.widgetWithText(FilledButton, '改好了'));
      await settle(tester);

      expect(backend.lastBody('PATCH', '/holdings/h2'), {'priceE4': 52000000});
      expect(find.text('¥5,200.00'), findsOneWidget);
    });

    testWidgets('下拉同步失败：页面上说出来并能重试', (tester) async {
      final backend = AssetsBackend(holdings: portfolio());
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/holdings/h1');

      backend.failNext['GET /changes'] = (503, 'down', '服务器挂了');
      await tester.fling(find.byType(ListView), const Offset(0, 400), 1000);
      await settle(tester, frames: 20);

      expect(tester.takeException(), isNull);
      expect(find.text('同步失败：服务器挂了'), findsOneWidget);

      await tapVisible(tester, find.text('重试'));
      expect(find.textContaining('同步失败'), findsNothing);
    });

    testWidgets('删除后退场那几帧还是原来的详情，不闪「已经不在了」', (tester) async {
      final backend = AssetsBackend(holdings: portfolio());
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=invest');
      await tapVisible(tester, find.text('招商中证白酒'));

      await tester.tap(find.byTooltip('删除'));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, '删掉'));
      var flashed = false;
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (find.text('这笔持仓已经不在了。').evaluate().isNotEmpty) flashed = true;
      }
      await settle(tester);

      expect(backend.requests('DELETE', '/holdings/h1'), hasLength(1));
      expect(flashed, isFalse);
      expect(find.text('招商中证白酒'), findsNothing);
      expect(find.text('总市值'), findsOneWidget);
    });

    testWidgets('已清仓：只看已实现盈亏，减仓按钮灰掉', (tester) async {
      await pumpAssetsAt(
        tester,
        bootAssets(AssetsBackend(holdings: portfolio())),
        '/assets/holdings/h4',
      );

      expect(find.text('已清仓'), findsOneWidget);
      expect(find.text('已实现盈亏'), findsWidgets);
      final sell = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '减仓'),
      );
      expect(sell.onPressed, isNull);
    });
  });

  group('三种宽度都不溢出', () {
    for (final size in kWidths) {
      final w = size.width.toInt();

      testWidgets('投资列表 @$w', (tester) async {
        await pumpAssetsAt(
          tester,
          bootAssets(AssetsBackend(holdings: portfolio())),
          '/assets?tab=invest',
          size: size,
        );
        expect(find.text('总市值'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('新建持仓表单 @$w', (tester) async {
        await pumpAssetsAt(
          tester,
          bootAssets(AssetsBackend()),
          '/assets/holdings/new',
          size: size,
        );
        await tester.drag(find.byType(ListView).first, const Offset(0, -2000));
        await settle(tester);
        expect(tester.takeException(), isNull);
      });

      testWidgets('持仓详情 + 减仓弹层 @$w', (tester) async {
        await pumpAssetsAt(
          tester,
          bootAssets(AssetsBackend(holdings: portfolio())),
          '/assets/holdings/h3',
          size: size,
        );
        await tapVisible(tester, find.widgetWithText(OutlinedButton, '减仓'));
        await tester.enterText(find.byKey(const ValueKey('trade-quantity')), '50');
        await tester.enterText(find.byKey(const ValueKey('trade-amount')), '80000');
        await tester.pump();
        expect(find.byKey(const ValueKey('trade-preview')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
