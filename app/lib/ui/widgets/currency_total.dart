import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/models/models.dart';
import '../../core/money.dart';
import 'money_text.dart';

/// 一组按币种分开的金额写成一句：「¥1,000.00 + $200.00」（基准币在前，其余按代码）。全是 0 写基准币的 0。
/// 用在副标题、说明文字里；要排版的地方用 [CurrencyTotal]。给了 [convertTo]（「换算」选的币种）和 [fx]
/// 就按今日汇率合成一个数，缺汇率的注明「不含 X」。
String formatAmounts(
  CurrencyAmounts amounts, {
  String base = 'CNY',
  bool signed = false,
  String? convertTo,
  FxRates? fx,
}) {
  if (convertTo != null && fx != null) {
    final r = amounts.convert(fx, convertTo);
    final text = Money.format(r.cents, currency: convertTo, signed: signed);
    return r.missing.isEmpty ? text : '$text（不含 ${r.missing.join('、')}）';
  }
  final nonZero = amounts.nonZero;
  if (nonZero.isEmpty) return Money.format(0, currency: base, signed: signed);
  final keys = nonZero.keys.toList()..sort((a, b) => a == base ? -1 : b == base ? 1 : a.compareTo(b));
  return keys.map((c) => Money.format(nonZero[c]!, currency: c, signed: signed)).join(' + ');
}

/// 合计（净资产、本月支出、板块余额、理财 / 债务 / 物品小结……）：按币种分开显示，不偷偷折算。
///
/// - 基准币和设置里的「显示币种」（默认人民币、美元）有数就常驻；其他外币收进「+N 种」，点开看全部。
/// - 只有一种币时就是一个 [MoneyText] —— 单币种的家庭看到的和以前一模一样。
/// - 「换算」选了币种（[displayCurrencyOverrideProvider]）时按今日汇率合成一个数；缺汇率的那部分不臆造，
///   后面注一句「不含 X（缺汇率）」。
///
/// 第一个币种用 [size]，后面的小一号，读的时候主次分明。
class CurrencyTotal extends ConsumerStatefulWidget {
  const CurrencyTotal(
    this.amounts, {
    super.key,
    this.size = MoneySize.body,
    this.signed = false,
    this.color,
    this.muted = false,
    this.alignEnd = false,
  });

  final CurrencyAmounts amounts;
  final MoneySize size;
  final bool signed;
  final Color? color;
  final bool muted;

  /// 放在行尾（列表右边）时右对齐。
  final bool alignEnd;

  @override
  ConsumerState<CurrencyTotal> createState() => _CurrencyTotalState();
}

class _CurrencyTotalState extends ConsumerState<CurrencyTotal> {
  bool _expanded = false;

  static MoneySize _smaller(MoneySize s) => switch (s) {
    MoneySize.display => MoneySize.title,
    MoneySize.title => MoneySize.body,
    MoneySize.body => MoneySize.body,
    MoneySize.small => MoneySize.small,
  };

  Widget _money(int cents, String currency, MoneySize size) => MoneyText(
    cents,
    currency: currency,
    size: size,
    signed: widget.signed,
    color: widget.color,
    muted: widget.muted,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fx = ref.watch(fxRatesProvider);
    final base = fx.base;
    final target = ref.watch(displayCurrencyOverrideProvider);
    final nonZero = widget.amounts.nonZero;
    final align = widget.alignEnd ? WrapAlignment.end : WrapAlignment.start;

    if (target != null) {
      final r = widget.amounts.convert(fx, target);
      final main = _money(r.cents, target, widget.size);
      if (r.missing.isEmpty) return main;
      return Wrap(
        spacing: 6,
        alignment: align,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          main,
          Text(
            '不含 ${r.missing.join('、')}（缺汇率）',
            key: const ValueKey('currency-missing'),
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
          ),
        ],
      );
    }

    if (nonZero.isEmpty) return _money(0, base, widget.size);
    if (nonZero.length == 1) {
      final only = nonZero.entries.first;
      return _money(only.value, only.key, widget.size);
    }

    // 排序：基准币、显示币种（按设置里的顺序）、其余按代码。
    final display = ref.watch(displayCurrenciesProvider).map((c) => c.toUpperCase()).toList();
    final pinned = [base, ...display.where((c) => c != base)];
    int rank(String c) {
      final i = pinned.indexOf(c);
      return i < 0 ? pinned.length : i;
    }

    final ordered = nonZero.keys.toList()..sort((a, b) => rank(a) != rank(b) ? rank(a) - rank(b) : a.compareTo(b));
    var visible = ordered.where(pinned.contains).toList();
    var hidden = ordered.where((c) => !pinned.contains(c)).toList();
    if (visible.isEmpty) {
      visible = hidden;
      hidden = const [];
    }
    final small = _smaller(widget.size);
    return Wrap(
      spacing: 10,
      runSpacing: 2,
      alignment: align,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var i = 0; i < visible.length; i++) _money(nonZero[visible[i]]!, visible[i], i == 0 ? widget.size : small),
        if (_expanded) for (final c in hidden) _money(nonZero[c]!, c, small),
        if (hidden.isNotEmpty)
          InkWell(
            key: const ValueKey('currency-more'),
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Text(
                _expanded ? '收起' : '+${hidden.length} 种',
                semanticsLabel: _expanded ? '收起其他币种' : '还有 ${hidden.length} 种外币，点开看',
                style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary),
              ),
            ),
          ),
      ],
    );
  }
}
