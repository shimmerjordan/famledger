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
  });

  final int netWorthCents;
  final int assetsCents;
  final int liabilitiesCents;
  final MonthStats month;
  final int pendingCount;
  final List<FundBalance> funds;
  final List<AccountBalance> accounts;

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
  );

  Map<String, dynamic> toJson() => {
    'netWorthCents': netWorthCents,
    'assetsCents': assetsCents,
    'liabilitiesCents': liabilitiesCents,
    'month': month.toJson(),
    'pendingCount': pendingCount,
    'funds': funds.map((e) => e.toJson()).toList(),
    'accounts': accounts.map((e) => e.toJson()).toList(),
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
