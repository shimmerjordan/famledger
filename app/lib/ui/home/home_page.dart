import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/shell.dart';
import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../core/money.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../transactions/tx_providers.dart';
import '../widgets/widgets.dart';
import 'fund_carousel.dart';
import 'month_summary.dart';
import 'pending_captures_card.dart';
import 'recent_list.dart';

/// 首页看的是哪个月（‹ › 切换，默认当月）。
final homeMonthProvider = StateProvider<String>((ref) => Dates.currentMonth());

/// 首页：本月合计 → 基金卡片 → 预算提醒 → 待确认 → 最近流水。
///
/// 宽屏时右侧栏接管「基金余额 + 待确认」，主栏只留合计与流水。
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  /// 下拉同步失败的原因。`LedgerController.state` 是 protected，页面没法把错误
  /// 写回 ledger 的 AsyncValue，所以自己记着，在页面顶上说清楚 + 给重试。
  Object? _syncError;

  /// 已经点过「确认」的那几条：服务端列表还没回来之前先从待确认里拿掉，
  /// 免得按钮点完没反应（离线时更明显——那次确认压根没发出去）。
  final Set<String> _confirmed = {};

  @override
  Widget build(BuildContext context) {
    final month = ref.watch(homeMonthProvider);
    final stats = ref.watch(statsProvider(month));
    final ledger = ref.watch(ledgerProvider);
    final wide = widthClassOf(context) == WidthClass.expanded;
    final data = ledger.valueOrNull;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: LedgerLayout.pagePadding - 8,
        title: MonthSwitcher(
          month: month,
          onChanged: (next) =>
              ref.read(homeMonthProvider.notifier).state = next,
        ),
      ),
      body: AdaptiveTwoPane(
        main: RefreshIndicator(
          onRefresh: () => _refresh(month),
          child: ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              if (_syncError != null)
                InlineError(
                  message: '同步失败：${describeError(_syncError!)}',
                  onRetry: () => _refresh(month),
                  padding: const EdgeInsets.fromLTRB(
                    LedgerLayout.pagePadding,
                    LedgerLayout.itemGap,
                    LedgerLayout.pagePadding,
                    0,
                  ),
                ),
              AsyncValueView<StatsOverview>(
                value: stats,
                loading: const MonthSummarySkeleton(),
                onRetry: () => ref.invalidate(statsProvider(month)),
                errorPadding: const EdgeInsets.all(LedgerLayout.pagePadding),
                data: (value) => MonthSummary(stats: value.month),
              ),
              if (!wide) ..._funds(context, data, stats.valueOrNull),
              ..._budgetAlerts(context, data, stats.valueOrNull),
              if (!wide) ..._pending(context, data, month),
              SectionHeader(
                '最近流水',
                actionLabel: '全部',
                onAction: () => context.go('/transactions'),
              ),
              _Recent(ledger: data),
            ],
          ),
        ),
        side: wide
            ? ListView(
                padding: const EdgeInsets.only(top: 8, bottom: 96),
                children: [
                  SectionHeader(
                    '基金余额',
                    padding: const EdgeInsets.only(bottom: 8),
                    actionLabel: '全部',
                    onAction: () => context.go('/funds'),
                  ),
                  if (data == null)
                    const SkeletonList(rows: 4, padding: EdgeInsets.zero)
                  else if (data.activeFunds.isEmpty)
                    const _NoFunds(compact: true)
                  else
                    FundBalanceList(
                      funds: data.activeFunds,
                      stats: stats.valueOrNull,
                      onTap: (fund) => context.push('/funds/${fund.id}'),
                    ),
                  const SizedBox(height: LedgerLayout.groupGap),
                  ..._pending(context, data, month, padding: EdgeInsets.zero),
                ],
              )
            : null,
      ),
    );
  }

  /// 下拉刷新 = 主数据增量同步 + 本月统计重取 + 待确认/最近流水重取。
  ///
  /// 同步失败不清空已经画出来的首页，但要在页面顶上说出来并给重试。
  Future<void> _refresh(String month) async {
    ref.invalidate(pendingTxProvider);
    ref.invalidate(recentTxProvider);
    Object? error;
    try {
      await ref.read(ledgerProvider.notifier).sync();
    } catch (e) {
      error = e;
    }
    await ref.read(statsProvider(month).notifier).refresh();
    if (!mounted) return;
    setState(() => _syncError = error);
  }

  List<Widget> _funds(
    BuildContext context,
    LedgerData? data,
    StatsOverview? stats,
  ) => [
    SectionHeader(
      '基金',
      actionLabel: '全部',
      onAction: () => context.go('/funds'),
    ),
    if (data == null)
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
        child: Skeleton(height: 132, radius: LedgerShapes.card),
      )
    else if (data.activeFunds.isEmpty)
      const _NoFunds()
    else
      FundCarousel(
        funds: data.activeFunds,
        stats: stats,
        onTap: (fund) => context.push('/funds/${fund.id}'),
      ),
    const SizedBox(height: LedgerLayout.groupGap),
  ];

  /// 预算提醒：只在真有事的时候出现（接近上限或已超）。
  List<Widget> _budgetAlerts(
    BuildContext context,
    LedgerData? data,
    StatsOverview? stats,
  ) {
    if (stats == null) return const [];
    final alerts = stats.month.budgets
        .where((b) => b.isOver || b.isNear)
        .toList()
      ..sort((a, b) => b.ratio.compareTo(a.ratio));
    if (alerts.isEmpty) return const [];
    return [
      const SectionHeader('预算提醒'),
      Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LedgerLayout.pagePadding,
        ),
        child: Column(
          children: [
            for (final alert in alerts.take(3))
              _BudgetAlertRow(alert: alert, ledger: data),
          ],
        ),
      ),
      const SizedBox(height: LedgerLayout.groupGap),
    ];
  }

  List<Widget> _pending(
    BuildContext context,
    LedgerData? data,
    String month, {
    EdgeInsetsGeometry? padding,
  }) {
    final pending = ref.watch(pendingTxProvider);
    final items = (pending.valueOrNull ?? const <Transaction>[])
        .where((tx) => !_confirmed.contains(tx.id))
        .toList();
    if (items.isEmpty) {
      // 没有待确认就整段不出现：没事发生时不要占地方。
      return pending.hasError
          ? [
              SectionHeader('待确认', padding: padding),
              InlineError(
                message: describeError(pending.error!),
                onRetry: () => ref.invalidate(pendingTxProvider),
                padding: const EdgeInsets.symmetric(
                  horizontal: LedgerLayout.pagePadding,
                  vertical: 8,
                ),
              ),
              const SizedBox(height: LedgerLayout.groupGap),
            ]
          : const [];
    }
    return [
      SectionHeader('待确认 ${items.length}', padding: padding),
      PendingCaptures(
        items: items,
        ledger: data,
        onConfirm: (tx) => _confirm(tx, month),
        onEdit: (tx) => context.push('/transactions/${tx.id}'),
      ),
      const SizedBox(height: LedgerLayout.groupGap),
    ];
  }

  /// 确认一笔。断网时 `confirm()` 不抛异常、只是悄悄入队，所以要看队列有没有
  /// 变长——不然会出现「点了确认、什么都没发生」。
  Future<void> _confirm(Transaction tx, String month) async {
    final repo = ref.read(transactionsRepoProvider);
    final offline = await wentToOutbox(repo, () => repo.confirm(tx.id));
    if (!mounted) return;
    // 不管在线离线，这条都不该继续挂在「待确认」里等人再点一次。
    setState(() => _confirmed.add(tx.id));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(offline ? '已离线保存，联网后自动上传' : '已确认'),
      ),
    );
    if (offline) return;
    ref.invalidate(pendingTxProvider);
    ref.invalidate(recentTxProvider);
    await ref.read(statsProvider(month).notifier).refresh();
  }
}

class _Recent extends ConsumerWidget {
  const _Recent({this.ledger});

  final LedgerData? ledger;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recent = ref.watch(recentTxProvider);
    return AsyncValueView<List<Transaction>>(
      value: recent,
      loading: const SkeletonList(rows: 4),
      onRetry: () => ref.invalidate(recentTxProvider),
      errorPadding: const EdgeInsets.all(LedgerLayout.pagePadding),
      data: (items) => RecentList(
        items: items,
        ledger: ledger,
        onTap: (tx) => context.push('/transactions/${tx.id}'),
        onAdd: () => context.push('/transactions/new'),
      ),
    );
  }
}

class _BudgetAlertRow extends StatelessWidget {
  const _BudgetAlertRow({required this.alert, this.ledger});

  final BudgetProgress alert;
  final LedgerData? ledger;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ledgerColors = LedgerColors.of(context);
    final isFund = alert.scope == Budget.scopeFund;
    final name = isFund
        ? ledger?.fund(alert.refId)?.name
        : ledger?.category(alert.refId)?.name;
    final color = alert.isOver ? theme.colorScheme.error : ledgerColors.warning;
    return Padding(
      padding: const EdgeInsets.only(bottom: LedgerLayout.itemGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  name ?? (isFund ? '某个基金' : '某个类别'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge,
                ),
              ),
              Text(
                alert.isOver
                    ? '超预算 ${Money.format(-alert.remainCents)}'
                    : '还剩 ${Money.format(alert.remainCents)}',
                style: theme.textTheme.bodySmall?.copyWith(color: color),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: alert.ratio > 1 ? 1 : alert.ratio,
              minHeight: 6,
              backgroundColor: ledgerColors.surface3,
              color: color,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              MoneyText(alert.spentCents, size: MoneySize.small),
              Text(' / ', style: theme.textTheme.bodySmall),
              MoneyText(alert.budgetCents, size: MoneySize.small, muted: true),
            ],
          ),
        ],
      ),
    );
  }
}

class _NoFunds extends StatelessWidget {
  const _NoFunds({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) => EmptyState(
    title: '还没有基金',
    message: '先从模板建一个，钱才有地方归。',
    icon: Icons.savings_outlined,
    compact: compact,
    actionLabel: '新建基金',
    onAction: () => context.push('/funds/new'),
  );
}
