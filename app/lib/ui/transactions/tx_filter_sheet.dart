import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../add_tx/picker_field.dart';
import '../widgets/widgets.dart';

/// 账单页的筛选底部弹层。返回 null = 用户没改主意。
Future<TxFilter?> showTxFilterSheet(
  BuildContext context, {
  required TxFilter initial,
  required LedgerData ledger,
}) => showModalBottomSheet<TxFilter>(
  context: context,
  isScrollControlled: true,
  builder: (context) => _TxFilterSheet(initial: initial, ledger: ledger),
);

class _TxFilterSheet extends StatefulWidget {
  const _TxFilterSheet({required this.initial, required this.ledger});

  final TxFilter initial;
  final LedgerData ledger;

  @override
  State<_TxFilterSheet> createState() => _TxFilterSheetState();
}

class _TxFilterSheetState extends State<_TxFilterSheet> {
  late String? _type = widget.initial.type;
  late String? _status = widget.initial.status;
  late String? _source = widget.initial.source;
  late String? _fundId = widget.initial.fundId;
  late String? _accountId = widget.initial.accountId;
  late String? _categoryId = widget.initial.categoryId;
  late String? _memberId = widget.initial.memberId;
  late DateTime? _from = widget.initial.from;
  late DateTime? _to = widget.initial.to;

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year + 1),
      initialDateRange: _from != null && _to != null
          ? DateTimeRange(start: _from!, end: _to!)
          : null,
    );
    if (picked == null) return;
    setState(() {
      _from = picked.start;
      _to = picked.end;
    });
  }

  void _reset() => setState(() {
    _type = null;
    _status = null;
    _source = null;
    _fundId = null;
    _accountId = null;
    _categoryId = null;
    _memberId = null;
    _from = null;
    _to = null;
  });

  void _apply() => Navigator.of(context).pop(
    TxFilter(
      from: _from,
      to: _to,
      type: _type,
      status: _status,
      source: _source,
      fundId: _fundId,
      accountId: _accountId,
      categoryId: _categoryId,
      memberId: _memberId,
      q: widget.initial.q,
      limit: widget.initial.limit,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final ledger = widget.ledger;
    final categories = ledger.categories.where((c) => !c.archived).toList();
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SectionHeader(
              '筛选',
              padding: EdgeInsets.fromLTRB(
                LedgerLayout.pagePadding,
                0,
                LedgerLayout.pagePadding,
                0,
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: LedgerLayout.groupGap),
                children: [
                  PickerField(
                    label: '类型',
                    topGap: LedgerLayout.itemGap,
                    child: _Chips(
                      values: Transaction.typeLabels,
                      selected: _type,
                      onSelected: (v) => setState(() => _type = v),
                    ),
                  ),
                  PickerField(
                    label: '状态',
                    child: _Chips(
                      values: Transaction.statusLabels,
                      selected: _status,
                      onSelected: (v) => setState(() => _status = v),
                    ),
                  ),
                  PickerField(
                    label: '来源',
                    child: _Chips(
                      values: Transaction.sourceLabels,
                      selected: _source,
                      onSelected: (v) => setState(() => _source = v),
                    ),
                  ),
                  PickerField(
                    label: '基金',
                    child: _Chips(
                      values: {
                        for (final f in ledger.activeFunds) f.id: f.name,
                      },
                      selected: _fundId,
                      onSelected: (v) => setState(() => _fundId = v),
                    ),
                  ),
                  PickerField(
                    label: '账户',
                    child: _Chips(
                      values: {
                        for (final a in ledger.activeAccounts) a.id: a.name,
                      },
                      selected: _accountId,
                      onSelected: (v) => setState(() => _accountId = v),
                    ),
                  ),
                  PickerField(
                    label: '类别',
                    child: _Chips(
                      values: {for (final c in categories) c.id: c.name},
                      selected: _categoryId,
                      onSelected: (v) => setState(() => _categoryId = v),
                    ),
                  ),
                  PickerField(
                    label: '成员',
                    child: _Chips(
                      values: {
                        for (final m in ledger.activeMembers) m.id: m.label,
                      },
                      selected: _memberId,
                      onSelected: (v) => setState(() => _memberId = v),
                    ),
                  ),
                  PickerField(
                    label: '日期范围',
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _pickRange,
                            icon: const Icon(Icons.date_range_outlined, size: 18),
                            label: Text(
                              _from == null || _to == null
                                  ? '不限'
                                  : '${Dates.isoDate(_from!)} 至 ${Dates.isoDate(_to!)}',
                            ),
                          ),
                        ),
                        if (_from != null || _to != null) ...[
                          const SizedBox(width: 8),
                          IconButton(
                            tooltip: '清除日期',
                            onPressed: () => setState(() {
                              _from = null;
                              _to = null;
                            }),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(LedgerLayout.pagePadding),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _reset,
                      child: const Text('重置'),
                    ),
                  ),
                  const SizedBox(width: LedgerLayout.itemGap),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: _apply,
                      child: const Text('应用筛选'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一排单选芯片，再点一下取消选择（= 不限）。
class _Chips extends StatelessWidget {
  const _Chips({
    required this.values,
    required this.selected,
    required this.onSelected,
  });

  final Map<String, String> values;
  final String? selected;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    if (values.isEmpty) {
      return Text('没有可选项', style: Theme.of(context).textTheme.bodySmall);
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final entry in values.entries)
          ChoiceChip(
            selected: entry.key == selected,
            onSelected: (on) => onSelected(on ? entry.key : null),
            label: Text(entry.value),
          ),
      ],
    );
  }
}
