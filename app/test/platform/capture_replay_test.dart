import 'dart:convert';
import 'dart:io';

import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/data/local/secure_store.dart';
import 'package:famledger/data/repos/session_repo.dart';
import 'package:famledger/platform/capture_runtime.dart';
import 'package:famledger/platform/file_capture_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_server.dart';

Map<String, Object> notification(String text) => {
  'id': 'key-${text.hashCode}',
  'package': 'com.eg.android.AlipayGphone',
  'title': '支付宝',
  'text': text,
  'bigText': '',
  'postedAt': DateTime(2026, 9, 12, 12, 30).millisecondsSinceEpoch,
};

Map<String, dynamic> sample(String text, {String categoryId = 'c1'}) => {
  'text': text,
  'merchant': text,
  'hour': 12,
  'weekday': 5,
  'categoryId': categoryId,
};

void main() {
  late Directory dir;
  late FakeServer server;
  late FileCaptureStore store;
  late CaptureRuntime runtime;

  CaptureRuntime build({bool autoReplay = false}) {
    final secure = MemorySecureStore();
    secure.data[SessionRepo.baseUrlKey] = 'https://x.dev';
    secure.data[SessionRepo.sessionKey] = jsonEncode({
      'baseUrl': 'https://x.dev',
      'token': 'tok',
      'deviceId': 'dev',
      'me': {'id': 'm1', 'username': 'mama', 'displayName': '妈妈', 'role': 'admin'},
    });
    return CaptureRuntime(
      secure: secure,
      cache: MemoryLocalStore(),
      store: store,
      httpClient: server.client,
      autoReplay: autoReplay,
      now: () => DateTime(2026, 9, 12, 12, 31),
    );
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('fl-capture-replay-');
    server = FakeServer();
    store = FileCaptureStore(dir);
    runtime = build();
  });

  tearDown(() => dir.deleteSync(recursive: true));

  /// 在线建一笔，返回 captureId。
  Future<String> capture(String text) async {
    final out = await runtime.handleNotification(notification(text));
    expect(out['transactionId'], isNotNull, reason: '$out');
    return out['captureId'] as String;
  }

  test('离线快捷回复 → 动作与学习样本入队；联网后只重放一次，记录变已同步', () async {
    final captureId = await capture('你有一笔35.00元的支出，来自美团');
    final txId = (await store.loadCapture(captureId))!.transactionId!;

    server.offline = true;
    final out = await runtime.handleAction({'captureId': captureId, 'action': 'reply', 'text': '宠物'});
    expect(out['title'], startsWith('已更新'), reason: '断网是临时故障：先落本地、乐观提示，联网后重放');
    expect(out['body'], contains('联网后自动同步'));
    // 本地记录改了但没同步
    final offlineRecord = (await store.loadCapture(captureId))!;
    expect(offlineRecord.synced, isFalse);
    expect(offlineRecord.draft.fundId, 'f2');

    final ops = await store.pendingOps();
    expect(ops.map((o) => o.type), ['patch']);
    expect(ops.single.transactionId, txId);
    expect(ops.single.captureId, captureId);
    expect(ops.single.payload, {'fundId': 'f2', 'status': 'confirmed'});
    final learn = await store.pendingLearn();
    expect(learn.length, 1);
    expect(learn.single.sample['fundId'], 'f2');
    expect(learn.single.sample['text'], '美团');
    expect(server.calls.where((c) => c.startsWith('PATCH')), isEmpty);

    server.offline = false;
    final before = server.seen.length;
    final replayed = await runtime.replayPending();
    expect(replayed['ok'], isTrue);
    expect(replayed['ops'], 1);
    expect(replayed['learned'], 1);
    expect(replayed['stopped'], isFalse);

    final calls = server.calls.sublist(before);
    expect(calls.where((c) => c == 'PATCH /api/v1/transactions/$txId').length, 1);
    expect(calls.where((c) => c == 'POST /api/v1/model/learn').length, 1);
    expect(server.bodyOf('PATCH /api/v1/transactions/$txId'), {'fundId': 'f2', 'status': 'confirmed'});
    expect(server.transactions[txId]!['fundId'], 'f2');
    expect(await store.pendingOps(), isEmpty);
    expect(await store.pendingLearn(), isEmpty);
    expect((await store.loadCapture(captureId))!.synced, isTrue);

    // 幂等：再来一次什么都不发
    final again = server.seen.length;
    final second = await runtime.replayPending();
    expect(second['ops'], 0);
    expect(second['learned'], 0);
    expect(server.calls.sublist(again).where((c) => c.startsWith('PATCH') || c.endsWith('/model/learn')), isEmpty);
  });

  test('离线先确认再撤销：两条动作按顺序重放，撤销后服务端没有这笔，墓碑记录同步完成', () async {
    final captureId = await capture('你有一笔42.00元的支出，来自滴滴出行');
    final txId = (await store.loadCapture(captureId))!.transactionId!;

    server.offline = true;
    await runtime.handleAction({'captureId': captureId, 'action': 'confirm'});
    final undone = await runtime.handleAction({'captureId': captureId, 'action': 'undo'});
    expect(undone['title'], '已撤销');
    expect((await store.pendingOps()).map((o) => o.type), ['confirm', 'delete']);
    // 撤销时管线先删了记录再推删除，入队那一刻查不到 captureId，重放时按流水 id 反查
    expect((await store.pendingOps()).last.transactionId, txId);

    server.offline = false;
    final before = server.seen.length;
    final replayed = await runtime.replayPending();
    expect(replayed['ops'], 2);
    final calls = server.calls.sublist(before).where((c) => c.contains('/transactions/$txId')).toList();
    expect(calls, ['POST /api/v1/transactions/$txId/confirm', 'DELETE /api/v1/transactions/$txId']);
    expect(server.transactions.containsKey(txId), isFalse);
    expect(await store.pendingOps(), isEmpty);
    final tombstone = (await store.loadCapture(captureId))!;
    expect(tombstone.synced, isTrue);
  });

  test('重放遇到 4xx：丢掉那条并记 syncError，后面的照常；删除撞 404 算成功', () async {
    final captureId = await capture('你有一笔18.00元的支出，来自肯德基');
    final txId = (await store.loadCapture(captureId))!.transactionId!;
    final at = DateTime(2026, 9, 12, 12, 32);
    await store.enqueueOp(CaptureOp(id: 'op-1', at: at, type: 'patch', captureId: captureId, transactionId: txId, payload: {'fundId': 'reject'}));
    await store.enqueueOp(CaptureOp(id: 'op-2', at: at, type: 'confirm', captureId: captureId, transactionId: txId));
    await store.enqueueOp(CaptureOp(id: 'op-3', at: at, type: 'delete', captureId: captureId, transactionId: 'no-such-tx'));

    final replayed = await runtime.replayPending();
    expect(replayed['ops'], 1, reason: 'confirm 成功');
    expect(replayed['opsDropped'], 2, reason: '400 的 patch 与 404 的 delete 都是定论');
    expect(await store.pendingOps(), isEmpty);
    expect(server.transactions[txId]!['status'], 'confirmed');
    // 400 那条给记录记了 syncError；随后 confirm 成功又把它清掉了（动作都推完了）
    final record = (await store.loadCapture(captureId))!;
    expect(record.synced, isTrue);
    expect(record.syncError, isNull);
  });

  test('重放遇到 5xx：停在那条，队列保留；服务端恢复后接着放完', () async {
    final captureId = await capture('你有一笔66.00元的支出，来自星巴克');
    final txId = (await store.loadCapture(captureId))!.transactionId!;
    final at = DateTime(2026, 9, 12, 12, 32);
    await store.enqueueOp(CaptureOp(id: 'op-1', at: at, type: 'patch', captureId: captureId, transactionId: txId, payload: {'note': '拿铁'}));
    await store.enqueueOp(CaptureOp(id: 'op-2', at: at, type: 'confirm', captureId: captureId, transactionId: txId));
    await store.enqueueLearn([sample('星巴克')]);

    server.statusOverrides['PATCH /api/v1/transactions/$txId'] = 503;
    final first = await runtime.replayPending();
    expect(first['ops'], 0);
    expect(first['stopped'], isTrue);
    expect(first['learned'], 0, reason: '动作没放完就不碰学习队列，保持顺序');
    expect((await store.pendingLearn()).length, 1);
    expect((await store.pendingOps()).length, 2);
    expect((await store.loadCapture(captureId))!.syncError, isNull, reason: '临时故障不算定论');

    server.statusOverrides.clear();
    final second = await runtime.replayPending();
    expect(second['ops'], 2);
    expect(second['learned'], 1);
    expect(second['stopped'], isFalse);
    expect(server.transactions[txId]!['note'], '拿铁');
    expect(await store.pendingOps(), isEmpty);
    expect(await store.pendingLearn(), isEmpty);
  });

  test('学习样本分批补发（≤50/批），整批 400 时逐条重发只丢坏样本', () async {
    await store.enqueueLearn([for (var i = 0; i < 120; i++) sample('商户$i', categoryId: i == 77 ? 'bad' : 'c1')]);

    final replayed = await runtime.replayPending();
    expect(replayed['learned'], 119);
    expect(replayed['learnDropped'], 1);
    expect(replayed['stopped'], isFalse);
    expect(await store.pendingLearn(), isEmpty);
    // 50（成功）+ 50（含坏样本，400）→ 50 条逐条 + 20（成功）
    expect(server.learnBatchSizes.first, 50);
    expect(server.learnBatchSizes.where((n) => n == 50).length, 2);
    expect(server.learnBatchSizes.where((n) => n == 1).length, 50);
    expect(server.learnBatchSizes.last, 20);
  });

  test('没登录时不重放；离线时停在第一条', () async {
    final at = DateTime(2026, 9, 12, 12, 32);
    await store.enqueueOp(CaptureOp(id: 'op-1', at: at, type: 'confirm', captureId: 'cap-x', transactionId: 't-x'));

    final noSession = CaptureRuntime(
      secure: MemorySecureStore(),
      cache: MemoryLocalStore(),
      store: store,
      httpClient: server.client,
      autoReplay: false,
    );
    expect((await noSession.replayPending())['reason'], 'no_session');

    server.offline = true;
    final offline = await runtime.replayPending();
    expect(offline['stopped'], isTrue);
    expect((await store.pendingOps()).length, 1);
  });

  test('自动重放：网络回来后第一次成功的接口调用会把积压放出去', () async {
    final auto = build(autoReplay: true);
    final captureId = await (() async {
      final out = await auto.handleNotification(notification('你有一笔35.00元的支出，来自美团'));
      return out['captureId'] as String;
    })();
    final txId = (await store.loadCapture(captureId))!.transactionId!;

    server.offline = true;
    await auto.handleAction({'captureId': captureId, 'action': 'reply', 'text': '宠物'});
    expect((await store.pendingOps()).length, 1);

    server.offline = false;
    // 一笔新通知在线成功 → onSuccess → 下一轮事件循环重放
    await auto.handleNotification(notification('你有一笔42.00元的支出，来自滴滴出行'));
    for (var i = 0; i < 20 && (await store.pendingOps()).isNotEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(await store.pendingOps(), isEmpty);
    expect(server.calls.where((c) => c == 'PATCH /api/v1/transactions/$txId').length, 1);
    expect(server.transactions[txId]!['fundId'], 'f2');
  });

  group('先排空再直写（旧动作不能盖掉新结果）', () {
    test('离线回复「宠物」、在线再回复「旅行」：旧 patch 先按序推出去，最终服务端是旅行，没有事后重放', () async {
      final captureId = await capture('你有一笔35.00元的支出，来自美团');
      final txId = (await store.loadCapture(captureId))!.transactionId!;

      server.offline = true;
      await runtime.handleAction({'captureId': captureId, 'action': 'reply', 'text': '宠物'});
      expect((await store.pendingOps()).map((o) => o.payload?['fundId']), ['f2']);

      server.offline = false;
      final before = server.seen.length;
      final out = await runtime.handleAction({'captureId': captureId, 'action': 'reply', 'text': '旅行'});
      expect(out['title'], startsWith('已更新'));
      final patches = server.seen
          .sublist(before)
          .where((r) => r.method == 'PATCH')
          .map((r) => (jsonDecode(r.body) as Map<String, dynamic>)['fundId'])
          .toList();
      expect(patches, ['f2', 'f3'], reason: '先排空积压的宠物，再写旅行');
      expect(server.transactions[txId]!['fundId'], 'f3');
      expect(await store.pendingOps(), isEmpty);
      expect((await store.loadCapture(captureId))!.synced, isTrue);

      final again = server.seen.length;
      final replayed = await runtime.replayPending();
      expect(replayed['ops'], 0);
      expect(server.seen.sublist(again).where((r) => r.method == 'PATCH'), isEmpty);
      expect(server.transactions[txId]!['fundId'], 'f3', reason: '重放不会把旧的宠物盖回去');
    });

    test('离线确认、在线撤销：确认先推出去再删除，本地不留带 syncError 的残留', () async {
      final captureId = await capture('你有一笔42.00元的支出，来自滴滴出行');
      final txId = (await store.loadCapture(captureId))!.transactionId!;

      server.offline = true;
      await runtime.handleAction({'captureId': captureId, 'action': 'confirm'});
      expect((await store.pendingOps()).map((o) => o.type), ['confirm']);

      server.offline = false;
      final before = server.seen.length;
      final out = await runtime.handleAction({'captureId': captureId, 'action': 'undo'});
      expect(out['title'], '已撤销');
      final calls = server.calls.sublist(before).where((c) => c.contains('/transactions/$txId')).toList();
      expect(calls, ['POST /api/v1/transactions/$txId/confirm', 'DELETE /api/v1/transactions/$txId']);
      expect(server.transactions.containsKey(txId), isFalse);
      expect(await store.pendingOps(), isEmpty);

      final replayed = await runtime.replayPending();
      expect(replayed['opsDropped'], 0);
      expect(replayed['ops'], 0);
      expect(await store.loadCapture(captureId), isNull, reason: '撤销成功：本地记录一并删掉，没有带 syncError 的残留');
    });

    test('学习样本：同一条捕获再纠正一次，队列里的旧样本作废，共享模型只学到新标签', () async {
      final captureId = await capture('你有一笔35.00元的支出，来自美团');

      server.offline = true;
      await runtime.handleAction({'captureId': captureId, 'action': 'reply', 'text': '宠物'});
      expect((await store.pendingLearn()).map((e) => e.sample['fundId']), ['f2']);

      server.offline = false;
      final before = server.seen.length;
      await runtime.handleAction({'captureId': captureId, 'action': 'reply', 'text': '旅行'});
      final learnBodies = server.seen
          .sublist(before)
          .where((r) => r.url.path == '/api/v1/model/learn')
          .map((r) => ((jsonDecode(r.body) as Map<String, dynamic>)['samples'] as List).single as Map)
          .toList();
      expect(learnBodies.map((s) => s['fundId']), ['f3'], reason: '旧的宠物样本不再发');
      expect(await store.pendingLearn(), isEmpty);

      final again = server.seen.length;
      await runtime.replayPending();
      expect(server.seen.sublist(again).where((r) => r.url.path == '/api/v1/model/learn'), isEmpty);
    });

    test('排空时仍离线：新动作排在旧动作后面，联网后按序全部推完', () async {
      final captureId = await capture('你有一笔18.00元的支出，来自肯德基');
      final txId = (await store.loadCapture(captureId))!.transactionId!;

      server.offline = true;
      await runtime.handleAction({'captureId': captureId, 'action': 'reply', 'text': '宠物'});
      await runtime.handleAction({'captureId': captureId, 'action': 'reply', 'text': '旅行'});
      expect((await store.pendingOps()).map((o) => o.payload?['fundId']), ['f2', 'f3']);

      server.offline = false;
      await runtime.replayPending();
      expect(server.transactions[txId]!['fundId'], 'f3');
      expect(await store.pendingOps(), isEmpty);
    });
  });

  test('学习补发中途 503：已发的批次立刻出队，恢复后不重发', () async {
    await store.enqueueLearn([for (var i = 0; i < 120; i++) sample('商户$i')]);
    server.learnFailFrom = 2; // 第一批成功，第二批开始 503

    final first = await runtime.replayPending();
    expect(first['learned'], 50);
    expect(first['stopped'], isTrue);
    expect((await store.pendingLearn()).length, 70, reason: '发成功的 50 条已经出队');

    server.learnFailFrom = null;
    final second = await runtime.replayPending();
    expect(second['learned'], 70);
    expect(await store.pendingLearn(), isEmpty);
    expect(server.learnBatchSizes, [50, 50, 20], reason: '总共恰好 120 条，没有重发');
  });

  test('不认识的动作类型：丢掉并计数，不把记录标成已同步', () async {
    final captureId = await capture('你有一笔66.00元的支出，来自星巴克');
    final record = (await store.loadCapture(captureId))!;
    await store.saveCapture(record.copyWith(synced: false));
    await store.enqueueOp(CaptureOp(id: 'op-x', at: DateTime(2026, 9, 12), type: 'frobnicate', captureId: captureId, transactionId: record.transactionId!));

    final replayed = await runtime.replayPending();
    expect(replayed['opsDropped'], 1);
    expect(replayed['ops'], 0);
    expect(await store.pendingOps(), isEmpty);
    expect((await store.loadCapture(captureId))!.synced, isFalse);
  });
}
