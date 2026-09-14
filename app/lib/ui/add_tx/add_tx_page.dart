import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../core/ids.dart';
import '../../core/money.dart';
import '../../data/api/api_client.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../transactions/tx_providers.dart';
import '../widgets/widgets.dart';
import 'account_picker.dart';
import 'add_tx_memory.dart';
import 'amount_keypad.dart';
import 'category_grid.dart';
import 'fund_picker.dart';
import 'member_picker.dart';
import 'picker_field.dart';

/// 记一笔：金额键盘 → 类型 → 类别 → 基金 → 账户 → 成员 → 时间 → 商户/备注。
///
/// 选择项「上次选了什么」会被记住（按类型分开），所以常规的一笔通常
/// 只要敲金额 + 点保存。
class AddTxPage extends ConsumerStatefulWidget {
  const AddTxPage({super.key});

  @override
  ConsumerState<AddTxPage> createState() => _AddTxPageState();
}

class _AddTxPageState extends ConsumerState<AddTxPage> {
  /// 金额的原始输入（只含数字和一个小数点），展示时才格式化。
  String _raw = '';
  String _type = Transaction.typeExpense;

  /// 用户亲手点过的选择。key 在 map 里 = 碰过（值可以是 null，表示「就是不填」），
  /// 不在 map 里 = 没碰过，那才轮到「上次记住的 / 默认基金 / 当前成员」兜底。
  final Map<String, String?> _picked = {};

  String? get _fundId => _picked[_kFund];
  String? get _toFundId => _picked[_kToFund];
  String? get _accountId => _picked[_kAccount];
  String? get _toAccountId => _picked[_kToAccount];

  static const String _kFund = 'fund';
  static const String _kToFund = 'toFund';
  static const String _kAccount = 'account';
  static const String _kToAccount = 'toAccount';
  static const String _kCategory = 'category';
  static const String _kMember = 'member';

  DateTime _occurredAt = DateTime.now();

  final TextEditingController _merchant = TextEditingController();
  final TextEditingController _note = TextEditingController();

  String? _amountError;
  String? _fundError;
  String? _transferError;
  String? _saveError;
  String? _saveNotice;
  bool _saving = false;

  static const int _maxYuanDigits = 9;

  @override
  void dispose() {
    _merchant.dispose();
    _note.dispose();
    super.dispose();
  }

  int get _cents => Money.tryParse(_raw) ?? 0;

  bool get _isTransfer => _type == Transaction.typeTransfer;

  void _onDigit(String ch) {
    setState(() {
      _amountError = null;
      if (ch == '.') {
        if (_raw.contains('.')) return;
        _raw = _raw.isEmpty ? '0.' : '$_raw.';
        return;
      }
      final dot = _raw.indexOf('.');
      if (dot >= 0) {
        if (_raw.length - dot > 2) return; // 最多两位小数
      } else if (_raw.length >= _maxYuanDigits) {
        return;
      }
      _raw = _raw == '0' ? ch : '$_raw$ch';
    });
  }

  void _onBackspace() {
    if (_raw.isEmpty) return;
    setState(() => _raw = _raw.substring(0, _raw.length - 1));
  }

  void _onClear() => setState(() => _raw = '');

  void _setType(String type) {
    if (type == _type) return;
    setState(() {
      _type = type;
      // 类别按 kind 分家，换了类型旧的就不作数了。
      _picked.remove(_kCategory);
      if (type == Transaction.typeTransfer) {
        // 支出/收入选的基金与账户是「单边」的，转账要的是成对的两侧。
        // 把单边的留着会凑出「fundId 有、toFundId 没有」的半对 —— 服务端直接
        // 400 invalid_transfer。宁可让用户重挑一遍，也不发一笔注定被拒的。
        _picked.remove(_kFund);
        _picked.remove(_kAccount);
      } else {
        // 回到支出/收入，「转入」那一侧没有意义了。
        _picked.remove(_kToFund);
        _picked.remove(_kToAccount);
      }
      _transferError = null;
      _fundError = null;
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _occurredAt,
      firstDate: DateTime(2000),
      lastDate: DateTime(_occurredAt.year + 5),
    );
    if (picked == null) return;
    setState(() {
      _occurredAt = DateTime(
        picked.year,
        picked.month,
        picked.day,
        _occurredAt.hour,
        _occurredAt.minute,
      );
    });
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_occurredAt),
    );
    if (picked == null) return;
    setState(() {
      _occurredAt = DateTime(
        _occurredAt.year,
        _occurredAt.month,
        _occurredAt.day,
        picked.hour,
        picked.minute,
      );
    });
  }

  /// 在候选里挑第一个「确实存在」的 id。
  static String? _existing(Iterable<String> ids, List<String?> candidates) {
    for (final id in candidates) {
      if (id != null && ids.contains(id)) return id;
    }
    return null;
  }

  /// 选中的基金：手点的（含「点掉了」）> 上次记住的 > 默认基金。
  String? _resolvedFund(LedgerData ledger, AddTxChoice memory) {
    final ids = ledger.activeFunds.map((f) => f.id).toSet();
    if (_picked.containsKey(_kFund)) return _existing(ids, [_fundId]);
    final remembered = _existing(ids, [memory.fundId]);
    if (remembered != null) return remembered;
    for (final fund in ledger.activeFunds) {
      if (fund.isDefault) return fund.id;
    }
    return null;
  }

  String? _resolvedAccount(LedgerData ledger, AddTxChoice memory) {
    final ids = ledger.activeAccounts.map((a) => a.id).toSet();
    if (_picked.containsKey(_kAccount)) return _existing(ids, [_accountId]);
    return _existing(ids, [memory.accountId]);
  }

  String? _resolvedCategory(List<TxCategory> categories, AddTxChoice memory) {
    final ids = categories.map((c) => c.id).toSet();
    if (_picked.containsKey(_kCategory)) {
      return _existing(ids, [_picked[_kCategory]]);
    }
    return _existing(ids, [memory.categoryId]);
  }

  String? _resolvedMember(LedgerData ledger, AddTxChoice memory) {
    final ids = ledger.activeMembers.map((m) => m.id).toSet();
    if (_picked.containsKey(_kMember)) {
      return _existing(ids, [_picked[_kMember]]);
    }
    return _existing(ids, [memory.memberId, ref.read(sessionProvider)?.me.id]);
  }

  Future<void> _save(LedgerData ledger) async {
    final memory = ref.read(addTxMemoryProvider).forType(_type);
    final categories = _type == Transaction.typeIncome
        ? ledger.incomeCategories()
        : ledger.expenseCategories();
    // 转账的两对是正交的：只填账户对时基金那一侧必须是空的，
    // 否则服务端会收到 fundId 有、toFundId 没有的半对，直接 400。
    final fundId = _isTransfer ? _fundId : _resolvedFund(ledger, memory);
    final accountId = _isTransfer ? _accountId : _resolvedAccount(ledger, memory);
    final categoryId = _resolvedCategory(categories, memory);
    final memberId = _resolvedMember(ledger, memory);

    final amountError = _cents <= 0 ? '请输入金额' : null;
    String? fundError;
    String? transferError;
    if (_isTransfer) {
      final accountPair = accountId != null && _toAccountId != null;
      final fundPair = fundId != null && _toFundId != null;
      // 半对（只填了一边）和「一对都没有」一样是服务端的 400，先在本地说清楚。
      final accountHalf =
          !accountPair && (accountId != null || _toAccountId != null);
      final fundHalf = !fundPair && (fundId != null || _toFundId != null);
      if (!accountPair && !fundPair) {
        transferError = '至少填一对：账户→账户，或基金→基金';
      } else if (fundHalf) {
        fundError = '基金只填了一边：两边都填，或者都留空';
      } else if (accountHalf) {
        transferError = '账户只填了一边：两边都填，或者都留空';
      } else if (accountPair && accountId == _toAccountId) {
        transferError = '转出和转入不能是同一个账户';
      } else if (fundPair && fundId == _toFundId) {
        transferError = '转出和转入不能是同一个基金';
      }
    } else if (fundId == null) {
      fundError = '请选择一个基金';
    }

    setState(() {
      _amountError = amountError;
      _fundError = fundError;
      _transferError = transferError;
      _saveError = null;
      _saveNotice = null;
    });
    if (amountError != null || fundError != null || transferError != null) return;

    final draft = TransactionDraft(
      clientId: newClientId(),
      type: _type,
      amountCents: _cents,
      occurredAt: _occurredAt,
      fundId: fundId,
      toFundId: _isTransfer ? _toFundId : null,
      accountId: accountId,
      toAccountId: _isTransfer ? _toAccountId : null,
      categoryId: _isTransfer ? null : categoryId,
      memberId: memberId,
      merchant: _merchant.text.trim().isEmpty ? null : _merchant.text.trim(),
      note: _note.text.trim().isEmpty ? null : _note.text.trim(),
    );

    setState(() => _saving = true);
    try {
      final saved = await ref.read(transactionsRepoProvider).create(draft);
      await ref
          .read(addTxMemoryProvider.notifier)
          .remember(
            _type,
            fundId: fundId,
            accountId: accountId,
            categoryId: draft.categoryId,
            memberId: memberId,
          );
      // 记完一笔，首页/账单/统计都过期了。
      ref.invalidate(recentTxProvider);
      ref.invalidate(pendingTxProvider);
      ref.invalidate(txListProvider);
      ref.invalidate(statsProvider);
      if (!mounted) return;
      if (saved.serverDuplicate) {
        // 服务端觉得这笔和已有的一笔撞了：已经存下来了（标成「疑似重复」），
        // 但不能一声不吭地关页面，让人自己决定要不要去改。
        setState(() {
          _saveNotice = '已保存，但服务器判定可能重复，已标为「疑似重复」，可在账单里处理。';
          _raw = '';
        });
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            saved.pendingSync
                ? '已离线保存，联网后自动上传'
                : '已记下 ${Money.format(saved.amountCents)}',
          ),
        ),
      );
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/home');
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _saveError = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saveError = describeError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ledger = ref.watch(ledgerProvider);
    // 系统键盘弹起来时把自绘键盘收掉，两个键盘叠着没法用。
    final systemKeyboard = MediaQuery.viewInsetsOf(context).bottom > 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('记一笔'),
        actions: [
          TextButton(
            key: const ValueKey('save-tx-appbar'),
            onPressed: _saving || !ledger.hasValue
                ? null
                : () => _save(ledger.requireValue),
            child: const Text('保存'),
          ),
        ],
      ),
      body: AsyncValueView<LedgerData>(
        value: ledger,
        onRetry: () => ref.invalidate(ledgerProvider),
        loading: const SkeletonList(rows: 6),
        data: (data) => data.activeFunds.isEmpty
            ? EmptyState(
                title: '还没有基金',
                message: '每一笔钱都要落到一个基金里，先建一个再记账。',
                icon: Icons.savings_outlined,
                actionLabel: '新建基金',
                onAction: () => context.push('/funds/new'),
              )
            : Column(
                children: [
                  _AmountHeader(
                    type: _type,
                    onType: _setType,
                    cents: _cents,
                    error: _amountError,
                    saveError: _saveError,
                    notice: _saveNotice,
                  ),
                  Expanded(child: _form(data)),
                  if (!systemKeyboard)
                    AmountKeypad(
                      onDigit: _onDigit,
                      onBackspace: _onBackspace,
                      onClear: _onClear,
                      onSave: () => _save(data),
                      busy: _saving,
                    ),
                ],
              ),
      ),
    );
  }

  Widget _form(LedgerData ledger) {
    final memory = ref.watch(addTxMemoryProvider).forType(_type);
    final categories = _type == Transaction.typeIncome
        ? ledger.incomeCategories()
        : ledger.expenseCategories();
    // 转账时不替用户「猜」基金/账户：没点就是没选。
    final fundId = _isTransfer ? _fundId : _resolvedFund(ledger, memory);
    final accountId = _isTransfer
        ? _accountId
        : _resolvedAccount(ledger, memory);

    return ListView(
      padding: const EdgeInsets.only(bottom: LedgerLayout.groupGap),
      children: [
        if (!_isTransfer)
          PickerField(
            label: '类别',
            child: CategoryGrid(
              categories: categories,
              selectedId: _resolvedCategory(categories, memory),
              onSelected: (id) => setState(() => _picked[_kCategory] = id),
            ),
          ),
        PickerField(
          label: _isTransfer ? '从哪个基金转出' : '基金',
          error: _fundError,
          contentPadding: EdgeInsets.zero,
          trailing: _FieldHint(text: '这笔钱归哪个模块', show: !_isTransfer),
          child: FundPicker(
            funds: ledger.activeFunds,
            selectedId: fundId,
            onSelected: (id) => setState(() {
              _picked[_kFund] = id;
              _fundError = null;
              _transferError = null;
            }),
          ),
        ),
        if (_isTransfer)
          PickerField(
            label: '转入哪个基金',
            topGap: LedgerLayout.itemGap,
            contentPadding: EdgeInsets.zero,
            child: FundPicker(
              funds: ledger.activeFunds,
              keyPrefix: 'to-fund',
              selectedId: _toFundId,
              onSelected: (id) => setState(() {
                _picked[_kToFund] = id;
                _transferError = null;
              }),
            ),
          ),
        PickerField(
          label: _isTransfer ? '从哪个账户转出' : '账户',
          error: _isTransfer ? null : _transferError,
          child: AccountPicker(
            accounts: ledger.activeAccounts,
            selectedId: accountId,
            onSelected: (id) => setState(() {
              _picked[_kAccount] = id;
              _transferError = null;
            }),
          ),
        ),
        if (_isTransfer)
          PickerField(
            label: '转入哪个账户',
            error: _transferError,
            topGap: LedgerLayout.itemGap,
            child: AccountPicker(
              accounts: ledger.activeAccounts,
              selectedId: _toAccountId,
              keyPrefix: 'to-account',
              onSelected: (id) => setState(() {
                _picked[_kToAccount] = id;
                _transferError = null;
              }),
            ),
          ),
        PickerField(
          label: '成员',
          child: MemberPicker(
            members: ledger.activeMembers,
            selectedId: _resolvedMember(ledger, memory),
            onSelected: (id) => setState(() => _picked[_kMember] = id),
          ),
        ),
        PickerField(
          label: '时间',
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(Icons.today_outlined, size: 18),
                  label: Text(Dates.dayLabel(_occurredAt)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickTime,
                  icon: const Icon(Icons.schedule_outlined, size: 18),
                  label: Text(Dates.timeLabel(_occurredAt)),
                ),
              ),
            ],
          ),
        ),
        PickerField(
          label: _isTransfer ? '备注' : '商户与备注',
          child: Column(
            children: [
              if (!_isTransfer) ...[
                TextField(
                  controller: _merchant,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(hintText: '商户，例如「巷口面馆」'),
                ),
                const SizedBox(height: 8),
              ],
              TextField(
                controller: _note,
                maxLines: 2,
                decoration: const InputDecoration(hintText: '备注（选填）'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 顶部：类型分段 + 实时格式化的大金额 + 行内校验。
class _AmountHeader extends StatelessWidget {
  const _AmountHeader({
    required this.type,
    required this.onType,
    required this.cents,
    this.error,
    this.saveError,
    this.notice,
  });

  final String type;
  final ValueChanged<String> onType;
  final int cents;
  final String? error;
  final String? saveError;

  /// 保存成功但有话要说（例如服务器判定疑似重复）。
  final String? notice;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ledger = LedgerColors.of(context);
    return Container(
      width: double.infinity,
      color: ledger.surface2,
      padding: const EdgeInsets.fromLTRB(
        LedgerLayout.pagePadding,
        12,
        LedgerLayout.pagePadding,
        16,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SegmentedButton<String>(
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
            style: SegmentedButton.styleFrom(
              minimumSize: const Size(0, 48),
            ),
            onSelectionChanged: (values) => onType(values.first),
          ),
          const SizedBox(height: 12),
          Text(
            Money.format(cents),
            style: theme.textTheme.displaySmall?.copyWith(
              color: error != null ? theme.colorScheme.error : null,
            ),
            maxLines: 1,
          ),
          if (error != null || saveError != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                error ?? saveError!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            )
          else if (notice != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                notice!,
                style: theme.textTheme.bodySmall?.copyWith(color: ledger.warning),
              ),
            ),
        ],
      ),
    );
  }
}

class _FieldHint extends StatelessWidget {
  const _FieldHint({required this.text, required this.show});

  final String text;
  final bool show;

  @override
  Widget build(BuildContext context) => show
      ? Text(text, style: Theme.of(context).textTheme.bodySmall)
      : const SizedBox.shrink();
}
