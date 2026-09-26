import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../api/api_client.dart';
import '../models/models.dart';

/// AI 渠道与对话/月报。对话与月报走 SSE，逐段吐文字。
class AiRepo {
  AiRepo(this._api);

  final ApiClient _api;

  // —— 渠道 ——

  Future<List<AiProvider>> providers() async =>
      jsonList((await _api.get('/ai/providers'))['items'], AiProvider.fromJson);

  Future<List<AiPreset>> presets() async =>
      jsonList((await _api.get('/ai/presets'))['items'], AiPreset.fromJson);

  Future<AiProvider> create({
    required String name,
    required String kind,
    required String baseUrl,
    required String apiKey,
    required String model,
    bool isDefault = false,
    Map<String, dynamic>? extra,
  }) async {
    final res = await _api.post('/ai/providers', {
      'name': name,
      'kind': kind,
      'baseUrl': baseUrl,
      'apiKey': apiKey,
      'model': model,
      'isDefault': isDefault,
      'extra': ?extra,
    });
    return AiProvider.fromJson(jsonMap(res['provider'] ?? res));
  }

  /// [apiKey] 留空 = 不改密钥（服务端同样把空串当作不改）。[extra] 给了就整个替换（requestExtras / importMaxTokens，
  /// 以及 P5 的 vision 等别的键 —— 调用方先拿原来的 extra 合并好再传）。
  Future<AiProvider> update(
    String id, {
    String? name,
    String? kind,
    String? baseUrl,
    String? apiKey,
    String? model,
    bool? isDefault,
    bool? enabled,
    Map<String, dynamic>? extra,
  }) async {
    final body = <String, dynamic>{};
    putIfNotNull(body, 'name', name);
    putIfNotNull(body, 'kind', kind);
    putIfNotNull(body, 'baseUrl', baseUrl);
    putIfNotNull(body, 'model', model);
    putIfNotNull(body, 'isDefault', isDefault);
    putIfNotNull(body, 'enabled', enabled);
    putIfNotNull(body, 'extra', extra);
    if (apiKey != null && apiKey.isNotEmpty) body['apiKey'] = apiKey;
    final res = await _api.patch('/ai/providers/$id', body);
    return AiProvider.fromJson(jsonMap(res['provider'] ?? res));
  }

  Future<void> remove(String id) => _api.delete('/ai/providers/$id');

  Future<AiProviderTest> test(String id) async =>
      AiProviderTest.fromJson(await _api.post('/ai/providers/$id/test', const {}));

  // —— 对话与月报 ——

  /// 一问一答的流：每个 `delta` 事件吐一段文字，`done` 结束，`error` 抛异常。
  Stream<String> chat(
    List<AiChatMessage> messages, {
    String? providerId,
    String? month,
  }) {
    final context = <String, dynamic>{};
    putIfNotNull(context, 'month', month);
    final body = <String, dynamic>{
      'messages': messages.map((m) => m.toJson()).toList(),
      'context': context,
    };
    putIfNotNull(body, 'providerId', providerId);
    return _stream('/ai/chat', body);
  }

  /// 生成某月的月报；完成后服务端会把内容落库，用 [reports] 能再读回来。
  Stream<String> report(String month, {String? providerId}) {
    final query = <String, String>{'month': month};
    if (providerId != null && providerId.isNotEmpty) query['providerId'] = providerId;
    final qs = query.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return _stream('/ai/report?$qs', const <String, dynamic>{});
  }

  Future<List<AiReport>> reports({String? month}) async {
    final res = await _api.get(
      '/ai/reports',
      query: month == null ? null : {'month': month},
    );
    return jsonList(res['items'], AiReport.fromJson);
  }

  /// SSE 的公共部分：`delta` → 文本，`error` → 异常，`done` → 收流。
  Stream<String> _stream(String path, Object body) async* {
    await for (final event in _api.sse(path, body)) {
      switch (event.event) {
        case 'delta':
          final text = jsonString(event.json['text']);
          if (text.isNotEmpty) yield text;
        case 'error':
          final message = jsonString(event.json['message']);
          throw ApiException(
            0,
            'ai_error',
            message.isEmpty ? 'AI 渠道出错了，去「设置 → AI 渠道」测一下。' : message,
          );
        case 'done':
          return;
      }
    }
  }
}

final aiRepoProvider = Provider<AiRepo>((ref) => AiRepo(ref.watch(apiProvider)));

/// 渠道列表；改完渠道用 `ref.invalidate(aiProvidersProvider)` 刷新。
final aiProvidersProvider = FutureProvider<List<AiProvider>>(
  (ref) => ref.watch(aiRepoProvider).providers(),
);

final aiPresetsProvider = FutureProvider<List<AiPreset>>(
  (ref) => ref.watch(aiRepoProvider).presets(),
);

/// 某月已生成的月报（新的在前）。
final aiReportsProvider = FutureProvider.family<List<AiReport>, String>(
  (ref, month) => ref.watch(aiRepoProvider).reports(month: month),
);

/// 默认渠道：服务端标了 `isDefault` 的那个，没有就第一个可用的。
AiProvider? defaultProviderOf(List<AiProvider> providers) {
  for (final p in providers) {
    if (p.isDefault && p.enabled) return p;
  }
  for (final p in providers) {
    if (p.enabled) return p;
  }
  return providers.isEmpty ? null : providers.first;
}
