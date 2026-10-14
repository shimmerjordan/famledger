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
import '../add_tx/category_grid.dart';
import '../add_tx/fund_picker.dart';
import '../add_tx/member_picker.dart';
import '../add_tx/picker_field.dart';
import '../widgets/widgets.dart';
import 'tx_providers.dart';
import 'tx_tile.dart';

/// 流水详情 = 编辑页。待确认的可以直接确认，疑似重复的可以说「不是重复」，
/// 删除要二次确认（服务端是软删，没有恢复接口，撤销不了就别假装能撤销）。
class TxDetailPage extends ConsumerStatefulWidget {
  const TxDetailPage(this.id, {super.key});

  final String id;

  @override
  ConsumerState<TxDetailPage> createState() => _TxDetailPageState();
}

class _TxDetailPageState extends ConsumerState<TxDetailPage> {
  final TextEditingController _amount = TextEditingController();
  final TextEditingController _merchant = TextEditingController();
  final TextEditingController _note = TextEditingController();

  /// 跨币种转账的到账金额（转入那一侧的币）。
  final TextEditingController _toAmount = TextEditingController();

  /// 没挂账户的流水（只走板块）自己选的币种；挂了账户的跟着账户走。
  String? _currency;

  /// 已经把哪条流水灌进输入框了（避免每次 build 都覆盖用户正在改的字）。
  String? _bound;

  String? _type;
  DateTime? _occurredAt;

  /// 用户亲手改过的那些字段。key 在 map 里 = 改过（值可以是 null，
  /// 表示「这一侧就是不填」——转账从「账户+基金两对」改成只留一对时要用到）。
  final Map<String, String?> _picked = {};

  static const String _kFund = 'fund';
  static const String _kToFund = 'toFund';
  static const String _kAccount = 'account';
  static const String _kToAccount = 'toAccount';
  static const String _kCategory = 'category';
  static const String _kMember = 'member';

  /// 改过就用改过的，没改过就用这条流水原来的值。
  String? _value(String key, String? original) =>
      _picked.containsKey(key) ? _picked[key] : original;

  void _pick(String key, String? value) => setState(() {
    _picked[key] = value;
    _error = null;
  });

  String? _error;
  bool _busy = false;

  /// 正展开着改的那一段（一次只展开一段）；null = 全收着，页面就是一份摘要。
  String? _open;

  void _toggle(String key) => setState(() => _open = _open == key ? null : key);

  @override
  void dispose() {
    _amount.dispose();
    _merchant.dispose();
    _note.dispose();
    _toAmount.dispose();
    super.dispose();
  }

  void _bind(Transaction tx) {
    if (_bound == tx.id) return;
    _bound = tx.id;
    _amount.text = Money.plain(tx.amountCents);
    _merchant.text = tx.merchant ?? '';
    _note.text = tx.note ?? '';
    _toAmount.text = tx.toAmountCents == null ? '' : Money.input(tx.toAmountCents!);
  }

  /// 这笔现在是什么币：挂了账户跟账户，没挂就是自己选的（默认原来的）。
  String _currencyOf(Transaction tx, LedgerData? ledger, String? accountId) =>
      (accountId == null ? null : ledger?.account(accountId)?.currency) ?? _currency ?? tx.currency;

  /// 转入那一侧的币：转入账户的币；没有转入账户就和转出同币。
  String _toCurrencyOf(Transaction tx, LedgerData? ledger, String? accountId, String? toAccountId) =>
      (toAccountId == null ? null : ledger?.account(toAccountId)?.currency) ?? _currencyOf(tx, ledger, accountId);

  /// 选择器里的候选：在用的那些，加上这笔原来选的（归档了、或是债务的内部账户）——不然改走了就选不回来。
  List<Fund> _fundsWith(LedgerData ledger, Iterable<String?> keep) => [
    ...ledger.activeFunds,
    for (final id in keep.toSet())
      if (id != null && !ledger.activeFunds.any((f) => f.id == id)) ?ledger.fund(id),
  ];

  List<Account> _accountsWith(LedgerData ledger, Iterable<String?> keep) => [
    ...ledger.activeAccounts,
    for (final id in keep.toSet())
      if (id != null && !ledger.activeAccounts.any((a) => a.id == id)) ?ledger.account(id),
  ];

  String _typeOf(Transaction tx) => _type ?? tx.type;
  DateTime _timeOf(Transaction tx) => _occurredAt ?? tx.occurredAt;

  Future<void> _pickDate(Transaction tx) async {
    final current = _timeOf(tx);
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2000),
      lastDate: DateTime(current.year + 5),
    );
    if (picked == null) return;
    setState(
      () => _occurredAt = DateTime(
        picked.year,
        picked.month,
        picked.day,
        current.hour,
        current.minute,
      ),
    );
  }

  Future<void> _pickTime(Transaction tx) async {
    final current = _timeOf(tx);
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
    );
    if (picked == null) return;
    setState(
      () => _occurredAt = DateTime(
        current.year,
        current.month,
        current.day,
        picked.hour,
        picked.minute,
      ),
    );
  }

  /// 改完一笔，凡是依赖流水的地方都过期了。
  void _invalidateAll() {
    ref.invalidate(txDetailProvider(widget.id));
    ref.invalidate(txListProvider);
    ref.invalidate(recentTxProvider);
    ref.invalidate(pendingTxProvider);
    ref.invalidate(statsProvider);
  }

  /// 跑一个写操作：转圈、成功提示、失败行内说明，一处写完。
  /// [action] 可以返回一句更贴切的提示（例如离线时的「已离线保存」）。
  Future<void> _run(
    Future<String?> Function() action, {
    required String done,
    bool pop = false,
  }) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final message = await action();
      _invalidateAll();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message ?? done)));
      if (pop && context.canPop()) context.pop();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = describeError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save(Transaction tx) async {
    final cents = Money.tryParse(_amount.text);
    if (cents == null || cents <= 0) {
      setState(() => _error = '金额填得不对，例如 35.50');
      return;
    }
    final type = _typeOf(tx);
    final isTransfer = type == Transaction.typeTransfer;
    final fundId = _value(_kFund, tx.fundId);
    final toFundId = _value(_kToFund, tx.toFundId);
    final accountId = _value(_kAccount, tx.accountId);
    final toAccountId = _value(_kToAccount, tx.toAccountId);

    if (isTransfer &&
        !(accountId != null && toAccountId != null) &&
        !(fundId != null && toFundId != null)) {
      setState(() => _error = '转账至少要填一对：账户→账户，或板块→板块');
      return;
    }
    if (!isTransfer && fundId == null) {
      setState(() => _error = '请选择一个板块');
      return;
    }

    final ledger = ref.read(ledgerProvider).valueOrNull;
    final currency = _currencyOf(tx, ledger, accountId);
    final cross = isTransfer && toAccountId != null && _toCurrencyOf(tx, ledger, accountId, toAccountId) != currency;
    int? toCents;
    if (cross) {
      toCents = Money.tryParse(_toAmount.text);
      if (toCents == null || toCents <= 0) {
        setState(() => _error = '两边币种不同，填一下到账多少，例如 669.40');
        return;
      }
    }

    final patch = <String, dynamic>{
      'type': type,
      'amountCents': cents,
      if (accountId == null && currency != tx.currency) 'currency': currency,
      if (cross) 'toAmountCents': toCents,
      // 服务端要带时区偏移的 ISO（不带就 400）。
      'occurredAt': Dates.isoLocal(_timeOf(tx)),
      'merchant': _merchant.text.trim(),
      'note': _note.text.trim(),
      'memberId': _value(_kMember, tx.memberId),
      'fundId': fundId,
      'accountId': accountId,
      'categoryId': isTransfer ? null : _value(_kCategory, tx.categoryId),
      'toFundId': isTransfer ? toFundId : null,
      'toAccountId': isTransfer ? toAccountId : null,
    };
    await _run(
      () async {
        final saved = await ref
            .read(transactionsRepoProvider)
            .update(tx.id, patch);
        // 断网时 update 不再抛异常，而是先记在本地队列里。
        return saved.pendingSync ? '已离线保存，联网后自动上传' : null;
      },
      done: '已保存',
      pop: true,
    );
  }

  Future<void> _confirmDelete(Transaction tx) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这笔流水？'),
        content: Text(
          '${Money.format(tx.amountCents, currency: tx.currency)} · ${Dates.dateTimeLabel(tx.occurredAt)}\n'
          '删除后不能恢复，余额与统计会跟着变。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run(
      () async {
        final repo = ref.read(transactionsRepoProvider);
        final offline = await wentToOutbox(repo, () => repo.delete(tx.id));
        return offline ? '已离线保存，联网后自动上传' : null;
      },
      done: '已删除',
      pop: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(txDetailProvider(widget.id));
    final ledger = ref.watch(ledgerProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(
        title: const Text('流水详情'),
        actions: [
          if (async.hasValue)
            IconButton(
              tooltip: '删除',
              onPressed: _busy ? null : () => _confirmDelete(async.requireValue),
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: AsyncValueView<Transaction>(
        value: async,
        loading: const SkeletonList(rows: 6),
        onRetry: () => ref.invalidate(txDetailProvider(widget.id)),
        errorPadding: const EdgeInsets.all(LedgerLayout.pagePadding),
        data: (tx) => _form(tx, ledger),
      ),
    );
  }

  Widget _form(Transaction tx, LedgerData? ledger) {
    _bind(tx);
    final theme = Theme.of(context);
    final type = _typeOf(tx);
    final isTransfer = type == Transaction.typeTransfer;
    final categories = ledger == null
        ? const <TxCategory>[]
        : (type == Transaction.typeIncome
              ? ledger.incomeCategories()
              : ledger.expenseCategories());
    final categoryId = _value(_kCategory, tx.categoryId);
    final fundId = _value(_kFund, tx.fundId);
    final toFundId = _value(_kToFund, tx.toFundId);
    final accountId = _value(_kAccount, tx.accountId);
    final toAccountId = _value(_kToAccount, tx.toAccountId);
    final memberId = _value(_kMember, tx.memberId);
    final merchant = _merchant.text.trim();
    final note = _note.text.trim();
    final currency = _currencyOf(tx, ledger, accountId);
    final toCurrency = _toCurrencyOf(tx, ledger, accountId, toAccountId);
    final cross = isTransfer && toAccountId != null && toCurrency != currency;

    // 一行一项的摘要，点哪一项就在它下面展开选择器：看一笔账不用滚过 15 个类别图标和
    // 三排芯片；要改哪个就点哪个。
    return ReadableListView(
      maxWidth: 720,
      padding: const EdgeInsets.only(bottom: LedgerLayout.groupGap),
      children: [
        _Header(tx: tx, amount: _amount, type: type, currency: currency),
        if (cross)
          PickerField(
            key: const ValueKey('tx-to-amount-field'),
            label: '到账多少（${currencyName(toCurrency)}）',
            topGap: LedgerLayout.itemGap,
            trailing: Text('两边币种不同', style: theme.textTheme.bodySmall),
            child: TextField(
              key: const ValueKey('tx-to-amount'),
              controller: _toAmount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(prefixText: '${Money.symbolFor(toCurrency).trim()} ', hintText: '669.40'),
            ),
          ),
        // 没挂账户的流水（只走板块）：币种自己选；挂了账户的跟着账户走，不用选。
        if (accountId == null)
          PickerField(
            label: '币种',
            topGap: LedgerLayout.itemGap,
            trailing: Text('没走账户才要选', style: theme.textTheme.bodySmall),
            child: Align(
              alignment: Alignment.centerLeft,
              child: CurrencyDropdown(
                keyPrefix: 'tx-currency',
                value: currency,
                onChanged: (c) => setState(() => _currency = c),
              ),
            ),
          ),
        PickerField(
          label: '类型',
          topGap: LedgerLayout.itemGap,
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: Transaction.typeExpense, label: Text('支出')),
              ButtonSegment(value: Transaction.typeIncome, label: Text('收入')),
              ButtonSegment(
                value: Transaction.typeTransfer,
                label: Text('转账·拨款'),
              ),
            ],
            selected: {type},
            showSelectedIcon: false,
            style: SegmentedButton.styleFrom(minimumSize: const Size(0, 48)),
            onSelectionChanged: (values) => setState(() {
              _type = values.first;
              // 注意是「显式置空」而不是 remove：remove 会让 _value() 退回
              // tx.categoryId，于是一笔改成收入的流水还挂着支出类别（服务端
              // 不拦这个，是静悄悄的脏数据）。置空 = PATCH 明确送 null，
              // 用户重新挑一个才有值。
              _picked[_kCategory] = null;
              _error = null;
            }),
          ),
        ),
        const SizedBox(height: LedgerLayout.itemGap),
        if (ledger == null)
          const SkeletonList(rows: 3)
        else ...[
          if (!isTransfer)
            _section(
              key: _kCategory,
              label: '类别',
              value: _categoryValue(ledger.category(categoryId)),
              child: CategoryGrid(
                categories: categories,
                selectedId: categoryId,
                onSelected: (id) => _pick(_kCategory, id),
              ),
            ),
          _section(
            key: _kFund,
            label: isTransfer ? '从哪个板块转出' : '板块',
            value: _fundValue(ledger, fundId),
            flush: true,
            child: FundPicker(
              funds: _fundsWith(ledger, [tx.fundId, fundId]),
              selectedId: fundId,
              onSelected: (id) => _pick(_kFund, id),
            ),
          ),
          if (isTransfer)
            _section(
              key: _kToFund,
              label: '转入哪个板块',
              value: _fundValue(ledger, toFundId),
              flush: true,
              child: FundPicker(
                funds: _fundsWith(ledger, [tx.toFundId, toFundId]),
                keyPrefix: 'to-fund',
                selectedId: toFundId,
                onSelected: (id) => _pick(_kToFund, id),
              ),
            ),
          _section(
            key: _kAccount,
            label: isTransfer ? '从哪个账户转出' : '账户',
            value: _plain(ledger.account(accountId)?.name, isTransfer ? '不走账户' : '没填'),
            child: AccountPicker(
              accounts: _accountsWith(ledger, [tx.accountId, accountId]),
              selectedId: accountId,
              onSelected: (id) => _pick(_kAccount, id),
            ),
          ),
          if (isTransfer)
            _section(
              key: _kToAccount,
              label: '转入哪个账户',
              value: _plain(ledger.account(toAccountId)?.name, '不走账户'),
              child: AccountPicker(
                accounts: _accountsWith(ledger, [tx.toAccountId, toAccountId]),
                selectedId: toAccountId,
                keyPrefix: 'to-account',
                onSelected: (id) => _pick(_kToAccount, id),
              ),
            ),
          _section(
            key: _kMember,
            label: '成员',
            value: _plain(ledger.member(memberId)?.label, '没填'),
            child: MemberPicker(
              members: ledger.activeMembers,
              selectedId: memberId,
              onSelected: (id) => _pick(_kMember, id),
            ),
          ),
        ],
        _section(
          key: 'time',
          label: '时间',
          value: _plain(Dates.dateTimeLabel(_timeOf(tx)), ''),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _pickDate(tx),
                  icon: const Icon(Icons.today_outlined, size: 18),
                  label: Text(Dates.dayLabel(_timeOf(tx))),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _pickTime(tx),
                  icon: const Icon(Icons.schedule_outlined, size: 18),
                  label: Text(Dates.timeLabel(_timeOf(tx))),
                ),
              ),
            ],
          ),
        ),
        _section(
          key: 'note',
          label: '商户与备注',
          value: _plain(
            [if (merchant.isNotEmpty) merchant, if (note.isNotEmpty) note].join(' · '),
            '没填',
          ),
          child: Column(
            children: [
              TextField(
                controller: _merchant,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(hintText: '商户'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _note,
                maxLines: 2,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(hintText: '备注'),
              ),
            ],
          ),
        ),
        if (tx.source != 'manual' || tx.rawText != null)
          PickerField(label: '来源', child: _Provenance(tx: tx)),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              LedgerLayout.pagePadding,
              LedgerLayout.groupGap,
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
          child: Column(
            children: [
              if (tx.isPending)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonal(
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                            final repo = ref.read(transactionsRepoProvider);
                            final offline = await wentToOutbox(
                              repo,
                              () => repo.confirm(tx.id),
                            );
                            return offline
                                ? '已离线保存，联网后自动上传'
                                : null;
                          }, done: '已确认'),
                    child: const Text('确认这笔'),
                  ),
                ),
              if (tx.isDuplicate) ...[
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                            await ref
                                .read(transactionsRepoProvider)
                                .update(tx.id, {'status': 'confirmed'});
                            return null;
                          }, done: '已标记为非重复'),
                    child: const Text('标记为非重复'),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _busy ? null : () => _save(tx),
                  child: const Text('保存修改'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 摘要一行 + （展开时）它的选择器。[flush] 的选择器自带左右边距（横滑芯片行要出血到屏幕边）。
  Widget _section({
    required String key,
    required String label,
    required Widget value,
    required Widget child,
    bool flush = false,
  }) {
    final expanded = _open == key;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SummaryRow(
          key: ValueKey('tx-section-$key'),
          label: label,
          value: value,
          expanded: expanded,
          onTap: () => _toggle(key),
        ),
        if (expanded)
          Padding(
            padding: EdgeInsets.fromLTRB(
              flush ? 0 : LedgerLayout.pagePadding,
              0,
              flush ? 0 : LedgerLayout.pagePadding,
              LedgerLayout.itemGap,
            ),
            child: child,
          ),
      ],
    );
  }

  Widget _plain(String? text, String empty) => Builder(
    builder: (context) {
      final theme = Theme.of(context);
      final filled = text != null && text.isNotEmpty;
      return Text(
        filled ? text : empty,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyLarge?.copyWith(
          color: filled ? null : theme.colorScheme.onSurfaceVariant,
        ),
      );
    },
  );

  Widget _categoryValue(TxCategory? category) {
    if (category == null) return _plain(null, '未分类');
    return Builder(
      builder: (context) => Row(
        children: [
          CategoryIcon(category.icon, size: 18, color: hexColor(category.color)),
          const SizedBox(width: 8),
          Flexible(child: _plain(category.name, '')),
        ],
      ),
    );
  }

  Widget _fundValue(LedgerData ledger, String? id) {
    final fund = ledger.fund(id);
    if (fund == null) return _plain(null, '没填');
    return Builder(
      builder: (context) => Row(
        children: [
          FundDot.of(context, fund: fund, index: ledger.fundIndex(fund.id)),
          const SizedBox(width: 8),
          Flexible(child: _plain(fund.name, '')),
        ],
      ),
    );
  }
}

/// 摘要行：左边名目，右边当前的值，末尾一个展开/收起的箭头。整行可点。
class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    super.key,
    required this.label,
    required this.value,
    required this.expanded,
    required this.onTap,
  });

  final String label;
  final Widget value;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 10, 8, 10),
          child: Row(
            children: [
              SizedBox(
                width: 104,
                child: Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Expanded(child: value),
              Icon(
                expanded ? Icons.expand_less : Icons.expand_more,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant,
                semanticLabel: expanded ? '收起' : '展开修改',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 顶部：当前状态 + 可改的金额。
class _Header extends StatelessWidget {
  const _Header({required this.tx, required this.amount, required this.type, required this.currency});

  final Transaction tx;
  final TextEditingController amount;
  final String type;

  /// 现在选的账户的币（改了账户就跟着变）。
  final String currency;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ledger = LedgerColors.of(context);
    return Container(
      color: ledger.surface2,
      padding: const EdgeInsets.fromLTRB(
        LedgerLayout.pagePadding,
        LedgerLayout.itemGap,
        LedgerLayout.pagePadding,
        LedgerLayout.pagePadding,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                type == Transaction.typeExpense ? '支出金额' : '金额',
                style: theme.textTheme.bodySmall,
              ),
              const Spacer(),
              if (tx.status != 'confirmed') TxStatusBadge(status: tx.status),
            ],
          ),
          const SizedBox(height: 4),
          TextField(
            controller: amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: theme.textTheme.headlineMedium,
            decoration: InputDecoration(
              // 这笔记的是什么币就写什么符号（美元户的流水是 $）。
              prefixText: '${Money.symbolFor(currency).trim()} ',
              filled: false,
              contentPadding: EdgeInsets.zero,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
            ),
          ),
        ],
      ),
    );
  }
}

/// 机器记的账要说清楚它从哪来、有多确定。
class _Provenance extends StatelessWidget {
  const _Provenance({required this.tx});

  final Transaction tx;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final confidence = tx.confidence;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          [
            tx.sourceLabel,
            if (tx.sourceApp != null && tx.sourceApp!.isNotEmpty) tx.sourceApp!,
            if (confidence != null) '${(confidence * 100).round()}% 可信',
            if (tx.createdAt != null) '记于 ${Dates.dateTimeLabel(tx.createdAt!)}',
          ].join(' · '),
          style: theme.textTheme.bodyMedium,
        ),
        if (tx.rawText != null && tx.rawText!.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(LedgerLayout.itemGap),
            decoration: BoxDecoration(
              color: LedgerColors.of(context).surface3,
              borderRadius: BorderRadius.circular(LedgerShapes.control),
            ),
            child: Text(tx.rawText!, style: theme.textTheme.bodySmall),
          ),
        ],
      ],
    );
  }
}
