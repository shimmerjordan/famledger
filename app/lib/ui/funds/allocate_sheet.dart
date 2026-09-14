import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/ids.dart';
import '../../core/money.dart';
import '../../data/models/models.dart';
import '../add_tx/fund_picker.dart';
import '../add_tx/picker_field.dart';
import '../transactions/tx_providers.dart';
import '../widgets/widgets.dart';

/// 拨款：把钱从一个基金挪到另一个基金（账户不动）。
///
/// 落到数据上就是一笔 `type=transfer` 且只填了基金对的流水（spec §3）。
/// 成功返回 true。
Future<bool?> showAllocateSheet(
  BuildContext context, {
  required Fund from,
  required List<Fund> funds,
}) => showModalBottomSheet<bool>(
  context: context,
  isScrollControlled: true,
  builder: (context) => _AllocateSheet(from: from, funds: funds),
);

class _AllocateSheet extends ConsumerStatefulWidget {
  const _AllocateSheet({required this.from, required this.funds});

  final Fund from;
  final List<Fund> funds;

  @override
  ConsumerState<_AllocateSheet> createState() => _AllocateSheetState();
}

class _AllocateSheetState extends ConsumerState<_AllocateSheet> {
  final TextEditingController _amount = TextEditingController();
  final TextEditingController _note = TextEditingController();
  String? _toFundId;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final cents = Money.tryParse(_amount.text);
    if (cents == null || cents <= 0) {
      setState(() => _error = '填个金额，例如 500');
      return;
    }
    if (_toFundId == null) {
      setState(() => _error = '选一个要拨给谁');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final saved = await ref
          .read(transactionsRepoProvider)
          .create(
            TransactionDraft(
              clientId: newClientId(),
              type: Transaction.typeTransfer,
              amountCents: cents,
              occurredAt: DateTime.now(),
              fundId: widget.from.id,
              toFundId: _toFundId,
              memberId: ref.read(sessionProvider)?.me.id,
              note: _note.text.trim().isEmpty ? null : _note.text.trim(),
            ),
          );
      ref.invalidate(recentTxProvider);
      ref.invalidate(txListProvider);
      ref.invalidate(statsProvider);
      if (!mounted) return;
      // 断网时 create 不抛异常，只是先记在本地队列里 —— 不说一声就关掉弹层，
      // 用户会以为钱已经拨过去了。
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            saved.pendingSync
                ? '已离线保存，联网后自动上传'
                : '已从「${widget.from.name}」拨出 ${Money.format(cents)}',
          ),
        ),
      );
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = describeError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final targets = widget.funds
        .where((f) => f.id != widget.from.id)
        .toList();
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SectionHeader('从「${widget.from.name}」拨款'),
            PickerField(
              label: '金额',
              topGap: 0,
              child: TextField(
                controller: _amount,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  prefixText: '¥ ',
                  hintText: '500',
                ),
              ),
            ),
            PickerField(
              label: '拨给哪个基金',
              contentPadding: EdgeInsets.zero,
              child: FundPicker(
                funds: targets,
                keyPrefix: 'to-fund',
                selectedId: _toFundId,
                emptyHint: '只有这一个基金，先去建第二个',
                onSelected: (id) => setState(() {
                  _toFundId = id;
                  _error = null;
                }),
              ),
            ),
            PickerField(
              label: '备注（选填）',
              child: TextField(
                controller: _note,
                decoration: const InputDecoration(hintText: '例如「本月生活费」'),
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
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(LedgerLayout.pagePadding),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _busy || targets.isEmpty ? null : _submit,
                  child: const Text('拨过去'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
