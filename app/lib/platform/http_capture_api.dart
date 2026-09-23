import '../capture/pipeline.dart';
import '../data/api/api_client.dart';

/// 请求根本没到（或没等到）服务端。管线把它当作「离线」：本地先留着，稍后重试。
class CaptureNetworkException implements Exception {
  const CaptureNetworkException(this.message, {this.maybeSent = false});

  final String message;

  /// 请求可能已经送到服务端（超时之类），重发靠 clientId 幂等兜底。
  final bool maybeSent;

  @override
  String toString() => 'CaptureNetworkException($message)';
}

/// [CaptureApi] 的真实现：走 [ApiClient]（同一个 baseUrl + Bearer 令牌）。
///
/// * `ApiException` 的网络错误 → [CaptureNetworkException]；
/// * 其余（服务端明确回了状态码）→ [CaptureApiException]，管线按 4xx / 5xx 分流。
class HttpCaptureApi implements CaptureApi {
  HttpCaptureApi(this.api, {this.aiEnabled = false, this.providerId});

  final ApiClient api;

  /// 家庭设置里的「AI 兜底」不是关闭状态；关着时 [aiClassify] 直接返回
  /// null，不打网络。
  final bool aiEnabled;

  /// 记账兜底专用渠道；null = 跟聊天/月报一样用服务端默认渠道。
  final String? providerId;

  @override
  Future<CaptureApiResult> createTransaction(Map<String, dynamic> body) async {
    final res = await _guard(() => api.post('/transactions', body));
    final tx = res['transaction'];
    return CaptureApiResult(
      id: tx is Map ? tx['id']?.toString() : res['id']?.toString(),
      duplicate: res['duplicate'] == true,
    );
  }

  @override
  Future<void> patchTransaction(String id, Map<String, dynamic> patch) =>
      _guard(() => api.patch('/transactions/$id', patch));

  @override
  Future<void> confirmTransaction(String id) =>
      _guard(() => api.post('/transactions/$id/confirm', null));

  @override
  Future<void> deleteTransaction(String id) => _guard(() => api.delete('/transactions/$id'));

  @override
  Future<void> learn(List<LearnSample> samples) =>
      learnJson(samples.where((s) => !s.isEmpty).map((s) => s.toJson()).toList());

  /// 已经是 `LearnSample.toJson()` 形状的样本（离线队列重放用）。空列表不发请求。
  Future<void> learnJson(List<Map<String, dynamic>> samples) {
    if (samples.isEmpty) return Future.value();
    return _guard(() => api.post('/model/learn', {'samples': samples}));
  }

  /// 管线给的是扁平的 `{text, merchant, amountCents, direction, channel, categories, funds}`，
  /// 服务端 `POST /ai/classify` 要的是 `{text, merchant, amountCents, candidates:{categories, funds}}`。
  @override
  Future<Map<String, dynamic>?> aiClassify(Map<String, dynamic> input) async {
    if (!aiEnabled) return null;
    final text = '${input['text'] ?? ''}';
    if (text.trim().isEmpty) return null;
    final res = await _guard(
      () => api.post('/ai/classify', {
        'text': text,
        if (input['merchant'] != null && '${input['merchant']}'.isNotEmpty) 'merchant': input['merchant'],
        if (input['amountCents'] != null) 'amountCents': input['amountCents'],
        if (providerId != null && providerId!.isNotEmpty) 'providerId': providerId,
        'candidates': {
          'categories': input['categories'] ?? const <Object>[],
          'funds': input['funds'] ?? const <Object>[],
        },
      }),
    );
    return {
      'categoryId': res['categoryId'],
      'fundId': res['fundId'],
      'confidence': (res['confidence'] as num?)?.toDouble() ?? 0.0,
    };
  }

  /// `GET /model` → `{version, category:{…}, fund:{…}}`。
  Future<Map<String, dynamic>> fetchModel() => _guard(() => api.get('/model'));

  Future<T> _guard<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on ApiException catch (e) {
      if (e.isNetwork) throw CaptureNetworkException(e.message, maybeSent: e.maybeSent);
      throw CaptureApiException(e.status, e.code, e.message);
    }
  }
}
