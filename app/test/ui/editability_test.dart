import 'package:famledger/app/providers.dart';
import 'package:famledger/app/theme.dart';
import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/data/local/secure_store.dart';
import 'package:famledger/data/models/models.dart';
import 'package:famledger/data/repos/ledger_repo.dart';
import 'package:famledger/data/repos/session_repo.dart';
import 'package:famledger/ui/funds/allocate_sheet.dart';
import 'package:famledger/ui/funds/fund_calibrate_sheet.dart';
import 'package:famledger/ui/transactions/tx_detail_page.dart';
import 'package:famledger/ui/transactions/tx_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'add_tx_test.dart' show RecordingTxRepo;
import 'assets_debts_test.dart' show withDebts;
import 'assets_harness.dart';
import 'tx_tile_test.dart' show DetailRepo, FakeLedger, tx;

/// 手动微调：算出来的数也能直接改。
/// 板块余额校准、拨款能拨进来；理财直接改份额 / 收益 / 结清；债务改总额 / 还剩多少（成员不丢）、备忘行能改能删；
/// 流水详情跨币种能改到账金额、原来选的归档账户还在候选里。

Finder byKeyPrefix(String prefix) => find.byWidgetPredicate((w) {
  final k = w.key;
  return k is ValueKey<String> && k.value.startsWith(prefix);
});

/// 挂一个按钮，点了开 [open]（弹层要有个能 push 的上下文）。
Future<void> pumpOpener(
  WidgetTester tester,
  ProviderContainer container,
  Future<void> Function(BuildContext context) open,
) async {
  addTearDown(container.dispose);
  tester.view.physicalSize = const Size(400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(onPressed: () => open(context), child: const Text('打开')),
            ),
          ),
        ),
      ),
    ),
  );
  await settle(tester);
  await tester.tap(find.text('打开'));
  await settle(tester);
}

void main() {
  group('板块', () {
    testWidgets('校准余额：只发改了的币种（现在实际有多少）', (tester) async {
      final backend = AssetsBackend();
      backend.fundRows['f1'] = {'id': 'f1', 'name': '家庭公共', 'kind': 'shared', 'color': '#c36a4f'};
      await pumpOpener(
        tester,
        bootAssets(backend),
        (context) => showFundCalibrateSheet(
          context,
          fund: const Fund(id: 'f1', name: '家庭公共'),
          balances: const CurrencyAmounts({'CNY': 100000, 'USD': 5000}),
        ),
      );
      expect(find.byKey(const ValueKey('calibrate-CNY')), findsOneWidget);
      expect(find.byKey(const ValueKey('calibrate-USD')), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('calibrate-CNY')), '1200');
      await tapVisible(tester, find.byKey(const ValueKey('calibrate-save')));

      expect(backend.lastBody('PATCH', '/funds/f1'), {
        'currentBalances': {'CNY': 120000},
      });
    });

    testWidgets('校准余额：欠着可以写负数；填错了行内说清', (tester) async {
      final backend = AssetsBackend();
      backend.fundRows['f1'] = {'id': 'f1', 'name': '家庭公共', 'kind': 'shared', 'color': '#c36a4f'};
      await pumpOpener(
        tester,
        bootAssets(backend),
        (context) => showFundCalibrateSheet(context, fund: const Fund(id: 'f1', name: '家庭公共'), balances: const CurrencyAmounts()),
      );
      await tester.enterText(find.byKey(const ValueKey('calibrate-CNY')), '一百');
      await tapVisible(tester, find.byKey(const ValueKey('calibrate-save')));
      expect(find.textContaining('金额填得不对'), findsOneWidget);
      expect(backend.requests('PATCH', '/funds/f1'), isEmpty);

      await tester.enterText(find.byKey(const ValueKey('calibrate-CNY')), '-35.5');
      await tapVisible(tester, find.byKey(const ValueKey('calibrate-save')));
      expect(backend.lastBody('PATCH', '/funds/f1'), {
        'currentBalances': {'CNY': -3550},
      });
    });

    testWidgets('拨款能「拨进来」：从对方板块拨到这个板块，币种、日子跟着选的', (tester) async {
      final repo = RecordingTxRepo();
      const from = Fund(id: 'f1', name: '家庭公共');
      const other = Fund(id: 'f2', name: '旅行');
      final container = ProviderContainer(
        overrides: [
          localStoreProvider.overrideWithValue(MemoryLocalStore()),
          secureStoreProvider.overrideWithValue(MemorySecureStore()),
          sessionRepoProvider.overrideWithValue(SessionRepo(secure: MemorySecureStore())),
          transactionsRepoProvider.overrideWithValue(repo),
        ],
      );
      await pumpOpener(tester, container, (context) => showAllocateSheet(context, from: from, funds: const [from, other]));

      await tester.tap(find.text('拨进来').first);
      await settle(tester);
      expect(find.text('从哪个板块拨过来'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('allocate-amount')), '300');
      await tapVisible(tester, find.text('旅行'));
      await tapVisible(tester, find.widgetWithText(FilledButton, '拨进来'));

      final draft = repo.lastDraft!;
      expect(draft.type, Transaction.typeTransfer);
      expect(draft.fundId, 'f2', reason: '从对方拨出');
      expect(draft.toFundId, 'f1', reason: '拨进这个板块');
      expect(draft.amountCents, 30000);
      expect(draft.currency, 'CNY');
    });
  });

  group('理财', () {
    testWidgets('编辑页能直接改份额、已实现收益（亏了写负数）；没改的成本不发', (tester) async {
      final backend = AssetsBackend(holdings: [holdingJson('h1')]);
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/holdings/h1/edit');

      expect(find.text('数额（记错了直接改）'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('holding-quantity')), '1200');
      await tester.enterText(find.byKey(const ValueKey('holding-realized')), '-50');
      await tapVisible(tester, find.widgetWithText(FilledButton, '保存'));

      final body = backend.lastBody('PATCH', '/holdings/h1');
      expect(body['quantityE4'], 12000000);
      expect(body['realizedCents'], -5000);
      expect(body.containsKey('costCents'), isFalse, reason: '成本没动就不发');
    });

    testWidgets('活期：标成已结清 = 份额置 0；当前金额也能改', (tester) async {
      final backend = AssetsBackend(holdings: [
        {
          ...holdingJson('h6', name: '余额宝', code: null, market: 'other', qty: 10000, cost: 1000000, price: null, prev: null, source: 'manual', accountId: null),
          'kind': 'demand',
          'valueCents': 1010000,
          'valueOn': '2026-09-01',
        },
      ]);
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/holdings/h6/edit');

      await tester.enterText(find.byKey(const ValueKey('holding-value')), '10123.45');
      await tapVisible(tester, find.byKey(const ValueKey('holding-cleared')));
      await tapVisible(tester, find.widgetWithText(FilledButton, '保存'));

      final body = backend.lastBody('PATCH', '/holdings/h6');
      expect(body['quantityE4'], 0);
      expect(body['valueCents'], 1012345);
    });
  });

  group('债务', () {
    testWidgets('编辑：改总额时还剩多少跟着挪；成员原样带回去（以前会被清掉）', (tester) async {
      final backend = await withDebts(tester);
      backend.debts['d2']!['memberId'] = 'm1';
      await pumpAssetsAt(tester, bootAssets(backend, session: await sessionAs('admin')), '/assets/debts/d2/edit');

      final remaining = find.byKey(const ValueKey('debt-remaining'));
      expect(tester.widget<TextField>(remaining).controller!.text, '2000.00');
      await tester.enterText(find.byKey(const ValueKey('debt-amount')), '2500');
      await tester.pump();
      expect(tester.widget<TextField>(remaining).controller!.text, '2500.00', reason: '起始记错了，两个数一起错');
      await tapVisible(tester, find.widgetWithText(FilledButton, '保存'));

      final body = backend.lastBody('PATCH', '/debts/d2');
      expect(body['memberId'], 'm1');
      expect(body['amountCents'], 250000);
      expect(body['remainingCents'], 250000);
      expect(body.containsKey('direction'), isFalse);
      expect(body.containsKey('currency'), isFalse);
    });

    testWidgets('编辑：只改还剩多少 = 校准，不动总额', (tester) async {
      final backend = await withDebts(tester);
      await pumpAssetsAt(tester, bootAssets(backend, session: await sessionAs('admin')), '/assets/debts/d2/edit');

      await tester.enterText(find.byKey(const ValueKey('debt-remaining')), '1500');
      await tapVisible(tester, find.widgetWithText(FilledButton, '保存'));

      final body = backend.lastBody('PATCH', '/debts/d2');
      expect(body['remainingCents'], 150000);
      expect(body.containsKey('amountCents'), isFalse);
    });

    testWidgets('备忘行点开能改金额、能删', (tester) async {
      final backend = await withDebts(tester);
      await pumpAssetsAt(tester, bootAssets(backend, session: await sessionAs('admin')), '/assets/debts/d2');

      await tapVisible(tester, byKeyPrefix('debt-memo-').first);
      await tester.enterText(find.byKey(const ValueKey('memo-amount')), '1800');
      await tapVisible(tester, find.byKey(const ValueKey('memo-save')));
      final body = backend.lastBody('PATCH', '/debts/d2/memo/0');
      expect(body['amountCents'], 180000);
      expect((backend.debts['d2']!['memoLog'] as List).first['amountCents'], -180000, reason: '借入：方向跟着原来那行');

      await tapVisible(tester, byKeyPrefix('debt-memo-').first);
      await tapVisible(tester, find.byKey(const ValueKey('memo-delete')));
      await tapVisible(tester, find.byKey(const ValueKey('memo-delete-confirm')));
      expect(backend.requests('DELETE', '/debts/d2/memo/0'), hasLength(1));
    });
  });

  group('流水详情', () {
    final usd = const Account(id: 'usd', name: '美元户', kind: 'bank', currency: 'USD');
    final cny = const Account(id: 'cny', name: '招行卡', kind: 'bank');
    final archived = const Account(id: 'old', name: '旧卡', kind: 'bank', archived: true);
    final data = LedgerData(
      funds: const [Fund(id: 'f1', name: '家庭公共', color: '#c36a4f')],
      categories: const [Category(id: 'c1', name: '餐饮', icon: 'restaurant')],
      accounts: [usd, cny, archived],
    );

    Future<void> pumpDetail(WidgetTester tester, Transaction detail, DetailRepo repo) async {
      tester.view.physicalSize = const Size(390, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final router = GoRouter(
        initialLocation: '/detail',
        routes: [GoRoute(path: '/detail', builder: (context, state) => const TxDetailPage('t1'))],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localStoreProvider.overrideWithValue(MemoryLocalStore()),
            secureStoreProvider.overrideWithValue(MemorySecureStore()),
            sessionRepoProvider.overrideWithValue(SessionRepo(secure: MemorySecureStore())),
            ledgerProvider.overrideWith(() => FakeLedger(data)),
            txDetailProvider.overrideWith((ref, id) async => detail),
            transactionsRepoProvider.overrideWithValue(repo),
          ],
          child: MaterialApp.router(theme: buildTheme(Brightness.light), routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('跨币种转账：到账金额能改，保存时带上', (tester) async {
      final repo = DetailRepo();
      final transfer = Transaction(
        id: 't1',
        clientId: 'c-1',
        type: Transaction.typeTransfer,
        amountCents: 10000,
        currency: 'USD',
        toAmountCents: 66940,
        toCurrency: 'CNY',
        occurredAt: DateTime(2026, 9, 12, 12, 30),
        accountId: 'usd',
        toAccountId: 'cny',
      );
      await pumpDetail(tester, transfer, repo);

      final field = find.byKey(const ValueKey('tx-to-amount'));
      expect(tester.widget<TextField>(field).controller!.text, '669.40');
      await tester.enterText(field, '670.12');
      await tapVisible(tester, find.text('保存修改'));

      expect(repo.lastPatch!['toAmountCents'], 67012);
    });

    testWidgets('原来选的是归档账户：候选里还在，改走了能选回来', (tester) async {
      final repo = DetailRepo();
      await pumpDetail(tester, tx().copyWith(accountId: 'old'), repo);

      await tapVisible(tester, find.text('账户'));
      expect(find.text('旧卡'), findsWidgets);
      expect(find.text('招行卡'), findsWidgets);
    });
  });
}
