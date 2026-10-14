import 'package:famledger/app/providers.dart';
import 'package:famledger/app/theme.dart';
import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/data/local/secure_store.dart';
import 'package:famledger/data/models/models.dart';
import 'package:famledger/data/repos/ledger_repo.dart';
import 'package:famledger/data/repos/session_repo.dart';
import 'package:famledger/ui/add_tx/add_tx_page.dart';
import 'package:famledger/ui/funds/fund_form_page.dart';
import 'package:famledger/ui/funds/fund_progress.dart';
import 'package:famledger/ui/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'add_tx_test.dart' show FakeLedger, RecordingTxRepo, tapKeys;
import 'assets_harness.dart';

/// 财富板块与多币种：合计按币种分开（人民币、美元常驻，其他收起）、「换算」合成一个数、
/// 记一笔的跨币种转账、板块的每月固定进账规则。

/// 1 CNY = 0.149388 USD（服务端 rate_e6 口径）；1 CNY = 0.128 EUR。
const FxRates rates = FxRates(base: 'CNY', rates: {'USD': 149388, 'EUR': 128000});

Future<void> pumpTotal(
  WidgetTester tester,
  CurrencyAmounts amounts, {
  String? convertTo,
  FxRates fx = rates,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        fxRatesProvider.overrideWithValue(fx),
        displayCurrenciesProvider.overrideWithValue(const ['CNY', 'USD']),
        displayCurrencyOverrideProvider.overrideWith((ref) => convertTo),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(body: Center(child: CurrencyTotal(amounts, size: MoneySize.title))),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('CurrencyTotal：合计按币种分开', () {
    testWidgets('只有一种币就是一个数，和单币种时代一样', (tester) async {
      await pumpTotal(tester, const CurrencyAmounts({'CNY': 100000, 'USD': 0}));
      expect(find.text('¥1,000.00'), findsOneWidget);
      expect(find.byType(MoneyText), findsOneWidget);
      expect(find.byKey(const ValueKey('currency-more')), findsNothing);
    });

    testWidgets('人民币、美元常驻；其他外币收进「+N 种」，点开看全部', (tester) async {
      await pumpTotal(tester, const CurrencyAmounts({'EUR': 2000, 'USD': 5000, 'CNY': 100000}));
      expect(find.text('¥1,000.00'), findsOneWidget);
      expect(find.text(r'$50.00'), findsOneWidget);
      expect(find.text('€20.00'), findsNothing);
      expect(find.text('+1 种'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('currency-more')));
      await tester.pump();
      expect(find.text('€20.00'), findsOneWidget);
      expect(find.text('收起'), findsOneWidget);
    });

    testWidgets('只有非常驻的外币：直接显示，不收起', (tester) async {
      await pumpTotal(tester, const CurrencyAmounts({'EUR': 2000, 'JPY': 100000}));
      expect(find.text('€20.00'), findsOneWidget);
      expect(find.byKey(const ValueKey('currency-more')), findsNothing);
    });

    testWidgets('「换算」成美元：按今日汇率合成一个数', (tester) async {
      // ¥1,000.00 → $149.39；$50.00 原样；合计 $199.39。
      await pumpTotal(tester, const CurrencyAmounts({'CNY': 100000, 'USD': 5000}), convertTo: 'USD');
      expect(find.text(r'$199.39'), findsOneWidget);
      expect(find.text('¥1,000.00'), findsNothing);
    });

    testWidgets('换算时缺汇率：那部分不臆造，注明不含哪个币', (tester) async {
      await pumpTotal(tester, const CurrencyAmounts({'CNY': 100000, 'GBP': 500}), convertTo: 'CNY');
      expect(find.text('¥1,000.00'), findsOneWidget);
      expect(find.text('不含 GBP（缺汇率）'), findsOneWidget);
    });
  });

  group('板块进度那行字跟着「换算」走', () {
    Future<void> pumpBar(WidgetTester tester, {String? convertTo}) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            fxRatesProvider.overrideWithValue(rates),
            baseCurrencyProvider.overrideWithValue('CNY'),
            displayCurrencyOverrideProvider.overrideWith((ref) => convertTo),
          ],
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            home: const Scaffold(
              body: FundProgressBar(
                progress: FundProgress(balanceCents: 0, monthExpenseCents: 100000, monthIncomeCents: 0, budgetCents: 300000),
                color: Colors.teal,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('平时写基准币', (tester) async {
      await pumpBar(tester);
      expect(find.text('本月预算还剩 ¥2,000.00'), findsOneWidget);
    });

    testWidgets('换算成美元时折过去写', (tester) async {
      await pumpBar(tester, convertTo: 'USD');
      expect(find.text(r'本月预算还剩 $298.78'), findsOneWidget);
    });
  });

  group('总览按币种的模型', () {
    test('byCurrency、板块分币种余额；老服务端（只给折算后的数）整份当基准币', () {
      final o = StatsOverview.fromJson({
        'netWorthCents': 106694,
        'assetsCents': 106694,
        'liabilitiesCents': 0,
        'month': {'expenseCents': 0, 'incomeCents': 0},
        'fx': {'base': 'CNY', 'rates': {'USD': 149388}},
        'byCurrency': {
          'CNY': {'netWorthCents': 100000, 'cashCents': 100000, 'monthExpenseCents': 2500},
          'USD': {'netWorthCents': 1000, 'cashCents': 1000, 'debts': {'countedReceivableCents': 300}},
        },
        'funds': [
          {'fundId': 'f1', 'balanceCents': 6694, 'balances': {'USD': 1000}},
          {'fundId': 'f2', 'balanceCents': 500},
        ],
      });
      expect(o.amountsBy((b) => b.netWorthCents), const CurrencyAmounts({'CNY': 100000, 'USD': 1000}));
      expect(o.amountsBy((b) => b.debtsNetCents), const CurrencyAmounts({'USD': 300}));
      expect(o.fundBalances('f1'), const CurrencyAmounts({'USD': 1000}));
      expect(o.fundBalances('f2'), const CurrencyAmounts({'CNY': 500}), reason: '老服务端只给一个数：当基准币');

      final legacy = StatsOverview.fromJson({
        'netWorthCents': 5000,
        'assetsCents': 5000,
        'liabilitiesCents': 0,
        'cashCents': 5000,
        'month': {'expenseCents': 1200},
      });
      expect(legacy.amountsBy((b) => b.netWorthCents), const CurrencyAmounts({'CNY': 5000}));
      expect(legacy.amountsBy((b) => b.monthExpenseCents), const CurrencyAmounts({'CNY': 1200}));
    });

    test('CurrencyAmounts：加减、换算、缺汇率', () {
      const a = CurrencyAmounts({'CNY': 100000, 'USD': 5000});
      expect(a - const CurrencyAmounts({'USD': 5000}), const CurrencyAmounts({'CNY': 100000}));
      final c = a.convert(rates, 'USD');
      expect(c.cents, 14939 + 5000);
      expect(c.missing, isEmpty);
      expect(const CurrencyAmounts({'GBP': 1}).convert(rates, 'CNY').missing, ['GBP']);
      expect(formatAmounts(a), r'¥1,000.00 + $50.00');
      expect(formatAmounts(const CurrencyAmounts()), '¥0.00');
    });
  });

  group('记一笔：跨币种转账', () {
    const data = LedgerData(
      funds: [Fund(id: 'f1', name: '家庭公共', isDefault: true)],
      accounts: [
        Account(id: 'a1', name: '招行', kind: 'bank'),
        Account(id: 'a2', name: '微信', kind: 'wechat'),
        Account(id: 'u1', name: '美元户', kind: 'bank', currency: 'USD'),
      ],
      categories: [Category(id: 'c1', name: '餐饮', icon: 'restaurant')],
    );

    Future<RecordingTxRepo> pump(WidgetTester tester, {FxRates fx = rates}) async {
      tester.view.physicalSize = const Size(390, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = RecordingTxRepo();
      final router = GoRouter(
        initialLocation: '/add',
        routes: [
          GoRoute(path: '/add', builder: (context, state) => const AddTxPage()),
          GoRoute(path: '/home', builder: (context, state) => const Scaffold(body: Text('回到首页'))),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localStoreProvider.overrideWithValue(MemoryLocalStore()),
            secureStoreProvider.overrideWithValue(MemorySecureStore()),
            sessionRepoProvider.overrideWithValue(SessionRepo(secure: MemorySecureStore())),
            ledgerProvider.overrideWith(() => FakeLedger(data)),
            transactionsRepoProvider.overrideWithValue(repo),
            fxRatesProvider.overrideWithValue(fx),
          ],
          child: MaterialApp.router(theme: buildTheme(Brightness.light), routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('转账·拨款'));
      await tester.pumpAndSettle();
      await tapKeys(tester, '100');
      return repo;
    }

    Future<void> pickAccounts(WidgetTester tester, String from, String to) async {
      await tester.tap(find.byKey(ValueKey('account-$from')));
      await tester.pump();
      await tester.tap(find.byKey(ValueKey('to-account-$to')));
      await tester.pump();
    }

    testWidgets('美元户转人民币户：出「到账金额」，空着按今日汇率；转出币种跟账户', (tester) async {
      final repo = await pump(tester);
      expect(find.byKey(const ValueKey('to-amount')), findsNothing);
      await pickAccounts(tester, 'u1', 'a1');
      expect(find.byKey(const ValueKey('to-amount')), findsOneWidget);
      expect(find.text('约 669.40（按今日汇率）'), findsOneWidget, reason: r'$100 按 1 CNY = 0.149388 USD 折成 ¥669.40');
      await tester.tap(find.byKey(const ValueKey('save-tx')));
      await tester.pumpAndSettle();
      final d = repo.lastDraft!;
      expect(d.currency, 'USD');
      expect(d.amountCents, 10000);
      expect(d.toAmountCents, 66940);
      expect(d.toCurrency, 'CNY');
    });

    testWidgets('到账金额填了就按填的（银行实际给的）', (tester) async {
      final repo = await pump(tester);
      await pickAccounts(tester, 'u1', 'a1');
      await tester.enterText(find.byKey(const ValueKey('to-amount')), '650');
      await tester.tap(find.byKey(const ValueKey('save-tx')));
      await tester.pumpAndSettle();
      expect(repo.lastDraft!.toAmountCents, 65000);
    });

    testWidgets('同币种不出这一栏；没有汇率又没填就说清楚', (tester) async {
      final repo = await pump(tester, fx: const FxRates());
      await pickAccounts(tester, 'a1', 'a2');
      expect(find.byKey(const ValueKey('to-amount')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('account-u1')));
      await tester.pump();
      expect(find.text('还没有汇率，填一下到账多少'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('save-tx')));
      await tester.pumpAndSettle();
      expect(repo.lastDraft, isNull);
      expect(find.text('两边币种不同，还没有汇率：填一下到账多少'), findsWidgets);
    });
  });

  group('板块的每月固定进账', () {
    Future<AssetsBackend> pumpForm(WidgetTester tester) async {
      final backend = AssetsBackend(
        accounts: const [
          {'id': 'bank', 'name': '工行卡', 'kind': 'bank', 'sortOrder': 0},
          {'id': 'usd', 'name': '美元户', 'kind': 'bank', 'currency': 'USD', 'sortOrder': 1},
        ],
      );
      final container = bootAssets(backend);
      addTearDown(container.dispose);
      tester.view.physicalSize = const Size(400, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final router = GoRouter(
        initialLocation: '/funds/new',
        routes: [
          GoRoute(path: '/funds', builder: (context, state) => const Scaffold(body: Text('财富页'))),
          GoRoute(path: '/funds/new', builder: (context, state) => const FundFormPage()),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(theme: buildTheme(Brightness.light), routerConfig: router),
        ),
      );
      await settle(tester);
      return backend;
    }

    testWidgets('打开开关：填金额、选账户、几号；请求带上整条规则；说清别再手记', (tester) async {
      final backend = await pumpForm(tester);
      await tester.enterText(find.widgetWithText(TextField, '例如「家庭公共」'), '工资结余');
      expect(find.byKey(const ValueKey('fund-income-amount')), findsNothing, reason: '没开就不占地方');
      await tapVisible(tester, find.byKey(const ValueKey('fund-income-switch')));
      expect(find.byKey(const ValueKey('fund-income-note')), findsOneWidget);

      await tapVisible(tester, find.widgetWithText(FilledButton, '建好了'));
      expect(find.text('每月进多少？例如 15000'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('fund-income-amount')), '15000');
      await tapVisible(tester, find.widgetWithText(FilledButton, '建好了'));
      expect(find.text('选一下工资进哪个账户'), findsOneWidget);

      await tapVisible(tester, find.byKey(const ValueKey('fund-income-account-usd')));
      expect(find.text(r'$ '), findsWidgets, reason: '进美元户：金额前缀跟着变成美元');
      await tapVisible(tester, find.widgetWithText(FilledButton, '建好了'));

      final body = backend.lastBody('POST', '/funds');
      expect(body['name'], '工资结余');
      expect(body['monthlyIncomeCents'], 1500000);
      expect(body['incomeAccountId'], 'usd');
      expect(body['incomeDay'], 10);
      expect(body['incomeStartMonth'], matches(RegExp(r'^\d{4}-\d{2}$')));
      expect(body.containsKey('incomeCategoryId'), isTrue, reason: '没选 = null，服务端用「工资」');
    });

    testWidgets('不开开关：monthlyIncomeCents 发 null，不带规则', (tester) async {
      final backend = await pumpForm(tester);
      await tester.enterText(find.widgetWithText(TextField, '例如「家庭公共」'), '旅行');
      await tapVisible(tester, find.widgetWithText(FilledButton, '建好了'));
      final body = backend.lastBody('POST', '/funds');
      expect(body['monthlyIncomeCents'], isNull);
      expect(body.containsKey('incomeAccountId'), isFalse);
    });
  });
}
