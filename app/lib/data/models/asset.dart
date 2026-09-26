import 'json_utils.dart';

/// 物品资产：买来一件东西，一直用到退役或卖掉。
///
/// 服务端只存事实和用户的选择；天数、日均在 `asset_math.dart` 里算，估值在 `asset_valuation.dart` 里算。
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
    this.valuationMethod = methodAuto,
    this.rateBp,
    this.residualBp,
    this.manualValueCents,
    this.manualValueOn,
    this.netWorth = netWorthAuto,
    this.origin = const {},
  });

  /// 顺序同服务端 `lib/valuation.js` 的 CATEGORY_DEFAULTS，也是表单里类别 chip 的顺序。
  /// 加类别四处一起改：服务端估值表、这里、`asset_widgets.dart` 的图标、`asset_valuation.dart` 的默认表。
  static const List<String> categories = [
    'digital',
    'appliance',
    'furniture',
    'clothing',
    'vehicle',
    'luxury',
    'jewelry',
    'sports',
    'other',
  ];

  static const Map<String, String> categoryLabels = {
    'digital': '数码',
    'appliance': '家电',
    'furniture': '家具',
    'clothing': '衣物',
    'vehicle': '出行',
    'luxury': '箱包/奢侈品',
    'jewelry': '首饰/贵金属',
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

  // 估值方式（spec §2）：auto 跟随类别；straight 直线法；declining 每年打折；locked 不折旧。
  static const String methodAuto = 'auto';
  static const String methodStraight = 'straight';
  static const String methodDeclining = 'declining';
  static const String methodLocked = 'locked';
  static const List<String> valuationMethods = [
    methodAuto,
    methodStraight,
    methodDeclining,
    methodLocked,
  ];

  // 计入净资产三态：auto 跟随类别默认，include / exclude 单件说了算。用文本不用可空 bool：
  // 服务端 rowToJson 会把 null 变成 false。
  static const String netWorthAuto = 'auto';
  static const String netWorthInclude = 'include';
  static const String netWorthExclude = 'exclude';
  static const List<String> netWorthModes = [
    netWorthAuto,
    netWorthInclude,
    netWorthExclude,
  ];

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

  /// auto | straight | declining | locked
  final String valuationMethod;

  /// 年折率（基点，0–9000）；null = 类别默认。
  final int? rateBp;

  /// 残值 / 保底比例（基点，0–10000）；null = 类别默认。
  final int? residualBp;

  /// 手动估值锚点：金额和日期（`YYYY-MM-DD`）要么都有要么都没有，服务端守着。
  final int? manualValueCents;
  final String? manualValueOn;

  /// auto | include | exclude
  final String netWorth;

  /// `{src, importId, ev, unverified}`（AI 导入写；手工记的是空）。
  final Map<String, dynamic> origin;

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
    valuationMethod: _oneOf(json['valuationMethod'], valuationMethods, methodAuto),
    rateBp: jsonIntOrNull(json['rateBp']),
    residualBp: jsonIntOrNull(json['residualBp']),
    manualValueCents: jsonIntOrNull(json['manualValueCents']),
    manualValueOn: jsonStringOrNull(json['manualValueOn']),
    netWorth: _oneOf(json['netWorth'], netWorthModes, netWorthAuto),
    // 007 之前写下的行、老缓存没有这个键（ALTER 不动 seq，不会重拉）：按空兜底。
    origin: jsonMap(json['origin']),
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
    json['valuationMethod'] = valuationMethod;
    putIfNotNull(json, 'rateBp', rateBp);
    putIfNotNull(json, 'residualBp', residualBp);
    putIfNotNull(json, 'manualValueCents', manualValueCents);
    putIfNotNull(json, 'manualValueOn', manualValueOn);
    json['netWorth'] = netWorth;
    if (origin.isNotEmpty) json['origin'] = origin;
    return json;
  }

  /// 缺字段（005 之前写下的行、老缓存 —— ALTER 不动 seq，不会重拉）或不认识的值（以后的版本写的）一律兜底。
  static String _oneOf(Object? raw, List<String> allowed, String fallback) {
    final value = jsonString(raw, fallback);
    return allowed.contains(value) ? value : fallback;
  }
}
