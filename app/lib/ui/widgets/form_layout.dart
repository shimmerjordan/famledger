import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'readable.dart';

/// 表单正文：窄屏一列从上往下；内容区够宽（≥ [twoColumnMin]，网页、平板横放）时主字段在左、
/// 次要段落（估值、备注、「同时记一笔」这些）在右，提交按钮跟在左列末尾——一屏看全，不用滚半天。
///
/// 两列时整体限宽 [wideMaxWidth]，一列时 [maxWidth]：输入框拉到 800 宽，名字和光标隔着半个屏。
class FormColumns extends StatelessWidget {
  const FormColumns({
    super.key,
    required this.main,
    this.side = const [],
    this.bottom = const [],
    this.padding = const EdgeInsets.only(bottom: LedgerLayout.groupGap),
    this.maxWidth = 720,
    this.wideMaxWidth = 1120,
    this.controller,
  });

  /// 内容区至少这么宽才分两列（展开的导航轨 180 + 这个 ≈ 1100 的窗口）。
  static const double twoColumnMin = 900;

  final List<Widget> main;
  final List<Widget> side;

  /// 提交按钮、错误行：一列时在最后，两列时跟在左列末尾。
  final List<Widget> bottom;
  final EdgeInsets padding;
  final double maxWidth;
  final double wideMaxWidth;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final two = side.isNotEmpty && box.maxWidth >= twoColumnMin;
      if (!two) {
        return ListView(
          controller: controller,
          padding: readableInsets(box.maxWidth, maxWidth: maxWidth).add(padding),
          children: [...main, ...side, ...bottom],
        );
      }
      return ListView(
        controller: controller,
        padding: readableInsets(box.maxWidth, maxWidth: wideMaxWidth).add(padding),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [...main, ...bottom],
                ),
              ),
              const SizedBox(width: LedgerLayout.groupGap),
              Expanded(
                flex: 2,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: side),
              ),
            ],
          ),
        ],
      );
    },
  );
}

/// 这个表单此刻会不会排成两列（给「两列时默认把折叠段展开」这类判断用；按窗口宽估，
/// 不含导航轨那 180）。
bool formIsTwoColumn(BuildContext context) =>
    MediaQuery.sizeOf(context).width - 180 >= FormColumns.twoColumnMin;
