import 'dart:async';

import 'package:flutter/material.dart';

/// 带操作按钮（「撤销」「查看」）的 SnackBar 都走这里：先收掉当前那条，再出这条，到点兜底收掉。
///
/// 系统报告「无障碍导航」时，Flutter 不会按时收掉带操作按钮的 SnackBar，而是一直挂着等人点
/// （ScaffoldMessengerState 的计时器里 `action != null && accessibleNavigation` 就直接 return）。
/// 装了 MacroDroid、Tasker、AutoInput 这类无障碍服务的手机也会被当成这种情况：每次打卡、续费之后，
/// 底部都留一条不会自己消失的提示，盖住下面的内容。这里在 [SnackBar.duration] 之外再等 [extra] 替它收掉——
/// 平常框架 4 秒就收了，兜底的计时器跟着这条一起被销毁、什么也不做；只有在会一直挂着的手机上，它才多给
/// [extra] 然后收掉。计时器挂在这条 SnackBar 的内容里：这条露出来才开始数，收掉（或整棵树销毁）就停。
ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showActionSnackBar(
  ScaffoldMessengerState messenger,
  SnackBar snackBar, {
  Duration extra = const Duration(seconds: 4),
}) {
  messenger.hideCurrentSnackBar();
  return messenger.showSnackBar(
    SnackBar(
      key: snackBar.key,
      content: _CloseAfter(after: snackBar.duration + extra, child: snackBar.content),
      backgroundColor: snackBar.backgroundColor,
      elevation: snackBar.elevation,
      margin: snackBar.margin,
      padding: snackBar.padding,
      width: snackBar.width,
      shape: snackBar.shape,
      hitTestBehavior: snackBar.hitTestBehavior,
      behavior: snackBar.behavior,
      action: snackBar.action,
      actionOverflowThreshold: snackBar.actionOverflowThreshold,
      showCloseIcon: snackBar.showCloseIcon,
      closeIconColor: snackBar.closeIconColor,
      duration: snackBar.duration,
      animation: snackBar.animation,
      onVisible: snackBar.onVisible,
      dismissDirection: snackBar.dismissDirection,
      clipBehavior: snackBar.clipBehavior,
    ),
  );
}

class _CloseAfter extends StatefulWidget {
  const _CloseAfter({required this.after, required this.child});

  final Duration after;
  final Widget child;

  @override
  State<_CloseAfter> createState() => _CloseAfterState();
}

class _CloseAfterState extends State<_CloseAfter> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // 这段内容只在它那条 SnackBar 露着时才挂在树上，所以到点收「当前那条」收的就是它自己。
    _timer = Timer(widget.after, () {
      if (mounted) ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar(reason: SnackBarClosedReason.timeout);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
