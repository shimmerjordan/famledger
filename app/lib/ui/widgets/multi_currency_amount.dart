import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import 'money_text.dart';

/// 单个东西的金额（一个账户、一笔流水、一笔理财、一件物品、一笔债务）：只显示它自己的币种。
/// 合计（跨实体加起来的数）用 [CurrencyTotal]，它会按币种分开。
///
/// 「换算」选了某个币种（[displayCurrencyOverrideProvider]）时按今日汇率折过去显示（纯显示层，
/// 不改存量金额）；缺汇率就照原币显示并注「缺汇率」，绝不臆造。
class MultiCurrencyAmount extends ConsumerWidget {
  const MultiCurrencyAmount(
    this.cents, {
    super.key,
    required this.currency,
    this.signed = false,
    this.size = MoneySize.body,
    this.showSymbol = true,
    this.color,
    this.muted = false,
  });

  final int cents;

  /// 这笔金额的原生币种。
  final String currency;
  final bool signed;
  final MoneySize size;
  final bool showSymbol;
  final Color? color;
  final bool muted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = ref.watch(displayCurrencyOverrideProvider);
    if (target == null || target.toUpperCase() == currency.toUpperCase()) return _money(cents, currency);
    final converted = ref.watch(fxRatesProvider).convert(cents, currency, target);
    if (converted != null) return _money(converted, target);
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: _money(cents, currency)),
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 4),
          child: Text('缺汇率', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
        ),
      ],
    );
  }

  Widget _money(int value, String cur) => MoneyText(
    value,
    signed: signed,
    size: size,
    showSymbol: showSymbol,
    color: color,
    muted: muted,
    currency: cur,
  );
}
