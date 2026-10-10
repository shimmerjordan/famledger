import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../core/ids.dart';
import '../../core/money.dart';
import '../../data/models/models.dart';
import '../../data/repos/holdings_repo.dart';
import '../add_tx/account_picker.dart';
import '../add_tx/picker_field.dart';
import '../widgets/widgets.dart';
import 'asset_providers.dart';
import 'asset_widgets.dart';

/// 这笔理财能做哪几种交易，按记法分：份额类 加仓 / 减仓 / 分红；金额类 存入 / 取出；
/// 定期类 到期取出 / 收到利息（不能追加）。
List<TradeSide> tradeSidesOf(Holding h) => switch (h.mode) {
  InvestMode.unit => const [TradeSide.buy, TradeSide.sell, TradeSide.income],
  InvestMode.balance => const [TradeSide.buy, TradeSide.sell],
  InvestMode.deposit => const [TradeSide.sell, TradeSide.income],
};

/// 按钮、标题上的叫法。
String tradeLabel(Holding h, TradeSide side) => switch ((h.mode, side)) {
  (InvestMode.unit, TradeSide.buy) => '加仓',
  (InvestMode.unit, TradeSide.sell) => '减仓',
  (InvestMode.unit, TradeSide.income) => '分红',
  (InvestMode.balance, TradeSide.buy) => '存入',
  (InvestMode.balance, TradeSide.sell) => '取出',
  (InvestMode.balance, TradeSide.income) => '收益到账',
  (InvestMode.deposit, TradeSide.buy) => '追加',
  (InvestMode.deposit, TradeSide.sell) => '到期取出',
  (InvestMode.deposit, TradeSide.income) => '收到利息',
};

/// 加仓 / 减仓 / 分红 / 存取。[side] 决定打开时选哪边，弹层里还能切。成功返回 true。
Future<bool?> showTradeSheet(
  BuildContext context,
  Holding holding, {
  required TradeSide side,
}) => showModalBottomSheet<bool>(
  useRootNavigator: true,
  context: context,
  isScrollControlled: true,
  builder: (context) => TradeSheet(holding: holding, side: side),
);

class TradeSheet extends ConsumerStatefulWidget {
  const TradeSheet({super.key, required this.holding, required this.side});

  final Holding holding;
  final TradeSide side;

  @override
  ConsumerState<TradeSheet> createState() => _TradeSheetState();
}

class _TradeSheetState extends ConsumerState<TradeSheet> {
  final TextEditingController _quantity = TextEditingController();
  late final TextEditingController _amount = TextEditingController(text: _defaultAmount(widget.side));
  late TradeSide _side = _initialSide();
  late DateTime _day = _today();

  /// 买卖：没挂投资账户就记不了转账（服务端 400 holding_needs_account），开关默认跟着它走。
  /// 分红、付息：钱落到哪个账户都行，默认记。
  late bool _record = _side == TradeSide.income || widget.holding.accountId != null;
  String? _accountId;
  bool _busy = false;
  String? _error;

  /// 幂等键：弹层开着期间的每次重试都沿用它。请求落库了回应却丢了，再点一次服务端认得出，
  /// 不会把份额、移动平均成本和已实现盈亏再改一遍。
  final String _clientId = newClientId();

  Holding get _h => widget.holding;
  bool get _unit => _h.mode == InvestMode.unit;

  TradeSide _initialSide() {
    final sides = tradeSidesOf(_h);
    final want = _h.isCleared && widget.side == TradeSide.sell ? TradeSide.buy : widget.side;
    return sides.contains(want) ? want : sides.first;
  }

  /// 定期到期取出：先填上按年化算该拿多少（本金 + 利息），多数时候直接点就行。
  String _defaultAmount(TradeSide side) {
    if (_h.mode != InvestMode.deposit || side != TradeSide.sell) return '';
    final value = holdingValueCents(_h, ref.read(assetClockProvider)());
    return value == null ? '' : Money.input(value);
  }

  DateTime _today() {
    final now = ref.read(assetClockProvider)();
    return DateTime(now.year, now.month, now.day);
  }

  @override
  void dispose() {
    _quantity.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _pickDay() async {
    final picked = await pickPastDay(context, initial: _day, help: '哪天的事');
    if (picked != null) setState(() => _day = picked);
  }

  String? _amountHint() => switch ((_h.mode, _side)) {
    (InvestMode.unit, TradeSide.buy) => '花了多少钱？例如 3500',
    (InvestMode.unit, TradeSide.sell) => '卖得多少钱？例如 5000',
    (_, TradeSide.income) => '到账多少？例如 120',
    (InvestMode.balance, TradeSide.buy) => '存进去多少？例如 1000',
    (InvestMode.balance, TradeSide.sell) => '取出来多少？例如 1000',
    _ => '到手多少（本金 + 利息）？',
  };

  Future<void> _submit() async {
    int? quantity;
    final tradesUnits = _unit && _side != TradeSide.income;
    if (tradesUnits) {
      quantity = parseE4(_quantity.text);
      if (quantity == null || quantity <= 0) {
        setState(() => _error = '份额填得不对，例如 100');
        return;
      }
      if (_side == TradeSide.sell && quantity > _h.quantityE4) {
        setState(() => _error = '最多能卖 ${formatE4(_h.quantityE4)} 份');
        return;
      }
    }
    final amount = parseMoneyField(_amount.text);
    if (amount == null || amount < 0 || (_side == TradeSide.income && amount == 0)) {
      setState(() => _error = _amountHint());
      return;
    }
    if (_h.mode == InvestMode.balance && _side == TradeSide.sell && amount > (_h.valueCents ?? _h.costCents)) {
      setState(() => _error = '最多能取 ${Money.format(_h.valueCents ?? _h.costCents)}');
      return;
    }
    if (_record && _accountId == null) {
      setState(() => _error = _side == TradeSide.income ? '选一个到账的账户，或关掉「同时记一笔」' : '选一个账户，或关掉「同时记一笔转账」');
      return;
    }
    final realized = _preview(quantity, amount);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await ref.read(holdingsRepoProvider).trade(
        _h.id,
        side: _side,
        quantityE4: quantity,
        amountCents: amount,
        occurredOn: Dates.isoDate(_day),
        accountId: _record ? _accountId : null,
        clientId: _clientId,
      );
      if (result.transactions.isNotEmpty) refreshMoneyViews(ref);
      if (!mounted) return;
      final verb = tradeLabel(_h, _side);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            // 回放的是第一次提交的结果，这次改过的数不一定是记上的那份，别按输入框里的说。
            result.replayed
                ? '刚才那次其实已经记上了，没有重复记'
                : [
                    tradesUnits ? '已$verb ${formatE4(quantity!)} 份' : '已$verb ${Money.format(amount)}',
                    if (realized != null && _side == TradeSide.sell) '已实现 ${Money.format(realized, signed: true)}',
                  ].join('，'),
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

  /// 卖出 / 取出 / 到期的预计已实现收益；算不出来是 null。
  int? _preview(int? quantity, int? amount) {
    if (_side != TradeSide.sell || amount == null || amount < 0) return null;
    return switch (_h.mode) {
      InvestMode.unit => quantity == null ? null : previewSell(_h, quantity, amount)?.realizedCents,
      InvestMode.balance => previewWithdraw(_h, amount)?.realizedCents,
      InvestMode.deposit => amount - _h.costCents,
    };
  }

  String _previewNote(int? quantity, int? amount) {
    if (amount == null) return '';
    switch (_h.mode) {
      case InvestMode.unit:
        final p = quantity == null ? null : previewSell(_h, quantity, amount);
        return p == null ? '' : '按平均成本摊 ${Money.format(p.costCents)}，剩 ${formatE4(p.remainingQuantityE4)} 份';
      case InvestMode.balance:
        final p = previewWithdraw(_h, amount);
        return p == null ? '' : '按比例摊本金 ${Money.format(p.costCents)}，剩本金 ${Money.format(p.remainingCostCents)}';
      case InvestMode.deposit:
        return '本金 ${Money.format(_h.costCents)}，取出后这笔就结清了';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ledger = ref.watch(ledgerProvider).valueOrNull;
    final accounts = ledger?.activeAccounts ?? const <Account>[];
    // 买卖记转账：对手是别的非投资账户；分红付息记收入：哪个账户都行（证券户、银行卡）。
    final pickable = _side == TradeSide.income
        ? accounts
        : accounts.where((a) => a.id != _h.accountId && a.kind != 'invest').toList();
    final quantity = parseE4(_quantity.text);
    final amount = parseMoneyField(_amount.text);
    final realized = _preview(quantity, amount);
    final sides = tradeSidesOf(_h);
    final verb = tradeLabel(_h, _side);
    final tradesUnits = _unit && _side != TradeSide.income;
    final canRecord = _side == TradeSide.income || _h.accountId != null;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: LedgerLayout.pagePadding),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionHeader(_h.label),
              if (sides.length > 1)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
                  child: SegmentedButton<TradeSide>(
                    segments: [
                      for (final s in sides)
                        ButtonSegment(
                          value: s,
                          label: Text(tradeLabel(_h, s)),
                          enabled: s != TradeSide.sell || !_h.isCleared,
                        ),
                    ],
                    selected: {_side},
                    showSelectedIcon: false,
                    onSelectionChanged: (s) => setState(() {
                      _side = s.first;
                      _error = null;
                      _record = _side == TradeSide.income || _h.accountId != null;
                      _accountId = null;
                      if (_amount.text.isEmpty) _amount.text = _defaultAmount(_side);
                    }),
                  ),
                ),
              if (tradesUnits)
                PickerField(
                  label: _side == TradeSide.buy ? '买了多少份' : '卖了多少份',
                  topGap: LedgerLayout.itemGap,
                  trailing: _side == TradeSide.buy
                      ? null
                      : TextButton(
                          onPressed: () => setState(
                            () => _quantity.text = formatE4(_h.quantityE4).replaceAll(',', ''),
                          ),
                          child: Text('全部 ${formatE4(_h.quantityE4)}'),
                        ),
                  child: TextField(
                    key: const ValueKey('trade-quantity'),
                    controller: _quantity,
                    autofocus: true,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(hintText: '100', suffixText: _h.kind == Holding.kindGold ? '克' : '份'),
                  ),
                ),
              PickerField(
                label: switch ((_h.mode, _side)) {
                  (InvestMode.unit, TradeSide.buy) => '花了多少',
                  (InvestMode.unit, TradeSide.sell) => '卖得多少',
                  (_, TradeSide.income) => '到账多少',
                  (InvestMode.balance, TradeSide.buy) => '存入多少',
                  (InvestMode.balance, TradeSide.sell) => '取出多少',
                  _ => '到手多少（本金 + 利息）',
                },
                topGap: tradesUnits ? LedgerLayout.groupGap : LedgerLayout.itemGap,
                trailing: switch ((_h.mode, _side)) {
                  (InvestMode.unit, TradeSide.buy || TradeSide.sell) => Text('含手续费', style: theme.textTheme.bodySmall),
                  (InvestMode.balance, TradeSide.sell) => TextButton(
                    onPressed: () => setState(() => _amount.text = Money.input(_h.valueCents ?? _h.costCents)),
                    child: Text('全部 ${Money.format(_h.valueCents ?? _h.costCents)}'),
                  ),
                  _ => null,
                },
                child: TextField(
                  key: const ValueKey('trade-amount'),
                  controller: _amount,
                  autofocus: !tradesUnits,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(prefixText: '¥ ', hintText: '0.00'),
                ),
              ),
              if (realized != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    LedgerLayout.pagePadding,
                    LedgerLayout.itemGap,
                    LedgerLayout.pagePadding,
                    0,
                  ),
                  child: Column(
                    key: const ValueKey('trade-preview'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(_unit ? '预计已实现盈亏 ' : '这次的收益 ', style: theme.textTheme.bodyMedium),
                          MoneyText(realized, signed: true),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(_previewNote(quantity, amount), style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
              PickerField(
                label: '哪天',
                child: DayButton(day: _day, onPressed: _pickDay),
              ),
              const SizedBox(height: LedgerLayout.itemGap),
              SwitchListTile(
                key: const ValueKey('trade-record'),
                value: _record,
                onChanged: canRecord ? (v) => setState(() => _record = v) : null,
                title: Text(_side == TradeSide.income ? '同时记一笔收入' : '同时记一笔转账'),
                subtitle: Text(
                  !canRecord
                      ? '这笔没挂投资账户，编辑挂上才能记'
                      : _side == TradeSide.income
                      ? '记成「投资收益」，落到下面的账户'
                      : _side == TradeSide.buy
                      ? '钱从下面的账户转进投资账户'
                      : '钱转回下面的账户，收益另记一笔',
                ),
              ),
              if (_record)
                PickerField(
                  label: _side == TradeSide.buy ? '从哪个账户转出' : '钱到哪个账户',
                  topGap: LedgerLayout.itemGap,
                  child: AccountPicker(
                    keyPrefix: 'trade-account',
                    accounts: pickable,
                    selectedId: _accountId,
                    emptyHint: '还没有别的账户',
                    onSelected: (id) => setState(() => _accountId = id),
                  ),
                ),
              FormSubmit(label: verb, busy: _busy, error: _error, onPressed: _submit),
            ],
          ),
        ),
      ),
    );
  }
}
