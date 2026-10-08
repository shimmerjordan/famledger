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

/// 投资：总市值、收益、今日涨跌，下面一只一只列；清了仓的收在最后。
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

    return RefreshIndicator(
      onRefresh: _sync,
      child: LayoutBuilder(
        builder: (context, box) => AsyncValueView<LedgerData>(
          value: ledger,
          // 骨架也放进可滚的列表：上面有净资产总览，矮屏（分屏、平板横放）时放不下 5 行。
          loading: ListView(children: const [SkeletonList(rows: 5)]),
          onRetry: () => ref.invalidate(ledgerProvider),
          data: (data) {
            final holdings = data.activeHoldings;
            if (holdings.isEmpty) {
              return ListView(
                children: [
                  banner,
                  const SizedBox(height: 40),
                  EmptyState(
                    title: '还没有持仓',
                    message: '基金、股票记进来，市值和收益自动算。',
                    icon: Icons.show_chart,
                    actionLabel: '添加持仓',
                    onAction: () => context.push('/assets/holdings/new'),
                  ),
                ],
              );
            }
            final held = holdings.where((h) => !h.isCleared).toList();
            final cleared = holdings.where((h) => h.isCleared).toList();
            return ListView(
              padding: readableInsets(box.maxWidth).copyWith(bottom: 96),
              children: [
                banner,
                _Header(
                  summary: summarizeHoldings(holdings, now),
                  priceAt: _latestPriceAt(held),
                  refreshing: _refreshing,
                  refreshError: _refreshError,
                  refreshNote: _refreshNote,
                  lastRefresh: lastRefresh,
                  holdings: holdings,
                  onRefresh: _refreshQuotes,
                ),
                for (final h in held) HoldingTile(holding: h, now: now),
                if (cleared.isNotEmpty) ...[
                  const SizedBox(height: LedgerLayout.groupGap),
                  const SectionHeader('已清仓'),
                  for (final h in cleared) HoldingTile(holding: h, now: now),
                ],
              ],
            );
          },
        ),
      ),
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
    required this.refreshing,
    required this.holdings,
    required this.onRefresh,
    this.priceAt,
    this.refreshError,
    this.refreshNote,
    this.lastRefresh,
  });

  final PortfolioSummary summary;
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
    final rate = summary.gainRate;
    return SegmentSummary(
      label: '总市值',
      value: MoneyText(summary.marketCents, size: MoneySize.title),
      trailing: TextButton.icon(
        onPressed: refreshing ? null : onRefresh,
        icon: refreshing
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.refresh, size: 18),
        label: const Text('刷新行情'),
      ),
      lines: [
        // 收益、涨跌、价格时间挤在一两行小字里：这一段的主角是下面一只只持仓。
        Wrap(
          spacing: LedgerLayout.itemGap,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('总收益 ', style: theme.textTheme.bodySmall),
                MoneyText(summary.gainCents, signed: true, size: MoneySize.small),
                const SizedBox(width: 4),
                RateText(rate, small: true),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('今日涨跌 ', style: theme.textTheme.bodySmall),
                MoneyText(summary.todayChangeCents, signed: true, size: MoneySize.small),
              ],
            ),
          ],
        ),
        Text(
          priceAt == null
              ? '还没有价格'
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
            '${summary.unpricedCount} 只还没有价格，没算进市值'
            '${_waitingForQuotes ? '；行情刚刷过，几分钟后再点「刷新行情」' : ''}',
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

IconData holdingIcon(String market) => switch (market) {
  'fund' => Icons.pie_chart_outline,
  'other' => Icons.savings_outlined,
  _ => Icons.show_chart,
};

/// 价格要紧的两种情况要标出来：手填的、好久没更新的。
String? priceTag(Holding h, HoldingMetrics m) {
  if (!m.hasPrice) return '没有价格';
  if (m.manual) return '手动价';
  if (m.stale) return '行情过期';
  return null;
}

/// 一只持仓：市值、收益与收益率、持有天数、日均收益。
class HoldingTile extends StatelessWidget {
  const HoldingTile({super.key, required this.holding, required this.now});

  final Holding holding;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final h = holding;
    final m = holdingMetrics(h, now);
    final code = h.code != null && h.code != h.label ? h.code : null;
    final daily = m.dailyGainCents;
    final sub = m.cleared
        ? [if (code != null) code, '已清仓'].join(' · ')
        // 不换行空格：副标题放不下折成两行时在「·」处折，别把「日均 +¥2,681.25」折成两截。
        : [
            if (code != null) code,
            '持有\u00A0${m.days}\u00A0天',
            if (daily != null) '日均\u00A0${Money.format(daily.round(), signed: true)}',
          ].join(' · ');
    final tag = m.cleared ? null : priceTag(h, m);

    return ListTile(
      key: ValueKey('holding-${h.id}'),
      onTap: () => context.push('/assets/holdings/${h.id}'),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: LedgerLayout.pagePadding,
        vertical: 4,
      ),
      leading: AssetAvatar(holdingIcon(h.market), muted: m.cleared),
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
              tone: tag == '手动价' ? TagTone.neutral : TagTone.warning,
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
                MoneyText(h.realizedCents, signed: true),
              ],
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (m.marketCents != null)
                  MoneyText(m.marketCents!)
                else
                  Text('—', style: theme.textTheme.bodyLarge),
                if (m.gainCents != null) ...[
                  const SizedBox(height: 2),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      MoneyText(m.gainCents!, signed: true, size: MoneySize.small),
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
