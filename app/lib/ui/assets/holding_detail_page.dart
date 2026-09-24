import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../core/money.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../widgets/widgets.dart';
import 'asset_providers.dart';
import 'asset_widgets.dart';
import 'invest_tab.dart';
import 'trade_sheet.dart';

/// 持仓详情：市值、收益、今日涨跌、持有天数；加仓/减仓、手动改价、编辑、删除。
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

  Future<void> _trade(Holding h, {required bool buy}) async {
    setState(() => _error = null);
    await showTradeSheet(context, h, buy: buy);
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
        content: const Text('只删这笔持仓，开仓、加减仓时记的流水还在。'),
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
        appBar: AppBar(title: const Text('持仓')),
        body: const SkeletonList(rows: 5),
      );
    }
    if (h == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('持仓')),
        body: const InlineError(message: '这笔持仓已经不在了。'),
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
                  children: [
                    FilledButton.tonal(
                      onPressed: _busy ? null : () => _trade(h, buy: true),
                      child: const Text('加仓'),
                    ),
                    OutlinedButton(
                      onPressed: _busy || h.isCleared
                          ? null
                          : () => _trade(h, buy: false),
                      child: const Text('减仓'),
                    ),
                    OutlinedButton(
                      onPressed: _busy ? null : () => _setPrice(h),
                      child: const Text('改价'),
                    ),
                  ],
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

  List<Widget> _details(Holding h, HoldingMetrics m, LedgerData ledger) {
    final opened = localDate(h.openedOn);
    final price = h.priceE4;
    final at = h.priceAt;
    final account = ledger.account(h.accountId);
    final daily = m.dailyGainCents;
    return [
      const SectionHeader('明细'),
      InfoRow('份额', InfoText('${formatE4(h.quantityE4)} 份')),
      InfoRow('成本', MoneyText(h.costCents)),
      if (h.quantityE4 > 0)
        InfoRow(
          '成本价',
          InfoText(
            formatE4(
              (h.costCents * 1e6 / h.quantityE4).round(),
              minFraction: 2,
            ),
          ),
        ),
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
      if (!m.cleared && daily != null)
        InfoRow('日均收益', MoneyText(daily.round(), signed: true)),
      InfoRow('已实现盈亏', MoneyText(h.realizedCents, signed: true)),
      if (opened != null) InfoRow('开仓', InfoText(Dates.dayLabel(opened))),
      InfoRow(
        '市场',
        InfoText([h.marketLabel, if (h.code != null) h.code!].join(' · ')),
      ),
      InfoRow('投资账户', InfoText(account?.name ?? '没挂')),
      if (h.note != null && h.note!.isNotEmpty) InfoRow('备注', InfoText(h.note!)),
    ];
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
    final tag = m.cleared ? '已清仓' : priceTag(holding, m);
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
              Text(m.cleared ? '已实现盈亏' : '市值', style: theme.textTheme.bodySmall),
              if (tag != null) ...[
                const SizedBox(width: 8),
                TagLabel(
                  tag,
                  tone: tag == '行情过期' || tag == '没有价格'
                      ? TagTone.warning
                      : TagTone.neutral,
                ),
              ],
            ],
          ),
          const SizedBox(height: 2),
          if (m.cleared)
            MoneyText(holding.realizedCents, signed: true, size: MoneySize.display)
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
                    label: '收益',
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
                Expanded(
                  child: _Cell(
                    label: '今日涨跌',
                    child: m.todayChangeCents == null
                        ? Text(
                            m.manual ? '手动价没有昨收' : '—',
                            style: theme.textTheme.bodySmall,
                          )
                        : MoneyText(m.todayChangeCents!, signed: true),
                  ),
                ),
              ],
            ),
          ],
          if (m.cleared) ...[
            const SizedBox(height: 4),
            Text(
              '全卖光了，留着看赚了多少。再买进来就点「加仓」。',
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
