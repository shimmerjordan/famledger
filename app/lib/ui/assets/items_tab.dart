import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/money.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../widgets/widgets.dart';
import 'asset_providers.dart';
import 'asset_widgets.dart';

/// 物品列表的排序；切到投资再切回来还记得。
final assetSortProvider = StateProvider<AssetSort>((ref) => AssetSort.daily);

const Map<AssetSort, String> _sortLabels = {
  AssetSort.daily: '按日均',
  AssetSort.days: '按天数',
  AssetSort.price: '按价格',
};

/// 物品：每天花多少钱。在用/闲置在前，退役/卖出的收在后面。
class ItemsTab extends ConsumerStatefulWidget {
  const ItemsTab({super.key});

  @override
  ConsumerState<ItemsTab> createState() => _ItemsTabState();
}

class _ItemsTabState extends ConsumerState<ItemsTab> {
  Object? _syncError;

  Future<void> _refresh() async {
    Object? error;
    try {
      await ref.read(ledgerProvider.notifier).sync();
    } catch (e) {
      error = e;
    }
    if (mounted) setState(() => _syncError = error);
  }

  @override
  Widget build(BuildContext context) {
    final ledger = ref.watch(ledgerProvider);
    final now = ref.watch(assetClockProvider)();
    final sort = ref.watch(assetSortProvider);
    final banner = SyncErrorBanner(error: _syncError, onRetry: _refresh);

    return RefreshIndicator(
      onRefresh: _refresh,
      child: LayoutBuilder(
        builder: (context, box) => AsyncValueView<LedgerData>(
          value: ledger,
          loading: const SkeletonList(rows: 5),
          onRetry: () => ref.invalidate(ledgerProvider),
          data: (data) {
            final assets = data.activeAssets;
            if (assets.isEmpty) {
              return ListView(
                children: [
                  banner,
                  const SizedBox(height: 40),
                  EmptyState(
                    title: '还没记物品',
                    message: '手机、家电、车……记下买价，看看每天花多少。',
                    icon: Icons.inventory_2_outlined,
                    actionLabel: '记一件',
                    onAction: () => context.push('/assets/items/new'),
                  ),
                ],
              );
            }
            final held = sortAssets(assets.where((a) => a.isHeld), sort, now);
            final ended = sortAssets(assets.where((a) => a.isEnded), sort, now);
            return ListView(
              padding: readableInsets(box.maxWidth).copyWith(bottom: 96),
              children: [
                banner,
                _Summary(summary: summarizeAssets(assets, now)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    LedgerLayout.pagePadding,
                    0,
                    LedgerLayout.pagePadding,
                    4,
                  ),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final entry in _sortLabels.entries)
                        ChoiceChip(
                          label: Text(entry.value),
                          selected: sort == entry.key,
                          onSelected: (_) => ref
                              .read(assetSortProvider.notifier)
                              .state = entry.key,
                        ),
                    ],
                  ),
                ),
                for (final asset in held) AssetTile(asset: asset, now: now),
                if (ended.isNotEmpty) ...[
                  const SizedBox(height: LedgerLayout.groupGap),
                  const SectionHeader('已退役 · 已卖出'),
                  for (final asset in ended) AssetTile(asset: asset, now: now),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.summary});

  final AssetSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LedgerLayout.pagePadding,
        LedgerLayout.pagePadding,
        LedgerLayout.pagePadding,
        LedgerLayout.itemGap,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('每天花费', style: theme.textTheme.bodySmall),
          const SizedBox(height: 2),
          if (summary.isEmpty)
            Text('东西都退役或卖掉了', style: theme.textTheme.titleMedium)
          else
            DailyMoney(summary.dailyCents, size: MoneySize.display),
          const SizedBox(height: 4),
          Text(
            summary.isEmpty
                ? '在用的物品每天花多少，会在这里合计'
                : '在用和闲置 ${summary.count} 件 · 原价合计 ${Money.format(summary.priceCents)}',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// 一件物品：分类图标、名字、用了几天、每天多少钱、状态。
class AssetTile extends StatelessWidget {
  const AssetTile({super.key, required this.asset, required this.now});

  final Asset asset;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final usage = assetUsage(asset, now);
    final expected = asset.expectedDays;
    final days = expected == null
        ? '${asset.isEnded ? '用了' : '已用'} ${usage.days} 天'
        : '${asset.isEnded ? '用了' : '已用'} ${usage.days} / $expected 天';
    return ListTile(
      key: ValueKey('asset-${asset.id}'),
      onTap: () => context.push('/assets/items/${asset.id}'),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: LedgerLayout.pagePadding,
        vertical: 4,
      ),
      leading: AssetAvatar(
        assetCategoryIcon(asset.category),
        muted: asset.isEnded,
      ),
      title: Text(
        asset.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyLarge,
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Row(
          children: [
            Flexible(
              child: Text(
                days,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
            if (asset.status != Asset.statusInUse) ...[
              const SizedBox(width: 6),
              TagLabel(
                asset.statusLabel,
                tone: asset.status == Asset.statusIdle
                    ? TagTone.warning
                    : TagTone.neutral,
              ),
            ],
          ],
        ),
      ),
      trailing: DailyMoney(usage.dailyCents, muted: asset.isEnded),
    );
  }
}
