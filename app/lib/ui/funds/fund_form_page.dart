import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/colors.dart';
import '../../core/dates.dart';
import '../../core/money.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../add_tx/account_picker.dart';
import '../add_tx/picker_field.dart';
import '../assets/asset_providers.dart';
import '../analysis/month_picker.dart';
import '../widgets/widgets.dart';
import 'fund_providers.dart';
import 'fund_template_sheet.dart';

/// 新建 / 编辑基金。新建时可以先挑个模板（名字、图标、颜色、说明都带好）。
class FundFormPage extends ConsumerStatefulWidget {
  const FundFormPage({super.key, this.id});

  /// 为 null 表示新建。
  final String? id;

  @override
  ConsumerState<FundFormPage> createState() => _FundFormPageState();
}

class _FundFormPageState extends ConsumerState<FundFormPage> {
  /// 基金常用的图标，够用就行，不做全量图标库。
  static const List<String> _icons = [
    'wallet',
    'home',
    'elderly',
    'child_care',
    'pets',
    'shield',
    'flight',
    'luggage',
    'account_balance',
    'savings',
    'emoji_events',
    'school',
    'medical_services',
    'payments',
  ];

  final TextEditingController _name = TextEditingController();
  final TextEditingController _target = TextEditingController();
  final TextEditingController _budget = TextEditingController();
  final TextEditingController _monthlyIncome = TextEditingController();
  final TextEditingController _description = TextEditingController();

  String _kind = 'custom';
  String? _icon;
  String? _color;
  String _incomeStartMonth = Dates.currentMonth();

  /// 每月固定进账：开着就每月 [_incomeDay] 号往 [_incomeAccountId] 记一笔真的收入（服务端生成）。
  bool _incomeOn = false;
  int _incomeDay = 10;
  String? _incomeAccountId;
  String? _incomeCategoryId;
  bool _isDefault = false;
  bool _archived = false;
  bool _bound = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.id == null) {
      // 模板弹层挑的那个（用完就扔，免得下次新建又被套上）。
      final template = ref.read(pendingFundTemplateProvider);
      if (template != null) {
        _applyTemplate(template);
        Future.microtask(
          () => ref.read(pendingFundTemplateProvider.notifier).state = null,
        );
      }
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _target.dispose();
    _budget.dispose();
    _monthlyIncome.dispose();
    _description.dispose();
    super.dispose();
  }

  void _applyTemplate(Fund template) {
    _name.text = template.name;
    _description.text = template.description ?? '';
    _kind = template.kind;
    _icon = template.icon;
    _color = template.color;
  }

  /// 编辑时把已有基金灌进表单（只灌一次）。
  void _bind(Fund fund) {
    if (_bound) return;
    _bound = true;
    _name.text = fund.name;
    _description.text = fund.description ?? '';
    _target.text = fund.targetCents == null
        ? ''
        : Money.plain(fund.targetCents!);
    _budget.text = fund.monthlyBudgetCents == null
        ? ''
        : Money.plain(fund.monthlyBudgetCents!);
    _monthlyIncome.text = fund.monthlyIncomeCents == null
        ? ''
        : Money.plain(fund.monthlyIncomeCents!);
    _incomeStartMonth = fund.incomeStartMonth ?? Dates.currentMonth();
    _incomeOn = fund.hasMonthlyIncome;
    _incomeDay = fund.incomeDay ?? 10;
    _incomeAccountId = fund.incomeAccountId;
    _incomeCategoryId = fund.incomeCategoryId;
    _kind = fund.kind;
    _icon = fund.icon;
    _color = fund.color;
    _isDefault = fund.isDefault;
    _archived = fund.archived;
  }

  Future<void> _pickTemplate() async {
    final template = await showFundTemplateSheet(context);
    if (template == null || template.name.isEmpty) return;
    setState(() => _applyTemplate(template));
  }

  int? _money(TextEditingController controller) {
    final text = controller.text.trim();
    if (text.isEmpty) return null;
    return Money.tryParse(text);
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '给这个板块起个名字');
      return;
    }
    for (final entry in {'目标金额': _target, '月预算': _budget, '每月进账': _monthlyIncome}.entries) {
      if (entry.value.text.trim().isNotEmpty && _money(entry.value) == null) {
        setState(() => _error = '${entry.key}填得不对，例如 10000');
        return;
      }
    }
    final income = _money(_monthlyIncome);
    if (_incomeOn) {
      if (income == null || income <= 0) {
        setState(() => _error = '每月进多少？例如 15000');
        return;
      }
      if (_incomeAccountId == null) {
        setState(() => _error = '选一下工资进哪个账户');
        return;
      }
    }

    final body = <String, dynamic>{
      'name': name,
      'kind': _kind,
      'icon': _icon,
      'color': _color,
      'targetCents': _money(_target),
      'monthlyBudgetCents': _money(_budget),
      // 关掉 = 不再生成（已经记的照常在）；开着就整条规则一起发。
      'monthlyIncomeCents': _incomeOn ? income : null,
      if (_incomeOn) ...{
        'incomeDay': _incomeDay,
        'incomeAccountId': _incomeAccountId,
        'incomeCategoryId': _incomeCategoryId,
        'incomeStartMonth': _incomeStartMonth,
      },
      'description': _description.text.trim(),
      'isDefault': _isDefault,
      'archived': _archived,
    };

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = ref.read(ledgerRepoProvider);
      if (widget.id == null) {
        await repo.createFund(body);
      } else {
        await repo.updateFund(widget.id!, body);
      }
      ref.invalidate(ledgerProvider);
      // 开着每月进账时服务端当场补记了该记的月份：账单、首页、净资产都要重取。
      refreshMoneyViews(ref);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.id == null ? '板块已建好' : '已保存')),
      );
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/funds');
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = describeError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ledger = ref.watch(ledgerProvider).valueOrNull;
    final editing = widget.id != null;
    final fund = editing ? ledger?.fund(widget.id) : null;
    if (fund != null) _bind(fund);

    if (editing && ledger == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('编辑板块')),
        body: const SkeletonList(rows: 5),
      );
    }
    if (editing && fund == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('编辑板块')),
        body: const InlineError(message: '这个板块已经不在了。'),
      );
    }

    final palette = LedgerColors.of(context).fundPalette;
    return Scaffold(
      appBar: AppBar(
        title: Text(editing ? '编辑板块' : '新建板块'),
        actions: [
          if (!editing)
            TextButton(onPressed: _pickTemplate, child: const Text('用模板')),
        ],
      ),
      // 宽屏两列：左边名字、类型、颜色、图标，右边目标、预算、说明和开关。
      body: FormColumns(
        main: [
          PickerField(
            label: '名字',
            topGap: LedgerLayout.pagePadding,
            child: TextField(
              controller: _name,
              decoration: const InputDecoration(hintText: '例如「家庭公共」'),
            ),
          ),
          PickerField(
            label: '类型',
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final entry in Fund.kindLabels.entries)
                  ChoiceChip(
                    selected: _kind == entry.key,
                    onSelected: (_) => setState(() => _kind = entry.key),
                    label: Text(entry.value),
                  ),
              ],
            ),
          ),
          PickerField(
            label: '颜色',
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final color in palette)
                  _Swatch(
                    color: color,
                    selected: hexColor(_color) == color,
                    onTap: () => setState(() => _color = colorHex(color)),
                  ),
              ],
            ),
          ),
          PickerField(
            label: '图标',
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final name in _icons)
                  _IconChoice(
                    name: name,
                    selected: _icon == name,
                    color: hexColor(_color) ?? theme.colorScheme.primary,
                    onTap: () => setState(() => _icon = name),
                  ),
              ],
            ),
          ),
        ],
        side: [
          PickerField(
            label: '目标金额（选填）',
            trailing: Text('攒够就算达成', style: theme.textTheme.bodySmall),
            child: TextField(
              controller: _target,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(prefixText: '¥ ', hintText: '例如 50000'),
            ),
          ),
          PickerField(
            label: '月预算（选填）',
            trailing: Text('超了会在首页提醒', style: theme.textTheme.bodySmall),
            child: TextField(
              controller: _budget,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(prefixText: '¥ ', hintText: '例如 3000'),
            ),
          ),
          const SizedBox(height: LedgerLayout.itemGap),
          SwitchListTile(
            key: const ValueKey('fund-income-switch'),
            value: _incomeOn,
            onChanged: (v) => setState(() => _incomeOn = v),
            title: const Text('每月固定进账'),
            subtitle: const Text('比如工资：每月到账那天自动记一笔收入'),
          ),
          if (_incomeOn) ..._incomeFields(theme, ledger),
          PickerField(
            label: '说明（选填）',
            child: TextField(
              controller: _description,
              maxLines: 2,
              decoration: const InputDecoration(hintText: '这个板块管哪些钱'),
            ),
          ),
          const SizedBox(height: LedgerLayout.itemGap),
          SwitchListTile(
            value: _isDefault,
            onChanged: (v) => setState(() => _isDefault = v),
            title: const Text('设为默认板块'),
            subtitle: const Text('自动记账认不出归属时就放这里'),
          ),
          if (editing)
            SwitchListTile(
              value: _archived,
              onChanged: (v) => setState(() => _archived = v),
              title: const Text('归档'),
              subtitle: const Text('不再出现在选择列表里，历史流水还在'),
            ),
        ],
        bottom: [
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
          Padding(
            padding: const EdgeInsets.fromLTRB(
              LedgerLayout.pagePadding,
              LedgerLayout.groupGap,
              LedgerLayout.pagePadding,
              0,
            ),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _busy ? null : _save,
                child: Text(editing ? '保存' : '建好了'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 每月固定进账的几栏：多少、几号、进哪个账户、记成什么、从哪个月起，外加一句提醒别再手记。
  List<Widget> _incomeFields(ThemeData theme, LedgerData? ledger) {
    final accounts = ledger?.activeAccounts ?? const <Account>[];
    final account = ledger?.account(_incomeAccountId);
    final symbol = Money.symbolFor(account?.currency ?? ref.read(baseCurrencyProvider)).trim();
    final categories = ledger?.incomeCategories() ?? const <TxCategory>[];
    return [
      PickerField(
        label: '每月进多少',
        topGap: LedgerLayout.itemGap,
        child: TextField(
          key: const ValueKey('fund-income-amount'),
          controller: _monthlyIncome,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(prefixText: '$symbol ', hintText: '例如 15000'),
        ),
      ),
      PickerField(
        label: '每月几号到账',
        child: DropdownButtonFormField<int>(
          key: const ValueKey('fund-income-day'),
          value: _incomeDay,
          items: [for (var d = 1; d <= 28; d++) DropdownMenuItem(value: d, child: Text('每月 $d 号'))],
          onChanged: (d) => setState(() => _incomeDay = d ?? 10),
        ),
      ),
      PickerField(
        label: '进哪个账户',
        trailing: Text('金额按这个账户的币种', style: theme.textTheme.bodySmall),
        child: AccountPicker(
          keyPrefix: 'fund-income-account',
          accounts: accounts,
          selectedId: _incomeAccountId,
          onSelected: (id) => setState(() => _incomeAccountId = id),
        ),
      ),
      PickerField(
        label: '记成什么',
        child: DropdownButtonFormField<String?>(
          key: const ValueKey('fund-income-category'),
          value: categories.any((c) => c.id == _incomeCategoryId) ? _incomeCategoryId : null,
          isExpanded: true,
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('工资（没有就自动建一个）')),
            for (final c in categories) DropdownMenuItem<String?>(value: c.id, child: Text(c.name)),
          ],
          onChanged: (v) => setState(() => _incomeCategoryId = v),
        ),
      ),
      PickerField(
        label: '从哪个月起',
        trailing: Text('选以前的月份会补记，最多 24 个月', style: theme.textTheme.bodySmall),
        child: MonthPicker(
          month: _incomeStartMonth,
          onChanged: (m) => setState(() => _incomeStartMonth = m),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 8, LedgerLayout.pagePadding, 0),
        child: Text(
          '记的是真流水：账户余额、这个板块、本月收入都会涨，账单里能改能删。'
          '开了就别再手记这份工资，不然会记重；改金额只影响以后的月份。',
          key: const ValueKey('fund-income-note'),
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    ];
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    customBorder: const CircleBorder(),
    // 触控目标 48dp，看得见的色块 28dp。
    child: SizedBox(
      width: 48,
      height: 48,
      child: Center(
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: selected
                ? Border.all(color: Theme.of(context).colorScheme.onSurface, width: 3)
                : null,
          ),
        ),
      ),
    ),
  );
}

class _IconChoice extends StatelessWidget {
  const _IconChoice({
    required this.name,
    required this.selected,
    required this.color,
    required this.onTap,
  });

  final String name;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(LedgerShapes.chip),
      child: Container(
        width: 48,
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? color.withValues(alpha: 0.18)
              : LedgerColors.of(context).surface2,
          borderRadius: BorderRadius.circular(LedgerShapes.chip),
          border: Border.all(
            color: selected ? color : theme.colorScheme.outlineVariant,
          ),
        ),
        child: CategoryIcon(name, color: selected ? color : null),
      ),
    );
  }
}
