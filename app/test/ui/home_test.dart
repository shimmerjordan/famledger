import 'package:famledger/app/providers.dart';
import 'package:famledger/app/theme.dart';
import 'package:famledger/core/dates.dart';
import 'package:famledger/data/api/api_client.dart';
import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/data/local/outbox.dart';
import 'package:famledger/data/local/secure_store.dart';
import 'package:famledger/data/models/models.dart';
import 'package:famledger/data/repos/ledger_repo.dart';
import 'package:famledger/data/repos/session_repo.dart';
import 'package:famledger/data/repos/transactions_repo.dart';
import 'package:famledger/ui/home/home_page.dart';
import 'package:famledger/ui/transactions/tx_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const LedgerData ledgerData = LedgerData(
  funds: [
    Fund(
      id: 'f1',
      name: '家庭公共',
      color: '#c36a4f',
      monthlyBudgetCents: 200000,
    ),
    Fund(id: 'f2', name: '旅行基金', color: '#bb6690', targetCents: 1000000),
  ],
  accounts: [Account(id: 'a1', name: '微信', kind: 'wechat')],
  categories: [Category(id: 'c1', name: '餐饮', icon: 'restaurant')],
  members: [Member(id: 'm1', username: 'mama', displayName: '妈妈')],
);

final StatsOverview overview = StatsOverview(
  netWorthCents: 5000000,
  assetsCents: 5200000,
  liabilitiesCents: 200000,
  pendingCount: 1,
  funds: const [
    FundBalance(fundId: 'f1', balanceCents: 1200000),
    FundBalance(fundId: 'f2', balanceCents: 620000),
  ],
  month: const MonthStats(
    expenseCents: 321000,
    incomeCents: 800000,
    byFund: [FundAmount(fundId: 'f1', expenseCents: 180000)],
    budgets: [
      BudgetProgress(
        scope: 'fund',
        refId: 'f1',
        budgetCents: 200000,
        spentCents: 180000,
      ),
    ],
  ),
);

final Transaction pendingTx = Transaction(
  id: 'p1',
  clientId: 'cp1',
  type: Transaction.typeExpense,
  amountCents: 3550,
  occurredAt: DateTime(2026, 9, 12, 12, 30),
  fundId: 'f1',
  categoryId: 'c1',
  merchant: '巷口面馆',
  status: 'pending',
  source: 'notification',
  sourceApp: '支付宝',
  confidence: 0.92,
);

final Transaction recentTx = Transaction(
  id: 'r1',
  clientId: 'cr1',
  type: Transaction.typeExpense,
  amountCents: 8800,
  occurredAt: DateTime(2026, 9, 12, 9, 5),
  fundId: 'f1',
  categoryId: 'c1',
  merchant: '菜市场',
);

class FakeLedger extends LedgerController {
  FakeLedger(this.data);

  final LedgerData data;

  @override
  Future<LedgerData> build() async => data;

  @override
  Future<void> sync({bool full = false}) async {}
}

class FakeStats extends StatsController {
  FakeStats(this.data);

  final StatsOverview data;

  @override
  Future<StatsOverview> build(String month) async => data;

  @override
  Future<void> refresh() async {}
}

/// `confirm()` 断网时不抛异常，只是把这条塞进 outbox —— 队列长度是唯一的信号。
class FakeConfirmRepo extends TransactionsRepo {
  FakeConfirmRepo({required this.offline})
    : super(
        api: ApiClient(baseUrl: 'http://127.0.0.1'),
        outbox: Outbox(MemoryLocalStore()),
      );

  final bool offline;
  int queued = 0;
  final List<String> confirmed = [];

  @override
  Future<int> pendingCount() async => queued;

  @override
  Future<void> confirm(String id) async {
    confirmed.add(id);
    if (offline) queued++;
  }
}

Future<void> pumpHome(
  WidgetTester tester, {
  List<Transaction> pending = const [],
  List<Transaction> recent = const [],
  Size size = const Size(390, 900),
  TransactionsRepo? repo,
}) async {
  tester.view.physicalSize = size;
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
        ledgerProvider.overrideWith(() => FakeLedger(ledgerData)),
        statsProvider.overrideWith(() => FakeStats(overview)),
        pendingTxProvider.overrideWith((ref) async => pending),
        recentTxProvider.overrideWith((ref) async => recent),
        if (repo != null) transactionsRepoProvider.overrideWithValue(repo),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const HomePage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('本月合计：支出大字 + 收入 + 结余', (tester) async {
    await pumpHome(tester, recent: [recentTx]);

    expect(find.text('本月支出'), findsOneWidget);
    expect(find.text('¥3,210.00'), findsOneWidget);
    expect(find.text('+¥8,000.00'), findsOneWidget);
    // 结余 = 8000 − 3210
    expect(find.text('+¥4,790.00'), findsOneWidget);
  });

  testWidgets('月份头默认当月，点 ‹ 回到上一月', (tester) async {
    await pumpHome(tester);

    final month = Dates.currentMonth();
    expect(find.text(Dates.monthLabel(month)), findsOneWidget);

    await tester.tap(find.byTooltip('上一月'));
    await tester.pumpAndSettle();

    expect(find.text(Dates.monthLabel(Dates.shiftMonth(month, -1))), findsOneWidget);
  });

  testWidgets('基金卡片显示余额与预算进度', (tester) async {
    await pumpHome(tester);

    expect(find.text('家庭公共'), findsWidgets);
    expect(find.text('¥12,000.00'), findsOneWidget);
    // 预算 2000，已花 1800
    expect(find.text('本月预算还剩 ¥200.00'), findsOneWidget);
    // 目标 10000，余额 6200 → 62%
    expect(find.text('目标 ¥10,000.00 · 62%'), findsOneWidget);
  });

  testWidgets('待确认项带置信度与来源，并有「确认」「修改」', (tester) async {
    await pumpHome(tester, pending: [pendingTx]);

    expect(find.text('待确认 1'), findsOneWidget);
    expect(find.text('巷口面馆'), findsOneWidget);
    expect(find.textContaining('92% 可信'), findsOneWidget);
    expect(find.textContaining('来自 支付宝'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '确认'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '修改'), findsOneWidget);
  });

  testWidgets('确认成功：该条从待确认里消失并给一句提示', (tester) async {
    final repo = FakeConfirmRepo(offline: false);
    await pumpHome(tester, pending: [pendingTx], repo: repo);

    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await tester.pumpAndSettle();

    expect(repo.confirmed, ['p1']);
    expect(find.text('已确认'), findsOneWidget);
    expect(find.text('巷口面馆'), findsNothing);
  });

  testWidgets('离线确认：说清楚是「离线保存」，条目也不再挂着等人再点一次', (tester) async {
    final repo = FakeConfirmRepo(offline: true);
    await pumpHome(tester, pending: [pendingTx], repo: repo);

    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await tester.pumpAndSettle();

    expect(find.text('已离线保存，联网后自动上传'), findsOneWidget);
    expect(find.text('巷口面馆'), findsNothing);
  });

  testWidgets('没有待确认时整段不出现', (tester) async {
    await pumpHome(tester, recent: [recentTx]);

    expect(find.textContaining('待确认'), findsNothing);
  });

  testWidgets('预算接近上限时给出提醒', (tester) async {
    await pumpHome(tester);

    expect(find.text('预算提醒'), findsOneWidget);
    expect(find.text('还剩 ¥200.00'), findsOneWidget);
  });

  testWidgets('最近流水为空时教一句并给主操作', (tester) async {
    await pumpHome(tester);

    expect(find.text('这个月还没有流水'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '记一笔'), findsOneWidget);
  });

  testWidgets('最近流水按 TxTile 渲染金额', (tester) async {
    await pumpHome(tester, recent: [recentTx]);

    expect(find.text('菜市场'), findsOneWidget);
    expect(find.text('−¥88.00'), findsOneWidget);
  });

  testWidgets('宽屏把基金余额与待确认搬到右侧栏', (tester) async {
    await pumpHome(
      tester,
      pending: [pendingTx],
      recent: [recentTx],
      size: const Size(1400, 1000),
    );

    expect(find.text('基金余额'), findsOneWidget);
    expect(find.text('待确认 1'), findsOneWidget);
    // 主栏不再放基金卡片横滑。
    expect(find.text('基金'), findsNothing);
  });
}
