import 'dart:convert';

import 'package:famledger/app/providers.dart';
import 'package:famledger/app/shell.dart';
import 'package:famledger/app/theme.dart';
import 'package:famledger/core/dates.dart';
import 'package:famledger/data/api/api_client.dart';
import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/data/local/secure_store.dart';
import 'package:famledger/data/repos/session_repo.dart';
import 'package:famledger/ui/analysis/analysis_page.dart';
import 'package:famledger/ui/analysis/category_donut.dart';
import 'package:famledger/ui/analysis/member_bars.dart';
import 'package:famledger/ui/analysis/trend_chart.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final String thisMonth = Dates.currentMonth();
final String lastMonth = Dates.shiftMonth(thisMonth, -1);

http.Response jsonOk(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

/// 主数据：两个成员、两个基金、两个类别。
const Map<String, dynamic> ledgerChanges = {
  'since': 0,
  'next': 7,
  'more': false,
  'members': [
    {'id': 'm1', 'username': 'mama', 'displayName': '妈妈', 'role': 'admin'},
    {'id': 'm2', 'username': 'baba', 'displayName': '爸爸', 'role': 'member'},
  ],
  'accounts': [],
  'funds': [
    {'id': 'f1', 'name': '家庭公共', 'kind': 'shared', 'sortOrder': 0},
    {'id': 'f2', 'name': '个人零花', 'kind': 'personal', 'sortOrder': 1},
  ],
  'categories': [
    {'id': 'c1', 'name': '餐饮', 'kind': 'expense', 'icon': 'restaurant'},
    {'id': 'c2', 'name': '交通', 'kind': 'expense', 'icon': 'directions_bus'},
  ],
  'transactions': [],
  'budgets': [],
  'rules': [],
};

/// 本月：餐饮 1200、交通 300；上月：餐饮 1000（环比 +20%）、交通 300（持平）。
Map<String, dynamic> overviewFor(String month) {
  final isThisMonth = month == thisMonth;
  return {
    'netWorthCents': 5000000,
    'assetsCents': 5000000,
    'liabilitiesCents': 0,
    'pendingCount': 0,
    'funds': [],
    'accounts': [],
    'month': {
      'expenseCents': isThisMonth ? 150000 : 130000,
      'incomeCents': isThisMonth ? 800000 : 800000,
      'byFund': [
        {'fundId': 'f1', 'expenseCents': isThisMonth ? 120000 : 100000},
        {'fundId': 'f2', 'expenseCents': 30000},
      ],
      'byCategory': [
        {'categoryId': 'c1', 'expenseCents': isThisMonth ? 120000 : 100000},
        {'categoryId': 'c2', 'expenseCents': 30000},
      ],
      'byMember': [
        {'memberId': 'm1', 'expenseCents': isThisMonth ? 90000 : 80000},
        {'memberId': 'm2', 'expenseCents': 60000},
      ],
      'budgets': [],
    },
  };
}

/// 最近 12 个月，金额逐月递增，好认。
Map<String, dynamic> trendBody() => {
  'series': [
    for (var i = 11; i >= 0; i--)
      {
        'month': Dates.shiftMonth(thisMonth, -i),
        'expenseCents': 100000 + (11 - i) * 1000,
        'incomeCents': 800000,
      },
  ],
};

/// 10 个类别，金额各不相同：用来验「环上并成一块灰的『其他』，排行榜也得跟着并」。
Map<String, dynamic> manyCategoriesChanges() => {
  ...ledgerChanges,
  'categories': [
    for (var i = 0; i < 10; i++)
      {'id': 'k$i', 'name': '类别${i + 1}', 'kind': 'expense', 'icon': 'restaurant'},
  ],
};

int manyCents(int i) => 100000 - i * 7000;

Map<String, dynamic> manyCategoriesOverview() {
  final rows = [
    for (var i = 0; i < 10; i++)
      {'categoryId': 'k$i', 'expenseCents': manyCents(i)},
  ];
  final total = rows.fold<int>(0, (sum, r) => sum + (r['expenseCents']! as int));
  return {
    'netWorthCents': 0,
    'assetsCents': 0,
    'liabilitiesCents': 0,
    'pendingCount': 0,
    'funds': [],
    'accounts': [],
    'month': {
      'expenseCents': total,
      'incomeCents': 0,
      'byFund': [],
      'byCategory': rows,
      'byMember': [],
      'budgets': [],
    },
  };
}

MockClient manyCategoriesApi() => MockClient((request) async {
  final path = request.url.path;
  if (path.endsWith('/changes')) return jsonOk(manyCategoriesChanges());
  if (path.endsWith('/stats/overview')) return jsonOk(manyCategoriesOverview());
  if (path.endsWith('/stats/trend')) return jsonOk(trendBody());
  return jsonOk(const {});
});

MockClient analysisApi({List<Uri>? seen}) => MockClient((request) async {
  seen?.add(request.url);
  final path = request.url.path;
  final month = request.url.queryParameters['month'] ?? thisMonth;
  if (path.endsWith('/changes')) return jsonOk(ledgerChanges);
  if (path.endsWith('/stats/overview')) return jsonOk(overviewFor(month));
  if (path.endsWith('/stats/trend')) return jsonOk(trendBody());
  return jsonOk(const {});
});

Future<ProviderContainer> boot(MockClient client) async {
  final secure = MemorySecureStore();
  secure.data[SessionRepo.baseUrlKey] = 'https://x.dev';
  secure.data[SessionRepo.sessionKey] = jsonEncode({
    'baseUrl': 'https://x.dev',
    'token': 'tok',
    'deviceId': 'dev',
    'me': {'id': 'm1', 'username': 'mama', 'displayName': '妈妈', 'role': 'admin'},
  });
  final repo = SessionRepo(secure: secure);
  await repo.restore();
  return ProviderContainer(
    overrides: [
      localStoreProvider.overrideWithValue(MemoryLocalStore()),
      secureStoreProvider.overrideWithValue(secure),
      sessionRepoProvider.overrideWithValue(repo),
      apiProvider.overrideWithValue(
        ApiClient(baseUrl: 'https://x.dev', token: 'tok', inner: client),
      ),
    ],
  );
}

/// 骨架块是永动动画，不能用 pumpAndSettle，手动推几帧让请求落地。
Future<void> pumpAnalysis(
  WidgetTester tester,
  ProviderContainer container, {
  Size size = const Size(800, 1200),
}) async {
  addTearDown(container.dispose);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const AnalysisPage(),
      ),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('趋势图把 12 个月都画成柱子', (tester) async {
    await pumpAnalysis(tester, await boot(analysisApi()));

    expect(find.byType(TrendChart), findsOneWidget);
    final chart = tester.widget<BarChart>(find.byType(BarChart));
    // 12 个月，每个月两根（支出 + 收入）。
    expect(chart.data.barGroups.length, 12);
    expect(chart.data.barGroups.first.barRods.length, 2);
    // 最右边那个月的支出 = 1110 元，收入 = 8000 元。
    expect(chart.data.barGroups.last.barRods[0].toY, 111000);
    expect(chart.data.barGroups.last.barRods[1].toY, 800000);
    // 最右边（当月）的刻度一定有标签。
    expect(
      find.text('${int.parse(thisMonth.split('-')[1])}月'),
      findsOneWidget,
    );
    // 图例给出两条的名字与合计，不靠颜色猜。
    expect(find.text('支出 合计'), findsOneWidget);
    expect(find.text('收入 合计'), findsOneWidget);
  });

  testWidgets('类别环形有图例列表：名字 + 金额 + 占比 + 环比', (tester) async {
    await pumpAnalysis(tester, await boot(analysisApi()));

    final pie = tester.widget<PieChart>(find.byType(PieChart));
    expect(pie.data.sections.length, 2);
    expect(pie.data.sections.first.value, 120000);
    final donut = tester.widget<CategoryDonut>(find.byType(CategoryDonut));
    expect(donut.slices.map((s) => s.label).toList(), ['餐饮', '交通']);
    expect(donut.totalCents, 150000);

    expect(find.byType(CategoryRankedList), findsOneWidget);
    expect(find.text('餐饮'), findsOneWidget);
    expect(find.text('交通'), findsOneWidget);
    // 金额用 MoneyText，等宽 + 千分位。
    expect(find.text('¥1,200.00'), findsWidgets);
    expect(find.text('¥300.00'), findsWidgets);
    // 占比
    expect(find.text('80%'), findsWidgets);
    // 环比来自上个月的第二次 overview 请求：1200 vs 1000
    expect(find.text('环比 +20%'), findsOneWidget);
    expect(find.text('环比持平'), findsOneWidget);
  });

  testWidgets('上个月的总览是单独请求的', (tester) async {
    final seen = <Uri>[];
    await pumpAnalysis(tester, await boot(analysisApi(seen: seen)));

    final months = seen
        .where((u) => u.path.endsWith('/stats/overview'))
        .map((u) => u.queryParameters['month'])
        .toSet();
    expect(months, {thisMonth, lastMonth});
  });

  testWidgets('成员与基金各有一组横条，带名字和金额', (tester) async {
    await pumpAnalysis(tester, await boot(analysisApi()));

    expect(find.byType(ShareBars), findsNWidgets(2));
    expect(find.text('妈妈'), findsOneWidget);
    expect(find.text('爸爸'), findsOneWidget);
    expect(find.text('家庭公共'), findsOneWidget);
    expect(find.text('个人零花'), findsOneWidget);
    expect(find.text('¥900.00'), findsOneWidget);
  });

  testWidgets('宽屏分成两栏：图在左，排行在右', (tester) async {
    await pumpAnalysis(
      tester,
      await boot(analysisApi()),
      size: const Size(1400, 1000),
    );
    expect(find.byType(AdaptiveTwoPane), findsOneWidget);
    expect(find.byType(BarChart), findsOneWidget);
    expect(find.byType(CategoryRankedList), findsOneWidget);
  });

  testWidgets('月份选择器往前翻会重新取那个月的数据', (tester) async {
    final seen = <Uri>[];
    await pumpAnalysis(tester, await boot(analysisApi(seen: seen)));
    seen.clear();

    await tester.tap(find.byTooltip('上个月'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text(Dates.monthLabel(lastMonth)), findsOneWidget);
    final months = seen
        .where((u) => u.path.endsWith('/stats/overview'))
        .map((u) => u.queryParameters['month'])
        .toSet();
    expect(months.contains(Dates.shiftMonth(lastMonth, -1)), isTrue);
  });

  testWidgets('取不到统计时行内报错并能重试', (tester) async {
    var calls = 0;
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('/changes')) return jsonOk(ledgerChanges);
      if (path.endsWith('/stats/trend')) return jsonOk(trendBody());
      calls++;
      return http.Response(
        jsonEncode({
          'error': {'code': 'boom', 'message': '统计算不出来'},
        }),
        500,
        headers: {'content-type': 'application/json'},
      );
    });
    await pumpAnalysis(tester, await boot(client));

    expect(find.text('统计算不出来'), findsWidgets);
    final before = calls;
    await tester.tap(find.text('重试').first);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(calls, greaterThan(before));
  });

  testWidgets('类别超过 8 个：排行榜折出一行灰「其他」，和环上那块对得上', (tester) async {
    await pumpAnalysis(
      tester,
      await boot(manyCategoriesApi()),
      size: const Size(800, 2400),
    );

    // 环上是 8 块 + 一块「其他」
    final pie = tester.widget<PieChart>(find.byType(PieChart));
    expect(pie.data.sections.length, 9);
    expect(
      pie.data.sections.last.value,
      (manyCents(8) + manyCents(9)).toDouble(),
    );

    expect(find.text('类别1'), findsOneWidget);
    expect(find.text('类别8'), findsOneWidget);
    // 第 9、10 项不单列，而是折进「其他」——否则图例比环还细，对不上。
    expect(find.text('类别9'), findsNothing);
    expect(find.text('类别10'), findsNothing);
    expect(find.text('其他 2 项'), findsOneWidget);
    expect(find.text('¥810.00'), findsOneWidget);

    await tester.tap(find.text('其他 2 项'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('类别9'), findsOneWidget);
    expect(find.text('类别10'), findsOneWidget);
  });
}
