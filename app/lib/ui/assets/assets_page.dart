import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/repos/holdings_repo.dart';
import 'asset_providers.dart';
import 'invest_tab.dart';
import 'items_tab.dart';
import 'net_worth_strip.dart';

/// 资产：顶上一行净资产总览，下面「物品」看每天花多少和估值，「投资」看市值和收益。
///
/// TabBar 放在页面里（不挂在 AppBar.bottom）：它上面的净资产总览能展开，高度不固定。
///
/// 入口在首页的资产卡片和「我的」，不占底部导航。
class AssetsPage extends ConsumerStatefulWidget {
  const AssetsPage({super.key, this.initialTab = 0});

  /// 0 = 物品，1 = 投资（`/assets?tab=invest`）。
  final int initialTab;

  static const int investTab = 1;

  @override
  ConsumerState<AssetsPage> createState() => _AssetsPageState();
}

class _AssetsPageState extends ConsumerState<AssetsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: 2,
    vsync: this,
    initialIndex: widget.initialTab.clamp(0, 1),
  );
  late int _index = _tabs.index;

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
    return Scaffold(
      appBar: AppBar(
        title: const Text('资产'),
        actions: [
          IconButton(
            tooltip: invest ? '添加持仓' : '记一件物品',
            icon: const Icon(Icons.add),
            onPressed: () => context.push(
              invest ? '/assets/holdings/new' : '/assets/items/new',
            ),
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
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: const [ItemsTab(), InvestTab()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
