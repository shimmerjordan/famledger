import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/colors.dart';
import '../../core/dates.dart';
import '../../core/money.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../analysis/month_picker.dart';
import '../widgets/widgets.dart';
import 'manage_widgets.dart';

/// 预算：按月给基金和类别定上限，看这个月花到哪儿了。
class BudgetsPage extends ConsumerStatefulWidget {
  const BudgetsPage({super.key});

  @override
  ConsumerState<BudgetsPage> createState() => _BudgetsPageState();
}

class _BudgetsPageState extends ConsumerState<BudgetsPage> {
  String _month = Dates.currentMonth();

  @override
  Widget build(BuildContext context) {
    final ledger = ref.watch(ledgerProvider);
    final stats = ref.watch(statsProvider(_month));
    final overview = stats.valueOrNull;

    return Scaffold(
      appBar: AppBar(title: const Text('预算')),
      body: Column(
        children: [
          MonthPicker(
            month: _month,
            onChanged: (value) => setState(() => _month = value),
            subtitle: overview == null
                ? (stats.hasError
                      ? Text(
                          '本月支出取不到',
                          style: Theme.of(context).textTheme.bodySmall,
                        )
                      : const Skeleton(width: 120, height: 12))
                : Text(
                    '本月支出 ${Money.format(overview.month.expenseCents)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
          ),
          const Divider(height: 1),
          Expanded(
            child: AsyncValueView<LedgerData>(
              value: ledger,
              onRetry: () => ref.read(ledgerProvider.notifier).sync(),
              data: (data) => _body(data, overview, stats.hasError),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(LedgerData data, StatsOverview? overview, bool statsFailed) {
    final funds = data.activeFunds;
    final categoryRows = _categoryRows(data, overview);
    // 统计没回来又没报错 = 还在路上，画骨架；报错了就把花销写成「—」，
    // 绝不能拿 0 冒充「这个月一分没花」。
    final loading = overview == null && !statsFailed;

    if (funds.isEmpty && data.expenseCategories().isEmpty) {
      return const EmptyState(
        title: '还没有可以定预算的东西',
        message: '先建几个基金或支出类别，再回来给它们定上限。',
        icon: Icons.pie_chart_outline,
      );
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        if (statsFailed)
          InlineError(
            message: '这个月的花销没取到，下面只显示预算金额。',
            onRetry: () => ref.read(statsProvider(_month).notifier).refresh(),
          ),
        const SizedBox(height: LedgerLayout.itemGap),
        const SectionHeader('基金预算'),
        if (funds.isEmpty)
          const EmptyState(
            title: '还没有基金',
            message: '基金是「这笔钱归谁、干什么用」，建好了再定预算。',
            compact: true,
          )
        else
          for (final fund in funds)
            _BudgetRow(
              label: fund.name,
              color: fundColorOf(context, fund, data.fundIndex(fund.id)),
              icon: fund.icon,
              budgetCents: _budgetOf(
                data,
                overview,
                Budget.scopeFund,
                fund.id,
                fallback: fund.monthlyBudgetCents,
              ),
              spentCents: overview == null
                  ? null
                  : _spentOfFund(overview, fund.id),
              monthOnly:
                  _budgetRow(data, Budget.scopeFund, fund.id, _month) != null,
              loading: loading,
              onTap: () => _edit(
                data: data,
                scope: Budget.scopeFund,
                refId: fund.id,
                label: fund.name,
                current: _budgetOf(data, overview, Budget.scopeFund, fund.id),
              ),
            ),
        const SizedBox(height: LedgerLayout.groupGap),
        const SectionHeader('类别预算'),
        if (categoryRows.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              LedgerLayout.pagePadding,
              0,
              LedgerLayout.pagePadding,
              8,
            ),
            child: Text(
              '还没给单个类别定过上限。基金管「谁的钱」，类别管「哪类开销」，两者可以一起用。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          )
        else
          for (final category in categoryRows)
            _BudgetRow(
              label: category.name,
              color:
                  hexColor(category.color) ??
                  LedgerColors.of(context).fundColor(
                    data.categories.indexWhere((c) => c.id == category.id),
                  ),
              icon: category.icon,
              budgetCents: _budgetOf(
                data,
                overview,
                Budget.scopeCategory,
                category.id,
              ),
              spentCents: overview == null
                  ? null
                  : _spentOfCategory(overview, category.id),
              monthOnly:
                  _budgetRow(data, Budget.scopeCategory, category.id, _month) !=
                  null,
              loading: loading,
              onTap: () => _edit(
                data: data,
                scope: Budget.scopeCategory,
                refId: category.id,
                label: category.name,
                current: _budgetOf(
                  data,
                  overview,
                  Budget.scopeCategory,
                  category.id,
                ),
              ),
            ),
        ListTile(
          leading: const Icon(Icons.add),
          title: const Text('添加类别预算'),
          onTap: () => _pickCategory(data, overview),
        ),
      ],
    );
  }

  /// 有预算的类别才列出来，否则一屏都是「未设预算」。
  List<TxCategory> _categoryRows(LedgerData data, StatsOverview? overview) {
    final ids = <String>{
      for (final b in data.budgets)
        if (b.scope == Budget.scopeCategory &&
            (b.month == _month || b.month == Budget.everyMonth))
          b.refId,
      if (overview != null)
        for (final b in overview.month.budgets)
          if (b.scope == Budget.scopeCategory) b.refId,
    };
    return data.categories.where((c) => ids.contains(c.id)).toList();
  }

  /// 本地缓存里那一行预算的金额（没有这行就是 null）。
  int? _budgetRow(LedgerData data, String scope, String refId, String month) {
    for (final b in data.budgets) {
      if (b.scope == scope && b.refId == refId && b.month == month) {
        return b.amountCents;
      }
    }
    return null;
  }

  /// 生效的预算：服务端算好的优先，其次本地缓存（精确月 > 每月默认），再退到基金自带的月预算。
  int? _budgetOf(
    LedgerData data,
    StatsOverview? overview,
    String scope,
    String refId, {
    int? fallback,
  }) {
    if (overview != null) {
      for (final b in overview.month.budgets) {
        if (b.scope == scope && b.refId == refId && b.budgetCents > 0) {
          return b.budgetCents;
        }
      }
    }
    return _budgetRow(data, scope, refId, _month) ??
        _budgetRow(data, scope, refId, Budget.everyMonth) ??
        fallback;
  }

  int _spentOfFund(StatsOverview overview, String fundId) {
    for (final b in overview.month.budgets) {
      if (b.scope == Budget.scopeFund && b.refId == fundId) return b.spentCents;
    }
    for (final f in overview.month.byFund) {
      if (f.fundId == fundId) return f.expenseCents;
    }
    return 0;
  }

  int _spentOfCategory(StatsOverview overview, String categoryId) {
    for (final b in overview.month.budgets) {
      if (b.scope == Budget.scopeCategory && b.refId == categoryId) {
        return b.spentCents;
      }
    }
    for (final c in overview.month.byCategory) {
      if (c.categoryId == categoryId) return c.expenseCents;
    }
    return 0;
  }

  Future<void> _pickCategory(LedgerData data, StatsOverview? overview) async {
    final taken = _categoryRows(data, overview).map((c) => c.id).toSet();
    final options = data
        .expenseCategories()
        .where((c) => !taken.contains(c.id))
        .toList();
    if (options.isEmpty) {
      manageToast(context, '支出类别都已经有预算了');
      return;
    }
    final picked = await showManageSheet<TxCategory>(
      context,
      (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(
                LedgerLayout.pagePadding,
                0,
                LedgerLayout.pagePadding,
                8,
              ),
              child: Text('给哪个类别定预算？'),
            ),
            for (final category in options)
              ListTile(
                leading: CategoryIcon(category.icon),
                title: Text(category.name),
                onTap: () => Navigator.of(context).pop(category),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await _edit(
      data: data,
      scope: Budget.scopeCategory,
      refId: picked.id,
      label: picked.name,
      current: null,
    );
  }

  Future<void> _edit({
    required LedgerData data,
    required String scope,
    required String refId,
    required String label,
    required int? current,
  }) async {
    final saved = await showManageSheet<bool>(
      context,
      (context) => _BudgetSheet(
        scope: scope,
        refId: refId,
        label: label,
        month: _month,
        currentCents: current,
        monthRowCents: _budgetRow(data, scope, refId, _month),
        everyRowCents: _budgetRow(data, scope, refId, Budget.everyMonth),
      ),
    );
    if (saved == true) {
      await ref.read(statsProvider(_month).notifier).refresh();
    }
  }
}

/// 一条预算：名字 + 花了多少/上限 + 进度。没预算时只报本月已花。
class _BudgetRow extends StatelessWidget {
  const _BudgetRow({
    required this.label,
    required this.color,
    required this.icon,
    required this.budgetCents,
    required this.spentCents,
    required this.monthOnly,
    required this.loading,
    required this.onTap,
  });

  final String label;
  final Color color;
  final String? icon;
  final int? budgetCents;

  /// null = 这个月的花销没取到（不是 0）。
  final int? spentCents;

  /// 这个月单独设过（不是每月默认）。
  final bool monthOnly;
  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ledger = LedgerColors.of(context);
    final budget = budgetCents ?? 0;
    final spent = spentCents;
    final ratio = (budget <= 0 || spent == null) ? 0.0 : spent / budget;
    final over = budget > 0 && spent != null && spent > budget;
    final near = budget > 0 && spent != null && !over && ratio >= 0.85;
    final barColor = over
        ? theme.colorScheme.error
        : (near ? ledger.warning : theme.colorScheme.primary);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          LedgerLayout.pagePadding,
          12,
          LedgerLayout.pagePadding,
          12,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CategoryIcon(icon, color: color, size: 18),
                const SizedBox(width: 12),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(label, overflow: TextOverflow.ellipsis),
                      ),
                      if (monthOnly) ...[
                        const SizedBox(width: 8),
                        const ManageTag('仅本月'),
                      ],
                    ],
                  ),
                ),
                if (loading)
                  const Skeleton(width: 72, height: 16)
                else ...[
                  if (spent == null)
                    Text('—', style: theme.textTheme.bodyLarge)
                  else
                    MoneyText(spent),
                  if (budget > 0) ...[
                    Text(' / ', style: theme.textTheme.bodySmall),
                    MoneyText(budget, size: MoneySize.small, muted: true),
                  ],
                ],
              ],
            ),
            if (budget > 0 && spent != null) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: ratio.clamp(0.0, 1.0),
                  minHeight: 6,
                  backgroundColor: ledger.surface3,
                  color: barColor,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Text(
                    over
                        ? '超支 ${Money.format(spent - budget)}'
                        : '还剩 ${Money.format(budget - spent)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: over ? theme.colorScheme.error : null,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '已用 ${(ratio * 100).round()}%',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ] else if (budget <= 0 && !loading) ...[
              const SizedBox(height: 4),
              Text('未设预算 · 点一下定个上限', style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}

/// 改一条预算的金额与适用范围。
class _BudgetSheet extends ConsumerStatefulWidget {
  const _BudgetSheet({
    required this.scope,
    required this.refId,
    required this.label,
    required this.month,
    required this.currentCents,
    required this.monthRowCents,
    required this.everyRowCents,
  });

  final String scope;
  final String refId;
  final String label;
  final String month;

  /// 当前生效的金额（可能来自基金自带的月预算，不一定有对应的预算行）。
  final int? currentCents;

  /// 「仅本月」那一行的金额，null = 没这行。
  final int? monthRowCents;

  /// 「每月默认」那一行的金额，null = 没这行。
  final int? everyRowCents;

  @override
  ConsumerState<_BudgetSheet> createState() => _BudgetSheetState();
}

class _BudgetSheetState extends ConsumerState<_BudgetSheet> {
  late final TextEditingController _amount = TextEditingController(
    text: widget.currentCents == null ? '' : Money.plain(widget.currentCents!),
  );

  /// 开着的时候按「现在到底有没有本月那一行」来定，不是瞎猜。
  late bool _monthOnly = widget.monthRowCents != null;

  bool _busy = false;
  String? _error;

  /// 真正存在的那一行的月份：本月覆盖优先（它才是生效的那条）。
  String? get _existingMonth => widget.monthRowCents != null
      ? widget.month
      : (widget.everyRowCents != null ? Budget.everyMonth : null);

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final cents = Money.tryParse(_amount.text.trim());
    if (cents == null || cents <= 0) {
      setState(() => _error = '填一个大于 0 的金额，比如 1500。');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final navigator = Navigator.of(context);
    final repo = ref.read(ledgerRepoProvider);
    try {
      await repo.setBudget(
        scope: widget.scope,
        refId: widget.refId,
        month: _monthOnly ? widget.month : Budget.everyMonth,
        amountCents: cents,
      );
      // 从「仅本月」改回「每月默认」时，本月那一行还在的话会盖住新默认值 ——
      // 存完默认值顺手把覆盖删掉，不然用户会觉得没保存上。
      if (!_monthOnly && widget.monthRowCents != null) {
        await repo.setBudget(
          scope: widget.scope,
          refId: widget.refId,
          month: widget.month,
          amountCents: null,
        );
      }
      navigator.pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = describeError(e);
        });
      }
    }
  }

  Future<void> _remove() async {
    // 删的是「真实存在的那一行」，不是分段器当前选中的那个月。
    final month = _existingMonth;
    if (month == null) return;
    final fallsBackTo = month == widget.month ? widget.everyRowCents : null;
    final ok = await confirmDestructive(
      context,
      title: '取消「${widget.label}」的预算？',
      message: month == Budget.everyMonth
          ? '每月默认的上限会被去掉，之后不再提醒超支。'
          : (fallsBackTo == null
                ? '只去掉 ${Dates.monthLabel(widget.month)} 这一个月的上限。'
                : '去掉 ${Dates.monthLabel(widget.month)} 的单独上限，'
                      '这个月会回到每月默认的 ${Money.format(fallsBackTo)}。'),
      confirmLabel: '取消预算',
    );
    if (!ok || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final navigator = Navigator.of(context);
    try {
      await ref.read(ledgerRepoProvider).setBudget(
        scope: widget.scope,
        refId: widget.refId,
        month: month,
        amountCents: null,
      );
      navigator.pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = describeError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => ManageSheet(
    title: '${widget.label} 的预算',
    busy: _busy,
    error: _error,
    onSubmit: _save,
    secondaryLabel: _existingMonth == null ? null : '取消预算',
    onSecondary: _existingMonth == null ? null : _remove,
    children: [
      ManageField(
        label: '每月上限',
        child: TextField(
          controller: _amount,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            prefixText: '${Money.symbol} ',
            hintText: '1500.00',
          ),
        ),
      ),
      ManageField(
        label: '适用范围',
        child: SegmentedButton<bool>(
          segments: [
            const ButtonSegment(value: false, label: Text('每月默认')),
            ButtonSegment(
              value: true,
              label: Text('仅 ${Dates.monthLabel(widget.month)}'),
            ),
          ],
          selected: {_monthOnly},
          onSelectionChanged: (value) =>
              setState(() => _monthOnly = value.first),
        ),
      ),
      Text(
        _monthOnly
            ? '只影响 ${Dates.monthLabel(widget.month)}，其他月份还用每月默认。'
            : (widget.monthRowCents == null
                  ? '以后每个月都按这个上限，除非哪个月单独改过。'
                  : '以后每个月都按这个上限，'
                        '${Dates.monthLabel(widget.month)} 原来的单独上限会一起去掉。'),
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ],
  );
}
