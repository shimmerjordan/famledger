import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../widgets/widgets.dart';

/// 图表里的一份：名字、金额、颜色，外加可选的图标与上月金额（算环比用）。
class AnalysisSlice {
  const AnalysisSlice({
    required this.id,
    required this.label,
    required this.cents,
    required this.color,
    this.icon,
    this.previousCents,
  });

  final String id;
  final String label;
  final int cents;
  final Color color;

  /// [kCategoryIcons] 里的名字。
  final String? icon;

  /// 上个月同一项的金额；null = 上个月的数据还没来，不显示环比。
  final int? previousCents;
}

/// 图例上的小色块。图表永远配图例，不让颜色单独承载信息（DESIGN.md）。
class ChartSwatch extends StatelessWidget {
  const ChartSwatch(this.color, {super.key, this.size = 10});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(2),
    ),
  );
}

/// 图例的一行：色块 + 名称 + 金额（+ 可选的占比/环比）。
class LegendRow extends StatelessWidget {
  const LegendRow({
    super.key,
    required this.color,
    required this.label,
    required this.cents,
    this.share,
    this.trailingNote,
    this.leading,
    this.trailing,
    this.onTap,
  });

  final Color color;
  final String label;
  final int cents;

  /// 0..1，占比。null 就不显示。
  final double? share;

  /// 右下角的小字，例如「环比 +12%」。
  final String? trailingNote;

  /// 色块之外还想放个图标时用。
  final Widget? leading;

  /// 金额右边的收起/展开箭头之类。
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final share = this.share;
    final note = trailingNote;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LedgerLayout.pagePadding,
          vertical: 10,
        ),
        child: Row(
          children: [
            ChartSwatch(color),
            const SizedBox(width: 10),
            if (leading != null) ...[leading!, const SizedBox(width: 8)],
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            if (share != null) ...[
              SizedBox(
                width: 44,
                child: Text(
                  '${(share * 100).round()}%',
                  textAlign: TextAlign.right,
                  style: theme.textTheme.bodySmall,
                ),
              ),
              const SizedBox(width: 8),
            ],
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                MoneyText(cents),
                if (note != null)
                  Text(note, style: theme.textTheme.bodySmall),
              ],
            ),
            if (trailing != null) ...[const SizedBox(width: 4), trailing!],
          ],
        ),
      ),
    );
  }
}

/// 环比文案：`null` 表示上个月没数据，不硬凑一个百分比。
String? momLabel(int current, int? previous) {
  if (previous == null) return null;
  if (previous == 0) return current == 0 ? null : '上月没花';
  final delta = (current - previous) / previous;
  if (delta.abs() < 0.005) return '环比持平';
  final percent = (delta.abs() * 100).round();
  return delta > 0 ? '环比 +$percent%' : '环比 −$percent%';
}
