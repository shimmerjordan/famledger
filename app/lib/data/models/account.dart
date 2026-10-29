import 'json_utils.dart';

/// 股票账户某一天的市值（服务端 `accounts.value_log` 的一条）。
class AccountValue {
  const AccountValue({required this.on, required this.valueCents});

  /// `YYYY-MM-DD`
  final String on;
  final int valueCents;

  factory AccountValue.fromJson(Map<String, dynamic> json) =>
      AccountValue(on: jsonString(json['on']), valueCents: jsonInt(json['valueCents']));

  Map<String, dynamic> toJson() => {'on': on, 'valueCents': valueCents};
}

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
    this.valueCents,
    this.valueOn,
    this.valueLog = const [],
  });

  /// 债务背后的内部账户（server/src/modules/debts.js）：余额 = 还剩多少，借出为正、借入为负。
  /// 不在 [kinds] 里：账户页、记账时选账户都看不到它，只在「资产 › 债务」里管。
  static const String kindDebt = 'debt';

  /// 股票账户：不挂持仓，整户记一个「当前市值」；余额 = 转进去的本金（投入），浮盈 = 市值 − 投入。
  static const String kindStock = 'stock';

  /// cash | bank | alipay | wechat | credit | invest | stock | other
  static const List<String> kinds = [
    'cash',
    'bank',
    'alipay',
    'wechat',
    'credit',
    'invest',
    kindStock,
    'other',
  ];

  static const Map<String, String> kindLabels = {
    'cash': '现金',
    'bank': '银行卡',
    'alipay': '支付宝',
    'wechat': '微信',
    'credit': '信用卡',
    'invest': '投资',
    kindStock: '股票账户',
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

  /// 股票账户的当前市值（照券商 App 填）；null = 还没填过，按投入算。别的类型恒为 null。
  final int? valueCents;

  /// [valueCents] 是哪天的数，`YYYY-MM-DD`。
  final String? valueOn;

  /// 历次市值，老的在前（同一天只留一条，最多 200 条）。
  final List<AccountValue> valueLog;

  String get kindLabel => kindLabels[kind] ?? '其他';

  /// 信用卡余额为负债，展示时要反过来说。
  bool get isLiability => kind == 'credit';

  bool get isDebt => kind == kindDebt;

  bool get isStock => kind == kindStock;

  /// 投资账户或股票账户：余额不算现金流，在总览里归到「投资」。
  bool get isInvestLike => kind == 'invest' || isStock;

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
    valueCents: jsonIntOrNull(json['valueCents']),
    valueOn: jsonStringOrNull(json['valueOn']),
    valueLog: jsonList(json['valueLog'], AccountValue.fromJson),
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
    // 本地缓存要存市值：离线打开理财页也得画得出股票账户那一段。
    putIfNotNull(json, 'valueCents', valueCents);
    putIfNotNull(json, 'valueOn', valueOn);
    if (valueLog.isNotEmpty) json['valueLog'] = valueLog.map((e) => e.toJson()).toList();
    return json;
  }
}
