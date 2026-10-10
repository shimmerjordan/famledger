import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../core/money.dart';
import '../../data/models/models.dart';
import '../../data/repos/holdings_repo.dart';
import '../../data/repos/ledger_repo.dart';
import '../widgets/widgets.dart';
import 'asset_providers.dart';
import 'asset_widgets.dart';
import 'invest_tab.dart';
import 'trade_sheet.dart';

/// 理财详情。按记法（[InvestMode]）各画各的：
/// - 份额类：市值、收益、今日涨跌；加仓 / 减仓 / 分红 / 改价。
/// - 定期类：本息（按天计息）、利息、离到期几天；到期取出 / 收到利息。
/// - 金额类：当前金额、收益、多久没更新；更新金额 / 存入 / 取出。
class HoldingDetailPage extends ConsumerStatefulWidget {
  const HoldingDetailPage(this.id, {super.key});

  final String id;

  @override
  ConsumerState<HoldingDetailPage> createState() => _HoldingDetailPageState();
}

class _HoldingDetailPageState extends ConsumerState<HoldingDetailPage> {
  bool _busy = false;
  String? _error;
  Object? _syncError;

  /// 删掉时本地先拿掉、同步完才退出去，这中间照旧画删之前的样子，不闪「已经不在了」。
  bool _deleting = false;
  Holding? _last;

  Future<void> _sync() async {
    Object? error;
    try {
      await ref.read(ledgerProvider.notifier).sync();
    } catch (e) {
      error = e;
    }
    if (mounted) setState(() => _syncError = error);
  }

  Future<void> _trade(Holding h, TradeSide side) async {
    setState(() => _error = null);
    await showTradeSheet(context, h, side: side);
  }

  Future<void> _setValue(Holding h) async {
    final value = await showDialog<int>(
      context: context,
      builder: (context) => _ValueDialog(holding: h),
    );
    if (value == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(holdingsRepoProvider).setValue(h.id, value);
      refreshNetWorth(ref);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('当前金额改成 ${Money.format(value)}')),
      );
    } catch (error) {
      if (mounted) setState(() => _error = describeError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setPrice(Holding h) async {
    final price = await showDialog<int>(
      context: context,
      builder: (context) => _PriceDialog(holding: h),
    );
    if (price == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(holdingsRepoProvider).setPrice(h.id, price);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('价格改成 ${formatE4(price, minFraction: 2)}')),
      );
    } catch (error) {
      if (mounted) setState(() => _error = describeError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(Holding h) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删掉「${h.label}」？'),
        content: const Text('只删这笔理财，买入、存取时记的流水还在。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('算了'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删掉'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _busy = true;
      _deleting = true;
    });
    try {
      await ref.read(holdingsRepoProvider).delete(h.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已删掉')),
      );
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/assets?tab=invest');
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _deleting = false;
        _error = describeError(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ledger = ref.watch(ledgerProvider).valueOrNull;
    final live = ledger?.holding(widget.id);
    if (live != null) _last = live;
    final h = live ?? (_deleting ? _last : null);
    if (ledger == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('理财')),
        body: const SkeletonList(rows: 5),
      );
    }
    if (h == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('理财')),
        body: const InlineError(message: '这笔理财已经不在了。'),
      );
    }
    final now = ref.watch(assetClockProvider)();
    final m = holdingMetrics(h, now);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(h.label, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '编辑',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => context.push('/assets/holdings/${h.id}/edit'),
          ),
          IconButton(
            tooltip: '删除',
            icon: const Icon(Icons.delete_outline),
            onPressed: _busy ? null : () => _delete(h),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _sync,
        child: LayoutBuilder(
          builder: (context, box) => ListView(
            padding: readableInsets(box.maxWidth, maxWidth: 720)
                .copyWith(bottom: 96),
            children: [
              SyncErrorBanner(error: _syncError, onRetry: _sync),
              _Hero(holding: h, metrics: m),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: LedgerLayout.pagePadding,
                ),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _actions(h, m),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    LedgerLayout.pagePadding,
                    LedgerLayout.itemGap,
                    LedgerLayout.pagePadding,
                    0,
                  ),
                  child: Text(
                    _error!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: LedgerLayout.groupGap),
              ..._details(h, m, ledger),
            ],
          ),
        ),
      ),
    );
  }

  /// 动作按钮：最常用的那个是实心的（定期到期了才把「到期取出」顶到前面）。
  List<Widget> _actions(Holding h, HoldingMetrics m) {
    Widget primary(String label, VoidCallback? onPressed) =>
        FilledButton.tonal(onPressed: _busy ? null : onPressed, child: Text(label));
    Widget secondary(String label, VoidCallback? onPressed) =>
        OutlinedButton(onPressed: _busy ? null : onPressed, child: Text(label));
    switch (h.mode) {
      case InvestMode.unit:
        return [
          primary('加仓', () => _trade(h, TradeSide.buy)),
          secondary('减仓', h.isCleared ? null : () => _trade(h, TradeSide.sell)),
          secondary('分红', () => _trade(h, TradeSide.income)),
          secondary('改价', () => _setPrice(h)),
        ];
      case InvestMode.balance:
        return [
          primary('更新金额', h.isCleared ? null : () => _setValue(h)),
          secondary('存入', () => _trade(h, TradeSide.buy)),
          secondary('取出', h.isCleared ? null : () => _trade(h, TradeSide.sell)),
        ];
      case InvestMode.deposit:
        final out = h.isCleared ? null : () => _trade(h, TradeSide.sell);
        final interest = h.isCleared ? null : () => _trade(h, TradeSide.income);
        return m.matured
            ? [primary('到期取出', out), secondary('收到利息', interest)]
            : [secondary('提前取出', out), secondary('收到利息', interest)];
    }
  }

  List<Widget> _details(Holding h, HoldingMetrics m, LedgerData ledger) {
    final opened = localDate(h.openedOn);
    final account = ledger.account(h.accountId);
    final daily = m.dailyGainCents;
    final common = [
      InfoRow('投资账户', InfoText(account?.name ?? '没挂')),
      if (h.institution != null && h.institution!.isNotEmpty) InfoRow('在哪买的', InfoText(h.institution!)),
      if (h.note != null && h.note!.isNotEmpty) InfoRow('备注', InfoText(h.note!)),
    ];
    switch (h.mode) {
      case InvestMode.unit:
        final price = h.priceE4;
        final at = h.priceAt;
        final unitName = h.kind == Holding.kindGold ? '克' : '份';
        return [
          const SectionHeader('明细'),
          InfoRow('品类', InfoText(h.kindLabel)),
          InfoRow(h.kind == Holding.kindGold ? '克数' : '份额', InfoText('${formatE4(h.quantityE4)} $unitName')),
          InfoRow('成本', MoneyText(h.costCents)),
          if (h.quantityE4 > 0)
            InfoRow('成本价', InfoText(formatE4((h.costCents * 1e6 / h.quantityE4).round(), minFraction: 2))),
          InfoRow(
            '现价',
            InfoText(
              price == null
                  ? '还没有'
                  : [
                      formatE4(price, minFraction: 2),
                      h.isAuto ? '自动' : '手动',
                      if (at != null) Dates.dateTimeLabel(at),
                    ].join(' · '),
            ),
          ),
          if (!m.cleared) InfoRow('持有', InfoText('${m.days} 天')),
          if (!m.cleared && daily != null) InfoRow('日均收益', MoneyText(daily.round(), signed: true)),
          InfoRow('已实现盈亏', MoneyText(h.realizedCents, signed: true)),
          if (opened != null) InfoRow('开仓', InfoText(Dates.dayLabel(opened))),
          if (h.kind != Holding.kindGold)
            InfoRow('市场', InfoText([h.marketLabel, if (h.code != null) h.code!].join(' · '))),
          ...common,
        ];
      case InvestMode.deposit:
        final due = localDate(h.maturesOn);
        final rate = h.rateE6;
        final term = parseDay(h.maturesOn)?.difference(parseDay(h.openedOn) ?? DateTime.utc(1970)).inDays;
        final accrued = h.isCleared
            ? null
            : accruedCents(h.costCents, rate, h.openedOn, _accrualEnd(h));
        return [
          const SectionHeader('明细'),
          InfoRow('品类', InfoText(h.kindLabel)),
          InfoRow('本金', MoneyText(h.isCleared ? 0 : h.costCents)),
          InfoRow(
            h.kind == Holding.kindStructured ? '年化（保底 ~ 最高）' : '年化',
            InfoText(
              rate == null
                  ? '没填'
                  : h.rateMaxE6 != null
                  ? '${formatRateE6(rate)} ~ ${formatRateE6(h.rateMaxE6!)}'
                  : formatRateE6(rate),
            ),
          ),
          if (opened != null) InfoRow('起息', InfoText(Dates.dayLabel(opened))),
          if (due != null) InfoRow('到期', InfoText(Dates.dayLabel(due))),
          if (term != null && term > 0) InfoRow('期限', InfoText('$term 天')),
          if (accrued != null) InfoRow('已计息', MoneyText(accrued, signed: true)),
          InfoRow(h.isCleared ? '利息合计' : '已到手的利息', MoneyText(h.realizedCents, signed: true)),
          ...common,
        ];
      case InvestMode.balance:
        final valueOn = localDate(h.valueOn);
        return [
          const SectionHeader('明细'),
          InfoRow('品类', InfoText(h.kindLabel)),
          InfoRow('本金', MoneyText(h.costCents)),
          InfoRow('当前金额', MoneyText(h.isCleared ? 0 : h.valueCents ?? h.costCents)),
          InfoRow('更新于', InfoText(valueOn == null ? '没更新过（按本金）' : Dates.dayLabel(valueOn))),
          if (h.rateE6 != null) InfoRow('年化', InfoText(formatRateE6(h.rateE6!))),
          InfoRow('已实现收益', MoneyText(h.realizedCents, signed: true)),
          if (opened != null) InfoRow('存入', InfoText(Dates.dayLabel(opened))),
          ...common,
        ];
    }
  }

  /// 计息算到哪天：同 holdingValueCents，到期了停在到期日。
  String _accrualEnd(Holding h) {
    final now = localDay(ref.read(assetClockProvider)());
    final today = Dates.isoDate(DateTime(now.year, now.month, now.day));
    final due = h.maturesOn;
    return due != null && due.compareTo(today) < 0 ? due : today;
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.holding, required this.metrics});

  final Holding holding;
  final HoldingMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = metrics;
    final h = holding;
    final tag = m.cleared ? (h.mode == InvestMode.unit ? '已清仓' : '已结清') : investTag(h, m);
    final label = switch (h.mode) {
      _ when m.cleared => h.mode == InvestMode.unit ? '已实现盈亏' : '已实现收益',
      InvestMode.unit => '市值',
      InvestMode.deposit => '本息',
      InvestMode.balance => '当前金额',
    };
    final secondLabel = switch (h.mode) {
      InvestMode.unit => '今日涨跌',
      InvestMode.deposit => '到期',
      InvestMode.balance => '更新于',
    };
    final Widget second = switch (h.mode) {
      InvestMode.unit => m.todayChangeCents == null
          ? Text(m.manual ? '手动价没有昨收' : '—', style: theme.textTheme.bodySmall)
          : MoneyText(m.todayChangeCents!, signed: true),
      InvestMode.deposit => Text(maturityLabel(m) ?? '—', style: theme.textTheme.bodyLarge),
      InvestMode.balance => Text(
          h.valueOn == null ? '没更新过' : Dates.dayLabel(localDate(h.valueOn)!),
          style: theme.textTheme.bodyLarge,
        ),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LedgerLayout.pagePadding,
        LedgerLayout.pagePadding,
        LedgerLayout.pagePadding,
        LedgerLayout.groupGap,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label, style: theme.textTheme.bodySmall),
              if (tag != null) ...[
                const SizedBox(width: 8),
                TagLabel(tag, tone: warningTags.contains(tag) ? TagTone.warning : TagTone.neutral),
              ],
            ],
          ),
          const SizedBox(height: 2),
          if (m.cleared)
            MoneyText(h.realizedCents, signed: true, size: MoneySize.display)
          else if (m.marketCents != null)
            MoneyText(m.marketCents!, size: MoneySize.display)
          else
            Text('还没有价格', style: theme.textTheme.headlineMedium),
          if (!m.cleared) ...[
            const SizedBox(height: LedgerLayout.itemGap),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _Cell(
                    label: h.mode == InvestMode.deposit ? '利息' : '收益',
                    child: Wrap(
                      spacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (m.gainCents != null)
                          MoneyText(m.gainCents!, signed: true)
                        else
                          Text('—', style: theme.textTheme.bodyLarge),
                        RateText(m.gainRate),
                      ],
                    ),
                  ),
                ),
                Expanded(child: _Cell(label: secondLabel, child: second)),
              ],
            ),
          ],
          if (m.cleared) ...[
            const SizedBox(height: 4),
            Text(
              h.mode == InvestMode.unit ? '全卖光了，留着看赚了多少。再买进来就点「加仓」。' : '已经结清了，留着看赚了多少。',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 2),
      child,
    ],
  );
}

/// 手动改价：填一个价，返回 ×10000 的整数。
class _PriceDialog extends StatefulWidget {
  const _PriceDialog({required this.holding});

  final Holding holding;

  @override
  State<_PriceDialog> createState() => _PriceDialogState();
}

class _PriceDialogState extends State<_PriceDialog> {
  late final TextEditingController _price = TextEditingController(
    text: widget.holding.priceE4 == null
        ? ''
        : formatE4(widget.holding.priceE4!, minFraction: 2).replaceAll(',', ''),
  );
  String? _error;

  @override
  void dispose() {
    _price.dispose();
    super.dispose();
  }

  void _submit() {
    final value = parseE4(_price.text);
    if (value == null) {
      setState(() => _error = '填个价格，例如 1.0230');
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('手动改价'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: const ValueKey('price-input'),
          controller: _price,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            prefixText: '${Money.symbol} ',
            hintText: '1.0230',
            errorText: _error,
          ),
          onSubmitted: (_) => _submit(),
        ),
        if (widget.holding.isAuto) ...[
          const SizedBox(height: 8),
          Text(
            '开着自动行情，下次刷新会被最新价覆盖。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('算了'),
      ),
      FilledButton(onPressed: _submit, child: const Text('改好了')),
    ],
  );
}

/// 金额类更新当前金额：看着 App 里的数填，返回分。
class _ValueDialog extends StatefulWidget {
  const _ValueDialog({required this.holding});

  final Holding holding;

  @override
  State<_ValueDialog> createState() => _ValueDialogState();
}

class _ValueDialogState extends State<_ValueDialog> {
  late final TextEditingController _value = TextEditingController(
    text: Money.input(widget.holding.valueCents ?? widget.holding.costCents),
  );
  String? _error;

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  void _submit() {
    final value = parseMoneyField(_value.text);
    if (value == null || value < 0) {
      setState(() => _error = '填个金额，例如 10230.55');
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('更新当前金额'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: const ValueKey('value-input'),
          controller: _value,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(prefixText: '${Money.symbol} ', errorText: _error),
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 8),
        Text(
          '看着银行或支付宝 App 里的数填：多出本金的就是收益。存取钱用「存入 / 取出」。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('算了')),
      FilledButton(onPressed: _submit, child: const Text('改好了')),
    ],
  );
}
