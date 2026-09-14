import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../widgets/widgets.dart';
import 'chart_legend.dart';

/// 环上最多画几份，多出来的并成一块灰色的「其他」。
///
/// 环与排行榜共用这一个数，两边的「其他」永远是同一块。
const int kMaxDonutSlices = 8;

/// 类别构成的环形图。超过 [maxSlices] 份就并成「其他」，否则环上全是碎片。
class CategoryDonut extends StatelessWidget {
  const CategoryDonut({
    super.key,
    required this.slices,
    required this.totalCents,
    this.caption = '本月支出',
    this.size = 176,
    this.thickness = 24,
    this.maxSlices = kMaxDonutSlices,
  });

  final List<AnalysisSlice> slices;
  final int totalCents;
  final String caption;
  final double size;
  final double thickness;
  final int maxSlices;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (slices.isEmpty || totalCents <= 0) {
      return const EmptyState(
        title: '这个月还没有支出',
        message: '记一笔之后，这里会画出钱都花在哪了。',
        compact: true,
      );
    }

    final shown = <AnalysisSlice>[];
    var rest = 0;
    for (var i = 0; i < slices.length; i++) {
      if (i < maxSlices) {
        shown.add(slices[i]);
      } else {
        rest += slices[i].cents;
      }
    }

    return Center(
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            PieChart(
              PieChartData(
                sectionsSpace: 2,
                centerSpaceRadius: size / 2 - thickness,
                startDegreeOffset: -90,
                pieTouchData: PieTouchData(enabled: false),
                sections: [
                  for (final slice in shown)
                    PieChartSectionData(
                      value: slice.cents.toDouble(),
                      color: slice.color,
                      radius: thickness,
                      showTitle: false,
                    ),
                  if (rest > 0)
                    PieChartSectionData(
                      value: rest.toDouble(),
                      color: theme.colorScheme.outlineVariant,
                      radius: thickness,
                      showTitle: false,
                    ),
                ],
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(caption, style: theme.textTheme.bodySmall),
                const SizedBox(height: 2),
                MoneyText(totalCents, size: MoneySize.title),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 环形图的图例 + 排行榜：占比、金额、环比，一份都不能少。
///
/// 前 [maxSlices] 项与环上的扇形一一对应（同名同色）；剩下的折进一行灰色的
/// 「其他 N 项」，点开才展开 —— 环上那块灰扇形就是它，图例不能比环更细。
class CategoryRankedList extends StatefulWidget {
  const CategoryRankedList({
    super.key,
    required this.slices,
    required this.totalCents,
    this.maxSlices = kMaxDonutSlices,
    this.emptyTitle = '这个月还没有支出',
    this.emptyMessage = '记一笔之后，这里会列出各类别的排行。',
  });

  final List<AnalysisSlice> slices;
  final int totalCents;
  final int maxSlices;
  final String emptyTitle;
  final String emptyMessage;

  @override
  State<CategoryRankedList> createState() => _CategoryRankedListState();
}

class _CategoryRankedListState extends State<CategoryRankedList> {
  bool _expanded = false;

  double? _share(int cents) =>
      widget.totalCents <= 0 ? null : cents / widget.totalCents;

  @override
  Widget build(BuildContext context) {
    if (widget.slices.isEmpty) {
      return EmptyState(
        title: widget.emptyTitle,
        message: widget.emptyMessage,
        compact: true,
      );
    }

    final restColor = Theme.of(context).colorScheme.outlineVariant;
    final shown = widget.slices.take(widget.maxSlices).toList();
    final rest = widget.slices.skip(widget.maxSlices).toList();
    final restCents = rest.fold<int>(0, (sum, s) => sum + s.cents);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final slice in shown)
          LegendRow(
            color: slice.color,
            label: slice.label,
            cents: slice.cents,
            share: _share(slice.cents),
            trailingNote: momLabel(slice.cents, slice.previousCents),
            leading: slice.icon == null
                ? null
                : CategoryIcon(slice.icon, size: 16, color: slice.color),
          ),
        if (rest.isNotEmpty) ...[
          LegendRow(
            color: restColor,
            label: '其他 ${rest.length} 项',
            cents: restCents,
            share: _share(restCents),
            onTap: () => setState(() => _expanded = !_expanded),
            trailing: Icon(
              _expanded ? Icons.expand_less : Icons.expand_more,
              size: 20,
            ),
          ),
          if (_expanded)
            for (final slice in rest)
              LegendRow(
                // 展开的这些在环上同属那块灰扇形，色块也就得是灰的。
                color: restColor,
                label: slice.label,
                cents: slice.cents,
                share: _share(slice.cents),
                trailingNote: momLabel(slice.cents, slice.previousCents),
                leading: slice.icon == null
                    ? null
                    : CategoryIcon(slice.icon, size: 16, color: restColor),
              ),
        ],
      ],
    );
  }
}
