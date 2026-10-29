import 'dart:convert';

import 'package:famledger/app/providers.dart';
import 'package:famledger/app/theme.dart';
import 'package:famledger/data/api/api_client.dart';
import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/data/local/secure_store.dart';
import 'package:famledger/data/models/models.dart';
import 'package:famledger/data/repos/import_repo.dart';
import 'package:famledger/data/repos/session_repo.dart';
import 'package:famledger/ui/import/import_page.dart';
import 'package:famledger/ui/import/import_preview_page.dart';
import 'package:famledger/ui/settings/settings_page.dart';
import 'package:famledger/ui/transactions/tx_detail_page.dart';
import 'package:famledger/ui/transactions/tx_providers.dart';
import 'package:famledger/ui/transactions/tx_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'assets_harness.dart' show tapVisible;
import 'import_preview_test.dart' as imp;
import 'tx_table_test.dart' as table;
import 'tx_tile_test.dart' as tile;

/// 「不计入账户余额」：模型来回、导入核对页的开关（默认 / 记住 / 提交体）、流水详情的开关、
/// 列表行与表格的「不计余额」小标、多选批量改。

Transaction offTx({String id = 't1', String? accountId = 'a1', String type = Transaction.typeExpense}) => Transaction(
  id: id,
  clientId: 'c-$id',
  type: type,
  amountCents: 12800,
  occurredAt: DateTime(2026, 9, 12, 19, 40),
  fundId: 'f1',
  accountId: accountId,
  categoryId: 'c1',
  merchant: '盒马鲜生',
  source: 'import',
  offBalance: true,
);

Future<tile.DetailRepo> pumpDetail(WidgetTester tester, Transaction detail) async {
  final repo = tile.DetailRepo();
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
        ledgerProvider.overrideWith(() => tile.FakeLedger(tile.ledger)),
        txDetailProvider.overrideWith((ref, id) async => detail),
        transactionsRepoProvider.overrideWithValue(repo),
      ],
      child: MaterialApp.router(theme: buildTheme(Brightness.light), routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

Future<imp.Harness> pumpImport(
  WidgetTester tester, {
  required ImportPreview preview,
  MemoryLocalStore? store,
  Size size = const Size(400, 1000),
}) async {
  final harness = imp.Harness();
  final secure = MemorySecureStore();
  secure.data[SessionRepo.sessionKey] = jsonEncode({
    'baseUrl': 'https://x.dev',
    'token': 'tok',
    'deviceId': 'dev',
    'me': {'id': 'm1', 'username': 'mama', 'displayName': '妈妈', 'role': 'admin'},
  });
  final session = SessionRepo(secure: secure);
  await session.restore();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        localStoreProvider.overrideWithValue(store ?? MemoryLocalStore()),
        secureStoreProvider.overrideWithValue(secure),
        sessionRepoProvider.overrideWithValue(session),
        ledgerProvider.overrideWith(imp.FakeLedger.new),
        importRepoProvider.overrideWithValue(
          ImportRepo(ApiClient(baseUrl: 'https://x.dev', token: 'tok', inner: harness.client)),
        ),
      ],
      child: MaterialApp(theme: buildTheme(Brightness.light), home: ImportPreviewPage(preview: preview)),
    ),
  );
  await tester.pumpAndSettle();
  return harness;
}

final ImportPreview templatePreview = ImportPreview.fromJson({
  'source': 'template',
  'sourceLabel': '通用模板',
  'total': 1,
  'importable': 1,
  'skipped': 0,
  'rows': [imp.rowJson(1, merchant: '午饭', amountCents: 3500)],
});

Switch balanceSwitch(WidgetTester tester) =>
    tester.widget<Switch>(find.byKey(const ValueKey('import-count-balance')));

List<Map<String, dynamic>> submittedItems(imp.Harness harness) => [
  for (final body in harness.bodiesOf('/transactions/batch'))
    ...(body['items'] as List).cast<Map<String, dynamic>>(),
];

void main() {
  group('模型', () {
    test('Transaction / TransactionDraft 的 offBalance 来回；只在为真时写进 JSON', () {
      final t = offTx();
      expect(t.offBalance, isTrue);
      expect(t.toJson()['offBalance'], isTrue);
      expect(Transaction.fromJson(t.toJson()).offBalance, isTrue);
      expect(tile.tx().toJson().containsKey('offBalance'), isFalse, reason: '默认计入，不写');
      expect(Transaction.fromJson({'id': 'x', 'clientId': 'x', 'type': 'expense', 'amountCents': 1, 'occurredAt': '2026-09-12T12:00:00+08:00'}).offBalance, isFalse, reason: '老服务端没这个字段');

      final draft = TransactionDraft(
        clientId: 'd1',
        type: Transaction.typeExpense,
        amountCents: 100,
        occurredAt: DateTime(2026, 9, 12),
        offBalance: true,
      );
      expect(draft.toJson()['offBalance'], isTrue);
      expect(TransactionDraft.fromJson(draft.toJson()).offBalance, isTrue);
      expect(draft.toOptimisticTransaction().offBalance, isTrue);
    });

    test('TxFilter.offBalance：查询串 1/0，算进筛选项个数，clearFacets 清掉', () {
      const on = TxFilter(offBalance: true);
      expect(on.toQuery()['offBalance'], '1');
      expect(const TxFilter(offBalance: false).toQuery()['offBalance'], '0');
      expect(const TxFilter().toQuery().containsKey('offBalance'), isFalse);
      expect(on.activeCount, 1);
      expect(on.isEmpty, isFalse);
      expect(on.copyWith(clearFacets: true).offBalance, isNull);
      expect(on.copyWith(type: 'expense').offBalance, isTrue);
    });

    test('ImportItem.toBatchJson 只在不计入时带 offBalance', () {
      final row = ImportRow.fromJson(imp.rowJson(1, merchant: '美团', amountCents: 3500));
      expect(ImportItem(row: row, offBalance: true).toBatchJson()['offBalance'], isTrue);
      expect(ImportItem(row: row).toBatchJson().containsKey('offBalance'), isFalse);
    });
  });

  group('导入核对页的「计入账户余额」', () {
    testWidgets('支付宝账单默认不计入：开关关着、说明写清；提交体每项 offBalance:true；结果页说一声', (tester) async {
      final harness = await pumpImport(tester, preview: imp.preview, size: const Size(800, 1400));

      expect(balanceSwitch(tester).value, isFalse);
      expect(find.text('这批只进收支统计，不改账户余额；余额在账户里直接校准'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('import-submit')));
      await tester.pumpAndSettle();

      final items = submittedItems(harness);
      expect(items.length, 3);
      expect(items.every((item) => item['offBalance'] == true), isTrue);
      expect(find.byKey(const ValueKey('import-result-off-balance')), findsOneWidget);
    });

    testWidgets('打开开关 = 计入：提交体不带 offBalance，结果页不提；选择记在本机', (tester) async {
      final store = MemoryLocalStore();
      final harness = await pumpImport(tester, preview: imp.preview, store: store, size: const Size(800, 1400));

      await tester.tap(find.byKey(const ValueKey('import-count-balance')));
      await tester.pumpAndSettle();
      expect(balanceSwitch(tester).value, isTrue);
      expect(find.text('会加减对应账户的余额'), findsOneWidget);
      expect(await store.read<bool>('import.countInBalance'), isTrue);

      await tester.tap(find.byKey(const ValueKey('import-submit')));
      await tester.pumpAndSettle();

      final items = submittedItems(harness);
      expect(items.length, 3);
      expect(items.any((item) => item.containsKey('offBalance')), isFalse);
      expect(find.byKey(const ValueKey('import-result-off-balance')), findsNothing);
    });

    testWidgets('本机记住上次的选择：上次计入，这次账单也默认计入', (tester) async {
      final store = MemoryLocalStore();
      await store.write('import.countInBalance', true);
      await pumpImport(tester, preview: imp.preview, store: store);

      expect(balanceSwitch(tester).value, isTrue);
    });

    testWidgets('通用模板默认计入', (tester) async {
      await pumpImport(tester, preview: templatePreview);

      expect(balanceSwitch(tester).value, isTrue);
    });
  });

  group('流水详情的「账户余额」一段', () {
    testWidgets('有账户的支出：摘要写「计入」，展开关掉开关后保存带 offBalance:true', (tester) async {
      final repo = await pumpDetail(tester, tile.tx());

      expect(find.byKey(const ValueKey('tx-section-balance')), findsOneWidget);
      expect(find.text('计入'), findsOneWidget);
      await tapVisible(tester, find.byKey(const ValueKey('tx-section-balance')));
      final toggle = find.byKey(const ValueKey('tx-off-balance'));
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);

      await tapVisible(tester, toggle);
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      expect(find.text('不计入'), findsOneWidget);
      await tapVisible(tester, find.text('保存修改'));

      expect(repo.lastPatch!['offBalance'], isTrue);
    });

    testWidgets('不计入的流水：摘要写「不计入」；没改过开关保存时不带 offBalance', (tester) async {
      final repo = await pumpDetail(tester, offTx());

      expect(find.text('不计入'), findsOneWidget);
      await tapVisible(tester, find.text('保存修改'));

      expect(repo.lastPatch!.containsKey('offBalance'), isFalse);
    });

    testWidgets('没走账户的流水不出这一段', (tester) async {
      // copyWith(accountId: null) 不会清掉账户（null = 不改），直接构造一笔没账户的。
      await pumpDetail(tester, offTx(accountId: null));

      expect(find.byKey(const ValueKey('tx-section-balance')), findsNothing);
    });
  });

  group('列表与表格', () {
    testWidgets('列表行：不计入的挂「不计余额」小标，和状态小标并排', (tester) async {
      await tester.pumpWidget(tile.wrap(TxTile(tx: offTx(), ledger: tile.ledger)));
      expect(find.text('不计余额'), findsOneWidget);

      await tester.pumpWidget(tile.wrap(TxTile(tx: offTx().copyWith(status: 'pending'), ledger: tile.ledger)));
      expect(find.text('不计余额'), findsOneWidget);
      expect(find.text('待确认'), findsOneWidget);

      await tester.pumpWidget(tile.wrap(TxTile(tx: tile.tx(), ledger: tile.ledger)));
      expect(find.text('不计余额'), findsNothing);
    });

    testWidgets('表格：不计入的行标「不计余额」；多选后「余额」菜单批量改成不计入', (tester) async {
      final repo = table.TableRepo();
      repo.items = [for (final t in repo.items) t.id == 't1' ? t.copyWith(offBalance: true) : t];
      await table.pumpPage(tester, repo: repo);

      expect(find.text('不计余额'), findsOneWidget);

      await table.select(tester, ['t1', 't2']);
      await tester.tap(find.byKey(const ValueKey('tx-bulk-balance')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tx-bulk-balance-off')));
      await tester.pumpAndSettle();

      expect(repo.bulkCalls, [
        {
          'ids': ['t1', 't2'],
          'patch': {'offBalance': true},
        },
      ]);
      expect(find.text('这 2 笔不再计入账户余额'), findsOneWidget);
      expect(find.textContaining('已选'), findsNothing, reason: '改完清空选择');
    });
  });

  test('「我的 › 智能与数据」的导入入口在宽屏右栏嵌的是导入页', () {
    expect(settingsPageFor('/import'), isA<ImportPage>());
  });
}
