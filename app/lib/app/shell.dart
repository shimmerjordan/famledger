import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'page_frame.dart';
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
  // 基金（资金模块）、物品、理财、会员权益都在这一个 tab 里（ui/assets/assets_page.dart）。
  ShellDestination(
    path: '/assets',
    label: '资产',
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

/// 这个地址（可以带查询参数）落在某个底部 tab 上。去这种地址要用 go 切过去：从整屏页上 push 会
/// 再叠一个外壳（go_router 直接断言）；在外壳里 push 不会叠，但底栏高亮的还是原来那个 tab。
bool isShellLocation(String location) {
  final path = Uri.parse(location).path;
  return kShellDestinations.any((d) => d.path == path);
}

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

    // 整屏页（page_frame.dart）画的是同一条轨：从外壳点进表单、详情，左边的导航不动。
    return Scaffold(
      body: Row(
        children: [
          LedgerRail(
            selectedIndex: navigationShell.currentIndex,
            onSelect: _go,
            onAddTx: () => _addTx(context),
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
