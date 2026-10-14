import 'json_utils.dart';
import 'transaction.dart';

/// `GET /stats/overview?month=` 的整包。
class StatsOverview {
  const StatsOverview({
    required this.netWorthCents,
    required this.assetsCents,
    required this.liabilitiesCents,
    required this.month,
    this.pendingCount = 0,
    this.funds = const [],
    this.accounts = const [],
    this.investMarketCents,
    this.netWorthExPhysicalCents,
    this.physical,
    this.cashCents,
    this.investAccountsCents,
    this.serverInvestNetCents,
    this.investByKind = const [],
    this.debts,
    this.fx = const FxRates(),
    this.byCurrency = const {},
  });

  /// 按家庭设置含不含实物，由服务端 stats.js 决定。
  final int netWorthCents;
  final int assetsCents;
  final int liabilitiesCents;
  final MonthStats month;
  final int pendingCount;
  final List<FundBalance> funds;
  final List<AccountBalance> accounts;

  /// 持仓总市值（stats.js 一直给；缺了是 null）。净资产总览拿它说清「投资（账户外）」
  /// 为什么比市值小：挂了账户的持仓成本已经在账户余额里。
  final int? investMarketCents;

  /// 不含实物的净资产；老服务端不给时是 null。
  final int? netWorthExPhysicalCents;

  /// 实物估值汇总；老服务端不给时是 null（净资产条就不写实物那段、也没有开关）。
  final PhysicalSummary? physical;

  /// 现金流：非投资、非债务账户的合计（信用卡欠款已减）；老服务端不给时是 null。
  final int? cashCents;

  /// 投资账户（证券户、理财户）的余额合计：持仓的成本记在这里；老服务端不给时是 null。
  final int? investAccountsCents;

  /// 投资补差：挂账户持仓的浮盈 + 没挂账户的整份估值（stats.js 第 4 条）。
  final int? serverInvestNetCents;

  /// 各品类的估值、成本、笔数，估值大的在前。
  final List<InvestKindTotal> investByKind;

  /// 债务汇总；老服务端不给时是 null。
  final DebtSummary? debts;

  /// 内嵌汇率：与服务端一致的折算表（客户端「换算」按钮用）。老服务端不给时是空表。
  final FxRates fx;

  /// 每个币种一份原生金额的分项（不折算）；老服务端不给时是空的，[buckets] 拿折成基准币的老字段顶上。
  final Map<String, CurrencyBucket> byCurrency;

  /// 各币种的分项：服务端给了 byCurrency 就用它；老服务端（单币种时代）整份当基准币。
  Map<String, CurrencyBucket> get buckets => byCurrency.isNotEmpty
      ? byCurrency
      : {
          fx.base: CurrencyBucket(
            netWorthCents: netWorthCents,
            netWorthExPhysicalCents: netWorthExPhysicalCents ?? netWorthCents,
            assetsCents: assetsCents,
            liabilitiesCents: liabilitiesCents,
            cashCents: cashFlowCents,
            investAccountsCents: investAccountsCents ?? 0,
            investNetCents: investNetCents,
            investMarketCents: investMarketCents ?? 0,
            physicalValueCents: physical?.valueCents ?? 0,
            physicalIncludedCents: physical?.includedCents ?? 0,
            debts: debts ?? const DebtSummary(),
            monthExpenseCents: month.expenseCents,
            monthIncomeCents: month.incomeCents,
          ),
        };

  /// 某个分项按币种分开，例如 `o.amountsBy((b) => b.cashCents)`。
  CurrencyAmounts amountsBy(int Function(CurrencyBucket b) pick) =>
      CurrencyAmounts({for (final e in buckets.entries) e.key: pick(e.value)});

  /// 全部账户余额合计（含投资账户和债务的内部账户）。
  int get accountsNetCents => accounts.fold<int>(0, (sum, a) => sum + a.balanceCents);

  /// 投资补差。老服务端没给就倒推：不含实物的净资产 − 账户合计（那时还没有债务）。
  int get investNetCents => serverInvestNetCents ?? (netWorthExPhysicalCents ?? netWorthCents) - accountsNetCents;

  /// 现金流（净资产的第一项）。老服务端：账户合计。
  int get cashFlowCents => cashCents ?? accountsNetCents;

  /// 理财对净资产的贡献 = 投资账户里的钱 + 投资补差。老服务端投资账户算在账户合计里，只剩补差。
  int get investTotalCents => (investAccountsCents ?? 0) + investNetCents;

  /// 计入净资产的债务净额：别人欠我 − 我欠别人。
  int get debtsNetCents => debts?.countedNetCents ?? 0;

  /// 某个账户的余额；不在列表里（刚建、统计还没刷新）是 null。
  int? balanceOf(String? accountId) {
    if (accountId == null) return null;
    for (final a in accounts) {
      if (a.accountId == accountId) return a.balanceCents;
    }
    return null;
  }

  int fundBalance(String fundId) {
    for (final f in funds) {
      if (f.fundId == fundId) return f.balanceCents;
    }
    return 0;
  }

  /// 板块按币种分开的余额（原生）；不在列表里是空的。
  CurrencyAmounts fundBalances(String fundId) {
    for (final f in funds) {
      if (f.fundId == fundId) return f.amounts(fx.base);
    }
    return const CurrencyAmounts();
  }

  /// 某个账户的币种；不在列表里按基准币。
  String accountCurrency(String accountId) {
    for (final a in accounts) {
      if (a.accountId == accountId) return a.currency;
    }
    return fx.base;
  }

  int accountBalance(String accountId) {
    for (final a in accounts) {
      if (a.accountId == accountId) return a.balanceCents;
    }
    return 0;
  }

  factory StatsOverview.fromJson(Map<String, dynamic> json) => StatsOverview(
    netWorthCents: jsonInt(json['netWorthCents']),
    assetsCents: jsonInt(json['assetsCents']),
    liabilitiesCents: jsonInt(json['liabilitiesCents']),
    month: MonthStats.fromJson(jsonMap(json['month'])),
    pendingCount: jsonInt(json['pendingCount']),
    funds: jsonList(json['funds'], FundBalance.fromJson),
    accounts: jsonList(json['accounts'], AccountBalance.fromJson),
    investMarketCents: jsonIntOrNull(json['investMarketCents']),
    netWorthExPhysicalCents: jsonIntOrNull(json['netWorthExPhysicalCents']),
    physical: json['physical'] is Map
        ? PhysicalSummary.fromJson(jsonMap(json['physical']))
        : null,
    cashCents: jsonIntOrNull(json['cashCents']),
    investAccountsCents: jsonIntOrNull(json['investAccountsCents']),
    serverInvestNetCents: jsonIntOrNull(json['investNetCents']),
    investByKind: jsonList(json['investByKind'], InvestKindTotal.fromJson),
    debts: json['debts'] is Map ? DebtSummary.fromJson(jsonMap(json['debts'])) : null,
    fx: json['fx'] is Map ? FxRates.fromJson(jsonMap(json['fx'])) : const FxRates(),
    byCurrency: {
      for (final e in jsonMap(json['byCurrency']).entries)
        if (e.value is Map) e.key.toUpperCase(): CurrencyBucket.fromJson(jsonMap(e.value)),
    },
  );

  Map<String, dynamic> toJson() => {
    'netWorthCents': netWorthCents,
    'assetsCents': assetsCents,
    'liabilitiesCents': liabilitiesCents,
    'month': month.toJson(),
    'pendingCount': pendingCount,
    'funds': funds.map((e) => e.toJson()).toList(),
    'accounts': accounts.map((e) => e.toJson()).toList(),
    if (investMarketCents != null) 'investMarketCents': investMarketCents,
    if (netWorthExPhysicalCents != null)
      'netWorthExPhysicalCents': netWorthExPhysicalCents,
    if (physical != null) 'physical': physical!.toJson(),
    if (cashCents != null) 'cashCents': cashCents,
    if (investAccountsCents != null) 'investAccountsCents': investAccountsCents,
    if (serverInvestNetCents != null) 'investNetCents': serverInvestNetCents,
    'investByKind': investByKind.map((e) => e.toJson()).toList(),
    if (debts != null) 'debts': debts!.toJson(),
    'fx': fx.toJson(),
    if (byCurrency.isNotEmpty) 'byCurrency': {for (final e in byCurrency.entries) e.key: e.value.toJson()},
  };
}

/// 按币种分开的金额（原生，不折算）：一组「币种 → 分」。合计（净资产、本月支出、板块余额……）都用它，
/// 界面上人民币、美元常驻、其他收起，「换算」时才按今日汇率合成一个数（[convert]）。
class CurrencyAmounts {
  const CurrencyAmounts([this.values = const {}]);

  CurrencyAmounts.single(String currency, int cents) : values = {currency.toUpperCase(): cents};

  final Map<String, int> values;

  /// 非 0 的那些（显示用）。
  Map<String, int> get nonZero => {for (final e in values.entries) if (e.value != 0) e.key: e.value};

  bool get isZero => values.values.every((v) => v == 0);

  int of(String currency) => values[currency.toUpperCase()] ?? 0;

  CurrencyAmounts add(String currency, int cents) {
    if (cents == 0) return this;
    final c = currency.toUpperCase();
    return CurrencyAmounts({...values, c: (values[c] ?? 0) + cents});
  }

  CurrencyAmounts operator +(CurrencyAmounts other) {
    final out = {...values};
    other.values.forEach((c, v) => out[c] = (out[c] ?? 0) + v);
    return CurrencyAmounts(out);
  }

  CurrencyAmounts operator -(CurrencyAmounts other) => this + other.scale(-1);

  CurrencyAmounts scale(int k) => CurrencyAmounts({for (final e in values.entries) e.key: e.value * k});

  /// 每个币种各自套 [f]（比如只取正数）。
  CurrencyAmounts map(int Function(int cents) f) => CurrencyAmounts({for (final e in values.entries) e.key: f(e.value)});

  /// 按今日汇率合成 [target] 一个数；缺汇率的币种不臆造，放进 missing（合计里那部分不算）。
  ({int cents, List<String> missing}) convert(FxRates fx, String target) {
    var total = 0;
    final missing = <String>[];
    for (final e in nonZero.entries) {
      final v = fx.convert(e.value, e.key, target);
      if (v == null) {
        missing.add(e.key);
      } else {
        total += v;
      }
    }
    return (cents: total, missing: missing);
  }

  /// 一组「币种 → 分」：老服务端只给一个数时整份当 [fallbackCurrency]。
  factory CurrencyAmounts.fromJson(Object? json, {int? fallbackCents, String fallbackCurrency = 'CNY'}) {
    if (json is Map) {
      return CurrencyAmounts({for (final e in json.entries) e.key.toString().toUpperCase(): jsonInt(e.value)});
    }
    return fallbackCents == null ? const CurrencyAmounts() : CurrencyAmounts.single(fallbackCurrency, fallbackCents);
  }

  Map<String, dynamic> toJson() => {...values};

  @override
  bool operator ==(Object other) =>
      other is CurrencyAmounts && other.nonZero.length == nonZero.length && nonZero.entries.every((e) => other.of(e.key) == e.value);

  @override
  int get hashCode => Object.hashAllUnordered(nonZero.entries.map((e) => Object.hash(e.key, e.value)));

  @override
  String toString() => 'CurrencyAmounts($nonZero)';
}

/// 服务端 `overview.byCurrency[币种]`：这一个币种的原生分项。getter 和 [StatsOverview] 的同名口径一致。
class CurrencyBucket {
  const CurrencyBucket({
    this.netWorthCents = 0,
    this.netWorthExPhysicalCents = 0,
    this.assetsCents = 0,
    this.liabilitiesCents = 0,
    this.cashCents = 0,
    this.investAccountsCents = 0,
    this.investNetCents = 0,
    this.investMarketCents = 0,
    this.investCostCents = 0,
    this.physicalValueCents = 0,
    this.physicalIncludedCents = 0,
    this.debts = const DebtSummary(),
    this.monthExpenseCents = 0,
    this.monthIncomeCents = 0,
  });

  final int netWorthCents;
  final int netWorthExPhysicalCents;
  final int assetsCents;
  final int liabilitiesCents;
  final int cashCents;
  final int investAccountsCents;
  final int investNetCents;
  final int investMarketCents;
  final int investCostCents;
  final int physicalValueCents;
  final int physicalIncludedCents;
  final DebtSummary debts;
  final int monthExpenseCents;
  final int monthIncomeCents;

  /// 理财对净资产的贡献 = 投资账户里的钱 + 投资补差。
  int get investTotalCents => investAccountsCents + investNetCents;

  /// 计入净资产的债务净额。
  int get debtsNetCents => debts.countedNetCents;

  factory CurrencyBucket.fromJson(Map<String, dynamic> json) => CurrencyBucket(
    netWorthCents: jsonInt(json['netWorthCents']),
    netWorthExPhysicalCents: jsonInt(json['netWorthExPhysicalCents']),
    assetsCents: jsonInt(json['assetsCents']),
    liabilitiesCents: jsonInt(json['liabilitiesCents']),
    cashCents: jsonInt(json['cashCents']),
    investAccountsCents: jsonInt(json['investAccountsCents']),
    investNetCents: jsonInt(json['investNetCents']),
    investMarketCents: jsonInt(json['investMarketCents']),
    investCostCents: jsonInt(json['investCostCents']),
    physicalValueCents: jsonInt(json['physicalValueCents']),
    physicalIncludedCents: jsonInt(json['physicalIncludedCents']),
    debts: json['debts'] is Map ? DebtSummary.fromJson(jsonMap(json['debts'])) : const DebtSummary(),
    monthExpenseCents: jsonInt(json['monthExpenseCents']),
    monthIncomeCents: jsonInt(json['monthIncomeCents']),
  );

  Map<String, dynamic> toJson() => {
    'netWorthCents': netWorthCents,
    'netWorthExPhysicalCents': netWorthExPhysicalCents,
    'assetsCents': assetsCents,
    'liabilitiesCents': liabilitiesCents,
    'cashCents': cashCents,
    'investAccountsCents': investAccountsCents,
    'investNetCents': investNetCents,
    'investMarketCents': investMarketCents,
    'investCostCents': investCostCents,
    'physicalValueCents': physicalValueCents,
    'physicalIncludedCents': physicalIncludedCents,
    'debts': debts.toJson(),
    'monthExpenseCents': monthExpenseCents,
    'monthIncomeCents': monthIncomeCents,
  };
}

/// 汇率表：与服务端 `overview.fx` / `GET /fx/rates` 同形状。
///
/// `rates[X]` 是「1 基准币 = rates[X] / 1e6 个 X」的 ×1e6 整数（与服务端 `rate_e6` 一致）。
/// 折算走 double 再四舍五入到分：这是**显示层**的换算（「换算」按钮），不改任何存量金额；
/// 缺某一对汇率时 [convert] 返回 null，调用方据此只显示原生币、标「汇率缺失」，绝不臆造。
class FxRates {
  const FxRates({
    this.base = 'CNY',
    this.rates = const {},
    this.asOf,
    this.missing = const [],
    this.manual = const [],
  });

  /// 家庭基准币。
  final String base;

  /// 相对 [base] 的汇率：`{ 'USD': 149388 }` 表示 1 CNY = 0.149388 USD。
  final Map<String, int> rates;

  /// 最近一次刷新时间（服务端给的字符串）；从没刷新过是 null。
  final String? asOf;

  /// 服务端聚合时抓不到汇率的币种（已按 0 计入基准币合计）。
  final List<String> missing;

  /// 手填的汇率（自动抓取不覆盖，直到「恢复自动」）。
  final List<String> manual;

  static const double _e6 = 1e6;

  bool get isEmpty => rates.isEmpty;

  /// 有没有 [currency] 相对基准币的汇率（同币恒有）。
  bool hasRate(String currency) {
    final c = currency.toUpperCase();
    return c == base || rates.containsKey(c);
  }

  /// `from` → `to` 折算到分；缺任一对汇率返回 null。先折到基准币再折到目标币。
  int? convert(int cents, String from, String to) {
    final f = from.toUpperCase();
    final t = to.toUpperCase();
    if (f == t) return cents;
    final viaBase = _toBase(cents, f);
    if (viaBase == null) return null;
    return _fromBase(viaBase, t);
  }

  int? _toBase(int cents, String c) {
    if (c == base) return cents;
    final r = rates[c];
    if (r == null || r == 0) return null;
    return (cents * (_e6 / r)).round(); // c → base：除以 (r/1e6)
  }

  int? _fromBase(int baseCents, String c) {
    if (c == base) return baseCents;
    final r = rates[c];
    if (r == null) return null;
    return (baseCents * (r / _e6)).round(); // base → c：乘以 (r/1e6)
  }

  factory FxRates.fromJson(Map<String, dynamic> json) {
    final rates = <String, int>{};
    jsonMap(json['rates']).forEach((k, val) => rates[k.toUpperCase()] = jsonInt(val));
    return FxRates(
      base: jsonString(json['base'], 'CNY').toUpperCase(),
      rates: rates,
      asOf: jsonStringOrNull(json['asOf']),
      missing: jsonStringList(json['missing']).map((e) => e.toUpperCase()).toList(),
      manual: jsonStringList(json['manual']).map((e) => e.toUpperCase()).toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'base': base,
    'rates': rates,
    if (asOf != null) 'asOf': asOf,
    'missing': missing,
    if (manual.isNotEmpty) 'manual': manual,
  };
}

/// `investByKind` 的一项。
class InvestKindTotal {
  const InvestKindTotal({required this.kind, this.valueCents = 0, this.costCents = 0, this.count = 0});

  final String kind;
  final int valueCents;
  final int costCents;
  final int count;

  factory InvestKindTotal.fromJson(Map<String, dynamic> json) => InvestKindTotal(
    kind: jsonString(json['kind']),
    valueCents: jsonInt(json['valueCents']),
    costCents: jsonInt(json['costCents']),
    count: jsonInt(json['count']),
  );

  Map<String, dynamic> toJson() => {'kind': kind, 'valueCents': valueCents, 'costCents': costCents, 'count': count};
}

/// `debts`：应收、应付（全部 / 计入净资产的部分）、笔数。
class DebtSummary {
  const DebtSummary({
    this.receivableCents = 0,
    this.payableCents = 0,
    this.countedReceivableCents = 0,
    this.countedPayableCents = 0,
    this.count = 0,
  });

  final int receivableCents;
  final int payableCents;
  final int countedReceivableCents;
  final int countedPayableCents;
  final int count;

  int get countedNetCents => countedReceivableCents - countedPayableCents;

  factory DebtSummary.fromJson(Map<String, dynamic> json) => DebtSummary(
    receivableCents: jsonInt(json['receivableCents']),
    payableCents: jsonInt(json['payableCents']),
    countedReceivableCents: jsonInt(json['countedReceivableCents']),
    countedPayableCents: jsonInt(json['countedPayableCents']),
    count: jsonInt(json['count']),
  );

  Map<String, dynamic> toJson() => {
    'receivableCents': receivableCents,
    'payableCents': payableCents,
    'countedReceivableCents': countedReceivableCents,
    'countedPayableCents': countedPayableCents,
    'count': count,
  };
}

/// `physical`：实物估值合计、按单件/类别「该计入」的部分、件数、全局开关开没开（spec §3）。
class PhysicalSummary {
  const PhysicalSummary({
    this.valueCents = 0,
    this.includedCents = 0,
    this.count = 0,
    this.counted = true,
  });

  final int valueCents;

  /// 按单件三态和类别默认该计入的估值；[counted] 为假时它不进净资产。
  final int includedCents;

  /// 在用 + 闲置、未归档的件数。
  final int count;

  /// 家庭设置 `assets.netWorthIncludesPhysical`。
  final bool counted;

  factory PhysicalSummary.fromJson(Map<String, dynamic> json) => PhysicalSummary(
    valueCents: jsonInt(json['valueCents']),
    includedCents: jsonInt(json['includedCents']),
    count: jsonInt(json['count']),
    counted: jsonBool(json['counted'], true),
  );

  Map<String, dynamic> toJson() => {
    'valueCents': valueCents,
    'includedCents': includedCents,
    'count': count,
    'counted': counted,
  };
}

/// 本月的收支与各维度构成。
class MonthStats {
  const MonthStats({
    this.expenseCents = 0,
    this.incomeCents = 0,
    this.byFund = const [],
    this.byCategory = const [],
    this.byMember = const [],
    this.budgets = const [],
  });

  final int expenseCents;
  final int incomeCents;
  final List<FundAmount> byFund;
  final List<CategoryAmount> byCategory;
  final List<MemberAmount> byMember;
  final List<BudgetProgress> budgets;

  int get netCents => incomeCents - expenseCents;

  factory MonthStats.fromJson(Map<String, dynamic> json) => MonthStats(
    expenseCents: jsonInt(json['expenseCents']),
    incomeCents: jsonInt(json['incomeCents']),
    byFund: jsonList(json['byFund'], FundAmount.fromJson),
    byCategory: jsonList(json['byCategory'], CategoryAmount.fromJson),
    byMember: jsonList(json['byMember'], MemberAmount.fromJson),
    budgets: jsonList(json['budgets'], BudgetProgress.fromJson),
  );

  Map<String, dynamic> toJson() => {
    'expenseCents': expenseCents,
    'incomeCents': incomeCents,
    'byFund': byFund.map((e) => e.toJson()).toList(),
    'byCategory': byCategory.map((e) => e.toJson()).toList(),
    'byMember': byMember.map((e) => e.toJson()).toList(),
    'budgets': budgets.map((e) => e.toJson()).toList(),
  };
}

class FundAmount {
  const FundAmount({required this.fundId, this.expenseCents = 0, this.incomeCents = 0});

  final String fundId;
  final int expenseCents;
  final int incomeCents;

  factory FundAmount.fromJson(Map<String, dynamic> json) => FundAmount(
    fundId: jsonString(json['fundId']),
    expenseCents: jsonInt(json['expenseCents']),
    incomeCents: jsonInt(json['incomeCents']),
  );

  Map<String, dynamic> toJson() => {
    'fundId': fundId,
    'expenseCents': expenseCents,
    'incomeCents': incomeCents,
  };
}

class CategoryAmount {
  const CategoryAmount({required this.categoryId, this.expenseCents = 0});

  final String categoryId;
  final int expenseCents;

  factory CategoryAmount.fromJson(Map<String, dynamic> json) => CategoryAmount(
    categoryId: jsonString(json['categoryId']),
    expenseCents: jsonInt(json['expenseCents']),
  );

  Map<String, dynamic> toJson() => {
    'categoryId': categoryId,
    'expenseCents': expenseCents,
  };
}

class MemberAmount {
  const MemberAmount({required this.memberId, this.expenseCents = 0});

  final String memberId;
  final int expenseCents;

  factory MemberAmount.fromJson(Map<String, dynamic> json) => MemberAmount(
    memberId: jsonString(json['memberId']),
    expenseCents: jsonInt(json['expenseCents']),
  );

  Map<String, dynamic> toJson() => {
    'memberId': memberId,
    'expenseCents': expenseCents,
  };
}

/// 预算达成：花了多少 / 预算多少。
class BudgetProgress {
  const BudgetProgress({
    required this.scope,
    required this.refId,
    required this.budgetCents,
    required this.spentCents,
  });

  final String scope;
  final String refId;
  final int budgetCents;
  final int spentCents;

  /// 0 表示没预算（不该拿来画进度条）。
  double get ratio => budgetCents <= 0 ? 0 : spentCents / budgetCents;
  bool get isOver => budgetCents > 0 && spentCents > budgetCents;

  /// 超过 85% 提前预警（见 DESIGN.md 的 warning 色）。
  bool get isNear => budgetCents > 0 && !isOver && ratio >= 0.85;
  int get remainCents => budgetCents - spentCents;

  factory BudgetProgress.fromJson(Map<String, dynamic> json) => BudgetProgress(
    scope: jsonString(json['scope'], 'fund'),
    refId: jsonString(json['refId']),
    budgetCents: jsonInt(json['budgetCents']),
    spentCents: jsonInt(json['spentCents']),
  );

  Map<String, dynamic> toJson() => {
    'scope': scope,
    'refId': refId,
    'budgetCents': budgetCents,
    'spentCents': spentCents,
  };
}

/// 板块的余额。板块没有币种：[balances] 是按币种分开的原生余额，[balanceCents] 是折成基准币的合计
/// （预算、目标进度用）。老服务端只给一个数时 [balances] 是空的，[amounts] 拿它当基准币。
class FundBalance {
  const FundBalance({required this.fundId, required this.balanceCents, this.balances = const CurrencyAmounts()});

  final String fundId;
  final int balanceCents;
  final CurrencyAmounts balances;

  /// 按币种分开的余额；老服务端（只给 balanceCents）整份当 [base]。
  CurrencyAmounts amounts(String base) =>
      balances.values.isNotEmpty || balanceCents == 0 ? balances : CurrencyAmounts.single(base, balanceCents);

  factory FundBalance.fromJson(Map<String, dynamic> json) => FundBalance(
    fundId: jsonString(json['fundId']),
    balanceCents: jsonInt(json['balanceCents']),
    balances: CurrencyAmounts.fromJson(json['balances']),
  );

  Map<String, dynamic> toJson() => {
    'fundId': fundId,
    'balanceCents': balanceCents,
    if (balances.values.isNotEmpty) 'balances': balances.toJson(),
  };
}

class AccountBalance {
  const AccountBalance({required this.accountId, required this.balanceCents, this.currency = 'CNY'});

  final String accountId;
  final int balanceCents;

  /// 这个账户余额的原生币种（老服务端不给时按 CNY）。
  final String currency;

  factory AccountBalance.fromJson(Map<String, dynamic> json) => AccountBalance(
    accountId: jsonString(json['accountId']),
    balanceCents: jsonInt(json['balanceCents']),
    currency: jsonString(json['currency'], 'CNY'),
  );

  Map<String, dynamic> toJson() => {
    'accountId': accountId,
    'balanceCents': balanceCents,
    'currency': currency,
  };
}

/// `GET /stats/fund/:id`
class FundStats {
  const FundStats({
    required this.balanceCents,
    this.targetCents,
    this.monthExpenseCents = 0,
    this.monthIncomeCents = 0,
    this.budgetCents,
    this.balances = const CurrencyAmounts(),
    this.byCategory = const [],
    this.recent = const [],
  });

  final int balanceCents;
  final int? targetCents;
  final int monthExpenseCents;
  final int monthIncomeCents;
  final int? budgetCents;

  /// 按币种分开的余额（原生）；老服务端不给时是空的，[amounts] 拿 [balanceCents] 当基准币。
  final CurrencyAmounts balances;
  final List<CategoryAmount> byCategory;
  final List<Transaction> recent;

  CurrencyAmounts amounts(String base) =>
      balances.values.isNotEmpty || balanceCents == 0 ? balances : CurrencyAmounts.single(base, balanceCents);

  /// 目标进度 0..1（没目标就是 0）。
  double get targetProgress {
    final t = targetCents ?? 0;
    if (t <= 0) return 0;
    return balanceCents / t;
  }

  /// 月预算使用率 0..1（没预算就是 0）。
  double get budgetProgress {
    final b = budgetCents ?? 0;
    if (b <= 0) return 0;
    return monthExpenseCents / b;
  }

  factory FundStats.fromJson(Map<String, dynamic> json) => FundStats(
    balanceCents: jsonInt(json['balanceCents']),
    targetCents: jsonIntOrNull(json['targetCents']),
    monthExpenseCents: jsonInt(json['monthExpenseCents']),
    monthIncomeCents: jsonInt(json['monthIncomeCents']),
    budgetCents: jsonIntOrNull(json['budgetCents']),
    balances: CurrencyAmounts.fromJson(json['balances']),
    byCategory: jsonList(json['byCategory'], CategoryAmount.fromJson),
    recent: jsonList(json['recent'], Transaction.fromJson),
  );
}

/// `GET /stats/trend`
class TrendSeries {
  const TrendSeries({this.series = const []});

  final List<TrendPoint> series;

  bool get isEmpty => series.isEmpty;

  /// 画柱状图的纵轴上限用。
  int get maxCents {
    var max = 0;
    for (final p in series) {
      if (p.expenseCents > max) max = p.expenseCents;
      if (p.incomeCents > max) max = p.incomeCents;
    }
    return max;
  }

  factory TrendSeries.fromJson(Map<String, dynamic> json) =>
      TrendSeries(series: jsonList(json['series'], TrendPoint.fromJson));
}

class TrendPoint {
  const TrendPoint({
    required this.month,
    this.expenseCents = 0,
    this.incomeCents = 0,
  });

  final String month;
  final int expenseCents;
  final int incomeCents;

  int get netCents => incomeCents - expenseCents;

  factory TrendPoint.fromJson(Map<String, dynamic> json) => TrendPoint(
    month: jsonString(json['month']),
    expenseCents: jsonInt(json['expenseCents']),
    incomeCents: jsonInt(json['incomeCents']),
  );
}

/// `GET /stats/calendar`
class CalendarDay {
  const CalendarDay({
    required this.date,
    this.expenseCents = 0,
    this.incomeCents = 0,
    this.count = 0,
  });

  /// `YYYY-MM-DD`
  final String date;
  final int expenseCents;
  final int incomeCents;
  final int count;

  factory CalendarDay.fromJson(Map<String, dynamic> json) => CalendarDay(
    date: jsonString(json['date']),
    expenseCents: jsonInt(json['expenseCents']),
    incomeCents: jsonInt(json['incomeCents']),
    count: jsonInt(json['count']),
  );
}
