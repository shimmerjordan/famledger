import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../assets/asset_widgets.dart';
import '../widgets/widgets.dart';
import 'tx_tile.dart';

/// 「这笔钱已经记过流水了」：从最近的支出 / 收入里挑一笔，交给债务当往来（服务端把它改成真账户和债务内部账户
/// 之间的转账，账户不会扣两次；人情不改那笔，只当钱那边已经记过）。
///
/// [type] 是 `expense` / `income`（借出 / 还款是花出去的钱，收回 / 借入是收进来的钱）；只列 [currency] 这个币种、
/// 挂了账户、没删、已确认、账户不是别的债务内部账户、没被人情关联过的那些。给了 [amountCents]，
/// 金额一样的排最前并标「金额一样」。选中返回那笔，关掉返回 null。
Future<Transaction?> showPickTransactionSheet(
  BuildContext context, {
  required String type,
  required String currency,
  int? amountCents,
}) => showModalBottomSheet<Transaction>(
  useRootNavigator: true,
  context: context,
  isScrollControlled: true,
  builder: (context) => PickTransactionSheet(type: type, currency: currency, amountCents: amountCents),
);

/// 最多拉最近这么多笔：再往前的账不太可能是「刚记过、还没关联」的那笔，真要找就去账单页。
const int kPickTxLimit = 100;

/// 「这笔流水能不能当债务往来」：和 `server/src/modules/debts.js` 的 `linkedTransaction` 同一套口径，
/// 列表里先筛一遍，省得选了再被 400。[ledger] 没到时账户查不到，按能选算（服务端还会拦）。
bool canLinkToDebt(Transaction tx, {required String currency, LedgerData? ledger}) =>
    (tx.isExpense || tx.isIncome) &&
    !tx.isDeleted &&
    // 待确认的不行：余额只算已确认的，关联了债务的「还剩多少」也不会动。
    tx.status == 'confirmed' &&
    tx.accountId != null &&
    tx.currency.toUpperCase() == currency.toUpperCase() &&
    ledger?.account(tx.accountId)?.isDebt != true &&
    ledger?.favorLinkedDebt(tx.id) == null;

class PickTransactionSheet extends ConsumerStatefulWidget {
  const PickTransactionSheet({super.key, required this.type, required this.currency, this.amountCents});

  final String type;
  final String currency;
  final int? amountCents;

  @override
  ConsumerState<PickTransactionSheet> createState() => _PickTransactionSheetState();
}

class _PickTransactionSheetState extends ConsumerState<PickTransactionSheet> {
  final TextEditingController _search = TextEditingController();
  late Future<List<Transaction>> _future = _load();

  bool get _expense => widget.type == Transaction.typeExpense;
  String get _typeLabel => _expense ? '支出' : '收入';

  Future<List<Transaction>> _load() async {
    final page = await ref.read(transactionsRepoProvider).list(TxFilter(type: widget.type, limit: kPickTxLimit));
    return page.items;
  }

  void _retry() => setState(() => _future = _load());

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// 能选的那些：金额一样的在前（各自保持服务端给的时间倒序），再按搜索词过滤商户 / 备注。
  List<Transaction> _candidates(List<Transaction> items, LedgerData? ledger) {
    final q = _search.text.trim().toLowerCase();
    bool hit(Transaction tx) =>
        q.isEmpty ||
        (tx.merchant ?? '').toLowerCase().contains(q) ||
        (tx.note ?? '').toLowerCase().contains(q);
    final ok = [
      for (final tx in items)
        if (tx.type == widget.type && canLinkToDebt(tx, currency: widget.currency, ledger: ledger) && hit(tx)) tx,
    ];
    final amount = widget.amountCents;
    if (amount == null || amount <= 0) return ok;
    return [...ok.where((tx) => tx.amountCents == amount), ...ok.where((tx) => tx.amountCents != amount)];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ledger = ref.watch(ledgerProvider).valueOrNull;
    final insets = MediaQuery.viewInsetsOf(context).bottom;
    final height = (MediaQuery.sizeOf(context).height - insets) * 0.8;
    return Padding(
      padding: EdgeInsets.only(bottom: insets),
      child: SafeArea(
        child: SizedBox(
          height: height,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: LedgerLayout.pagePadding),
              SectionHeader(
                '选一笔$_typeLabel',
                trailing: Text('最近 $kPickTxLimit 笔里挑', style: theme.textTheme.bodySmall),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 0, LedgerLayout.pagePadding, 8),
                child: TextField(
                  key: const ValueKey('pick-tx-search'),
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: '按商户 / 备注找',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清空',
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () => setState(_search.clear),
                          ),
                  ),
                ),
              ),
              Expanded(
                child: FutureBuilder<List<Transaction>>(
                  future: _future,
                  builder: (context, snap) {
                    if (snap.hasError) {
                      return InlineError(
                        message: describeError(snap.error!),
                        onRetry: _retry,
                        padding: const EdgeInsets.all(LedgerLayout.pagePadding),
                      );
                    }
                    final items = snap.data;
                    if (items == null) return const SkeletonList(rows: 4);
                    final rows = _candidates(items, ledger);
                    if (rows.isEmpty) {
                      final searching = _search.text.trim().isNotEmpty;
                      return EmptyState(
                        title: searching ? '没有叫这个的' : '最近没有可选的$_typeLabel',
                        message: searching
                            ? '换个词试试，或清空搜索'
                            : '要挂了账户、同币种、没作废的$_typeLabel才能选；最近 $kPickTxLimit 笔里没有',
                        compact: true,
                      );
                    }
                    final amount = widget.amountCents;
                    return ListView.builder(
                      padding: const EdgeInsets.only(bottom: LedgerLayout.pagePadding),
                      itemCount: rows.length,
                      itemBuilder: (context, i) {
                        final tx = rows[i];
                        final same = amount != null && amount > 0 && tx.amountCents == amount;
                        return TxTile(
                          key: ValueKey('pick-tx-${tx.id}'),
                          tx: tx,
                          ledger: ledger,
                          onTap: () => Navigator.of(context).pop(tx),
                          // 「金额一样」挂在金额下面；状态小标（待确认）照旧留着，别被盖掉。
                          trailingBelow: same
                              ? Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (tx.status != 'confirmed') ...[
                                      TxStatusBadge(status: tx.status),
                                      const SizedBox(width: 4),
                                    ],
                                    const TagLabel('金额一样'),
                                  ],
                                )
                              : null,
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 表单里「已经选了哪笔流水」的摘要行：商户 · 账户 · 哪天，右边金额；点一下换一笔。
/// 债务表单和收回 / 再借 sheet 共用，key 由调用方给（`debt-linked-tx` / `debt-move-linked-tx`）。
class LinkedTxRow extends StatelessWidget {
  const LinkedTxRow({super.key, required this.tx, required this.onTap, this.ledger});

  final Transaction tx;
  final VoidCallback onTap;
  final LedgerData? ledger;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final account = ledger?.account(tx.accountId);
    final merchant = tx.merchant ?? '';
    final note = tx.note ?? '';
    final title = merchant.isNotEmpty ? merchant : (note.isNotEmpty ? note : tx.typeLabel);
    return ListTile(
      onTap: onTap,
      contentPadding: EdgeInsets.zero,
      leading: const AssetAvatar(Icons.receipt_long_outlined),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          if (account != null) account.name,
          Dates.dayLabel(tx.occurredAt),
          '点一下换一笔',
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      trailing: MultiCurrencyAmount(tx.amountCents, currency: tx.currency),
    );
  }
}
