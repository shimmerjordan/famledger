import 'dart:async';

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
import '../transactions/pick_tx_sheet.dart';
import '../widgets/widgets.dart';
import 'debt_widgets.dart';

/// 记一笔 / 编辑债务：别人欠我还是我欠别人、借款还是人情、对方、多少、哪天、约定哪天还。
///
/// 新建时默认「同时记一笔」：借款记成真账户和这笔债务之间的转账（不算支出），人情记成一笔
/// 支出 / 收入（类别「人情」）。平时金额经详情页的「收回 / 再借」改；记错了在编辑页直接改总额、还剩多少
/// （校准，留一行备忘），还没有往来流水时方向、币种也能改。
/// 新建时能顺带填「已经收回 / 已经还了」多少（以前的账收回过一部分），存的时候一起记，不用建完再去点「收回」。
/// 钱已经被自动记账 / 导入记成一笔支出 / 收入的，勾「这笔钱已经记过流水了」选那笔：服务端把它改成转账，账户不会扣两次；
/// 从流水详情「记成一笔新债务」进来时（[txId]）直接按那笔预填并关联。
class DebtFormPage extends ConsumerStatefulWidget {
  const DebtFormPage({super.key, this.id, this.txId});

  final String? id;

  /// 新建时按这笔流水预填（金额、日期、方向、币种）并关联它。
  final String? txId;

  @override
  ConsumerState<DebtFormPage> createState() => _DebtFormPageState();
}

class _DebtFormPageState extends ConsumerState<DebtFormPage> {
  final TextEditingController _counterparty = TextEditingController();
  final TextEditingController _amount = TextEditingController();
  final TextEditingController _settled = TextEditingController();
  final TextEditingController _note = TextEditingController();

  /// 编辑时的「还剩多少」：改了就是校准（服务端按差额改内部账户、留一行「校准」）。
  final TextEditingController _remaining = TextEditingController();
  bool _remainingTouched = false;
  int? _origRemaining;
  int _origTotal = 0;
  String _origDirection = Debt.lend;
  String _origCurrency = 'CNY';

  /// 家里谁的（null = 家庭共用）。新建默认是自己；编辑时原样带回去（不带会被清掉）。
  late String? _memberId = ref.read(sessionProvider)?.me.id;

  String _direction = Debt.lend;

  /// 这笔债是什么币；只在新建时定（服务端建好后不让改）。钱经过的账户只列同币种的。
  late String _currency = ref.read(baseCurrencyProvider);
  String _kind = Debt.kindLoan;
  late DateTime _startedOn = _today();
  DateTime? _dueOn;
  bool _counted = true;

  /// 用户亲手点过「计入净资产」：换类型时不再按类型改它。
  bool _countedTouched = false;
  bool _record = true;
  String? _accountId;

  /// 「这笔钱已经记过流水了」：选一笔已有的支出 / 收入当起始那笔，不再新记。
  bool _linkExisting = false;
  Transaction? _linkedTx;
  bool _txLoading = false;
  String? _txError;
  bool _bound = false;
  bool _busy = false;
  String? _error;
  final String _clientId = newClientId();

  bool get _editing => widget.id != null;
  bool get _favor => _kind == Debt.kindFavor;

  /// 要关联的那笔是支出还是收入：借出（随礼）是花出去的钱，借入（收礼）是收进来的钱。
  String get _linkType => _direction == Debt.lend ? Transaction.typeExpense : Transaction.typeIncome;

  DateTime _today() {
    final now = ref.read(assetClockProvider)();
    return DateTime(now.year, now.month, now.day);
  }

  @override
  void initState() {
    super.initState();
    final txId = widget.txId;
    if (txId != null && !_editing) unawaited(_prefillFrom(txId));
  }

  /// 从流水详情「记成一笔新债务」进来：按那笔预填金额、日期、方向、币种，并直接进入「已记过流水」模式。
  Future<void> _prefillFrom(String txId) async {
    setState(() => _txLoading = true);
    try {
      final tx = await ref.read(transactionsRepoProvider).get(txId);
      if (!mounted) return;
      setState(() {
        _txLoading = false;
        _record = true;
        _linkExisting = true;
        _linkedTx = tx;
        _direction = tx.isIncome ? Debt.borrow : Debt.lend;
        _currency = tx.currency;
        _amount.text = Money.input(tx.amountCents);
        _startedOn = DateTime(tx.occurredAt.year, tx.occurredAt.month, tx.occurredAt.day);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _txLoading = false;
        _txError = describeError(error);
      });
    }
  }

  Future<void> _pickTx() async {
    final tx = await showPickTransactionSheet(
      context,
      type: _linkType,
      currency: _currency,
      amountCents: parseMoneyField(_amount.text),
    );
    if (tx == null || !mounted) return;
    setState(() {
      _linkedTx = tx;
      _amount.text = Money.input(tx.amountCents);
      _error = null;
    });
  }

  @override
  void dispose() {
    _counterparty.dispose();
    _amount.dispose();
    _settled.dispose();
    _note.dispose();
    _remaining.dispose();
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
    _memberId = d.memberId;
    _currency = d.currency;
    _origCurrency = d.currency;
    _origDirection = d.direction;
    _origTotal = d.amountCents;
    _amount.text = Money.input(d.amountCents);
    _origRemaining = outstandingOf(d, ref.read(debtBalancesProvider));
    if (_origRemaining != null) _remaining.text = Money.input(_origRemaining!);
  }

  /// 编辑时改总额：还剩多少没亲手改过就跟着挪同样多（起始那笔记错了，两个数一起错）。
  void _onTotalChanged(String text) {
    if (!_editing || _remainingTouched || _origRemaining == null) return;
    final total = Money.tryParse(text);
    if (total == null) return;
    _remaining.text = Money.input(_origRemaining! + total - _origTotal);
  }

  void _setKind(String kind) => setState(() {
    _kind = kind;
    // 人情是情分不是钱：默认不进净资产（用户自己改过就听用户的）。
    if (!_countedTouched) _counted = kind != Debt.kindFavor;
    _accountId = null;
    _linkedTx = null;
  });

  /// 「已经收回」那一栏怎么叫：借出是收回，借入是还；人情是收回 / 还的人情。
  String get _settledLabel => switch ((_direction == Debt.lend, _favor)) {
    (true, false) => '已经收回（选填）',
    (false, false) => '已经还了（选填）',
    (true, true) => '已经收回的人情（选填）',
    (false, true) => '已经还的人情（选填）',
  };

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
      final total = parseMoneyField(_amount.text);
      if (total == null || total <= 0) {
        setState(() => _error = '总额填得不对，例如 5000');
        return;
      }
      int? remaining;
      if (_remaining.text.trim().isNotEmpty) {
        remaining = Money.tryParse(_remaining.text);
        if (remaining == null) {
          setState(() => _error = '还剩多少填得不对，例如 2000（多还了写负数）');
          return;
        }
      }
      final calibrate = remaining != null && remaining != _origRemaining;
      return _submit(() async {
        await repo.edit(
          widget.id!,
          kind: _kind,
          counterparty: counterparty,
          startedOn: Dates.isoDate(_startedOn),
          dueOn: dueOn,
          counted: _counted,
          memberId: _memberId,
          note: _note.text.trim(),
          amountCents: total != _origTotal ? total : null,
          remainingCents: calibrate ? remaining : null,
          direction: _direction != _origDirection ? _direction : null,
          currency: _currency != _origCurrency ? _currency : null,
        );
        if (calibrate) refreshMoneyViews(ref);
        return calibrate ? '已保存，还剩 ${Money.format(remaining!, currency: _currency)}' : '已保存';
      });
    }
    // 关联已有流水时金额跟着那笔走：先问选了没有，再看金额。
    final linking = _record && _linkExisting;
    if (linking && _linkedTx == null) {
      setState(() => _error = '选那笔流水，或关掉「这笔钱已经记过流水了」');
      return;
    }
    final amount = parseMoneyField(_amount.text);
    if (amount == null || amount <= 0) {
      setState(() => _error = '多少钱？例如 5000');
      return;
    }
    final settled = parseMoneyField(_settled.text);
    if (settled == -1) {
      setState(() => _error = '「${_settledLabel.replaceAll('（选填）', '')}」填得不对，例如 2000');
      return;
    }
    if (settled != null && settled > amount) {
      setState(() => _error = switch ((_direction == Debt.lend, _favor)) {
        (true, false) => '收回的不能比借出去的还多',
        (false, false) => '还掉的不能比借来的还多',
        (true, true) => '收回的人情不能比随出去的还多',
        (false, true) => '还的人情不能比收下的还多',
      });
      return;
    }
    if (_record && !linking && _accountId == null) {
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
        memberId: _memberId,
        note: _note.text.trim(),
        accountId: _record && !linking ? _accountId : null,
        transactionId: linking ? _linkedTx!.id : null,
        settledCents: settled,
        currency: _currency == ref.read(baseCurrencyProvider) ? null : _currency,
        clientId: _clientId,
      );
      refreshMoneyViews(ref);
      final back = settled ?? 0;
      return [
        '记好了',
        if (linking)
          _favor ? '那笔${_direction == Debt.lend ? '支出' : '收入'}算作这份人情的钱，没再记一笔' : '那笔流水变成了转账，账户不会扣两次'
        else if (_record)
          back > 0 ? '记了 ${Money.format(amount)} 和 ${Money.format(back)} 两笔流水' : '也记了一笔 ${Money.format(amount)}',
        if (back > 0) back == amount ? '已结清' : '还剩 ${Money.format(amount - back)}',
      ].join('，');
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
    // 总览晚到一步：到了再补上「还剩多少」的初值。
    if (debt != null && _origRemaining == null) {
      _origRemaining = outstandingOf(debt, ref.watch(debtBalancesProvider));
      if (_origRemaining != null) _remaining.text = Money.input(_origRemaining! + (Money.tryParse(_amount.text) ?? _origTotal) - _origTotal);
    }
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
          PickerField(
              label: '方向',
              topGap: LedgerLayout.pagePadding,
              trailing: _editing ? Text('有往来流水时不能改', style: theme.textTheme.bodySmall) : null,
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
                  // 方向换了，要关联的就从支出换成收入（或反过来），原来选的那笔不算数。
                  _linkedTx = null;
                }),
              ),
            ),
          PickerField(
            label: '类型',
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
          PickerField(
              label: _editing ? (_favor ? '礼金总额' : '总额') : (_favor ? '礼金' : '金额'),
              trailing: _editing ? Text('借出 / 借入一共多少', style: theme.textTheme.bodySmall) : null,
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('debt-amount'),
                      controller: _amount,
                      onChanged: _onTotalChanged,
                      // 关联了已有流水：金额跟着那笔走（服务端要求一样），改金额就换一笔。
                      readOnly: _linkedTx != null,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        prefixText: '${Money.symbolFor(_currency).trim()} ',
                        hintText: '5000',
                        helperText: _linkedTx == null ? null : '金额跟着那笔流水；改金额就换一笔',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 换了币种，原来选的账户不一定还是同币种的；编辑时有往来流水服务端不让改（409，原话照显示）。
                  CurrencyDropdown(
                    key: const ValueKey('debt-currency'),
                    value: _currency,
                    keyPrefix: 'debt-currency',
                    onChanged: (c) => setState(() {
                      _currency = c;
                      _accountId = null;
                      _linkedTx = null;
                    }),
                  ),
                ],
              ),
            ),
          if (_editing && _origRemaining != null)
            PickerField(
              label: '还剩多少',
              trailing: Text('和实际对不上就直接改；留一行「校准」备忘', style: theme.textTheme.bodySmall),
              child: TextField(
                key: const ValueKey('debt-remaining'),
                controller: _remaining,
                onChanged: (_) => _remainingTouched = true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                decoration: InputDecoration(prefixText: '${Money.symbolFor(_currency).trim()} '),
              ),
            ),
          if (!_editing)
            PickerField(
              label: _settledLabel,
              // 钱怎么走跟着「同时记一笔」：记了借出那笔，收回的也经同一个账户记，账户才对得上。
              trailing: Text(_record ? '也经选的账户记一笔' : '只调还剩多少，不记账', style: theme.textTheme.bodySmall),
              child: TextField(
                key: const ValueKey('debt-settled'),
                controller: _settled,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  prefixText: '${Money.symbolFor(_currency).trim()} ',
                  hintText: _direction == Debt.lend ? '以前收回过一部分就填' : '以前还过一部分就填',
                ),
              ),
            ),
          PickerField(
            label: '家里谁的',
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  key: const ValueKey('debt-member-none'),
                  selected: _memberId == null,
                  onSelected: (_) => setState(() => _memberId = null),
                  label: const Text('家庭共用'),
                ),
                for (final m in ledger.activeMembers)
                  ChoiceChip(
                    key: ValueKey('debt-member-${m.id}'),
                    selected: _memberId == m.id,
                    onSelected: (_) => setState(() => _memberId = m.id),
                    label: Text(m.label),
                  ),
              ],
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
            if (_record) ...[
              // 钱已经被自动记账 / 导入记过了：选那笔，服务端把它改成转账，不再新记、账户不扣两次。
              SwitchListTile(
                key: const ValueKey('debt-link-existing'),
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
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            OutlinedButton.icon(
                              key: const ValueKey('debt-pick-tx'),
                              onPressed: _txLoading ? null : _pickTx,
                              icon: const Icon(Icons.receipt_long_outlined, size: 18),
                              label: Text(_txLoading ? '正在读那笔流水…' : '选流水'),
                            ),
                            if (_txError != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(
                                  '那笔流水读不出来：$_txError',
                                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                                ),
                              ),
                          ],
                        )
                      : LinkedTxRow(key: const ValueKey('debt-linked-tx'), tx: _linkedTx!, ledger: ledger, onTap: _pickTx),
                )
              else
                PickerField(
                  label: _accountLabel,
                  topGap: LedgerLayout.itemGap,
                  child: AccountPicker(
                    keyPrefix: 'debt-account',
                    accounts: [
                      for (final a in ledger.activeAccounts)
                        if (a.currency.toUpperCase() == _currency.toUpperCase()) a,
                    ],
                    selectedId: _accountId,
                    emptyHint: '还没有账户',
                    onSelected: (id) => setState(() => _accountId = id),
                  ),
                ),
            ],
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
