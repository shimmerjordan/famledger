import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// 列表页的「添加 X」放哪：手机（< 600）是右下角的 FAB；有导航轨的宽度放顶栏——
/// 网页上 FAB 飘在屏幕角落，离居中的列表半个屏，看着像掉在那儿的。
bool addButtonInAppBar(BuildContext context) => !LedgerLayout.isCompact(MediaQuery.sizeOf(context).width);

/// 顶栏里的「添加 X」，和资产页顶栏的「新建基金」一个样子。
class AppBarAddButton extends StatelessWidget {
  const AppBarAddButton({super.key, required this.label, required this.onPressed, this.icon = Icons.add});

  final String label;
  final VoidCallback? onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) =>
      TextButton.icon(onPressed: onPressed, icon: Icon(icon, size: 18), label: Text(label));
}
