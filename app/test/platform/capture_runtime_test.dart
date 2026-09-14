import 'dart:convert';
import 'dart:io';

import 'package:famledger/capture/pipeline.dart';
import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/data/local/secure_store.dart';
import 'package:famledger/data/repos/ledger_repo.dart';
import 'package:famledger/data/repos/session_repo.dart';
import 'package:famledger/data/repos/settings_repo.dart';
import 'package:famledger/platform/capture_runtime.dart';
import 'package:famledger/platform/file_capture_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_server.dart';

Map<String, Object> notification({String text = '你有一笔35.00元的支出，来自美团'}) => {
  'id': '0|com.eg.android.AlipayGphone|1|null|10101',
  'package': 'com.eg.android.AlipayGphone',
  'title': '支付宝',
  'text': text,
  'bigText': '',
  'postedAt': DateTime(2026, 9, 12, 12, 30).millisecondsSinceEpoch,
};

void main() {
  late Directory dir;
  late FakeServer server;
  late MemorySecureStore secure;
  late MemoryLocalStore cache;
  late FileCaptureStore store;
  late CaptureRuntime runtime;

  Future<void> login() async {
    secure.data[SessionRepo.baseUrlKey] = 'https://x.dev';
    secure.data[SessionRepo.sessionKey] = jsonEncode({
      'baseUrl': 'https://x.dev',
      'token': 'tok',
      'deviceId': 'dev',
      'me': {'id': 'm1', 'username': 'mama', 'displayName': '妈妈', 'role': 'admin'},
    });
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('fl-capture-runtime-');
    server = FakeServer();
    secure = MemorySecureStore();
    cache = MemoryLocalStore();
    store = FileCaptureStore(dir);
    runtime = CaptureRuntime(
      secure: secure,
      cache: cache,
      store: store,
      httpClient: server.client,
      autoReplay: false, // 这组测试只看单次调用的行为，重放另有专门测试
      now: () => DateTime(2026, 9, 12, 12, 31),
    );
    await login();
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('通知 → 建流水 → 结果 map（含 captureId / transactionId / 动作）→ 日志', () async {
    final out = await runtime.handleNotification(notification());

    expect(out['decision'], anyOf('recorded', 'pending'));
    expect(out['captureId'], isNotNull);
    expect(out['transactionId'], 't1');
    expect(out['title'], contains('支付宝 −¥35.00'));
    expect(out['actions'], ['confirm', 'edit', 'undo'], reason: '刚记下时三个动作都要有，自动入账的也能点「正确」');

    final posted = server.bodyOf('POST /api/v1/transactions');
    expect(posted['amountCents'], 3500);
    expect(posted['type'], 'expense');
    expect(posted['source'], 'notification');
    expect(posted['sourceApp'], 'com.eg.android.AlipayGphone');
    expect(posted['memberId'], 'm1');
    expect(posted['merchant'], '美团');
    expect(posted['captureId'], out['captureId']);
    expect((posted['occurredAt'] as String), matches(RegExp(r'[+-]\d{2}:\d{2}$')));
    // 主数据与设置是从服务端拉的
    expect(server.calls, contains('GET /api/v1/changes'));
    expect(server.calls, contains('GET /api/v1/settings'));

    final log = await store.recent();
    expect(log.single.transactionId, 't1');
    expect(log.single.package, 'com.eg.android.AlipayGphone');
    expect(log.single.amountCents, 3500);
  });

  test('没登录：不打网络，回 error 结论', () async {
    secure.data.clear();
    final out = await runtime.handleNotification(notification());
    expect(out['decision'], 'error');
    expect(out['title'], '家账还没登录');
    expect(server.seen, isEmpty);
  });

  test('噪声通知：ignored，不建流水', () async {
    final out = await runtime.handleNotification(notification(text: '【支付宝】验证码 123456，请勿泄露'));
    expect(out['decision'], 'ignored');
    expect(out.containsKey('captureId'), isFalse);
    expect(server.calls.where((c) => c == 'POST /api/v1/transactions'), isEmpty);
  });

  test('快捷回复「宠物」→ PATCH 改基金 → 「已更新」，剩下 edit / undo', () async {
    final first = await runtime.handleNotification(notification());
    final captureId = first['captureId'] as String;

    final out = await runtime.handleAction({'captureId': captureId, 'action': 'reply', 'text': '宠物'});
    expect(out['title'], startsWith('已更新：'));
    expect(out['actions'], ['edit', 'undo']);
    expect(out['transactionId'], 't1');

    final patch = server.bodyOf('PATCH /api/v1/transactions/t1');
    expect(patch['fundId'], 'f2');
    expect(patch['status'], 'confirmed');
    expect(server.calls, contains('POST /api/v1/model/learn'));
    expect(server.transactions['t1']!['fundId'], 'f2');

    final log = await store.recent();
    expect(log.single.decision, 'recorded');
  });

  test('正确 → confirm；撤销 → DELETE，没有动作，日志变已撤销', () async {
    final first = await runtime.handleNotification(notification());
    final captureId = first['captureId'] as String;

    final confirmed = await runtime.handleAction({'captureId': captureId, 'action': 'confirm'});
    expect(confirmed['title'], startsWith('已确认：'));
    expect(server.calls, contains('POST /api/v1/transactions/t1/confirm'));

    final undone = await runtime.handleAction({'captureId': captureId, 'action': 'undo'});
    expect(undone['title'], '已撤销');
    expect(undone['actions'], isEmpty);
    expect(server.calls, contains('DELETE /api/v1/transactions/t1'));
    expect(server.transactions, isEmpty);
    expect((await store.recent()).single.decision, 'undone');
  });

  test('空回复：什么都不改，记录仍待确认，三个动作都保留', () async {
    server.threshold = 0.999; // 一定进待确认
    final first = await runtime.handleNotification(notification());
    expect(first['decision'], 'pending');
    expect(first['actions'], ['confirm', 'edit', 'undo']);
    final out = await runtime.handleAction({'captureId': first['captureId'], 'action': 'reply', 'text': '   '});
    expect(out['title'], '没有收到修改内容');
    expect(out['actions'], ['confirm', 'edit', 'undo']);
    expect(server.calls.where((c) => c.startsWith('PATCH')), isEmpty);
  });

  test('拉共享模型：版本更新才替换本地，并让管线重装', () async {
    await runtime.handleNotification(notification()); // 先有本地种子模型
    final seed = await store.loadModel(kCategoryModelKey);
    expect(seed, isNotNull);

    server.modelVersion = 9;
    final synced = await runtime.syncModel();
    expect(synced['ok'], isTrue);
    expect(synced['updated'], isTrue);
    final local = await store.loadModel(kCategoryModelKey);
    expect(local!['version'], 9);
    expect((local['classes'] as Map).keys, ['c2']);

    final again = await runtime.syncModel();
    expect(again['updated'], isFalse);
  });

  test('断网时本地留档，联网后 retryPending 用 clientId 幂等补传', () async {
    // 先联网一次把主数据拉好，再拔线
    await runtime.syncModel();
    server.offline = true;
    final out = await runtime.handleNotification(notification());
    expect(out['decision'], anyOf('recorded', 'pending'));
    expect(out.containsKey('transactionId'), isFalse);
    expect((await store.pendingUploads()).length, 1);

    server.offline = false;
    final n = await runtime.retryPending();
    expect(n, 1);
    expect(await store.pendingUploads(), isEmpty);
    final record = await store.loadCapture(out['captureId'] as String);
    expect(record!.transactionId, 't1');
    expect(record.synced, isTrue);
    expect((await store.recent()).single.transactionId, 't1');
  });

  test('调试登录：走 SessionRepo，会话落进安全存储', () async {
    secure.data.clear();
    final out = await runtime.e2eLogin({'baseUrl': 'http://127.0.0.1:48123', 'username': 'e2e', 'password': 'secret'});
    expect(out['ok'], isTrue, reason: '$out');
    expect(out['member'], 'e2e');
    final session = Session.fromJson(jsonDecode(secure.data[SessionRepo.sessionKey]!) as Map<String, dynamic>);
    expect(session.token, 'tok-e2e');
    expect(session.baseUrl, 'http://127.0.0.1:48123');
    expect(server.bodyOf('POST /api/v1/auth/login')['username'], 'e2e');
  });

  test('主数据缓存只读：后台同步不改主引擎写的缓存文件', () async {
    await cache.write(LedgerRepo.cacheKey, {'funds': <Object>[], 'seq': 0});
    await cache.write(SettingsRepo.cacheKey, {'capture': {'autoConfirmThreshold': 0.3}});
    await runtime.handleNotification(notification());
    final ledger = await cache.read<Map<String, dynamic>>(LedgerRepo.cacheKey);
    expect(ledger!['seq'], 0, reason: '缓存文件不该被 headless 引擎改写');
    final settings = await cache.read<Map<String, dynamic>>(SettingsRepo.cacheKey);
    expect((settings!['capture'] as Map)['autoConfirmThreshold'], 0.3);
  });
}
