import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../data/models/models.dart';
import '../widgets/widgets.dart';

/// 月份切换：‹ 2026年9月 ›。未来的月份没有数据，右箭头到当月为止。
class MonthSwitcher extends StatelessWidget {
  const MonthSwitcher({super.key, required this.month, required this.onChanged});

  final String month;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canForward = month.compareTo(Dates.currentMonth()) < 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: '上一月',
          onPressed: () => onChanged(Dates.shiftMonth(month, -1)),
          icon: const Icon(Icons.chevron_left),
        ),
        Text(Dates.monthLabel(month), style: theme.textTheme.titleMedium),
        IconButton(
          tooltip: '下一月',
          onPressed: canForward
              ? () => onChanged(Dates.shiftMonth(month, 1))
              : null,
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    );
  }
}

/// 本月支出（大字）+ 收入 / 结余。一屏的第一眼就是钱（DESIGN.md）。
class MonthSummary extends StatelessWidget {
  const MonthSummary({super.key, required this.stats});

  final MonthStats stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LedgerLayout.pagePadding,
        8,
        LedgerLayout.pagePadding,
        LedgerLayout.groupGap,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('本月支出', style: theme.textTheme.bodySmall),
          const SizedBox(height: 2),
          MoneyText(stats.expenseCents, size: MoneySize.display),
          const SizedBox(height: LedgerLayout.itemGap),
          Row(
            children: [
              Expanded(
                child: _Cell(
                  label: '收入',
                  child: MoneyText(stats.incomeCents, signed: true),
                ),
              ),
              Expanded(
                child: _Cell(
                  label: '结余',
                  child: MoneyText(stats.netCents, signed: true),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 2),
      child,
    ],
  );
}

/// 首页加载中的骨架：先把「大金额 + 两个小数字」的形占住，别跳版。
class MonthSummarySkeleton extends StatelessWidget {
  const MonthSummarySkeleton({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.fromLTRB(
      LedgerLayout.pagePadding,
      8,
      LedgerLayout.pagePadding,
      LedgerLayout.groupGap,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Skeleton(width: 56, height: 12),
        SizedBox(height: 10),
        Skeleton(width: 180, height: 30),
        SizedBox(height: LedgerLayout.itemGap),
        Row(
          children: [
            Skeleton(width: 96, height: 18),
            SizedBox(width: 32),
            Skeleton(width: 96, height: 18),
          ],
        ),
      ],
    ),
  );
}
