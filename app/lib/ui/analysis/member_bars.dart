import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../widgets/widgets.dart';
import 'chart_legend.dart';

/// 横条排行：成员对比与基金占比都用它。
///
/// 条的长度按「占最大那一项的比例」画，右边永远有金额和占比，
/// 颜色只是身份标识，不承载数值（DESIGN.md）。
class ShareBars extends StatelessWidget {
  const ShareBars({
    super.key,
    required this.items,
    required this.totalCents,
    required this.emptyTitle,
    this.emptyMessage,
  });

  final List<AnalysisSlice> items;
  final int totalCents;
  final String emptyTitle;
  final String? emptyMessage;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return EmptyState(
        title: emptyTitle,
        message: emptyMessage,
        compact: true,
      );
    }
    var maxCents = 0;
    for (final item in items) {
      if (item.cents > maxCents) maxCents = item.cents;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final item in items)
          _Bar(
            item: item,
            ratio: maxCents <= 0 ? 0 : item.cents / maxCents,
            share: totalCents <= 0 ? null : item.cents / totalCents,
          ),
      ],
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.item, required this.ratio, required this.share});

  final AnalysisSlice item;
  final double ratio;
  final double? share;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ledger = LedgerColors.of(context);
    final share = this.share;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: LedgerLayout.pagePadding,
        vertical: 8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ChartSwatch(item.color),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  item.label,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              if (share != null) ...[
                Text(
                  '${(share * 100).round()}%',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(width: 8),
              ],
              MoneyText(item.cents),
            ],
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 8,
            child: Stack(
              fit: StackFit.expand,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: ledger.surface3,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: ratio.clamp(0.0, 1.0),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: item.color,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
