import 'json_utils.dart';

/// 板块（「我的 › 财富」里的一项；代码里叫 Fund）：钱「归谁、干什么用」。余额 = Σ流水，按币种分开算。
/// 可以挂「每月固定进账」：每月 [incomeDay] 号往 [incomeAccountId] 记一笔真的收入（服务端 fund_income.js 生成）。
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
    this.monthlyIncomeCents,
    this.incomeDay,
    this.incomeAccountId,
    this.incomeCategoryId,
    this.incomeStartMonth,
    this.description,
    this.sortOrder = 0,
    this.archived = false,
    this.isDefault = false,
  });

  /// personal | shared | goal | reserve | custom —— 只影响展示与模板。
  static const List<String> kinds = ['personal', 'shared', 'goal', 'reserve', 'custom'];

  /// 攒专款的两类：里面的钱不算「可支配现金流」（net_worth_strip.dart 的 reservedCents）。
  static const Set<String> savingKinds = {'goal', 'reserve'};

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

  /// 「每月固定进账」金额（分，按进账账户的币种）；空或 0 = 不自动进账。
  final int? monthlyIncomeCents;

  /// 每月几号到账（1–28）。
  final int? incomeDay;

  /// 进哪个账户（开着进账时必有）。
  final String? incomeAccountId;

  /// 记成什么收入类别；空 = 服务端用「工资」。
  final String? incomeCategoryId;

  /// 从哪个月起 `YYYY-MM`（含）。
  final String? incomeStartMonth;

  /// 开着每月固定进账。
  bool get hasMonthlyIncome => (monthlyIncomeCents ?? 0) > 0 && incomeAccountId != null;
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
    monthlyIncomeCents: jsonIntOrNull(json['monthlyIncomeCents']),
    incomeDay: jsonIntOrNull(json['incomeDay']),
    incomeAccountId: jsonStringOrNull(json['incomeAccountId']),
    incomeCategoryId: jsonStringOrNull(json['incomeCategoryId']),
    incomeStartMonth: jsonStringOrNull(json['incomeStartMonth']),
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
    putIfNotNull(json, 'monthlyIncomeCents', monthlyIncomeCents);
    putIfNotNull(json, 'incomeDay', incomeDay);
    putIfNotNull(json, 'incomeAccountId', incomeAccountId);
    putIfNotNull(json, 'incomeCategoryId', incomeCategoryId);
    putIfNotNull(json, 'incomeStartMonth', incomeStartMonth);
    putIfNotNull(json, 'description', description);
    json['sortOrder'] = sortOrder;
    json['archived'] = archived;
    json['isDefault'] = isDefault;
    return json;
  }
}
