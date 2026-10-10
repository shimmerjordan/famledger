import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/shell.dart';
import '../../app/theme.dart';
import '../../core/money.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../assets/asset_providers.dart';
import '../assets/asset_widgets.dart';
import '../widgets/widgets.dart';
import 'debt_detail_page.dart';
import 'debt_widgets.dart';

/// 资产 › 债务：别人欠我、我欠别人、人情，各一组；还清了的收在最后。
/// 顶上一行小结：净额（计入净资产的那部分）+ 两边各多少。
class DebtsTab extends ConsumerStatefulWidget {
  const DebtsTab({super.key});

  @override
  ConsumerState<DebtsTab> createState() => _DebtsTabState();
}

class _DebtsTabState extends ConsumerState<DebtsTab> {
  Object? _syncError;

  Future<void> _sync() async {
    Object? error;
    try {
      await ref.read(ledgerProvider.notifier).sync();
      if (mounted) refreshNetWorth(ref);
    } catch (e) {
      error = e;
    }
    if (mounted) setState(() => _syncError = error);
  }

  @override
  Widget build(BuildContext context) {
    final ledger = ref.watch(ledgerProvider);
    final overview = ref.watch(debtBalancesProvider);
    final now = ref.watch(assetClockProvider)();
    final banner = SyncErrorBanner(error: _syncError, onRetry: _sync);
    // ≥ 840：左边列表、右边嵌着选中那笔的详情页。
    final twoPane = widthClassOf(context) == WidthClass.expanded;
    final all = ledger.valueOrNull?.debts ?? const <Debt>[];
    final selected = ref.watch(selectedDebtProvider);
    final shown = twoPane ? (all.any((d) => d.id == selected) ? selected : all.firstOrNull?.id) : null;
    if (twoPane && shown != selected) pinSelection(ref, selectedDebtProvider, shown);
    void open(Debt d) {
      if (twoPane) {
        ref.read(selectedDebtProvider.notifier).state = d.id;
      } else {
        context.push('/assets/debts/${d.id}');
      }
    }

    final list = RefreshIndicator(
      onRefresh: _sync,
      child: LayoutBuilder(
        builder: (context, box) => AsyncValueView<LedgerData>(
          value: ledger,
          loading: ListView(children: const [SkeletonList(rows: 5)]),
          onRetry: () => ref.invalidate(ledgerProvider),
          data: (data) {
            final debts = data.debts;
            if (debts.isEmpty) {
              return ListView(
                children: [
                  banner,
                  const SizedBox(height: 40),
                  EmptyState(
                    title: '还没有债务',
                    message: '借给别人的、欠别人的、人情往来都能记。借款算进净资产，人情默认不算。',
                    icon: Icons.handshake_outlined,
                    actionLabel: '记一笔债务',
                    onAction: () => context.push('/assets/debts/new'),
                  ),
                ],
              );
            }
            bool done(Debt d) => d.archived || isSettled(d, overview);
            final open_ = debts.where((d) => !done(d)).toList();
            final groups = <String, List<Debt>>{
              '别人欠我': [for (final d in open_) if (d.isLend && !d.isFavor) d],
              '我欠别人': [for (final d in open_) if (!d.isLend && !d.isFavor) d],
              '人情': [for (final d in open_) if (d.isFavor) d],
            };
            final settled = debts.where(done).toList();
            return ListView(
              padding: (twoPane ? EdgeInsets.zero : readableInsets(box.maxWidth)).copyWith(bottom: 96),
              children: [
                banner,
                _Summary(overview: overview, debts: debts),
                for (final e in groups.entries)
                  if (e.value.isNotEmpty) ...[
                    _GroupHeader(title: e.key, debts: e.value, overview: overview),
                    for (final d in e.value)
                      DebtTile(debt: d, overview: overview, now: now, selected: d.id == shown, onTap: () => open(d)),
                  ],
                if (settled.isNotEmpty) ...[
                  const SizedBox(height: LedgerLayout.groupGap),
                  const SectionHeader('已结清'),
                  for (final d in settled)
                    DebtTile(debt: d, overview: overview, now: now, selected: d.id == shown, onTap: () => open(d)),
                ],
              ],
            );
          },
        ),
      ),
    );
    if (!twoPane) return list;
    return AdaptiveTwoPane(
      main: list,
      sideWidth: LedgerLayout.detailPaneWidth,
      side: shown == null
          ? const EmptyState(title: '选一笔债务看详情', compact: true)
          : DetailPane(key: ValueKey('debt-pane-$shown'), child: DebtDetailPage(shown)),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.overview, required this.debts});

  final StatsOverview? overview;
  final List<Debt> debts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = overview?.debts;
    final favorOnly = debts.any((d) => d.isFavor);
    return SegmentSummary(
      key: const ValueKey('debts-summary'),
      label: '净额',
      value: s == null
          ? Text('—', style: theme.textTheme.titleLarge)
          : MoneyText(s.countedNetCents, size: MoneySize.title, signed: true),
      lines: [
        if (s != null)
          Text(
            '别人欠我 ${Money.format(s.receivableCents)} · 我欠别人 ${Money.format(s.payableCents)}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        Text(
          favorOnly ? '净额只算「计入净资产」的；人情默认不算' : '净额会算进资产页顶上的净资产',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.title, required this.debts, required this.overview});

  final String title;
  final List<Debt> debts;
  final StatsOverview? overview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    var total = 0;
    var known = true;
    for (final d in debts) {
      final o = outstandingOf(d, overview);
      if (o == null) known = false;
      total += o ?? 0;
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, LedgerLayout.itemGap, LedgerLayout.pagePadding, 0),
      child: Row(
        children: [
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(width: 6),
          Text('${debts.length} 笔', style: theme.textTheme.bodySmall),
          const Spacer(),
          if (known) MoneyText(total, size: MoneySize.small),
        ],
      ),
    );
  }
}

/// 一笔债务：对方、类型和原始金额、约定日子；右边还剩多少。
class DebtTile extends StatelessWidget {
  const DebtTile({
    super.key,
    required this.debt,
    required this.overview,
    required this.now,
    this.onTap,
    this.selected = false,
  });

  final Debt debt;
  final StatsOverview? overview;
  final DateTime now;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = debt;
    final left = outstandingOf(d, overview);
    final settled = left == 0;
    final due = settled ? null : dueLabel(d, now);
    final overdue = due != null && due.startsWith('逾期');
    final sub = [
      d.kindLabel,
      '${d.isFavor ? (d.isLend ? '随了' : '收了') : (d.isLend ? '借出' : '借入')} ${Money.format(d.amountCents)}',
      if (due != null) due,
      if (!d.counted && !d.isFavor) '不计入净资产',
    ].join(' · ');
    return ListTile(
      key: ValueKey('debt-${d.id}'),
      selected: selected,
      onTap: onTap ?? () => GoRouter.of(context).push('/assets/debts/${d.id}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding, vertical: 4),
      leading: AssetAvatar(debtIcon(d), muted: settled || d.archived),
      title: Row(
        children: [
          Flexible(
            child: Text(d.counterparty, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyLarge),
          ),
          if (overdue) ...[
            const SizedBox(width: 6),
            const TagLabel('逾期', tone: TagTone.warning),
          ],
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
      ),
      trailing: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (left == null) Text('—', style: theme.textTheme.bodyLarge) else MoneyText(left),
          const SizedBox(height: 2),
          Text(settled ? '已结清' : '还剩', style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}
