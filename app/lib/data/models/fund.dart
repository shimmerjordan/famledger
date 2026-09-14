import 'json_utils.dart';

/// 基金/模块：钱「归谁、干什么用」。余额 = Σ流水。
class Fund {
  const Fund({
    required this.id,
    required this.name,
    this.kind = 'custom',
    this.ownerMemberId,
    this.icon,
    this.color,
    this.targetCents,
    this.monthlyBudgetCents,
    this.description,
    this.sortOrder = 0,
    this.archived = false,
    this.isDefault = false,
  });

  /// personal | shared | goal | reserve | custom —— 只影响展示与模板。
  static const List<String> kinds = ['personal', 'shared', 'goal', 'reserve', 'custom'];

  static const Map<String, String> kindLabels = {
    'personal': '个人',
    'shared': '共同',
    'goal': '目标',
    'reserve': '储备',
    'custom': '自定义',
  };

  final String id;
  final String name;
  final String kind;
  final String? ownerMemberId;
  final String? icon;
  final String? color;
  final int? targetCents;
  final int? monthlyBudgetCents;
  final String? description;
  final int sortOrder;
  final bool archived;
  final bool isDefault;

  String get kindLabel => kindLabels[kind] ?? '自定义';

  factory Fund.fromJson(Map<String, dynamic> json) => Fund(
    id: jsonString(json['id']),
    name: jsonString(json['name']),
    kind: jsonString(json['kind'], 'custom'),
    ownerMemberId: jsonStringOrNull(json['ownerMemberId']),
    icon: jsonStringOrNull(json['icon']),
    color: jsonStringOrNull(json['color']),
    targetCents: jsonIntOrNull(json['targetCents']),
    monthlyBudgetCents: jsonIntOrNull(json['monthlyBudgetCents']),
    description: jsonStringOrNull(json['description']),
    sortOrder: jsonInt(json['sortOrder']),
    archived: jsonBool(json['archived']),
    isDefault: jsonBool(json['isDefault']),
  );

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{'id': id, 'name': name, 'kind': kind};
    putIfNotNull(json, 'ownerMemberId', ownerMemberId);
    putIfNotNull(json, 'icon', icon);
    putIfNotNull(json, 'color', color);
    putIfNotNull(json, 'targetCents', targetCents);
    putIfNotNull(json, 'monthlyBudgetCents', monthlyBudgetCents);
    putIfNotNull(json, 'description', description);
    json['sortOrder'] = sortOrder;
    json['archived'] = archived;
    json['isDefault'] = isDefault;
    return json;
  }
}
