import 'package:famledger/app/providers.dart';
import 'package:famledger/app/theme.dart';
import 'package:famledger/data/api/api_client.dart';
import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/data/local/secure_store.dart';
import 'package:famledger/data/models/models.dart';
import 'package:famledger/data/repos/ledger_repo.dart';
import 'package:famledger/data/repos/session_repo.dart';
import 'package:famledger/ui/funds/fund_detail_page.dart';
import 'package:famledger/ui/funds/fund_progress.dart';
import 'package:famledger/ui/funds/fund_providers.dart';
import 'package:famledger/ui/funds/funds_page.dart';
import 'package:fl_chart/fl_chart.dart';
import 'dart:async';

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
    Fund(id: 'f3', name: '已归档的', archived: true),
  ],
);

final StatsOverview overview = const StatsOverview(
  netWorthCents: 0,
  assetsCents: 0,
  liabilitiesCents: 0,
  funds: [
    FundBalance(fundId: 'f1', balanceCents: 1200000),
    FundBalance(fundId: 'f2', balanceCents: 620000),
  ],
  month: MonthStats(
    expenseCents: 180000,
    byFund: [FundAmount(fundId: 'f1', expenseCents: 180000)],
  ),
);

class FakeLedger extends LedgerController {
  FakeLedger(this.data, {this.syncError});

  final LedgerData data;

  /// 非 null 时模拟「下拉同步失败」。
  final Object? syncError;

  @override
  Future<LedgerData> build() async => data;

  @override
  Future<void> sync({bool full = false}) async {
    final error = syncError;
    if (error != null) throw error;
  }
}

class FakeStats extends StatsController {
  FakeStats(this.data);

  final StatsOverview data;

  @override
  Future<StatsOverview> build(String month) async => data;

  @override
  Future<void> refresh() async {}
}

Future<void> pumpFunds(
  WidgetTester tester, {
  LedgerData data = ledgerData,
  Size size = const Size(390, 900),
  Object? syncError,
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
        ledgerProvider.overrideWith(
          () => FakeLedger(data, syncError: syncError),
        ),
        statsProvider.overrideWith(() => FakeStats(overview)),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const FundsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('列表列出在用的基金与各自余额', (tester) async {
    await pumpFunds(tester);

    expect(find.text('家庭公共'), findsOneWidget);
    expect(find.text('¥12,000.00'), findsOneWidget);
    expect(find.text('旅行基金'), findsOneWidget);
    expect(find.text('¥6,200.00'), findsOneWidget);
    // 归档的不出现在列表里。
    expect(find.text('已归档的'), findsNothing);
  });

  testWidgets('合计 = 各基金余额之和', (tester) async {
    await pumpFunds(tester);

    expect(find.text('基金合计'), findsOneWidget);
    expect(find.text('¥18,200.00'), findsOneWidget);
    expect(find.text('本月支出 ¥1,800.00 · 2 个基金'), findsOneWidget);
  });

  testWidgets('预算进度与目标进度各画各的', (tester) async {
    await pumpFunds(tester);

    expect(find.text('本月预算还剩 ¥200.00'), findsOneWidget);
    expect(find.text('目标 ¥10,000.00 · 62%'), findsOneWidget);

    final bars = tester
        .widgetList<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator),
        )
        .toList();
    expect(bars.length, 2);
    // 预算：1800 / 2000 = 0.9；目标：6200 / 10000 = 0.62
    expect(bars[0].value, closeTo(0.9, 0.001));
    expect(bars[1].value, closeTo(0.62, 0.001));
  });

  testWidgets('一个基金都没有时教一句并给主操作', (tester) async {
    await pumpFunds(tester, data: const LedgerData());

    expect(find.text('还没有基金'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '从模板新建'), findsOneWidget);
  });

  testWidgets('下拉同步失败：页面顶上说清楚并给重试，内容不塌', (tester) async {
    await pumpFunds(
      tester,
      syncError: const ApiException(0, 'network', '连不上服务器'),
    );

    expect(find.textContaining('同步失败'), findsNothing);

    final indicator = tester.state<RefreshIndicatorState>(
      find.byType(RefreshIndicator),
    );
    unawaited(indicator.show());
    await tester.pumpAndSettle();

    expect(find.text('同步失败：连不上服务器'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    // 已经画出来的基金还在，不能因为同步失败就白屏。
    expect(find.text('家庭公共'), findsOneWidget);
  });

  testWidgets('一个基金都没有时，同步失败也要看得见（不然分不清「真没有」和「没同步上」）', (
    tester,
  ) async {
    await pumpFunds(
      tester,
      data: const LedgerData(),
      syncError: const ApiException(0, 'network', '连不上服务器'),
    );

    final indicator = tester.state<RefreshIndicatorState>(
      find.byType(RefreshIndicator),
    );
    unawaited(indicator.show());
    await tester.pumpAndSettle();

    expect(find.text('同步失败：连不上服务器'), findsOneWidget);
    expect(find.text('还没有基金'), findsOneWidget);
  });

  testWidgets('宽屏用卡片网格，窄屏用列表', (tester) async {
    await pumpFunds(tester, size: const Size(1200, 1000));

    expect(find.byType(GridView), findsOneWidget);
    expect(find.text('家庭公共'), findsOneWidget);
    expect(find.text('¥12,000.00'), findsOneWidget);
  });

  group('基金详情', () {
    final fundStats = FundStats(
      balanceCents: 1200000,
      targetCents: null,
      budgetCents: 200000,
      monthExpenseCents: 180000,
      monthIncomeCents: 50000,
      byCategory: const [CategoryAmount(categoryId: 'c1', expenseCents: 180000)],
      recent: [
        Transaction(
          id: 't1',
          clientId: 'c1',
          type: Transaction.typeExpense,
          amountCents: 3550,
          occurredAt: DateTime(2026, 9, 12, 12, 30),
          fundId: 'f1',
          categoryId: 'c1',
          merchant: '巷口面馆',
        ),
      ],
    );
    const trend = TrendSeries(
      series: [
        TrendPoint(month: '2026-08', expenseCents: 150000),
        TrendPoint(month: '2026-09', expenseCents: 180000, incomeCents: 50000),
      ],
    );

    Future<void> pumpDetail(WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 1200);
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
            ledgerProvider.overrideWith(
              () => FakeLedger(
                const LedgerData(
                  funds: [
                    Fund(
                      id: 'f1',
                      name: '家庭公共',
                      color: '#c36a4f',
                      monthlyBudgetCents: 200000,
                    ),
                    Fund(id: 'f2', name: '旅行基金'),
                  ],
                  categories: [
                    Category(id: 'c1', name: '餐饮', icon: 'restaurant'),
                  ],
                ),
              ),
            ),
            statsProvider.overrideWith(() => FakeStats(overview)),
            fundStatsProvider.overrideWith((ref, id) async => fundStats),
            fundTrendProvider.overrideWith((ref, id) async => trend),
          ],
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            home: const FundDetailPage('f1'),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('余额、预算进度、类别构成、趋势、流水都在', (tester) async {
      await pumpDetail(tester);

      // 标题一次，流水行的基金标签一次。
      expect(find.text('家庭公共'), findsNWidgets(2));
      expect(find.text('¥12,000.00'), findsOneWidget);
      expect(find.text('本月预算还剩 ¥200.00'), findsOneWidget);

      expect(find.text('本月构成'), findsOneWidget);
      expect(find.byType(PieChart), findsOneWidget);
      expect(find.text('餐饮'), findsOneWidget);
      expect(find.text('100%'), findsOneWidget);

      expect(find.text('近 6 个月'), findsOneWidget);
      expect(find.byType(BarChart), findsOneWidget);
      expect(find.text('8月'), findsOneWidget);
      expect(find.text('9月'), findsOneWidget);

      expect(find.text('巷口面馆'), findsOneWidget);
      expect(find.text('拨款'), findsOneWidget);
      expect(find.text('目标/预算'), findsOneWidget);
    });
  });

  group('fundProgressOf', () {
    test('预算超了就是超了，攒过头不算超', () {
      const fund = Fund(id: 'f1', name: 'x', monthlyBudgetCents: 100000);
      final over = fundProgressOf(
        fund,
        const StatsOverview(
          netWorthCents: 0,
          assetsCents: 0,
          liabilitiesCents: 0,
          month: MonthStats(
            byFund: [FundAmount(fundId: 'f1', expenseCents: 150000)],
          ),
        ),
      );
      expect(over.isOver, isTrue);
      expect(over.label, '超预算 ¥500.00');

      const goal = Fund(id: 'f2', name: 'y', targetCents: 100000);
      final done = fundProgressOf(
        goal,
        const StatsOverview(
          netWorthCents: 0,
          assetsCents: 0,
          liabilitiesCents: 0,
          funds: [FundBalance(fundId: 'f2', balanceCents: 150000)],
          month: MonthStats(),
        ),
      );
      expect(done.isOver, isFalse);
      expect(done.ratio, 1);
    });

    test('这个月单独设的预算盖过基金上的月预算', () {
      const fund = Fund(id: 'f1', name: 'x', monthlyBudgetCents: 100000);
      final progress = fundProgressOf(
        fund,
        const StatsOverview(
          netWorthCents: 0,
          assetsCents: 0,
          liabilitiesCents: 0,
          month: MonthStats(
            byFund: [FundAmount(fundId: 'f1', expenseCents: 50000)],
            budgets: [
              BudgetProgress(
                scope: 'fund',
                refId: 'f1',
                budgetCents: 500000,
                spentCents: 50000,
              ),
            ],
          ),
        ),
      );
      expect(progress.label, '本月预算还剩 ¥4,500.00');
    });
  });
}
