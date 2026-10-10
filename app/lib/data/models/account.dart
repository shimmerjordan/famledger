import 'json_utils.dart';

/// 账户：钱「在哪」。余额 = initialBalanceCents + Σ流水。
class Account {
  const Account({
    required this.id,
    required this.name,
    required this.kind,
    this.ownerMemberId,
    this.initialBalanceCents = 0,
    this.currency = 'CNY',
    this.icon,
    this.color,
    this.sortOrder = 0,
    this.archived = false,
    this.matchHints = const {},
  });

  /// 债务背后的内部账户（server/src/modules/debts.js）：余额 = 还剩多少，借出为正、借入为负。
  /// 不在 [kinds] 里：账户页、记账时选账户都看不到它，只在「资产 › 债务」里管。
  static const String kindDebt = 'debt';

  /// cash | bank | alipay | wechat | credit | invest | other
  static const List<String> kinds = [
    'cash',
    'bank',
    'alipay',
    'wechat',
    'credit',
    'invest',
    'other',
  ];

  static const Map<String, String> kindLabels = {
    'cash': '现金',
    'bank': '银行卡',
    'alipay': '支付宝',
    'wechat': '微信',
    'credit': '信用卡',
    'invest': '投资',
    'other': '其他',
    kindDebt: '债务',
  };

  final String id;
  final String name;
  final String kind;
  final String? ownerMemberId;
  final int initialBalanceCents;
  final String currency;
  final String? icon;
  final String? color;
  final int sortOrder;
  final bool archived;

  /// 自动识别用：卡尾号 / 包名 / 关键字。
  final Map<String, dynamic> matchHints;

  String get kindLabel => kindLabels[kind] ?? '其他';

  /// 信用卡余额为负债，展示时要反过来说。
  bool get isLiability => kind == 'credit';

  bool get isDebt => kind == kindDebt;

  factory Account.fromJson(Map<String, dynamic> json) => Account(
    id: jsonString(json['id']),
    name: jsonString(json['name']),
    kind: jsonString(json['kind'], 'other'),
    ownerMemberId: jsonStringOrNull(json['ownerMemberId']),
    initialBalanceCents: jsonInt(json['initialBalanceCents']),
    currency: jsonString(json['currency'], 'CNY'),
    icon: jsonStringOrNull(json['icon']),
    color: jsonStringOrNull(json['color']),
    sortOrder: jsonInt(json['sortOrder']),
    archived: jsonBool(json['archived']),
    matchHints: jsonMap(json['matchHints']),
  );

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{'id': id, 'name': name, 'kind': kind};
    putIfNotNull(json, 'ownerMemberId', ownerMemberId);
    json['initialBalanceCents'] = initialBalanceCents;
    json['currency'] = currency;
    putIfNotNull(json, 'icon', icon);
    putIfNotNull(json, 'color', color);
    json['sortOrder'] = sortOrder;
    json['archived'] = archived;
    if (matchHints.isNotEmpty) json['matchHints'] = matchHints;
    return json;
  }
}
