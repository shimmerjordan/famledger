import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'theme.dart';

/// 底部导航/导航轨的五个目的地。
class ShellDestination {
  const ShellDestination({
    required this.path,
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String path;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

const List<ShellDestination> kShellDestinations = [
  ShellDestination(
    path: '/home',
    label: '首页',
    icon: Icons.home_outlined,
    selectedIcon: Icons.home,
  ),
  ShellDestination(
    path: '/transactions',
    label: '账单',
    icon: Icons.receipt_long_outlined,
    selectedIcon: Icons.receipt_long,
  ),
  ShellDestination(
    path: '/funds',
    label: '基金',
    icon: Icons.savings_outlined,
    selectedIcon: Icons.savings,
  ),
  ShellDestination(
    path: '/analysis',
    label: '分析',
    icon: Icons.insights_outlined,
    selectedIcon: Icons.insights,
  ),
  ShellDestination(
    path: '/settings',
    label: '我的',
    icon: Icons.person_outline,
    selectedIcon: Icons.person,
  ),
];

/// 屏宽档位：结构随宽度变，字号不变（DESIGN.md）。
enum WidthClass { compact, medium, expanded }

WidthClass widthClassOf(BuildContext context) =>
    widthClassFor(MediaQuery.sizeOf(context).width);

WidthClass widthClassFor(double width) {
  if (width < LedgerLayout.compact) return WidthClass.compact;
  if (width < LedgerLayout.medium) return WidthClass.medium;
  return WidthClass.expanded;
}

/// 自适应外壳：
/// - < 600：底部 NavigationBar + 「记一笔」FAB
/// - 600–839：NavigationRail（图标）+ 轨首 FAB
/// - ≥ 840：NavigationRail（展开标签）+ 轨首 FAB，内容限宽
///
/// 宽屏右侧栏由各页面自己用 [AdaptiveTwoPane] 排（内容因页而异，
/// 外壳不知道该放什么）。
class AdaptiveShell extends StatelessWidget {
  const AdaptiveShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  void _go(int index) => navigationShell.goBranch(
    index,
    initialLocation: index == navigationShell.currentIndex,
  );

  void _addTx(BuildContext context) => context.push('/transactions/new');

  @override
  Widget build(BuildContext context) {
    final width = widthClassOf(context);
    if (width == WidthClass.compact) {
      return Scaffold(
        body: navigationShell,
        floatingActionButton: FloatingActionButton(
          onPressed: () => _addTx(context),
          tooltip: '记一笔',
          child: const Icon(Icons.add),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: navigationShell.currentIndex,
          onDestinationSelected: _go,
          destinations: [
            for (final d in kShellDestinations)
              NavigationDestination(
                icon: Icon(d.icon),
                selectedIcon: Icon(d.selectedIcon),
                label: d.label,
              ),
          ],
        ),
      );
    }

    final expanded = width == WidthClass.expanded;
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            extended: expanded,
            // 展开时标签在图标右边；不展开时放图标下面，别让人猜图标含义。
            labelType: expanded
                ? NavigationRailLabelType.none
                : NavigationRailLabelType.all,
            minExtendedWidth: 180,
            selectedIndex: navigationShell.currentIndex,
            onDestinationSelected: _go,
            leading: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: expanded
                  ? FloatingActionButton.extended(
                      onPressed: () => _addTx(context),
                      icon: const Icon(Icons.add),
                      label: const Text('记一笔'),
                    )
                  : FloatingActionButton(
                      onPressed: () => _addTx(context),
                      tooltip: '记一笔',
                      child: const Icon(Icons.add),
                    ),
            ),
            destinations: [
              for (final d in kShellDestinations)
                NavigationRailDestination(
                  icon: Icon(d.icon),
                  selectedIcon: Icon(d.selectedIcon),
                  label: Text(d.label),
                ),
            ],
          ),
          VerticalDivider(
            width: 1,
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          Expanded(child: navigationShell),
        ],
      ),
    );
  }
}

/// 宽屏（≥ 840）双栏：左 8/12 主内容，右 4/12 侧栏；窄屏则把侧栏接在下面。
class AdaptiveTwoPane extends StatelessWidget {
  const AdaptiveTwoPane({
    super.key,
    required this.main,
    this.side,
    this.sideWidth = 360,
  });

  final Widget main;
  final Widget? side;
  final double sideWidth;

  @override
  Widget build(BuildContext context) {
    final side = this.side;
    if (side == null || widthClassOf(context) != WidthClass.expanded) {
      return main;
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 8, child: main),
        SizedBox(
          width: sideWidth,
          child: Padding(
            padding: const EdgeInsets.only(right: LedgerLayout.widePagePadding),
            child: side,
          ),
        ),
      ],
    );
  }
}
