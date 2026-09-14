import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../core/money.dart';
import '../../data/models/models.dart';
import '../widgets/widgets.dart';
import 'chart_legend.dart';

/// 12 个月的收支柱状：支出用墨色，收入用青绿，下面跟一条图例。
class TrendChart extends StatelessWidget {
  const TrendChart({super.key, required this.series, this.height = 180});

  final List<TrendPoint> series;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ledger = LedgerColors.of(context);

    if (series.isEmpty) {
      return const EmptyState(
        title: '还没有可以比较的月份',
        message: '记满一个月，这里就会长出柱子。',
        compact: true,
      );
    }

    final expenseColor = theme.colorScheme.onSurface;
    final incomeColor = ledger.income;
    var maxCents = 0;
    var totalExpense = 0;
    var totalIncome = 0;
    for (final point in series) {
      if (point.expenseCents > maxCents) maxCents = point.expenseCents;
      if (point.incomeCents > maxCents) maxCents = point.incomeCents;
      totalExpense += point.expenseCents;
      totalIncome += point.incomeCents;
    }
    // 全是 0 的时候给个 1 元的高度，免得坐标轴退化成一条线。
    final maxY = (maxCents == 0 ? 100 : maxCents * 1.15).toDouble();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: LedgerLayout.pagePadding,
          ),
          child: SizedBox(
            height: height,
            child: BarChart(
              BarChartData(
                maxY: maxY,
                minY: 0,
                alignment: BarChartAlignment.spaceAround,
                barGroups: [
                  for (var i = 0; i < series.length; i++)
                    BarChartGroupData(
                      x: i,
                      barsSpace: 2,
                      barRods: [
                        BarChartRodData(
                          toY: series[i].expenseCents.toDouble(),
                          color: expenseColor,
                          width: 5,
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(2),
                          ),
                        ),
                        BarChartRodData(
                          toY: series[i].incomeCents.toDouble(),
                          color: incomeColor,
                          width: 5,
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(2),
                          ),
                        ),
                      ],
                    ),
                ],
                gridData: FlGridData(
                  drawVerticalLine: false,
                  horizontalInterval: maxY / 2,
                  getDrawingHorizontalLine: (_) => FlLine(
                    color: theme.colorScheme.outlineVariant,
                    strokeWidth: 1,
                  ),
                ),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(),
                  rightTitles: const AxisTitles(),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 44,
                      interval: maxY / 2,
                      getTitlesWidget: (value, meta) => SideTitleWidget(
                        meta: meta,
                        child: Text(
                          _compactYuan(value),
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 24,
                      getTitlesWidget: (value, meta) {
                        final index = value.round();
                        if (index < 0 || index >= series.length) {
                          return const SizedBox.shrink();
                        }
                        // 12 个标签挤不下，隔一个显示，最右边（当月）一定显示。
                        if ((series.length - 1 - index) % 2 != 0) {
                          return const SizedBox.shrink();
                        }
                        return SideTitleWidget(
                          meta: meta,
                          child: Text(
                            _monthTick(series[index].month),
                            style: theme.textTheme.bodySmall,
                          ),
                        );
                      },
                    ),
                  ),
                ),
                barTouchData: BarTouchData(
                  touchTooltipData: BarTouchTooltipData(
                    getTooltipColor: (_) => ledger.surface3,
                    tooltipBorderRadius: BorderRadius.circular(
                      LedgerShapes.chip,
                    ),
                    getTooltipItem: (group, groupIndex, rod, rodIndex) {
                      final point = series[group.x];
                      final isExpense = rodIndex == 0;
                      final cents = isExpense
                          ? point.expenseCents
                          : point.incomeCents;
                      return BarTooltipItem(
                        '${Dates.monthLabel(point.month)}\n'
                        '${isExpense ? '支出' : '收入'} ${Money.format(cents)}',
                        theme.textTheme.bodySmall ?? const TextStyle(),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: LedgerLayout.itemGap),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: LedgerLayout.pagePadding,
          ),
          child: Wrap(
            spacing: 20,
            runSpacing: 8,
            children: [
              _LegendItem(color: expenseColor, label: '支出', cents: totalExpense),
              _LegendItem(color: incomeColor, label: '收入', cents: totalIncome),
            ],
          ),
        ),
      ],
    );
  }
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({
    required this.color,
    required this.label,
    required this.cents,
  });

  final Color color;
  final String label;
  final int cents;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      ChartSwatch(color),
      const SizedBox(width: 6),
      Text('$label 合计', style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(width: 6),
      MoneyText(cents, size: MoneySize.small),
    ],
  );
}

/// `2026-09` → `9月`
String _monthTick(String month) {
  final parts = month.split('-');
  if (parts.length < 2) return month;
  return '${int.tryParse(parts[1]) ?? parts[1]}月';
}

/// 纵轴刻度：分 → `1.2万` / `800`
String _compactYuan(double cents) {
  final yuan = cents / 100;
  if (yuan >= 10000) {
    final wan = yuan / 10000;
    return '${wan >= 10 ? wan.round() : wan.toStringAsFixed(1)}万';
  }
  return yuan.round().toString();
}
