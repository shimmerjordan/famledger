import 'json_utils.dart';

/// 理财的三种记法（server/src/lib/invest.js 的 mode）。
enum InvestMode {
  /// 份额 × 价格：基金、股票、黄金。
  unit,

  /// 本金 + 年化 + 到期日，按天计息：定期、结构性存款、国债、逆回购。
  deposit,

  /// 手动更新的当前金额：活期、银行理财、保险存单、其他。
  balance,
}

/// 一笔理财（服务端表名 holdings）。份额与价格都是 ×10000 的整数（基金份额常见 2 位小数、净值 4 位）。
///
/// [kind] 决定怎么记（[InvestMode]）；非份额类的 [quantityE4] 恒为 1 份，只当「还持有着」的标记，清仓置 0。
/// 份额与成本只能经存取 / 加减仓接口改；估值、收益这些派生数在 `asset_math.dart` 里算。
class Holding {
  const Holding({
    required this.id,
    this.name = '',
    this.kind = kindStock,
    this.code,
    this.market = 'other',
    this.quantityE4 = 0,
    this.costCents = 0,
    this.priceE4,
    this.prevCloseE4,
    this.priceSource = sourceManual,
    this.priceAt,
    required this.openedOn,
    this.accountId,
    this.realizedCents = 0,
    this.institution,
    this.rateE6,
    this.rateMaxE6,
    this.maturesOn,
    this.valueCents,
    this.valueOn,
    this.note,
    this.sortOrder = 0,
    this.archived = false,
  });

  static const String kindFund = 'fund';
  static const String kindStock = 'stock';
  static const String kindDemand = 'demand';
  static const String kindFixed = 'fixed';
  static const String kindStructured = 'structured';
  static const String kindWealth = 'wealth';
  static const String kindBond = 'bond';
  static const String kindRepo = 'repo';
  static const String kindInsurance = 'insurance';
  static const String kindGold = 'gold';
  static const String kindOther = 'other';

  /// 理财页分组、表单里 chip 的顺序：基金打头（用户说它是理财的一大类），然后从活到死、从稳到险。
  static const List<String> kinds = [
    kindFund,
    kindStock,
    kindDemand,
    kindFixed,
    kindStructured,
    kindWealth,
    kindBond,
    kindRepo,
    kindInsurance,
    kindGold,
    kindOther,
  ];

  static const Map<String, String> kindLabels = {
    kindFund: '基金',
    kindStock: '股票',
    kindDemand: '活期存款',
    kindFixed: '定期存款',
    kindStructured: '结构性存款',
    kindWealth: '银行理财',
    kindBond: '国债',
    kindRepo: '国债逆回购',
    kindInsurance: '保险存单',
    kindGold: '黄金',
    kindOther: '其他',
  };

  /// 选品类时的一句说明：哪些东西算这一类、按什么记。
  static const Map<String, String> kindHints = {
    kindFund: '公募基金、ETF 联接：份额 × 净值，能自动拉净值',
    kindStock: 'A 股、场内 ETF：股数 × 现价，能自动拉行情',
    kindDemand: '余额宝、零钱通、活期理财：记当前金额；银行卡里的钱记在账户里',
    kindFixed: '定期、大额存单：本金 + 年利率 + 到期日，按天算利息',
    kindStructured: '本金 + 保底 / 最高年化 + 到期日，按保底算利息',
    kindWealth: '银行理财产品：记当前金额，看着 App 更新',
    kindBond: '储蓄国债、债券：本金 + 票面利率 + 到期日',
    kindRepo: '本金 + 年化 + 天数，到期自动回来',
    kindInsurance: '储蓄险、年金、增额寿：已交保费 + 现金价值',
    kindGold: '积存金、实物金：克数 × 金价',
    kindOther: '记当前金额',
  };

  static const Map<String, InvestMode> kindModes = {
    kindFund: InvestMode.unit,
    kindStock: InvestMode.unit,
    kindGold: InvestMode.unit,
    kindFixed: InvestMode.deposit,
    kindStructured: InvestMode.deposit,
    kindBond: InvestMode.deposit,
    kindRepo: InvestMode.deposit,
    kindDemand: InvestMode.balance,
    kindWealth: InvestMode.balance,
    kindInsurance: InvestMode.balance,
    kindOther: InvestMode.balance,
  };

  static InvestMode modeOf(String kind) => kindModes[kind] ?? InvestMode.balance;

  /// 非份额类的「持有中」标记：1 份。
  static const int heldE4 = 10000;

  static const List<String> markets = ['fund', 'sh', 'sz', 'bj', 'other'];

  static const Map<String, String> marketLabels = {
    'fund': '场外基金',
    'sh': '沪市',
    'sz': '深市',
    'bj': '北交所',
    'other': '其他',
  };

  /// 这几个市场有行情源，能开自动行情。
  static const Set<String> autoMarkets = {'fund', 'sh', 'sz', 'bj'};

  static const String sourceAuto = 'auto';
  static const String sourceManual = 'manual';

  final String id;
  final String name;

  /// [kinds] 之一。老数据没有这个字段时按市场推：场外基金 → 基金，其余 → 股票（同服务端迁移 009）。
  final String kind;
  final String? code;

  /// fund | sh | sz | bj | other；非份额类恒为 other。
  final String market;
  final int quantityE4;

  /// 当前持仓总成本（移动平均）；定期类是本金，金额类是投进去的本金。
  final int costCents;
  final int? priceE4;

  /// 昨收 / 上一个净值；手动改价后为 null。
  final int? prevCloseE4;

  /// auto | manual
  final String priceSource;
  final DateTime? priceAt;

  /// `YYYY-MM-DD`：买入日 / 起息日 / 存入日。
  final String openedOn;

  /// 挂的投资账户（kind=invest）。
  final String? accountId;

  /// 已实现收益：卖出盈亏、分红、付息之和。
  final int realizedCents;

  /// 在哪买的：招商银行、支付宝……
  final String? institution;

  /// 年化 ×1e6（2.15% → 21500）；结构性存款是保底。
  final int? rateE6;

  /// 结构性存款的最高年化。
  final int? rateMaxE6;

  /// 定期类的到期日 `YYYY-MM-DD`。
  final String? maturesOn;

  /// 金额类的当前金额；null = 没更新过，按本金算。
  final int? valueCents;
  final String? valueOn;
  final String? note;
  final int sortOrder;
  final bool archived;

  InvestMode get mode => modeOf(kind);
  bool get isUnit => mode == InvestMode.unit;
  bool get isAuto => priceSource == sourceAuto;
  bool get isCleared => quantityE4 <= 0;
  String get marketLabel => marketLabels[market] ?? '其他';
  String get kindLabel => kindLabels[kind] ?? '其他';

  /// 名称和代码服务端要求至少有一个。
  String get label {
    if (name.isNotEmpty) return name;
    final c = code;
    return c == null || c.isEmpty ? kindLabel : c;
  }

  static String _kindFrom(Map<String, dynamic> json) {
    final raw = jsonStringOrNull(json['kind']);
    if (raw != null && kindLabels.containsKey(raw)) return raw;
    return jsonString(json['market'], 'other') == 'fund' ? kindFund : kindStock;
  }

  factory Holding.fromJson(Map<String, dynamic> json) => Holding(
    id: jsonString(json['id']),
    name: jsonString(json['name']),
    kind: _kindFrom(json),
    code: jsonStringOrNull(json['code']),
    market: jsonString(json['market'], 'other'),
    quantityE4: jsonInt(json['quantityE4']),
    costCents: jsonInt(json['costCents']),
    priceE4: jsonIntOrNull(json['priceE4']),
    prevCloseE4: jsonIntOrNull(json['prevCloseE4']),
    priceSource: jsonString(json['priceSource'], sourceManual),
    priceAt: jsonDateOrNull(json['priceAt']),
    openedOn: jsonString(json['openedOn']),
    accountId: jsonStringOrNull(json['accountId']),
    realizedCents: jsonInt(json['realizedCents']),
    institution: jsonStringOrNull(json['institution']),
    rateE6: jsonIntOrNull(json['rateE6']),
    rateMaxE6: jsonIntOrNull(json['rateMaxE6']),
    maturesOn: jsonStringOrNull(json['maturesOn']),
    valueCents: jsonIntOrNull(json['valueCents']),
    valueOn: jsonStringOrNull(json['valueOn']),
    note: jsonStringOrNull(json['note']),
    sortOrder: jsonInt(json['sortOrder']),
    archived: jsonBool(json['archived']),
  );

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'id': id,
      'name': name,
      'kind': kind,
      'market': market,
      'quantityE4': quantityE4,
      'costCents': costCents,
      'priceSource': priceSource,
      'openedOn': openedOn,
      'realizedCents': realizedCents,
    };
    putIfNotNull(json, 'code', code);
    putIfNotNull(json, 'priceE4', priceE4);
    putIfNotNull(json, 'prevCloseE4', prevCloseE4);
    putIfNotNull(json, 'priceAt', priceAt?.toIso8601String());
    putIfNotNull(json, 'accountId', accountId);
    putIfNotNull(json, 'institution', institution);
    putIfNotNull(json, 'rateE6', rateE6);
    putIfNotNull(json, 'rateMaxE6', rateMaxE6);
    putIfNotNull(json, 'maturesOn', maturesOn);
    putIfNotNull(json, 'valueCents', valueCents);
    putIfNotNull(json, 'valueOn', valueOn);
    putIfNotNull(json, 'note', note);
    json['sortOrder'] = sortOrder;
    json['archived'] = archived;
    return json;
  }
}
