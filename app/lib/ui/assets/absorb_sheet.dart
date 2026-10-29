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
import '../settings/account_form.dart';
import '../widgets/widgets.dart';
import 'asset_providers.dart';
import 'asset_widgets.dart';

/// 把逐只记的持仓并进一个股票账户（`POST /accounts/:id/absorb`）。成功返回 true。
/// [candidates] 是能并的持仓（还持有着的）；默认勾上其中的股票。
Future<bool?> showAbsorbSheet(BuildContext context, {required List<Holding> candidates, String? accountId}) =>
    showModalBottomSheet<bool>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      builder: (context) => AbsorbSheet(candidates: candidates, accountId: accountId),
    );

class AbsorbSheet extends ConsumerStatefulWidget {
  const AbsorbSheet({super.key, required this.candidates, this.accountId});

  final List<Holding> candidates;
  final String? accountId;

  @override
  ConsumerState<AbsorbSheet> createState() => _AbsorbSheetState();
}

class _AbsorbSheetState extends ConsumerState<AbsorbSheet> {
  late String? _accountId = widget.accountId ?? _stockAccounts().firstOrNull?.id;
  late final Set<String> _selected = {
    for (final h in widget.candidates)
      if (h.kind == Holding.kindStock && !h.isCleared) h.id,
  };
  final TextEditingController _value = TextEditingController();
  bool _valueTouched = false;
  late DateTime _day = _today();
  bool _busy = false;
  String? _error;
  final String _clientId = newClientId();

  List<Account> _stockAccounts() =>
      ref.read(ledgerProvider).valueOrNull?.activeAccounts.where((a) => a.isStock).toList() ?? const [];

  /// 和选中账户同币种的候选（美股持仓只能进美元户）：列表、预填市值、提交都只看这些 ——
  /// 不然勾着的、但被币种筛掉看不见的持仓也会交上去，被服务端点名 currency_mismatch。
  List<Holding> _visible() {
    final account = _stockAccounts().where((a) => a.id == _accountId).firstOrNull;
    return [
      for (final h in widget.candidates)
        if (account == null || h.currency.toUpperCase() == account.currency.toUpperCase()) h,
    ];
  }

  DateTime _today() {
    final now = ref.read(assetClockProvider)();
    return DateTime(now.year, now.month, now.day);
  }

  @override
  void initState() {
    super.initState();
    _refreshValue();
  }

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  /// 勾选的持仓市值合计（有价格的那些），预填成「并进去后的市值」；用户动过就不再覆盖。
  void _refreshValue() {
    if (_valueTouched) return;
    final now = ref.read(assetClockProvider)();
    var sum = 0;
    for (final h in _visible()) {
      if (!_selected.contains(h.id)) continue;
      sum += holdingMetrics(h, now).marketCents ?? 0;
    }
    _value.text = sum > 0 ? Money.input(sum) : '';
  }

  /// 新建一个股票账户，建好了就选中它。
  Future<void> _newAccount() async {
    final before = {for (final a in _stockAccounts()) a.id};
    await showAccountForm(context, initialKind: Account.kindStock);
    if (!mounted) return;
    final added = _stockAccounts().where((a) => !before.contains(a.id)).firstOrNull;
    if (added != null) {
      setState(() {
        _accountId = added.id;
        _refreshValue();
      });
    }
  }

  Future<void> _submit() async {
    final accountId = _accountId;
    if (accountId == null) {
      setState(() => _error = '选一个股票账户，或新建一个');
      return;
    }
    final ids = [for (final h in _visible()) if (_selected.contains(h.id)) h.id];
    if (ids.isEmpty) {
      setState(() => _error = '至少勾一只持仓');
      return;
    }
    final value = parseMoneyField(_value.text);
    if (value == -1) {
      setState(() => _error = '市值看不懂：${_value.text}');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await ref.read(holdingsRepoProvider).absorbHoldings(
        accountId,
        holdingIds: ids,
        valueCents: value,
        valueOn: value == null ? null : Dates.isoDate(_day),
        clientId: _clientId,
      );
      refreshMoneyViews(ref);
      refreshNetWorth(ref);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.replayed
                ? '刚才那次其实已经并好了，没有重复记'
                : '已并进「${result.account.name}」：${ids.length} 只持仓归档${result.transactions.isEmpty ? '' : '，记了 ${result.transactions.length} 笔移仓转账'}',
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
    final stockAccounts = ledger?.activeAccounts.where((a) => a.isStock).toList() ?? const <Account>[];
    final account = stockAccounts.where((a) => a.id == _accountId).firstOrNull;
    final now = ref.watch(assetClockProvider)();
    // 只能并同币种的（美股持仓进美元户）。
    final candidates = _visible();
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: LedgerLayout.pagePadding),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader('合并到股票账户'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
                child: Text(
                  '挂着投资账户的成本记一笔「移仓」转账到股票账户，没挂的记进股票账户的投入；并过的持仓归档，以后只在股票账户上记市值。',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              PickerField(
                label: '并进哪个股票账户',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AccountPicker(
                      keyPrefix: 'absorb-account',
                      accounts: stockAccounts,
                      selectedId: _accountId,
                      emptyHint: '还没有股票账户',
                      onSelected: (id) => setState(() {
                        _accountId = id;
                        _refreshValue();
                      }),
                    ),
                    TextButton.icon(
                      key: const ValueKey('absorb-new-account'),
                      onPressed: _busy ? null : _newAccount,
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('新建股票账户'),
                    ),
                  ],
                ),
              ),
              PickerField(
                label: '要并进去的持仓',
                contentPadding: EdgeInsets.zero,
                child: candidates.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
                        child: Text('没有同币种的持仓可以并', style: theme.textTheme.bodySmall),
                      )
                    : Column(
                        children: [
                          for (final h in candidates)
                            CheckboxListTile(
                              key: ValueKey('absorb-h-${h.id}'),
                              value: _selected.contains(h.id),
                              controlAffinity: ListTileControlAffinity.leading,
                              title: Text(h.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                [
                                  h.kindLabel,
                                  if (holdingMetrics(h, now).marketCents case final v?)
                                    '市值 ${Money.format(v, currency: h.currency)}'
                                  else
                                    '没有价格',
                                ].join(' · '),
                              ),
                              onChanged: (on) => setState(() {
                                on == true ? _selected.add(h.id) : _selected.remove(h.id);
                                _refreshValue();
                              }),
                            ),
                        ],
                      ),
              ),
              PickerField(
                label: '并进去后的市值（选填）',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      key: const ValueKey('absorb-value'),
                      controller: _value,
                      onChanged: (_) => _valueTouched = true,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        prefixText: '${Money.symbolFor(account?.currency ?? 'CNY').trim()} ',
                        helperText: '预填的是勾选持仓的市值合计；照券商 App 改成整户的数，留空就先不填',
                        helperMaxLines: 2,
                      ),
                    ),
                    const SizedBox(height: 8),
                    DayButton(
                      key: const ValueKey('absorb-day'),
                      day: _day,
                      onPressed: () async {
                        final picked = await pickPastDay(context, initial: _day, help: '市值是哪天的');
                        if (picked != null) setState(() => _day = picked);
                      },
                    ),
                  ],
                ),
              ),
              FormSubmit(key: const ValueKey('absorb-submit'), label: '合并', busy: _busy, error: _error, onPressed: _submit),
            ],
          ),
        ),
      ),
    );
  }
}
