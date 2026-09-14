import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api/api_client.dart';
import 'skeleton.dart';

/// `AsyncValue` 的统一呈现：加载给骨架、出错给行内说明 + 重试。
class AsyncValueView<T> extends StatelessWidget {
  const AsyncValueView({
    super.key,
    required this.value,
    required this.data,
    this.loading,
    this.onRetry,
    this.errorPadding,
  });

  final AsyncValue<T> value;
  final Widget Function(T data) data;
  final Widget? loading;
  final VoidCallback? onRetry;
  final EdgeInsetsGeometry? errorPadding;

  @override
  Widget build(BuildContext context) => value.when(
    skipLoadingOnRefresh: true,
    skipLoadingOnReload: true,
    data: data,
    loading: () => loading ?? const SkeletonList(),
    error: (error, _) => InlineError(
      message: describeError(error),
      onRetry: onRetry,
      padding: errorPadding,
    ),
  );
}

/// 行内错误：一句中文说明 + 重试（Snackbar 只用于可撤销的成功反馈）。
class InlineError extends StatelessWidget {
  const InlineError({
    super.key,
    required this.message,
    this.onRetry,
    this.padding,
  });

  final String message;
  final VoidCallback? onRetry;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: padding ?? const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message, style: theme.textTheme.bodyMedium),
          if (onRetry != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试'),
            ),
          ],
        ],
      ),
    );
  }
}

/// 任何异常都翻成一句能读的中文。
String describeError(Object error) {
  if (error is ApiException) return error.message;
  if (error is FormatException) return '数据格式不对：${error.message}';
  return '出了点问题：$error';
}
