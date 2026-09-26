import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// 限宽底栏：surface2 底、顶上一条细线，内容在 [maxWidth] 里居中，页边距跟着宽度走（紧凑 16 / 展开 24），
/// 底部让出安全区。核对页的「导入 N 笔」、多选时的批量操作都放在这里。
class ConstrainedBottomBar extends StatelessWidget {
  const ConstrainedBottomBar({super.key, required this.child, this.maxWidth = 960});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final pad = LedgerLayout.isExpanded(width) ? LedgerLayout.widePagePadding : LedgerLayout.pagePadding;
    // 颜色给 Material 而不是 DecoratedBox：底栏按钮的水波纹画在 Material 上，被盖住就看不见了。
    return Material(
      color: LedgerColors.of(context).surface2,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
        ),
        child: SafeArea(
          top: false,
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: Padding(
                padding: EdgeInsets.fromLTRB(pad, 8, pad, 12),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
