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

class FundBalance {
  const FundBalance({required this.fundId, required this.balanceCents});

  final String fundId;
  final int balanceCents;

  factory FundBalance.fromJson(Map<String, dynamic> json) => FundBalance(
    fundId: jsonString(json['fundId']),
    balanceCents: jsonInt(json['balanceCents']),
  );

  Map<String, dynamic> toJson() => {'fundId': fundId, 'balanceCents': balanceCents};
}

class AccountBalance {
  const AccountBalance({required this.accountId, required this.balanceCents});

  final String accountId;
  final int balanceCents;

  factory AccountBalance.fromJson(Map<String, dynamic> json) => AccountBalance(
    accountId: jsonString(json['accountId']),
    balanceCents: jsonInt(json['balanceCents']),
  );

  Map<String, dynamic> toJson() => {
    'accountId': accountId,
    'balanceCents': balanceCents,
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
    this.byCategory = const [],
    this.recent = const [],
  });

  final int balanceCents;
  final int? targetCents;
  final int monthExpenseCents;
  final int monthIncomeCents;
  final int? budgetCents;
  final List<CategoryAmount> byCategory;
  final List<Transaction> recent;

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
