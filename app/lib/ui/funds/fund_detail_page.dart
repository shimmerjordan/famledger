import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/shell.dart';
import '../../app/theme.dart';
import '../../core/colors.dart';
import '../../core/money.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../analysis/trend_chart.dart' show compactYuan;
import '../assets/asset_providers.dart' show refreshMoneyViews;
import '../transactions/tx_providers.dart';
import '../transactions/tx_tile.dart';
import '../widgets/widgets.dart';
import 'allocate_sheet.dart';
import 'fund_calibrate_sheet.dart';
import 'fund_progress.dart';
import 'fund_providers.dart';

/// 板块详情：余额（能校准）、目标/预算、本月类别构成、近 6 月趋势、最近流水、拨款；归档 / 恢复、删除。
class FundDetailPage extends ConsumerWidget {
  const FundDetailPage(this.id, {super.key});

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ledger = ref.watch(ledgerProvider).valueOrNull;
    final fund = ledger?.fund(id);
    final stats = ref.watch(fundStatsProvider(id));
    final wide = widthClassOf(context) == WidthClass.expanded;

    if (ledger != null && fund == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('财富')),
        body: const InlineError(message: '这个板块已经不在了。'),
      );
    }

    final index = fund == null ? 0 : ledger!.fundIndex(fund.id);
    final color = fundColorOf(context, fund, index < 0 ? 0 : index);

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            FundDot(color: color, size: 10),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                fund?.name ?? '板块',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '编辑',
            onPressed: fund == null ? null : () => context.push('/funds/$id/edit'),
            icon: const Icon(Icons.edit_outlined),
          ),
          if (fund != null)
            PopupMenuButton<String>(
              key: const ValueKey('fund-menu'),
              tooltip: '更多',
              onSelected: (action) => switch (action) {
                'calibrate' => _calibrate(context, ref, fund),
                'archive' => _setArchived(context, ref, fund, !fund.archived),
                _ => _delete(context, ref, fund),
              },
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'calibrate', child: Text('校准余额')),
                PopupMenuItem(
                  key: const ValueKey('fund-archive'),
                  value: 'archive',
                  child: Text(fund.archived ? '恢复（取消归档）' : '归档'),
                ),
                const PopupMenuItem(key: ValueKey('fund-delete'), value: 'delete', child: Text('删除')),
              ],
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(fundStatsProvider(id));
          ref.invalidate(fundTrendProvider(id));
          await ref.read(ledgerProvider.notifier).sync();
        },
        // 宽屏整块限宽：主栏的环图图例、柱图别拉到 1000 多宽。
        child: ReadableBox(
          maxWidth: 1120,
          child: AdaptiveTwoPane(
          main: ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              if (fund != null && fund.archived)
                MaterialBanner(
                  key: const ValueKey('fund-archived-banner'),
                  content: const Text('这个板块已归档：记账时不再出现，余额照算。'),
                  actions: [
                    TextButton(
                      onPressed: () => _setArchived(context, ref, fund, false),
                      child: const Text('恢复'),
                    ),
                  ],
                ),
              _Balance(
                fund: fund,
                stats: stats.valueOrNull,
                color: color,
                onCalibrate: fund == null ? null : () => _calibrate(context, ref, fund),
              ),
              if (stats.hasError)
                InlineError(
                  message: describeError(stats.error!),
                  onRetry: () => ref.invalidate(fundStatsProvider(id)),
                  padding: const EdgeInsets.all(LedgerLayout.pagePadding),
                ),
              if (!wide && fund != null)
                ..._sideContent(context, ref, fund, ledger!, color),
              const SectionHeader('本月构成'),
              _CategoryDonut(stats: stats, ledger: ledger),
              const SizedBox(height: LedgerLayout.groupGap),
              const SectionHeader('近 6 个月'),
              _Trend(fundId: id, color: color),
              const SizedBox(height: LedgerLayout.groupGap),
              SectionHeader(
                '最近流水',
                actionLabel: '全部',
                // 账单是底部 tab：切过去（push 会再叠一个外壳），筛好这个板块。
                onAction: () {
                  ref.read(txFilterProvider.notifier).state = TxFilter(fundId: id, limit: TxListController.pageSize);
                  context.go('/transactions');
                },
              ),
              _Recent(stats: stats, ledger: ledger),
            ],
          ),
          side: wide && fund != null
              ? ListView(
                  padding: const EdgeInsets.only(top: 8, bottom: 96),
                  children: _sideContent(context, ref, fund, ledger!, color),
                )
              : null,
          ),
        ),
      ),
    );
  }

  Future<void> _calibrate(BuildContext context, WidgetRef ref, Fund fund) async {
    final base = ref.read(baseCurrencyProvider);
    final stats = ref.read(fundStatsProvider(id)).valueOrNull;
    await showFundCalibrateSheet(context, fund: fund, balances: stats?.amounts(base) ?? const CurrencyAmounts());
  }

  Future<void> _setArchived(BuildContext context, WidgetRef ref, Fund fund, bool archived) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(ledgerRepoProvider).updateFund(fund.id, {'archived': archived});
      ref.invalidate(ledgerProvider);
      refreshMoneyViews(ref);
      messenger.showSnackBar(SnackBar(content: Text(archived ? '已归档「${fund.name}」' : '「${fund.name}」恢复了')));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(describeError(error))));
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, Fund fund) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删掉「${fund.name}」？'),
        content: const Text('只能删还没有流水的板块；有流水的可以「归档」，余额照算、记账时不再出现。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('算了')),
          FilledButton(
            key: const ValueKey('fund-delete-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删掉'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(ledgerRepoProvider).deleteFund(fund.id);
      ref.invalidate(ledgerProvider);
      refreshMoneyViews(ref);
      messenger.showSnackBar(SnackBar(content: Text('已删掉「${fund.name}」')));
      if (!context.mounted) return;
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/funds');
      }
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(describeError(error))));
    }
  }

  /// 目标/预算 + 操作。宽屏在右栏，窄屏接在余额下面。
  List<Widget> _sideContent(
    BuildContext context,
    WidgetRef ref,
    Fund fund,
    LedgerData ledger,
    Color color,
  ) {
    final stats = ref.watch(fundStatsProvider(id)).valueOrNull;
    final progress = FundProgress(
      balanceCents: stats?.balanceCents ?? 0,
      monthExpenseCents: stats?.monthExpenseCents ?? 0,
      monthIncomeCents: stats?.monthIncomeCents ?? 0,
      targetCents: stats?.targetCents ?? fund.targetCents,
      budgetCents: stats?.budgetCents ?? fund.monthlyBudgetCents,
    );
    return [
      const SectionHeader('目标与预算'),
      Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LedgerLayout.pagePadding,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (progress.hasBar)
              FundProgressBar(progress: progress, color: color)
            else
              Text(
                '还没设目标或月预算。设一个，首页才能提醒你。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            const SizedBox(height: LedgerLayout.itemGap),
            // 三个按钮按内容宽度排，放不下就换行（宽屏右栏只有 360 宽，等分会把字挤成两三行）。
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: () async {
                    final done = await showAllocateSheet(
                      context,
                      from: fund,
                      funds: ledger.activeFunds,
                    );
                    if (done == true) ref.invalidate(fundStatsProvider(id));
                  },
                  icon: const Icon(Icons.swap_horiz, size: 18),
                  label: const Text('拨款'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('fund-calibrate'),
                  onPressed: () => _calibrate(context, ref, fund),
                  icon: const Icon(Icons.edit_note, size: 18),
                  label: const Text('校准余额'),
                ),
                OutlinedButton.icon(
                  onPressed: () => context.push('/funds/$id/edit'),
                  icon: const Icon(Icons.tune, size: 18),
                  label: const Text('目标/预算'),
                ),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: LedgerLayout.groupGap),
    ];
  }
}

class _Balance extends ConsumerWidget {
  const _Balance({required this.color, this.fund, this.stats, this.onCalibrate});

  final Fund? fund;
  final FundStats? stats;
  final Color color;

  /// 点余额 = 校准（填现在实际有多少）。
  final VoidCallback? onCalibrate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // 余额按币种分开（板块没有币种）；本月支出/收入是跨实体聚合，服务端已折到基准币。
    final base = ref.watch(baseCurrencyProvider);
    final ledger = ref.watch(ledgerProvider).valueOrNull;
    final f = fund;
    final incomeAccount = f != null && f.hasMonthlyIncome ? ledger?.account(f.incomeAccountId) : null;
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
          Text('余额', style: theme.textTheme.bodySmall),
          const SizedBox(height: 2),
          if (stats == null)
            const Skeleton(width: 180, height: 30)
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Flexible(child: CurrencyTotal(stats!.amounts(base), size: MoneySize.display)),
                if (onCalibrate != null)
                  IconButton(
                    key: const ValueKey('fund-balance-edit'),
                    tooltip: '校准余额',
                    visualDensity: VisualDensity.compact,
                    onPressed: onCalibrate,
                    icon: Icon(Icons.edit_outlined, size: 18, color: theme.colorScheme.onSurfaceVariant),
                  ),
              ],
            ),
          const SizedBox(height: LedgerLayout.itemGap),
          Row(
            children: [
              Text('本月支出 ', style: theme.textTheme.bodySmall),
              MultiCurrencyAmount(
                -(stats?.monthExpenseCents ?? 0),
                currency: base,
                size: MoneySize.small,
              ),
              const SizedBox(width: LedgerLayout.pagePadding),
              Text('收入 ', style: theme.textTheme.bodySmall),
              MultiCurrencyAmount(
                stats?.monthIncomeCents ?? 0,
                currency: base,
                size: MoneySize.small,
                signed: true,
              ),
            ],
          ),
          if (f != null && f.hasMonthlyIncome) ...[
            const SizedBox(height: 8),
            Row(
              key: const ValueKey('fund-income-rule'),
              children: [
                Icon(Icons.autorenew, size: 14, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    '每月 ${f.incomeDay ?? 1} 号自动进账 '
                    '${Money.format(f.monthlyIncomeCents!, currency: incomeAccount?.currency ?? base)}'
                    '${incomeAccount == null ? '' : ' → ${incomeAccount.name}'}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
          if (fund?.description != null && fund!.description!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(fund!.description!, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

/// 本月支出的类别构成：环形 + 图例（图例带金额，不靠猜颜色）。
class _CategoryDonut extends ConsumerWidget {
  const _CategoryDonut({required this.stats, this.ledger});

  final AsyncValue<FundStats> stats;
  final LedgerData? ledger;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final base = ref.watch(baseCurrencyProvider);
    final data = stats.valueOrNull;
    if (data == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
        child: Skeleton(height: 160, radius: LedgerShapes.card),
      );
    }
    final rows = data.byCategory.where((c) => c.expenseCents > 0).toList()
      ..sort((a, b) => b.expenseCents.compareTo(a.expenseCents));
    if (rows.isEmpty) {
      return const EmptyState(
        title: '本月还没有支出',
        message: '这个板块这个月一分没动。',
        compact: true,
      );
    }
    final total = rows.fold<int>(0, (sum, row) => sum + row.expenseCents);
    final palette = LedgerColors.of(context).fundPalette;
    final slices = <(String, int, Color)>[];
    for (var i = 0; i < rows.length && i < 6; i++) {
      final category = ledger?.category(rows[i].categoryId);
      slices.add((
        category?.name ?? '未分类',
        rows[i].expenseCents,
        hexColor(category?.color) ?? palette[i % palette.length],
      ));
    }
    if (rows.length > 6) {
      final rest = rows.skip(6).fold<int>(0, (sum, row) => sum + row.expenseCents);
      slices.add(('其他', rest, theme.colorScheme.onSurfaceVariant));
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 140,
            height: 140,
            child: PieChart(
              PieChartData(
                sectionsSpace: 2,
                centerSpaceRadius: 38,
                sections: [
                  for (final slice in slices)
                    PieChartSectionData(
                      value: slice.$2.toDouble(),
                      color: slice.$3,
                      radius: 22,
                      showTitle: false,
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: LedgerLayout.pagePadding),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final slice in slices)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        FundDot(color: slice.$3),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            slice.$1,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                        MultiCurrencyAmount(slice.$2, currency: base, size: MoneySize.small),
                        const SizedBox(width: 6),
                        SizedBox(
                          width: 34,
                          child: Text(
                            '${(slice.$2 * 100 / total).round()}%',
                            textAlign: TextAlign.right,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
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

/// 近 6 个月的支出/收入柱状。
class _Trend extends ConsumerWidget {
  const _Trend({required this.fundId, required this.color});

  final String fundId;
  final Color color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final ledgerColors = LedgerColors.of(context);
    final trend = ref.watch(fundTrendProvider(fundId));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
      child: AsyncValueView<TrendSeries>(
        value: trend,
        loading: const Skeleton(height: 160, radius: LedgerShapes.card),
        onRetry: () => ref.invalidate(fundTrendProvider(fundId)),
        errorPadding: EdgeInsets.zero,
        data: (series) {
          if (series.isEmpty || series.maxCents == 0) {
            return const EmptyState(
              title: '还没有足够的数据',
              message: '记满一个月就能看出趋势了。',
              compact: true,
            );
          }
          final points = series.series.length > 6
              ? series.series.sublist(series.series.length - 6)
              : series.series;
          var maxCents = 0;
          for (final p in points) {
            if (p.expenseCents > maxCents) maxCents = p.expenseCents;
            if (p.incomeCents > maxCents) maxCents = p.incomeCents;
          }
          // 纵轴给两道刻度（半、满）：光有柱子没有数，高矮只能靠猜。
          final maxY = (maxCents == 0 ? 100 : maxCents * 1.15).toDouble();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 160,
                child: BarChart(
                  BarChartData(
                    alignment: BarChartAlignment.spaceAround,
                    maxY: maxY,
                    minY: 0,
                    gridData: FlGridData(
                      drawVerticalLine: false,
                      horizontalInterval: maxY / 2,
                      getDrawingHorizontalLine: (_) => FlLine(
                        color: theme.colorScheme.outlineVariant,
                        strokeWidth: 1,
                      ),
                    ),
                    borderData: FlBorderData(show: false),
                    barTouchData: BarTouchData(enabled: false),
                    titlesData: FlTitlesData(
                      leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 44,
                          interval: maxY / 2,
                          getTitlesWidget: (value, meta) => SideTitleWidget(
                            meta: meta,
                            child: Text(compactYuan(value), style: theme.textTheme.bodySmall),
                          ),
                        ),
                      ),
                      rightTitles: const AxisTitles(),
                      topTitles: const AxisTitles(),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 26,
                          getTitlesWidget: (value, meta) {
                            final i = value.toInt();
                            if (i < 0 || i >= points.length) {
                              return const SizedBox.shrink();
                            }
                            return Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                '${int.parse(points[i].month.split('-')[1])}月',
                                style: theme.textTheme.bodySmall,
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    barGroups: [
                      for (var i = 0; i < points.length; i++)
                        BarChartGroupData(
                          x: i,
                          barsSpace: 4,
                          barRods: [
                            BarChartRodData(
                              toY: points[i].expenseCents.toDouble(),
                              color: color,
                              width: 10,
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(3),
                              ),
                            ),
                            BarChartRodData(
                              toY: points[i].incomeCents.toDouble(),
                              color: ledgerColors.income,
                              width: 10,
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(3),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  FundDot(color: color),
                  const SizedBox(width: 6),
                  Text('支出', style: theme.textTheme.bodySmall),
                  const SizedBox(width: LedgerLayout.itemGap),
                  FundDot(color: ledgerColors.income),
                  const SizedBox(width: 6),
                  Text('收入', style: theme.textTheme.bodySmall),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Recent extends StatelessWidget {
  const _Recent({required this.stats, this.ledger});

  final AsyncValue<FundStats> stats;
  final LedgerData? ledger;

  @override
  Widget build(BuildContext context) {
    final data = stats.valueOrNull;
    if (data == null) return const SkeletonList(rows: 3);
    if (data.recent.isEmpty) {
      return const EmptyState(
        title: '这个板块还没有流水',
        message: '记一笔时选中它就会出现在这里。',
        compact: true,
      );
    }
    return Column(
      children: [
        for (final tx in data.recent)
          TxTile(
            tx: tx,
            ledger: ledger,
            onTap: () => context.push('/transactions/${tx.id}'),
          ),
      ],
    );
  }
}
