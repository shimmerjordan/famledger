import 'json_utils.dart';

/// 自动识别规则：命中就把类别/基金/账户/成员填上。
class Rule {
  const Rule({
    required this.id,
    this.priority = 0,
    this.field = 'merchant',
    this.op = 'contains',
    required this.pattern,
    this.categoryId,
    this.fundId,
    this.accountId,
    this.memberId,
    this.enabled = true,
  });

  static const List<String> fields = ['merchant', 'text', 'app'];
  static const List<String> ops = ['contains', 'regex'];

  static const Map<String, String> fieldLabels = {
    'merchant': '商户',
    'text': '原文',
    'app': '来源应用',
  };

  static const Map<String, String> opLabels = {
    'contains': '包含',
    'regex': '正则',
  };

  final String id;
  final int priority;

  /// merchant | text | app
  final String field;

  /// contains | regex
  final String op;
  final String pattern;
  final String? categoryId;
  final String? fundId;
  final String? accountId;
  final String? memberId;
  final bool enabled;

  String get fieldLabel => fieldLabels[field] ?? field;
  String get opLabel => opLabels[op] ?? op;

  factory Rule.fromJson(Map<String, dynamic> json) => Rule(
    id: jsonString(json['id']),
    priority: jsonInt(json['priority']),
    field: jsonString(json['field'], 'merchant'),
    op: jsonString(json['op'], 'contains'),
    pattern: jsonString(json['pattern']),
    categoryId: jsonStringOrNull(json['categoryId']),
    fundId: jsonStringOrNull(json['fundId']),
    accountId: jsonStringOrNull(json['accountId']),
    memberId: jsonStringOrNull(json['memberId']),
    enabled: jsonBool(json['enabled'], true),
  );

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'id': id,
      'priority': priority,
      'field': field,
      'op': op,
      'pattern': pattern,
    };
    putIfNotNull(json, 'categoryId', categoryId);
    putIfNotNull(json, 'fundId', fundId);
    putIfNotNull(json, 'accountId', accountId);
    putIfNotNull(json, 'memberId', memberId);
    json['enabled'] = enabled;
    return json;
  }
}
