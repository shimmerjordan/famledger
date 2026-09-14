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
import 'package:famledger/ui/add_tx/add_tx_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// 没有默认基金、没有「上次选择」——所以进页面时是「一个基金都没选中」的状态。
const LedgerData ledgerData = LedgerData(
  funds: [
    Fund(id: 'f1', name: '家庭公共', color: '#c36a4f'),
    Fund(id: 'f2', name: '个人零花', color: '#8678c9'),
  ],
  accounts: [
    Account(id: 'a1', name: '微信', kind: 'wechat'),
    Account(id: 'a2', name: '招行', kind: 'bank'),
  ],
  categories: [
    Category(id: 'c1', name: '餐饮', icon: 'restaurant'),
    Category(id: 'c2', name: '交通', icon: 'directions_bus'),
    Category(id: 'c9', name: '工资', kind: 'income', icon: 'payments'),
  ],
  members: [Member(id: 'm1', username: 'mama', displayName: '妈妈')],
);

class FakeLedger extends LedgerController {
  FakeLedger(this.data);

  final LedgerData data;

  @override
  Future<LedgerData> build() async => data;

  @override
  Future<void> sync({bool full = false}) async {}
}

/// 只记下草稿，不发网络；保存成功后页面会 pop，所以测试要带个路由。
class RecordingTxRepo extends TransactionsRepo {
  RecordingTxRepo()
    : super(
        api: ApiClient(baseUrl: 'http://127.0.0.1'),
        outbox: Outbox(MemoryLocalStore()),
      );

  TransactionDraft? lastDraft;

  @override
  Future<Transaction> create(TransactionDraft draft) async {
    lastDraft = draft;
    return draft.toOptimisticTransaction().copyWith(pendingSync: false);
  }
}

Future<void> pumpAddTx(
  WidgetTester tester, {
  LedgerData data = ledgerData,
}) async {
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
        ledgerProvider.overrideWith(() => FakeLedger(data)),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const AddTxPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tapKeys(WidgetTester tester, String keys) async {
  for (final key in keys.split('')) {
    await tester.tap(find.byKey(ValueKey('key-$key')));
    await tester.pump();
  }
}

/// 带路由的版本：用来测「保存」之后真正发出去的草稿长什么样。
Future<void> pumpAddTxRouted(
  WidgetTester tester,
  RecordingTxRepo repo, {
  LedgerData data = ledgerData,
}) async {
  tester.view.physicalSize = const Size(390, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    initialLocation: '/add',
    routes: [
      GoRoute(path: '/add', builder: (context, state) => const AddTxPage()),
      GoRoute(
        path: '/home',
        builder: (context, state) =>
            const Scaffold(body: Center(child: Text('回到首页'))),
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
        ledgerProvider.overrideWith(() => FakeLedger(data)),
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

void main() {
  testWidgets('敲 35.5 就显示 ¥35.50（两位小数当场补齐）', (tester) async {
    await pumpAddTx(tester);

    expect(find.text('¥0.00'), findsOneWidget);
    await tapKeys(tester, '35.5');

    expect(find.text('¥35.50'), findsOneWidget);
  });

  testWidgets('退格与小数位上限', (tester) async {
    await pumpAddTx(tester);

    await tapKeys(tester, '12.345');
    // 第三位小数按不进去。
    expect(find.text('¥12.34'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('key-⌫')));
    await tester.pump();
    expect(find.text('¥12.30'), findsOneWidget);
  });

  testWidgets('没选基金就点保存，行内出校验提示', (tester) async {
    await pumpAddTx(tester);

    await tapKeys(tester, '35.5');
    await tester.tap(find.byKey(const ValueKey('save-tx')));
    await tester.pump();

    expect(find.text('请选择一个基金'), findsOneWidget);
  });

  testWidgets('没输金额就点保存，提示先输金额', (tester) async {
    await pumpAddTx(tester);

    await tester.tap(find.byKey(const ValueKey('save-tx')));
    await tester.pump();

    expect(find.text('请输入金额'), findsOneWidget);
  });

  testWidgets('选了基金之后校验提示就不再出现', (tester) async {
    await pumpAddTx(tester);

    await tapKeys(tester, '35.5');
    await tester.tap(find.byKey(const ValueKey('save-tx')));
    await tester.pump();
    expect(find.text('请选择一个基金'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('fund-f1')));
    await tester.pump();

    expect(find.text('请选择一个基金'), findsNothing);
  });

  testWidgets('默认基金会自动选中', (tester) async {
    await pumpAddTx(
      tester,
      data: const LedgerData(
        funds: [Fund(id: 'f1', name: '家庭公共', isDefault: true)],
        categories: [Category(id: 'c1', name: '餐饮', icon: 'restaurant')],
      ),
    );

    final chip = tester.widget<ChoiceChip>(
      find.byKey(const ValueKey('fund-f1')),
    );
    expect(chip.selected, isTrue);
  });

  testWidgets('切到收入后类别网格换成收入类别', (tester) async {
    await pumpAddTx(tester);

    expect(find.text('餐饮'), findsOneWidget);
    expect(find.text('工资'), findsNothing);

    await tester.tap(find.text('收入'));
    await tester.pumpAndSettle();

    expect(find.text('工资'), findsOneWidget);
    expect(find.text('餐饮'), findsNothing);
  });

  testWidgets('转账只填账户对时，默认基金不许偷偷塞进去', (tester) async {
    final repo = RecordingTxRepo();
    await pumpAddTxRouted(
      tester,
      repo,
      // 存在一个「默认基金」：支出/收入会自动选中它，转账绝不能跟着带上。
      data: const LedgerData(
        funds: [Fund(id: 'f1', name: '家庭公共', isDefault: true)],
        accounts: [
          Account(id: 'a1', name: '微信', kind: 'wechat'),
          Account(id: 'a2', name: '招行', kind: 'bank'),
        ],
        categories: [Category(id: 'c1', name: '餐饮', icon: 'restaurant')],
      ),
    );

    await tester.tap(find.text('转账·拨款'));
    await tester.pumpAndSettle();
    await tapKeys(tester, '100');
    await tester.tap(find.byKey(const ValueKey('account-a1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('to-account-a2')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('save-tx')));
    await tester.pumpAndSettle();

    final draft = repo.lastDraft;
    expect(draft, isNotNull);
    expect(draft!.type, Transaction.typeTransfer);
    expect(draft.amountCents, 10000);
    expect(draft.accountId, 'a1');
    expect(draft.toAccountId, 'a2');
    // 半对基金（fundId 有、toFundId 没有）会让服务端回 400 invalid_transfer。
    expect(draft.fundId, isNull);
    expect(draft.toFundId, isNull);
  });

  testWidgets('从支出切到转账：单边选的基金不会残留成半对', (tester) async {
    final repo = RecordingTxRepo();
    await pumpAddTxRouted(
      tester,
      repo,
      data: const LedgerData(
        funds: [Fund(id: 'f1', name: '家庭公共')],
        accounts: [
          Account(id: 'a1', name: '微信', kind: 'wechat'),
          Account(id: 'a2', name: '招行', kind: 'bank'),
        ],
        categories: [Category(id: 'c1', name: '餐饮', icon: 'restaurant')],
      ),
    );

    // 先在支出模式下挑一个基金（单边），再切到转账。
    await tester.tap(find.byKey(const ValueKey('fund-f1')));
    await tester.pump();
    await tester.tap(find.text('转账·拨款'));
    await tester.pumpAndSettle();

    // 切过来之后那一边应该已经没选中了。
    expect(
      tester.widget<ChoiceChip>(find.byKey(const ValueKey('fund-f1'))).selected,
      isFalse,
    );

    await tapKeys(tester, '100');
    await tester.tap(find.byKey(const ValueKey('account-a1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('to-account-a2')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('save-tx')));
    await tester.pumpAndSettle();

    expect(repo.lastDraft!.fundId, isNull);
    expect(repo.lastDraft!.toFundId, isNull);
  });

  testWidgets('转账只填了基金的一边：本地就说清楚，不等服务端 400', (tester) async {
    await pumpAddTx(tester);

    await tester.tap(find.text('转账·拨款'));
    await tester.pumpAndSettle();
    await tapKeys(tester, '100');
    // 账户填了完整一对，基金只填转出那一边。
    await tester.tap(find.byKey(const ValueKey('account-a1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('to-account-a2')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('fund-f1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('save-tx')));
    await tester.pump();

    expect(find.text('基金只填了一边：两边都填，或者都留空'), findsOneWidget);
  });

  testWidgets('芯片再点一下可以取消选择', (tester) async {
    await pumpAddTx(tester);

    await tester.tap(find.byKey(const ValueKey('fund-f1')));
    await tester.pump();
    expect(
      tester.widget<ChoiceChip>(find.byKey(const ValueKey('fund-f1'))).selected,
      isTrue,
    );

    await tester.tap(find.byKey(const ValueKey('fund-f1')));
    await tester.pump();
    expect(
      tester.widget<ChoiceChip>(find.byKey(const ValueKey('fund-f1'))).selected,
      isFalse,
    );

    // 取消之后保存，校验提示要回来（不能被「上次记住的」偷偷补上）。
    await tapKeys(tester, '10');
    await tester.tap(find.byKey(const ValueKey('save-tx')));
    await tester.pump();
    expect(find.text('请选择一个基金'), findsOneWidget);
  });

  testWidgets('转账模式两对都没填时说清楚要填什么', (tester) async {
    await pumpAddTx(tester);

    await tester.tap(find.text('转账·拨款'));
    await tester.pumpAndSettle();
    await tapKeys(tester, '100');
    await tester.tap(find.byKey(const ValueKey('save-tx')));
    await tester.pump();

    expect(find.text('至少填一对：账户→账户，或基金→基金'), findsOneWidget);
  });
}
