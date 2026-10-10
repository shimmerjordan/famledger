import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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
import '../widgets/widgets.dart';
import 'debt_widgets.dart';

/// 记一笔 / 编辑债务：别人欠我还是我欠别人、借款还是人情、对方、多少、哪天、约定哪天还。
///
/// 新建时默认「同时记一笔」：借款记成真账户和这笔债务之间的转账（不算支出），人情记成一笔
/// 支出 / 收入（类别「人情」）。编辑只改基本信息；金额经详情页的「收回 / 再借」改。
class DebtFormPage extends ConsumerStatefulWidget {
  const DebtFormPage({super.key, this.id});

  final String? id;

  @override
  ConsumerState<DebtFormPage> createState() => _DebtFormPageState();
}

class _DebtFormPageState extends ConsumerState<DebtFormPage> {
  final TextEditingController _counterparty = TextEditingController();
  final TextEditingController _amount = TextEditingController();
  final TextEditingController _note = TextEditingController();

  String _direction = Debt.lend;
  String _kind = Debt.kindLoan;
  late DateTime _startedOn = _today();
  DateTime? _dueOn;
  bool _counted = true;

  /// 用户亲手点过「计入净资产」：换类型时不再按类型改它。
  bool _countedTouched = false;
  bool _record = true;
  String? _accountId;
  bool _bound = false;
  bool _busy = false;
  String? _error;
  final String _clientId = newClientId();

  bool get _editing => widget.id != null;
  bool get _favor => _kind == Debt.kindFavor;

  DateTime _today() {
    final now = ref.read(assetClockProvider)();
    return DateTime(now.year, now.month, now.day);
  }

  @override
  void dispose() {
    _counterparty.dispose();
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  void _bind(Debt d) {
    if (_bound) return;
    _bound = true;
    _direction = d.direction;
    _kind = d.kind;
    _counterparty.text = d.counterparty;
    _note.text = d.note ?? '';
    _startedOn = localDate(d.startedOn) ?? _startedOn;
    _dueOn = localDate(d.dueOn);
    _counted = d.counted;
    _countedTouched = true;
  }

  void _setKind(String kind) => setState(() {
    _kind = kind;
    // 人情是情分不是钱：默认不进净资产（用户自己改过就听用户的）。
    if (!_countedTouched) _counted = kind != Debt.kindFavor;
    _accountId = null;
  });

  String get _accountLabel {
    if (_favor) return _direction == Debt.lend ? '礼金从哪个账户出（记一笔人情支出）' : '收的礼进了哪个账户（记一笔人情收入）';
    return _direction == Debt.lend ? '钱从哪个账户借出去' : '借来的钱进了哪个账户';
  }

  Future<void> _save() async {
    final counterparty = _counterparty.text.trim();
    if (counterparty.isEmpty) {
      setState(() => _error = '对方是谁？例如「张三」「小王」');
      return;
    }
    final repo = ref.read(debtsRepoProvider);
    final dueOn = _dueOn == null ? null : Dates.isoDate(_dueOn!);
    if (_editing) {
      return _submit(() async {
        await repo.edit(
          widget.id!,
          kind: _kind,
          counterparty: counterparty,
          startedOn: Dates.isoDate(_startedOn),
          dueOn: dueOn,
          counted: _counted,
          note: _note.text.trim(),
        );
        return '已保存';
      });
    }
    final amount = parseMoneyField(_amount.text);
    if (amount == null || amount <= 0) {
      setState(() => _error = '多少钱？例如 5000');
      return;
    }
    if (_record && _accountId == null) {
      setState(() => _error = '选一个账户，或关掉「同时记一笔」');
      return;
    }
    return _submit(() async {
      await repo.create(
        direction: _direction,
        kind: _kind,
        counterparty: counterparty,
        amountCents: amount,
        startedOn: Dates.isoDate(_startedOn),
        dueOn: dueOn,
        counted: _counted,
        memberId: ref.read(sessionProvider)?.me.id,
        note: _note.text.trim(),
        accountId: _record ? _accountId : null,
        clientId: _clientId,
      );
      refreshMoneyViews(ref);
      return _record ? '记好了，也记了一笔 ${Money.format(amount)}' : '记好了';
    });
  }

  Future<void> _submit(Future<String> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final done = await action();
      refreshNetWorth(ref);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/assets?tab=debts');
      }
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
    final ledger = ref.watch(ledgerProvider).valueOrNull;
    final debt = _editing ? ledger?.debt(widget.id) : null;
    if (debt != null) _bind(debt);
    final title = _editing ? '编辑债务' : '记一笔债务';
    if (ledger == null) {
      return Scaffold(appBar: AppBar(title: Text(title)), body: const SkeletonList(rows: 5));
    }
    if (_editing && debt == null) {
      return Scaffold(appBar: AppBar(title: Text(title)), body: const InlineError(message: '这笔债务已经不在了。'));
    }

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      // 宽屏两列：左边「谁欠谁、多少、哪天」，右边约定还款、计不计入净资产、记账和备注。
      body: FormColumns(
        main: [
          if (!_editing)
            PickerField(
              label: '方向',
              topGap: LedgerLayout.pagePadding,
              child: SegmentedButton<String>(
                key: const ValueKey('debt-direction'),
                segments: [
                  ButtonSegment(value: Debt.lend, label: Text(directionLabel(Debt.lend, favor: _favor))),
                  ButtonSegment(value: Debt.borrow, label: Text(directionLabel(Debt.borrow, favor: _favor))),
                ],
                selected: {_direction},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() {
                  _direction = s.first;
                  _accountId = null;
                }),
              ),
            ),
          PickerField(
            label: '类型',
            topGap: _editing ? LedgerLayout.pagePadding : LedgerLayout.groupGap,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final k in Debt.kinds)
                      ChoiceChip(
                        key: ValueKey('debt-kind-$k'),
                        selected: _kind == k,
                        onSelected: (_) => _setKind(k),
                        label: Text(Debt.kindLabels[k]!),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  switch (_kind) {
                    Debt.kindLoan => '借钱给人、找人借钱',
                    Debt.kindCredit => '赊账、垫付、代付，回头要结的钱',
                    Debt.kindFavor => '份子钱、礼金往来：随出去的、收下的，记着以后还',
                    _ => '别的往来',
                  },
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          PickerField(
            label: '对方',
            child: TextField(
              key: const ValueKey('debt-counterparty'),
              controller: _counterparty,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(hintText: '例如「张三」「小王」「李阿姨」'),
            ),
          ),
          if (!_editing)
            PickerField(
              label: _favor ? '礼金' : '金额',
              child: TextField(
                key: const ValueKey('debt-amount'),
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(prefixText: '¥ ', hintText: '5000'),
              ),
            ),
          PickerField(
            label: '哪天',
            child: DayButton(
              day: _startedOn,
              onPressed: () async {
                final picked = await pickPastDay(context, initial: _startedOn, help: '哪天的事');
                if (picked != null) setState(() => _startedOn = picked);
              },
            ),
          ),
        ],
        side: [
          PickerField(
            label: '约定哪天还（选填）',
            topGap: LedgerLayout.pagePadding,
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('debt-due'),
                    onPressed: () async {
                      final picked = await pickAnyDay(
                        context,
                        initial: _dueOn ?? _startedOn.add(const Duration(days: 30)),
                        first: _startedOn,
                        help: '约定哪天还',
                      );
                      if (picked != null) setState(() => _dueOn = picked);
                    },
                    icon: const Icon(Icons.event_outlined, size: 18),
                    label: Text(_dueOn == null ? '没约定' : Dates.dayLabel(_dueOn!)),
                  ),
                ),
                if (_dueOn != null)
                  IconButton(
                    tooltip: '不约定了',
                    onPressed: () => setState(() => _dueOn = null),
                    icon: const Icon(Icons.close),
                  ),
              ],
            ),
          ),
          const SizedBox(height: LedgerLayout.itemGap),
          SwitchListTile(
            key: const ValueKey('debt-counted'),
            value: _counted,
            onChanged: (v) => setState(() {
              _counted = v;
              _countedTouched = true;
            }),
            title: const Text('计入净资产'),
            subtitle: Text(_favor ? '人情默认不算：是情分，不一定按钱还' : '别人欠我的算资产、我欠别人的算负债'),
          ),
          if (!_editing) ...[
            SwitchListTile(
              key: const ValueKey('debt-record'),
              value: _record,
              onChanged: (v) => setState(() => _record = v),
              title: Text(_favor ? '同时记一笔支出 / 收入' : '同时记一笔转账'),
              subtitle: Text(
                _record
                    ? (_favor ? '礼金是真花出去 / 收进来的钱，记进人情类别' : '钱经过下面的账户，不算支出也不算收入')
                    : '不记流水：以前的旧账，只记个数',
              ),
            ),
            if (_record)
              PickerField(
                label: _accountLabel,
                topGap: LedgerLayout.itemGap,
                child: AccountPicker(
                  keyPrefix: 'debt-account',
                  accounts: ledger.activeAccounts,
                  selectedId: _accountId,
                  emptyHint: '还没有账户',
                  onSelected: (id) => setState(() => _accountId = id),
                ),
              ),
          ],
          PickerField(
            label: '备注（选填）',
            child: TextField(
              key: const ValueKey('debt-note'),
              controller: _note,
              maxLines: 2,
              decoration: const InputDecoration(hintText: '借条、利息、谁经手的'),
            ),
          ),
        ],
        bottom: [
          const SizedBox(height: LedgerLayout.itemGap),
          FormSubmit(label: _editing ? '保存' : '记好了', busy: _busy, error: _error, onPressed: _save),
        ],
      ),
    );
  }
}
