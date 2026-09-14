import 'package:flutter/material.dart';

import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../transactions/tx_tile.dart';
import '../widgets/widgets.dart';

/// 首页「最近流水」：就是账单页那一行，只是不分组、不翻页。
class RecentList extends StatelessWidget {
  const RecentList({
    super.key,
    required this.items,
    required this.onTap,
    required this.onAdd,
    this.ledger,
  });

  final List<Transaction> items;
  final LedgerData? ledger;
  final void Function(Transaction tx) onTap;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return EmptyState(
        title: '这个月还没有流水',
        message: '记一笔，或者打开自动记账让它自己进来。',
        icon: Icons.receipt_long_outlined,
        actionLabel: '记一笔',
        onAction: onAdd,
      );
    }
    return Column(
      children: [
        for (final tx in items)
          TxTile(tx: tx, ledger: ledger, onTap: () => onTap(tx)),
      ],
    );
  }
}
