import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/shell.dart';
import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../assets/asset_providers.dart';
import '../assets/asset_widgets.dart';
import '../home/fund_carousel.dart';
import '../widgets/widgets.dart';
import 'fund_progress.dart';
import 'fund_detail_page.dart';
import 'fund_providers.dart';
import 'fund_template_sheet.dart';

/// 基金（钱袋子）的列表：每个模块还剩多少、这个月花了多少、离目标还有多远。
///
/// 只是内容，顶栏归「我的 › 财富」那一页（funds_page.dart，它的「新建板块」调 [startNewFund]）。
/// 首页的板块卡片是它的缩略。
class FundsTab extends ConsumerStatefulWidget {
  const FundsTab({super.key});

  @override
  ConsumerState<FundsTab> createState() => _FundsTabState();
}

/// 新建基金：模板弹层 → 表单（模板经 [pendingFundTemplateProvider] 传给表单页）。
Future<void> startNewFund(BuildContext context, WidgetRef ref) async {
  final template = await showFundTemplateSheet(context);
  if (template == null || !context.mounted) return;
  ref.read(pendingFundTemplateProvider.notifier).state = template;
  await context.push('/funds/new');
}

class _FundsTabState extends ConsumerState<FundsTab> {
  /// 下拉同步失败的原因（同首页：ledger 的错误态页面写不进去，自己记着）。
  Object? _syncError;

  /// 下拉刷新：同步主数据 + 重取本月统计。失败要看得见，不能只让圈圈转完。
  Future<void> _refresh(String month) async {
    Object? error;
    try {
      await ref.read(ledgerProvider.notifier).sync();
    } catch (e) {
      error = e;
    }
    await ref.read(statsProvider(month).notifier).refresh();
    if (!mounted) return;
    setState(() => _syncError = error);
  }

  /// 同步失败的横幅。空态和有内容时都要出现 —— 一个基金都没有的时候，
  /// 「是真没有，还是没同步上来」恰恰是最需要说清楚的。
  Widget _syncBanner(String month) => _syncError == null
      ? const SizedBox.shrink()
      : InlineError(
          message: '同步失败：${describeError(_syncError!)}',
          onRetry: () => _refresh(month),
          padding: const EdgeInsets.fromLTRB(
            LedgerLayout.pagePadding,
            LedgerLayout.itemGap,
            LedgerLayout.pagePadding,
            0,
          ),
        );

  @override
  Widget build(BuildContext context) {
    final month = Dates.currentMonth();
    final ledger = ref.watch(ledgerProvider);
    final stats = ref.watch(statsProvider(month));
    final width = widthClassOf(context);
    final grid = width != WidthClass.compact;
    // ≥ 840：左边卡片、右边嵌着选中那个基金的详情页（fund_detail_page），右半屏不再空着。
    final twoPane = width == WidthClass.expanded;
    final funds = ledger.valueOrNull?.activeFunds ?? const <Fund>[];
    final all = ledger.valueOrNull?.funds ?? const <Fund>[];
    final selected = ref.watch(selectedFundProvider);
    // 已归档的也能点开看（右栏照常嵌详情，那里能恢复）。
    final shown = twoPane
        ? (all.any((f) => f.id == selected) ? selected : funds.firstOrNull?.id)
        : null;
    if (twoPane && shown != selected) pinSelection(ref, selectedFundProvider, shown);

    final list = LayoutBuilder(
      builder: (context, box) => _body(month, ledger, stats, grid, twoPane ? EdgeInsets.zero : readableInsets(box.maxWidth), (fund) {
        if (twoPane) {
          ref.read(selectedFundProvider.notifier).state = fund.id;
        } else {
          context.push('/funds/${fund.id}');
        }
      }),
    );
    if (!twoPane) return list;
    return AdaptiveTwoPane(
      main: list,
      sideWidth: LedgerLayout.detailPaneWidth,
      side: shown == null
          ? const EmptyState(title: '选一个板块看详情', compact: true)
          : DetailPane(key: ValueKey('fund-pane-$shown'), child: FundDetailPage(shown)),
    );
  }

  Widget _body(
    String month,
    AsyncValue<LedgerData> ledger,
    AsyncValue<StatsOverview> stats,
    bool wide,
    EdgeInsets side,
    ValueChanged<Fund> onOpen,
  ) {
    return RefreshIndicator(
      onRefresh: () => _refresh(month),
      child: AsyncValueView<LedgerData>(
        value: ledger,
        loading: const SkeletonList(rows: 6),
        onRetry: () => ref.invalidate(ledgerProvider),
        errorPadding: const EdgeInsets.all(LedgerLayout.pagePadding),
        data: (data) {
          final funds = data.activeFunds;
          final archived = data.funds.where((f) => f.archived).toList();
          final archivedSection = archived.isEmpty
              ? const SizedBox.shrink()
              : _ArchivedFunds(funds: archived, stats: stats.valueOrNull, onOpen: onOpen);
          if (funds.isEmpty) {
            return ListView(
              padding: side,
              children: [
                _syncBanner(month),
                const SizedBox(height: 40),
                EmptyState(
                  title: '还没有板块',
                  message: '先从模板建一个，钱才有地方归。',
                  icon: Icons.savings_outlined,
                  actionLabel: '从模板新建',
                  onAction: () => startNewFund(context, ref),
                ),
                archivedSection,
              ],
            );
          }
          final overview = stats.valueOrNull;
          return ListView(
            padding: side.copyWith(bottom: 96),
            children: [
              _syncBanner(month),
              _Total(funds: funds, stats: overview, loading: stats.isLoading),
              if (wide)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: LedgerLayout.pagePadding,
                  ),
                  child: GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 260,
                          mainAxisSpacing: LedgerLayout.itemGap,
                          crossAxisSpacing: LedgerLayout.itemGap,
                          mainAxisExtent: 132,
                        ),
                    itemCount: funds.length,
                    itemBuilder: (context, index) => FundCard(
                      fund: funds[index],
                      index: index,
                      width: double.infinity,
                      progress: fundProgressOf(funds[index], overview),
                      balances: overview?.fundBalances(funds[index].id) ?? const CurrencyAmounts(),
                      onTap: () => onOpen(funds[index]),
                    ),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: LedgerLayout.pagePadding,
                  ),
                  child: FundBalanceList(
                    funds: funds,
                    stats: overview,
                    onTap: onOpen,
                  ),
                ),
              archivedSection,
            ],
          );
        },
      ),
    );
  }
}

class _Total extends ConsumerWidget {
  const _Total({required this.funds, required this.loading, this.stats});

  final List<Fund> funds;
  final StatsOverview? stats;
  final bool loading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final overview = stats;
    final base = ref.watch(baseCurrencyProvider);
    var balance = const CurrencyAmounts();
    var expense = 0;
    for (final fund in funds) {
      // 各板块余额按币种分开相加（不折算）；月度支出服务端已折成基准币。
      if (overview != null) balance += overview.fundBalances(fund.id);
      expense += fundProgressOf(fund, overview).monthExpenseCents;
    }
    return SegmentSummary(
      label: '财富合计',
      value: overview == null && loading
          ? const Skeleton(width: 140, height: 22)
          : CurrencyTotal(balance, size: MoneySize.title),
      lines: [
        Text(
          '本月支出 ${formatAmounts(CurrencyAmounts.single(base, expense), base: base, convertTo: ref.watch(displayCurrencyOverrideProvider), fx: ref.watch(fxRatesProvider))} · ${funds.length} 个板块',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// 已归档的板块：收在列表底下，点开看详情（详情里能恢复），行尾也能直接恢复。余额照算，只是记账时不再出现。
class _ArchivedFunds extends ConsumerWidget {
  const _ArchivedFunds({required this.funds, required this.stats, required this.onOpen});

  final List<Fund> funds;
  final StatsOverview? stats;
  final ValueChanged<Fund> onOpen;

  Future<void> _restore(BuildContext context, WidgetRef ref, Fund fund) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(ledgerRepoProvider).updateFund(fund.id, {'archived': false});
      ref.invalidate(ledgerProvider);
      refreshMoneyViews(ref);
      messenger.showSnackBar(SnackBar(content: Text('「${fund.name}」恢复了')));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(describeError(error))));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: LedgerLayout.groupGap),
      child: ExpansionTile(
        key: const ValueKey('funds-archived'),
        tilePadding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
        title: Text('已归档（${funds.length}）', style: theme.textTheme.titleSmall),
        subtitle: Text('记账时不再出现，余额照算；点开能恢复', style: theme.textTheme.bodySmall),
        children: [
          for (final fund in funds)
            ListTile(
              key: ValueKey('archived-fund-${fund.id}'),
              contentPadding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
              title: Text(fund.name),
              subtitle: CurrencyTotal(stats?.fundBalances(fund.id) ?? const CurrencyAmounts(), muted: true),
              onTap: () => onOpen(fund),
              trailing: TextButton(
                key: ValueKey('restore-fund-${fund.id}'),
                onPressed: () => _restore(context, ref, fund),
                child: const Text('恢复'),
              ),
            ),
        ],
      ),
    );
  }
}
