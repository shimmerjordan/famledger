import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../core/money.dart';
import '../../data/models/models.dart';
import '../perk_import/ai_inferred_dot.dart';
import '../widgets/widgets.dart';
import 'asset_providers.dart';
import 'asset_widgets.dart';
import 'sell_sheet.dart';

/// 物品详情：每天花多少、离预期还有多远、现在值多少；标记闲置、退役、卖出、编辑、删除。
class AssetDetailPage extends ConsumerStatefulWidget {
  const AssetDetailPage(this.id, {super.key});

  final String id;

  @override
  ConsumerState<AssetDetailPage> createState() => _AssetDetailPageState();
}

class _AssetDetailPageState extends ConsumerState<AssetDetailPage> {
  bool _busy = false;
  String? _error;

  /// 删掉时本地先拿掉、同步完才退出去，这中间照旧画删之前的样子，不闪「已经不在了」。
  bool _deleting = false;
  Asset? _last;

  Future<void> _run(Future<void> Function() action, {String? done}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (!mounted) return;
      if (done != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = describeError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setStatus(String status, String done) => _run(
    () => ref.read(assetsRepoProvider).setStatus(widget.id, status),
    done: done,
  );

  Future<void> _retire(Asset asset) async {
    final day = await pickPastDay(
      context,
      initial: DateTime.now(),
      first: localDate(asset.purchasedOn),
      help: '哪天退役的',
    );
    if (day == null || !mounted) return;
    await _run(
      () => ref.read(assetsRepoProvider).retire(widget.id, endedOn: Dates.isoDate(day)),
      done: '已退役，天数停在这天',
    );
  }

  Future<void> _sell(Asset asset) async {
    setState(() => _error = null);
    await showSellSheet(context, asset);
  }

  Future<void> _delete(Asset asset) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删掉「${asset.name}」？'),
        content: const Text('只删这条物品记录，买入/卖出时记的流水还在。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('算了'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删掉'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _busy = true;
      _deleting = true;
    });
    try {
      await ref.read(assetsRepoProvider).delete(widget.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已删掉')),
      );
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/assets');
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _deleting = false;
        _error = describeError(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ledger = ref.watch(ledgerProvider).valueOrNull;
    final live = ledger?.asset(widget.id);
    if (live != null) _last = live;
    final asset = live ?? (_deleting ? _last : null);
    if (ledger == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('物品')),
        body: const SkeletonList(rows: 5),
      );
    }
    if (asset == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('物品')),
        body: const InlineError(message: '这件物品已经不在了。'),
      );
    }
    final now = ref.watch(assetClockProvider)();
    final usage = assetUsage(asset, now);

    return Scaffold(
      appBar: AppBar(
        title: Text(asset.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '编辑',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => context.push('/assets/items/${asset.id}/edit'),
          ),
          IconButton(
            tooltip: '删除',
            icon: const Icon(Icons.delete_outline),
            onPressed: _busy ? null : () => _delete(asset),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, box) => ListView(
          padding: readableInsets(box.maxWidth, maxWidth: 720)
              .copyWith(bottom: 96),
          children: [
            _Hero(asset: asset, usage: usage),
            ..._valuation(context, asset, now),
            ..._details(context, asset, usage),
            const SizedBox(height: LedgerLayout.groupGap),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: LedgerLayout.pagePadding,
              ),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _actions(asset),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  LedgerLayout.pagePadding,
                  LedgerLayout.itemGap,
                  LedgerLayout.pagePadding,
                  0,
                ),
                child: Text(
                  _error!,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _actions(Asset asset) {
    final off = _busy;
    final idle = FilledButton.tonal(
      onPressed: off
          ? null
          : () => _setStatus(Asset.statusIdle, '已标记闲置，还照样算天数'),
      child: const Text('标记闲置'),
    );
    final back = FilledButton.tonal(
      onPressed: off
          ? null
          : () => _setStatus(Asset.statusInUse, '又用上了'),
      child: Text(asset.status == Asset.statusSold ? '撤销卖出' : '恢复在用'),
    );
    final retire = OutlinedButton(
      onPressed: off ? null : () => _retire(asset),
      child: const Text('退役'),
    );
    final sell = OutlinedButton(
      onPressed: off ? null : () => _sell(asset),
      child: const Text('卖出'),
    );
    return switch (asset.status) {
      Asset.statusInUse => [idle, retire, sell],
      Asset.statusIdle => [back, retire, sell],
      Asset.statusRetired => [back, sell],
      _ => [back],
    };
  }

  /// 估值卡（spec §5）：现在估值与较原价、怎么算的、1/2/3 年后、计入净资产；
  /// 卖掉或退役的估值归零，只给处置盈亏（只展示，不记账）。
  List<Widget> _valuation(BuildContext context, Asset asset, DateTime now) {
    final theme = Theme.of(context);
    Widget note(String text, {Key? key}) => Padding(
      key: key,
      padding: const EdgeInsets.fromLTRB(
        LedgerLayout.pagePadding,
        0,
        LedgerLayout.pagePadding,
        8,
      ),
      child: Text(text, style: theme.textTheme.bodySmall),
    );

    if (asset.isEnded) {
      final gain = disposalGain(asset);
      final endedAt = endedValue(asset);
      if (gain == null || endedAt == null) return const [];
      final at = Money.format(endedAt);
      final String how;
      if (asset.status == Asset.statusSold) {
        how = '卖出价 − 卖出那天的估值 $at，只展示，不记账';
      } else if (asset.saleCents == null) {
        how = '退役没卖钱：少了退役那天的估值 $at，只展示，不记账';
      } else {
        how = '卖出价 − 退役那天的估值 $at，只展示，不记账';
      }
      return [
        const SectionHeader('估值'),
        InfoRow('处置盈亏', MoneyText(gain, signed: true)),
        note(how),
        const SizedBox(height: LedgerLayout.itemGap),
      ];
    }

    final value = currentValue(asset, now);
    final change = valueChangeLabel(value, asset.priceCents);
    final stale = anchorStaleMonths(asset, now);
    // 总开关的原始值在家庭设置里（有本地缓存）；还没拉到就按默认的「开」。
    final switchOn =
        ref.watch(settingsProvider).valueOrNull?.assets.netWorthIncludesPhysical ?? true;
    // 不折旧的东西 1/2/3 年后还是这个数，不列。
    final forecast = resolveValuation(asset).method == Asset.methodLocked
        ? const <int>[]
        : valueForecast(asset, now);
    return [
      const SectionHeader('估值'),
      InfoRow(
        '现在估值',
        // 大字号时标签、较原价和金额放不下一行就折到下一行（Row 会溢出）。
        Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 6,
          runSpacing: 4,
          children: [
            if (valuationUncertain(asset)) const TagLabel('估值不确定', tone: TagTone.warning),
            if (change != null) Text(change, style: theme.textTheme.bodySmall),
            MoneyText(value),
          ],
        ),
      ),
      note(valuationExplain(asset), key: const ValueKey('valuation-explain')),
      // 一整句提醒会折行（长辈大字号也不丢字），后面直接给去改的入口。
      if (stale != null)
        Padding(
          key: const ValueKey('valuation-stale'),
          padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 0, 8, 8),
          child: Row(
            children: [
              Icon(Icons.update, size: 16, color: LedgerColors.of(context).warning),
              const SizedBox(width: 6),
              Expanded(
                child: Text('估值已 $stale 个月没更新', style: theme.textTheme.bodySmall),
              ),
              TextButton(
                onPressed: () => context.push('/assets/items/${asset.id}/edit'),
                child: const Text('更新估值'),
              ),
            ],
          ),
        ),
      for (var i = 0; i < forecast.length; i++)
        InfoRow('${i + 1} 年后', MoneyText(forecast[i], muted: true)),
      InfoRow('计入净资产', InfoText(netWorthLabel(asset, switchOn: switchOn))),
      if (!switchOn && countsInNetWorth(asset))
        note(
          '资产页顶上净资产里的「实物计入净资产」关着，打开后这件就计入',
          key: const ValueKey('valuation-networth-switch-off'),
        ),
      const SizedBox(height: LedgerLayout.itemGap),
    ];
  }

  /// 值后面跟一个「AI 推断」小点（这个字段是导入时推断、还没确认的）。
  Widget _withDot(Asset asset, Widget value, String field) {
    if (inferredOf(asset.origin, [field]).isEmpty) return value;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: value),
        AiInferredDot(
          key: ValueKey('ai-dot-$field'),
          fields: [field],
          origin: asset.origin,
          onConfirm: (ref, origin) => ref.read(assetsRepoProvider).update(asset.id, {'origin': origin}),
          onEdit: () => context.push('/assets/items/${asset.id}/edit'),
        ),
      ],
    );
  }

  List<Widget> _details(BuildContext context, Asset asset, AssetUsage usage) {
    final purchased = localDate(asset.purchasedOn);
    final ended = localDate(asset.endedOn);
    return [
      const SectionHeader('明细'),
      InfoRow(asset.isEnded ? '用了' : '已用', InfoText('${usage.days} 天')),
      InfoRow('买价', _withDot(asset, MoneyText(asset.priceCents), 'priceCents')),
      if (purchased != null) InfoRow('买入', _withDot(asset, InfoText(Dates.dayLabel(purchased)), 'purchasedOn')),
      if (asset.expectedDays != null)
        InfoRow('打算用', InfoText('${asset.expectedDays} 天')),
      if (ended != null)
        InfoRow(
          asset.status == Asset.statusSold ? '卖出' : '退役',
          InfoText(Dates.dayLabel(ended)),
        ),
      if (asset.saleCents != null)
        InfoRow('卖出价', MoneyText(asset.saleCents!)),
      if (asset.note != null && asset.note!.isNotEmpty)
        InfoRow('备注', InfoText(asset.note!)),
      if (asset.transactionId != null)
        InfoRow(
          '买入那笔支出',
          TextButton(
            onPressed: () => context.push('/transactions/${asset.transactionId}'),
            child: const Text('查看'),
          ),
        ),
      if (asset.saleTransactionId != null)
        InfoRow(
          '卖出那笔收入',
          TextButton(
            onPressed: () =>
                context.push('/transactions/${asset.saleTransactionId}'),
            child: const Text('查看'),
          ),
        ),
    ];
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.asset, required this.usage});

  final Asset asset;
  final AssetUsage usage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ledger = LedgerColors.of(context);
    final target = usage.targetDailyCents;
    final progress = usage.progress;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LedgerLayout.pagePadding,
        LedgerLayout.pagePadding,
        LedgerLayout.pagePadding,
        LedgerLayout.groupGap,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AssetAvatar(
                assetCategoryIcon(asset.category),
                muted: asset.isEnded,
              ),
              const SizedBox(width: LedgerLayout.itemGap),
              Expanded(
                child: Text(
                  '${asset.categoryLabel} · ${asset.statusLabel}',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: LedgerLayout.itemGap),
          Text(
            asset.isEnded ? '平均每天花了' : '每天花费',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 2),
          DailyMoney(usage.dailyCents, size: MoneySize.display),
          if (usage.dailyCents < 0) ...[
            const SizedBox(height: 4),
            Text('卖得比买得贵，这件是赚的', style: theme.textTheme.bodySmall),
          ],
          if (target != null && progress != null) ...[
            const SizedBox(height: LedgerLayout.itemGap),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress > 1 ? 1 : progress,
                minHeight: 6,
                backgroundColor: ledger.surface3,
                color: progress >= 1 ? ledger.income : theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              progress >= 1
                  ? '已经用够预期的 ${asset.expectedDays} 天，目标 ${dailyLabel(target)}'
                  : '用到预期 ${(progress * 100).floor()}% · 用满时 ${dailyLabel(target)}',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}
