import 'dart:async';
import 'dart:convert';

import 'package:famledger/data/api/api_client.dart';
import 'package:famledger/data/models/models.dart';
import 'package:famledger/data/repos/ai_repo.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response jsonResponse(Object body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

/// 一个按给定分片吐 SSE 的仓库（分片边界故意切在事件中间）。
AiRepo sseRepo(List<String> chunks, {int status = 200}) {
  final controller = StreamController<List<int>>();
  return AiRepo(
    ApiClient(
      baseUrl: 'https://x.dev',
      token: 'tok',
      inner: MockClient.streaming((request, body) async {
        scheduleMicrotask(() async {
          for (final chunk in chunks) {
            controller.add(utf8.encode(chunk));
          }
          await controller.close();
        });
        return http.StreamedResponse(
          controller.stream,
          status,
          headers: {'content-type': 'text/event-stream'},
        );
      }),
    ),
  );
}

void main() {
  group('对话流', () {
    test('一个分片里有 1.5 条事件也能拼对，done 之后收流', () async {
      final repo = sseRepo([
        'event: delta\ndata: {"text":"本月支出 "}\n\nevent: delta\ndata: {"te',
        'xt":"3,210 元，"}\n\nevent: delta\ndata: {"text":"比上月少 8%。"}\n\n'
            'event: done\ndata: {"usage":{"inputTokens":1200}}\n\n'
            'event: delta\ndata: {"text":"这段不该出现"}\n\n',
      ]);

      final text = await repo
          .chat([const AiChatMessage.user('这个月花了多少')], month: '2026-09')
          .join();

      expect(text, '本月支出 3,210 元，比上月少 8%。');
    });

    test('error 事件变成带原文的异常', () async {
      final repo = sseRepo([
        'event: delta\ndata: {"text":"正在看…"}\n\n',
        'event: error\ndata: {"message":"渠道余额不足"}\n\n',
      ]);

      await expectLater(
        repo.chat([const AiChatMessage.user('嗨')]).toList(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'ai_error')
              .having((e) => e.message, 'message', '渠道余额不足'),
        ),
      );
    });

    test('error 没给原因时给一句能照着做的中文', () async {
      final repo = sseRepo(['event: error\ndata: {}\n\n']);
      await expectLater(
        repo.chat([const AiChatMessage.user('嗨')]).toList(),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            contains('AI 渠道'),
          ),
        ),
      );
    });

    test('请求体带消息、月份上下文与指定渠道', () async {
      late Map<String, dynamic> sent;
      late Uri url;
      final repo = AiRepo(
        ApiClient(
          baseUrl: 'https://x.dev',
          inner: MockClient.streaming((request, body) async {
            url = request.url;
            sent = jsonDecode((request as http.Request).body) as Map<String, dynamic>;
            return http.StreamedResponse(
              Stream.value(utf8.encode('event: done\ndata: {}\n\n')),
              200,
            );
          }),
        ),
      );

      await repo
          .chat(
            [
              const AiChatMessage.user('上个月呢'),
              const AiChatMessage.assistant('上月支出 4,000 元。'),
            ],
            providerId: 'p1',
            month: '2026-08',
          )
          .toList();

      expect(url.path, '/api/v1/ai/chat');
      expect(sent['providerId'], 'p1');
      expect(sent['context'], {'month': '2026-08'});
      expect(sent['messages'], [
        {'role': 'user', 'content': '上个月呢'},
        {'role': 'assistant', 'content': '上月支出 4,000 元。'},
      ]);
    });

    test('SSE 非 2xx 直接抛错误体里的说明', () async {
      final repo = AiRepo(
        ApiClient(
          baseUrl: 'https://x.dev',
          inner: MockClient.streaming((request, body) async {
            return http.StreamedResponse(
              Stream.value(
                utf8.encode(
                  jsonEncode({
                    'error': {'code': 'no_provider', 'message': '还没配 AI 渠道'},
                  }),
                ),
              ),
              400,
            );
          }),
        ),
      );

      await expectLater(
        repo.chat([const AiChatMessage.user('嗨')]).toList(),
        throwsA(
          isA<ApiException>().having((e) => e.message, 'message', '还没配 AI 渠道'),
        ),
      );
    });
  });

  group('月报', () {
    test('月份与渠道拼在查询串里，事件按 delta 拼接', () async {
      late Uri url;
      final repo = AiRepo(
        ApiClient(
          baseUrl: 'https://x.dev',
          inner: MockClient.streaming((request, body) async {
            url = request.url;
            return http.StreamedResponse(
              Stream.value(
                utf8.encode(
                  'event: delta\ndata: {"text":"## 九月\\n"}\n\n'
                  'event: delta\ndata: {"text":"- 支出 3,210 元"}\n\n'
                  'event: done\ndata: {}\n\n',
                ),
              ),
              200,
            );
          }),
        ),
      );

      final text = await repo.report('2026-09', providerId: 'p1').join();

      expect(url.path, '/api/v1/ai/report');
      expect(url.queryParameters, {'month': '2026-09', 'providerId': 'p1'});
      expect(text, '## 九月\n- 支出 3,210 元');
    });

    test('历史月报按 items 解析', () async {
      late Uri url;
      final repo = AiRepo(
        ApiClient(
          baseUrl: 'https://x.dev',
          inner: MockClient((request) async {
            url = request.url;
            return jsonResponse({
              'items': [
                {
                  'id': 'r1',
                  'month': '2026-09',
                  'providerId': 'p1',
                  'content': '# 九月月报',
                  'createdAt': '2026-09-30T12:00:00.000Z',
                },
              ],
            });
          }),
        ),
      );

      final reports = await repo.reports(month: '2026-09');

      expect(url.queryParameters, {'month': '2026-09'});
      expect(reports.single.content, '# 九月月报');
      expect(reports.single.createdAt, isNotNull);
    });
  });

  group('渠道', () {
    test('列表与预设解析', () async {
      final repo = AiRepo(
        ApiClient(
          baseUrl: 'https://x.dev',
          inner: MockClient((request) async {
            if (request.url.path.endsWith('/ai/presets')) {
              return jsonResponse({
                'items': [
                  {
                    'key': 'cc-trans',
                    'name': 'cc-trans（自建反代）',
                    'kind': 'anthropic',
                    'baseUrl': 'http://nas:8787',
                    'model': 'claude-sonnet-4',
                    'hint': '填 cct- 令牌',
                  },
                ],
              });
            }
            return jsonResponse({
              'items': [
                {
                  'id': 'p1',
                  'name': '硅基流动',
                  'kind': 'openai',
                  'baseUrl': 'https://api.siliconflow.cn/v1',
                  'model': 'deepseek-ai/DeepSeek-V3',
                  'isDefault': true,
                  'enabled': true,
                  'hasKey': true,
                  'keyTail': '3f9a',
                },
              ],
            });
          }),
        ),
      );

      final providers = await repo.providers();
      expect(providers.single.name, '硅基流动');
      expect(providers.single.keyTail, '3f9a');
      expect(defaultProviderOf(providers)?.id, 'p1');

      final presets = await repo.presets();
      expect(presets.single.key, 'cc-trans');
      expect(presets.single.baseUrl, 'http://nas:8787');
    });

    test('新建把密钥发上去，编辑时空密钥不发（= 不修改）', () async {
      final bodies = <Map<String, dynamic>>[];
      final repo = AiRepo(
        ApiClient(
          baseUrl: 'https://x.dev',
          inner: MockClient((request) async {
            bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
            return jsonResponse({
              'provider': {'id': 'p1', 'name': '硅基流动', 'model': 'x'},
            });
          }),
        ),
      );

      await repo.create(
        name: '硅基流动',
        kind: 'openai',
        baseUrl: 'https://api.siliconflow.cn/v1',
        apiKey: 'sk-abc',
        model: 'deepseek-ai/DeepSeek-V3',
        isDefault: true,
      );
      await repo.update('p1', name: '改个名', apiKey: '');
      await repo.update('p1', apiKey: 'sk-new');
      await repo.update('p1', enabled: false);

      expect(bodies[0]['apiKey'], 'sk-abc');
      expect(bodies[0]['isDefault'], isTrue);
      expect(bodies[1].containsKey('apiKey'), isFalse);
      expect(bodies[1], {'name': '改个名'});
      expect(bodies[2]['apiKey'], 'sk-new');
      expect(bodies[3], {'enabled': false});
    });

    test('extra：新建和编辑都带上（requestExtras / importMaxTokens）；不给就不发', () async {
      final bodies = <Map<String, dynamic>>[];
      final repo = AiRepo(
        ApiClient(
          baseUrl: 'https://x.dev',
          inner: MockClient((request) async {
            bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
            return jsonResponse({
              'provider': {'id': 'p1', 'name': '硅基流动'},
            });
          }),
        ),
      );
      await repo.create(
        name: '硅基流动',
        kind: 'openai',
        baseUrl: 'https://api.siliconflow.cn/v1',
        apiKey: 'sk-abc',
        model: 'Qwen/Qwen3-32B',
        extra: {'requestExtras': {'enable_thinking': false}},
      );
      await repo.update('p1', extra: {'importMaxTokens': 8000});
      await repo.update('p1', name: '只改名');
      expect(bodies[0]['extra'], {'requestExtras': {'enable_thinking': false}});
      expect(bodies[1], {'extra': {'importMaxTokens': 8000}});
      expect(bodies[2].containsKey('extra'), isFalse);
    });

    test('测试渠道返回延迟与样例', () async {
      late Uri url;
      final repo = AiRepo(
        ApiClient(
          baseUrl: 'https://x.dev',
          inner: MockClient((request) async {
            url = request.url;
            return jsonResponse({
              'ok': true,
              'model': 'deepseek-chat',
              'latencyMs': 321,
              'sample': '你好，我在。',
            });
          }),
        ),
      );

      final result = await repo.test('p1');

      expect(url.path, '/api/v1/ai/providers/p1/test');
      expect(result.ok, isTrue);
      expect(result.latencyMs, 321);
      expect(result.sample, '你好，我在。');
    });
  });
}
