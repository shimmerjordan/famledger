import 'dart:convert';

import 'package:famledger/capture/classifier.dart';
import 'package:famledger/capture/pipeline.dart';
import 'package:famledger/data/api/api_client.dart';
import 'package:famledger/platform/http_capture_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class Server {
  final List<http.Request> seen = [];
  bool offline = false;
  Object Function(http.Request req)? respond;
  int status = 200;

  http.Client get client => MockClient((req) async {
    if (offline) throw http.ClientException('Connection refused');
    seen.add(req);
    final body = respond?.call(req) ?? const <String, dynamic>{};
    return http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });

  http.Request get last => seen.last;
  Map<String, dynamic> get lastBody => jsonDecode(last.body) as Map<String, dynamic>;
}

void main() {
  late Server server;
  late HttpCaptureApi api;

  setUp(() {
    server = Server();
    api = HttpCaptureApi(
      ApiClient(baseUrl: 'https://x.dev/', token: 'tok', inner: server.client),
      aiEnabled: true,
    );
  });

  test('createTransaction：POST /api/v1/transactions，带令牌，解开 {transaction} 信封', () async {
    server.respond = (_) => {'transaction': {'id': 't1', 'status': 'confirmed'}};
    final res = await api.createTransaction({'clientId': 'cap-1', 'amountCents': 3500});
    expect(res.id, 't1');
    expect(res.duplicate, isFalse);
    expect(server.last.method, 'POST');
    expect(server.last.url.toString(), 'https://x.dev/api/v1/transactions');
    expect(server.last.headers['authorization'], 'Bearer tok');
    expect(server.lastBody['clientId'], 'cap-1');
  });

  test('createTransaction：顶层 duplicate:true 透传', () async {
    server.respond = (_) => {'transaction': {'id': 't2', 'status': 'duplicate'}, 'duplicate': true};
    final res = await api.createTransaction({'clientId': 'cap-2'});
    expect(res.id, 't2');
    expect(res.duplicate, isTrue);
  });

  test('4xx → CaptureApiException(status, code, message)，isClientError', () async {
    server.status = 400;
    server.respond = (_) => {'error': {'code': 'invalid_occurredAt', 'message': 'occurredAt 必须带时区偏移'}};
    try {
      await api.createTransaction({});
      fail('should throw');
    } on CaptureApiException catch (e) {
      expect(e.status, 400);
      expect(e.code, 'invalid_occurredAt');
      expect(e.message, 'occurredAt 必须带时区偏移');
      expect(e.isClientError, isTrue);
    }
  });

  test('5xx → CaptureApiException 但 isTransient', () async {
    server.status = 503;
    server.respond = (_) => {'error': {'code': 'busy', 'message': '稍后再试'}};
    expect(
      () => api.confirmTransaction('t1'),
      throwsA(isA<CaptureApiException>().having((e) => e.isTransient, 'isTransient', isTrue)),
    );
  });

  test('断网 → CaptureNetworkException，不是 CaptureApiException', () async {
    server.offline = true;
    expect(
      () => api.patchTransaction('t1', {'fundId': 'f2'}),
      throwsA(isA<CaptureNetworkException>()),
    );
  });

  test('patch / confirm / delete 打对路径', () async {
    server.respond = (_) => {'transaction': {'id': 't1'}};
    await api.patchTransaction('t1', {'fundId': 'f2', 'status': 'confirmed'});
    expect('${server.last.method} ${server.last.url.path}', 'PATCH /api/v1/transactions/t1');
    expect(server.lastBody, {'fundId': 'f2', 'status': 'confirmed'});

    await api.confirmTransaction('t1');
    expect('${server.last.method} ${server.last.url.path}', 'POST /api/v1/transactions/t1/confirm');

    await api.deleteTransaction('t1');
    expect('${server.last.method} ${server.last.url.path}', 'DELETE /api/v1/transactions/t1');
  });

  test('learn：{samples:[LearnSample.toJson()]}，空样本不发请求', () async {
    server.respond = (_) => {'version': 2, 'learned': {'category': 1, 'fund': 0}};
    await api.learn(const [
      LearnSample(
        text: '美团',
        features: CaptureFeatures(merchant: '美团', direction: 'expense', channel: 'alipay', amountCents: 3500, hour: 12, weekday: 5, memberId: 'm1'),
        categoryId: 'c1',
      ),
    ]);
    expect(server.last.url.path, '/api/v1/model/learn');
    final samples = server.lastBody['samples'] as List<dynamic>;
    expect(samples.single, {
      'text': '美团',
      'merchant': '美团',
      'direction': 'expense',
      'channel': 'alipay',
      'amountCents': 3500,
      'hour': 12,
      'weekday': 5,
      'memberId': 'm1',
      'categoryId': 'c1',
    });

    final before = server.seen.length;
    await api.learn(const [LearnSample(text: 'x', features: CaptureFeatures(hour: 1, weekday: 1))]);
    await api.learn(const []);
    expect(server.seen.length, before, reason: '没有标签的样本不该发');
  });

  test('aiClassify：改成服务端要的 {text, merchant, amountCents, candidates:{categories, funds}}', () async {
    server.respond = (_) => {'categoryId': 'c2', 'fundId': 'f1', 'confidence': 0.83};
    final out = await api.aiClassify({
      'text': '滴滴出行 −¥23.00',
      'merchant': '滴滴出行',
      'amountCents': 2300,
      'direction': 'expense',
      'channel': 'alipay',
      'categories': [{'id': 'c1', 'name': '餐饮'}, {'id': 'c2', 'name': '交通'}],
      'funds': [{'id': 'f1', 'name': '家庭公共'}],
    });
    expect(server.last.url.path, '/api/v1/ai/classify');
    expect(server.lastBody, {
      'text': '滴滴出行 −¥23.00',
      'merchant': '滴滴出行',
      'amountCents': 2300,
      'candidates': {
        'categories': [{'id': 'c1', 'name': '餐饮'}, {'id': 'c2', 'name': '交通'}],
        'funds': [{'id': 'f1', 'name': '家庭公共'}],
      },
    });
    expect(out, {'categoryId': 'c2', 'fundId': 'f1', 'confidence': 0.83});
  });

  test('aiClassify：设置关着就返回 null 且不打网络', () async {
    final quiet = HttpCaptureApi(ApiClient(baseUrl: 'https://x.dev', inner: server.client));
    expect(await quiet.aiClassify({'text': 'x'}), isNull);
    expect(server.seen, isEmpty);
  });

  test('fetchModel：GET /api/v1/model', () async {
    server.respond = (_) => {'version': 7, 'category': {'version': 7}, 'fund': {'version': 3}};
    final model = await api.fetchModel();
    expect(server.last.method, 'GET');
    expect(server.last.url.path, '/api/v1/model');
    expect(model['version'], 7);
  });
}
