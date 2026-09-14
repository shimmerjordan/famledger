import 'dart:convert';

import 'package:famledger/app/providers.dart';
import 'package:famledger/app/theme.dart';
import 'package:famledger/data/api/api_client.dart';
import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/data/local/outbox.dart';
import 'package:famledger/data/local/secure_store.dart';
import 'package:famledger/data/repos/session_repo.dart';
import 'package:famledger/data/repos/transactions_repo.dart';
import 'package:famledger/ui/settings/server_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 只替掉「待上传 / 未能上传」这几件事，其余沿用真实实现。
class FakeTxRepo extends TransactionsRepo {
  FakeTxRepo(this._failed)
    : super(
        api: ApiClient(
          baseUrl: 'https://x.dev',
          inner: MockClient((req) async => http.Response('{}', 200)),
        ),
        outbox: Outbox(MemoryLocalStore()),
      );

  List<OutboxFailure> _failed;
  bool cleared = false;

  /// 设了就让对应的一步抛出来（模拟本地存储读不出 / 写不进）。
  Object? loadError;
  Object? clearError;

  @override
  List<OutboxFailure> get failedItems => _failed;

  @override
  Future<List<OutboxFailure>> loadFailed() async {
    if (loadError != null) throw loadError!;
    return _failed;
  }

  @override
  Future<void> clearFailed() async {
    if (clearError != null) throw clearError!;
    cleared = true;
    _failed = const [];
  }

  @override
  Future<int> pendingCount() async => 2;
}

OutboxFailure failure(String clientId, int cents, String message) => OutboxFailure(
  clientId: clientId,
  code: 'bad_request',
  message: message,
  at: DateTime(2026, 9, 12, 20, 30),
  payload: {'amountCents': cents},
);

Future<ProviderContainer> boot(FakeTxRepo repo) async {
  final secure = MemorySecureStore();
  secure.data[SessionRepo.baseUrlKey] = 'https://ledger.example.com';
  secure.data[SessionRepo.sessionKey] = jsonEncode({
    'baseUrl': 'https://ledger.example.com',
    'token': 'tok',
    'deviceId': 'dev',
    'me': {'id': 'm1', 'username': 'mama', 'displayName': '妈妈', 'role': 'admin'},
  });
  final session = SessionRepo(secure: secure);
  await session.restore();
  return ProviderContainer(
    overrides: [
      localStoreProvider.overrideWithValue(MemoryLocalStore()),
      secureStoreProvider.overrideWithValue(secure),
      sessionRepoProvider.overrideWithValue(session),
      transactionsRepoProvider.overrideWithValue(repo),
    ],
  );
}

Future<void> pump(WidgetTester tester, ProviderContainer container) async {
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const ServerPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('有被拒记录时显示「N 条未能上传」，可展开、可清除', (tester) async {
    final repo = FakeTxRepo([
      failure('c1', 3250, '基金不存在'),
      failure('c2', 990, 'items 最多 200 条'),
    ]);
    await pump(tester, await boot(repo));

    expect(find.text('2 条未能上传'), findsOneWidget);
    // 详情默认收起。
    expect(find.text('基金不存在（bad_request）'), findsNothing);

    await tester.tap(find.text('查看详情'));
    await tester.pumpAndSettle();
    expect(find.text('基金不存在（bad_request）'), findsOneWidget);
    expect(find.text('¥32.50'), findsOneWidget);
    expect(find.text('c1'), findsOneWidget);

    await tester.tap(find.text('清除'));
    await tester.pumpAndSettle();
    expect(repo.cleared, isTrue);
    expect(find.text('2 条未能上传'), findsNothing);
  });

  testWidgets('没有被拒记录时这一段整个不出现', (tester) async {
    await pump(tester, await boot(FakeTxRepo(const [])));
    expect(find.textContaining('未能上传'), findsNothing);
    expect(find.text('查看详情'), findsNothing);
    // 正常内容还在。
    expect(find.text('还有 2 条离线记录没发出去'), findsOneWidget);
  });

  testWidgets('读本地队列失败：页面不崩、行内提示、能重试', (tester) async {
    final repo = FakeTxRepo([failure('c1', 3250, '基金不存在')])
      ..loadError = Exception('磁盘读不出来');
    await pump(tester, await boot(repo));

    // 出错要说出来，不能装作「都同步完了」；其余内容照常。
    expect(find.textContaining('磁盘读不出来'), findsOneWidget);
    expect(find.text('都同步完了'), findsNothing);
    expect(find.text('本地队列没读出来'), findsOneWidget);
    expect(find.text('服务器地址'), findsOneWidget);
    expect(find.text('修改密码'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 存储恢复后点「重试」能读出来，错误提示消失。
    repo.loadError = null;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.textContaining('磁盘读不出来'), findsNothing);
    expect(find.text('还有 2 条离线记录没发出去'), findsOneWidget);
    expect(find.text('1 条未能上传'), findsOneWidget);
  });

  testWidgets('清除被拒记录失败：行内提示，列表还在', (tester) async {
    final repo = FakeTxRepo([failure('c1', 3250, '基金不存在')])
      ..clearError = Exception('写不进去');
    await pump(tester, await boot(repo));

    await tester.tap(find.text('查看详情'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清除'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('写不进去'), findsOneWidget);
    expect(find.text('1 条未能上传'), findsOneWidget);
    expect(repo.cleared, isFalse);
  });
}
