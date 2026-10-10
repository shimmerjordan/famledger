import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../core/money.dart';
import '../../data/models/models.dart';
import '../assets/asset_providers.dart';
import '../assets/net_worth_strip.dart';
import '../widgets/widgets.dart';

/// 首页的「资产」概览：净资产一行，下面现金流 / 理财 / 债务 / 物品 / 会员权益各一格，点哪格进哪段。
///
/// 首页的英雄数字仍是本月支出：净资产这里只用 titleLarge 一行，不抢（DESIGN.md「一屏一个英雄指标」）。
/// 不套卡片：格子是并排的几块字，和本月合计一个样子。没记过的那类写「还没记」，点进去就能加。
class AssetsHomeCard extends ConsumerWidget {
  const AssetsHomeCard({super.key, this.padding, this.columns});

  final EdgeInsetsGeometry? padding;

  /// 一行几格；不给就按宽度定（手机 3 格，很窄 2 格，宽屏 5 格一行排完）。
  final int? columns;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ledger = ref.watch(ledgerProvider).valueOrNull;
    if (ledger == null) return const SizedBox.shrink();
    final stats = ref.watch(statsProvider(Dates.currentMonth()));
    final overview = stats.valueOrNull;
    final now = ref.watch(assetClockProvider)();
    final theme = Theme.of(context);
    final sidePadding = padding ?? const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding);

    final items = summarizeAssets(ledger.assets, now);
    final itemsRecorded = ledger.activeAssets.isNotEmpty;
    final invest = summarizeHoldings(ledger.holdings, now);
    final debts = ledger.activeDebts;
    final cards = perkMemberships(ledger.memberships);
    final toClaim = cards.isEmpty
        ? 0
        : currentPerks(
            memberships: ledger.memberships,
            benefits: ledger.benefits,
            events: ledger.benefitEvents,
            platforms: ledger.platforms,
            today: localDay(now),
          ).toClaimCount;
    final notYet = Text('还没记', style: theme.textTheme.bodyLarge);
    // 总览还在路上画骨架；取不到（离线、出错）就是一道杠，别让骨架一直闪。
    Widget pending(double width) =>
        stats.hasError ? Text('—', style: theme.textTheme.bodyLarge) : Skeleton(width: width, height: 18);

    final tiles = <Widget>[
      _Tile(
        key: const ValueKey('home-asset-cash'),
        label: '现金流',
        value: overview == null ? pending(96) : MoneyText(cashFlowCents(overview)),
        note: overview == null ? null : '可支配 ${Money.format(disposableCents(overview, ledger.funds))}',
        onTap: () => context.push('/settings/accounts'),
      ),
      _Tile(
        key: const ValueKey('home-asset-invest'),
        label: '理财',
        value: invest.isEmpty ? notYet : MoneyText(invest.marketCents),
        note: invest.isEmpty
            ? '基金、定期、活期……'
            : '浮动 ${Money.format(invest.gainCents, signed: true)} · ${invest.byKind.length} 类',
        onTap: () => context.go('/assets?tab=invest'),
      ),
      _Tile(
        key: const ValueKey('home-asset-debts'),
        label: '债务',
        value: debts.isEmpty
            ? notYet
            : overview?.debts == null
            ? pending(96)
            : MoneyText(overview!.debts!.countedNetCents, signed: true),
        note: debts.isEmpty
            ? '借出、借入、人情'
            : overview?.debts == null
            ? null
            // 和净资产条同一个口径：只算计入净资产的（人情默认不算）。
            : '别人欠 ${Money.format(overview!.debts!.countedReceivableCents)} · 欠别人 ${Money.format(overview.debts!.countedPayableCents)}',
        onTap: () => context.go('/assets?tab=debts'),
      ),
      _Tile(
        key: const ValueKey('home-asset-items'),
        label: '物品',
        value: itemsRecorded ? MoneyText(items.valueCents) : notYet,
        note: !itemsRecorded
            ? '东西每天花多少'
            : items.isEmpty
            ? '都退役或卖掉了'
            : '每天 ${Money.format(items.dailyCents.round())}',
        onTap: () => context.go('/assets?tab=items'),
      ),
      _Tile(
        key: const ValueKey('home-asset-perks'),
        label: '会员权益',
        value: cards.isEmpty ? notYet : Text('${cards.length} 张卡', style: theme.textTheme.bodyLarge),
        note: cards.isEmpty ? '88VIP、信用卡权益' : toClaim > 0 ? '本期待领 $toClaim 项' : '本期都领完了',
        onTap: () => context.go('/assets?tab=perks'),
      ),
    ];

    return Column(
      key: const ValueKey('assets-card'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          '资产',
          padding: padding == null ? null : const EdgeInsets.only(bottom: 8),
          actionLabel: '全部',
          onAction: () => context.go('/assets'),
        ),
        Padding(
          padding: sidePadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                key: const ValueKey('home-net-worth'),
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text('净资产', style: theme.textTheme.bodySmall),
                  const SizedBox(width: 8),
                  Flexible(
                    child: overview == null
                        ? pending(140)
                        : MoneyText(overview.netWorthCents, size: MoneySize.title),
                  ),
                ],
              ),
              const SizedBox(height: LedgerLayout.itemGap),
              LayoutBuilder(
                builder: (context, box) {
                  // 手机 3 格一行（两行排完），宽屏主栏 5 格一行。
                  final cols = columns ?? (box.maxWidth >= 760 ? 5 : box.maxWidth >= 330 ? 3 : 2);
                  const gap = LedgerLayout.itemGap;
                  final width = (box.maxWidth - gap * (cols - 1)) / cols;
                  return Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [for (final t in tiles) SizedBox(width: width, child: t)],
                  );
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: LedgerLayout.groupGap),
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({super.key, required this.label, required this.value, required this.onTap, this.note});

  final String label;
  final Widget value;
  final String? note;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(LedgerShapes.control),
      child: Padding(
        // 没有卡片边框，左右不留白，字才跟上面的「资产」标题对齐。
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: theme.textTheme.bodySmall),
            const SizedBox(height: 2),
            FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: value),
            if (note != null) ...[
              const SizedBox(height: 2),
              Text(note!, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}
