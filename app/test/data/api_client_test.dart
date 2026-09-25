import 'dart:async';
import 'dart:convert';

import 'package:famledger/data/api/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response jsonResponse(Object body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  group('地址拼接', () {
    test('去掉 baseUrl 末尾斜杠并加 /api/v1 前缀，query 拼在后面', () async {
      late Uri seen;
      final api = ApiClient(
        baseUrl: 'https://ledger.example.com/',
        inner: MockClient((req) async {
          seen = req.url;
          return jsonResponse({'items': []});
        }),
      );
      await api.get('/transactions', query: {'limit': '10', 'q': '肯德基'});
      expect(seen.origin, 'https://ledger.example.com');
      expect(seen.path, '/api/v1/transactions');
      expect(seen.queryParameters, {'limit': '10', 'q': '肯德基'});
      expect(api.baseUrl, 'https://ledger.example.com');
    });

    test('prefix 可置空以访问 /healthz', () async {
      late Uri seen;
      final api = ApiClient(
        baseUrl: 'https://ledger.example.com',
        prefix: '',
        inner: MockClient((req) async {
          seen = req.url;
          return jsonResponse({'ok': true});
        }),
      );
      await api.get('/healthz');
      expect(seen.toString(), 'https://ledger.example.com/healthz');
    });
  });

  group('请求头与请求体', () {
    test('有 token 时带 Authorization: Bearer', () async {
      late http.Request seen;
      final api = ApiClient(
        baseUrl: 'https://x.dev',
        token: 'tok-123',
        inner: MockClient((req) async {
          seen = req;
          return jsonResponse({'ok': true});
        }),
      );
      await api.get('/auth/me');
      expect(seen.headers['authorization'], 'Bearer tok-123');
      expect(seen.headers['accept'], contains('application/json'));
    });

    test('无 token 时不带 Authorization', () async {
      late http.Request seen;
      final api = ApiClient(
        baseUrl: 'https://x.dev',
        inner: MockClient((req) async {
          seen = req;
          return jsonResponse({'ok': true});
        }),
      );
      await api.get('/setup/status');
      expect(seen.headers.containsKey('authorization'), isFalse);
    });

    test('token 可后设并立即生效', () async {
      late http.Request seen;
      final api = ApiClient(
        baseUrl: 'https://x.dev',
        inner: MockClient((req) async {
          seen = req;
          return jsonResponse({'ok': true});
        }),
      );
      api.token = 'later';
      await api.get('/auth/me');
      expect(seen.headers['authorization'], 'Bearer later');
    });

    test('post 发送 JSON 体并解析 JSON 响应', () async {
      late http.Request seen;
      final api = ApiClient(
        baseUrl: 'https://x.dev',
        inner: MockClient((req) async {
          seen = req;
          return jsonResponse({'id': 't1'}, status: 201);
        }),
      );
      final out = await api.post('/transactions', {'amountCents': 100});
      expect(seen.method, 'POST');
      expect(seen.headers['content-type'], contains('application/json'));
      expect(jsonDecode(seen.body), {'amountCents': 100});
      expect(out['id'], 't1');
    });

    test('patch 与 delete 走对应方法，204 空体不报错', () async {
      final methods = <String>[];
      final api = ApiClient(
        baseUrl: 'https://x.dev',
        inner: MockClient((req) async {
          methods.add(req.method);
          return http.Response('', 204);
        }),
      );
      expect(await api.patch('/transactions/t1', {'note': 'x'}), isEmpty);
      await api.delete('/transactions/t1');
      expect(methods, ['PATCH', 'DELETE']);
    });

    test('顶层数组响应包成 {items: [...]}', () async {
      final api = ApiClient(
        baseUrl: 'https://x.dev',
        inner: MockClient((req) async => jsonResponse([
          {'id': 'f1'},
        ])),
      );
      final out = await api.get('/funds');
      expect(out['items'], [
        {'id': 'f1'},
      ]);
    });
  });

  group('错误映射', () {
    test('服务端 {error:{code,message}} 映射为 ApiException', () async {
      final api = ApiClient(
        baseUrl: 'https://x.dev',
        inner: MockClient(
          (req) async => jsonResponse({
            'error': {'code': 'bad_credentials', 'message': '用户名或密码不对'},
          }, status: 401),
        ),
      );
      await expectLater(
        api.post('/auth/login', {}),
        throwsA(
          isA<ApiException>()
              .having((e) => e.status, 'status', 401)
              .having((e) => e.code, 'code', 'bad_credentials')
              .having((e) => e.message, 'message', '用户名或密码不对')
              .having((e) => e.isUnauthorized, 'isUnauthorized', true),
        ),
      );
    });

    test('error.details 带进 ApiException.details；没有 details 就是空 Map', () async {
      final api = ApiClient(
        baseUrl: 'https://x.dev',
        inner: MockClient(
          (req) async => req.url.path.endsWith('/platforms')
              ? jsonResponse({
                  'error': {
                    'code': 'name_taken',
                    'message': '已经有叫「优酷」的平台了',
                    'details': {'id': 'p1', 'name': '优酷'},
                  },
                }, status: 409)
              : jsonResponse({
                  'error': {'code': 'not_found', 'message': '没有'},
                }, status: 404),
        ),
      );
      await expectLater(
        api.post('/platforms', {'name': 'YOUKU'}),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'name_taken')
              .having((e) => e.details, 'details', {'id': 'p1', 'name': '优酷'}),
        ),
      );
      await expectLater(
        api.get('/nothing'),
        throwsA(isA<ApiException>().having((e) => e.details, 'details', isEmpty)),
      );
    });

    test('非 JSON 错误体回退到 http_<status>', () async {
      final api = ApiClient(
        baseUrl: 'https://x.dev',
        inner: MockClient((req) async => http.Response('<html>oops</html>', 502)),
      );
      await expectLater(
        api.get('/stats/overview'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.status, 'status', 502)
              .having((e) => e.code, 'code', 'http_502'),
        ),
      );
    });

    test('响应体迟迟不来也会超时（超时覆盖读体阶段，不只是连接）', () async {
      final never = StreamController<List<int>>();
      addTearDown(never.close);
      final api = ApiClient(
        baseUrl: 'https://x.dev',
        timeout: const Duration(milliseconds: 80),
        inner: MockClient.streaming(
          (req, body) async => http.StreamedResponse(never.stream, 200),
        ),
      );
      await expectLater(
        api.get('/stats/overview'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.status, 'status', 0)
              .having((e) => e.code, 'code', 'network')
              .having((e) => e.message, 'message', contains('超时')),
        ),
      );
    });

    test('网络异常映射为 ApiException(0, network)', () async {
      final api = ApiClient(
        baseUrl: 'https://x.dev',
        inner: MockClient((req) async {
          throw http.ClientException('connection refused');
        }),
      );
      await expectLater(
        api.get('/funds'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.status, 'status', 0)
              .having((e) => e.code, 'code', 'network')
              .having((e) => e.isNetwork, 'isNetwork', true),
        ),
      );
    });
  });

  group('SSE', () {
    ApiClient sseClient(List<String> chunks, {int status = 200}) {
      final controller = StreamController<List<int>>();
      return ApiClient(
        baseUrl: 'https://x.dev',
        token: 'tok',
        inner: MockClient.streaming((req, body) async {
          scheduleMicrotask(() async {
            for (final c in chunks) {
              controller.add(utf8.encode(c));
            }
            await controller.close();
          });
          return http.StreamedResponse(
            controller.stream,
            status,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );
    }

    test('跨 chunk 的半个事件能被正确缓冲拼接', () async {
      final api = sseClient([
        'event: delta\ndata: {"text":"你好"}\n\nevent: delta\ndata: {"te',
        'xt":"世界"}\n\nevent: done\ndata: {"usage":{"in":1}}\n\n',
      ]);
      final events = await api.sse('/ai/chat', {'messages': []}).toList();
      expect(events.map((e) => e.event).toList(), ['delta', 'delta', 'done']);
      expect(events[0].data, '{"text":"你好"}');
      expect(events[1].json['text'], '世界');
      expect(events[2].json['usage'], {'in': 1});
    });

    test('多行 data 以换行拼接，缺省事件名为 message', () async {
      final api = sseClient(['data: 第一行\ndata: 第二行\n\n']);
      final events = await api.sse('/ai/report', null).toList();
      expect(events.single.event, 'message');
      expect(events.single.data, '第一行\n第二行');
    });

    test('CRLF 与注释行被忽略', () async {
      final api = sseClient([': keep-alive\r\nevent: delta\r\ndata: hi\r\n\r\n']);
      final events = await api.sse('/ai/chat', null).toList();
      expect(events.single.event, 'delta');
      expect(events.single.data, 'hi');
    });

    test('SSE 请求带鉴权与 accept 头', () async {
      late http.BaseRequest seen;
      final api = ApiClient(
        baseUrl: 'https://x.dev',
        token: 'tok',
        inner: MockClient.streaming((req, body) async {
          seen = req;
          return http.StreamedResponse(
            Stream.value(utf8.encode('event: done\ndata: {}\n\n')),
            200,
          );
        }),
      );
      await api.sse('/ai/chat', {'messages': []}).toList();
      expect(seen.headers['authorization'], 'Bearer tok');
      expect(seen.headers['accept'], 'text/event-stream');
      expect(seen.method, 'POST');
    });

    test('SSE 非 2xx 抛 ApiException', () async {
      final api = ApiClient(
        baseUrl: 'https://x.dev',
        inner: MockClient.streaming(
          (req, body) async => http.StreamedResponse(
            Stream.value(
              utf8.encode(
                jsonEncode({
                  'error': {'code': 'no_provider', 'message': '未配置 AI 渠道'},
                }),
              ),
            ),
            400,
          ),
        ),
      );
      await expectLater(
        api.sse('/ai/chat', null).toList(),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'no_provider')),
      );
    });
  });
}
