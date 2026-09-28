import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/models/models.dart';
import '../../data/repos/holdings_repo.dart';
import '../funds/funds_tab.dart';
import '../perk_import/perk_import_providers.dart';
import 'asset_providers.dart';
import 'asset_routes.dart';
import '../perks/perk_providers.dart';
import '../perks/perks_tab.dart';
import 'invest_tab.dart';
import 'items_tab.dart';
import 'net_worth_strip.dart';

/// 资产（底部导航的一个 tab）：顶上一行净资产总览，下面四段 ——
/// 「基金」每个资金模块还剩多少，「物品」看每天花多少和估值，「理财」看持仓市值和收益，
/// 「会员权益」看每张卡有哪些权益、去哪领（虚拟资产不计入净资产）。
///
/// TabBar 放在页面里（不挂在 AppBar.bottom）：它上面的净资产总览能展开，高度不固定。
///
/// 当前在哪一段写在地址里（`/assets?tab=…`，见 [assetsLocation]）：用户切段时顺手改掉地址，
/// 之后首页、通知再带着同一个地址过来才算「变了」，才切得过去。
class AssetsPage extends ConsumerStatefulWidget {
  const AssetsPage({super.key, this.initialTab, this.perksView, this.perksScope});

  /// 地址点名要哪一段（[fundsTab]、[itemsTab]、[investTab]、[perksTab]，见 requestedAssetsTab）；
  /// null = 没点名：头一次打开是第一段「基金」，之后保持用户当前所在的段。
  final int? initialTab;

  /// 会员权益 tab 先打开哪一种（`&view=current&scope=mine`，首页和提醒带过来）；见 [PerksTab.view]。
  final PerkView? perksView;
  final PerkScope? perksScope;

  static const int fundsTab = 0;
  static const int itemsTab = 1;
  static const int investTab = 2;
  static const int perksTab = 3;
  static const int tabCount = 4;

  @override
  ConsumerState<AssetsPage> createState() => _AssetsPageState();
}

/// 会员权益 tab 的「+」（spec §6）：先给智能导入（粘贴权益说明，AI 拆成卡和权益），再给手动记一张。
Future<void> showPerkAddSheet(BuildContext context) => showModalBottomSheet<void>(
  useRootNavigator: true,
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
    length: AssetsPage.tabCount,
    vsync: this,
    initialIndex: (widget.initialTab ?? AssetsPage.fundsTab).clamp(0, AssetsPage.tabCount - 1),
  );
  late int _index = _tabs.index;

  /// 首页带来的会员权益视图；用户一动分段就忘掉（PerksTab.onPrefsTouched）。
  late PerkView? _perksView = widget.perksView;
  late PerkScope? _perksScope = widget.perksScope;

  /// 正在按地址切段（[didUpdateWidget] 里的 animateTo）：这次切段是路由带来的，不回写地址。
  bool _routeDriven = false;

  /// 这次进理财页已经判断过要不要顺手刷行情了。
  bool _autoChecked = false;

  @override
  void initState() {
    super.initState();
    _tabs.addListener(_onTab);
    if (_index == AssetsPage.investTab) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAutoRefresh());
    }
  }

  /// 这一页还在（tab 一直挂着）时又被 `go('/assets?tab=perks&view=current')` 带着新参数打开
  /// （首页、通知、导入结果页的「去看看」）：go_router 复用这一页，这里切到新的段、换上新的会员权益视图。
  @override
  void didUpdateWidget(AssetsPage old) {
    super.didUpdateWidget(old);
    final want = widget.initialTab;
    if (want != null && want != old.initialTab) {
      // animateTo 会同步地通知 _onTab：这次切段不回写地址。尤其是 go 到另一段的子页
      // （`/assets/memberships/m1`）时，回写的那次 go 会把刚打开的子页换掉。
      _routeDriven = true;
      _tabs.animateTo(want.clamp(0, AssetsPage.tabCount - 1));
      _routeDriven = false;
    } else if (want == null) {
      // 没点名：再点一次底部「资产」、从深链接进的子页返回，地址都会退回 `/assets`。段不动，地址补回来，
      // 不然网页刷新、前进后退会落到第一段。
      _scheduleSync();
    }
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
    if (!_routeDriven) _scheduleSync();
    _maybeAutoRefresh();
  }

  /// 地址跟上当前段（见类注释），放到这一帧画完之后：切段可能发生在 build 里（didUpdateWidget），
  /// 那时候再 go 会让 Router 在 build 期间重建。
  void _scheduleSync() => WidgetsBinding.instance.addPostFrameCallback((_) => _syncLocation());

  /// 只在资产页自己在最上面（整个 App 当前的地址就是 `/assets…`）时改：上面盖着子页（go 过去的、
  /// push 上来的、正 pushReplacement 进来的）时一改地址就把子页换掉了。看的是 router 当前的地址，
  /// 不是这一页自己的 GoRouterState —— 子页是 push 上来的时候，这一页拿到的还是底下那个 `/assets`。
  /// 地址里的段已经是这一段（从链接切过来的那一下）就不动，不然会把 `&view=current&scope=mine` 冲掉。
  /// [Router.neglect]：网页上不为每次切段记一条历史。
  void _syncLocation() {
    if (!mounted) return;
    final router = GoRouter.maybeOf(context);
    if (router == null) return; // 不在 go_router 里（单独挂出来的测试）
    final uri = router.state.uri;
    if (uri.path != '/assets') return;
    final named = uri.queryParameters['tab'];
    if (named != null ? assetsTabIndexOf(named) == _index : _index == AssetsPage.fundsTab) return;
    final location = assetsLocation(_index);
    Router.neglect(context, () => context.go(location));
  }

  /// 本地还没有自动行情的持仓（首次打开、缓存刚清过）就先不判，等同步回来再看一次。
  void _maybeAutoRefresh() {
    if (!mounted || _autoChecked || _index != AssetsPage.investTab) return;
    final data = ref.read(ledgerProvider).valueOrNull;
    if (data == null || !wantsAutoQuotes(data.holdings)) return;
    _autoChecked = true;
    _autoRefresh();
  }

  /// 进理财页顺手刷一次行情（一小时内刷过就不刷）。
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
    final items = _index == AssetsPage.itemsTab;
    final perks = _index == AssetsPage.perksTab;
    return Scaffold(
      appBar: AppBar(
        title: const Text('资产'),
        actions: [
          // 物品 tab 的「✨ 智能导入」：粘贴订单文字，识别范围预选「只要实物」。
          if (items)
            IconButton(
              key: const ValueKey('items-ai-import'),
              tooltip: '智能导入',
              icon: const Icon(Icons.auto_awesome_outlined),
              onPressed: () => context.push(perkImportLocation(want: ImportWant.items)),
            ),
          IconButton(
            tooltip: switch (_index) {
              AssetsPage.fundsTab => '新建基金',
              AssetsPage.investTab => '添加持仓',
              AssetsPage.perksTab => '记一张会员卡',
              _ => '记一件物品',
            },
            icon: const Icon(Icons.add),
            onPressed: () => switch (_index) {
              AssetsPage.fundsTab => startNewFund(context, ref),
              AssetsPage.perksTab => showPerkAddSheet(context),
              AssetsPage.investTab => context.push('/assets/holdings/new'),
              _ => context.push('/assets/items/new'),
            },
          ),
          // 溢出菜单：会员权益 tab 有平台管理、会员提醒（从「我的」挪过来）；物品和会员权益都有
          // 「最近的 AI 导入」（7 天内导进来的可以整批撤销，spec §1）。
          if (perks)
            PopupMenuButton<String>(
              key: const ValueKey('perks-menu'),
              tooltip: '更多',
              onSelected: (value) => context.push(switch (value) {
                'imports' => '/assets/import/recent',
                'reminders' => '/settings/perk-reminders',
                _ => '/assets/platforms',
              }),
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'platforms', child: Text('平台管理')),
                PopupMenuItem(key: ValueKey('menu-perk-reminders'), value: 'reminders', child: Text('会员提醒')),
                PopupMenuItem(key: ValueKey('menu-recent-imports'), value: 'imports', child: Text('最近的 AI 导入')),
              ],
            ),
          if (items)
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
                Tab(text: '基金'),
                Tab(text: '物品'),
                Tab(text: '理财'),
                Tab(text: '会员权益'),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [
                  const FundsTab(),
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
