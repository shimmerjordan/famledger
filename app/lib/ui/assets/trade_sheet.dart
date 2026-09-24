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
import '../widgets/widgets.dart';
import 'asset_providers.dart';
import 'asset_widgets.dart';

/// 加仓 / 减仓。[buy] 决定打开时选哪边，弹层里还能切。成功返回 true。
Future<bool?> showTradeSheet(
  BuildContext context,
  Holding holding, {
  required bool buy,
}) => showModalBottomSheet<bool>(
  context: context,
  isScrollControlled: true,
  builder: (context) => TradeSheet(holding: holding, buy: buy),
);

class TradeSheet extends ConsumerStatefulWidget {
  const TradeSheet({super.key, required this.holding, required this.buy});

  final Holding holding;
  final bool buy;

  @override
  ConsumerState<TradeSheet> createState() => _TradeSheetState();
}

class _TradeSheetState extends ConsumerState<TradeSheet> {
  final TextEditingController _quantity = TextEditingController();
  final TextEditingController _amount = TextEditingController();
  late bool _buy = widget.buy || widget.holding.isCleared;
  late DateTime _day = _today();

  /// 没挂投资账户就记不了转账（服务端 400 holding_needs_account），开关默认跟着它走。
  late bool _record = widget.holding.accountId != null;
  String? _accountId;
  bool _busy = false;
  String? _error;

  /// 幂等键：弹层开着期间的每次重试都沿用它。请求落库了回应却丢了，再点一次服务端认得出，
  /// 不会把份额、移动平均成本和已实现盈亏再改一遍。
  final String _clientId = newClientId();

  Holding get _h => widget.holding;

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
    final picked = await pickPastDay(context, initial: _day, help: '哪天成交的');
    if (picked != null) setState(() => _day = picked);
  }

  Future<void> _submit() async {
    final quantity = parseE4(_quantity.text);
    if (quantity == null || quantity <= 0) {
      setState(() => _error = '份额填得不对，例如 100');
      return;
    }
    if (!_buy && quantity > _h.quantityE4) {
      setState(() => _error = '最多能卖 ${formatE4(_h.quantityE4)} 份');
      return;
    }
    final amount = parseMoneyField(_amount.text);
    if (amount == null || amount < 0) {
      setState(() => _error = _buy ? '花了多少钱？例如 3500' : '卖得多少钱？例如 5000');
      return;
    }
    if (_record && _accountId == null) {
      setState(() => _error = '选一个账户，或关掉「同时记一笔转账」');
      return;
    }
    final preview = _buy ? null : previewSell(_h, quantity, amount);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await ref.read(holdingsRepoProvider).trade(
        _h.id,
        buy: _buy,
        quantityE4: quantity,
        amountCents: amount,
        occurredOn: Dates.isoDate(_day),
        accountId: _record ? _accountId : null,
        clientId: _clientId,
      );
      if (result.transactions.isNotEmpty) refreshMoneyViews(ref);
      if (!mounted) return;
      final realized = preview?.realizedCents;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            // 回放的是第一次提交的结果，这次改过的数不一定是记上的那份，别按输入框里的说。
            result.replayed
                ? '刚才那次其实已经记上了，没有重复记'
                : _buy
                ? '已加仓 ${formatE4(quantity)} 份'
                : '已减仓 ${formatE4(quantity)} 份'
                      '${realized == null ? '' : '，已实现 ${Money.format(realized, signed: true)}'}',
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
    final ledger = ref.watch(ledgerProvider).valueOrNull;
    final counterAccounts = (ledger?.activeAccounts ?? const <Account>[])
        .where((a) => a.id != _h.accountId && a.kind != 'invest')
        .toList();
    final quantity = parseE4(_quantity.text);
    final amount = parseMoneyField(_amount.text);
    final preview = !_buy && quantity != null && amount != null && amount >= 0
        ? previewSell(_h, quantity, amount)
        : null;

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
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: LedgerLayout.pagePadding,
                ),
                child: SegmentedButton<bool>(
                  segments: [
                    const ButtonSegment(value: true, label: Text('加仓')),
                    ButtonSegment(
                      value: false,
                      label: const Text('减仓'),
                      enabled: !_h.isCleared,
                    ),
                  ],
                  selected: {_buy},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) => setState(() {
                    _buy = s.first;
                    _error = null;
                  }),
                ),
              ),
              PickerField(
                label: _buy ? '买了多少份' : '卖了多少份',
                topGap: LedgerLayout.itemGap,
                trailing: _buy
                    ? null
                    : TextButton(
                        onPressed: () => setState(
                          () => _quantity.text = formatE4(_h.quantityE4)
                              .replaceAll(',', ''),
                        ),
                        child: Text('全部 ${formatE4(_h.quantityE4)}'),
                      ),
                child: TextField(
                  key: const ValueKey('trade-quantity'),
                  controller: _quantity,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(hintText: '100', suffixText: '份'),
                ),
              ),
              PickerField(
                label: _buy ? '花了多少' : '卖得多少',
                trailing: Text('含手续费', style: theme.textTheme.bodySmall),
                child: TextField(
                  key: const ValueKey('trade-amount'),
                  controller: _amount,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(prefixText: '¥ ', hintText: '3500'),
                ),
              ),
              if (preview != null)
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
                          Text('预计已实现盈亏 ', style: theme.textTheme.bodyMedium),
                          MoneyText(preview.realizedCents, signed: true),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '按平均成本摊 ${Money.format(preview.costCents)}，'
                        '剩 ${formatE4(preview.remainingQuantityE4)} 份',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              PickerField(
                label: '哪天成交的',
                child: DayButton(day: _day, onPressed: _pickDay),
              ),
              const SizedBox(height: LedgerLayout.itemGap),
              SwitchListTile(
                key: const ValueKey('trade-record'),
                value: _record,
                onChanged: _h.accountId == null
                    ? null
                    : (v) => setState(() => _record = v),
                title: const Text('同时记一笔转账'),
                subtitle: Text(
                  _h.accountId == null
                      ? '这笔持仓没挂投资账户，编辑挂上才能记'
                      : _buy
                      ? '钱从下面的账户转进投资账户'
                      : '卖得的钱转回下面的账户，盈亏另记一笔',
                ),
              ),
              if (_record)
                PickerField(
                  label: _buy ? '从哪个账户转出' : '钱转回哪个账户',
                  topGap: LedgerLayout.itemGap,
                  child: AccountPicker(
                    keyPrefix: 'trade-account',
                    accounts: counterAccounts,
                    selectedId: _accountId,
                    emptyHint: '还没有别的账户',
                    onSelected: (id) => setState(() => _accountId = id),
                  ),
                ),
              FormSubmit(
                label: _buy ? '加仓' : '减仓',
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
