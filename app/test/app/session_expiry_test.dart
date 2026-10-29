import 'dart:async';
import 'dart:convert';

import 'package:famledger/app/providers.dart';
import 'package:famledger/app/router.dart';
import 'package:famledger/app/theme.dart';
import 'package:famledger/data/api/api_client.dart';
import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/data/local/secure_store.dart';
import 'package:famledger/data/repos/session_repo.dart';
import 'package:famledger/platform/perk_notifications.dart';
import 'package:famledger/ui/auth/login_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _server = 'https://ledger.example.com';
const _notice = '登录已过期，请重新登录';

/// 服务端那种令牌：`base64url(JSON{sub,tid,exp,iat})` + `.` + 签名。
String _token({int? exp}) {
  final payload = {'sub': 'm1', 'tid': 't1', 'iat': 1700000000, if (exp != null) 'exp': exp};
  return '${base64Url.encode(utf8.encode(jsonEncode(payload))).replaceAll('=', '')}.c2ln';
}

/// 令牌已经不认了的服务端：带令牌的请求一律 401 unauthorized，没带令牌的回 404。
http.Client _deadTokenServer(List<String> seen) => MockClient((req) async {
  final withToken = req.headers.containsKey('authorization');
  seen.add('${req.method} ${req.url.path}${withToken ? ' +token' : ''}');
  final body = withToken
      ? {'error': {'code': 'unauthorized', 'message': '令牌无效或已过期'}}
      : {'error': {'code': 'not_found', 'message': '没有'}};
  return http.Response(
    jsonEncode(body),
    withToken ? 401 : 404,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
});

/// 记住了 [_server] 的一台设备；[token] 非空就是登录着。
///
/// [mockApi] 为 true 时把 `apiProvider` 换成「真的 [ApiClient] + 假服务端」（回调接法与
/// providers.dart 里一样）；为 false 时用生产的 `apiProvider`（真网络，连不上而已）。
Future<ProviderContainer> _boot({
  required http.Client client,
  String? token,
  MemoryLocalStore? cache,
  bool mockApi = true,
}) async {
  final secure = MemorySecureStore();
  secure.data[SessionRepo.baseUrlKey] = _server;
  if (token != null) {
    secure.data[SessionRepo.sessionKey] = jsonEncode({
      'baseUrl': _server,
      'token': token,
      'deviceId': 'dev',
      'me': {'id': 'm1', 'username': 'mama', 'displayName': '妈妈', 'role': 'admin'},
    });
  }
  final repo = SessionRepo(secure: secure, httpClient: client);
  await repo.restore();
  return ProviderContainer(
    overrides: [
      localStoreProvider.overrideWithValue(cache ?? MemoryLocalStore()),
      secureStoreProvider.overrideWithValue(secure),
      sessionRepoProvider.overrideWithValue(repo),
      perkNotificationSchedulerProvider.overrideWithValue(
        const UnsupportedPerkNotificationScheduler(PerkPushBlock.desktop),
      ),
      if (mockApi)
        apiProvider.overrideWith((ref) {
          final session = ref.watch(sessionProvider);
          final api = ApiClient(baseUrl: _server, token: session?.token, inner: client);
          api.onUnauthorized = () => unawaited(ref.read(sessionProvider.notifier).expire(_notice));
          return api;
        }),
    ],
  );
}

Future<void> _pumpApp(WidgetTester tester, ProviderContainer container) async {
  addTearDown(container.dispose);
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light),
        routerConfig: container.read(routerProvider),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

MemorySecureStore _secureOf(ProviderContainer c) => c.read(secureStoreProvider) as MemorySecureStore;

void main() {
  testWidgets('登录着启动，服务端对带令牌的请求回 401：自动回到登录页、顶上有提示，本地缓存不清', (tester) async {
    final seen = <String>[];
    final cache = MemoryLocalStore();
    await cache.write('outbox', [
      {'id': 'op1', 'kind': 'create'},
    ]);
    final container = await _boot(client: _deadTokenServer(seen), token: 'tok', cache: cache);
    var hooks = 0;
    container.read(logoutHooksProvider).add(() async => hooks++);
    await _pumpApp(tester, container);

    expect(seen.where((c) => c.endsWith('+token')), isNotEmpty, reason: '首页启动时确实带令牌去请求过');
    expect(container.read(routerProvider).state.uri.path, '/login');
    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.byKey(const ValueKey('login-notice')), findsOneWidget);
    expect(find.text(_notice), findsOneWidget);
    expect(find.text(_server), findsOneWidget, reason: '记住的服务器地址还在');

    expect(container.read(sessionProvider), isNull);
    expect(container.read(sessionNoticeProvider), _notice);
    expect(_secureOf(container).data.containsKey(SessionRepo.sessionKey), isFalse, reason: '安全存储里的会话删了');
    expect(_secureOf(container).data[SessionRepo.baseUrlKey], _server);
    expect(await cache.read<List>('outbox'), hasLength(1), reason: '排着的账不能丢，等重新登录后再发');
    expect(container.read(localStoreEpochProvider), 0, reason: '不是退出登录，本机设置不用重读');
    expect(hooks, 0, reason: 'logoutHooks 只在退出登录时跑');
  });

  testWidgets('生产的 apiProvider 接的回调就是 expire：调一次就回登录页并显示提示', (tester) async {
    final container = await _boot(client: _deadTokenServer([]), token: 'tok', mockApi: false);
    await _pumpApp(tester, container);
    expect(container.read(routerProvider).state.uri.path, '/home');

    final onUnauthorized = container.read(apiProvider).onUnauthorized;
    expect(onUnauthorized, isNotNull);
    onUnauthorized!();
    await tester.pumpAndSettle();

    expect(container.read(routerProvider).state.uri.path, '/login');
    expect(find.text(_notice), findsOneWidget);
    expect(container.read(sessionProvider), isNull);
    expect(_secureOf(container).data.containsKey(SessionRepo.sessionKey), isFalse);
  });

  testWidgets('启动时令牌已经过期：直接停在登录页并显示提示，不用等第一个请求', (tester) async {
    final seen = <String>[];
    final container = await _boot(client: _deadTokenServer(seen), token: _token(exp: 1700000000));
    await _pumpApp(tester, container);

    expect(container.read(routerProvider).state.uri.path, '/login');
    expect(find.text(_notice), findsOneWidget);
    expect(container.read(sessionNoticeProvider), _notice);
    expect(seen.where((c) => c.endsWith('+token')), isEmpty, reason: '过期的令牌一次都没拿去用');
    expect(_secureOf(container).data.containsKey(SessionRepo.sessionKey), isFalse);
    expect(_secureOf(container).data[SessionRepo.baseUrlKey], _server);
    expect(container.read(sessionRepoProvider).lastNotice, isNull, reason: '搬走就清掉，不会反复冒出来');
  });

  testWidgets('还没过期的令牌照常进首页', (tester) async {
    final future = DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch ~/ 1000;
    final container = await _boot(client: _deadTokenServer([]), token: _token(exp: future), mockApi: false);
    await _pumpApp(tester, container);
    expect(container.read(routerProvider).state.uri.path, '/home');
    expect(container.read(sessionNoticeProvider), isNull);
  });

  test('expire：会话已经没了就什么都不做（并发的几个 401 只处理一次）', () async {
    final container = await _boot(client: _deadTokenServer([]));
    addTearDown(container.dispose);
    await container.read(sessionProvider.notifier).expire('不该出现');
    expect(container.read(sessionNoticeProvider), isNull);
  });

  test('expire：并发撞上几次只留一句提示；真的 ApiClient 撞 401 就触发', () async {
    final seen = <String>[];
    final container = await _boot(client: _deadTokenServer(seen), token: 'tok');
    addTearDown(container.dispose);
    final api = container.read(apiProvider);
    await expectLater(
      Future.wait([api.get('/auth/me'), api.get('/stats/overview')]),
      throwsA(isA<ApiException>().having((e) => e.isUnauthorized, 'isUnauthorized', true)),
    );
    await Future<void>.delayed(Duration.zero);
    expect(container.read(sessionProvider), isNull);
    expect(container.read(sessionNoticeProvider), _notice);
    expect(container.read(apiProvider).token, isNull, reason: '会话没了，客户端重建成不带令牌的');
  });

  test('expire：旧客户端带着旧令牌来不踢新会话（换过会话之后还在飞的慢请求回 401）；带当前令牌的照常', () async {
    final container = await _boot(client: _deadTokenServer([]), token: 'tok');
    addTearDown(container.dispose);
    await container.read(sessionProvider.notifier).expire('旧的', token: 'stale');
    expect(container.read(sessionProvider), isNotNull, reason: '不是当前令牌，不理');
    expect(container.read(sessionNoticeProvider), isNull);
    await container.read(sessionProvider.notifier).expire(_notice, token: 'tok');
    expect(container.read(sessionProvider), isNull);
    expect(container.read(sessionNoticeProvider), _notice);
  });
}
