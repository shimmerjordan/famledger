import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/money.dart';

/// 全局「换算」：默认按币种分开显示合计；选一个币种就把全 App 的金额按今日汇率合成那个币
/// （纯显示层，不改存量数据）。缺汇率的部分不臆造，金额旁注明。首页、资产、财富的顶栏都有这个入口。
class CurrencyMenuButton extends ConsumerWidget {
  const CurrencyMenuButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = ref.watch(displayCurrencyOverrideProvider);
    final base = ref.watch(baseCurrencyProvider).toUpperCase();
    final display = ref.watch(displayCurrenciesProvider).map((c) => c.toUpperCase());
    final used = ref.watch(usedCurrenciesProvider);
    final options = <String>{base, ...display, ...used}.toList();
    final theme = Theme.of(context);
    return PopupMenuButton<String>(
      key: const ValueKey('currency-menu'),
      tooltip: target == null ? '换算：按币种分开显示中' : '换算：全部折成 ${target.toUpperCase()}',
      initialValue: target ?? '',
      icon: Icon(Icons.currency_exchange, color: target == null ? null : theme.colorScheme.primary),
      onSelected: (value) => ref.read(displayCurrencyOverrideProvider.notifier).state = value.isEmpty ? null : value,
      itemBuilder: (context) => [
        const PopupMenuItem<String>(value: '', child: Text('按币种分开显示')),
        for (final c in options)
          PopupMenuItem<String>(
            value: c,
            child: Text('全部折成 ${Money.symbolFor(c).trim()} $c（今日汇率）'),
          ),
      ],
    );
  }
}
