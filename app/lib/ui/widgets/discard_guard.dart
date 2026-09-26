import 'package:flutter/material.dart';

/// 有没保存的改动时拦住返回（系统返回键、手势、AppBar 的返回），先问一句再走。
///
/// [canPop] 为真直接放行。否则先给 [onBlocked] 一次机会（退出多选、提交中不让走这类），它返回 true 就算处理过了；
/// 不然弹确认框，用户选 [leaveLabel] 才调 [onDiscard] 并退出这一页。
class DiscardGuard extends StatelessWidget {
  const DiscardGuard({
    super.key,
    required this.canPop,
    required this.title,
    required this.message,
    required this.child,
    this.stayLabel = '接着改',
    this.leaveLabel = '不要了',
    this.onBlocked,
    this.onDiscard,
  });

  final bool canPop;
  final String title;
  final String message;
  final String stayLabel;
  final String leaveLabel;
  final bool Function()? onBlocked;
  final VoidCallback? onDiscard;
  final Widget child;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: canPop,
    onPopInvokedWithResult: (didPop, _) async {
      if (didPop || (onBlocked?.call() ?? false)) return;
      final leave = await confirmDiscard(context, title: title, message: message, stayLabel: stayLabel, leaveLabel: leaveLabel);
      if (!leave || !context.mounted) return;
      onDiscard?.call();
      // Navigator.pop 不经过 PopScope（只有 maybePop 和返回手势才问它），这里直接走。
      Navigator.of(context).pop();
    },
    child: child,
  );
}

/// 「放弃改动」确认框：选 [leaveLabel] 回 true，其余（包括点外面关掉）回 false。
Future<bool> confirmDiscard(
  BuildContext context, {
  required String title,
  required String message,
  String stayLabel = '接着改',
  String leaveLabel = '不要了',
}) async {
  final leave = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(stayLabel)),
        TextButton(onPressed: () => Navigator.of(context).pop(true), child: Text(leaveLabel)),
      ],
    ),
  );
  return leave == true;
}
