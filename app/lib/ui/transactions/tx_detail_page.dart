import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
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

  @override
  void dispose() {
    _amount.dispose();
    _merchant.dispose();
    _note.dispose();
    super.dispose();
  }

  void _bind(Transaction tx) {
    if (_bound == tx.id) return;
    _bound = tx.id;
    _amount.text = Money.plain(tx.amountCents);
    _merchant.text = tx.merchant ?? '';
    _note.text = tx.note ?? '';
  }

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
      setState(() => _error = '转账至少要填一对：账户→账户，或基金→基金');
      return;
    }
    if (!isTransfer && fundId == null) {
      setState(() => _error = '请选择一个基金');
      return;
    }

    final patch = <String, dynamic>{
      'type': type,
      'amountCents': cents,
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
          '${Money.format(tx.amountCents)} · ${Dates.dateTimeLabel(tx.occurredAt)}\n'
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

    return ListView(
      padding: const EdgeInsets.only(bottom: LedgerLayout.groupGap),
      children: [
        _Header(tx: tx, amount: _amount, type: type),
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
        if (ledger == null)
          const SkeletonList(rows: 3)
        else ...[
          if (!isTransfer)
            PickerField(
              label: '类别',
              child: CategoryGrid(
                categories: categories,
                selectedId: _value(_kCategory, tx.categoryId),
                onSelected: (id) => _pick(_kCategory, id),
              ),
            ),
          PickerField(
            label: isTransfer ? '从哪个基金转出' : '基金',
            contentPadding: EdgeInsets.zero,
            child: FundPicker(
              funds: ledger.activeFunds,
              selectedId: _value(_kFund, tx.fundId),
              onSelected: (id) => _pick(_kFund, id),
            ),
          ),
          if (isTransfer)
            PickerField(
              label: '转入哪个基金',
              topGap: LedgerLayout.itemGap,
              contentPadding: EdgeInsets.zero,
              child: FundPicker(
                funds: ledger.activeFunds,
                keyPrefix: 'to-fund',
                selectedId: _value(_kToFund, tx.toFundId),
                onSelected: (id) => _pick(_kToFund, id),
              ),
            ),
          PickerField(
            label: isTransfer ? '从哪个账户转出' : '账户',
            child: AccountPicker(
              accounts: ledger.activeAccounts,
              selectedId: _value(_kAccount, tx.accountId),
              onSelected: (id) => _pick(_kAccount, id),
            ),
          ),
          if (isTransfer)
            PickerField(
              label: '转入哪个账户',
              topGap: LedgerLayout.itemGap,
              child: AccountPicker(
                accounts: ledger.activeAccounts,
                selectedId: _value(_kToAccount, tx.toAccountId),
                keyPrefix: 'to-account',
                onSelected: (id) => _pick(_kToAccount, id),
              ),
            ),
          PickerField(
            label: '成员',
            child: MemberPicker(
              members: ledger.activeMembers,
              selectedId: _value(_kMember, tx.memberId),
              onSelected: (id) => _pick(_kMember, id),
            ),
          ),
        ],
        PickerField(
          label: '时间',
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
        PickerField(
          label: '商户与备注',
          child: Column(
            children: [
              TextField(
                controller: _merchant,
                decoration: const InputDecoration(hintText: '商户'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _note,
                maxLines: 2,
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
}

/// 顶部：当前状态 + 可改的金额。
class _Header extends StatelessWidget {
  const _Header({required this.tx, required this.amount, required this.type});

  final Transaction tx;
  final TextEditingController amount;
  final String type;

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
            decoration: const InputDecoration(
              prefixText: '¥ ',
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
