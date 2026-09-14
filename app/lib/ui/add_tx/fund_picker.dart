import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../data/models/models.dart';
import '../widgets/widgets.dart';

/// 基金芯片行：左侧 8dp 色点 = 基金身份色（DESIGN.md）。
///
/// 横滑而不是换行：基金是第一公民，一行里能扫完比堆成一片好认。
/// 再点一下选中的芯片 = 取消选择（转账时「这一侧不填基金」必须表达得出来）。
class FundPicker extends StatelessWidget {
  const FundPicker({
    super.key,
    required this.funds,
    required this.selectedId,
    required this.onSelected,
    this.keyPrefix = 'fund',
    this.emptyHint = '还没有基金',
  });

  final List<Fund> funds;
  final String? selectedId;
  /// 取消选择时回调 null。
  final ValueChanged<String?> onSelected;

  /// 转账页上下两排基金用的是同一批 id，key 要分得开。
  final String keyPrefix;
  final String emptyHint;

  @override
  Widget build(BuildContext context) {
    if (funds.isEmpty) {
      return Text(emptyHint, style: Theme.of(context).textTheme.bodySmall);
    }
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: LedgerLayout.pagePadding,
        ),
        itemCount: funds.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final fund = funds[index];
          return Align(
            child: ChoiceChip(
              key: ValueKey('$keyPrefix-${fund.id}'),
              selected: fund.id == selectedId,
              onSelected: (on) => onSelected(on ? fund.id : null),
              // 色点写在 label 里而不是 avatar：avatar 会被撑成与文字等高的大圆，
              // 8dp 的「记号」就变成了满屏彩色球（PRODUCT.md 的反面参考）。
              label: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FundDot.of(context, fund: fund, index: index),
                  const SizedBox(width: 8),
                  Text(fund.name),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
