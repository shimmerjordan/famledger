import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../core/ids.dart';
import '../../core/money.dart';
import '../../data/models/models.dart';
import '../../data/repos/assets_repo.dart';
import '../add_tx/picker_field.dart';
import '../widgets/widgets.dart';
import 'asset_providers.dart';
import 'asset_widgets.dart';

/// 卖出一件物品：卖出价、日期，默认同时记一笔收入。成功返回 true。
Future<bool?> showSellSheet(BuildContext context, Asset asset) =>
    showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SellSheet(asset: asset),
    );

class SellSheet extends ConsumerStatefulWidget {
  const SellSheet({super.key, required this.asset});

  final Asset asset;

  @override
  ConsumerState<SellSheet> createState() => _SellSheetState();
}

class _SellSheetState extends ConsumerState<SellSheet> {
  final TextEditingController _price = TextEditingController();
  late DateTime _day = _today();
  bool _record = true;
  String? _accountId;
  String? _fundId;
  bool _fundTouched = false;
  String? _categoryId;
  bool _busy = false;
  String? _error;

  /// 幂等键：弹层开着期间的每次重试都沿用它，回应丢了再点也只记一笔收入。
  final String _clientId = newClientId();

  DateTime _today() {
    final now = ref.read(assetClockProvider)();
    return DateTime(now.year, now.month, now.day);
  }

  @override
  void dispose() {
    _price.dispose();
    super.dispose();
  }

  Future<void> _pickDay() async {
    final picked = await pickPastDay(
      context,
      initial: _day,
      first: localDate(widget.asset.purchasedOn),
      help: '哪天卖的',
    );
    if (picked != null) setState(() => _day = picked);
  }

  Future<void> _submit() async {
    final price = parseMoneyField(_price.text);
    if (price == null || price < 0) {
      setState(() => _error = '卖了多少钱？送人了就填 0');
      return;
    }
    final ledger = ref.read(ledgerProvider).valueOrNull;
    final withIncome = _record && price > 0;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(assetsRepoProvider).sell(
        widget.asset.id,
        saleCents: price,
        endedOn: Dates.isoDate(_day),
        record: withIncome
            ? AssetRecord(
                accountId: _accountId,
                fundId: _fundTouched || ledger == null
                    ? _fundId
                    : defaultFundId(ledger),
                categoryId: _categoryId,
              )
            : null,
        clientId: _clientId,
      );
      if (withIncome) refreshMoneyViews(ref);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            withIncome
                ? '已卖出，记了一笔 ${Money.format(price)} 的收入'
                : '已卖出',
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
    final ledger = ref.watch(ledgerProvider).valueOrNull;
    final price = parseMoneyField(_price.text);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: LedgerLayout.pagePadding),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionHeader('卖出「${widget.asset.name}」'),
              PickerField(
                label: '卖了多少',
                topGap: 0,
                child: TextField(
                  key: const ValueKey('sell-price'),
                  controller: _price,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(prefixText: '¥ ', hintText: '800'),
                ),
              ),
              PickerField(
                label: '哪天卖的',
                child: DayButton(day: _day, onPressed: _pickDay),
              ),
              const SizedBox(height: LedgerLayout.itemGap),
              SwitchListTile(
                key: const ValueKey('sell-record'),
                value: _record,
                onChanged: (v) => setState(() => _record = v),
                title: const Text('记一笔收入'),
                subtitle: Text(
                  price == 0 ? '卖出价是 0，不用记账' : '卖出价记成当天的一笔收入',
                ),
              ),
              if (_record && ledger != null)
                RecordTargetFields(
                  ledger: ledger,
                  income: true,
                  accountId: _accountId,
                  fundId: _fundTouched ? _fundId : defaultFundId(ledger),
                  categoryId: _categoryId,
                  onAccount: (id) => setState(() => _accountId = id),
                  onFund: (id) => setState(() {
                    _fundTouched = true;
                    _fundId = id;
                  }),
                  onCategory: (id) => setState(() => _categoryId = id),
                ),
              FormSubmit(
                label: '卖出',
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
