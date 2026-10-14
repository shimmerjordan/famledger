import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/money.dart';
import '../../data/models/models.dart';
import '../add_tx/picker_field.dart';
import '../assets/asset_providers.dart' show refreshMoneyViews;
import '../widgets/widgets.dart';
import 'fund_providers.dart';

/// 校准板块余额：一种币一行，填「现在实际有多少」。服务端把差额记进期初余额（`PATCH /funds/:id`
/// 的 `currentBalances`）——不多记一笔流水，不算进本月收支。没出现过的币也能加一行。
/// 改过就返回 true。
Future<bool?> showFundCalibrateSheet(
  BuildContext context, {
  required Fund fund,
  required CurrencyAmounts balances,
}) => showModalBottomSheet<bool>(
  useRootNavigator: true,
  context: context,
  isScrollControlled: true,
  builder: (context) => _CalibrateSheet(fund: fund, balances: balances),
);

class _CalibrateSheet extends ConsumerStatefulWidget {
  const _CalibrateSheet({required this.fund, required this.balances});

  final Fund fund;
  final CurrencyAmounts balances;

  @override
  ConsumerState<_CalibrateSheet> createState() => _CalibrateSheetState();
}

class _CalibrateSheetState extends ConsumerState<_CalibrateSheet> {
  final Map<String, TextEditingController> _fields = {};
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final base = ref.read(baseCurrencyProvider).toUpperCase();
    final keys = {base, ...widget.balances.nonZero.keys.map((c) => c.toUpperCase())}.toList()
      ..sort((a, b) => a == base ? -1 : b == base ? 1 : a.compareTo(b));
    for (final c in keys) {
      _fields[c] = TextEditingController(text: Money.input(_current(c)));
    }
  }

  int _current(String currency) => widget.balances.values[currency] ?? widget.balances.values[currency.toLowerCase()] ?? 0;

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _add(String currency) {
    if (_fields.containsKey(currency)) return;
    setState(() => _fields[currency] = TextEditingController(text: '0.00'));
  }

  Future<void> _save() async {
    final changed = <String, int>{};
    for (final e in _fields.entries) {
      final cents = Money.tryParse(e.value.text);
      if (cents == null) {
        setState(() => _error = '${currencyName(e.key)}的金额填得不对，例如 1234.56（欠着就写负数）');
        return;
      }
      if (cents != _current(e.key)) changed[e.key] = cents;
    }
    if (changed.isEmpty) {
      Navigator.of(context).pop(false);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(ledgerRepoProvider).updateFund(widget.fund.id, {'currentBalances': changed});
      ref.invalidate(ledgerProvider);
      refreshMoneyViews(ref);
      ref.invalidate(fundStatsProvider(widget.fund.id));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('「${widget.fund.name}」的余额已校准')),
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
    final more = [...kCommonCurrencies, ...kMoreCurrencies].where((c) => !_fields.containsKey(c)).toList();
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SectionHeader('校准「${widget.fund.name}」的余额'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
                child: Text(
                  '填现在实际有多少。差额记进期初余额：不多记一笔流水，也不算进本月收支。',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              for (final e in _fields.entries)
                PickerField(
                  label: currencyName(e.key),
                  trailing: Text('现在 ${Money.format(_current(e.key), currency: e.key)}', style: theme.textTheme.bodySmall),
                  child: TextField(
                    key: ValueKey('calibrate-${e.key}'),
                    controller: e.value,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                    decoration: InputDecoration(prefixText: '${Money.symbolFor(e.key)} '),
                    onChanged: (_) => setState(() => _error = null),
                  ),
                ),
              if (more.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 4, LedgerLayout.pagePadding, 0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: PopupMenuButton<String>(
                      key: const ValueKey('calibrate-add-currency'),
                      onSelected: _add,
                      itemBuilder: (context) => [
                        for (final c in more) PopupMenuItem(value: c, child: Text(currencyName(c))),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text('+ 加一种币', style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary)),
                      ),
                    ),
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, LedgerLayout.itemGap, LedgerLayout.pagePadding, 0),
                  child: Text(_error!, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error)),
                ),
              Padding(
                padding: const EdgeInsets.all(LedgerLayout.pagePadding),
                child: FilledButton(
                  key: const ValueKey('calibrate-save'),
                  onPressed: _busy ? null : _save,
                  child: const Text('按这个校准'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
