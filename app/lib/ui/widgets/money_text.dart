import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/money.dart';

/// 金额的四个尺寸（DESIGN.md：首页合计 / 卡片余额 / 列表金额 / 辅助）。
enum MoneySize { display, title, body, small }

/// 等宽数字的金额文本。支出用墨色只带 `−`，收入（signed 且为正）用青绿 `+`。
class MoneyText extends StatelessWidget {
  const MoneyText(
    this.cents, {
    super.key,
    this.signed = false,
    this.size = MoneySize.body,
    this.showSymbol = true,
    this.color,
    this.muted = false,
  });

  final int cents;

  /// 正数是否显示 `+`，并按收入色着色。
  final bool signed;
  final MoneySize size;
  final bool showSymbol;

  /// 覆盖颜色（例如超预算用 error 色）。
  final Color? color;

  /// 次要信息（用 muted 色）。
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ledger = LedgerColors.of(context);
    final base = switch (size) {
      MoneySize.display => theme.textTheme.headlineMedium,
      MoneySize.title => theme.textTheme.titleLarge,
      MoneySize.body => theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
      MoneySize.small => theme.textTheme.bodySmall,
    };
    final resolved = color ??
        (muted
            ? theme.colorScheme.onSurfaceVariant
            : (signed && cents > 0 ? ledger.income : theme.colorScheme.onSurface));
    return Text(
      Money.format(cents, signed: signed, showSymbol: showSymbol),
      style: (base ?? const TextStyle()).copyWith(
        color: resolved,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
