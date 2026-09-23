import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/shell.dart';
import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../core/money.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../home/fund_carousel.dart';
import '../widgets/widgets.dart';
import 'fund_progress.dart';
import 'fund_providers.dart';
import 'fund_template_sheet.dart';

/// 基金：每个模块还剩多少、这个月花了多少、离目标还有多远。
class FundsPage extends ConsumerStatefulWidget {
  const FundsPage({super.key});

  @override
  ConsumerState<FundsPage> createState() => _FundsPageState();
}

class _FundsPageState extends ConsumerState<FundsPage> {
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
    final wide = widthClassOf(context) != WidthClass.compact;

    return Scaffold(
      appBar: AppBar(
        title: const Text('基金'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '新建基金',
            onPressed: () => _newFund(context, ref),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _refresh(month),
        child: AsyncValueView<LedgerData>(
          value: ledger,
          loading: const SkeletonList(rows: 6),
          onRetry: () => ref.invalidate(ledgerProvider),
          errorPadding: const EdgeInsets.all(LedgerLayout.pagePadding),
          data: (data) {
            final funds = data.activeFunds;
            if (funds.isEmpty) {
              return ListView(
                children: [
                  _syncBanner(month),
                  const SizedBox(height: 40),
                  EmptyState(
                    title: '还没有基金',
                    message: '先从模板建一个，钱才有地方归。',
                    icon: Icons.savings_outlined,
                    actionLabel: '从模板新建',
                    onAction: () => _newFund(context, ref),
                  ),
                ],
              );
            }
            final overview = stats.valueOrNull;
            return ListView(
              padding: const EdgeInsets.only(bottom: 96),
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
                        onTap: () =>
                            context.push('/funds/${funds[index].id}'),
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
                      onTap: (fund) => context.push('/funds/${fund.id}'),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// FAB → 模板弹层 → 表单（模板经 [pendingFundTemplateProvider] 传给表单页）。
  Future<void> _newFund(BuildContext context, WidgetRef ref) async {
    final template = await showFundTemplateSheet(context);
    if (template == null || !context.mounted) return;
    ref.read(pendingFundTemplateProvider.notifier).state = template;
    await context.push('/funds/new');
  }
}

class _Total extends StatelessWidget {
  const _Total({required this.funds, required this.loading, this.stats});

  final List<Fund> funds;
  final StatsOverview? stats;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final overview = stats;
    var balance = 0;
    var expense = 0;
    for (final fund in funds) {
      final progress = fundProgressOf(fund, overview);
      balance += progress.balanceCents;
      expense += progress.monthExpenseCents;
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LedgerLayout.pagePadding,
        8,
        LedgerLayout.pagePadding,
        LedgerLayout.groupGap,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('基金合计', style: theme.textTheme.bodySmall),
          const SizedBox(height: 2),
          if (overview == null && loading)
            const Skeleton(width: 180, height: 30)
          else
            MoneyText(balance, size: MoneySize.display),
          const SizedBox(height: 4),
          Text(
            '本月支出 ${Money.format(expense)} · ${funds.length} 个基金',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
