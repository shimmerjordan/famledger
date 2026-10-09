import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../app/theme_mode.dart';

/// 顶栏右上角的外观按钮：点一下在「跟随系统 → 浅色 → 深色」之间轮换。
///
/// 手机的顶栏本来就挤（资产页有三个动作），默认只在 ≥ 600 宽时出现；手机上在「我的 › 外观」里改。
class ThemeModeButton extends ConsumerWidget {
  const ThemeModeButton({super.key, this.showOnCompact = false});

  final bool showOnCompact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!showOnCompact && LedgerLayout.isCompact(MediaQuery.sizeOf(context).width)) {
      return const SizedBox.shrink();
    }
    final mode = ref.watch(themeModeProvider);
    final icon = switch (mode) {
      ThemeMode.system => Icons.brightness_auto_outlined,
      ThemeMode.light => Icons.light_mode_outlined,
      ThemeMode.dark => Icons.dark_mode_outlined,
    };
    final next = switch (mode) {
      ThemeMode.system => '浅色',
      ThemeMode.light => '深色',
      ThemeMode.dark => '跟随系统',
    };
    return IconButton(
      key: const ValueKey('theme-mode'),
      tooltip: '外观：${themeModeLabel(mode)}，点一下换$next',
      icon: Icon(icon),
      onPressed: () => ref.read(themeModeProvider.notifier).cycle(),
    );
  }
}
