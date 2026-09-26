import 'package:flutter/material.dart';

/// 带计数的筛选 chip：「需确认 3」。一排里选中的那个高亮；计数为 0 的藏不藏由调用方决定
/// （账单导入的核对页、AI 导入的预览页共用）。
class CountFilterChip extends StatelessWidget {
  const CountFilterChip({
    super.key,
    required this.label,
    required this.count,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) => ChoiceChip(
    label: Text('$label $count'),
    selected: selected,
    onSelected: (_) => onSelected(),
  );
}
