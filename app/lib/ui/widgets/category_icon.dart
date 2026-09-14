import 'package:flutter/material.dart';

/// 服务端存的是图标名（`restaurant`），这里翻成 [IconData]。
///
/// 全部是 const 常量，`--tree-shake-icons` 照样生效。
const Map<String, IconData> kCategoryIcons = {
  'restaurant': Icons.restaurant,
  'directions_bus': Icons.directions_bus,
  'shopping_bag': Icons.shopping_bag,
  'home': Icons.home,
  'bolt': Icons.bolt,
  'phone_android': Icons.phone_android,
  'medical_services': Icons.medical_services,
  'school': Icons.school,
  'child_care': Icons.child_care,
  'pets': Icons.pets,
  'sports_esports': Icons.sports_esports,
  'redeem': Icons.redeem,
  'flight': Icons.flight,
  'shield': Icons.shield,
  'more_horiz': Icons.more_horiz,
  'payments': Icons.payments,
  'emoji_events': Icons.emoji_events,
  'trending_up': Icons.trending_up,
  'undo': Icons.undo,
  'swap_horiz': Icons.swap_horiz,
  'savings': Icons.savings,
  'elderly': Icons.elderly,
  'luggage': Icons.luggage,
  'account_balance': Icons.account_balance,
  'credit_card': Icons.credit_card,
  'wallet': Icons.wallet,
  'currency_yen': Icons.currency_yen,
};

/// 认不出来的名字一律退回 [Icons.category]，不要让界面开天窗。
IconData categoryIconData(String? name) =>
    kCategoryIcons[name] ?? Icons.category;

/// 类别/账户/基金的图标。[background] 为真时套一个圆底。
class CategoryIcon extends StatelessWidget {
  const CategoryIcon(
    this.name, {
    super.key,
    this.size = 20,
    this.color,
    this.background = false,
  });

  final String? name;
  final double size;
  final Color? color;
  final bool background;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final icon = Icon(
      categoryIconData(name),
      size: size,
      color: color ?? scheme.onSurfaceVariant,
    );
    if (!background) return icon;
    final diameter = size * 2;
    return Container(
      width: diameter,
      height: diameter,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: (color ?? scheme.onSurfaceVariant).withValues(alpha: 0.12),
        shape: BoxShape.circle,
      ),
      child: icon,
    );
  }
}
