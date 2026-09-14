/// 自动记账管线的轻量输入/输出类型。
///
/// 刻意不 import `lib/data/models`：Task 12 与数据层并行开发，这里只定义管线
/// 真正需要的字段，由后续任务把真实模型适配成这些类型。
library;

/// 本地时间的 ISO-8601，**带时区偏移**，秒级精度：`2026-09-05T01:00:00+08:00`。
///
/// 服务端 `POST /api/v1/transactions` 会拒收没有偏移的 `occurredAt`
/// （400 `invalid_occurredAt`），而 Dart 的 `toIso8601String()` 对本地时间
/// 不带偏移、对 UTC 只给 `Z`，所以这里自己拼。
String isoLocal(DateTime dt) {
  final local = dt.isUtc ? dt.toLocal() : dt;
  final offset = local.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final hh = offset.inHours.abs().toString().padLeft(2, '0');
  final mm = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');
  String two(int v) => v.toString().padLeft(2, '0');
  return '${local.year.toString().padLeft(4, '0')}-${two(local.month)}-'
      '${two(local.day)}T${two(local.hour)}:${two(local.minute)}:'
      '${two(local.second)}$sign$hh:$mm';
}

/// 用户规则（优先级高者先命中）。
class CaptureRule {
  const CaptureRule({
    required this.id,
    required this.priority,
    required this.field,
    required this.op,
    required this.pattern,
    this.categoryId,
    this.fundId,
    this.accountId,
    this.memberId,
    this.enabled = true,
  });

  final String id;
  final int priority;

  /// merchant|text|app
  final String field;

  /// contains|regex
  final String op;
  final String pattern;
  final String? categoryId;
  final String? fundId;
  final String? accountId;
  final String? memberId;
  final bool enabled;

  bool matches({
    required String merchant,
    required String text,
    required String app,
  }) {
    if (!enabled || pattern.isEmpty) return false;
    final subject = switch (field) {
      'merchant' => merchant,
      'app' => app,
      _ => text,
    };
    if (subject.isEmpty) return false;
    if (op == 'regex') {
      try {
        return RegExp(pattern).hasMatch(subject);
      } on FormatException {
        return false; // 用户写错的正则不应该让整条通知失败
      }
    }
    return subject.contains(pattern);
  }

  factory CaptureRule.fromJson(Map<String, dynamic> json) => CaptureRule(
        id: json['id'] as String,
        priority: (json['priority'] as num?)?.toInt() ?? 0,
        field: (json['field'] as String?) ?? 'text',
        op: (json['op'] as String?) ?? 'contains',
        pattern: (json['pattern'] as String?) ?? '',
        categoryId: json['categoryId'] as String?,
        fundId: json['fundId'] as String?,
        accountId: json['accountId'] as String?,
        memberId: json['memberId'] as String?,
        enabled: (json['enabled'] as bool?) ?? true,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'priority': priority,
        'field': field,
        'op': op,
        'pattern': pattern,
        if (categoryId != null) 'categoryId': categoryId,
        if (fundId != null) 'fundId': fundId,
        if (accountId != null) 'accountId': accountId,
        if (memberId != null) 'memberId': memberId,
        'enabled': enabled,
      };
}

/// 账户（只保留匹配所需字段）。
///
/// [matchHints] 约定：`cardTails: [String]`、`packages: [String]`、
/// `keywords: [String]`。
class CaptureAccount {
  const CaptureAccount({
    required this.id,
    required this.name,
    required this.kind,
    this.matchHints = const <String, dynamic>{},
  });

  final String id;
  final String name;
  final String kind;
  final Map<String, dynamic> matchHints;

  List<String> get cardTails => _hints('cardTails');
  List<String> get packages => _hints('packages');
  List<String> get keywords => _hints('keywords');

  List<String> _hints(String key) {
    final raw = matchHints[key];
    if (raw is List) {
      return raw.map((e) => '$e').where((e) => e.isNotEmpty).toList();
    }
    return const <String>[];
  }

  factory CaptureAccount.fromJson(Map<String, dynamic> json) => CaptureAccount(
        id: json['id'] as String,
        name: (json['name'] as String?) ?? '',
        kind: (json['kind'] as String?) ?? 'other',
        matchHints:
            (json['matchHints'] as Map?)?.cast<String, dynamic>() ??
                const <String, dynamic>{},
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'kind': kind,
        'matchHints': matchHints,
      };
}

/// 待提交的流水草稿 —— 即 `POST /api/v1/transactions` 的请求体。
class CaptureDraft {
  const CaptureDraft({
    required this.clientId,
    required this.type,
    required this.amountCents,
    required this.occurredAt,
    this.accountId,
    this.fundId,
    this.categoryId,
    required this.memberId,
    this.merchant = '',
    this.note = '',
    this.source = 'notification',
    required this.status,
    required this.confidence,
    required this.rawText,
    required this.sourceApp,
    required this.captureId,
  });

  /// 服务端幂等键（与 [captureId] 同值）。
  final String clientId;

  /// expense|income|transfer
  final String type;
  final int amountCents;
  final DateTime occurredAt;
  final String? accountId;
  final String? fundId;
  final String? categoryId;
  final String memberId;
  final String merchant;
  final String note;

  /// 固定 `notification`。
  final String source;

  /// confirmed|pending
  final String status;
  final double confidence;
  final String rawText;
  final String sourceApp;
  final String captureId;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'clientId': clientId,
        'type': type,
        'amountCents': amountCents,
        'occurredAt': isoLocal(occurredAt),
        if (accountId != null) 'accountId': accountId,
        if (fundId != null) 'fundId': fundId,
        if (categoryId != null) 'categoryId': categoryId,
        'memberId': memberId,
        'merchant': merchant,
        'note': note,
        'source': source,
        'status': status,
        'confidence': confidence,
        'rawText': rawText,
        'sourceApp': sourceApp,
        'captureId': captureId,
      };

  factory CaptureDraft.fromJson(Map<String, dynamic> json) => CaptureDraft(
        clientId: json['clientId'] as String,
        type: json['type'] as String,
        amountCents: (json['amountCents'] as num).toInt(),
        occurredAt: DateTime.parse(json['occurredAt'] as String).toLocal(),
        accountId: json['accountId'] as String?,
        fundId: json['fundId'] as String?,
        categoryId: json['categoryId'] as String?,
        memberId: (json['memberId'] as String?) ?? '',
        merchant: (json['merchant'] as String?) ?? '',
        note: (json['note'] as String?) ?? '',
        source: (json['source'] as String?) ?? 'notification',
        status: (json['status'] as String?) ?? 'pending',
        confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
        rawText: (json['rawText'] as String?) ?? '',
        sourceApp: (json['sourceApp'] as String?) ?? '',
        captureId: (json['captureId'] as String?) ?? '',
      );

  CaptureDraft copyWith({
    String? type,
    int? amountCents,
    DateTime? occurredAt,
    String? accountId,
    String? fundId,
    String? categoryId,
    String? memberId,
    String? merchant,
    String? note,
    String? status,
    double? confidence,
  }) =>
      CaptureDraft(
        clientId: clientId,
        type: type ?? this.type,
        amountCents: amountCents ?? this.amountCents,
        occurredAt: occurredAt ?? this.occurredAt,
        accountId: accountId ?? this.accountId,
        fundId: fundId ?? this.fundId,
        categoryId: categoryId ?? this.categoryId,
        memberId: memberId ?? this.memberId,
        merchant: merchant ?? this.merchant,
        note: note ?? this.note,
        source: source,
        status: status ?? this.status,
        confidence: confidence ?? this.confidence,
        rawText: rawText,
        sourceApp: sourceApp,
        captureId: captureId,
      );
}
