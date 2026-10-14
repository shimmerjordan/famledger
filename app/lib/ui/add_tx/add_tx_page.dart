import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/shell.dart';
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

  /// 跨币种转账的到账金额（按转入账户的币种）。空着就按今日汇率算（输入框里的提示就是那个数）。
  final TextEditingController _toAmount = TextEditingController();

  /// 实体键盘（网页、平板外接键盘）：数字和小数点直接进金额，Backspace 退格，Delete 清空，
  /// Enter 保存。焦点在商户/备注输入框里时不出手（那时 [FocusNode.hasPrimaryFocus] 为假）。
  final FocusNode _keys = FocusNode(debugLabel: 'add-tx-keys');

  /// 桌面（电脑上的网页、桌面端）：有实体键盘，金额就是个输入框，不画手机那种九宫格。
  /// 平板、手机上的网页还是键盘——没有实体键盘，九宫格比系统键盘好点。
  static bool get _desktop => const {
    TargetPlatform.linux,
    TargetPlatform.macOS,
    TargetPlatform.windows,
  }.contains(defaultTargetPlatform);

  /// 桌面金额框的文字和 [_raw] 保持一致（键盘快捷键、保存后清空都要同步过去）。
  final TextEditingController _amountField = TextEditingController();
  final FocusNode _amountFocus = FocusNode(debugLabel: 'add-tx-amount');

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
    _toAmount.dispose();
    _keys.dispose();
    _amountField.dispose();
    _amountFocus.dispose();
    super.dispose();
  }

  void _syncAmountField() {
    if (_amountField.text == _raw) return;
    _amountField.value = TextEditingValue(
      text: _raw,
      selection: TextSelection.collapsed(offset: _raw.length),
    );
  }

  /// 桌面金额框里敲的：只留数字和一个小数点，最多两位小数、整数 [_maxYuanDigits] 位，
  /// 多敲的当场扔掉——和九宫格的规矩一样。
  void _onAmountTyped(String text) {
    final buf = StringBuffer();
    var dot = false;
    var intDigits = 0;
    var decimals = 0;
    for (final ch in text.split('')) {
      if (ch == '.') {
        if (dot) continue;
        dot = true;
        if (buf.isEmpty) buf.write('0');
        buf.write('.');
        continue;
      }
      if (!'0123456789'.contains(ch)) continue;
      if (dot) {
        if (decimals >= 2) continue;
        decimals++;
      } else {
        if (intDigits >= _maxYuanDigits) continue;
        intDigits++;
      }
      buf.write(ch);
    }
    setState(() {
      _amountError = null;
      _raw = buf.toString();
    });
    _syncAmountField();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!_keys.hasPrimaryFocus || event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final ch = event.character;
    if (ch != null && ch.length == 1 && '0123456789.'.contains(ch)) {
      _onDigit(ch);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.backspace) {
      _onBackspace();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete) {
      _onClear();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      final data = ref.read(ledgerProvider).valueOrNull;
      if (data != null && !_saving) _save(data);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 点过屏幕键盘之后把焦点收回来：之前点进商户框的话，接着敲实体键盘的数字该进金额，不该进商户。
  void _focusKeys() {
    if (_desktop) {
      if (!_amountFocus.hasPrimaryFocus) _amountFocus.requestFocus();
      return;
    }
    if (!_keys.hasPrimaryFocus) _keys.requestFocus();
  }

  int get _cents => Money.tryParse(_raw) ?? 0;

  bool get _isTransfer => _type == Transaction.typeTransfer;

  /// 挡住保存的那个错误（本地校验或保存失败）。保存键在屏幕下半区，只在顶部刷
  /// 一行等于没提示（体感「点不动」），底部键盘上方再内联说一次，见 [_BottomError]。
  String? get _blockingError =>
      _amountError ?? _fundError ?? _transferError ?? _saveError;

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
    _syncAmountField();
  }

  void _onBackspace() {
    if (_raw.isEmpty) return;
    setState(() => _raw = _raw.substring(0, _raw.length - 1));
    _syncAmountField();
  }

  void _onClear() {
    setState(() => _raw = '');
    _syncAmountField();
  }

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

  /// 转账两头的账户币种不同时，转入账户的币种；否则 null。
  String? _crossCurrency(LedgerData ledger, String? accountId) {
    if (!_isTransfer || accountId == null || _toAccountId == null) return null;
    final from = ledger.account(accountId)?.currency;
    final to = ledger.account(_toAccountId)?.currency;
    if (from == null || to == null || from.toUpperCase() == to.toUpperCase()) return null;
    return to;
  }

  /// 到账金额的建议值：按今日汇率把转出金额折成转入币种；没汇率是 null。
  int? _suggestedToAmount(LedgerData ledger, String accountId, String toCurrency) {
    final String base = ref.read(baseCurrencyProvider);
    final String from = ledger.account(accountId)?.currency ?? base;
    return ref.read(fxRatesProvider).convert(_cents, from, toCurrency);
  }

  /// 保存：准备阶段（挑默认板块、账户、组请求体）出了意外也要说出来 —— 不能只进控制台、按钮点了没反应。
  Future<void> _save(LedgerData ledger) async {
    try {
      await _saveInner(ledger);
    } catch (e) {
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      setState(() {
        _saving = false;
        _saveError = describeError(e);
      });
    }
  }

  Future<void> _saveInner(LedgerData ledger) async {
    final memory = ref.read(addTxMemoryProvider).forType(_type);
    final categories = _type == Transaction.typeIncome
        ? ledger.incomeCategories()
        : ledger.expenseCategories();
    // 转账的两对是正交的：只填账户对时基金那一侧必须是空的，
    // 否则服务端会收到 fundId 有、toFundId 没有的半对，直接 400。
    final fundId = _isTransfer ? _fundId : _resolvedFund(ledger, memory);
    final accountId = _isTransfer
        ? _accountId
        : _resolvedAccount(ledger, memory);
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
        transferError = '至少填一对：账户→账户，或板块→板块';
      } else if (fundHalf) {
        fundError = '板块只填了一边：两边都填，或者都留空';
      } else if (accountHalf) {
        transferError = '账户只填了一边：两边都填，或者都留空';
      } else if (accountPair && accountId == _toAccountId) {
        transferError = '转出和转入不能是同一个账户';
      } else if (fundPair && fundId == _toFundId) {
        transferError = '转出和转入不能是同一个板块';
      }
    } else if (fundId == null) {
      fundError = '请选择一个板块';
    }

    // 跨币种转账：到账多少按转入账户的币种。没填就按今日汇率；没汇率又没填，就得让人填。
    int? toAmount;
    final toCurrency = transferError == null ? _crossCurrency(ledger, accountId) : null;
    if (toCurrency != null) {
      final raw = _toAmount.text.trim();
      final typed = raw.isEmpty ? null : Money.tryParse(raw);
      if (raw.isNotEmpty && (typed == null || typed < 0)) {
        transferError = '到账金额填得不对，例如 669.40';
      } else {
        toAmount = typed ?? _suggestedToAmount(ledger, accountId!, toCurrency);
        if (toAmount == null) transferError = '两边币种不同，还没有汇率：填一下到账多少';
      }
    }

    setState(() {
      _amountError = amountError;
      _fundError = fundError;
      _transferError = transferError;
      _saveError = null;
      _saveNotice = null;
    });
    if (amountError != null || fundError != null || transferError != null) {
      HapticFeedback.mediumImpact();
      return;
    }

    // 币种跟着账户走（转账看转出账户）；没选账户就用家庭基准币。
    final base = ref.read(baseCurrencyProvider);
    final currency = ledger.account(accountId)?.currency ?? base;
    final draft = TransactionDraft(
      clientId: newClientId(),
      type: _type,
      amountCents: _cents,
      occurredAt: _occurredAt,
      currency: currency,
      toAmountCents: toAmount,
      toCurrency: toCurrency,
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
        _syncAmountField();
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            saved.pendingSync
                ? '已离线保存，联网后自动上传'
                : '已记下 ${Money.format(saved.amountCents, currency: currency)}',
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
      HapticFeedback.mediumImpact();
      setState(() => _saveError = e.message);
    } catch (e) {
      if (!mounted) return;
      HapticFeedback.mediumImpact();
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
    final width = widthClassOf(context);

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
      body: Focus(
        focusNode: _keys,
        // 桌面上焦点给金额框（它自己 autofocus），不然两个都抢。
        autofocus: !_desktop,
        onKeyEvent: _onKey,
        child: AsyncValueView<LedgerData>(
          value: ledger,
          onRetry: () => ref.invalidate(ledgerProvider),
          loading: const SkeletonList(rows: 6),
          data: (data) => data.activeFunds.isEmpty
              ? EmptyState(
                  title: '还没有板块',
                  message: '每一笔钱都要落到一个板块里，先建一个再记账。',
                  icon: Icons.savings_outlined,
                  actionLabel: '新建板块',
                  onAction: () => context.push('/funds/new'),
                )
              : switch (width) {
                  WidthClass.compact => _compactLayout(data, systemKeyboard),
                  // 平板竖放：还是手机的上下结构，只是别把键盘拉到 700 宽。
                  WidthClass.medium => ReadableBox(
                    maxWidth: 600,
                    child: _compactLayout(data, systemKeyboard),
                  ),
                  WidthClass.expanded => _wideLayout(data, systemKeyboard),
                },
        ),
      ),
    );
  }

  Widget _header(LedgerData data) {
    final currency = _effectiveCurrency(data);
    return _AmountHeader(
      type: _type,
      onType: _setType,
      cents: _cents,
      currency: currency,
      error: _amountError,
      saveError: _saveError,
      notice: _saveNotice,
      onTap: _focusKeys,
      amountField: _desktop ? _amountInput(data, currency) : null,
    );
  }

  /// 这笔的币种：跟着选中的账户走（转账看转出账户）；没选账户就用家庭基准币。
  String _effectiveCurrency(LedgerData ledger) {
    final memory = ref.read(addTxMemoryProvider).forType(_type);
    final accountId = _isTransfer ? _accountId : _resolvedAccount(ledger, memory);
    final base = ref.watch(baseCurrencyProvider);
    return ledger.account(accountId)?.currency ?? base;
  }

  /// 桌面的金额框：大字、自动聚焦，回车就保存。
  Widget _amountInput(LedgerData data, String currency) => TextField(
    key: const ValueKey('amount-field'),
    controller: _amountField,
    focusNode: _amountFocus,
    autofocus: true,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    textInputAction: TextInputAction.done,
    onChanged: _onAmountTyped,
    onSubmitted: (_) {
      if (!_saving) _save(data);
    },
    style: Theme.of(context).textTheme.displaySmall,
    decoration: InputDecoration(prefixText: '${Money.symbolFor(currency)} ', hintText: '0.00'),
  );

  /// 桌面没有九宫格，金额框下面直接一个保存键（顶栏那个太远）。
  Widget _desktopSave(LedgerData data) => Padding(
    padding: const EdgeInsets.fromLTRB(
      LedgerLayout.pagePadding,
      LedgerLayout.itemGap,
      LedgerLayout.pagePadding,
      LedgerLayout.pagePadding,
    ),
    child: SizedBox(
      width: double.infinity,
      height: 48,
      child: FilledButton(
        key: const ValueKey('save-tx-desktop'),
        onPressed: _saving ? null : () => _save(data),
        child: _saving
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Text('保存'),
      ),
    ),
  );

  Widget _keypad(LedgerData data) => AmountKeypad(
    onDigit: (ch) {
      _focusKeys();
      _onDigit(ch);
    },
    onBackspace: () {
      _focusKeys();
      _onBackspace();
    },
    onClear: _onClear,
    onSave: () => _save(data),
    busy: _saving,
  );

  /// 手机：金额在上、表单在中间滚、键盘贴底。
  Widget _compactLayout(LedgerData data, bool systemKeyboard) => Column(
    children: [
      _header(data),
      Expanded(child: _form(data)),
      if (_blockingError != null) _BottomError(_blockingError!),
      if (_desktop) _desktopSave(data) else if (!systemKeyboard) _keypad(data),
    ],
  );

  /// 宽屏（≥ 840）：左边是表单，右边一块固定 360 宽的「计算器」—— 类型、金额、键盘靠在一起，
  /// 眼睛不用在整屏上来回找；整体限宽 1040，再宽也不把类别格拉成 280 一格。
  Widget _wideLayout(LedgerData data, bool systemKeyboard) => ReadableBox(
    maxWidth: 1040,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _form(data)),
        SizedBox(
          width: 360,
          child: Column(
            children: [
              _header(data),
              if (_blockingError != null) _BottomError(_blockingError!),
              if (_desktop) _desktopSave(data) else if (!systemKeyboard) _keypad(data),
            ],
          ),
        ),
      ],
    ),
  );

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
          label: _isTransfer ? '从哪个板块转出' : '板块',
          error: _fundError,
          contentPadding: EdgeInsets.zero,
          trailing: _FieldHint(text: '这笔钱归哪个板块', show: !_isTransfer),
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
            label: '转入哪个板块',
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
        if (_crossCurrency(ledger, accountId) case final toCurrency?)
          PickerField(
            label: '到账金额',
            topGap: LedgerLayout.itemGap,
            trailing: Text('两边币种不同；空着就按今日汇率', style: Theme.of(context).textTheme.bodySmall),
            child: TextField(
              key: const ValueKey('to-amount'),
              controller: _toAmount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                prefixText: '${Money.symbolFor(toCurrency).trim()} ',
                hintText: switch (_suggestedToAmount(ledger, accountId!, toCurrency)) {
                  final v? => '约 ${Money.plain(v)}（按今日汇率）',
                  null => '还没有汇率，填一下到账多少',
                },
              ),
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
    this.currency = 'CNY',
    this.error,
    this.saveError,
    this.notice,
    this.onTap,
    this.amountField,
  });

  final String type;
  final ValueChanged<String> onType;
  final int cents;

  /// 这笔金额的币种（跟着选中的账户）：决定大金额的货币符号。
  final String currency;
  final String? error;
  final String? saveError;

  /// 桌面：金额是输入框，不是只读的大数字。
  final Widget? amountField;

  /// 保存成功但有话要说（例如服务器判定疑似重复）。
  final String? notice;

  /// 点一下金额区把实体键盘的焦点收回来（见 _AddTxPageState._focusKeys）。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ledger = LedgerColors.of(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
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
                ButtonSegment(
                  value: Transaction.typeExpense,
                  label: Text('支出'),
                ),
                ButtonSegment(value: Transaction.typeIncome, label: Text('收入')),
                ButtonSegment(
                  value: Transaction.typeTransfer,
                  label: Text('转账·拨款'),
                ),
              ],
              selected: {type},
              showSelectedIcon: false,
              style: SegmentedButton.styleFrom(minimumSize: const Size(0, 48)),
              onSelectionChanged: (values) => onType(values.first),
            ),
            const SizedBox(height: 12),
            amountField ??
                Text(
                  Money.format(cents, currency: currency),
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
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: ledger.warning,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 底部保存键正上方的行内错误横幅（DESIGN.md：错误用行内说明，不用错误 Snackbar）。
/// 保存键在屏幕下半区，错误只在顶部刷出来用户看不到，体感就是「点不动」。
class _BottomError extends StatelessWidget {
  const _BottomError(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = theme.colorScheme.error;
    return Container(
      key: const ValueKey('save-tx-error'),
      width: double.infinity,
      color: error.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(
        horizontal: LedgerLayout.pagePadding,
        vertical: 10,
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 18, color: error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(color: error),
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
