import 'package:flutter/material.dart';

/// 宽屏上把内容收窄到 [maxWidth]：名字和数字别隔着半个屏幕（DESIGN.md「Layout」）。
///
/// 返回的是**左右对称的外边距**，给 `ListView.padding` 用，而不是包一层 `Padding`：
/// 列表仍然占满整屏，空白处也能滚、滚动条也在屏幕边上。
EdgeInsets readableInsets(double width, {double maxWidth = 880}) =>
    EdgeInsets.symmetric(
      horizontal: width > maxWidth ? (width - maxWidth) / 2 : 0,
    );

/// 限宽的 `ListView`：整屏页（预算、我的、详情、表单……）的正文都用它，不用自己写
/// `LayoutBuilder + readableInsets`。表格页（账单宽表）例外，表格本来就要铺满。
class ReadableListView extends StatelessWidget {
  const ReadableListView({
    super.key,
    required this.children,
    this.padding = EdgeInsets.zero,
    this.maxWidth = 880,
    this.controller,
    this.physics,
  });

  final List<Widget> children;

  /// 限宽之外再加的内边距（通常只有 `bottom`）。
  final EdgeInsets padding;
  final double maxWidth;
  final ScrollController? controller;
  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => ListView(
      controller: controller,
      physics: physics,
      padding: readableInsets(box.maxWidth, maxWidth: maxWidth).add(padding),
      children: children,
    ),
  );
}

/// 不滚的版本：给 `Column` / 固定页面限宽，内容居中。
class ReadableBox extends StatelessWidget {
  const ReadableBox({super.key, required this.child, this.maxWidth = 880});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: child,
    ),
  );
}
