import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../core/ids.dart';
import '../../core/money.dart';
import '../../data/models/models.dart';
import '../add_tx/account_picker.dart';
import '../add_tx/picker_field.dart';
import '../assets/asset_providers.dart';
import '../assets/asset_widgets.dart';
import '../transactions/pick_tx_sheet.dart';
import '../widgets/widgets.dart';
import 'debt_widgets.dart';

/// 收回 / 还钱（[add] 为假）或再借（[add] 为真）。成功返回 true。
/// 钱已经被自动记账 / 导入记过的，勾「这笔钱已经记过流水了」选那笔：服务端把它改成转账，账户不扣两次。
Future<bool?> showDebtMoveSheet(BuildContext context, Debt debt, {required bool add}) => showModalBottomSheet<bool>(
  useRootNavigator: true,
  context: context,
  isScrollControlled: true,
  builder: (context) => DebtMoveSheet(debt: debt, add: add),
);

class DebtMoveSheet extends ConsumerStatefulWidget {
  const DebtMoveSheet({super.key, required this.debt, required this.add});

  final Debt debt;
  final bool add;

  @override
  ConsumerState<DebtMoveSheet> createState() => _DebtMoveSheetState();
}

class _DebtMoveSheetState extends ConsumerState<DebtMoveSheet> {
  late final TextEditingController _amount = TextEditingController(text: _prefill());
  final TextEditingController _note = TextEditingController();
  late DateTime _day = _today();

  /// 默认记流水：钱真的经过某个账户（人情是记一笔支出 / 收入）。
  bool _record = true;
  String? _accountId;

  /// 「这笔钱已经记过流水了」：选一笔已有的支出 / 收入当这次往来。
  bool _linkExisting = false;
  Transaction? _linkedTx;
  bool _busy = false;
  String? _error;
  final String _clientId = newClientId();

  Debt get _d => widget.debt;

  /// 钱进真账户的（收回、再借入、收礼）要关联一笔收入，出去的（还钱、再借出、随礼）要一笔支出。
  String get _linkType => _d.isLend != widget.add ? Transaction.typeIncome : Transaction.typeExpense;

  Future<void> _pickTx() async {
    final tx = await showPickTransactionSheet(
      context,
      type: _linkType,
      currency: _d.currency,
      amountCents: parseMoneyField(_amount.text),
    );
    if (tx == null || !mounted) return;
    setState(() {
      _linkedTx = tx;
      _amount.text = Money.input(tx.amountCents);
      _error = null;
    });
  }

  /// 收回 / 还钱：先填上还剩多少，多数是一次还清。
  String _prefill() {
    if (widget.add) return '';
    final left = outstandingOf(_d, ref.read(debtBalancesProvider));
    return left == null || left <= 0 ? '' : Money.input(left);
  }

  DateTime _today() {
    final now = ref.read(assetClockProvider)();
    return DateTime(now.year, now.month, now.day);
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  String get _accountLabel {
    if (_d.isFavor) {
      // 人情：内部余额变多 = 随礼出去（支出），变少 = 收到礼（收入）。
      final out = _d.isLend == widget.add;
      return out ? '礼金从哪个账户出（记一笔人情支出）' : '收的礼进了哪个账户（记一笔人情收入）';
    }
    final moneyIn = _d.isLend != widget.add;
    return moneyIn ? '钱进了哪个账户' : '钱从哪个账户出';
  }

  Future<void> _submit() async {
    final amount = parseMoneyField(_amount.text);
    if (amount == null || amount <= 0) {
      setState(() => _error = '填个金额，例如 2000');
      return;
    }
    final left = outstandingOf(_d, ref.read(debtBalancesProvider));
    if (!widget.add && left != null && amount > left) {
      setState(() => _error = '最多 ${Money.format(left)}');
      return;
    }
    final linking = _record && _linkExisting;
    if (linking && _linkedTx == null) {
      setState(() => _error = '选那笔流水，或关掉「这笔钱已经记过流水了」');
      return;
    }
    if (_record && !linking && _accountId == null) {
      setState(() => _error = '选一个账户，或关掉「同时记一笔」');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await ref.read(debtsRepoProvider).move(
        _d.id,
        add: widget.add,
        amountCents: amount,
        occurredOn: Dates.isoDate(_day),
        accountId: _record && !linking ? _accountId : null,
        transactionId: linking ? _linkedTx!.id : null,
        note: _note.text.trim(),
        clientId: _clientId,
      );
      refreshMoneyViews(ref);
      if (!mounted) return;
      final money = Money.format(amount, currency: _d.currency);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.replayed
                ? '刚才那次其实已经记上了，没有重复记'
                : linking && !_d.isFavor
                    ? '已记：${debtMoveLabel(_d, add: widget.add)} $money，那笔流水变成了转账'
                    : '已记：${debtMoveLabel(_d, add: widget.add)} $money',
          ),
        ),
      );
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = describeWriteError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accounts = ref.watch(ledgerProvider).valueOrNull?.activeAccounts ?? const <Account>[];
    final left = outstandingOf(_d, ref.watch(debtBalancesProvider));
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: LedgerLayout.pagePadding),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionHeader('${debtMoveLabel(_d, add: widget.add)} · ${_d.counterparty}'),
              PickerField(
                label: '多少',
                topGap: 0,
                trailing: !widget.add && left != null && left > 0
                    ? Text('还剩 ${Money.format(left)}', style: theme.textTheme.bodySmall)
                    : null,
                child: TextField(
                  key: const ValueKey('debt-move-amount'),
                  controller: _amount,
                  autofocus: true,
                  // 关联了已有流水：金额跟着那笔走，改金额就换一笔。
                  readOnly: _linkedTx != null,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  // 这笔债务是什么币就写什么符号（美元的债不是 ¥）。
                  decoration: InputDecoration(
                    prefixText: '${Money.symbolFor(_d.currency).trim()} ',
                    hintText: '2000',
                    helperText: _linkedTx == null ? null : '金额跟着那笔流水；改金额就换一笔',
                  ),
                ),
              ),
              PickerField(label: '哪天', child: DayButton(day: _day, onPressed: () async {
                final picked = await pickPastDay(context, initial: _day, help: '哪天的事');
                if (picked != null) setState(() => _day = picked);
              })),
              PickerField(
                label: '备注（选填）',
                child: TextField(
                  key: const ValueKey('debt-move-note'),
                  controller: _note,
                  decoration: InputDecoration(hintText: widget.add ? '又借了一笔' : '例如「微信转回来的」「抵了一顿饭」'),
                ),
              ),
              const SizedBox(height: LedgerLayout.itemGap),
              SwitchListTile(
                key: const ValueKey('debt-move-record'),
                value: _record,
                onChanged: (v) => setState(() => _record = v),
                title: Text(_d.isFavor ? '同时记一笔支出 / 收入' : '同时记一笔转账'),
                subtitle: Text(
                  _record
                      ? (_d.isFavor ? '礼金是真花出去 / 收进来的钱，记进人情类别' : '钱经过下面的账户，不算支出也不算收入')
                      : '不记流水，只改这笔债务还剩多少（以前的旧账、抵了、免了）',
                ),
              ),
              if (_record) ...[
                SwitchListTile(
                  key: const ValueKey('debt-move-link'),
                  value: _linkExisting,
                  onChanged: (v) => setState(() {
                    _linkExisting = v;
                    if (!v) _linkedTx = null;
                  }),
                  title: const Text('这笔钱已经记过流水了'),
                  subtitle: const Text('自动记账 / 导入的那笔，选它就不会再扣一次'),
                ),
                if (_linkExisting)
                  PickerField(
                    label: _linkedTx == null ? '选那笔${_linkType == Transaction.typeExpense ? '支出' : '收入'}' : '关联的流水',
                    topGap: LedgerLayout.itemGap,
                    child: _linkedTx == null
                        ? Align(
                            alignment: Alignment.centerLeft,
                            child: OutlinedButton.icon(
                              key: const ValueKey('debt-move-pick-tx'),
                              onPressed: _pickTx,
                              icon: const Icon(Icons.receipt_long_outlined, size: 18),
                              label: const Text('选流水'),
                            ),
                          )
                        : LinkedTxRow(
                            key: const ValueKey('debt-move-linked-tx'),
                            tx: _linkedTx!,
                            ledger: ref.watch(ledgerProvider).valueOrNull,
                            onTap: _pickTx,
                          ),
                  )
                else
                  PickerField(
                    label: _accountLabel,
                    topGap: LedgerLayout.itemGap,
                    child: AccountPicker(
                      keyPrefix: 'debt-move-account',
                      accounts: accounts,
                      selectedId: _accountId,
                      emptyHint: '还没有账户',
                      onSelected: (id) => setState(() => _accountId = id),
                    ),
                  ),
              ],
              FormSubmit(
                key: const ValueKey('debt-move-submit'),
                label: debtMoveLabel(_d, add: widget.add),
                busy: _busy,
                error: _error,
                onPressed: _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
