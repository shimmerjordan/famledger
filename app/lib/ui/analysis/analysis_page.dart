import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/shell.dart';
import '../../app/theme.dart';
import '../../core/colors.dart';
import '../../core/dates.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../widgets/widgets.dart';
import 'category_donut.dart';
import 'chart_legend.dart';
import 'member_bars.dart';
import 'month_picker.dart';
import 'trend_chart.dart';

/// 截至某个月（含）往前 12 个月的收支趋势，跟着月份选择器走：翻到去年某月，
/// 柱状图也切到以那个月收尾的 12 根，而不是永远画「最近 12 个月」。
final trendProvider = FutureProvider.autoDispose.family<TrendSeries, String>(
  (ref, endMonth) => ref.watch(statsRepoProvider).trend(endMonth: endMonth),
);

/// 分析：这个月钱去哪了、跟上个月比怎么样、谁花的、哪个基金花的。
class AnalysisPage extends ConsumerStatefulWidget {
  const AnalysisPage({super.key});

  @override
  ConsumerState<AnalysisPage> createState() => _AnalysisPageState();
}

class _AnalysisPageState extends ConsumerState<AnalysisPage> {
  String _month = Dates.currentMonth();

  @override
  Widget build(BuildContext context) {
    final stats = ref.watch(statsProvider(_month));
    final previous = ref.watch(statsProvider(Dates.shiftMonth(_month, -1)));
    final trend = ref.watch(trendProvider(_month));
    final ledger = ref.watch(ledgerProvider).valueOrNull ?? const LedgerData();
    final overview = stats.valueOrNull;
    final prevOverview = previous.valueOrNull;

    final main = <Widget>[
      MonthPicker(
        month: _month,
        onChanged: (value) => setState(() => _month = value),
      ),
      _Summary(stats: stats),
      const _AiActions(),
      const SizedBox(height: LedgerLayout.groupGap),
      SectionHeader(
        _month == Dates.currentMonth() ? '最近 12 个月' : '截至 ${Dates.monthLabel(_month)} 的 12 个月',
      ),
      AsyncValueView<TrendSeries>(
        value: trend,
        loading: const _ChartSkeleton(height: 180),
        onRetry: () => ref.invalidate(trendProvider(_month)),
        data: (data) => TrendChart(series: data.series),
      ),
      const SizedBox(height: LedgerLayout.groupGap),
      const SectionHeader('类别构成'),
      AsyncValueView<StatsOverview>(
        value: stats,
        loading: const _ChartSkeleton(height: 176),
        onRetry: () => ref.read(statsProvider(_month).notifier).refresh(),
        data: (data) => CategoryDonut(
          slices: _categorySlices(context, ledger, data, prevOverview),
          totalCents: data.month.expenseCents,
        ),
      ),
    ];

    final side = <Widget>[
      const SizedBox(height: LedgerLayout.groupGap),
      const SectionHeader('类别排行'),
      if (overview == null)
        const SkeletonList(rows: 4)
      else
        CategoryRankedList(
          slices: _categorySlices(context, ledger, overview, prevOverview),
          totalCents: overview.month.expenseCents,
        ),
      const SizedBox(height: LedgerLayout.groupGap),
      const SectionHeader('成员对比'),
      if (overview == null)
        const SkeletonList(rows: 3)
      else
        ShareBars(
          items: _memberSlices(context, ledger, overview),
          totalCents: overview.month.expenseCents,
          emptyTitle: '这个月还没人花钱',
          emptyMessage: '记一笔之后，这里按成员比一比。',
        ),
      const SizedBox(height: LedgerLayout.groupGap),
      const SectionHeader('基金占比'),
      if (overview == null)
        const SkeletonList(rows: 3)
      else
        ShareBars(
          items: _fundSlices(context, ledger, overview),
          totalCents: overview.month.expenseCents,
          emptyTitle: '这个月各基金都没动',
          emptyMessage: '支出记到基金上，才看得出哪个模块花得多。',
        ),
      const SizedBox(height: 32),
    ];

    final wide = widthClassOf(context) == WidthClass.expanded;
    return Scaffold(
      appBar: AppBar(title: const Text('分析')),
      body: wide
          ? AdaptiveTwoPane(
              main: ListView(children: main),
              side: ListView(children: side),
            )
          : ListView(children: [...main, ...side]),
    );
  }
}

/// 本月支出/收入/结余。
class _Summary extends StatelessWidget {
  const _Summary({required this.stats});

  final AsyncValue<StatsOverview> stats;

  @override
  Widget build(BuildContext context) {
    final month = stats.valueOrNull?.month;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LedgerLayout.pagePadding,
        8,
        LedgerLayout.pagePadding,
        0,
      ),
      child: Row(
        children: [
          _SummaryCell(label: '支出', cents: month?.expenseCents),
          _SummaryCell(label: '收入', cents: month?.incomeCents, signed: true),
          _SummaryCell(label: '结余', cents: month?.netCents, signed: true),
        ],
      ),
    );
  }
}

class _SummaryCell extends StatelessWidget {
  const _SummaryCell({
    required this.label,
    required this.cents,
    this.signed = false,
  });

  final String label;
  final int? cents;
  final bool signed;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 4),
        if (cents == null)
          const Skeleton(width: 72, height: 18)
        else
          MoneyText(cents!, signed: signed),
      ],
    ),
  );
}

/// 两个 AI 入口：月报是「读给我听」，对话是「我来问」。
class _AiActions extends StatelessWidget {
  const _AiActions();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      LedgerLayout.pagePadding,
      LedgerLayout.pagePadding,
      LedgerLayout.pagePadding,
      0,
    ),
    child: Row(
      children: [
        FilledButton.tonalIcon(
          onPressed: () => context.push('/ai/report'),
          icon: const Icon(Icons.auto_stories_outlined, size: 18),
          label: const Text('AI 月报'),
        ),
        const SizedBox(width: LedgerLayout.itemGap),
        OutlinedButton.icon(
          onPressed: () => context.push('/ai/chat'),
          icon: const Icon(Icons.chat_bubble_outline, size: 18),
          label: const Text('问 AI'),
        ),
      ],
    ),
  );
}

/// 图表加载时的骨架：一块和图表一样高的灰面，不用转圈。
class _ChartSkeleton extends StatelessWidget {
  const _ChartSkeleton({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
    child: Skeleton(height: height, radius: LedgerShapes.card),
  );
}

/// 类别构成：按金额从大到小，颜色优先用类别自己的，否则按排名取 12 色盘。
List<AnalysisSlice> _categorySlices(
  BuildContext context,
  LedgerData ledger,
  StatsOverview overview,
  StatsOverview? previous,
) {
  final palette = LedgerColors.of(context);
  final prevById = <String, int>{
    if (previous != null)
      for (final c in previous.month.byCategory) c.categoryId: c.expenseCents,
  };
  final rows = overview.month.byCategory
      .where((c) => c.expenseCents > 0)
      .toList()
    ..sort((a, b) => b.expenseCents.compareTo(a.expenseCents));

  return [
    for (var i = 0; i < rows.length; i++)
      () {
        final category = ledger.category(rows[i].categoryId);
        return AnalysisSlice(
          id: rows[i].categoryId,
          label: category?.name ?? '未分类',
          cents: rows[i].expenseCents,
          color: hexColor(category?.color) ?? palette.fundColor(i),
          icon: category?.icon,
          previousCents:
              previous == null ? null : (prevById[rows[i].categoryId] ?? 0),
        );
      }(),
  ];
}

List<AnalysisSlice> _memberSlices(
  BuildContext context,
  LedgerData ledger,
  StatsOverview overview,
) {
  final palette = LedgerColors.of(context);
  final rows = overview.month.byMember
      .where((m) => m.expenseCents > 0)
      .toList()
    ..sort((a, b) => b.expenseCents.compareTo(a.expenseCents));

  return [
    for (var i = 0; i < rows.length; i++)
      () {
        final member = ledger.member(rows[i].memberId);
        return AnalysisSlice(
          id: rows[i].memberId,
          label: member?.label ?? '未指定成员',
          cents: rows[i].expenseCents,
          color: hexColor(member?.color) ?? palette.fundColor(i),
        );
      }(),
  ];
}

List<AnalysisSlice> _fundSlices(
  BuildContext context,
  LedgerData ledger,
  StatsOverview overview,
) {
  final rows = overview.month.byFund
      .where((f) => f.expenseCents > 0)
      .toList()
    ..sort((a, b) => b.expenseCents.compareTo(a.expenseCents));

  return [
    for (final row in rows)
      () {
        final fund = ledger.fund(row.fundId);
        final index = ledger.fundIndex(row.fundId);
        return AnalysisSlice(
          id: row.fundId,
          label: fund?.name ?? '未指定基金',
          cents: row.expenseCents,
          color: fundColorOf(context, fund, index < 0 ? 0 : index),
          icon: fund?.icon,
        );
      }(),
  ];
}
