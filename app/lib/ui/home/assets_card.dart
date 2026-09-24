import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/models/models.dart';
import '../assets/asset_providers.dart';
import '../assets/asset_widgets.dart';
import '../widgets/widgets.dart';

/// 首页的「资产」：物品每天花多少、投资值多少今天涨跌多少。
///
/// 两边都还没记时只留一行入口，不占首页的地方。不套 Card：DESIGN.md 只把卡片留给
/// 基金横滑和待确认，这里跟本月合计一样用并排的两格。
class AssetsHomeCard extends ConsumerWidget {
  const AssetsHomeCard({super.key, this.padding});

  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ledger = ref.watch(ledgerProvider).valueOrNull;
    if (ledger == null) return const SizedBox.shrink();
    final now = ref.watch(assetClockProvider)();
    // 记过但都退役/卖掉了也算记过：summarizeAssets 只数还在家里的。
    final recorded = ledger.activeAssets.isNotEmpty;
    final items = summarizeAssets(ledger.assets, now);
    final invest = summarizeHoldings(ledger.holdings, now);

    if (!recorded && invest.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: LedgerLayout.groupGap),
        child: ListTile(
          key: const ValueKey('assets-entry'),
          onTap: () => context.push('/assets'),
          contentPadding: padding ??
              const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
          leading: const Icon(Icons.inventory_2_outlined),
          title: const Text('记录资产'),
          subtitle: const Text('东西每天花多少、投资赚了多少'),
          trailing: const Icon(Icons.chevron_right, size: 20),
        ),
      );
    }

    final theme = Theme.of(context);
    final sidePadding = padding ??
        const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          '资产',
          padding: padding == null ? null : const EdgeInsets.only(bottom: 8),
          actionLabel: '全部',
          onAction: () => context.push('/assets'),
        ),
        Padding(
          key: const ValueKey('assets-card'),
          padding: sidePadding,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _Half(
                  onTap: () => context.push('/assets'),
                  label: '物品每天',
                  value: recorded
                      ? DailyMoney(items.dailyCents)
                      : Text('还没记', style: theme.textTheme.bodyLarge),
                  note: _itemsNote(recorded, items),
                ),
              ),
              const SizedBox(width: LedgerLayout.itemGap),
              Expanded(child: _investHalf(context, invest)),
            ],
          ),
        ),
        const SizedBox(height: LedgerLayout.groupGap),
      ],
    );
  }

  /// 没价格的持仓不进市值（summarizeHoldings 只数它的个数）。一只价都没有时写 ¥0.00 等于说它
  /// 一分不值；有一部分没价格时不提，就是悄悄少算。两种都照投资页的口径明说。
  Widget _investHalf(BuildContext context, PortfolioSummary invest) {
    final theme = Theme.of(context);
    final priced = invest.heldCount - invest.unpricedCount;
    final unpricedNote = Text(
      priced == 0
          ? '${invest.unpricedCount} 只还没有价格'
          : '另有 ${invest.unpricedCount} 只没价格，没算进来',
      key: const ValueKey('assets-invest-unpriced'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodySmall,
    );
    final today = Row(
      children: [
        Text('今日 ', style: theme.textTheme.bodySmall),
        Flexible(
          child: MoneyText(
            invest.todayChangeCents,
            signed: true,
            size: MoneySize.small,
          ),
        ),
      ],
    );
    void open() => context.push('/assets?tab=invest');

    if (invest.isEmpty) {
      return _Half(
        onTap: open,
        label: '投资市值',
        value: Text('还没记', style: theme.textTheme.bodyLarge),
        note: '点这里添加',
      );
    }
    if (invest.heldCount == 0) {
      return _Half(
        onTap: open,
        label: '投资市值',
        value: MoneyText(invest.marketCents),
        note: '都清仓了',
      );
    }
    if (priced == 0) {
      return _Half(
        onTap: open,
        label: '投资市值',
        value: Text('还没有价格', style: theme.textTheme.bodyLarge),
        noteWidget: unpricedNote,
      );
    }
    return _Half(
      onTap: open,
      label: '投资市值',
      value: MoneyText(invest.marketCents),
      noteWidget: invest.unpricedCount == 0
          ? today
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [today, unpricedNote],
            ),
    );
  }

  static String _itemsNote(bool recorded, AssetSummary items) {
    if (!recorded) return '点这里记一件';
    if (items.isEmpty) return '都退役或卖掉了';
    final inUse = items.count - items.idleCount;
    return [
      if (inUse > 0) '$inUse 件在用',
      if (items.idleCount > 0) '${items.idleCount} 件闲置',
    ].join(' · ');
  }
}

class _Half extends StatelessWidget {
  const _Half({
    required this.onTap,
    required this.label,
    required this.value,
    this.note,
    this.noteWidget,
  });

  final VoidCallback onTap;
  final String label;
  final Widget value;
  final String? note;
  final Widget? noteWidget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(LedgerShapes.control),
      child: Padding(
        // 没有卡片边框了，左右不留白，字才跟上面的「资产」标题对齐。
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: theme.textTheme.bodySmall),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: value,
            ),
            const SizedBox(height: 2),
            if (noteWidget != null)
              noteWidget!
            else if (note != null)
              Text(
                note!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
          ],
        ),
      ),
    );
  }
}
