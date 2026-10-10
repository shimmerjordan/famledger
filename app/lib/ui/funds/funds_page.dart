import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets/widgets.dart';
import 'funds_tab.dart';

/// 「我的 › 基金」：家庭公共、育儿、旅行这些钱袋子——每笔流水都落在其中一个上，它们不是一类资产，
/// 所以不在资产页；资产页的理财里另有「基金」品类（公募基金），和股票、定期平级。
///
/// 首页的基金卡片、「基金余额」的「全部」都到这里。新建：手机是右下角的按钮，宽屏在顶栏。
class FundsPage extends ConsumerWidget {
  const FundsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inAppBar = addButtonInAppBar(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('基金'),
        actions: [
          if (inAppBar)
            AppBarAddButton(
              key: const ValueKey('funds-add'),
              label: '新建基金',
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
              label: const Text('新建基金'),
            ),
      body: const FundsTab(),
    );
  }
}
