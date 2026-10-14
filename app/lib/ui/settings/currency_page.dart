import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../core/money.dart';
import '../../data/models/models.dart';
import '../widgets/widgets.dart';

/// 「币种与汇率」：家庭基准币、常驻显示的币种、汇率刷新。
///
/// - 基准币（[Settings.currency]）：所有聚合（净资产、月度收支、模块合计）都由服务端折成它；
///   各条目仍按自己的原生币存，这里只改「汇总口径」。
/// - 显示币种（[UiSettings.displayCurrencies]）：合计按币种分开显示时，这些币种有数就常驻（默认人民币 + 美元），其他外币收进「+N 种」。
/// - 汇率来自腾讯行情，服务端定时抓；这里能手动「立即刷新」，并显示最近更新时间与缺哪些对。
///
/// 改设置（`PATCH /settings`）与刷新（`POST /fx/refresh`）都是管理员权限，成员只读。
class CurrencyPage extends ConsumerStatefulWidget {
  const CurrencyPage({super.key});

  @override
  ConsumerState<CurrencyPage> createState() => _CurrencyPageState();
}

/// 常见币种（代码, 中文名）。基准币 / 显示币都从这里选；不认识的代码也能显示（回退成「CODE」）。
const List<(String, String)> _kCurrencies = [
  ('CNY', '人民币'),
  ('USD', '美元'),
  ('EUR', '欧元'),
  ('GBP', '英镑'),
  ('JPY', '日元'),
  ('KRW', '韩元'),
  ('HKD', '港币'),
  ('AUD', '澳元'),
  ('CAD', '加元'),
  ('SGD', '新加坡元'),
  ('CHF', '瑞士法郎'),
  ('TWD', '新台币'),
  ('THB', '泰铢'),
  ('MYR', '林吉特'),
];

/// `¥ CNY · 人民币`；认不出的代码回退成 `CODE`（[Money.symbolFor] 对未知币给「CODE 」，此时只显示代码）。
String _currencyLabel(String code) {
  final c = code.toUpperCase();
  for (final (known, name) in _kCurrencies) {
    if (known == c) return '${Money.symbolFor(c)} $c · $name';
  }
  return c;
}

/// 紧凑标签（下拉、chip 用）：`¥ CNY`；未知币只显示代码。
String _shortLabel(String code) {
  final c = code.toUpperCase();
  final sym = Money.symbolFor(c);
  return sym.endsWith(' ') ? c : '$sym $c';
}

class _CurrencyPageState extends ConsumerState<CurrencyPage> {
  bool _saving = false;
  bool _refreshing = false;
  String? _error;
  String? _notice;

  // ------------------------------------------------------------ 动作

  Future<void> _patch(Map<String, dynamic> body, String ok) async {
    setState(() {
      _saving = true;
      _error = null;
      _notice = null;
    });
    try {
      await ref.read(settingsProvider.notifier).patch(body);
      // 改了基准币 / 显示币后让当月总览重拉（内嵌 fx 也随之更新）。
      ref.invalidate(statsProvider);
      if (mounted) setState(() => _notice = ok);
    } catch (e) {
      if (mounted) setState(() => _error = '没改成：${describeError(e)}');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _setBase(String code) => _patch(
    {'currency': code},
    '基准币已改成 ${_shortLabel(code)}；建议点「立即刷新」按新基准币重抓汇率',
  );

  void _toggleDisplay(String code, bool on) {
    final current = ref.read(displayCurrenciesProvider);
    final next = on
        ? [...current, if (!current.contains(code)) code]
        : current.where((c) => c != code).toList();
    // 至少留一个：删到空服务端也会回退默认，这里直接挡住。
    if (next.isEmpty) {
      setState(() {
        _error = '至少保留一个显示币种';
        _notice = null;
      });
      return;
    }
    _patch({'ui': {'displayCurrencies': next}}, '常驻显示的币种已更新');
  }

  Future<void> _refreshRates() async {
    setState(() {
      _refreshing = true;
      _error = null;
      _notice = null;
    });
    try {
      final res = await ref.read(apiProvider).post('/fx/refresh', const {});
      // 抓完让总览重拉，内嵌 fx（asOf、rates）随之刷新，「换算」都用上新价。
      ref.invalidate(statsProvider);
      if (!mounted) return;
      final updated = (res['updated'] as num?)?.toInt() ?? 0;
      final failed = (res['failed'] as List?)?.length ?? 0;
      setState(() {
        _notice = failed == 0
            ? '汇率已刷新（更新 $updated 个币种）'
            : '汇率已刷新：更新 $updated 个，$failed 个没抓到（保留旧价）';
      });
    } catch (e) {
      if (mounted) setState(() => _error = '刷新失败：${describeError(e)}');
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  // ------------------------------------------------------------ 界面

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider).valueOrNull;
    final isAdmin = ref.watch(sessionProvider)?.me.isAdmin ?? false;
    final base = (settings?.currency ?? 'CNY').toUpperCase();
    final display = ref.watch(displayCurrenciesProvider);
    final fx = ref.watch(fxRatesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('币种与汇率')),
      body: ReadableListView(
        maxWidth: 720,
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const SectionHeader('基准币'),
          _baseTile(base, isAdmin),
          _hint('预算、分析图表和「换算」默认折成这个币种（按今日汇率）；各条目仍按自己的币种存，改这里不动存量数字。'),
          const SizedBox(height: LedgerLayout.groupGap),
          const SectionHeader('常驻显示的币种'),
          _displayChips(display, isAdmin && !_saving),
          _hint('合计按币种分开显示：这几个币种有数就常驻（默认人民币、美元），其他外币收进「+N 种」点开看。要合成一个数，点顶栏的「换算」。'),
          const SizedBox(height: LedgerLayout.groupGap),
          const SectionHeader('汇率'),
          _ratesSection(fx, isAdmin),
          if (!isAdmin) _hint('只有管理员能改币种与刷新汇率。'),
          if (_error != null) _warn(_error!),
          if (_notice != null) _hint(_notice!),
        ],
      ),
    );
  }

  Widget _baseTile(String base, bool isAdmin) {
    final codes = <String>[for (final (c, _) in _kCurrencies) c];
    if (!codes.contains(base)) codes.insert(0, base);
    return ListTile(
      leading: const Icon(Icons.flag_outlined),
      title: const Text('家庭基准币'),
      subtitle: Text(_currencyLabel(base)),
      trailing: DropdownButton<String>(
        value: base,
        underline: const SizedBox.shrink(),
        items: [
          for (final c in codes) DropdownMenuItem(value: c, child: Text(_shortLabel(c))),
        ],
        onChanged: isAdmin && !_saving ? (v) {
          if (v != null && v != base) _setBase(v);
        } : null,
      ),
    );
  }

  Widget _displayChips(List<String> display, bool canEdit) {
    final selected = display.map((e) => e.toUpperCase()).toSet();
    // 预设币种之外，服务端可能存了别的显示币，也补一个 chip 出来，免得「选着却看不见、也删不掉」。
    final codes = <String>[for (final (c, _) in _kCurrencies) c];
    for (final s in selected) {
      if (!codes.contains(s)) codes.add(s);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final c in codes)
            FilterChip(
              label: Text(_shortLabel(c)),
              selected: selected.contains(c),
              onSelected: canEdit ? (on) => _toggleDisplay(c, on) : null,
            ),
        ],
      ),
    );
  }

  Widget _ratesSection(FxRates fx, bool isAdmin) {
    final theme = Theme.of(context);
    final asOf = fx.asOf == null ? null : DateTime.tryParse(fx.asOf!);
    final entries = fx.rates.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: const Icon(Icons.currency_exchange),
          title: const Text('最近更新'),
          subtitle: Text(asOf == null ? '还没抓过汇率' : Dates.dateTimeLabel(asOf.toLocal())),
          trailing: isAdmin
              ? FilledButton.tonal(
                  onPressed: _refreshing ? null : _refreshRates,
                  child: _refreshing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('立即刷新'),
                )
              : null,
        ),
        if (entries.isEmpty)
          _hint('还没有汇率数据。刷新一次后，这里会列出 1 ${_shortLabel(fx.base)} 能换多少其它币种。')
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 0, LedgerLayout.pagePadding, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('1 ${_shortLabel(fx.base)} =', style: theme.textTheme.labelMedium),
                const SizedBox(height: 4),
                for (final e in entries)
                  Text(
                    '${_shortLabel(e.key)}  ${(e.value / 1e6).toStringAsFixed(4)}',
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
          ),
        if (fx.missing.isNotEmpty)
          _warn('这些币种暂时没抓到汇率，聚合里已按 0 计入、显示时只出原生币：${fx.missing.join('、')}'),
      ],
    );
  }

  Widget _hint(String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 4, LedgerLayout.pagePadding, 0),
      child: Text(text, style: theme.textTheme.bodySmall),
    );
  }

  Widget _warn(String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 8, LedgerLayout.pagePadding, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 16, color: theme.colorScheme.error),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
          ),
        ],
      ),
    );
  }
}
