import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/dates.dart';

/// 月份选择器：`‹ 2026年9月 ›`，不让往未来翻。
///
/// 放在 `ui/analysis/` 是因为 `ui/widgets/` 是基础层（Task 8）的地盘；
/// 预算页用的也是这一个，别再抄一份。
class MonthPicker extends StatelessWidget {
  const MonthPicker({
    super.key,
    required this.month,
    required this.onChanged,
    this.subtitle,
  });

  /// `YYYY-MM`
  final String month;
  final ValueChanged<String> onChanged;

  /// 月份下面的一行小字（例如「本月支出 ¥1,234.56」）。
  final Widget? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = Dates.currentMonth();
    final canGoNext = month.compareTo(current) < 0;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: LedgerLayout.pagePadding,
        vertical: 4,
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: () => onChanged(Dates.shiftMonth(month, -1)),
            icon: const Icon(Icons.chevron_left),
            tooltip: '上个月',
          ),
          Expanded(
            child: Column(
              children: [
                Text(
                  Dates.monthLabel(month),
                  style: theme.textTheme.titleMedium,
                ),
                if (subtitle != null) subtitle!,
              ],
            ),
          ),
          IconButton(
            onPressed: canGoNext
                ? () => onChanged(Dates.shiftMonth(month, 1))
                : null,
            icon: const Icon(Icons.chevron_right),
            tooltip: '下个月',
          ),
          if (month != current)
            TextButton(
              onPressed: () => onChanged(current),
              child: const Text('本月'),
            ),
        ],
      ),
    );
  }
}
