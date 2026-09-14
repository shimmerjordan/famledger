import 'package:flutter/material.dart';

import '../../core/colors.dart';
import '../../data/models/models.dart';
import '../widgets/widgets.dart';

/// 账户芯片：钱「从哪出」。账户不多，换行排比横滑好点。
///
/// 再点一下选中的芯片 = 取消选择（转账只用基金对时，账户那一侧要留空）。
class AccountPicker extends StatelessWidget {
  const AccountPicker({
    super.key,
    required this.accounts,
    required this.selectedId,
    required this.onSelected,
    this.keyPrefix = 'account',
    this.emptyHint = '还没有账户',
  });

  final List<Account> accounts;
  final String? selectedId;
  /// 取消选择时回调 null。
  final ValueChanged<String?> onSelected;

  /// 转账页上下两排都用这个组件，key 要分得开。
  final String keyPrefix;
  final String emptyHint;

  @override
  Widget build(BuildContext context) {
    if (accounts.isEmpty) {
      return Text(emptyHint, style: Theme.of(context).textTheme.bodySmall);
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final account in accounts)
          ChoiceChip(
            key: ValueKey('$keyPrefix-${account.id}'),
            selected: account.id == selectedId,
            onSelected: (on) => onSelected(on ? account.id : null),
            label: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CategoryIcon(
                  account.icon ?? _iconFor(account.kind),
                  size: 16,
                  color: hexColor(account.color),
                ),
                const SizedBox(width: 6),
                Text(account.name),
              ],
            ),
          ),
      ],
    );
  }

  static String _iconFor(String kind) => switch (kind) {
    'cash' => 'payments',
    'bank' => 'account_balance',
    'credit' => 'credit_card',
    'invest' => 'trending_up',
    _ => 'wallet',
  };
}
