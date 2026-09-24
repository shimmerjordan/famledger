import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../data/models/models.dart';
import '../../data/repos/import_repo.dart';
import '../../data/repos/ledger_repo.dart';
import '../add_tx/category_grid.dart';
import '../add_tx/fund_picker.dart';
import '../add_tx/picker_field.dart';
import '../widgets/widgets.dart';
import 'import_draft.dart';

List<TxCategory> categoriesFor(LedgerData ledger, String type) =>
    type == 'income' ? ledger.incomeCategories() : ledger.expenseCategories();

String importRowTitle(ImportRow row) {
  if (row.merchant.isNotEmpty) return row.merchant;
  if (row.note.isNotEmpty) return row.note.split('\n').first;
  return row.rawCategory ?? (row.isIncome ? '收入' : '支出');
}

String importRowWhen(ImportRow row) {
  final t = row.wallTime;
  if (t == null) return '日期不明';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

Future<void> showRowEditSheet(
  BuildContext context, {
  required ImportDraft draft,
  required int index,
  required LedgerData ledger,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (context) => _SheetFrame(
    child: ListenableBuilder(
      listenable: draft,
      builder: (context, _) {
        final theme = Theme.of(context);
        final row = draft.rows[index];
        final amount = row.amountCents ?? 0;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: LedgerLayout.pagePadding,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          importRowTitle(row),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium,
                        ),
                        Text(
                          [
                            importRowWhen(row),
                            if (row.rawCategory != null) row.rawCategory!,
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  MoneyText(
                    row.isIncome ? amount : -amount,
                    signed: row.isIncome,
                  ),
                ],
              ),
            ),
            PickerField(
              label: '类别',
              topGap: LedgerLayout.itemGap,
              trailing: draft.categoryId(index) == null
                  ? null
                  : TextButton(
                      onPressed: () =>
                          draft.setCategory([index], null, kind: row.type),
                      child: const Text('不设类别'),
                    ),
              child: CategoryGrid(
                categories: categoriesFor(ledger, row.type),
                selectedId: draft.categoryId(index),
                onSelected: (id) =>
                    draft.setCategory([index], id, kind: row.type),
              ),
            ),
            PickerField(
              label: '基金',
              contentPadding: EdgeInsets.zero,
              child: FundPicker(
                keyPrefix: 'sheet-fund',
                funds: ledger.activeFunds,
                selectedId: draft.fundId(index),
                onSelected: (id) => draft.setFund([index], id),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                LedgerLayout.pagePadding,
                4,
                LedgerLayout.pagePadding,
                0,
              ),
              child: Text('不选就记进默认基金', style: theme.textTheme.bodySmall),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                LedgerLayout.pagePadding,
                LedgerLayout.groupGap,
                LedgerLayout.pagePadding,
                LedgerLayout.pagePadding,
              ),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('好了'),
                ),
              ),
            ),
          ],
        );
      },
    ),
  ),
);

Future<void> showBatchCategorySheet(
  BuildContext context, {
  required ImportDraft draft,
  required List<int> indices,
  required LedgerData ledger,
}) {
  final expense = indices.where((i) => draft.rows[i].type == 'expense').length;
  final income = indices.length - expense;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _SheetFrame(
      child: _BatchCategory(
        draft: draft,
        indices: indices,
        ledger: ledger,
        expense: expense,
        income: income,
      ),
    ),
  );
}

class _BatchCategory extends StatefulWidget {
  const _BatchCategory({
    required this.draft,
    required this.indices,
    required this.ledger,
    required this.expense,
    required this.income,
  });

  final ImportDraft draft;
  final List<int> indices;
  final LedgerData ledger;
  final int expense;
  final int income;

  @override
  State<_BatchCategory> createState() => _BatchCategoryState();
}

class _BatchCategoryState extends State<_BatchCategory> {
  late String _kind = widget.income > widget.expense ? 'income' : 'expense';

  bool get _mixed => widget.expense > 0 && widget.income > 0;

  List<int> get _ofKind =>
      widget.indices.where((i) => widget.draft.rows[i].type == _kind).toList();

  void _apply(String? id) {
    widget.draft.setCategory(_ofKind, id, kind: _kind);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = _ofKind.length;
    final label = _kind == 'income' ? '收入' : '支出';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          '给选中的 $n 笔$label改类别',
          padding: const EdgeInsets.symmetric(
            horizontal: LedgerLayout.pagePadding,
          ),
          trailing: TextButton(
            onPressed: () => _apply(null),
            child: const Text('清空类别'),
          ),
        ),
        if (_mixed) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: LedgerLayout.pagePadding,
            ),
            child: SegmentedButton<String>(
              segments: [
                ButtonSegment(
                  value: 'expense',
                  label: Text('支出 ${widget.expense}'),
                ),
                ButtonSegment(
                  value: 'income',
                  label: Text('收入 ${widget.income}'),
                ),
              ],
              selected: {_kind},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _kind = s.first),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              LedgerLayout.pagePadding,
              6,
              LedgerLayout.pagePadding,
              0,
            ),
            child: Text(
              '支出和收入的类别不通用，这次只改$label那 $n 笔',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
        const SizedBox(height: LedgerLayout.itemGap),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            LedgerLayout.pagePadding,
            0,
            LedgerLayout.pagePadding,
            LedgerLayout.pagePadding,
          ),
          child: CategoryGrid(
            categories: categoriesFor(widget.ledger, _kind),
            selectedId: null,
            onSelected: _apply,
          ),
        ),
      ],
    );
  }
}

Future<void> showBatchFundSheet(
  BuildContext context, {
  required ImportDraft draft,
  required List<int> indices,
  required LedgerData ledger,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (context) {
    void apply(String? id) {
      draft.setFund(indices, id);
      Navigator.of(context).pop();
    }

    return _SheetFrame(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            '给选中的 ${indices.length} 笔改基金',
            padding: const EdgeInsets.symmetric(
              horizontal: LedgerLayout.pagePadding,
            ),
            trailing: TextButton(
              onPressed: () => apply(null),
              child: const Text('用默认基金'),
            ),
          ),
          const SizedBox(height: LedgerLayout.itemGap),
          FundPicker(
            keyPrefix: 'batch-fund',
            funds: ledger.activeFunds,
            selectedId: null,
            onSelected: (id) {
              if (id != null) apply(id);
            },
          ),
          const SizedBox(height: LedgerLayout.groupGap),
        ],
      ),
    );
  },
);

class _SheetFrame extends StatelessWidget {
  const _SheetFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      child: SingleChildScrollView(child: child),
    ),
  );
}
