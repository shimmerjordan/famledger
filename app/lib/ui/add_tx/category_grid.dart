import 'package:flutter/material.dart';

import '../../core/colors.dart';
import '../../data/models/models.dart';
import '../widgets/widgets.dart';

/// 类别网格：按 `kind`（支出/收入）过滤后的一片图标 + 名字。
///
/// 嵌在页面的滚动列表里，所以自己不滚。
class CategoryGrid extends StatelessWidget {
  const CategoryGrid({
    super.key,
    required this.categories,
    required this.selectedId,
    required this.onSelected,
    this.maxColumns = 9,
  });

  final List<TxCategory> categories;
  final String? selectedId;
  final ValueChanged<String> onSelected;
  final int maxColumns;

  @override
  Widget build(BuildContext context) {
    if (categories.isEmpty) {
      return Text('还没有类别', style: Theme.of(context).textTheme.bodySmall);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // 一格 64–80dp 宽：手机 5 列，宽屏（限宽后约 660）8 列、两行放完，而不是 5 个 130 宽的大格。
        final fit = (constraints.maxWidth / 80).floor();
        final count = fit < 3 ? 3 : (fit > maxColumns ? maxColumns : fit);
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: count,
            mainAxisSpacing: 4,
            crossAxisSpacing: 4,
            childAspectRatio: 0.86,
          ),
          itemCount: categories.length,
          itemBuilder: (context, index) {
            final category = categories[index];
            return _CategoryCell(
              key: ValueKey('category-${category.id}'),
              category: category,
              selected: category.id == selectedId,
              onTap: () => onSelected(category.id),
            );
          },
        );
      },
    );
  }
}

class _CategoryCell extends StatelessWidget {
  const _CategoryCell({
    super.key,
    required this.category,
    required this.selected,
    required this.onTap,
  });

  final TxCategory category;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = hexColor(category.color) ??
        (selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected
                  ? theme.colorScheme.primaryContainer
                  : color.withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
            child: Icon(
              categoryIconData(category.icon),
              size: 22,
              color: selected ? theme.colorScheme.onPrimaryContainer : color,
            ),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              category.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: selected
                    ? theme.colorScheme.onSurface
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
