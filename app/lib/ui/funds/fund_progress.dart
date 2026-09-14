import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/money.dart';
import '../../data/models/models.dart';

/// 一个基金在某个月的「一句话状态」：余额、本月花了多少、进度条怎么画。
///
/// 目标（`targetCents`）与月预算（`monthlyBudgetCents` 或 `budgets` 里那条）
/// 是两回事：有目标就画攒钱进度，没目标才画预算消耗。
class FundProgress {
  const FundProgress({
    required this.balanceCents,
    required this.monthExpenseCents,
    required this.monthIncomeCents,
    this.targetCents,
    this.budgetCents,
  });

  final int balanceCents;
  final int monthExpenseCents;
  final int monthIncomeCents;
  final int? targetCents;
  final int? budgetCents;

  bool get hasTarget => (targetCents ?? 0) > 0;
  bool get hasBudget => (budgetCents ?? 0) > 0;
  bool get hasBar => hasTarget || hasBudget;

  /// 0..1 之间给进度条用（真实比例可能超过 1，见 [isOver]）。
  double get ratio {
    final raw = hasTarget
        ? balanceCents / targetCents!
        : (hasBudget ? monthExpenseCents / budgetCents! : 0.0);
    if (raw.isNaN || raw <= 0) return 0;
    return raw > 1 ? 1 : raw;
  }

  /// 只有预算会「超」；攒钱攒过头不是坏事。
  bool get isOver => hasBudget && !hasTarget && monthExpenseCents > budgetCents!;

  /// 预算用掉 85% 起提前提醒（与 [BudgetProgress.isNear] 同口径）。
  bool get isNear =>
      hasBudget &&
      !hasTarget &&
      !isOver &&
      monthExpenseCents / budgetCents! >= 0.85;

  int get percent => (ratio * 100).round();

  /// 进度条下面那行字。
  String get label {
    if (hasTarget) {
      return '目标 ${Money.format(targetCents!)} · $percent%';
    }
    if (hasBudget) {
      final remain = budgetCents! - monthExpenseCents;
      return remain >= 0
          ? '本月预算还剩 ${Money.format(remain)}'
          : '超预算 ${Money.format(-remain)}';
    }
    return '本月支出 ${Money.format(monthExpenseCents)}';
  }
}

/// 从 `GET /stats/overview` 的整包里取出某个基金的状态。
FundProgress fundProgressOf(Fund fund, StatsOverview? stats) {
  var expense = 0;
  var income = 0;
  int? budget = fund.monthlyBudgetCents;
  if (stats != null) {
    for (final row in stats.month.byFund) {
      if (row.fundId == fund.id) {
        expense = row.expenseCents;
        income = row.incomeCents;
        break;
      }
    }
    // 预算表里这个月单独设过的，优先于基金上写死的月预算。
    for (final row in stats.month.budgets) {
      if (row.scope == Budget.scopeFund && row.refId == fund.id) {
        budget = row.budgetCents;
        break;
      }
    }
  }
  return FundProgress(
    balanceCents: stats?.fundBalance(fund.id) ?? 0,
    monthExpenseCents: expense,
    monthIncomeCents: income,
    targetCents: fund.targetCents,
    budgetCents: budget,
  );
}

/// 进度条 + 一行说明。超预算用 error 色，接近上限用 warning 色，
/// 但文字自己也说得清（不靠颜色单独承载信息）。
class FundProgressBar extends StatelessWidget {
  const FundProgressBar({
    super.key,
    required this.progress,
    required this.color,
    this.showLabel = true,
  });

  final FundProgress progress;

  /// 基金身份色：没有超支预警时进度条就是基金自己的颜色。
  final Color color;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ledger = LedgerColors.of(context);
    final bar = progress.isOver
        ? theme.colorScheme.error
        : (progress.isNear ? ledger.warning : color);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (progress.hasBar)
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress.isOver ? 1 : progress.ratio,
              minHeight: 6,
              backgroundColor: ledger.surface3,
              color: bar,
            ),
          ),
        if (showLabel) ...[
          if (progress.hasBar) const SizedBox(height: 6),
          Text(
            progress.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: progress.isOver ? theme.colorScheme.error : null,
            ),
          ),
        ],
      ],
    );
  }
}
