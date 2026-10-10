import 'dart:convert';

import 'package:famledger/app/providers.dart';
import 'package:famledger/data/models/models.dart';
import 'package:famledger/data/repos/ledger_repo.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assets_harness.dart';

/// 借给张三 5000（从工行卡出）、欠李四 2000（不记流水）、随王五 800 的礼（人情，不计入）。
Future<AssetsBackend> withDebts(WidgetTester tester) async {
  final backend = AssetsBackend();
  Future<void> add(Map<String, dynamic> body) async {
    final res = await backend.client.post(
      Uri.parse('https://x.dev/api/v1/debts'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode(body),
    );
    expect(res.statusCode, 201);
  }

  await add({'direction': 'lend', 'kind': 'loan', 'counterparty': '张三', 'amountCents': 500000, 'startedOn': '2026-09-01', 'dueOn': '2026-12-31', 'recordTransaction': {'accountId': 'bank'}});
  await add({'direction': 'borrow', 'kind': 'credit', 'counterparty': '李四', 'amountCents': 200000, 'startedOn': '2026-08-01', 'dueOn': '2026-09-01'});
  await add({'direction': 'lend', 'kind': 'favor', 'counterparty': '王五', 'amountCents': 80000, 'startedOn': '2026-05-01', 'counted': false});
  return backend;
}

Finder debtTile(String id) => find.byKey(ValueKey('debt-$id'));

/// 弹层底下的提交按钮（详情页上也有一个同名的「收回 / 还钱」）。
final Finder moveSubmit = find.descendant(
  of: find.byKey(const ValueKey('debt-move-submit')),
  matching: find.byType(FilledButton),
);

void main() {
  group('债务段', () {
    testWidgets('一笔都没有：说清能记什么，给「记一笔债务」', (tester) async {
      await pumpAssetsAt(tester, bootAssets(AssetsBackend()), '/assets?tab=debts');
      expect(find.text('还没有债务'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '记一笔债务'), findsOneWidget);
    });

    testWidgets('分三组：别人欠我、我欠别人、人情；净额只算计入的；逾期标出来', (tester) async {
      final backend = await withDebts(tester);
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=debts');

      expect(find.text('别人欠我'), findsWidgets);
      expect(find.text('我欠别人'), findsWidgets);
      expect(find.text('人情'), findsWidgets);
      // 净额 = 5000 − 2000（人情不计）
      expect(find.descendant(of: find.byKey(const ValueKey('debts-summary')), matching: find.text('+¥3,000.00')), findsOneWidget);
      expect(find.text('别人欠我 ¥5,800.00 · 我欠别人 ¥2,000.00'), findsOneWidget);
      expect(find.descendant(of: debtTile('d1'), matching: find.text('¥5,000.00')), findsOneWidget);
      expect(find.descendant(of: debtTile('d1'), matching: find.text('借款 · 借出 ¥5,000.00 · 12月31日到期')), findsOneWidget);
      // 李四 9/1 该还，今天 9/23：逾期 22 天
      expect(find.descendant(of: debtTile('d2'), matching: find.text('逾期')), findsOneWidget);
      expect(find.descendant(of: debtTile('d3'), matching: find.text('人情 · 随了 ¥800.00')), findsOneWidget);
    });

    testWidgets('净资产条多一段「债务」，只算计入的', (tester) async {
      final backend = await withDebts(tester);
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=debts');
      final line = tester.widget<Text>(find.byKey(const ValueKey('net-worth-breakdown'))).data!;
      expect(line, contains('债务 +¥3,000.00'));
      // 借出去的 5000 从工行卡出了：现金流 1 万 − 5000
      expect(line, startsWith('现金流 ¥5,000.00'));
    });

    testWidgets('记一笔借出：从工行卡出，记转账；请求里带方向、类型、对方、账户', (tester) async {
      final backend = AssetsBackend();
      await pumpAssetsAt(tester, bootAssets(backend, session: await sessionAs('admin')), '/assets/debts/new');

      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      expect(find.text('对方是谁？例如「张三」「小王」'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('debt-counterparty')), '张三');
      await tester.enterText(find.byKey(const ValueKey('debt-amount')), '5000');
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      expect(find.text('选一个账户，或关掉「同时记一笔」'), findsOneWidget);
      expect(find.text('钱从哪个账户借出去'), findsOneWidget);

      await tapVisible(tester, find.byKey(const ValueKey('debt-account-bank')));
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));

      final body = backend.lastBody('POST', '/debts');
      expect(body['direction'], 'lend');
      expect(body['kind'], 'loan');
      expect(body['counterparty'], '张三');
      expect(body['amountCents'], 500000);
      expect(body['counted'], isTrue);
      expect(body['recordTransaction'], {'accountId': 'bank'});
      expect(backend.debts, hasLength(1));
    });

    testWidgets('人情：计入净资产默认关；记账说的是随礼支出；改方向后说收礼', (tester) async {
      final backend = AssetsBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/debts/new');
      await tapVisible(tester, find.byKey(const ValueKey('debt-kind-favor')));
      expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('debt-counted'))).value, isFalse);
      expect(find.text('礼金从哪个账户出（记一笔人情支出）'), findsOneWidget);
      expect(find.text('我随出去的'), findsOneWidget);
      await tapVisible(tester, find.text('我收下的'));
      expect(find.text('收的礼进了哪个账户（记一笔人情收入）'), findsOneWidget);

      // 不记流水：旧账只记个数
      await tester.enterText(find.byKey(const ValueKey('debt-counterparty')), '王五');
      await tester.enterText(find.byKey(const ValueKey('debt-amount')), '800');
      await tapVisible(tester, find.byKey(const ValueKey('debt-record')));
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      final body = backend.lastBody('POST', '/debts');
      expect(body['kind'], 'favor');
      expect(body['direction'], 'borrow');
      expect(body['counted'], isFalse);
      expect(body.containsKey('recordTransaction'), isFalse);
    });

    testWidgets('详情：还剩多少、收回一部分（先填好还剩的数）、收多了说最多多少；备忘进往来', (tester) async {
      final backend = await withDebts(tester);
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/debts/d1');

      expect(find.text('还剩'), findsOneWidget);
      expect(find.text('¥5,000.00'), findsWidgets);
      await tapVisible(tester, find.byKey(const ValueKey('debt-settle')));
      final amount = find.byKey(const ValueKey('debt-move-amount'));
      expect(tester.widget<TextField>(amount).controller!.text, '5000.00', reason: '多数是一次还清');

      await tester.enterText(amount, '6000');
      await tapVisible(tester, find.byKey(const ValueKey('debt-move-record')));
      await tapVisible(tester, moveSubmit);
      expect(find.text('最多 ¥5,000.00'), findsOneWidget);

      await tester.enterText(amount, '2000');
      await tester.enterText(find.byKey(const ValueKey('debt-move-note')), '微信转回来的');
      await tapVisible(tester, moveSubmit);
      final body = backend.lastBody('POST', '/debts/d1/settle');
      expect(body['action'], 'settle');
      expect(body['amountCents'], 200000);
      expect(body.containsKey('accountId'), isFalse);
      expect(find.text('¥3,000.00'), findsWidgets);
      expect(find.text('微信转回来的'), findsOneWidget, reason: '没记流水的那笔进了往来');
    });

    testWidgets('还清了：进「已结清」，详情能归档', (tester) async {
      final backend = await withDebts(tester);
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/debts/d2');
      await tapVisible(tester, find.byKey(const ValueKey('debt-settle')));
      await tapVisible(tester, find.byKey(const ValueKey('debt-move-record')));
      await tapVisible(tester, moveSubmit);
      expect(find.text('已结清'), findsWidgets);
      await tapVisible(tester, find.byKey(const ValueKey('debt-archive')));
      expect(backend.lastBody('PATCH', '/debts/d2'), {'archived': true});
    });
  });

  test('债务的内部账户不进「在用的账户」：记账、筛选、账户页都挑不到', () {
    const data = LedgerData(
      accounts: [
        Account(id: 'bank', name: '工行卡', kind: 'bank'),
        Account(id: 'acct-d1', name: '借给 张三', kind: Account.kindDebt),
      ],
    );
    expect(data.activeAccounts.map((a) => a.id), ['bank']);
  });

  group('三种宽度都不溢出', () {
    for (final size in kWidths) {
      testWidgets('债务段 @${size.width.toInt()}', (tester) async {
        final backend = await withDebts(tester);
        await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=debts', size: size);
        expect(tester.takeException(), isNull);
      });

      testWidgets('记一笔债务 @${size.width.toInt()}', (tester) async {
        await pumpAssetsAt(tester, bootAssets(AssetsBackend()), '/assets/debts/new', size: size);
        expect(tester.takeException(), isNull);
      });

      testWidgets('债务详情 @${size.width.toInt()}', (tester) async {
        final backend = await withDebts(tester);
        await pumpAssetsAt(tester, bootAssets(backend), '/assets/debts/d1', size: size);
        expect(tester.takeException(), isNull);
      });
    }
  });

  testWidgets('宽屏：右栏嵌着选中那笔的详情', (tester) async {
    final backend = await withDebts(tester);
    final container = bootAssets(backend);
    await pumpAssetsAt(tester, container, '/assets?tab=debts', size: const Size(1400, 1000));
    expect(find.byKey(const ValueKey('debt-pane-d1')), findsOneWidget);
    await tapVisible(tester, debtTile('d2'));
    expect(find.byKey(const ValueKey('debt-pane-d2')), findsOneWidget);
    expect(container.read(ledgerProvider).valueOrNull?.debts, hasLength(3));
  });
}
