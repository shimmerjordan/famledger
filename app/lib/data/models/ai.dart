import 'json_utils.dart';

/// AI 渠道。密钥只写不读，服务端只回 `hasKey` 与尾号。
class AiProvider {
  const AiProvider({
    required this.id,
    required this.name,
    this.kind = 'openai',
    this.baseUrl = '',
    this.model = '',
    this.isDefault = false,
    this.enabled = true,
    this.hasKey = false,
    this.keyTail,
    this.extra = const {},
  });

  /// anthropic | openai
  static const List<String> kinds = ['anthropic', 'openai'];

  final String id;
  final String name;
  final String kind;
  final String baseUrl;
  final String model;
  final bool isDefault;
  final bool enabled;
  final bool hasKey;
  final String? keyTail;
  final Map<String, dynamic> extra;

  bool get isReady => enabled && hasKey && model.isNotEmpty;

  AiProvider copyWith({bool? enabled, bool? isDefault}) => AiProvider(
    id: id,
    name: name,
    kind: kind,
    baseUrl: baseUrl,
    model: model,
    isDefault: isDefault ?? this.isDefault,
    enabled: enabled ?? this.enabled,
    hasKey: hasKey,
    keyTail: keyTail,
    extra: extra,
  );

  factory AiProvider.fromJson(Map<String, dynamic> json) => AiProvider(
    id: jsonString(json['id']),
    name: jsonString(json['name']),
    kind: jsonString(json['kind'], 'openai'),
    baseUrl: jsonString(json['baseUrl']),
    model: jsonString(json['model']),
    isDefault: jsonBool(json['isDefault']),
    enabled: jsonBool(json['enabled'], true),
    hasKey: jsonBool(json['hasKey']),
    keyTail: jsonStringOrNull(json['keyTail']),
    extra: jsonMap(json['extra']),
  );

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'id': id,
      'name': name,
      'kind': kind,
      'baseUrl': baseUrl,
      'model': model,
      'isDefault': isDefault,
      'enabled': enabled,
      'hasKey': hasKey,
    };
    putIfNotNull(json, 'keyTail', keyTail);
    json['extra'] = extra;
    return json;
  }
}

/// 已生成的 AI 月报。
class AiReport {
  const AiReport({
    required this.id,
    required this.month,
    required this.content,
    this.providerId,
    this.createdAt,
  });

  final String id;
  final String month;
  final String content;
  final String? providerId;
  final DateTime? createdAt;

  factory AiReport.fromJson(Map<String, dynamic> json) => AiReport(
    id: jsonString(json['id']),
    month: jsonString(json['month']),
    content: jsonString(json['content']),
    providerId: jsonStringOrNull(json['providerId']),
    createdAt: jsonDateOrNull(json['createdAt']),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'month': month,
    'content': content,
    'providerId': providerId,
    'createdAt': createdAt?.toIso8601String(),
  };
}

/// 渠道预设（`GET /ai/presets`）：选中后自动填 baseUrl / model。
class AiPreset {
  const AiPreset({
    required this.key,
    required this.name,
    this.kind = 'openai',
    this.baseUrl = '',
    this.model = '',
    this.hint = '',
  });

  final String key;
  final String name;
  final String kind;
  final String baseUrl;
  final String model;

  /// 一句中文说明：去哪儿拿密钥、地址怎么填。
  final String hint;

  factory AiPreset.fromJson(Map<String, dynamic> json) => AiPreset(
    key: jsonString(json['key']),
    name: jsonString(json['name']),
    kind: jsonString(json['kind'], 'openai'),
    baseUrl: jsonString(json['baseUrl']),
    model: jsonString(json['model']),
    hint: jsonString(json['hint']),
  );

  Map<String, dynamic> toJson() => {
    'key': key,
    'name': name,
    'kind': kind,
    'baseUrl': baseUrl,
    'model': model,
    'hint': hint,
  };
}

/// `POST /ai/providers/:id/test` 的结果：通了给延迟与样例，不通给原因。
class AiProviderTest {
  const AiProviderTest({
    required this.ok,
    this.model = '',
    this.latencyMs = 0,
    this.sample = '',
    this.message = '',
  });

  final bool ok;
  final String model;
  final int latencyMs;

  /// 模型回的一小段话，用来确认「真的通了」。
  final String sample;

  /// 失败原因（ok 为 true 时一般为空）。
  final String message;

  factory AiProviderTest.fromJson(Map<String, dynamic> json) => AiProviderTest(
    ok: jsonBool(json['ok']),
    model: jsonString(json['model']),
    latencyMs: jsonInt(json['latencyMs']),
    sample: jsonString(json['sample']),
    message: jsonString(json['message']),
  );
}

/// 对话里的一条消息。`role` 只有 user / assistant 两种。
class AiChatMessage {
  const AiChatMessage(this.role, this.content, {this.error = false});

  const AiChatMessage.user(String content) : this('user', content);
  const AiChatMessage.assistant(String content) : this('assistant', content);

  final String role;
  final String content;

  /// 这条是「这次请求失败了」的占位，不发给服务端。
  final bool error;

  bool get isUser => role == 'user';

  AiChatMessage copyWith({String? content, bool? error}) =>
      AiChatMessage(role, content ?? this.content, error: error ?? this.error);

  Map<String, dynamic> toJson() => {'role': role, 'content': content};
}
