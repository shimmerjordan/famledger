import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'shell.dart';

/// 外壳左边那条导航轨（600–839 只有图标、≥ 840 展开标签，轨首是「记一笔」）。
/// 外壳（[AdaptiveShell]）和压在外壳上面的整屏页（[PageFrame]）画的是同一条，切页时轨不动。
class LedgerRail extends StatelessWidget {
  const LedgerRail({
    super.key,
    required this.selectedIndex,
    required this.onSelect,
    required this.onAddTx,
  });

  /// 高亮哪个目的地；整屏页不属于任何 tab 时是 null。
  final int? selectedIndex;
  final ValueChanged<int> onSelect;

  /// null = 已经在记一笔页上，按钮灰掉。
  final VoidCallback? onAddTx;

  @override
  Widget build(BuildContext context) {
    final expanded = widthClassOf(context) == WidthClass.expanded;
    return NavigationRail(
      extended: expanded,
      // 展开时标签在图标右边；不展开时放图标下面，别让人猜图标含义。
      labelType: expanded ? NavigationRailLabelType.none : NavigationRailLabelType.all,
      minExtendedWidth: 180,
      selectedIndex: selectedIndex,
      onDestinationSelected: onSelect,
      leading: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: expanded
            ? FloatingActionButton.extended(
                onPressed: onAddTx,
                icon: const Icon(Icons.add),
                label: const Text('记一笔'),
              )
            : FloatingActionButton(
                onPressed: onAddTx,
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
    );
  }
}

/// 整屏页（表单、详情、设置子页、导入、AI）归哪个 tab：轨上高亮它，点别的 tab 直接切过去。
int? shellIndexFor(String location) {
  final path = Uri.parse(location).path;
  bool under(String prefix) => path == prefix || path.startsWith('$prefix/');
  if (under('/home')) return 0;
  if (under('/transactions') || under('/import')) return 1;
  if (under('/assets')) return 2;
  if (under('/analysis') || under('/ai')) return 3;
  // 基金（钱袋子）在「我的」里管。
  if (under('/settings') || under('/funds')) return 4;
  return null;
}

/// 压在外壳上面的整屏页在 ≥ 600 宽时也带着导航轨：网页上点进「记一件」「新建基金」「成员」
/// 不该像换了个 App——左边的导航还在，点一下就回到别的 tab，和外壳里看到的一模一样。
/// 手机（< 600）不变：整屏盖住底栏。
class PageFrame extends StatelessWidget {
  const PageFrame({super.key, required this.location, required this.child});

  /// 这一页的地址（`/assets/items/new`），决定轨上高亮哪个 tab。
  final String location;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (widthClassOf(context) == WidthClass.compact) return child;
    final onAddTx = Uri.parse(location).path == '/transactions/new';
    return Scaffold(
      body: Row(
        children: [
          LedgerRail(
            selectedIndex: shellIndexFor(location),
            // go 到 tab 地址：把这页（和它上面的）弹掉、切到那个分支。
            onSelect: (index) => context.go(kShellDestinations[index].path),
            onAddTx: onAddTx ? null : () => context.push('/transactions/new'),
          ),
          VerticalDivider(width: 1, color: Theme.of(context).colorScheme.outlineVariant),
          Expanded(child: child),
        ],
      ),
    );
  }
}
