import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../data/models/models.dart';
import '../add_tx/category_grid.dart';
import '../widgets/widgets.dart';

/// 批量改类别：选中一个再点确定（批量覆盖改不回原样，误点一下代价太大）。
/// 返回类别 id；null = 没改主意。
Future<String?> showBulkCategoryDialog(
  BuildContext context, {
  required List<TxCategory> categories,
  required int count,
}) => showDialog<String>(
  context: context,
  builder: (context) => _PickDialog(
    title: '把这 $count 笔改成哪个类别？',
    confirmLabel: '改 $count 笔',
    builder: (selected, onSelected) => CategoryGrid(
      categories: categories,
      selectedId: selected,
      onSelected: onSelected,
    ),
  ),
);

/// 批量改基金。芯片换行排而不是 [FundPicker] 那样横滑：
/// 网页上鼠标拖不动横向列表，弹窗里也放得下。
Future<String?> showBulkFundDialog(
  BuildContext context, {
  required List<Fund> funds,
  required int count,
  required int Function(Fund fund) indexOf,
}) => showDialog<String>(
  context: context,
  builder: (context) => _PickDialog(
    title: '把这 $count 笔改到哪个基金？',
    confirmLabel: '改 $count 笔',
    builder: (selected, onSelected) => funds.isEmpty
        ? Text('还没有基金', style: Theme.of(context).textTheme.bodySmall)
        : Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final fund in funds)
                ChoiceChip(
                  key: ValueKey('bulk-fund-${fund.id}'),
                  selected: fund.id == selected,
                  onSelected: (_) => onSelected(fund.id),
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FundDot.of(context, fund: fund, index: indexOf(fund)),
                      const SizedBox(width: 8),
                      Text(fund.name),
                    ],
                  ),
                ),
            ],
          ),
  ),
);

/// 批量删除的二次确认。和详情页一样直说「不能恢复」。
Future<bool> confirmBulkDelete(
  BuildContext context, {
  required int count,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return AlertDialog(
        title: Text('删除这 $count 笔流水？'),
        content: const Text('删除后不能恢复，余额与统计会跟着变。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('删除 $count 笔'),
          ),
        ],
      );
    },
  );
  return ok == true;
}

/// 「挑一个 → 确定」的弹窗外框。不用 AlertDialog：它按内容的固有宽度排版，
/// 而类别网格靠 LayoutBuilder 算列数，拿不出固有宽度。
class _PickDialog extends StatefulWidget {
  const _PickDialog({
    required this.title,
    required this.confirmLabel,
    required this.builder,
  });

  final String title;
  final String confirmLabel;
  final Widget Function(String? selected, ValueChanged<String> onSelected)
  builder;

  @override
  State<_PickDialog> createState() => _PickDialogState();
}

class _PickDialogState extends State<_PickDialog> {
  String? _selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            LedgerLayout.widePagePadding,
            LedgerLayout.widePagePadding,
            LedgerLayout.widePagePadding,
            LedgerLayout.pagePadding,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.title, style: theme.textTheme.titleMedium),
              const SizedBox(height: LedgerLayout.pagePadding),
              Flexible(
                child: SingleChildScrollView(
                  child: widget.builder(
                    _selected,
                    (id) => setState(() => _selected = id),
                  ),
                ),
              ),
              const SizedBox(height: LedgerLayout.pagePadding),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _selected == null
                        ? null
                        : () => Navigator.of(context).pop(_selected),
                    child: Text(widget.confirmLabel),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
