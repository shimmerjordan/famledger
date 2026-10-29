import 'package:famledger/app/theme.dart';
import 'package:famledger/core/money.dart';
import 'package:famledger/data/models/models.dart';
import 'package:famledger/ui/transactions/tx_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'assets_debts_test.dart' show moveSubmit, withDebts;
import 'assets_harness.dart';

/// 债务「关联已有流水」：借出 / 收回 / 借入 / 还款的钱已经被自动记账或导入记成支出 / 收入时，
/// 建债务、收回 / 再借、流水详情都能直接选那笔，服务端把它改成转账，账户不扣两次。

Map<String, dynamic> txJson(
  String id, {
  String type = 'expense',
  int amountCents = 500000,
  String? accountId = 'bank',
  String merchant = '转账给张三',
  String occurredAt = '2026-09-12T12:30:00+08:00',
}) => {
  'id': id,
  'clientId': 'c-$id',
  'type': type,
  'amountCents': amountCents,
  'currency': 'CNY',
  'occurredAt': occurredAt,
  'accountId': accountId,
  'toAccountId': type == 'transfer' ? 'acct-x' : null,
  'fundId': 'f1',
  'categoryId': type == 'transfer' ? null : 'c1',
  'merchant': merchant,
  'note': '',
  'tags': <String>[],
  'source': 'notification',
  'status': 'confirmed',
};

Finder amountField(String key) => find.byKey(ValueKey(key));

Future<void> pumpTxDetail(WidgetTester tester, AssetsBackend backend, String id) async {
  final container = bootAssets(backend);
  addTearDown(container.dispose);
  tester.view.physicalSize = const Size(400, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    initialLocation: '/transactions/$id',
    routes: [
      GoRoute(path: '/transactions/:id', builder: (context, state) => TxDetailPage(state.pathParameters['id']!)),
      GoRoute(
        path: '/assets/debts/new',
        builder: (context, state) => Scaffold(body: Text('新债务 ${state.uri.queryParameters['txId']}')),
      ),
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
}

void main() {
  group('债务表单', () {
    testWidgets('记一笔借出：勾「已经记过流水了」从最近支出里选一笔，金额锁定；提交带 transactionId，那笔变成转账', (tester) async {
      final backend = AssetsBackend();
      backend.transactions.addAll([
        txJson('tx-1'),
        txJson('tx-2', type: 'income', amountCents: 300000, merchant: '老王转账'),
        {...txJson('tx-3', merchant: '待确认的'), 'status': 'pending'},
      ]);
      await pumpAssetsAt(tester, bootAssets(backend, session: await sessionAs('admin')), '/assets/debts/new');

      await tester.enterText(find.byKey(const ValueKey('debt-counterparty')), '张三');
      await tapVisible(tester, find.byKey(const ValueKey('debt-link-existing')));
      expect(find.byKey(const ValueKey('debt-account-bank')), findsNothing, reason: '选了已记过流水就不用选账户');
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      expect(find.text('选那笔流水，或关掉「这笔钱已经记过流水了」'), findsOneWidget);

      await tapVisible(tester, find.byKey(const ValueKey('debt-pick-tx')));
      expect(find.byKey(const ValueKey('pick-tx-tx-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('pick-tx-tx-2')), findsNothing, reason: '借出是花出去的钱，只列支出');
      expect(find.byKey(const ValueKey('pick-tx-tx-3')), findsNothing, reason: '待确认的不算进余额，不能当往来');
      await tapVisible(tester, find.byKey(const ValueKey('pick-tx-tx-1')));

      expect(find.byKey(const ValueKey('debt-linked-tx')), findsOneWidget);
      final amount = tester.widget<TextField>(amountField('debt-amount'));
      expect(amount.controller!.text, Money.input(500000));
      expect(amount.readOnly, isTrue);

      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      final body = backend.lastBody('POST', '/debts');
      expect(body['recordTransaction'], {'transactionId': 'tx-1'});
      expect(body['amountCents'], 500000);
      expect(body['direction'], 'lend');
      final linked = backend.transactions.firstWhere((t) => t['id'] == 'tx-1');
      expect(linked['type'], 'transfer');
      expect(linked['accountId'], 'bank');
      expect(linked['toAccountId'], 'acct-d1');
      expect(find.text('记好了，那笔流水变成了转账，账户不会扣两次'), findsOneWidget);
    });

    testWidgets('从流水详情「记成一笔新债务」进来：按那笔预填金额、日期、方向，直接关联', (tester) async {
      final backend = AssetsBackend();
      backend.transactions.add(txJson('tx-1', type: 'income', amountCents: 200000, merchant: '李四转来'));
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/debts/new?txId=tx-1');
      await settle(tester);

      expect(find.byKey(const ValueKey('debt-linked-tx')), findsOneWidget);
      expect(tester.widget<TextField>(amountField('debt-amount')).controller!.text, Money.input(200000));
      final direction = tester.widget<SegmentedButton<String>>(find.byKey(const ValueKey('debt-direction')));
      expect(direction.selected, {Debt.borrow}, reason: '收进来的钱 = 我欠别人');

      await tester.enterText(find.byKey(const ValueKey('debt-counterparty')), '李四');
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      final body = backend.lastBody('POST', '/debts');
      expect(body['recordTransaction'], {'transactionId': 'tx-1'});
      expect(body['direction'], 'borrow');
      expect(body['startedOn'], '2026-09-12');
    });
  });

  group('收回 / 再借', () {
    testWidgets('收回：勾「已经记过流水了」选一笔收入，提交带顶层 transactionId、不带 accountId；金额前缀跟币种', (tester) async {
      final backend = await withDebts(tester);
      backend.transactions.add(txJson('tx-3', type: 'income', amountCents: 200000, merchant: '张三还钱'));
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/debts/d1');

      await tapVisible(tester, find.byKey(const ValueKey('debt-settle')));
      expect(tester.widget<TextField>(amountField('debt-move-amount')).decoration!.prefixText, '¥ ');
      await tapVisible(tester, find.byKey(const ValueKey('debt-move-link')));
      await tapVisible(tester, find.byKey(const ValueKey('debt-move-pick-tx')));
      await tapVisible(tester, find.byKey(const ValueKey('pick-tx-tx-3')));

      expect(find.byKey(const ValueKey('debt-move-linked-tx')), findsOneWidget);
      expect(tester.widget<TextField>(amountField('debt-move-amount')).controller!.text, Money.input(200000));
      await tapVisible(tester, moveSubmit);

      final body = backend.lastBody('POST', '/debts/d1/settle');
      expect(body['action'], 'settle');
      expect(body['transactionId'], 'tx-3');
      expect(body.containsKey('accountId'), isFalse);
      expect(body['amountCents'], 200000);
      final linked = backend.transactions.firstWhere((t) => t['id'] == 'tx-3');
      expect(linked['type'], 'transfer');
      expect(linked['accountId'], 'acct-d1', reason: '收回：内部账户 → 真账户');
      expect(linked['toAccountId'], 'bank');
    });
  });

  group('流水详情的「债务」一段', () {
    testWidgets('支出能关联到已有债务：借出的「再借给」、借入的「还」、人情按方向；点了按这笔的金额日期记', (tester) async {
      final backend = await withDebts(tester);
      backend.transactions.add(txJson('tx-1', amountCents: 150000));
      await pumpTxDetail(tester, backend, 'tx-1');

      await tapVisible(tester, find.byKey(const ValueKey('tx-link-debt')));
      expect(find.text('再借给 张三'), findsOneWidget);
      expect(find.text('还 李四'), findsOneWidget, reason: '欠李四 2000，够还 1500');
      expect(find.text('又随了 王五 的礼'), findsOneWidget);

      await tapVisible(tester, find.byKey(const ValueKey('link-debt-d2')));
      final body = backend.lastBody('POST', '/debts/d2/settle');
      expect(body['action'], 'settle');
      expect(body['amountCents'], 150000);
      expect(body['occurredOn'], '2026-09-12');
      expect(body['transactionId'], 'tx-1');
      expect(body['clientId'], isNotEmpty);
      expect(find.text('已记成「还 李四」，这笔流水变成了转账'), findsOneWidget);
      // 变成转账后这一段就没了。
      await settle(tester);
      expect(find.byKey(const ValueKey('tx-link-debt')), findsNothing);
    });

    testWidgets('还钱 / 收回要还欠着这么多：欠的不够就不列；「记成一笔新债务」带着这笔的 id', (tester) async {
      final backend = await withDebts(tester);
      backend.transactions.add(txJson('tx-1', amountCents: 250000));
      await pumpTxDetail(tester, backend, 'tx-1');

      await tapVisible(tester, find.byKey(const ValueKey('tx-link-debt')));
      expect(find.text('再借给 张三'), findsOneWidget);
      expect(find.text('还 李四'), findsNothing, reason: '只欠 2000，还不了 2500');
      await tester.tapAt(const Offset(200, 20));
      await settle(tester);

      await tapVisible(tester, find.byKey(const ValueKey('tx-new-debt')));
      expect(find.text('新债务 tx-1'), findsOneWidget);
    });

    testWidgets('待确认的不出这一段（余额只算已确认的，关联了债务也不会动）', (tester) async {
      final backend = await withDebts(tester);
      backend.transactions.add({...txJson('tx-p', amountCents: 150000), 'status': 'pending'});
      await pumpTxDetail(tester, backend, 'tx-p');
      expect(find.byKey(const ValueKey('tx-link-debt')), findsNothing);
      expect(find.byKey(const ValueKey('tx-new-debt')), findsNothing);
    });

    testWidgets('已经作为人情关联过的：这一段变成一句说明，不再给按钮', (tester) async {
      final backend = await withDebts(tester);
      backend.transactions.add(txJson('tx-g', amountCents: 80000, merchant: '王五婚礼随礼'));
      backend.debts['d3']!['memoLog'] = [
        {'on': '2026-05-01', 'amountCents': 80000, 'note': '起始', 'recorded': true, 'transactionId': 'tx-g'},
      ];
      await pumpTxDetail(tester, backend, 'tx-g');
      expect(find.byKey(const ValueKey('tx-link-debt')), findsNothing);
      expect(find.byKey(const ValueKey('tx-new-debt')), findsNothing);
      expect(find.byKey(const ValueKey('tx-favor-linked')), findsOneWidget);
      expect(find.textContaining('人情「王五」'), findsOneWidget);
    });

    testWidgets('转账不出这一段', (tester) async {
      final backend = await withDebts(tester);
      backend.transactions.add(txJson('tx-9', type: 'transfer'));
      await pumpTxDetail(tester, backend, 'tx-9');

      expect(find.byKey(const ValueKey('tx-link-debt')), findsNothing);
      expect(find.byKey(const ValueKey('tx-new-debt')), findsNothing);
    });
  });
}
