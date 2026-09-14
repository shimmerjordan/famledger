import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../data/models/models.dart';
import '../funds/fund_progress.dart';
import '../widgets/widgets.dart';

/// 首页的基金卡片横滑（DESIGN.md 只给了卡片两处用武之地，这是其一）。
class FundCarousel extends StatelessWidget {
  const FundCarousel({
    super.key,
    required this.funds,
    required this.stats,
    required this.onTap,
  });

  final List<Fund> funds;
  final StatsOverview? stats;
  final ValueChanged<Fund> onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 132,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
      itemCount: funds.length,
      separatorBuilder: (_, _) => const SizedBox(width: LedgerLayout.itemGap),
      itemBuilder: (context, index) => FundCard(
        fund: funds[index],
        index: index,
        progress: fundProgressOf(funds[index], stats),
        onTap: () => onTap(funds[index]),
      ),
    ),
  );
}

/// 一张基金卡：名字 + 余额 + 目标/预算进度。
class FundCard extends StatelessWidget {
  const FundCard({
    super.key,
    required this.fund,
    required this.index,
    required this.progress,
    required this.onTap,
    this.width = 200,
  });

  final Fund fund;
  final int index;
  final FundProgress progress;
  final VoidCallback onTap;
  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = fundColorOf(context, fund, index);
    return SizedBox(
      width: width,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(LedgerLayout.itemGap),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    FundDot(color: color),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        fund.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                  ],
                ),
                MoneyText(progress.balanceCents, size: MoneySize.title),
                FundProgressBar(progress: progress, color: color),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 宽屏侧栏里的「基金余额」：同样的数据，竖着排一条条。
class FundBalanceList extends StatelessWidget {
  const FundBalanceList({
    super.key,
    required this.funds,
    required this.stats,
    required this.onTap,
  });

  final List<Fund> funds;
  final StatsOverview? stats;
  final ValueChanged<Fund> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        for (var i = 0; i < funds.length; i++)
          Builder(
            builder: (context) {
              final fund = funds[i];
              final progress = fundProgressOf(fund, stats);
              final color = fundColorOf(context, fund, i);
              return ListTile(
                onTap: () => onTap(fund),
                contentPadding: EdgeInsets.zero,
                leading: FundDot(color: color, size: 10),
                title: Text(fund.name, style: theme.textTheme.bodyLarge),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: FundProgressBar(progress: progress, color: color),
                ),
                trailing: MoneyText(progress.balanceCents),
              );
            },
          ),
      ],
    );
  }
}
