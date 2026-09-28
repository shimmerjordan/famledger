import 'dart:async';
import 'dart:convert';

import 'package:famledger/app/providers.dart';
import 'package:famledger/data/local/secure_store.dart';
import 'package:famledger/data/repos/session_repo.dart';
import 'package:famledger/platform/perk_notifications.dart';
import 'package:famledger/ui/auth/login_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _server = 'http://127.0.0.1:48090';

/// 记住了 [_server] 的一台设备，服务端按参数回 `/setup/status`。
Future<(List<String>, GoRouter)> _pumpLogin(
  WidgetTester tester, {
  bool? needsSetup,
  bool offline = false,
  bool rememberServer = true,
}) async {
  final calls = <String>[];
  final client = MockClient((req) async {
    calls.add(req.url.path);
    if (offline) throw http.ClientException('Connection refused');
    final body = switch (req.url.path) {
      '/healthz' => {'ok': true},
      '/api/v1/setup/status' => {'needsSetup': needsSetup, if (needsSetup == false) 'householdName': '测试家庭'},
      _ => {'error': {'code': 'not_found', 'message': '没有'}},
    };
    return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
  });
  final secure = MemorySecureStore();
  if (rememberServer) secure.data[SessionRepo.baseUrlKey] = _server;
  final session = SessionRepo(secure: secure, httpClient: client);
  await session.restore();

  final router = GoRouter(
    initialLocation: '/login',
    routes: [
      GoRoute(path: '/login', builder: (context, state) => const LoginPage()),
      GoRoute(path: '/setup', builder: (context, state) => const Scaffold(body: Text('首启向导'))),
      GoRoute(path: '/connect', builder: (context, state) => const Scaffold(body: Text('连接'))),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        secureStoreProvider.overrideWithValue(secure),
        sessionRepoProvider.overrideWithValue(session),
        perkNotificationSchedulerProvider.overrideWithValue(
          const UnsupportedPerkNotificationScheduler(PerkPushBlock.desktop),
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return (calls, router);
}

void main() {
  testWidgets('记住的服务器换成了还没初始化的库：打开登录页就转去首启向导', (tester) async {
    final (calls, router) = await _pumpLogin(tester, needsSetup: true);
    expect(calls, ['/api/v1/setup/status'], reason: '只问初始化状态，不重新连一遍');
    expect(find.text('首启向导'), findsOneWidget);
    expect(router.routerDelegate.currentConfiguration.uri.path, '/setup');
  });

  testWidgets('已经初始化过：留在登录页，标题带上家庭名', (tester) async {
    final (calls, router) = await _pumpLogin(tester, needsSetup: false);
    expect(calls, contains('/api/v1/setup/status'));
    expect(router.routerDelegate.currentConfiguration.uri.path, '/login');
    expect(find.text('登录「测试家庭」'), findsOneWidget);
  });

  testWidgets('服务器连不上：照旧留在登录页，不先冒出报错', (tester) async {
    final (calls, router) = await _pumpLogin(tester, offline: true);
    expect(calls, isNotEmpty);
    expect(router.routerDelegate.currentConfiguration.uri.path, '/login');
    expect(find.text('登录'), findsWidgets);
    expect(find.textContaining('Connection refused'), findsNothing);
  });

  testWidgets('没记住任何服务器：不发请求', (tester) async {
    final (calls, router) = await _pumpLogin(tester, needsSetup: true, rememberServer: false);
    expect(calls, isEmpty);
    expect(router.routerDelegate.currentConfiguration.uri.path, '/login');
  });

  test('问的途中换了服务器：这次结果作废，也不把地址写回旧的', () async {
    final gate = Completer<void>();
    final client = MockClient((req) async {
      Map<String, Object?> body;
      if (req.url.host == '127.0.0.1') {
        await gate.future; // 旧服务器慢
        body = {'needsSetup': true};
      } else {
        body = req.url.path == '/healthz' ? {'ok': true} : {'needsSetup': false, 'householdName': '新家'};
      }
      return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    });
    final secure = MemorySecureStore()..data[SessionRepo.baseUrlKey] = _server;
    final repo = SessionRepo(secure: secure, httpClient: client);
    await repo.restore();

    final probe = repo.probeSetup();
    await repo.connect('https://b.example.com'); // 用户点了「换个服务器」
    gate.complete();

    expect(await probe, isNull);
    expect(repo.storedBaseUrl, 'https://b.example.com');
    expect(secure.data[SessionRepo.baseUrlKey], 'https://b.example.com');
    expect(repo.needsSetup, isFalse);
    expect(repo.householdName, '新家');
  });
}
