import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../assets/asset_providers.dart';
import '../assets/asset_widgets.dart';
import '../transactions/tx_tile.dart';
import '../widgets/widgets.dart';
import 'debt_move_sheet.dart';
import 'debt_widgets.dart';

/// 一笔债务内部账户上的流水（借出、收回这些转账）：详情页的「往来」。同步到新数据就重取。
final debtTransactionsProvider = FutureProvider.autoDispose.family<List<Transaction>, String>((ref, accountId) async {
  ref.watch(ledgerProvider.select((l) => l.valueOrNull?.seq));
  final page = await ref.watch(transactionsRepoProvider).list(TxFilter(accountId: accountId, limit: 50));
  return page.items;
});

/// 债务详情：还剩多少、原始金额、约定日子；收回 / 还钱、再借、编辑、归档、删除；往来记录。
class DebtDetailPage extends ConsumerStatefulWidget {
  const DebtDetailPage(this.id, {super.key});

  final String id;

  @override
  ConsumerState<DebtDetailPage> createState() => _DebtDetailPageState();
}

class _DebtDetailPageState extends ConsumerState<DebtDetailPage> {
  bool _busy = false;
  String? _error;
  bool _deleting = false;
  Debt? _last;

  Future<void> _move(Debt d, {required bool add}) async {
    setState(() => _error = null);
    final done = await showDebtMoveSheet(context, d, add: add);
    if (done == true && mounted) ref.invalidate(debtTransactionsProvider);
  }

  Future<void> _archive(Debt d, bool archived) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(debtsRepoProvider).setArchived(d.id, archived);
    } catch (error) {
      if (mounted) setState(() => _error = describeError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(Debt d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删掉「${d.title}」？'),
        content: const Text('只能删还没有往来流水的；有流水的结清后点「归档」。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('算了')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('删掉')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _busy = true;
      _deleting = true;
    });
    try {
      await ref.read(debtsRepoProvider).delete(d.id);
      refreshNetWorth(ref);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已删掉')));
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/assets?tab=debts');
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
    final live = ledger?.debt(widget.id);
    if (live != null) _last = live;
    final d = live ?? (_deleting ? _last : null);
    if (ledger == null) {
      return Scaffold(appBar: AppBar(title: const Text('债务')), body: const SkeletonList(rows: 5));
    }
    if (d == null) {
      return Scaffold(appBar: AppBar(title: const Text('债务')), body: const InlineError(message: '这笔债务已经不在了。'));
    }
    final theme = Theme.of(context);
    final overview = ref.watch(debtBalancesProvider);
    final now = ref.watch(assetClockProvider)();
    final left = outstandingOf(d, overview);
    final settled = left == 0;

    return Scaffold(
      appBar: AppBar(
        title: Text(d.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '编辑',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => context.push('/assets/debts/${d.id}/edit'),
          ),
          IconButton(
            key: const ValueKey('debt-delete'),
            tooltip: '删除',
            icon: const Icon(Icons.delete_outline),
            onPressed: _busy ? null : () => _delete(d),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(statsProvider);
          ref.invalidate(debtTransactionsProvider);
          await ref.read(ledgerProvider.notifier).sync();
        },
        child: LayoutBuilder(
          builder: (context, box) => ListView(
            padding: readableInsets(box.maxWidth, maxWidth: 720).copyWith(bottom: 96),
            children: [
              Padding(
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
                        Text(settled ? '已结清' : '还剩', style: theme.textTheme.bodySmall),
                        const SizedBox(width: 8),
                        TagLabel(directionLabel(d.direction, favor: d.isFavor)),
                        if (!d.counted) ...[const SizedBox(width: 6), const TagLabel('不计入净资产')],
                      ],
                    ),
                    const SizedBox(height: 2),
                    if (left == null)
                      Text('—', style: theme.textTheme.headlineMedium)
                    else
                      MoneyText(left, size: MoneySize.display),
                    const SizedBox(height: LedgerLayout.itemGap),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _Cell(
                            label: d.isFavor ? (d.isLend ? '随出去' : '收下') : (d.isLend ? '借出' : '借入'),
                            child: MoneyText(d.amountCents),
                          ),
                        ),
                        Expanded(
                          child: _Cell(
                            label: '约定',
                            child: Text(dueLabel(d, now) ?? '没约定日子', style: theme.textTheme.bodyLarge),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonal(
                      key: const ValueKey('debt-settle'),
                      onPressed: _busy || settled ? null : () => _move(d, add: false),
                      child: Text(debtMoveLabel(d, add: false)),
                    ),
                    OutlinedButton(
                      key: const ValueKey('debt-add'),
                      onPressed: _busy ? null : () => _move(d, add: true),
                      child: Text(debtMoveLabel(d, add: true)),
                    ),
                    if (settled || d.archived)
                      OutlinedButton(
                        key: const ValueKey('debt-archive'),
                        onPressed: _busy ? null : () => _archive(d, !d.archived),
                        child: Text(d.archived ? '取消归档' : '归档'),
                      ),
                  ],
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
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
                  ),
                ),
              const SizedBox(height: LedgerLayout.groupGap),
              const SectionHeader('明细'),
              InfoRow('对方', InfoText(d.counterparty)),
              InfoRow('类型', InfoText(d.kindLabel)),
              if (localDate(d.startedOn) case final started?) InfoRow('开始', InfoText(Dates.dayLabel(started))),
              if (localDate(d.dueOn) case final due?) InfoRow('约定还款', InfoText(Dates.dayLabel(due))),
              InfoRow('计入净资产', InfoText(d.counted ? '计入' : '不计入')),
              if (ledger.member(d.memberId) case final m?) InfoRow('家里谁的', InfoText(m.label)),
              if (d.note != null && d.note!.isNotEmpty) InfoRow('备注', InfoText(d.note!)),
              const SizedBox(height: LedgerLayout.groupGap),
              const SectionHeader('往来'),
              _History(debt: d, ledger: ledger),
            ],
          ),
        ),
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 2),
      child,
    ],
  );
}

/// 往来：经账户的流水 + 没记流水的那几笔（备忘），按日期新的在前。
class _History extends ConsumerWidget {
  const _History({required this.debt, required this.ledger});

  final Debt debt;
  final LedgerData ledger;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accountId = debt.accountId;
    final txs = accountId == null ? const AsyncValue<List<Transaction>>.data([]) : ref.watch(debtTransactionsProvider(accountId));
    final memos = debt.memoLog;
    final rows = <({String day, Widget child})>[];
    for (final m in memos) {
      // 备忘里记的是对内部账户余额的影响；借入那边反过来才是「欠的变多 / 变少」。
      final delta = debt.isLend ? m.amountCents : -m.amountCents;
      rows.add((
        day: m.on,
        child: ListTile(
          key: ValueKey('debt-memo-${m.on}-${m.amountCents}-${m.note}'),
          contentPadding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
          leading: const AssetAvatar(Icons.edit_note),
          title: Text(m.note.isEmpty ? '没记流水' : m.note, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            [
              if (localDate(m.on) case final day?) Dates.dayLabel(day),
              if (debt.isFavor && m.recorded) '钱另记了一笔' else '没记流水',
            ].join(' · '),
            style: theme.textTheme.bodySmall,
          ),
          trailing: MoneyText(delta, signed: true),
        ),
      ));
    }
    for (final tx in txs.valueOrNull ?? const <Transaction>[]) {
      rows.add((
        day: tx.occurredAt.toIso8601String(),
        child: TxTile(tx: tx, ledger: ledger, onTap: () => context.push('/transactions/${tx.id}')),
      ));
    }
    rows.sort((a, b) => b.day.compareTo(a.day));
    if (txs.isLoading && rows.isEmpty) return const SkeletonList(rows: 2);
    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
        child: Text('还没有往来', style: theme.textTheme.bodySmall),
      );
    }
    return Column(children: [for (final r in rows) r.child]);
  }
}
