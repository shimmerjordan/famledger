import 'json_utils.dart';

/// 物品资产：买来一件东西，一直用到退役或卖掉。
///
/// 服务端只存事实；天数、日均这些派生数在 `asset_math.dart` 里算。
class Asset {
  const Asset({
    required this.id,
    required this.name,
    this.category = 'other',
    this.icon,
    required this.priceCents,
    required this.purchasedOn,
    this.status = statusInUse,
    this.endedOn,
    this.saleCents,
    this.expectedDays,
    this.note,
    this.memberId,
    this.transactionId,
    this.saleTransactionId,
    this.sortOrder = 0,
    this.archived = false,
  });

  static const List<String> categories = [
    'digital',
    'appliance',
    'furniture',
    'clothing',
    'vehicle',
    'sports',
    'other',
  ];

  static const Map<String, String> categoryLabels = {
    'digital': '数码',
    'appliance': '家电',
    'furniture': '家具',
    'clothing': '衣物',
    'vehicle': '出行',
    'sports': '运动',
    'other': '其他',
  };

  static const String statusInUse = 'in_use';
  static const String statusIdle = 'idle';
  static const String statusRetired = 'retired';
  static const String statusSold = 'sold';

  static const Map<String, String> statusLabels = {
    statusInUse: '在用',
    statusIdle: '闲置',
    statusRetired: '已退役',
    statusSold: '已卖出',
  };

  final String id;
  final String name;
  final String category;
  final String? icon;
  final int priceCents;

  /// `YYYY-MM-DD`
  final String purchasedOn;

  /// in_use | idle | retired | sold
  final String status;

  /// `YYYY-MM-DD`，只有退役/卖出才有。
  final String? endedOn;
  final int? saleCents;
  final int? expectedDays;
  final String? note;
  final String? memberId;
  final String? transactionId;
  final String? saleTransactionId;
  final int sortOrder;
  final bool archived;

  bool get isEnded => status == statusRetired || status == statusSold;

  /// 在用或闲置：还在家里，每天都在「花钱」。
  bool get isHeld => !isEnded;

  String get categoryLabel => categoryLabels[category] ?? '其他';
  String get statusLabel => statusLabels[status] ?? status;

  factory Asset.fromJson(Map<String, dynamic> json) => Asset(
    id: jsonString(json['id']),
    name: jsonString(json['name']),
    category: jsonString(json['category'], 'other'),
    icon: jsonStringOrNull(json['icon']),
    priceCents: jsonInt(json['priceCents']),
    purchasedOn: jsonString(json['purchasedOn']),
    status: jsonString(json['status'], statusInUse),
    endedOn: jsonStringOrNull(json['endedOn']),
    saleCents: jsonIntOrNull(json['saleCents']),
    expectedDays: jsonIntOrNull(json['expectedDays']),
    note: jsonStringOrNull(json['note']),
    memberId: jsonStringOrNull(json['memberId']),
    transactionId: jsonStringOrNull(json['transactionId']),
    saleTransactionId: jsonStringOrNull(json['saleTransactionId']),
    sortOrder: jsonInt(json['sortOrder']),
    archived: jsonBool(json['archived']),
  );

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'id': id,
      'name': name,
      'category': category,
      'priceCents': priceCents,
      'purchasedOn': purchasedOn,
      'status': status,
    };
    putIfNotNull(json, 'icon', icon);
    putIfNotNull(json, 'endedOn', endedOn);
    putIfNotNull(json, 'saleCents', saleCents);
    putIfNotNull(json, 'expectedDays', expectedDays);
    putIfNotNull(json, 'note', note);
    putIfNotNull(json, 'memberId', memberId);
    putIfNotNull(json, 'transactionId', transactionId);
    putIfNotNull(json, 'saleTransactionId', saleTransactionId);
    json['sortOrder'] = sortOrder;
    json['archived'] = archived;
    return json;
  }
}
