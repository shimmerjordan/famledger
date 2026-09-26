import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/models/models.dart';
import '../../data/repos/holdings_repo.dart';
import '../perk_import/perk_import_providers.dart';
import 'asset_providers.dart';
import '../perks/perk_providers.dart';
import '../perks/perks_tab.dart';
import 'invest_tab.dart';
import 'items_tab.dart';
import 'net_worth_strip.dart';

/// 资产：顶上一行净资产总览，下面「物品」看每天花多少和估值，「投资」看市值和收益，
/// 「会员权益」看每张卡有哪些权益、去哪领（虚拟资产不计入净资产）。
///
/// TabBar 放在页面里（不挂在 AppBar.bottom）：它上面的净资产总览能展开，高度不固定。
///
/// 入口在首页的资产卡片和「我的」，不占底部导航。
class AssetsPage extends ConsumerStatefulWidget {
  const AssetsPage({super.key, this.initialTab = 0, this.perksView, this.perksScope});

  /// 0 = 物品，1 = 投资（`/assets?tab=invest`），2 = 会员权益（`/assets?tab=perks`）。
  final int initialTab;

  /// 会员权益 tab 先打开哪一种（`&view=current&scope=mine`，首页和提醒带过来）；见 [PerksTab.view]。
  final PerkView? perksView;
  final PerkScope? perksScope;

  static const int investTab = 1;
  static const int perksTab = 2;

  @override
  ConsumerState<AssetsPage> createState() => _AssetsPageState();
}

/// 会员权益 tab 的「+」（spec §6）：先给智能导入（粘贴权益说明，AI 拆成卡和权益），再给手动记一张。
Future<void> showPerkAddSheet(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  useSafeArea: true,
  builder: (sheet) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      ListTile(
        key: const ValueKey('perks-add-ai'),
        leading: const Icon(Icons.auto_awesome_outlined),
        title: const Text('智能导入'),
        subtitle: const Text('粘贴 88VIP、PLUS 这类权益说明，AI 帮你拆成卡和权益，导入前能逐条改'),
        onTap: () {
          Navigator.of(sheet).pop();
          context.push(perkImportLocation(want: ImportWant.virtual));
        },
      ),
      ListTile(
        key: const ValueKey('perks-add-manual'),
        leading: const Icon(Icons.edit_outlined),
        title: const Text('手动记一张'),
        onTap: () {
          Navigator.of(sheet).pop();
          context.push('/assets/memberships/new');
        },
      ),
      const SizedBox(height: 16),
    ],
  ),
);

class _AssetsPageState extends ConsumerState<AssetsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: 3,
    vsync: this,
    initialIndex: widget.initialTab.clamp(0, 2),
  );
  late int _index = _tabs.index;

  /// 首页带来的会员权益视图；用户一动分段就忘掉（PerksTab.onPrefsTouched）。
  late PerkView? _perksView = widget.perksView;
  late PerkScope? _perksScope = widget.perksScope;

  /// 这次进投资页已经判断过要不要顺手刷行情了。
  bool _autoChecked = false;

  @override
  void initState() {
    super.initState();
    _tabs.addListener(_onTab);
    if (_index == AssetsPage.investTab) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAutoRefresh());
    }
  }

  /// 页面还在栈里时又被 `go('/assets?tab=perks&view=current')` 带着新参数打开（导入结果页的「去看看」）：
  /// go_router 复用这一页，这里切到新的 tab、换上新的会员权益视图。
  @override
  void didUpdateWidget(AssetsPage old) {
    super.didUpdateWidget(old);
    if (widget.initialTab != old.initialTab) _tabs.animateTo(widget.initialTab.clamp(0, 2));
    if (widget.perksView != old.perksView || widget.perksScope != old.perksScope) {
      _perksView = widget.perksView;
      _perksScope = widget.perksScope;
    }
  }

  @override
  void dispose() {
    _tabs.removeListener(_onTab);
    _tabs.dispose();
    super.dispose();
  }

  void _onTab() {
    if (_tabs.index == _index) return;
    setState(() {
      _index = _tabs.index;
      _autoChecked = false;
    });
    _maybeAutoRefresh();
  }

  /// 本地还没有自动行情的持仓（首次打开、缓存刚清过）就先不判，等同步回来再看一次。
  void _maybeAutoRefresh() {
    if (!mounted || _autoChecked || _index != AssetsPage.investTab) return;
    final data = ref.read(ledgerProvider).valueOrNull;
    if (data == null || !wantsAutoQuotes(data.holdings)) return;
    _autoChecked = true;
    _autoRefresh();
  }

  /// 进投资页顺手刷一次行情（一小时内刷过就不刷）。
  Future<void> _autoRefresh() async {
    try {
      final result = await ref
          .read(holdingsRepoProvider)
          .refreshIfStale(now: ref.read(assetClockProvider)());
      if (result != null && mounted) {
        ref.read(quoteRefreshProvider.notifier).state = result;
      }
    } catch (_) {
      // 顺手刷的，失败（含节流）不打扰；点「刷新行情」时会把原因说出来。
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(ledgerProvider, (_, _) => _maybeAutoRefresh());
    final invest = _index == AssetsPage.investTab;
    final perks = _index == AssetsPage.perksTab;
    return Scaffold(
      appBar: AppBar(
        title: const Text('资产'),
        actions: [
          // 物品 tab 的「✨ 智能导入」：粘贴订单文字，识别范围预选「只要实物」。
          if (!invest && !perks)
            IconButton(
              key: const ValueKey('items-ai-import'),
              tooltip: '智能导入',
              icon: const Icon(Icons.auto_awesome_outlined),
              onPressed: () => context.push(perkImportLocation(want: ImportWant.items)),
            ),
          IconButton(
            tooltip: invest ? '添加持仓' : (perks ? '记一张会员卡' : '记一件物品'),
            icon: const Icon(Icons.add),
            onPressed: () => perks
                ? showPerkAddSheet(context)
                : context.push(invest ? '/assets/holdings/new' : '/assets/items/new'),
          ),
          // 溢出菜单：会员权益 tab 有平台管理；两个 tab 都有「最近的 AI 导入」（7 天内导进来的可以整批撤销，spec §1）。
          if (perks)
            PopupMenuButton<String>(
              key: const ValueKey('perks-menu'),
              tooltip: '更多',
              onSelected: (value) => context.push(value == 'imports' ? '/assets/import/recent' : '/assets/platforms'),
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'platforms', child: Text('平台管理')),
                PopupMenuItem(key: ValueKey('menu-recent-imports'), value: 'imports', child: Text('最近的 AI 导入')),
              ],
            ),
          if (!invest && !perks)
            PopupMenuButton<String>(
              key: const ValueKey('items-menu'),
              tooltip: '更多',
              onSelected: (_) => context.push('/assets/import/recent'),
              itemBuilder: (context) => const [
                PopupMenuItem(key: ValueKey('menu-recent-imports'), value: 'imports', child: Text('最近的 AI 导入')),
              ],
            ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, box) => Column(
          children: [
            // 手机横放、分屏时页面很矮：展开的明细最多占一半高，多出来的在总览里自己滚，
            // 不把下面的 Tab 和列表挤没。
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: box.maxHeight / 2),
              child: const SingleChildScrollView(child: NetWorthStrip()),
            ),
            TabBar(
              controller: _tabs,
              tabs: const [
                Tab(text: '物品'),
                Tab(text: '投资'),
                Tab(text: '会员权益'),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [
                  const ItemsTab(),
                  const InvestTab(),
                  PerksTab(
                    view: _perksView,
                    scope: _perksScope,
                    onPrefsTouched: _perksView == null && _perksScope == null
                        ? null
                        : () => setState(() {
                            _perksView = null;
                            _perksScope = null;
                          }),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
