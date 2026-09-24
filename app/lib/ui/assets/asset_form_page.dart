import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../core/ids.dart';
import '../../core/money.dart';
import '../../data/models/models.dart';
import '../../data/repos/assets_repo.dart';
import '../../data/repos/ledger_repo.dart';
import '../add_tx/picker_field.dart';
import '../widgets/widgets.dart';
import 'asset_providers.dart';
import 'asset_widgets.dart';

/// 新建 / 编辑物品。新建时默认「同时记一笔支出」：买东西本来就是一笔账。
class AssetFormPage extends ConsumerStatefulWidget {
  const AssetFormPage({super.key, this.id});

  /// null = 新建。
  final String? id;

  @override
  ConsumerState<AssetFormPage> createState() => _AssetFormPageState();
}

class _AssetFormPageState extends ConsumerState<AssetFormPage> {
  static const Map<int, String> _presets = {
    365: '1 年',
    730: '2 年',
    1095: '3 年',
    1825: '5 年',
  };

  final TextEditingController _name = TextEditingController();
  final TextEditingController _price = TextEditingController();
  final TextEditingController _expected = TextEditingController();
  final TextEditingController _note = TextEditingController();

  String _category = 'digital';
  DateTime _purchasedOn = DateTime.now();
  bool _record = true;
  String? _accountId;
  String? _fundId;
  bool _fundTouched = false;
  String? _categoryId;
  bool _bound = false;
  bool _busy = false;
  String? _error;

  /// 幂等键：这张表单的每次重试都沿用它，回应丢了再点保存也只记一件、一笔支出。
  final String _clientId = newClientId();

  bool get _editing => widget.id != null;

  @override
  void dispose() {
    _name.dispose();
    _price.dispose();
    _expected.dispose();
    _note.dispose();
    super.dispose();
  }

  void _bind(Asset asset) {
    if (_bound) return;
    _bound = true;
    _name.text = asset.name;
    _price.text = Money.plain(asset.priceCents).replaceAll(',', '');
    _expected.text = asset.expectedDays?.toString() ?? '';
    _note.text = asset.note ?? '';
    _category = Asset.categories.contains(asset.category) ? asset.category : 'other';
    _purchasedOn = localDate(asset.purchasedOn) ?? DateTime.now();
  }

  Future<void> _pickDate() async {
    final picked = await pickPastDay(
      context,
      initial: _purchasedOn,
      help: '哪天买的',
    );
    if (picked != null) setState(() => _purchasedOn = picked);
  }

  Future<void> _save(LedgerData ledger) async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '给它起个名字');
      return;
    }
    final price = parseMoneyField(_price.text);
    if (price == null || price < 0) {
      setState(() => _error = '买价填得不对，例如 5999');
      return;
    }
    int? expected;
    final rawExpected = _expected.text.trim();
    if (rawExpected.isNotEmpty) {
      expected = int.tryParse(rawExpected);
      if (expected == null || expected < 1 || expected > 36500) {
        setState(() => _error = '打算用多少天填个整数，例如 1095');
        return;
      }
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    final repo = ref.read(assetsRepoProvider);
    final day = Dates.isoDate(_purchasedOn);
    final note = _note.text.trim();
    try {
      if (_editing) {
        await repo.edit(
          widget.id!,
          name: name,
          category: _category,
          priceCents: price,
          purchasedOn: day,
          expectedDays: expected,
          note: note,
        );
      } else {
        await repo.create(
          name: name,
          category: _category,
          priceCents: price,
          purchasedOn: day,
          expectedDays: expected,
          note: note,
          record: _record && price > 0
              ? AssetRecord(
                  accountId: _accountId,
                  fundId: _resolvedFund(ledger),
                  categoryId: _categoryId,
                )
              : null,
          clientId: _clientId,
        );
        if (_record && price > 0) refreshMoneyViews(ref);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _editing ? '已保存' : (_record && price > 0 ? '记好了，也记了一笔支出' : '记好了'),
          ),
        ),
      );
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/assets');
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = describeWriteError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _resolvedFund(LedgerData ledger) =>
      _fundTouched ? _fundId : defaultFundId(ledger);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ledger = ref.watch(ledgerProvider).valueOrNull;
    final asset = _editing ? ledger?.asset(widget.id) : null;
    if (asset != null) _bind(asset);
    final title = _editing ? '编辑物品' : '记一件物品';

    if (ledger == null) {
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: const SkeletonList(rows: 5),
      );
    }
    if (_editing && asset == null) {
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: const InlineError(message: '这件物品已经不在了。'),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: LayoutBuilder(
        builder: (context, box) => ListView(
          padding: readableInsets(box.maxWidth, maxWidth: 720)
              .copyWith(bottom: LedgerLayout.groupGap),
          children: [
            PickerField(
              label: '名称',
              topGap: LedgerLayout.pagePadding,
              child: TextField(
                key: const ValueKey('asset-name'),
                controller: _name,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(hintText: '例如「iPhone 16」「洗衣机」'),
              ),
            ),
            PickerField(
              label: '分类',
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in Asset.categories)
                    ChoiceChip(
                      key: ValueKey('asset-category-$c'),
                      selected: _category == c,
                      onSelected: (_) => setState(() => _category = c),
                      label: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(assetCategoryIcon(c), size: 16),
                          const SizedBox(width: 6),
                          Text(Asset.categoryLabels[c]!),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            PickerField(
              label: '买价',
              child: TextField(
                key: const ValueKey('asset-price'),
                controller: _price,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(prefixText: '¥ ', hintText: '5999'),
              ),
            ),
            PickerField(
              label: '哪天买的',
              child: DayButton(day: _purchasedOn, onPressed: _pickDate),
            ),
            PickerField(
              label: '打算用多久（选填）',
              trailing: Text('算目标日均用', style: theme.textTheme.bodySmall),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    key: const ValueKey('asset-expected'),
                    controller: _expected,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      hintText: '1095',
                      suffixText: '天',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final entry in _presets.entries)
                        ChoiceChip(
                          selected: _expected.text.trim() == '${entry.key}',
                          onSelected: (_) => setState(
                            () => _expected.text = '${entry.key}',
                          ),
                          label: Text(entry.value),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            PickerField(
              label: '备注（选填）',
              child: TextField(
                controller: _note,
                maxLines: 2,
                decoration: const InputDecoration(hintText: '在哪买的、保修到哪天'),
              ),
            ),
            if (!_editing) ...[
              const SizedBox(height: LedgerLayout.itemGap),
              SwitchListTile(
                key: const ValueKey('asset-record'),
                value: _record,
                onChanged: (v) => setState(() => _record = v),
                title: const Text('同时记一笔支出'),
                subtitle: Text(
                  (parseMoneyField(_price.text) ?? 0) == 0 && _price.text.trim().isNotEmpty
                      ? '买价是 0，不用记账'
                      : '买价记成买入当天的一笔支出',
                ),
              ),
              if (_record)
                RecordTargetFields(
                  ledger: ledger,
                  income: false,
                  accountId: _accountId,
                  fundId: _resolvedFund(ledger),
                  categoryId: _categoryId,
                  onAccount: (id) => setState(() => _accountId = id),
                  onFund: (id) => setState(() {
                    _fundTouched = true;
                    _fundId = id;
                  }),
                  onCategory: (id) => setState(() => _categoryId = id),
                ),
            ],
            const SizedBox(height: LedgerLayout.itemGap),
            FormSubmit(
              label: _editing ? '保存' : '记好了',
              busy: _busy,
              error: _error,
              onPressed: () => _save(ledger),
            ),
          ],
        ),
      ),
    );
  }
}
