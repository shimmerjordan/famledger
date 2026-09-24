import 'dart:convert';

import 'package:famledger/app/providers.dart';
import 'package:famledger/app/theme.dart';
import 'package:famledger/data/api/api_client.dart';
import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/data/local/secure_store.dart';
import 'package:famledger/data/models/models.dart';
import 'package:famledger/data/repos/import_repo.dart';
import 'package:famledger/data/repos/ledger_repo.dart';
import 'package:famledger/data/repos/session_repo.dart';
import 'package:famledger/ui/import/import_preview_page.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const LedgerData ledgerData = LedgerData(
  funds: [
    Fund(id: 'f1', name: '家庭公共', isDefault: true),
    Fund(id: 'f2', name: '个人零花'),
  ],
  categories: [
    Category(id: 'c1', name: '餐饮', icon: 'restaurant'),
    Category(id: 'c2', name: '交通', icon: 'directions_bus'),
    Category(id: 'c9', name: '工资', kind: 'income', icon: 'payments'),
  ],
  accounts: [Account(id: 'a1', name: '支付宝', kind: 'alipay')],
  members: [Member(id: 'm1', username: 'mama', displayName: '妈妈')],
);

class FakeLedger extends LedgerController {
  @override
  Future<LedgerData> build() async => ledgerData;

  @override
  Future<void> sync({bool full = false}) async {}
}

Map<String, dynamic> rowJson(
  int n, {
  String merchant = '',
  String type = 'expense',
  int amountCents = 1000,
  String? categoryId,
  double? confidence,
  Map<String, String>? skip,
  bool exists = false,
  String? duplicateOf,
}) => {
  'row': n,
  'clientId': 'imp-$n',
  'type': type,
  'amountCents': amountCents,
  'occurredAt': '2026-09-1${n}T12:30:00+08:00',
  'merchant': merchant,
  'note': '',
  'rawCategory': '餐饮美食',
  'categoryId': categoryId,
  'fundId': null,
  'accountId': 'a1',
  'confidence': confidence,
  'skip': skip,
  'exists': exists,
  'duplicateOf': duplicateOf,
  'hint': null,
};

final ImportPreview preview = ImportPreview.fromJson({
  'source': 'alipay',
  'sourceLabel': '支付宝账单',
  'total': 6,
  'importable': 5,
  'skipped': 1,
  'rows': [
    rowJson(1, merchant: '美团', amountCents: 3500),
    rowJson(
      2,
      merchant: '滴滴',
      amountCents: 2350,
      categoryId: 'c2',
      confidence: 0.82,
    ),
    rowJson(3, merchant: '老王转账', type: 'income', amountCents: 8800),
    rowJson(
      4,
      merchant: '余额宝',
      skip: {'code': 'neutral', 'message': '不计收支（转账、充值、理财等），不记账'},
    ),
    rowJson(5, merchant: '盒马', exists: true),
    rowJson(6, merchant: '全家', duplicateOf: 'tx-9'),
  ],
});

class Harness {
  final List<http.Request> seen = [];

  /// 依次给每次 `/transactions/batch` 用：'down' = 连不上服务器；Set = 这些 clientId 逐行被拒；
  /// null = 全收下。用完之后一直全收下。
  final List<Object?> batchPlan = [];

  List<Map<String, dynamic>> bodiesOf(String path) => [
    for (final r in seen)
      if (r.url.path.endsWith(path)) jsonDecode(r.body) as Map<String, dynamic>,
  ];

  late final MockClient client = MockClient((request) async {
    seen.add(request);
    final path = request.url.path;
    if (path.endsWith('/transactions/batch')) {
      final plan = batchPlan.isEmpty ? null : batchPlan.removeAt(0);
      if (plan == 'down') {
        throw http.ClientException('Connection refused', request.url);
      }
      final rejected = plan is Set ? plan : const <Object>{};
      final items = (jsonDecode(request.body)['items'] as List)
          .cast<Map<String, dynamic>>();
      return http.Response(
        jsonEncode({
          'results': [
            for (final item in items)
              rejected.contains(item['clientId'])
                  ? {
                      'clientId': item['clientId'],
                      'status': 'error',
                      'error': 'invalid_categoryId',
                      'message': '类别不存在',
                    }
                  : {
                      'clientId': item['clientId'],
                      'id': 'tx-${item['clientId']}',
                      'status': 'created',
                    },
          ],
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    if (path.endsWith('/model/learn')) {
      return http.Response(
        '{"version":2,"learned":{"category":1,"fund":0}}',
        200,
      );
    }
    return http.Response('{}', 404);
  });
}

Future<Harness> pumpPreview(
  WidgetTester tester, {
  Size size = const Size(400, 1000),
}) async {
  final harness = Harness();
  final secure = MemorySecureStore();
  secure.data[SessionRepo.sessionKey] = jsonEncode({
    'baseUrl': 'https://x.dev',
    'token': 'tok',
    'deviceId': 'dev',
    'me': {
      'id': 'm1',
      'username': 'mama',
      'displayName': '妈妈',
      'role': 'admin',
    },
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
        localStoreProvider.overrideWithValue(MemoryLocalStore()),
        secureStoreProvider.overrideWithValue(secure),
        sessionRepoProvider.overrideWithValue(session),
        ledgerProvider.overrideWith(FakeLedger.new),
        importRepoProvider.overrideWithValue(
          ImportRepo(
            ApiClient(
              baseUrl: 'https://x.dev',
              token: 'tok',
              inner: harness.client,
            ),
          ),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: ImportPreviewPage(preview: preview),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return harness;
}

Checkbox checkbox(WidgetTester tester, int index) =>
    tester.widget<Checkbox>(find.byKey(ValueKey('import-check-$index')));

Finder inRow(int index, String text) => find.descendant(
  of: find.byKey(ValueKey('import-row-$index')),
  matching: find.text(text),
);

Future<void> scrollTo(WidgetTester tester, int index) =>
    tester.scrollUntilVisible(
      find.byKey(ValueKey('import-row-$index')),
      200,
      scrollable: find.byType(Scrollable).last,
    );

void main() {
  testWidgets('勾选规则：跳过的灰掉不能勾；导入过/可能重复的默认不勾并标出来', (tester) async {
    await pumpPreview(tester, size: const Size(800, 1400));

    expect(find.byKey(const ValueKey('import-summary')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('import-summary'))).data,
      '支付宝账单共 6 笔：5 笔能导，1 笔跳过；其中 1 笔导入过、1 笔可能重复，先没勾。',
    );

    for (final i in [0, 1, 2]) {
      expect(checkbox(tester, i).value, isTrue, reason: '第 ${i + 1} 行');
    }
    expect(checkbox(tester, 3).value, isFalse);
    expect(checkbox(tester, 3).onChanged, isNull, reason: 'skip 行不能勾');
    expect(inRow(3, '不计收支（转账、充值、理财等），不记账'), findsOneWidget);
    expect(checkbox(tester, 4).value, isFalse);
    expect(inRow(4, '已导入过'), findsOneWidget);
    expect(checkbox(tester, 5).value, isFalse);
    expect(inRow(5, '可能重复'), findsOneWidget);
    // 机器猜的类别要说是猜的。
    expect(inRow(1, '交通 · 猜的 82%'), findsOneWidget);
    expect(inRow(0, '没类别'), findsOneWidget);
    expect(find.text('导入 3 笔'), findsOneWidget);
    expect(find.text('已勾 3 笔'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('import-check-4')));
    await tester.pump();
    expect(find.text('导入 4 笔'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('import-check-3')));
    await tester.pump();
    expect(find.text('导入 4 笔'), findsOneWidget, reason: '点跳过的行没有反应');

    await tester.tap(find.byKey(const ValueKey('import-check-0')));
    await tester.pump();
    expect(find.text('导入 3 笔'), findsOneWidget);
  });

  testWidgets('多选批量改类别，只改同方向的；提交体带 source/clientId，learn 只发改过的行', (
    tester,
  ) async {
    final harness = await pumpPreview(tester, size: const Size(800, 1400));

    await tester.tap(find.byTooltip('多选'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('import-row-0')));
    await tester.tap(find.byKey(const ValueKey('import-row-1')));
    await tester.tap(find.byKey(const ValueKey('import-row-2')));
    await tester.tap(
      find.byKey(const ValueKey('import-row-3')),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(find.text('选了 3 笔'), findsOneWidget, reason: '跳过的行选不中');

    await tester.tap(find.text('改类别'));
    await tester.pumpAndSettle();
    // 一笔收入混在里面：默认改占多数的支出，并说清楚收入那笔不动。
    expect(find.text('给选中的 2 笔支出改类别'), findsOneWidget);
    expect(find.text('支出和收入的类别不通用，这次只改支出那 2 笔'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('category-c1')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('改基金'));
    await tester.pumpAndSettle();
    expect(find.text('给选中的 3 笔改基金'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('batch-fund-f2')));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('退出多选'));
    await tester.pumpAndSettle();
    expect(inRow(0, '餐饮'), findsOneWidget);
    expect(inRow(1, '餐饮'), findsOneWidget, reason: '改过就不再标「猜的」');
    expect(inRow(2, '没类别'), findsOneWidget, reason: '收入那笔不挂支出类别');
    expect(inRow(2, '个人零花'), findsOneWidget);
    expect(find.text('你改过类别或基金的 3 笔会拿去学'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('import-submit')));
    await tester.pumpAndSettle();

    final batch = harness.bodiesOf('/transactions/batch').single;
    final items = (batch['items'] as List).cast<Map<String, dynamic>>();
    expect(items.map((e) => e['clientId']), ['imp-1', 'imp-2', 'imp-3']);
    expect(items.every((e) => e['source'] == 'import'), isTrue);
    expect(items.map((e) => e['categoryId']), ['c1', 'c1', null]);
    expect(items.map((e) => e['fundId']), ['f2', 'f2', 'f2']);
    expect(items.first['occurredAt'], '2026-09-11T12:30:00+08:00');
    expect(items.first['accountId'], 'a1');

    final samples = (harness.bodiesOf('/model/learn').single['samples'] as List)
        .cast<Map<String, dynamic>>();
    expect(samples.map((s) => s['text']), ['美团', '滴滴', '老王转账']);
    expect(samples.map((s) => s['categoryId']), ['c1', 'c1', null]);
    expect(samples.map((s) => s['fundId']), ['f2', 'f2', 'f2']);
    expect(samples.first['channel'], 'alipay');
    expect(samples.first['memberId'], 'm1');

    expect(find.byKey(const ValueKey('import-result-title')), findsOneWidget);
    expect(find.text('导入好了'), findsOneWidget);
    expect(find.text('3 笔'), findsOneWidget);
    expect(find.text('拿你改过的 3 笔教了自动识别。'), findsOneWidget);
  });

  testWidgets('整批没送到：留在核对页说原因、给重试，改过的类别还在；重试成功才进结果页', (tester) async {
    final harness = await pumpPreview(tester, size: const Size(800, 1400));
    harness.batchPlan.add('down');

    await tester.tap(find.byKey(const ValueKey('import-row-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('category-c1')));
    await tester.pump();
    await tester.tap(find.text('好了'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('import-submit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('import-result-title')), findsNothing);
    expect(find.byKey(const ValueKey('import-submit-error')), findsOneWidget);
    expect(
      find.textContaining('一笔都没导进去。刚才改的都还在，可以直接重试。'),
      findsOneWidget,
    );
    expect(inRow(0, '餐饮'), findsOneWidget, reason: '手改的类别没丢');
    expect(find.text('导入 3 笔'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('import-submit-error')),
        matching: find.text('重试'),
      ),
    );
    await tester.pumpAndSettle();

    final batches = harness.bodiesOf('/transactions/batch');
    expect(batches, hasLength(2));
    final retried = (batches.last['items'] as List).cast<Map<String, dynamic>>();
    expect(retried.map((e) => e['clientId']), ['imp-1', 'imp-2', 'imp-3']);
    expect(retried.first['categoryId'], 'c1', reason: '按核对好的样子重发');
    expect(find.text('导入好了'), findsOneWidget);
    expect(find.byKey(const ValueKey('import-retry-failed')), findsNothing);
    // 学的是重试时落了地的那笔手改
    final samples = (harness.bodiesOf('/model/learn').single['samples'] as List)
        .cast<Map<String, dynamic>>();
    expect(samples.map((s) => s['text']), ['美团']);
  });

  testWidgets('部分没导进去：结果页给「重试没导进去的 N 笔」，只重发那几笔并把数加起来', (tester) async {
    final harness = await pumpPreview(tester, size: const Size(800, 1400));
    harness.batchPlan.add({'imp-2'});

    await tester.tap(find.byKey(const ValueKey('import-submit')));
    await tester.pumpAndSettle();
    expect(find.text('有 1 笔没导进去'), findsOneWidget);
    expect(find.text('类别不存在（第 2 笔）'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('import-retry-failed')));
    await tester.pumpAndSettle();

    final batches = harness.bodiesOf('/transactions/batch');
    expect(batches, hasLength(2));
    final retried = (batches.last['items'] as List).cast<Map<String, dynamic>>();
    expect(retried.map((e) => e['clientId']), ['imp-2']);
    expect(find.text('导入好了'), findsOneWidget);
    expect(find.text('3 笔'), findsOneWidget, reason: '新增 = 第一次 2 笔 + 重试 1 笔');
    expect(find.byKey(const ValueKey('import-retry-failed')), findsNothing);
  });

  testWidgets('点一行单独改类别和基金；关掉训练开关就不调 learn', (tester) async {
    final harness = await pumpPreview(tester, size: const Size(800, 1400));

    await tester.tap(find.byKey(const ValueKey('import-row-2')));
    await tester.pumpAndSettle();
    // 收入那笔只给收入类别。
    expect(find.byKey(const ValueKey('category-c1')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('category-c9')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('sheet-fund-f2')));
    await tester.pump();
    await tester.tap(find.text('好了'));
    await tester.pumpAndSettle();
    expect(inRow(2, '工资'), findsOneWidget);
    expect(inRow(2, '个人零花'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('import-learn')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('import-submit')));
    await tester.pumpAndSettle();

    final items =
        (harness.bodiesOf('/transactions/batch').single['items'] as List)
            .cast<Map<String, dynamic>>();
    final income = items.firstWhere((e) => e['clientId'] == 'imp-3');
    expect(income['categoryId'], 'c9');
    expect(income['fundId'], 'f2');
    expect(income['type'], 'income');
    expect(harness.bodiesOf('/model/learn'), isEmpty);
  });

  testWidgets('筛出没类别的行，全选后一次改掉', (tester) async {
    final harness = await pumpPreview(tester, size: const Size(800, 1400));

    await tester.tap(find.byKey(const ValueKey('import-filter-uncategorized')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('import-row-1')),
      findsNothing,
      reason: '滴滴已经猜了交通',
    );
    expect(
      find.byKey(const ValueKey('import-row-3')),
      findsNothing,
      reason: '跳过的不算',
    );

    await tester.tap(find.byTooltip('多选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pump();
    // 美团、老王转账、盒马、全家；收入那笔默认不改。
    expect(find.text('选了 4 笔'), findsOneWidget);
    await tester.tap(find.text('导入'));
    await tester.pump();
    await tester.tap(find.text('改类别'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('category-c1')));
    await tester.pumpAndSettle();
    // 三笔支出有了类别、掉出这个筛选，就不再选着；剩下没改的收入那笔。
    expect(find.text('选了 1 笔'), findsOneWidget);
    await tester.tap(find.byTooltip('退出多选'));
    await tester.pumpAndSettle();

    expect(find.text('导入 5 笔'), findsOneWidget, reason: '批量「导入」把导入过/可能重复的也勾上了');
    await tester.tap(find.byKey(const ValueKey('import-submit')));
    await tester.pumpAndSettle();
    final items =
        (harness.bodiesOf('/transactions/batch').single['items'] as List)
            .cast<Map<String, dynamic>>();
    expect(
      {for (final e in items) e['clientId']: e['categoryId']},
      {
        'imp-1': 'c1',
        'imp-2': 'c2',
        'imp-3': null,
        'imp-5': 'c1',
        'imp-6': 'c1',
      },
    );
  });

  testWidgets('被筛选藏起来的行不再算选中：批量改只动看得见的那几笔', (tester) async {
    await pumpPreview(tester, size: const Size(800, 1400));

    await tester.tap(find.byKey(const ValueKey('import-filter-uncategorized')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('多选'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('import-row-0')));
    await tester.pump();
    await tester.tap(find.text('改类别'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('category-c1')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('import-row-0')),
      findsNothing,
      reason: '有了类别就掉出「没类别」',
    );
    expect(find.text('选了 0 笔'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('import-row-5')));
    await tester.pump();
    expect(find.text('选了 1 笔'), findsOneWidget);
    await tester.tap(find.text('改类别'));
    await tester.pumpAndSettle();
    expect(find.text('给选中的 1 笔支出改类别'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('category-c2')));
    await tester.pumpAndSettle();

    // 换筛选也一样：看不见的就不再选着。
    await tester.tap(find.byKey(const ValueKey('import-filter-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('import-row-1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('import-filter-skipped')));
    await tester.pumpAndSettle();
    expect(find.text('选了 0 笔'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('import-filter-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('退出多选'));
    await tester.pumpAndSettle();

    expect(inRow(0, '餐饮'), findsOneWidget, reason: '第一次改的那笔不被第二次覆盖');
    expect(inRow(0, '交通'), findsNothing);
    expect(inRow(5, '交通'), findsOneWidget);
    expect(inRow(1, '交通 · 猜的 82%'), findsOneWidget);
  });

  testWidgets('跳过的行不整行调透明度：跳过原因要看得清', (tester) async {
    await pumpPreview(tester, size: const Size(800, 1400));
    final reason = inRow(3, '不计收支（转账、充值、理财等），不记账');
    expect(reason, findsOneWidget);
    final faded = find.ancestor(
      of: reason,
      matching: find.byWidgetPredicate((w) => w is Opacity && w.opacity < 1),
    );
    expect(faded, findsNothing);
    final style = tester.widget<Text>(reason).style;
    final theme = Theme.of(tester.element(reason));
    expect(style?.color?.a, 1.0);
    expect(style?.color, theme.textTheme.bodySmall?.color);
  });

  testWidgets('宽屏（≥840）页边距 24，跟选文件页一致', (tester) async {
    await pumpPreview(tester, size: const Size(1400, 900));
    final gutter = (1400 - 960) / 2;
    final summary = tester.getTopLeft(
      find.byKey(const ValueKey('import-summary')),
    );
    expect(summary.dx, gutter + LedgerLayout.widePagePadding);
    final submit = tester.getTopRight(
      find.byKey(const ValueKey('import-submit')),
    );
    expect(submit.dx, 1400 - gutter - LedgerLayout.widePagePadding);

    await pumpPreview(tester, size: const Size(800, 900));
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('import-summary'))).dx,
      LedgerLayout.pagePadding,
    );
  });

  testWidgets('宽屏上鼠标停在两侧空白处，滚轮照样能滚列表', (tester) async {
    await pumpPreview(tester, size: const Size(1400, 500));
    final list = find
        .descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        )
        .first;
    double offset() => tester.state<ScrollableState>(list).position.pixels;
    expect(
      tester.state<ScrollableState>(list).position.maxScrollExtent,
      greaterThan(0),
    );

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    pointer.hover(const Offset(60, 300));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 200)));
    await tester.pumpAndSettle();
    expect(offset(), greaterThan(0));
  });

  for (final width in [400.0, 800.0, 1400.0]) {
    testWidgets('宽 $width：核对、多选、结果三种状态都不溢出', (tester) async {
      await pumpPreview(tester, size: Size(width, 900));
      expect(tester.takeException(), isNull);
      await scrollTo(tester, 5);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byTooltip('多选'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('import-row-5')));
      await tester.pump();
      await tester.tap(find.text('改类别'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('category-c2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('退出多选'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('import-row-5')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('好了'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('import-submit')));
      await tester.pumpAndSettle();
      expect(find.text('导入好了'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
