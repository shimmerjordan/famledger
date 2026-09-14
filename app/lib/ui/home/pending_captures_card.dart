import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../widgets/widgets.dart';

/// 待确认的自动记账：机器记下的每一笔都要标出「有多确定、从哪来」，
/// 并且一步就能改（PRODUCT.md「自动但可疑」）。
class PendingCaptures extends StatefulWidget {
  const PendingCaptures({
    super.key,
    required this.items,
    required this.onConfirm,
    required this.onEdit,
    this.ledger,
  });

  final List<Transaction> items;
  final LedgerData? ledger;

  /// 确认失败要把原因说出来，所以要等结果。
  final Future<void> Function(Transaction tx) onConfirm;
  final void Function(Transaction tx) onEdit;

  @override
  State<PendingCaptures> createState() => _PendingCapturesState();
}

class _PendingCapturesState extends State<PendingCaptures> {
  final Set<String> _busy = {};
  final Map<String, String> _errors = {};

  Future<void> _confirm(Transaction tx) async {
    setState(() {
      _busy.add(tx.id);
      _errors.remove(tx.id);
    });
    try {
      await widget.onConfirm(tx);
    } catch (error) {
      if (!mounted) return;
      setState(() => _errors[tx.id] = describeError(error));
    } finally {
      if (mounted) setState(() => _busy.remove(tx.id));
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
    child: Column(
      children: [
        for (final tx in widget.items) ...[
          _PendingCard(
            tx: tx,
            ledger: widget.ledger,
            busy: _busy.contains(tx.id),
            error: _errors[tx.id],
            onConfirm: () => _confirm(tx),
            onEdit: () => widget.onEdit(tx),
          ),
          if (tx != widget.items.last) const SizedBox(height: LedgerLayout.itemGap),
        ],
      ],
    ),
  );
}

class _PendingCard extends StatelessWidget {
  const _PendingCard({
    required this.tx,
    required this.busy,
    required this.onConfirm,
    required this.onEdit,
    this.ledger,
    this.error,
  });

  final Transaction tx;
  final LedgerData? ledger;
  final bool busy;
  final String? error;
  final VoidCallback onConfirm;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fund = ledger?.fund(tx.fundId);
    final category = ledger?.category(tx.categoryId);
    final index = fund == null ? 0 : (ledger?.fundIndex(fund.id) ?? 0);
    final color = fund == null
        ? theme.colorScheme.onSurfaceVariant
        : fundColorOf(context, fund, index < 0 ? 0 : index);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(LedgerLayout.itemGap),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CategoryIcon(category?.icon, background: true, color: color),
                const SizedBox(width: LedgerLayout.itemGap),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tx.merchant?.isNotEmpty == true
                            ? tx.merchant!
                            : (category?.name ?? tx.typeLabel),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _provenance(fund),
                        maxLines: 2,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                MoneyText(
                  tx.isExpense ? -tx.amountCents : tx.amountCents,
                  signed: tx.isIncome,
                ),
              ],
            ),
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(
                error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonal(
                    onPressed: busy ? null : onConfirm,
                    child: busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('确认'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: busy ? null : onEdit,
                    child: const Text('修改'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 「92% 可信 · 来自支付宝 · 今天 12:30」——不确定就要说出来。
  String _provenance(Fund? fund) {
    final confidence = tx.confidence;
    return [
      if (confidence != null) '${(confidence * 100).round()}% 可信',
      if (tx.sourceApp != null && tx.sourceApp!.isNotEmpty)
        '来自 ${tx.sourceApp}'
      else
        '来自${tx.sourceLabel}',
      if (fund != null) fund.name,
      Dates.dateTimeLabel(tx.occurredAt),
    ].join(' · ');
  }
}
