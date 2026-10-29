import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/shell.dart';
import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../core/money.dart';
import '../../data/models/models.dart';
import '../../data/repos/holdings_repo.dart';
import '../../data/repos/ledger_repo.dart';
import '../settings/account_form.dart';
import '../widgets/widgets.dart';
import 'absorb_sheet.dart';
import 'asset_providers.dart';
import 'asset_widgets.dart';
import 'holding_detail_page.dart';
import 'stock_account_page.dart';

/// 理财：估值合计、收益，下面按品类分组（基金、股票、活期、定期……），每组一个小计；结清的收在最后。
class InvestTab extends ConsumerStatefulWidget {
  const InvestTab({super.key});

  @override
  ConsumerState<InvestTab> createState() => _InvestTabState();
}

class _InvestTabState extends ConsumerState<InvestTab> {
  Object? _syncError;
  Object? _refreshError;
  String? _refreshNote;
  bool _refreshing = false;

  Future<void> _sync() async {
    Object? error;
    try {
      await ref.read(ledgerProvider.notifier).sync();
      if (mounted) refreshNetWorth(ref);
    } catch (e) {
      error = e;
    }
    if (mounted) setState(() => _syncError = error);
  }

  Future<void> _refreshQuotes() async {
    setState(() {
      _refreshing = true;
      _refreshError = null;
      _refreshNote = null;
    });
    try {
      final result = await ref
          .read(holdingsRepoProvider)
          .refresh(now: ref.read(assetClockProvider)());
      ref.read(quoteRefreshProvider.notifier).state = result;
      if (mounted) setState(() => _refreshNote = _noteFor(result));
    } catch (e) {
      if (mounted) setState(() => _refreshError = e);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  /// 服务端 10 分钟节流、手动价不刷，都得说一声，不然像是按钮没反应。
  static String? _noteFor(QuoteRefresh result) {
    if (result.throttled) return '刚刷过，过几分钟再刷';
    if (result.updated > 0) return '更新了 ${result.updated} 只';
    if (result.failed.isEmpty) return '没有开自动行情的持仓，手动价点进去改';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final ledger = ref.watch(ledgerProvider);
    final now = ref.watch(assetClockProvider)();
    final lastRefresh = ref.watch(quoteRefreshProvider);
    final banner = SyncErrorBanner(error: _syncError, onRetry: _sync);
    // ≥ 840：左边列表、右边嵌着选中那只持仓的详情页。
    final twoPane = widthClassOf(context) == WidthClass.expanded;
    // 股票账户的投入 = 账户余额，在总览里。
    final overview = ref.watch(statsProvider(Dates.currentMonth())).valueOrNull;
    final all = ledger.valueOrNull?.activeHoldings ?? const <Holding>[];
    final stockAccounts = ledger.valueOrNull?.activeAccounts.where((a) => a.isStock).toList() ?? const <Account>[];
    final selected = ref.watch(selectedHoldingProvider);
    final selectedAccount = ref.watch(selectedStockAccountProvider);
    // 右栏二选一：一笔持仓或一个股票账户。都没选（或选的不在了）就默认第一个股票账户，再没有就第一笔持仓。
    String? shown;
    String? shownAccount;
    if (twoPane) {
      if (all.any((h) => h.id == selected)) {
        shown = selected;
      } else if (stockAccounts.any((a) => a.id == selectedAccount)) {
        shownAccount = selectedAccount;
      } else if (stockAccounts.isNotEmpty) {
        shownAccount = stockAccounts.first.id;
      } else {
        shown = all.firstOrNull?.id;
      }
      if (shown != selected) pinSelection(ref, selectedHoldingProvider, shown);
      if (shownAccount != selectedAccount) pinSelection(ref, selectedStockAccountProvider, shownAccount);
    }
    void open(Holding h) {
      if (twoPane) {
        ref.read(selectedStockAccountProvider.notifier).state = null;
        ref.read(selectedHoldingProvider.notifier).state = h.id;
      } else {
        context.push('/assets/holdings/${h.id}');
      }
    }
    void openAccount(Account a) {
      if (twoPane) {
        ref.read(selectedHoldingProvider.notifier).state = null;
        ref.read(selectedStockAccountProvider.notifier).state = a.id;
      } else {
        context.push('/assets/accounts/${a.id}');
      }
    }

    final list = RefreshIndicator(
      onRefresh: _sync,
      child: LayoutBuilder(
        builder: (context, box) => AsyncValueView<LedgerData>(
          value: ledger,
          // 骨架也放进可滚的列表：上面有净资产总览，矮屏（分屏、平板横放）时放不下 5 行。
          loading: ListView(children: const [SkeletonList(rows: 5)]),
          onRetry: () => ref.invalidate(ledgerProvider),
          data: (data) {
            final holdings = data.activeHoldings;
            final accounts = data.activeAccounts.where((a) => a.isStock).toList();
            if (holdings.isEmpty && accounts.isEmpty) {
              return ListView(
                children: [
                  banner,
                  const SizedBox(height: 40),
                  EmptyState(
                    title: '还没有理财',
                    message: '基金、定期、活期、保险存单一笔一笔记；股票按账户汇总，只记整户市值。估值和收益自动算。',
                    icon: Icons.savings_outlined,
                    actionLabel: '添加理财',
                    onAction: () => context.push('/assets/holdings/new'),
                  ),
                  Center(
                    child: TextButton.icon(
                      key: const ValueKey('invest-empty-stock'),
                      onPressed: () => showAccountForm(context, initialKind: Account.kindStock),
                      icon: const Icon(Icons.show_chart, size: 18),
                      label: const Text('新建股票账户'),
                    ),
                  ),
                ],
              );
            }
            final held = holdings.where((h) => !h.isCleared).toList();
            final cleared = holdings.where((h) => h.isCleared).toList();
            final summary = summarizeHoldings(holdings, now);
            // 金额按币种分开（美股按美元算），笔数、品类这些不分。
            final byCurrency = summarizeHoldingsByCurrency(holdings, now);
            final stocks = summarizeStockAccounts(accounts, (id) => overview?.balanceOf(id), now);
            final stockMarket = CurrencyAmounts({for (final e in stocks.entries) e.key: e.value.marketCents});
            // 逐只记的老股票：提醒可以并进股票账户。
            final legacyStocks = held.where((h) => h.kind == Holding.kindStock).toList();
            return ListView(
              padding: (twoPane ? EdgeInsets.zero : readableInsets(box.maxWidth)).copyWith(bottom: 96),
              children: [
                banner,
                _Header(
                  summary: summary,
                  byCurrency: byCurrency,
                  stocks: stocks,
                  priceAt: _latestPriceAt(held),
                  refreshing: _refreshing,
                  refreshError: _refreshError,
                  refreshNote: _refreshNote,
                  lastRefresh: lastRefresh,
                  holdings: holdings,
                  onRefresh: _refreshQuotes,
                ),
                if (accounts.isNotEmpty) ...[
                  SectionHeader(
                    '股票账户',
                    trailing: CurrencyTotal(stockMarket, size: MoneySize.small, muted: true),
                  ),
                  for (final a in accounts)
                    StockAccountTile(
                      account: a,
                      metrics: stockAccountMetrics(a, overview?.balanceOf(a.id), now),
                      selected: a.id == shownAccount,
                      onTap: () => openAccount(a),
                    ),
                ],
                if (legacyStocks.isNotEmpty) _MergeHint(onMerge: () => showAbsorbSheet(context, candidates: held)),
                if (held.isNotEmpty && accounts.isNotEmpty) ...[
                  const SizedBox(height: LedgerLayout.itemGap),
                  const SectionHeader('持仓'),
                ],
                // 不按品类分组（品类写在行里第一段）：一个列表从头看到尾。
                for (final h in held) HoldingTile(holding: h, now: now, selected: h.id == shown, onTap: () => open(h)),
                if (cleared.isNotEmpty) ...[
                  const SizedBox(height: LedgerLayout.groupGap),
                  const SectionHeader('已结清'),
                  for (final h in cleared) HoldingTile(holding: h, now: now, selected: h.id == shown, onTap: () => open(h)),
                ],
              ],
            );
          },
        ),
      ),
    );
    if (!twoPane) return list;
    return AdaptiveTwoPane(
      main: list,
      sideWidth: LedgerLayout.detailPaneWidth,
      side: shownAccount != null
          ? DetailPane(key: ValueKey('stock-pane-$shownAccount'), child: StockAccountPage(shownAccount))
          : shown == null
              ? const EmptyState(title: '选一笔理财看详情', compact: true)
              : DetailPane(key: ValueKey('holding-pane-$shown'), child: HoldingDetailPage(shown)),
    );
  }

  static DateTime? _latestPriceAt(List<Holding> holdings) {
    DateTime? latest;
    for (final h in holdings) {
      final at = h.priceAt;
      if (h.priceE4 == null || at == null) continue;
      if (latest == null || at.isAfter(latest)) latest = at;
    }
    return latest;
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.summary,
    required this.byCurrency,
    required this.refreshing,
    required this.holdings,
    required this.onRefresh,
    this.stocks = const {},
    this.priceAt,
    this.refreshError,
    this.refreshNote,
    this.lastRefresh,
  });

  final PortfolioSummary summary;

  /// 每个币种一份小结（金额不折算）；估值、收益、涨跌按币种分开显示。
  final Map<String, PortfolioSummary> byCurrency;

  /// 股票账户的小结（按币种）：整户市值算进估值，浮盈算进浮动收益。
  final Map<String, StockAccountSummary> stocks;
  final DateTime? priceAt;
  final bool refreshing;
  final Object? refreshError;
  final String? refreshNote;
  final QuoteRefresh? lastRefresh;
  final List<Holding> holdings;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final errorStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.error,
    );
    final failed = lastRefresh?.failed ?? const <QuoteFailure>[];
    CurrencyAmounts by(int Function(PortfolioSummary p) pick) =>
        CurrencyAmounts({for (final e in byCurrency.entries) e.key: pick(e.value)});
    CurrencyAmounts byStock(int Function(StockAccountSummary s) pick) =>
        CurrencyAmounts({for (final e in stocks.entries) e.key: pick(e.value)});
    // 股票账户按整户市值算进估值和浮动收益。收益率只在一种币时有意义（美元的收益除以人民币的成本不成话）。
    final market = by((p) => p.marketCents) + byStock((s) => s.marketCents);
    final gain = by((p) => p.gainCents) + byStock((s) => s.gainCents);
    double? rate;
    if ({...byCurrency.keys, ...stocks.keys}.length <= 1) {
      final cost = summary.costCents + stocks.values.fold<int>(0, (sum, s) => sum + s.valuedInvestedCents);
      final gained = summary.gainCents + stocks.values.fold<int>(0, (sum, s) => sum + s.gainCents);
      rate = cost > 0 ? gained / cost : null;
    }
    final unvaluedStocks = stocks.values.fold<int>(0, (sum, s) => sum + s.unvaluedCount);
    final hasUnits = holdings.any((h) => !h.archived && !h.isCleared && h.isUnit);
    final canRefresh = wantsAutoQuotes(holdings);
    return SegmentSummary(
      label: '理财估值',
      value: CurrencyTotal(market, size: MoneySize.title),
      trailing: canRefresh
          ? TextButton.icon(
              onPressed: refreshing ? null : onRefresh,
              icon: refreshing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh, size: 18),
              label: const Text('刷新行情'),
            )
          : null,
      lines: [
        // 收益、涨跌、价格时间挤在一两行小字里：这一段的主角是下面一笔笔理财。
        Wrap(
          spacing: LedgerLayout.itemGap,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('浮动收益 ', style: theme.textTheme.bodySmall),
                CurrencyTotal(gain, signed: true, size: MoneySize.small),
                if (rate != null) ...[
                  const SizedBox(width: 4),
                  RateText(rate, small: true),
                ],
              ],
            ),
            if (summary.realizedCents != 0)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('已实现 ', style: theme.textTheme.bodySmall),
                  CurrencyTotal(by((p) => p.realizedCents), signed: true, size: MoneySize.small),
                ],
              ),
            if (hasUnits)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('今日涨跌 ', style: theme.textTheme.bodySmall),
                  CurrencyTotal(by((p) => p.todayChangeCents), signed: true, size: MoneySize.small),
                ],
              ),
          ],
        ),
        if (hasUnits)
          Text(
            priceAt == null
                ? '基金股票还没有价格'
                : '价格更新于 ${Dates.dateTimeLabel(priceAt!)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
      ],
      children: [
        if (refreshError != null)
          Text('刷新失败：${describeError(refreshError!)}', style: errorStyle),
        if (refreshNote != null)
          Text(refreshNote!, style: theme.textTheme.bodySmall),
        if (failed.isNotEmpty)
          Text(_failedLine(failed), style: errorStyle),
        if (summary.unpricedCount > 0)
          Text(
            '${summary.unpricedCount} 只还没有价格，没算进估值'
            '${_waitingForQuotes ? '；行情刚刷过，几分钟后再点「刷新行情」' : ''}',
            style: theme.textTheme.bodySmall,
          ),
        if (unvaluedStocks > 0)
          Text(
            '$unvaluedStocks 个股票账户还没填市值，先按投入算',
            key: const ValueKey('invest-unvalued-stocks'),
            style: theme.textTheme.bodySmall,
          ),
      ],
    );
  }

  /// 刚加的自动行情持仓碰上服务端节流：那次回的是加它之前的结果，不说一声就像行情坏了。
  bool get _waitingForQuotes =>
      refreshNote == null &&
      (lastRefresh?.throttled ?? false) &&
      holdings.any(
        (h) => !h.archived && !h.isCleared && h.isAuto && h.priceE4 == null,
      );

  /// 「2 只没拿到行情：161725 超时；600000 行情里没有这个代码」
  String _failedLine(List<QuoteFailure> failed) {
    String nameOf(QuoteFailure f) {
      for (final h in holdings) {
        if (h.id == f.id) return h.label;
      }
      return f.code ?? '某只';
    }

    final parts = failed.take(2).map((f) => '${nameOf(f)} ${f.message}');
    final more = failed.length > 2 ? ' 等' : '';
    return '${failed.length} 只没拿到行情：${parts.join('；')}$more';
  }
}

/// 收益率：正数用收入色带 +，负数只带 −（同金额，不靠红绿）。
class RateText extends StatelessWidget {
  const RateText(this.rate, {super.key, this.small = false});

  final double? rate;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = rate;
    final base = small ? theme.textTheme.bodySmall : theme.textTheme.bodyMedium;
    return Text(
      value == null ? '—' : formatRate(value),
      maxLines: 1,
      style: base?.copyWith(
        color: value != null && value > 0 && formatRate(value) != '0.00%'
            ? LedgerColors.of(context).income
            : theme.colorScheme.onSurfaceVariant,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// 品类的图标。
IconData holdingIcon(String kind) => switch (kind) {
  Holding.kindFund => Icons.pie_chart_outline,
  Holding.kindStock => Icons.show_chart,
  Holding.kindDemand => Icons.account_balance_wallet_outlined,
  Holding.kindFixed => Icons.lock_clock_outlined,
  Holding.kindStructured => Icons.stacked_line_chart,
  Holding.kindWealth => Icons.account_balance_outlined,
  Holding.kindBond => Icons.receipt_long_outlined,
  Holding.kindRepo => Icons.swap_horiz,
  Holding.kindInsurance => Icons.health_and_safety_outlined,
  Holding.kindGold => Icons.diamond_outlined,
  _ => Icons.savings_outlined,
};

/// `2026-10-01` → `10月1日`：列表行里不要「周三」这种尾巴。
String _md(String day) {
  final d = parseDay(day);
  return d == null ? day : '${d.month}月${d.day}日';
}

/// 要提醒的状态标签（黄底）。
const Set<String> warningTags = {'行情过期', '没有价格', '已到期', '该更新了'};

/// 价格要紧的两种情况要标出来：手填的、好久没更新的。
String? priceTag(Holding h, HoldingMetrics m) {
  if (!m.hasPrice) return '没有价格';
  if (m.manual) return '手动价';
  if (m.stale) return '行情过期';
  return null;
}

/// 列表行、详情页名字后面的小标：份额类说价格，定期类说到期，金额类说该更新了。
String? investTag(Holding h, HoldingMetrics m) => switch (h.mode) {
  InvestMode.unit => priceTag(h, m),
  InvestMode.deposit => m.matured ? '已到期' : null,
  InvestMode.balance => m.stale ? '该更新了' : null,
};

/// 「还有 120 天」「今天到期」「已到期 3 天」；不是定期类是 null。
String? maturityLabel(HoldingMetrics m) {
  final d = m.daysToMaturity;
  if (d == null) return null;
  if (d > 0) return '还有\u00A0$d\u00A0天到期';
  if (d == 0) return '今天到期';
  return '已到期\u00A0${-d}\u00A0天';
}

/// 一个股票账户：整户市值、投入、浮盈。没填过市值的按投入算并提醒；超过 31 天没更新标「该更新了」。
class StockAccountTile extends StatelessWidget {
  const StockAccountTile({super.key, required this.account, required this.metrics, this.onTap, this.selected = false});

  final Account account;
  final StockAccountMetrics metrics;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final a = account;
    final m = metrics;
    final gain = m.gainCents;
    final sub = holdingSubtitle([
      '投入 ${Money.format(m.investedCents, currency: a.currency)}',
      if (m.unvalued) ...['按投入算', '填一下市值'] else if (a.valueOn != null) '${_md(a.valueOn!)} 更新',
    ]);
    return ListTile(
      key: ValueKey('stock-account-${a.id}'),
      selected: selected,
      onTap: onTap ?? () => context.push('/assets/accounts/${a.id}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding, vertical: 4),
      leading: const AssetAvatar(Icons.show_chart),
      title: Row(
        children: [
          Flexible(child: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyLarge)),
          if (m.stale) ...[const SizedBox(width: 6), const TagLabel('该更新了', tone: TagTone.warning)],
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
      ),
      trailing: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          MultiCurrencyAmount(m.marketCents, currency: a.currency),
          if (gain != null) ...[
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                MultiCurrencyAmount(gain, currency: a.currency, signed: true, size: MoneySize.small),
                const SizedBox(width: 4),
                RateText(m.gainRate, small: true),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 还有逐只记的股票时的提示：可以并进股票账户。
class _MergeHint extends StatelessWidget {
  const _MergeHint({required this.onMerge});

  final VoidCallback onMerge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('stock-merge-hint'),
      margin: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, LedgerLayout.itemGap, LedgerLayout.pagePadding, 0),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(color: LedgerColors.of(context).surface2, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('股票可以按账户汇总记了', style: theme.textTheme.titleSmall),
                Text('市值记在股票账户上，不用一只一只记；并进去的持仓归档', style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          TextButton(key: const ValueKey('stock-merge-hint-action'), onPressed: onMerge, child: const Text('合并')),
        ],
      ),
    );
  }
}

/// 一段文字整段不折：空格换成不换行空格，字与字之间塞零宽的 U+2060。
/// 中文任意两个字之间都能折行，光换空格挡不住「日均」折成「日」「均」、「+¥」折成两行。
String keepTogether(String s) =>
    s.replaceAll(' ', '\u00A0').runes.map(String.fromCharCode).join('\u2060');

/// 理财行的副标题：每段整段不折，段与段之间用「 · 」，窄屏放不下只在这里折。
String holdingSubtitle(Iterable<String> parts) => parts.map(keepTogether).join(' · ');

/// 一笔理财：估值、收益与收益率；副标题按记法说持有天数、利率与到期、金额什么时候更新的。
class HoldingTile extends StatelessWidget {
  const HoldingTile({super.key, required this.holding, required this.now, this.onTap, this.selected = false});

  final Holding holding;
  final DateTime now;

  /// 不给就整页打开详情；宽屏的理财段给「选中它」。
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final h = holding;
    final m = holdingMetrics(h, now);
    final code = h.code != null && h.code != h.label ? h.code : null;
    final daily = m.dailyGainCents;
    final inst = h.institution != null && h.institution!.isNotEmpty ? h.institution : null;
    // 每段整段不折（keepTogether）：放不下折成两行时只在「·」处折。
    // 不按品类分组了：品类写在行里第一段。每段整段不折（keepTogether）：放不下折成两行时只在「·」处折。
    final sub = holdingSubtitle(
      m.cleared
          ? [h.kindLabel, if (code != null) code, if (inst != null) inst, h.mode == InvestMode.unit ? '已清仓' : '已结清']
          : switch (h.mode) {
              InvestMode.unit => [
                h.kindLabel,
                if (code != null) code,
                '持有 ${m.days} 天',
                if (daily != null) '日均 ${Money.format(daily.round(), signed: true, currency: h.currency)}',
              ],
              InvestMode.deposit => [
                h.kindLabel,
                if (inst != null) inst,
                if (h.rateE6 != null)
                  h.rateMaxE6 != null
                      ? '${formatRateE6(h.rateE6!)}~${formatRateE6(h.rateMaxE6!)}'
                      : formatRateE6(h.rateE6!),
                if (maturityLabel(m) case final due?) due,
              ],
              InvestMode.balance => [
                h.kindLabel,
                if (inst != null) inst,
                if (h.rateE6 != null) '年化 ${formatRateE6(h.rateE6!)}',
                h.valueOn == null ? '按本金' : '${_md(h.valueOn!)} 更新',
              ],
            },
    );
    final tag = m.cleared ? null : investTag(h, m);

    return ListTile(
      key: ValueKey('holding-${h.id}'),
      selected: selected,
      onTap: onTap ?? () => context.push('/assets/holdings/${h.id}'),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: LedgerLayout.pagePadding,
        vertical: 4,
      ),
      leading: AssetAvatar(holdingIcon(h.kind), muted: m.cleared),
      // 「手动价 / 行情过期」挂在名字后面：副标题只有一行，塞标签进去会把「持有 N 天 · 日均」截掉。
      title: Row(
        children: [
          Flexible(
            child: Text(
              h.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyLarge,
            ),
          ),
          if (tag != null) ...[
            const SizedBox(width: 6),
            TagLabel(
              tag,
              tone: warningTags.contains(tag) ? TagTone.warning : TagTone.neutral,
            ),
          ],
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        // 手机上「代码 · 持有 N 天 · 日均 +¥…」偶尔一行放不下，折成两行也比截成「日均 +¥2,…」强。
        child: Text(
          sub,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall,
        ),
      ),
      trailing: m.cleared
          ? Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('已实现', style: theme.textTheme.bodySmall),
                MultiCurrencyAmount(h.realizedCents, currency: h.currency, signed: true),
              ],
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (m.marketCents != null)
                  MultiCurrencyAmount(m.marketCents!, currency: h.currency)
                else
                  Text('—', style: theme.textTheme.bodyLarge),
                if (m.gainCents != null) ...[
                  const SizedBox(height: 2),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      MultiCurrencyAmount(m.gainCents!, currency: h.currency, signed: true, size: MoneySize.small),
                      const SizedBox(width: 4),
                      RateText(m.gainRate, small: true),
                    ],
                  ),
                ],
              ],
            ),
    );
  }
}
