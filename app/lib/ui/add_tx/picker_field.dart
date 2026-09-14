import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// 记账表单里每一段的外框：小标题 + 内容（校验提示就写在标题旁边）。
///
/// 不用卡片、不用描边，靠留白和标题分组（DESIGN.md）。
class PickerField extends StatelessWidget {
  const PickerField({
    super.key,
    required this.label,
    required this.child,
    this.error,
    this.trailing,
    this.topGap = LedgerLayout.groupGap,
    this.contentPadding = const EdgeInsets.symmetric(
      horizontal: LedgerLayout.pagePadding,
    ),
  });

  final String label;
  final Widget child;

  /// 行内校验说明（用 error 色），没有就不占位置。
  final String? error;

  /// 标题右边的补充说明。
  final Widget? trailing;

  /// 与上一段之间的距离。
  final double topGap;

  /// 内容自己的左右边距；横滑芯片行传 [EdgeInsets.zero] 好出血到屏幕边。
  final EdgeInsetsGeometry contentPadding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(height: topGap),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: LedgerLayout.pagePadding,
          ),
          child: Row(
            children: [
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (error != null) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    error!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              ] else if (trailing != null) ...[
                const Spacer(),
                trailing!,
              ],
            ],
          ),
        ),
        const SizedBox(height: 8),
        Padding(padding: contentPadding, child: child),
      ],
    );
  }
}
