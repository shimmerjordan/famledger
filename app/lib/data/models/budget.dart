import 'json_utils.dart';

/// 预算：按基金或类别，按月（`'*'` = 每月默认）。
class Budget {
  const Budget({
    this.id,
    required this.scope,
    required this.refId,
    required this.month,
    required this.amountCents,
  });

  static const String scopeFund = 'fund';
  static const String scopeCategory = 'category';

  /// 「每月默认」的月份占位。
  static const String everyMonth = '*';

  final String? id;

  /// fund | category
  final String scope;
  final String refId;

  /// `YYYY-MM` 或 `'*'`
  final String month;
  final int amountCents;

  bool get isDefaultMonth => month == everyMonth;

  factory Budget.fromJson(Map<String, dynamic> json) => Budget(
    id: jsonStringOrNull(json['id']),
    scope: jsonString(json['scope'], scopeFund),
    refId: jsonString(json['refId']),
    month: jsonString(json['month'], everyMonth),
    amountCents: jsonInt(json['amountCents']),
  );

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
    putIfNotNull(json, 'id', id);
    json['scope'] = scope;
    json['refId'] = refId;
    json['month'] = month;
    json['amountCents'] = amountCents;
    return json;
  }
}
