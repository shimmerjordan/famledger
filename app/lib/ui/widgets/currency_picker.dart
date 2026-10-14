import 'package:flutter/material.dart';

import '../../core/money.dart';

/// 常用币种：前几个直接给 chip，其余收在「其他币种」里。
const List<String> kCommonCurrencies = ['CNY', 'USD', 'HKD', 'EUR', 'JPY', 'GBP'];
const List<String> kMoreCurrencies = ['AUD', 'CAD', 'SGD', 'CHF', 'KRW', 'TWD', 'MOP', 'NZD', 'THB'];

/// 币种的中文名：「人民币」「美元」……认不出就是代码本身。
String currencyName(String code) => switch (code.toUpperCase()) {
  'CNY' => '人民币',
  'USD' => '美元',
  'HKD' => '港币',
  'EUR' => '欧元',
  'JPY' => '日元',
  'GBP' => '英镑',
  'AUD' => '澳元',
  'CAD' => '加元',
  'SGD' => '新加坡元',
  'CHF' => '瑞士法郎',
  'KRW' => '韩元',
  'TWD' => '新台币',
  'MOP' => '澳门元',
  'NZD' => '新西兰元',
  'THB' => '泰铢',
  _ => code.toUpperCase(),
};

/// 选币种：常用的几个是 chip，其余在「其他币种」菜单里；选中的不常用币种也补一个 chip 显示出来。
/// [enabled] 为 false 时只读（比如债务建好后币种不能改）。控件 key：`<keyPrefix>-<代码>`、`<keyPrefix>-more`。
class CurrencyPicker extends StatelessWidget {
  const CurrencyPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.keyPrefix = 'currency',
  });

  final String value;
  final ValueChanged<String> onChanged;
  final bool enabled;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final selected = value.toUpperCase();
    final shown = [...kCommonCurrencies, if (!kCommonCurrencies.contains(selected)) selected];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final c in shown)
          ChoiceChip(
            key: ValueKey('$keyPrefix-$c'),
            showCheckmark: false,
            selected: c == selected,
            onSelected: enabled ? (_) => onChanged(c) : null,
            label: Text('${currencyName(c)} ${Money.symbolFor(c).trim()}'),
          ),
        if (enabled)
          PopupMenuButton<String>(
            key: ValueKey('$keyPrefix-more'),
            tooltip: '其他币种',
            onSelected: onChanged,
            itemBuilder: (context) => [
              for (final c in kMoreCurrencies) PopupMenuItem(value: c, child: Text('${currencyName(c)} $c')),
            ],
            child: const Chip(label: Text('其他币种'), avatar: Icon(Icons.expand_more, size: 18)),
          ),
      ],
    );
  }
}

/// 紧凑的币种下拉：放在金额输入框右边，和金额同一行（「¥ 5999 [人民币 ▾]」），不多占一行。
/// 选项是常用币种 + 其他币种；当前值不在里面也补上。key：传进来的 [key]，选项 `<keyPrefix>-<代码>`。
class CurrencyDropdown extends StatelessWidget {
  const CurrencyDropdown({
    super.key,
    required this.value,
    required this.onChanged,
    this.keyPrefix = 'currency',
  });

  final String value;
  final ValueChanged<String> onChanged;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final selected = value.toUpperCase();
    final options = [...kCommonCurrencies, ...kMoreCurrencies, if (!kCommonCurrencies.contains(selected) && !kMoreCurrencies.contains(selected)) selected];
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: selected,
        isDense: true,
        borderRadius: BorderRadius.circular(12),
        items: [
          for (final c in options)
            DropdownMenuItem(
              key: ValueKey('$keyPrefix-$c'),
              value: c,
              child: Text(currencyName(c)),
            ),
        ],
        onChanged: (c) {
          if (c != null) onChanged(c);
        },
      ),
    );
  }
}
