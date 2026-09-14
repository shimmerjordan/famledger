import 'json_utils.dart';

/// 类别：钱「花在什么事上」。
class Category {
  const Category({
    required this.id,
    required this.name,
    this.kind = 'expense',
    this.parentId,
    this.icon,
    this.color,
    this.sortOrder = 0,
    this.archived = false,
  });

  final String id;
  final String name;

  /// expense | income
  final String kind;
  final String? parentId;
  final String? icon;
  final String? color;
  final int sortOrder;
  final bool archived;

  bool get isIncome => kind == 'income';

  factory Category.fromJson(Map<String, dynamic> json) => Category(
    id: jsonString(json['id']),
    name: jsonString(json['name']),
    kind: jsonString(json['kind'], 'expense'),
    parentId: jsonStringOrNull(json['parentId']),
    icon: jsonStringOrNull(json['icon']),
    color: jsonStringOrNull(json['color']),
    sortOrder: jsonInt(json['sortOrder']),
    archived: jsonBool(json['archived']),
  );

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{'id': id, 'name': name, 'kind': kind};
    putIfNotNull(json, 'parentId', parentId);
    putIfNotNull(json, 'icon', icon);
    putIfNotNull(json, 'color', color);
    json['sortOrder'] = sortOrder;
    json['archived'] = archived;
    return json;
  }
}
