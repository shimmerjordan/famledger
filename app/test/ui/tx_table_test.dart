import 'package:famledger/app/providers.dart';
import 'package:famledger/app/shell.dart';
import 'package:famledger/app/theme.dart';
import 'package:famledger/data/api/api_client.dart';
import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/data/local/outbox.dart';
import 'package:famledger/data/local/secure_store.dart';
import 'package:famledger/data/models/models.dart';
import 'package:famledger/data/repos/ledger_repo.dart';
import 'package:famledger/data/repos/session_repo.dart';
import 'package:famledger/data/repos/transactions_repo.dart';
import 'package:famledger/ui/transactions/transactions_page.dart';
import 'package:famledger/ui/transactions/tx_table.dart';
import 'package:famledger/ui/transactions/tx_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const LedgerData ledger = LedgerData(
  funds: [
    Fund(id: 'f1', name: '家庭公共', color: '#c36a4f'),
    Fund(id: 'f2', name: '旅行基金'),
  ],
  categories: [
    Category(id: 'c1', name: '餐饮', icon: 'restaurant'),
    Category(id: 'c2', name: '交通', icon: 'directions_bus'),
    Category(id: 'c3', name: '工资', kind: 'income', icon: 'payments'),
  ],
  accounts: [
    Account(id: 'a1', name: '微信', kind: 'wechat'),
    Account(id: 'a2', name: '招行卡', kind: 'bank'),
  ],
  members: [Member(id: 'm1', username: 'dad', displayName: '爸爸')],
);

List<Transaction> sampleItems() {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day, 12, 30);
  return [
    Transaction(
      id: 't1',
      clientId: 'c-1',
      type: Transaction.typeExpense,
      amountCents: 3550,
      occurredAt: today,
      fundId: 'f1',
      accountId: 'a1',
      categoryId: 'c1',
      memberId: 'm1',
      merchant: '巷口面馆',
      note: '午饭',
    ),
    Transaction(
      id: 't2',
      clientId: 'c-2',
      type: Transaction.typeIncome,
      amountCents: 120000,
      occurredAt: today.subtract(const Duration(hours: 2)),
      fundId: 'f1',
      accountId: 'a2',
      categoryId: 'c3',
      memberId: 'm1',
      merchant: '公司',
    ),
    Transaction(
      id: 't3',
      clientId: 'c-3',
      type: Transaction.typeTransfer,
      amountCents: 50000,
      occurredAt: today.subtract(const Duration(days: 1)),
      fundId: 'f1',
      toFundId: 'f2',
      accountId: 'a1',
      toAccountId: 'a2',
    ),
    Transaction(
      id: 't4',
      clientId: 'c-4',
      type: Transaction.typeExpense,
      amountCents: 2300,
      occurredAt: today.subtract(const Duration(days: 1, hours: 3)),
      fundId: 'f2',
      accountId: 'a1',
      categoryId: 'c2',
      merchant: '滴滴出行',
      status: 'pending',
      source: 'notification',
    ),
  ];
}

class FakeLedger extends LedgerController {
  @override
  Future<LedgerData> build() async => ledger;

  @override
  Future<void> sync({bool full = false}) async {}
}

/// 列表从内存给；bulk 只记请求体，删掉的从内存里拿走，好看出「刷新过」。
class TableRepo extends TransactionsRepo {
  TableRepo()
    : items = sampleItems(),
      super(
        api: ApiClient(baseUrl: 'http://127.0.0.1'),
        outbox: Outbox(MemoryLocalStore()),
      );

  List<Transaction> items;
  final List<Map<String, dynamic>> bulkCalls = [];
  int listCalls = 0;
  ApiException? failWith;

  @override
  Future<TxPage> list(TxFilter filter, {String? cursor}) async {
    listCalls++;
    return TxPage(items: List.of(items));
  }

  @override
  Future<int> bulk(
    List<String> ids, {
    Map<String, dynamic>? patch,
    bool delete = false,
  }) async {
    bulkCalls.add({'ids': ids, if (delete) 'delete': true else 'patch': patch});
    final error = failWith;
    if (error != null) throw error;
    if (delete) items = items.where((tx) => !ids.contains(tx.id)).toList();
    return ids.length;
  }
}

Future<void> pumpPage(
  WidgetTester tester, {
  required TableRepo repo,
  double width = 1400,
  double height = 900,
  double railWidth = 0,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    initialLocation: '/transactions',
    routes: [
      GoRoute(
        path: '/transactions',
        // railWidth 模拟外壳的导航轨：840 宽的窗口里表格实际只有六百多。
        builder: (context, state) => railWidth == 0
            ? const TransactionsPage()
            : Row(
                children: [
                  SizedBox(width: railWidth),
                  const Expanded(child: TransactionsPage()),
                ],
              ),
      ),
      GoRoute(
        path: '/transactions/new',
        builder: (context, state) => const Scaffold(body: Text('记一笔页')),
      ),
      GoRoute(
        path: '/transactions/:id',
        builder: (context, state) =>
            Scaffold(body: Text('详情 ${state.pathParameters['id']}')),
      ),
      // 真正的导入页由另一路做，这里只看有没有往 /import 走。
      GoRoute(
        path: '/import',
        builder: (context, state) => const Scaffold(body: Text('导入页')),
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
        ledgerProvider.overrideWith(FakeLedger.new),
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

/// 和 app/router.dart 一样的外壳：五个分支，账单在第二个。用来看真实导航轨下的
/// 宽度，以及「切到别的 Tab 后，留在 Offstage 里的账单页不该再吃快捷键」。
Future<void> pumpShell(
  WidgetTester tester, {
  required TableRepo repo,
  double width = 1400,
  double height = 900,
  String initialLocation = '/transactions',
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  StatefulShellBranch stub(String path) => StatefulShellBranch(
    routes: [
      GoRoute(
        path: path,
        builder: (context, state) => Scaffold(body: Text('分支 $path')),
      ),
    ],
  );
  final router = GoRouter(
    initialLocation: initialLocation,
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) =>
            AdaptiveShell(navigationShell: shell),
        branches: [
          stub('/home'),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/transactions',
                builder: (context, state) => const TransactionsPage(),
              ),
            ],
          ),
          stub('/funds'),
          stub('/analysis'),
          stub('/settings'),
        ],
      ),
      GoRoute(
        path: '/transactions/new',
        builder: (context, state) => const Scaffold(body: Text('记一笔页')),
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
        ledgerProvider.overrideWith(FakeLedger.new),
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

Finder rowOf(String id) => find.byKey(ValueKey('tx-row-$id'));
Finder checkOf(String id) => find.byKey(ValueKey('tx-check-$id'));
final Finder checkAll = find.byKey(const ValueKey('tx-check-all'));

TextButton buttonOf(WidgetTester tester, String label) =>
    tester.widget<TextButton>(
      find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((w) => w is TextButton),
      ),
    );

Future<void> select(WidgetTester tester, List<String> ids) async {
  for (final id in ids) {
    await tester.tap(checkOf(id));
    await tester.pump();
  }
}

void main() {
  group('1400 宽：表格', () {
    testWidgets('表头七列，一笔一行，金额颜色照 MoneyText', (tester) async {
      await pumpPage(tester, repo: TableRepo());

      for (final label in ['日期', '类别', '商户 / 备注', '基金', '账户', '成员', '金额']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      for (final id in ['t1', 't2', 't3', 't4']) {
        expect(rowOf(id), findsOneWidget);
        expect(checkOf(id), findsOneWidget);
      }
      expect(find.byType(TxTile), findsNothing, reason: '宽屏不再是列表');

      final t1 = rowOf('t1');
      expect(
        find.descendant(of: t1, matching: find.text('今天 12:30')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: t1, matching: find.text('餐饮')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: t1, matching: find.text('巷口面馆 · 午饭')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: t1, matching: find.text('家庭公共')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: t1, matching: find.text('微信')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: t1, matching: find.text('爸爸')),
        findsOneWidget,
      );

      final expense = tester.widget<Text>(find.text('−¥35.50'));
      expect(
        expense.style?.color,
        buildTheme(Brightness.light).colorScheme.onSurface,
      );
      final income = tester.widget<Text>(find.text('+¥1,200.00'));
      expect(income.style?.color, LedgerColors.light.income);

      // 转账：两侧成对显示，不带正负号，也没有类别。
      final t3 = rowOf('t3');
      expect(
        find.descendant(of: t3, matching: find.text('转账')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: t3, matching: find.text('家庭公共 → 旅行基金')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: t3, matching: find.text('微信 → 招行卡')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: t3, matching: find.text('¥500.00')),
        findsOneWidget,
      );

      expect(
        find.descendant(of: rowOf('t4'), matching: find.text('待确认')),
        findsOneWidget,
      );
    });

    testWidgets('点行打开详情（和列表一样）', (tester) async {
      await pumpPage(tester, repo: TableRepo());

      await tester.tap(find.text('巷口面馆 · 午饭'));
      await tester.pumpAndSettle();

      expect(find.text('详情 t1'), findsOneWidget);
    });

    testWidgets('单选出工具条，表头全选框变半选；全选 / 再点取消', (tester) async {
      await pumpPage(tester, repo: TableRepo());
      expect(find.text('已选 1 笔'), findsNothing);

      await select(tester, ['t1']);
      expect(find.text('已选 1 笔'), findsOneWidget);
      for (final label in ['改类别', '改基金', '删除', '取消']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('日期'), findsNothing, reason: '工具条顶替了表头');
      expect(tester.widget<Checkbox>(checkAll).value, isNull);

      // 半选时点全选框 = 全部勾上。
      await tester.tap(checkAll);
      await tester.pump();
      expect(find.text('已选 4 笔'), findsOneWidget);
      expect(tester.widget<Checkbox>(checkAll).value, isTrue);
      expect(tester.widget<Checkbox>(checkOf('t3')).value, isTrue);

      await tester.tap(checkAll);
      await tester.pump();
      expect(find.text('日期'), findsOneWidget);
      expect(tester.widget<Checkbox>(checkAll).value, isFalse);

      // 取消单个：勾上再点一下。
      await select(tester, ['t2', 't2']);
      expect(find.textContaining('已选'), findsNothing);
    });

    testWidgets('工具条的「取消」清空选择', (tester) async {
      await pumpPage(tester, repo: TableRepo());
      await select(tester, ['t1', 't2']);

      await tester.tap(find.text('取消'));
      await tester.pump();

      expect(find.textContaining('已选'), findsNothing);
      expect(tester.widget<Checkbox>(checkOf('t1')).value, isFalse);
    });
  });

  group('批量改删的请求体', () {
    testWidgets('改类别：{ids, patch:{categoryId}}，成功后刷新并清空选择', (tester) async {
      final repo = TableRepo();
      await pumpPage(tester, repo: repo);
      final before = repo.listCalls;
      await select(tester, ['t1', 't4']);

      await tester.tap(find.text('改类别'));
      await tester.pumpAndSettle();
      expect(find.text('把这 2 笔改成哪个类别？'), findsOneWidget);
      // 两笔都是支出：只给支出类别。
      expect(find.byKey(const ValueKey('category-c3')), findsNothing);
      final confirm = find.widgetWithText(FilledButton, '改 2 笔');
      expect(
        tester.widget<FilledButton>(confirm).onPressed,
        isNull,
        reason: '没选不能确定',
      );

      await tester.tap(find.byKey(const ValueKey('category-c2')));
      await tester.pump();
      await tester.tap(confirm);
      await tester.pumpAndSettle();

      expect(repo.bulkCalls, [
        {
          'ids': ['t1', 't4'],
          'patch': {'categoryId': 'c2'},
        },
      ]);
      expect(find.text('改好了 2 笔'), findsOneWidget);
      expect(find.textContaining('已选'), findsNothing);
      expect(repo.listCalls, greaterThan(before), reason: '改完重拉列表');
    });

    testWidgets('改类别时转账不发给服务端，提示里说清楚', (tester) async {
      final repo = TableRepo();
      await pumpPage(tester, repo: repo);
      await select(tester, ['t1', 't3']);

      await tester.tap(find.text('改类别'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('category-c2')));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '改 1 笔'));
      await tester.pumpAndSettle();

      expect(repo.bulkCalls.single['ids'], ['t1']);
      expect(find.text('改好了 1 笔，1 笔转账不改类别'), findsOneWidget);
    });

    testWidgets('支出收入混选、或者全是转账：改类别置灰', (tester) async {
      await pumpPage(tester, repo: TableRepo());

      await select(tester, ['t1', 't2']);
      expect(buttonOf(tester, '改类别').onPressed, isNull);
      expect(buttonOf(tester, '改基金').onPressed, isNotNull, reason: '基金不分收支');

      await tester.tap(find.text('取消'));
      await tester.pump();
      await select(tester, ['t3']);
      expect(buttonOf(tester, '改类别').onPressed, isNull);
      expect(buttonOf(tester, '改基金').onPressed, isNull);
      expect(buttonOf(tester, '删除').onPressed, isNotNull);
    });

    testWidgets('改基金：{ids, patch:{fundId}}', (tester) async {
      final repo = TableRepo();
      await pumpPage(tester, repo: repo);
      await select(tester, ['t1', 't2']);

      await tester.tap(find.text('改基金'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bulk-fund-f2')));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '改 2 笔'));
      await tester.pumpAndSettle();

      expect(repo.bulkCalls, [
        {
          'ids': ['t1', 't2'],
          'patch': {'fundId': 'f2'},
        },
      ]);
      expect(find.text('改好了 2 笔'), findsOneWidget);
    });

    testWidgets('删除要二次确认：取消什么都不发，确定发 {ids, delete:true}', (tester) async {
      final repo = TableRepo();
      await pumpPage(tester, repo: repo);
      await select(tester, ['t1', 't3']);

      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.text('删除这 2 笔流水？'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '取消').last);
      await tester.pumpAndSettle();
      expect(repo.bulkCalls, isEmpty);
      expect(find.text('已选 2 笔'), findsOneWidget, reason: '取消删除不动选择');

      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除 2 笔'));
      await tester.pumpAndSettle();

      expect(repo.bulkCalls, [
        {
          'ids': ['t1', 't3'],
          'delete': true,
        },
      ]);
      expect(find.text('删掉了 2 笔'), findsOneWidget);
      expect(rowOf('t1'), findsNothing, reason: '刷新后删掉的行没了');
      expect(rowOf('t3'), findsNothing);
      expect(rowOf('t2'), findsOneWidget);
    });

    testWidgets('失败：显示服务端的中文 message，选择留着好重试', (tester) async {
      final repo = TableRepo()
        ..failWith = const ApiException(404, 'not_found', '这笔流水不存在');
      await pumpPage(tester, repo: repo);
      await select(tester, ['t1', 't2']);

      await tester.tap(find.text('改基金'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bulk-fund-f2')));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '改 2 笔'));
      await tester.pumpAndSettle();

      expect(find.text('没改成：这笔流水不存在'), findsOneWidget);
      expect(find.text('已选 2 笔'), findsOneWidget);

      await tester.tap(find.byTooltip('知道了'));
      await tester.pump();
      expect(find.text('没改成：这笔流水不存在'), findsNothing);
    });

    testWidgets('失败后点「重试」原样再发一次，不用重新选', (tester) async {
      final repo = TableRepo()
        ..failWith = const ApiException(0, 'network', '连不上服务器');
      await pumpPage(tester, repo: repo);
      await select(tester, ['t1', 't4']);

      await tester.tap(find.text('改类别'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('category-c2')));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '改 2 笔'));
      await tester.pumpAndSettle();
      expect(find.text('没改成：连不上服务器'), findsOneWidget);

      repo.failWith = null;
      await tester.tap(find.widgetWithText(TextButton, '重试'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing, reason: '不再弹选择框');
      expect(repo.bulkCalls, [
        for (var i = 0; i < 2; i++)
          {
            'ids': ['t1', 't4'],
            'patch': {'categoryId': 'c2'},
          },
      ]);
      expect(find.text('没改成：连不上服务器'), findsNothing);
      expect(find.text('改好了 2 笔'), findsOneWidget);
      expect(find.textContaining('已选'), findsNothing);
    });

    testWidgets('删除失败也能重试，照样是 {ids, delete:true}', (tester) async {
      final repo = TableRepo()
        ..failWith = const ApiException(0, 'network', '连不上服务器');
      await pumpPage(tester, repo: repo);
      await select(tester, ['t2']);

      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除 1 笔'));
      await tester.pumpAndSettle();
      expect(find.text('没删成：连不上服务器'), findsOneWidget);

      repo.failWith = null;
      await tester.tap(find.widgetWithText(TextButton, '重试'));
      await tester.pumpAndSettle();

      expect(repo.bulkCalls.last, {
        'ids': ['t2'],
        'delete': true,
      });
      expect(repo.bulkCalls, hasLength(2));
      expect(rowOf('t2'), findsNothing);
    });

    testWidgets('失败后改了选择，横条连同「重试」一起消失', (tester) async {
      final repo = TableRepo()
        ..failWith = const ApiException(0, 'network', '连不上服务器');
      await pumpPage(tester, repo: repo);
      await select(tester, ['t2']);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除 1 笔'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextButton, '重试'), findsOneWidget);

      await select(tester, ['t4']);
      expect(find.widgetWithText(TextButton, '重试'), findsNothing);
    });
  });

  group('快捷键', () {
    testWidgets('N 打开记一笔', (tester) async {
      await pumpPage(tester, repo: TableRepo());

      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();

      expect(find.text('记一笔页'), findsOneWidget);
    });

    testWidgets('Esc 取消选择', (tester) async {
      await pumpPage(tester, repo: TableRepo());
      await select(tester, ['t1', 't4']);
      expect(find.text('已选 2 笔'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(find.textContaining('已选'), findsNothing);
    });

    testWidgets('Delete 删除所选，同样二次确认', (tester) async {
      final repo = TableRepo();
      await pumpPage(tester, repo: repo);

      // 什么都没选时 Delete 不弹窗。
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);

      await select(tester, ['t2', 't4']);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      expect(find.text('删除这 2 笔流水？'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '删除 2 笔'));
      await tester.pumpAndSettle();
      expect(repo.bulkCalls, [
        {
          'ids': ['t2', 't4'],
          'delete': true,
        },
      ]);
    });

    testWidgets('/ 聚焦搜索框；输入框聚焦时 N / Delete / Esc 都不响应', (tester) async {
      final repo = TableRepo();
      await pumpPage(tester, repo: repo);
      await select(tester, ['t1']);
      final field = find.byType(TextField);
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.slash);
      await tester.pump();
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();
      expect(find.text('记一笔页'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('已选 1 笔'), findsOneWidget);
      expect(repo.bulkCalls, isEmpty);
    });

    testWidgets('搜索框里按 Esc 退出输入，N 又灵了；有选择时再按一次 Esc 才取消', (tester) async {
      await pumpPage(tester, repo: TableRepo());
      final field = find.byType(TextField);
      bool focused() => tester.widget<TextField>(field).focusNode!.hasFocus;

      await tester.sendKeyEvent(LogicalKeyboardKey.slash);
      await tester.pump();
      await tester.enterText(field, '面');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(focused(), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(focused(), isFalse);
      expect(
        tester.widget<TextField>(field).controller!.text,
        '面',
        reason: 'Esc 只退出，不清空搜索',
      );

      await select(tester, ['t1']);
      await tester.sendKeyEvent(LogicalKeyboardKey.slash);
      await tester.pump();
      expect(focused(), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(focused(), isFalse);
      expect(find.text('已选 1 笔'), findsOneWidget, reason: '第一下 Esc 只管输入框');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.textContaining('已选'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();
      expect(find.text('记一笔页'), findsOneWidget);
    });

    testWidgets('输入法还在拼字时 Esc 留给输入法，不退出搜索框', (tester) async {
      await pumpPage(tester, repo: TableRepo());
      final field = find.byType(TextField);
      await tester.sendKeyEvent(LogicalKeyboardKey.slash);
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'mian',
          selection: TextSelection.collapsed(offset: 4),
          composing: TextRange(start: 0, end: 4),
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
    });

    testWidgets('点进搜索框再按 N 也不跳', (tester) async {
      await pumpPage(tester, repo: TableRepo());

      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();

      expect(find.text('记一笔页'), findsNothing);
      expect(find.text('账单'), findsOneWidget);
    });

    testWidgets('搜完点一下表格，焦点回到页面，快捷键又灵了', (tester) async {
      await pumpPage(tester, repo: TableRepo());
      final field = find.byType(TextField);

      await tester.tap(field);
      await tester.pump();
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);

      await select(tester, ['t1']);
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.textContaining('已选'), findsNothing);
    });

    testWidgets('窄屏不响应快捷键', (tester) async {
      await pumpPage(tester, repo: TableRepo(), width: 400);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();

      expect(find.text('记一笔页'), findsNothing);
    });
  });

  group('窄屏与中屏', () {
    testWidgets('400 宽仍是原来的按日分组列表，没有表格与复选框', (tester) async {
      await pumpPage(tester, repo: TableRepo(), width: 400);

      expect(find.byType(TxTile), findsNWidgets(4));
      expect(find.byType(TxTable), findsNothing);
      expect(find.byType(Checkbox), findsNothing);
      expect(find.text('今天'), findsOneWidget);
      expect(find.text('昨天'), findsOneWidget);
    });

    testWidgets('800 宽（中屏）也还是列表', (tester) async {
      await pumpPage(tester, repo: TableRepo(), width: 800);

      expect(find.byType(TxTile), findsNWidgets(4));
      expect(find.byType(TxTable), findsNothing);
    });
  });

  group('导入入口', () {
    for (final width in [400.0, 1400.0]) {
      testWidgets('${width.toInt()} 宽顶栏有「导入」，点了往 /import 走', (tester) async {
        await pumpPage(tester, repo: TableRepo(), width: width);

        expect(find.byTooltip('导入'), findsOneWidget);
        await tester.tap(find.byTooltip('导入'));
        await tester.pumpAndSettle();

        expect(find.text('导入页'), findsOneWidget);
      });
    }
  });

  group('放进真实外壳', () {
    for (final width in [400.0, 800.0, 840.0, 1400.0]) {
      testWidgets('${width.toInt()} 宽不溢出', (tester) async {
        await pumpShell(tester, repo: TableRepo(), width: width);
        final wide = width >= 840;
        expect(find.byType(TxTable), wide ? findsOneWidget : findsNothing);
        if (wide) {
          await tester.tap(checkAll);
          await tester.pump();
          expect(find.text('已选 4 笔'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('切到别的 Tab 后按 N 不跳；切回来又灵了', (tester) async {
      await pumpShell(tester, repo: TableRepo());
      Future<void> go(String tab) async {
        await tester.tap(find.text(tab));
        await tester.pumpAndSettle();
      }

      // 第二次进首页时焦点还留在 Offstage 的账单页里，最容易误触发。
      await go('首页');
      await go('账单');
      await go('首页');
      expect(find.text('分支 /home'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();
      expect(find.text('记一笔页'), findsNothing);

      // 第一次进基金页会把焦点拿走；切回账单要自己拿回来。
      await go('基金');
      await go('账单');
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();
      expect(find.text('记一笔页'), findsOneWidget);
    });

    testWidgets('登录后先落在首页，第一次点进账单快捷键就灵', (tester) async {
      await pumpShell(tester, repo: TableRepo(), initialLocation: '/home');
      await tester.tap(find.text('账单'));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();
      expect(find.text('记一笔页'), findsOneWidget);
    });

    testWidgets('从记一笔返回、关掉确认框之后，快捷键照样灵', (tester) async {
      await pumpShell(tester, repo: TableRepo());

      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();
      expect(find.text('记一笔页'), findsOneWidget);
      GoRouter.of(tester.element(find.text('记一笔页'))).pop();
      await tester.pumpAndSettle();
      expect(find.text('记一笔页'), findsNothing);

      await select(tester, ['t1']);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '取消').last);
      await tester.pumpAndSettle();
      expect(find.text('已选 1 笔'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.textContaining('已选'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();
      expect(find.text('记一笔页'), findsOneWidget);
    });
  });

  group('不溢出', () {
    for (final (width, rail) in [
      (400.0, 0.0),
      (800.0, 0.0),
      (840.0, 181.0),
      (1400.0, 181.0),
      (1400.0, 0.0),
    ]) {
      testWidgets('${width.toInt()} 宽${rail > 0 ? '（带导航轨）' : ''}', (
        tester,
      ) async {
        await pumpPage(
          tester,
          repo: TableRepo(),
          width: width,
          railWidth: rail,
        );
        if (width >= 840) {
          // 工具条在最窄的表格里也要放得下。
          await tester.tap(checkAll);
          await tester.pump();
          expect(find.text('已选 4 笔'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      });
    }

    for (final (width, rail) in [(1400.0, 181.0), (840.0, 181.0)]) {
      testWidgets('${width.toInt()} 宽：千万级金额整串显示，不被省略号截掉', (tester) async {
        final repo = TableRepo();
        final base = repo.items.first;
        repo.items = [
          Transaction(
            id: 'big1',
            clientId: 'c-big1',
            type: Transaction.typeIncome,
            amountCents: 9876543210,
            occurredAt: base.occurredAt,
            fundId: 'f1',
            accountId: 'a2',
          ),
          Transaction(
            id: 'big2',
            clientId: 'c-big2',
            type: Transaction.typeExpense,
            amountCents: 123456789,
            occurredAt: base.occurredAt,
            fundId: 'f1',
            accountId: 'a1',
          ),
        ];
        await pumpPage(tester, repo: repo, width: width, railWidth: rail);

        for (final text in ['+¥98,765,432.10', '−¥1,234,567.89']) {
          final paragraph = tester.renderObject<RenderParagraph>(
            find.text(text),
          );
          expect(paragraph.didExceedMaxLines, isFalse, reason: text);
          final cell = tester.getRect(find.text(text));
          final row = tester.getRect(
            rowOf(text.startsWith('+') ? 'big1' : 'big2'),
          );
          expect(cell.right, lessThanOrEqualTo(row.right), reason: text);
        }
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('840 宽带导航轨时收起成员列，1400 宽带导航轨时成员列还在', (tester) async {
      await pumpPage(tester, repo: TableRepo(), width: 840, railWidth: 181);
      expect(find.text('成员'), findsNothing);
      expect(find.text('爸爸'), findsNothing);

      await pumpPage(tester, repo: TableRepo(), width: 1400, railWidth: 181);
      expect(find.text('成员'), findsOneWidget);
    });
  });
}
