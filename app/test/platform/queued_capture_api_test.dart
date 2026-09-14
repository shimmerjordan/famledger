import 'dart:convert';

import 'package:famledger/capture/capture_types.dart';
import 'package:famledger/capture/classifier.dart';
import 'package:famledger/capture/pipeline.dart';
import 'package:famledger/data/api/api_client.dart';
import 'package:famledger/platform/file_capture_store.dart';
import 'package:famledger/platform/http_capture_api.dart';
import 'package:famledger/platform/queued_capture_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late MemoryCaptureStore store;
  late int status;
  late bool offline;
  late int successes;
  late List<http.Request> seen;
  late QueuedCaptureApi api;
  var ids = 0;

  setUp(() {
    store = MemoryCaptureStore();
    status = 200;
    offline = false;
    successes = 0;
    seen = [];
    final client = MockClient((req) async {
      if (offline) throw http.ClientException('Connection refused');
      seen.add(req);
      final body = status >= 400
          ? {'error': {'code': 'forced', 'message': '强制 $status'}}
          : {'transaction': {'id': 't1'}};
      return http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});
    });
    api = QueuedCaptureApi(
      HttpCaptureApi(ApiClient(baseUrl: 'https://x.dev', token: 'tok', inner: client)),
      store,
      onSuccess: () => successes++,
      now: () => DateTime(2026, 9, 12, 12, 30),
      idGenerator: () => 'op-${++ids}',
    );
  });

  test('成功：直通并回调 onSuccess，不入队', () async {
    await api.patchTransaction('t1', {'fundId': 'f2'});
    await api.confirmTransaction('t1');
    expect(successes, 2);
    expect(store.ops, isEmpty);
  });

  test('断网：动作入队（类型 / 流水 id / 请求体 / 反查的 captureId），异常原样抛出', () async {
    await store.saveCapture(_record('cap-1', 't1'));
    offline = true;
    await expectLater(api.patchTransaction('t1', {'fundId': 'f2', 'status': 'confirmed'}), throwsA(isA<CaptureNetworkException>()));
    await expectLater(api.deleteTransaction('t1'), throwsA(isA<CaptureNetworkException>()));
    expect(store.ops.map((o) => o.type), ['patch', 'delete']);
    expect(store.ops.first.captureId, 'cap-1');
    expect(store.ops.first.transactionId, 't1');
    expect(store.ops.first.payload, {'fundId': 'f2', 'status': 'confirmed'});
    expect(store.ops.first.id, 'op-1');
    expect(successes, 0);
  });

  test('5xx / 429 入队，4xx 不入队，都原样抛出', () async {
    status = 503;
    await expectLater(api.confirmTransaction('t1'), throwsA(isA<CaptureApiException>()));
    status = 429;
    await expectLater(api.confirmTransaction('t1'), throwsA(isA<CaptureApiException>()));
    expect(store.ops.length, 2);
    status = 400;
    // 换一条流水：直写 t1 会先把上面两条积压排空（见「排空时 4xx」用例），这里只看「4xx 不入队」
    await expectLater(api.patchTransaction('t2', {'fundId': 'x'}), throwsA(isA<CaptureApiException>().having((e) => e.isClientError, 'isClientError', isTrue)));
    expect(store.ops.length, 2, reason: '4xx 是定论，不重试；别的流水的积压原样留着');
    expect(store.ops.map((o) => o.transactionId).toSet(), {'t1'});
  });

  test('学习样本：临时故障入队（服务端形状），成功不入队，空样本不发', () async {
    const s = LearnSample(text: '美团', features: CaptureFeatures(merchant: '美团', hour: 12, weekday: 5), categoryId: 'c1');
    offline = true;
    await expectLater(api.learn(const [s]), throwsA(isA<CaptureNetworkException>()));
    expect(store.learnQueue.single.sample, s.toJson());
    offline = false;
    await api.learn(const [s]);
    expect(store.learnQueue, isEmpty, reason: '同特征的新样本发成功，旧的排队样本作废');
    final before = seen.length;
    await api.learn(const [LearnSample(text: 'x', features: CaptureFeatures(hour: 1, weekday: 1))]);
    expect(seen.length, before);
  });

  test('直写前先按序排空同一条流水的积压；别的流水的不动', () async {
    await store.enqueueOp(CaptureOp(id: 'q1', at: DateTime(2026, 9, 12), type: 'patch', captureId: 'cap-1', transactionId: 't1', payload: {'fundId': 'f2'}));
    await store.enqueueOp(CaptureOp(id: 'q2', at: DateTime(2026, 9, 12), type: 'confirm', captureId: 'cap-2', transactionId: 't2'));
    await api.patchTransaction('t1', {'fundId': 'f3'});
    final bodies = seen.map((r) => '${r.method} ${r.url.path} ${r.body}').toList();
    expect(bodies, [
      'PATCH /api/v1/transactions/t1 {"fundId":"f2"}',
      'PATCH /api/v1/transactions/t1 {"fundId":"f3"}',
    ]);
    expect(store.ops.map((o) => o.id), ['q2']);
    expect(successes, 1);
  });

  test('排空时临时故障：旧的留着，新动作排到后面，异常原样抛出', () async {
    await store.saveCapture(_record('cap-1', 't1'));
    await store.enqueueOp(CaptureOp(id: 'q1', at: DateTime(2026, 9, 12), type: 'patch', captureId: 'cap-1', transactionId: 't1', payload: {'fundId': 'f2'}));
    status = 503;
    await expectLater(api.patchTransaction('t1', {'fundId': 'f3'}), throwsA(isA<CaptureApiException>()));
    expect(store.ops.map((o) => o.payload?['fundId']), ['f2', 'f3']);
    expect(seen.length, 1, reason: '排空第一条就失败，新动作没直接发');
  });

  test('排空时 4xx：那条丢掉，继续直写', () async {
    await store.enqueueOp(CaptureOp(id: 'q1', at: DateTime(2026, 9, 12), type: 'patch', captureId: 'cap-1', transactionId: 't1', payload: {'fundId': 'f2'}));
    status = 400;
    var calls = 0;
    // 第一条（排空）400，第二条（直写）200
    api = QueuedCaptureApi(
      HttpCaptureApi(ApiClient(baseUrl: 'https://x.dev', token: 'tok', inner: MockClient((req) async {
        calls++;
        final code = calls == 1 ? 400 : 200;
        final body = code >= 400
            ? {'error': {'code': 'invalid_fundId', 'message': 'fundId 指向的基金不存在'}}
            : {'transaction': {'id': 't1'}};
        return http.Response(jsonEncode(body), code, headers: {'content-type': 'application/json; charset=utf-8'});
      }))),
      store,
      onSuccess: () => successes++,
    );
    await api.patchTransaction('t1', {'fundId': 'f3'});
    expect(calls, 2);
    expect(store.ops, isEmpty);
    expect(successes, 1);
  });

  test('建流水与 AI 兜底不排队（建流水靠记录自身幂等重发）', () async {
    offline = true;
    await expectLater(api.createTransaction({'clientId': 'c'}), throwsA(isA<CaptureNetworkException>()));
    expect(store.ops, isEmpty);
  });
}

CaptureRecord _record(String captureId, String txId) => CaptureRecord(
  captureId: captureId,
  decision: CaptureDecision.recorded,
  draft: CaptureDraft(
    clientId: captureId,
    type: 'expense',
    amountCents: 3500,
    occurredAt: DateTime(2026, 9, 12, 12, 30),
    memberId: 'm1',
    status: 'confirmed',
    confidence: 0.9,
    rawText: 'x',
    sourceApp: 'com.eg.android.AlipayGphone',
    captureId: captureId,
  ),
  dedupeHash: 'h',
  learnText: '美团',
  features: const CaptureFeatures(hour: 12, weekday: 5),
  createdAt: DateTime(2026, 9, 12, 12, 30),
  transactionId: txId,
  synced: true,
);
