import 'dart:convert';

import 'package:famledger/app/providers.dart';
import 'package:famledger/app/theme.dart';
import 'package:famledger/core/dates.dart';
import 'package:famledger/data/api/api_client.dart';
import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/data/local/secure_store.dart';
import 'package:famledger/data/repos/session_repo.dart';
import 'package:famledger/ui/settings/accounts_page.dart';
import 'package:famledger/ui/settings/budgets_page.dart';
import 'package:famledger/ui/settings/categories_page.dart';
import 'package:famledger/ui/settings/members_page.dart';
import 'package:famledger/ui/settings/rule_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final String thisMonth = Dates.currentMonth();

http.Response jsonOk(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

final Map<String, dynamic> changesBody = {
  'since': 0,
  'next': 12,
  'more': false,
  'members': [
    {
      'id': 'm1',
      'username': 'mama',
      'displayName': '妈妈',
      'role': 'admin',
      'avatarEmoji': '👩',
    },
    {'id': 'm2', 'username': 'baba', 'displayName': '爸爸', 'role': 'member'},
  ],
  'accounts': [
    {
      'id': 'a1',
      'name': '工行储蓄卡',
      'kind': 'bank',
      'sortOrder': 0,
      'ownerMemberId': 'm1',
      'matchHints': {
        'cardTails': ['6688'],
      },
    },
    {'id': 'a2', 'name': '招行储蓄卡', 'kind': 'bank', 'sortOrder': 1},
    {'id': 'a3', 'name': '我的支付宝', 'kind': 'alipay', 'sortOrder': 2},
    {'id': 'a4', 'name': '钱包', 'kind': 'cash', 'sortOrder': 3, 'archived': true},
  ],
  'funds': [
    {'id': 'f1', 'name': '家庭公共', 'kind': 'shared', 'sortOrder': 0},
    {'id': 'f2', 'name': '个人零花', 'kind': 'personal', 'sortOrder': 1},
    {'id': 'f3', 'name': '旅行基金', 'kind': 'goal', 'sortOrder': 2},
  ],
  'categories': [
    {'id': 'c1', 'name': '餐饮', 'kind': 'expense', 'sortOrder': 0},
    {'id': 'c1a', 'name': '早餐', 'kind': 'expense', 'parentId': 'c1', 'sortOrder': 1},
    {'id': 'c3', 'name': '交通', 'kind': 'expense', 'sortOrder': 2},
    {'id': 'c2', 'name': '工资', 'kind': 'income', 'sortOrder': 0},
  ],
  'transactions': [],
  'budgets': [
    {'id': 'b1', 'scope': 'fund', 'refId': 'f1', 'month': '*', 'amountCents': 200000},
    // f2 只有「仅本月」那一行，f3 什么都没有。
    {'id': 'b2', 'scope': 'fund', 'refId': 'f2', 'month': thisMonth, 'amountCents': 100000},
  ],
  'rules': [
    {
      'id': 'r1',
      'priority': 10,
      'field': 'merchant',
      'op': 'contains',
      'pattern': '星巴克',
      'categoryId': 'c1',
      'enabled': true,
    },
  ],
};

Map<String, dynamic> overviewBody() => {
  'netWorthCents': 350000,
  'assetsCents': 350000,
  'liabilitiesCents': 0,
  'pendingCount': 0,
  'funds': [],
  'accounts': [
    {'accountId': 'a1', 'balanceCents': 100000},
    {'accountId': 'a2', 'balanceCents': 200000},
    {'accountId': 'a3', 'balanceCents': 50000},
  ],
  'month': {
    'expenseCents': 210000,
    'incomeCents': 0,
    'byFund': [
      {'fundId': 'f1', 'expenseCents': 210000},
    ],
    'byCategory': [],
    'byMember': [],
    'budgets': [
      {'scope': 'fund', 'refId': 'f1', 'budgetCents': 200000, 'spentCents': 210000},
    ],
  },
};

/// 假服务器。`PUT /*/reorder` 会像真服务端那样按下标改写 sortOrder，
/// 下一次 `/changes` 就带着新顺序回来 —— 不这么做就测不出「拖完真的存住了」。
MockClient settingsApi({
  List<http.Request>? seen,
  bool statsFail = false,
  bool reorderFail = false,
}) {
  final sortOverride = <String, int>{};

  List<Map<String, dynamic>> rowsOf(String key) => [
    for (final row in changesBody[key] as List)
      {
        ...Map<String, dynamic>.from(row as Map),
        if (sortOverride.containsKey((row)['id']))
          'sortOrder': sortOverride[(row)['id']],
      },
  ];

  return MockClient((request) async {
    seen?.add(request);
    final path = request.url.path;
    if (path.endsWith('/reorder')) {
      if (reorderFail) return boom('排序存不上');
      final ids = ((jsonDecode(request.body) as Map)['ids'] as List)
          .cast<String>();
      for (var i = 0; i < ids.length; i++) {
        sortOverride[ids[i]] = i;
      }
      return jsonOk(const {'items': []});
    }
    if (path.endsWith('/changes')) {
      return jsonOk({
        ...changesBody,
        'accounts': rowsOf('accounts'),
        'categories': rowsOf('categories'),
      });
    }
    if (path.endsWith('/stats/overview')) {
      return statsFail ? boom('统计算不出来') : jsonOk(overviewBody());
    }
    // 其他写操作回什么无所谓，用例断言的是「发了什么请求」。
    return jsonOk(const {'id': 'x', 'name': 'x', 'kind': 'bank', 'scope': 'fund'});
  });
}

http.Response boom(String message) => http.Response(
  jsonEncode({
    'error': {'code': 'boom', 'message': message},
  }),
  500,
  headers: {'content-type': 'application/json'},
);

/// 请求体里那个 JSON。
Map<String, dynamic> bodyOf(http.Request request) =>
    jsonDecode(request.body) as Map<String, dynamic>;

http.Request? lastWhere(
  List<http.Request> seen,
  String method,
  String pathEnd,
) {
  for (final request in seen.reversed) {
    if (request.method == method && request.url.path.endsWith(pathEnd)) {
      return request;
    }
  }
  return null;
}

Future<ProviderContainer> boot(
  MockClient client, {
  String role = 'admin',
}) async {
  final secure = MemorySecureStore();
  secure.data[SessionRepo.baseUrlKey] = 'https://x.dev';
  secure.data[SessionRepo.sessionKey] = jsonEncode({
    'baseUrl': 'https://x.dev',
    'token': 'tok',
    'deviceId': 'dev',
    'me': {
      'id': role == 'admin' ? 'm1' : 'm2',
      'username': role == 'admin' ? 'mama' : 'baba',
      'displayName': role == 'admin' ? '妈妈' : '爸爸',
      'role': role,
    },
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

/// 骨架是永动动画，不能 pumpAndSettle；手动推帧等请求落地。
Future<void> pumpPage(
  WidgetTester tester,
  ProviderContainer container,
  Widget page, {
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
      child: MaterialApp(theme: buildTheme(Brightness.light), home: page),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// 推几帧：弹层/对话框是滑上来的，一帧 pump 只够它开始动，点不到里面的按钮。
Future<void> settle(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// 把第 [from] 项挪到第 [to] 个位置。
///
/// 直接调 `ReorderableListView.onReorder`，不去模拟像素拖拽 —— 手势落点和动画
/// 时序跟机器负载有关，并发跑测试时会偶发失败（真出过）。这里要验的是「挪完
/// 之后顺序对不对、发出去的 ids 对不对」，跟手指怎么动没关系。
Future<void> reorderVia(WidgetTester tester, int from, int to) async {
  final list = tester.widget<ReorderableListView>(
    find.byType(ReorderableListView),
  );
  list.onReorder(from, to);
  await settle(tester);
}

/// 列表当前显示的顺序（按 widget 树的顺序读，不看坐标）。
List<String> listedTitles(WidgetTester tester) => [
  for (final tile in tester.widgetList<ListTile>(find.byType(ListTile)))
    if (tile.title case final Text text) text.data ?? '',
];

void main() {
  group('账户', () {
    testWidgets('按类型分组，每组带小计，每行带余额', (tester) async {
      await pumpPage(tester, await boot(settingsApi()), const AccountsPage());

      expect(find.text('银行卡'), findsOneWidget);
      expect(find.text('支付宝'), findsOneWidget);
      expect(find.text('工行储蓄卡'), findsOneWidget);
      expect(find.text('招行储蓄卡'), findsOneWidget);
      expect(find.text('我的支付宝'), findsOneWidget);

      // 余额来自 /stats/overview 的 accounts
      expect(find.text('¥1,000.00'), findsOneWidget);
      expect(find.text('¥2,000.00'), findsOneWidget);
      // 银行卡小计 1000 + 2000
      expect(find.text('¥3,000.00'), findsOneWidget);
      // 归档的单独一组，不混进「现金」：一个分组标题 + 一个行内标签
      expect(find.text('已归档'), findsNWidgets(2));
      expect(find.text('钱包'), findsOneWidget);
      expect(find.text('现金'), findsNothing);
    });

    testWidgets('账户行的副标题给出归属与识别线索', (tester) async {
      await pumpPage(tester, await boot(settingsApi()), const AccountsPage());
      expect(find.text('妈妈 · 尾号 6688'), findsOneWidget);
      expect(find.text('家庭共用'), findsWidgets);
    });
  });

  group('成员', () {
    testWidgets('非管理员看不到任何写操作', (tester) async {
      await pumpPage(
        tester,
        await boot(settingsApi(), role: 'member'),
        const MembersPage(),
      );

      expect(find.text('妈妈'), findsOneWidget);
      expect(find.text('爸爸'), findsOneWidget);
      expect(find.text('添加成员'), findsNothing);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.byIcon(Icons.chevron_right), findsNothing);
      expect(find.text('只有管理员能添加成员、改角色或重置密码。'), findsOneWidget);

      // 点一下也不该弹出编辑表单
      await tester.tap(find.text('妈妈'));
      await settle(tester);
      expect(find.text('编辑成员'), findsNothing);
    });

    testWidgets('管理员能添加、能点开编辑', (tester) async {
      await pumpPage(tester, await boot(settingsApi()), const MembersPage());

      expect(find.text('添加成员'), findsOneWidget);
      await tester.tap(find.text('爸爸'));
      await settle(tester);
      expect(find.text('编辑成员'), findsOneWidget);
      expect(find.text('@baba'), findsOneWidget);
      // 管理员可以归档别人
      expect(find.text('归档'), findsOneWidget);
    });

    testWidgets('管理员改不了自己的角色，也归档不了自己', (tester) async {
      await pumpPage(tester, await boot(settingsApi()), const MembersPage());

      await tester.tap(find.text('妈妈'));
      await settle(tester);
      expect(find.text('这是你自己：角色与归档只能由别的管理员改。'), findsOneWidget);
      expect(find.text('归档'), findsNothing);
    });
  });

  group('类别', () {
    testWidgets('两个页签，子类别挂在父类别下面', (tester) async {
      await pumpPage(tester, await boot(settingsApi()), const CategoriesPage());

      expect(find.text('支出'), findsWidgets);
      expect(find.text('收入'), findsWidgets);
      expect(find.text('餐饮'), findsOneWidget);
      expect(find.text('早餐'), findsOneWidget);
      // 收入类别不该出现在支出页签里
      expect(find.text('工资'), findsNothing);
    });
  });

  group('预算', () {
    testWidgets('超支的基金给出超支金额与百分比', (tester) async {
      await pumpPage(tester, await boot(settingsApi()), const BudgetsPage());

      expect(find.text(Dates.monthLabel(thisMonth)), findsOneWidget);
      expect(find.text('家庭公共'), findsOneWidget);
      // 2100 花掉 / 2000 上限
      expect(find.text('超支 ¥100.00'), findsOneWidget);
      expect(find.text('已用 105%'), findsOneWidget);
      // 没预算的基金说清楚下一步
      expect(find.text('未设预算 · 点一下定个上限'), findsOneWidget);
    });

    testWidgets('点一条预算能改金额，默认是每月默认', (tester) async {
      await pumpPage(tester, await boot(settingsApi()), const BudgetsPage());

      await tester.tap(find.text('家庭公共'));
      await settle(tester);
      expect(find.text('家庭公共 的预算'), findsOneWidget);
      expect(find.text('每月默认'), findsOneWidget);
      expect(find.text('仅 ${Dates.monthLabel(thisMonth)}'), findsOneWidget);
      expect(find.text('取消预算'), findsOneWidget);
    });
  });

  group('识别规则', () {
    testWidgets('「测试匹配」用的就是自动记账那套匹配', (tester) async {
      await pumpPage(
        tester,
        await boot(settingsApi()),
        const Scaffold(body: RuleFormSheet()),
      );

      await tester.enterText(find.byType(TextField).at(0), '星巴克');
      await tester.pump();
      await tester.enterText(find.byType(TextField).at(1), '星巴克咖啡 支付 35 元');
      await tester.pump();
      expect(find.text('命中，会按下面的设置填'), findsOneWidget);

      await tester.enterText(find.byType(TextField).at(1), '肯德基 支付 35 元');
      await tester.pump();
      expect(find.text('没命中'), findsOneWidget);
    });

    testWidgets('正则写错了当场说，不等到半夜', (tester) async {
      await pumpPage(
        tester,
        await boot(settingsApi()),
        const Scaffold(body: RuleFormSheet()),
      );

      await tester.tap(find.text('正则'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).at(0), '[未闭合');
      await tester.pump();
      expect(
        find.textContaining('正则不对'),
        findsOneWidget,
        reason: '正则编译不过要在输入框下面直接说',
      );
    });
  });

  group('归档（回归：以前发的是 DELETE）', () {
    testWidgets('归档账户走 PATCH archived，不发 DELETE', (tester) async {
      final seen = <http.Request>[];
      await pumpPage(
        tester,
        await boot(settingsApi(seen: seen)),
        const AccountsPage(),
      );

      await tester.tap(find.text('工行储蓄卡'));
      await settle(tester);
      await tester.tap(find.text('归档'));
      await settle(tester);
      // 二次确认
      await tester.tap(find.widgetWithText(FilledButton, '归档'));
      await settle(tester);

      final patch = lastWhere(seen, 'PATCH', '/accounts/a1');
      expect(patch, isNotNull, reason: '归档应该是 PATCH {archived:true}');
      expect(bodyOf(patch!)['archived'], true);
      // DELETE 是软删打墓碑：行会从各设备消失，还会被 409 挡，绝不能用。
      expect(seen.any((r) => r.method == 'DELETE'), isFalse);
    });

    testWidgets('已归档的账户给的是「取消归档」，一步收回', (tester) async {
      final seen = <http.Request>[];
      await pumpPage(
        tester,
        await boot(settingsApi(seen: seen)),
        const AccountsPage(),
      );

      await tester.tap(find.text('钱包'));
      await settle(tester);
      expect(find.text('取消归档'), findsOneWidget);
      expect(find.text('归档'), findsNothing);

      await tester.tap(find.text('取消归档'));
      await settle(tester);

      final patch = lastWhere(seen, 'PATCH', '/accounts/a4');
      expect(bodyOf(patch!)['archived'], false);
    });

    testWidgets('归档类别也走 PATCH，不发 DELETE', (tester) async {
      final seen = <http.Request>[];
      await pumpPage(
        tester,
        await boot(settingsApi(seen: seen)),
        const CategoriesPage(),
      );

      await tester.tap(find.text('餐饮'));
      await settle(tester);
      await tester.tap(find.text('归档'));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, '归档'));
      await settle(tester);

      final patch = lastWhere(seen, 'PATCH', '/categories/c1');
      expect(bodyOf(patch!)['archived'], true);
      expect(seen.any((r) => r.method == 'DELETE'), isFalse);
    });
  });

  group('成员 PATCH（回归：以前会被服务端 400）', () {
    testWidgets('没设颜色/头像的成员，PATCH 里不带这两个字段', (tester) async {
      final seen = <http.Request>[];
      await pumpPage(
        tester,
        await boot(settingsApi(seen: seen)),
        const MembersPage(),
      );

      await tester.tap(find.text('爸爸'));
      await settle(tester);
      await tester.tap(find.text('保存'));
      await settle(tester);

      final patch = lastWhere(seen, 'PATCH', '/members/m2');
      expect(patch, isNotNull);
      final body = bodyOf(patch!);
      expect(body['displayName'], '爸爸');
      // color: null 会被 members.js 的 required 校验 400；avatarEmoji: null 服务端
      // 当「不改」。两个都没值就别发。
      expect(body.containsKey('color'), isFalse);
      expect(body.containsKey('avatarEmoji'), isFalse);
    });

    testWidgets('编辑成员时不摆「自动配色」这个存不进去的选项', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpPage(tester, await boot(settingsApi()), const MembersPage());

      await tester.tap(find.text('爸爸'));
      await settle(tester);
      expect(find.bySemanticsLabel('自动配色'), findsNothing);

      await tester.tap(find.text('取消'));
      await settle(tester);
      // 新建时可以交给服务端按顺序取色，那一格就该在。
      await tester.tap(find.text('添加成员'));
      await settle(tester);
      expect(find.bySemanticsLabel('自动配色'), findsOneWidget);
      // 语义句柄得在测试体里关掉，tearDown 太晚了。
      handle.dispose();
    });
  });

  group('排序（回归：以前只发一部分 id）', () {
    testWidgets('账户排序发全量 id，归档的垫底', (tester) async {
      final seen = <http.Request>[];
      await pumpPage(
        tester,
        await boot(settingsApi(seen: seen)),
        const AccountsPage(),
      );

      await tester.tap(find.text('排序'));
      await settle(tester);
      // 把「工行储蓄卡」挪到「招行储蓄卡」后面
      await reorderVia(tester, 0, 2);

      final put = lastWhere(seen, 'PUT', '/accounts/reorder');
      expect(put, isNotNull);
      final ids = (bodyOf(put!)['ids'] as List).cast<String>();
      // 服务端按下标写 sort_order，漏发的行就会和别人撞号。
      expect(ids.toSet(), {'a1', 'a2', 'a3', 'a4'});
      expect(ids.last, 'a4', reason: '归档的排最后');
      expect(ids, ['a2', 'a1', 'a3', 'a4'], reason: '顺序确实变了');
      // 假服务器按提交的 ids 写回 sortOrder，同步回来后界面就是新顺序。
      expect(listedTitles(tester), ['招行储蓄卡', '工行储蓄卡', '我的支付宝']);
    });

    testWidgets('排序存不上就摆回原顺序并行内报错', (tester) async {
      await pumpPage(
        tester,
        await boot(settingsApi(reorderFail: true)),
        const AccountsPage(),
      );

      await tester.tap(find.text('排序'));
      await settle(tester);
      await reorderVia(tester, 0, 2);

      expect(find.textContaining('顺序没存上'), findsOneWidget);
      expect(
        listedTitles(tester),
        ['工行储蓄卡', '招行储蓄卡', '我的支付宝'],
        reason: '写失败了就得摆回去，不能让界面显示一个服务端没有的顺序',
      );
    });

    testWidgets('类别排序发的是两个页签 + 子类别 + 归档的全量 id', (tester) async {
      final seen = <http.Request>[];
      await pumpPage(
        tester,
        await boot(settingsApi(seen: seen)),
        const CategoriesPage(),
      );

      await tester.tap(find.text('排序'));
      await settle(tester);
      // 把「餐饮」挪到「交通」后面
      await reorderVia(tester, 0, 2);

      final put = lastWhere(seen, 'PUT', '/categories/reorder');
      expect(put, isNotNull);
      final ids = (bodyOf(put!)['ids'] as List).cast<String>();
      expect(ids.toSet(), {'c1', 'c1a', 'c3', 'c2'});
      // 子类别永远紧跟着自己的父类别
      expect(ids.indexOf('c1a'), ids.indexOf('c1') + 1);
      // 收入页签那条也在里面，不然它的 sort_order 会被支出那几行撞掉
      expect(ids.contains('c2'), isTrue);
      expect(ids, ['c3', 'c1', 'c1a', 'c2'], reason: '顺序确实变了');
      expect(listedTitles(tester), ['交通', '餐饮']);
    });
  });

  group('预算（回归）', () {
    testWidgets('统计取不到时花销写「—」，不画进度条', (tester) async {
      await pumpPage(
        tester,
        await boot(settingsApi(statsFail: true)),
        const BudgetsPage(),
      );

      expect(find.text('这个月的花销没取到，下面只显示预算金额。'), findsOneWidget);
      // 以前这里会写 ¥0.00 / 已用 0%，等于告诉用户「这个月一分没花」。
      expect(find.text('—'), findsWidgets);
      expect(find.text('¥0.00'), findsNothing);
      expect(find.textContaining('已用'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      // 预算金额本身还是能看的
      expect(find.text('¥2,000.00'), findsOneWidget);
    });

    testWidgets('「取消预算」删的是真实存在的那一行，不是分段器选中的月份', (tester) async {
      final seen = <http.Request>[];
      await pumpPage(
        tester,
        await boot(settingsApi(seen: seen)),
        const BudgetsPage(),
      );

      // f1 只有「每月默认」那一行
      await tester.tap(find.text('家庭公共'));
      await settle(tester);
      // 故意把分段器拨到「仅本月」，看它会不会把删除带偏
      await tester.tap(find.text('仅 ${Dates.monthLabel(thisMonth)}'));
      await settle(tester);
      await tester.tap(find.text('取消预算'));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, '取消预算'));
      await settle(tester);

      final put = lastWhere(seen, 'PUT', '/budgets');
      expect(put, isNotNull);
      final body = bodyOf(put!);
      expect(body['month'], '*', reason: '真实存在的是每月默认那一行');
      expect(body['amountCents'], isNull);
    });

    testWidgets('从「仅本月」改回「每月默认」会把本月的覆盖一起清掉', (tester) async {
      final seen = <http.Request>[];
      await pumpPage(
        tester,
        await boot(settingsApi(seen: seen)),
        const BudgetsPage(),
      );

      // f2 只有「仅本月」那一行，行上应该挂着标签
      expect(find.text('仅本月'), findsOneWidget);
      await tester.tap(find.text('个人零花'));
      await settle(tester);
      await tester.tap(find.text('每月默认'));
      await settle(tester);
      await tester.tap(find.text('保存'));
      await settle(tester);

      final puts = seen
          .where((r) => r.method == 'PUT' && r.url.path.endsWith('/budgets'))
          .map(bodyOf)
          .toList();
      expect(puts.length, 2, reason: '先写默认值，再把本月的覆盖删掉');
      expect(puts[0]['month'], '*');
      expect(puts[1]['month'], thisMonth);
      expect(puts[1]['amountCents'], isNull);
    });
  });
}
