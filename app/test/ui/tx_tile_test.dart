import 'dart:async';

import 'package:famledger/app/providers.dart';
import 'package:famledger/app/theme.dart';
import 'package:famledger/data/api/api_client.dart';
import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/data/local/outbox.dart';
import 'package:famledger/data/local/secure_store.dart';
import 'package:famledger/data/models/models.dart';
import 'package:famledger/data/repos/ledger_repo.dart';
import 'package:famledger/data/repos/session_repo.dart';
import 'package:famledger/data/repos/transactions_repo.dart';
import 'package:famledger/ui/transactions/tx_detail_page.dart';
import 'package:famledger/ui/transactions/tx_providers.dart';
import 'package:famledger/ui/transactions/transactions_page.dart';
import 'package:famledger/ui/transactions/tx_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

Widget wrap(Widget child, {Brightness brightness = Brightness.light}) =>
    MaterialApp(
      theme: buildTheme(brightness),
      home: Scaffold(body: child),
    );

final LedgerData ledger = const LedgerData(
  funds: [Fund(id: 'f1', name: '家庭公共', color: '#c36a4f')],
  categories: [Category(id: 'c1', name: '餐饮', icon: 'restaurant')],
  accounts: [Account(id: 'a1', name: '微信', kind: 'wechat')],
);

Transaction tx({
  String type = Transaction.typeExpense,
  int amountCents = 3550,
  String status = 'confirmed',
  String source = 'manual',
  bool pendingSync = false,
  String? merchant = '巷口面馆',
}) => Transaction(
  id: 't1',
  clientId: 'c-1',
  type: type,
  amountCents: amountCents,
  occurredAt: DateTime(2026, 9, 12, 12, 30),
  fundId: 'f1',
  accountId: 'a1',
  categoryId: 'c1',
  merchant: merchant,
  status: status,
  source: source,
  pendingSync: pendingSync,
);

void main() {
  testWidgets('支出行的金额是 −¥35.50，减号是 U+2212', (tester) async {
    await tester.pumpWidget(wrap(TxTile(tx: tx(), ledger: ledger)));

    expect(find.text('−¥35.50'), findsOneWidget);
    final text = tester.widget<Text>(find.text('−¥35.50'));
    // 支出不着色，只靠符号（DESIGN.md）。
    expect(text.style?.color, buildTheme(Brightness.light).colorScheme.onSurface);
  });

  testWidgets('收入行带 + 号并用收入色', (tester) async {
    await tester.pumpWidget(
      wrap(
        TxTile(
          tx: tx(type: Transaction.typeIncome, amountCents: 120000),
          ledger: ledger,
        ),
      ),
    );

    expect(find.text('+¥1,200.00'), findsOneWidget);
    final text = tester.widget<Text>(find.text('+¥1,200.00'));
    expect(text.style?.color, LedgerColors.light.income);
  });

  testWidgets('转账不带正负号', (tester) async {
    await tester.pumpWidget(
      wrap(
        TxTile(
          tx: tx(type: Transaction.typeTransfer, merchant: null),
          ledger: ledger,
        ),
      ),
    );

    expect(find.text('¥35.50'), findsOneWidget);
  });

  testWidgets('副标题带基金名、账户与时间', (tester) async {
    await tester.pumpWidget(wrap(TxTile(tx: tx(), ledger: ledger)));

    expect(find.text('巷口面馆'), findsOneWidget);
    expect(find.text('家庭公共'), findsOneWidget);
    expect(find.text('微信 · 12:30'), findsOneWidget);
  });

  testWidgets('没有商户时退回类别名', (tester) async {
    await tester.pumpWidget(
      wrap(TxTile(tx: tx(merchant: null), ledger: ledger)),
    );

    expect(find.text('餐饮'), findsOneWidget);
  });

  testWidgets('待确认与待上传各有一个状态小标', (tester) async {
    await tester.pumpWidget(
      wrap(
        Column(
          children: [
            TxTile(tx: tx(status: 'pending'), ledger: ledger),
            TxTile(tx: tx(pendingSync: true), ledger: ledger),
          ],
        ),
      ),
    );

    expect(find.text('待确认'), findsOneWidget);
    expect(find.text('待上传'), findsOneWidget);
  });

  testWidgets('点一下会回调', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(
      wrap(TxTile(tx: tx(), ledger: ledger, onTap: () => tapped++)),
    );

    await tester.tap(find.text('巷口面馆'));
    expect(tapped, 1);
  });

  group('账单页', transactionsPageTests);
  group('groupByDay', groupByDayTests);
  group('筛选条件', filterProviderTests);
  group('流水详情', detailPageTests);
}

class FakeLedger extends LedgerController {
  FakeLedger(this.data);

  final LedgerData data;

  @override
  Future<LedgerData> build() async => data;

  @override
  Future<void> sync({bool full = false}) async {}
}

class FakeTxList extends TxListController {
  FakeTxList(this.data);

  final TxListState data;

  @override
  Future<TxListState> build() async => data;

  @override
  Future<void> refresh() async {}

  @override
  Future<void> loadMore() async {}
}

/// 账单页的冒烟测试：分组头、当日合计、到底提示。
void transactionsPageTests() {
  Future<void> pumpPage(WidgetTester tester, TxListState state) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localStoreProvider.overrideWithValue(MemoryLocalStore()),
          secureStoreProvider.overrideWithValue(MemorySecureStore()),
          sessionRepoProvider.overrideWithValue(
            SessionRepo(secure: MemorySecureStore()),
          ),
          ledgerProvider.overrideWith(() => FakeLedger(ledger)),
          txListProvider.overrideWith(() => FakeTxList(state)),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: const TransactionsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('按日分组，组头带当日收支合计', (tester) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day, 12, 30);
    await pumpPage(
      tester,
      TxListState(
        items: [
          tx().copyWith(id: 't1', occurredAt: today),
          tx(
            type: Transaction.typeIncome,
            amountCents: 120000,
            merchant: '工资',
          ).copyWith(id: 't2', occurredAt: today),
          tx().copyWith(
            id: 't3',
            occurredAt: today.subtract(const Duration(days: 1)),
          ),
        ],
      ),
    );

    expect(find.text('今天'), findsOneWidget);
    expect(find.text('昨天'), findsOneWidget);
    // 两条支出行 + 两个组头的当日支出合计
    expect(find.text('\u2212¥35.50'), findsNWidgets(4));
    expect(find.text('+¥1,200.00'), findsNWidgets(2));
    expect(find.text('没有更多了'), findsOneWidget);
  });

  testWidgets('一条都没有时给空态与主操作', (tester) async {
    await pumpPage(tester, const TxListState());

    expect(find.text('还没有流水'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '记一笔'), findsOneWidget);
  });

  testWidgets('换筛选条件时有一条细进度条（骨架被 skipLoadingOnReload 跳过了）', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = GatedTxRepo();
    final container = ProviderContainer(
      overrides: [
        localStoreProvider.overrideWithValue(MemoryLocalStore()),
        secureStoreProvider.overrideWithValue(MemorySecureStore()),
        sessionRepoProvider.overrideWithValue(
          SessionRepo(secure: MemorySecureStore()),
        ),
        ledgerProvider.overrideWith(() => FakeLedger(ledger)),
        transactionsRepoProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: const TransactionsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);

    // 卡住下一次请求，模拟「换了条件、还在拉」。
    final gate = Completer<TxPage>();
    repo.gate = gate;
    unawaited(
      container
          .read(txListProvider.notifier)
          .setFilter(const TxFilter(fundId: 'f1')),
    );
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    gate.complete(TxPage.empty);
    await tester.pumpAndSettle();

    expect(find.byType(LinearProgressIndicator), findsNothing);
  });
}

/// `groupByDay` 的纯函数行为（翻页时组头的合计只算已加载的部分）。
void groupByDayTests() {
  test('按自然日切段并各自合计，作废的不计入', () {
    final day1 = DateTime(2026, 9, 12, 20, 0);
    final day2 = DateTime(2026, 9, 11, 8, 0);
    final groups = groupByDay([
      tx().copyWith(id: '1', occurredAt: day1),
      tx(type: Transaction.typeIncome, amountCents: 100000)
          .copyWith(id: '2', occurredAt: day1),
      tx(status: 'void').copyWith(id: '3', occurredAt: day1),
      tx().copyWith(id: '4', occurredAt: day2),
    ]);

    expect(groups.length, 2);
    expect(groups[0].items.length, 3);
    expect(groups[0].expenseCents, 3550);
    expect(groups[0].incomeCents, 100000);
    expect(groups[1].expenseCents, 3550);
  });
}

/// 能把某一次 `list` 卡住，用来观察「正在重拉」的那一帧。
class GatedTxRepo extends TransactionsRepo {
  GatedTxRepo()
    : super(
        api: ApiClient(baseUrl: 'http://127.0.0.1'),
        outbox: Outbox(MemoryLocalStore()),
      );

  Completer<TxPage>? gate;

  @override
  Future<TxPage> list(TxFilter filter, {String? cursor}) {
    final pending = gate;
    if (pending == null) return Future.value(TxPage.empty);
    gate = null;
    return pending.future;
  }
}

/// 每次 `list` 都记下来，用来看重新加载时带的是哪套条件。
class RecordingTxRepo extends TransactionsRepo {
  RecordingTxRepo()
    : super(
        api: ApiClient(baseUrl: 'http://127.0.0.1'),
        outbox: Outbox(MemoryLocalStore()),
      );

  final List<TxFilter> calls = [];

  @override
  Future<TxPage> list(TxFilter filter, {String? cursor}) async {
    calls.add(filter);
    return TxPage.empty;
  }
}

/// 筛选条件不能挂在列表的 notifier 实例上：记一笔 / 改一笔 / 拨款都会
/// `invalidate(txListProvider)`，那会把 notifier 整个换掉。
void filterProviderTests() {
  test('invalidate 列表之后，重新加载用的还是同一套筛选条件', () async {
    final repo = RecordingTxRepo();
    final container = ProviderContainer(
      overrides: [transactionsRepoProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);

    await container.read(txListProvider.future);
    expect(repo.calls.single.fundId, isNull);

    await container
        .read(txListProvider.notifier)
        .setFilter(const TxFilter(fundId: 'f1', q: '面馆'));
    await container.pump();
    await container.read(txListProvider.future);
    expect(repo.calls.last.fundId, 'f1');

    // 模拟「记完一笔」之后的刷新。
    container.invalidate(txListProvider);
    await container.pump();
    await container.read(txListProvider.future);

    expect(container.read(txFilterProvider).fundId, 'f1');
    expect(container.read(txFilterProvider).q, '面馆');
    expect(repo.calls.last.fundId, 'f1');
    expect(repo.calls.last.q, '面馆');
    // 每页条数也没丢。
    expect(repo.calls.last.limit, TxListController.pageSize);
  });
}

/// 详情页用的假仓库：记下 PATCH 的内容，并能模拟「断网只入队」。
class DetailRepo extends TransactionsRepo {
  DetailRepo({this.offline = false})
    : super(
        api: ApiClient(baseUrl: 'http://127.0.0.1'),
        outbox: Outbox(MemoryLocalStore()),
      );

  final bool offline;
  Map<String, dynamic>? lastPatch;
  final List<String> confirmed = [];
  final List<String> deleted = [];
  int queued = 0;

  @override
  Future<int> pendingCount() async => queued;

  @override
  Future<Transaction> update(
    String id,
    Map<String, dynamic> patch, {
    Transaction? current,
  }) async {
    lastPatch = patch;
    if (offline) queued++;
    return tx().copyWith(pendingSync: offline);
  }

  @override
  Future<void> confirm(String id) async {
    confirmed.add(id);
    if (offline) queued++;
  }

  @override
  Future<void> delete(String id) async {
    deleted.add(id);
    if (offline) queued++;
  }
}

void detailPageTests() {
  Future<void> pumpDetail(
    WidgetTester tester,
    Transaction detail,
    DetailRepo repo,
  ) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final router = GoRouter(
      initialLocation: '/detail',
      routes: [
        GoRoute(
          path: '/detail',
          builder: (context, state) => const TxDetailPage('t1'),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localStoreProvider.overrideWithValue(MemoryLocalStore()),
          secureStoreProvider.overrideWithValue(MemorySecureStore()),
          sessionRepoProvider.overrideWithValue(
            SessionRepo(secure: MemorySecureStore()),
          ),
          ledgerProvider.overrideWith(() => FakeLedger(ledger)),
          txDetailProvider.overrideWith((ref, id) async => detail),
          transactionsRepoProvider.overrideWithValue(repo),
        ],
        child: MaterialApp.router(
          theme: buildTheme(Brightness.light),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('把支出改成收入时，旧的支出类别会被明确清掉', (tester) async {
    final repo = DetailRepo();
    await pumpDetail(tester, tx(), repo);

    await tester.tap(find.text('收入'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存修改'));
    await tester.pumpAndSettle();

    expect(repo.lastPatch, isNotNull);
    expect(repo.lastPatch!['type'], Transaction.typeIncome);
    // 留着 c1（餐饮）就是一笔挂着支出类别的收入 —— 服务端不拦，是脏数据。
    expect(repo.lastPatch!.containsKey('categoryId'), isTrue);
    expect(repo.lastPatch!['categoryId'], isNull);
  });

  testWidgets('离线确认：详情页也说「已离线保存」', (tester) async {
    final repo = DetailRepo(offline: true);
    await pumpDetail(tester, tx(status: 'pending'), repo);

    await tester.tap(find.text('确认这笔'));
    await tester.pumpAndSettle();

    expect(repo.confirmed, ['t1']);
    expect(find.text('已离线保存，联网后自动上传'), findsOneWidget);
  });

  testWidgets('在线确认还是说「已确认」', (tester) async {
    final repo = DetailRepo();
    await pumpDetail(tester, tx(status: 'pending'), repo);

    await tester.tap(find.text('确认这笔'));
    await tester.pumpAndSettle();

    expect(find.text('已确认'), findsOneWidget);
  });

  testWidgets('删除要二次确认，离线删除也说清楚', (tester) async {
    final repo = DetailRepo(offline: true);
    await pumpDetail(tester, tx(), repo);

    await tester.tap(find.byTooltip('删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除这笔流水？'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(repo.deleted, ['t1']);
    expect(find.text('已离线保存，联网后自动上传'), findsOneWidget);
  });
}
