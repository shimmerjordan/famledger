import 'dart:math' as math;

import '../../app/theme.dart';

/// 页边距跟着宽度走（紧凑 16 / 展开 24），和别的页一致。
double importPagePad(double width) => LedgerLayout.isExpanded(width)
    ? LedgerLayout.widePagePadding
    : LedgerLayout.pagePadding;

/// 内容限宽居中时两侧多出来的空白。
///
/// 这段空白要算进滚动区自己的 padding，而不是把滚动区整个塞进限宽盒子：
/// 网页上鼠标停在两侧空白处滚轮也得能滚，滚动条也该贴着窗口边。
double importGutter(double width, double maxWidth) =>
    math.max(0, (width - maxWidth) / 2);
