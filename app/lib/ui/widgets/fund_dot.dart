import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/colors.dart';
import '../../data/models/models.dart';

/// 基金身份色的小圆点：芯片左侧、列表前缀、图例都用它。
class FundDot extends StatelessWidget {
  const FundDot({super.key, required this.color, this.size = 8});

  /// 按基金取色（基金自己没设颜色就按顺序从 12 色盘取）。
  factory FundDot.of(
    BuildContext context, {
    Fund? fund,
    int index = 0,
    double size = 8,
    Key? key,
  }) => FundDot(key: key, color: fundColorOf(context, fund, index), size: size);

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// 基金颜色：自定义色优先，否则按下标取 12 色盘。
Color fundColorOf(BuildContext context, Fund? fund, int index) =>
    hexColor(fund?.color) ?? LedgerColors.of(context).fundColor(index);
