import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets/widgets.dart';
import 'fund_reorder_sheet.dart';
import 'funds_tab.dart';

/// 「我的 › 财富」（顶栏能给板块排序）：家庭公共、育儿、旅行这些钱袋子——每笔流水都落在其中一个上，它们不是一类资产，
/// 所以不在资产页；资产页的理财里另有「基金」品类（公募基金），和股票、定期平级。
///
/// 一个钱袋子叫一个「板块」。首页的板块卡片、「财富余额」的「全部」都到这里。新建：手机是右下角的按钮，宽屏在顶栏。
class FundsPage extends ConsumerWidget {
  const FundsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inAppBar = addButtonInAppBar(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('财富'),
        actions: [
          const CurrencyMenuButton(),
          IconButton(
            key: const ValueKey('funds-reorder'),
            tooltip: '排序',
            onPressed: () => showFundReorderSheet(context),
            icon: const Icon(Icons.swap_vert),
          ),
          if (inAppBar)
            AppBarAddButton(
              key: const ValueKey('funds-add'),
              label: '新建板块',
              onPressed: () => startNewFund(context, ref),
            ),
        ],
      ),
      floatingActionButton: inAppBar
          ? null
          : FloatingActionButton.extended(
              key: const ValueKey('funds-add'),
              onPressed: () => startNewFund(context, ref),
              icon: const Icon(Icons.add),
              label: const Text('新建板块'),
            ),
      body: const FundsTab(),
    );
  }
}
