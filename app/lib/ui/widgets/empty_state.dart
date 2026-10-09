import 'package:flutter/material.dart';

/// 空态：一句说明 + 一个主操作（DESIGN.md）。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    this.message,
    this.icon,
    this.actionLabel,
    this.onAction,
    this.compact = false,
  });

  final String title;
  final String? message;
  final IconData? icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// 嵌在卡片/侧栏里时用紧凑版。
  final bool compact;

  /// 说明文字最宽这么多：宽屏上一句话别拉成通栏长行。
  static const double maxWidth = 520;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Column 横向是按内容收缩的：直接放进 Scaffold body 会贴在左上角（手机上内容和屏幕差不多宽，
    // 看不出来；网页上就缩在左边一小块）。这里明确居中、限宽。
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: maxWidth),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 24,
            vertical: compact ? 16 : 40,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
          if (icon != null && !compact) ...[
            Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
          ],
          Text(
            title,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          if (message != null) ...[
            const SizedBox(height: 6),
            Text(
              message!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: 16),
                FilledButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
