import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/colors.dart';
import '../../core/dates.dart';
import '../../core/money.dart';
import '../../data/models/models.dart';
import '../transactions/tx_providers.dart';
import '../widgets/widgets.dart';
import 'manage_widgets.dart';

/// 新建/编辑账户。编辑时能直接填「现在余额」校准（差额进初始余额，不多记流水）、看这个账户的流水、删掉没流水的账户。
Future<void> showAccountForm(BuildContext context, {Account? account}) =>
    showManageSheet<void>(
      context,
      (context) => AccountFormSheet(account: account),
    );

class AccountFormSheet extends ConsumerStatefulWidget {
  const AccountFormSheet({super.key, this.account});

  final Account? account;

  @override
  ConsumerState<AccountFormSheet> createState() => _AccountFormSheetState();
}

class _AccountFormSheetState extends ConsumerState<AccountFormSheet> {
  late final TextEditingController _name = TextEditingController(
    text: widget.account?.name ?? '',
  );
  late final TextEditingController _balance = TextEditingController(
    text: widget.account == null
        ? ''
        : Money.plain(widget.account!.initialBalanceCents),
  );
  late final TextEditingController _tails = TextEditingController(
    text: _hintText('cardTails'),
  );
  late final TextEditingController _packages = TextEditingController(
    text: _hintText('packages'),
  );
  late final TextEditingController _keywords = TextEditingController(
    text: _hintText('keywords'),
  );

  late String _kind = widget.account?.kind ?? 'bank';

  /// 新建默认家庭基准币；有流水后服务端不让改（409 currency_locked，错误照常显示）。
  late String _currency = widget.account?.currency ?? ref.read(baseCurrencyProvider);
  late String? _owner = widget.account?.ownerMemberId;
  late String? _icon = widget.account?.icon;
  late String? _color = widget.account?.color;

  bool _busy = false;
  String? _error;

  bool get _isNew => widget.account == null;

  /// 「现在余额」：编辑时才有（要总览里的余额）。和初始余额联动：差的那一截是这个账户的流水合计。
  late final int? _now = _isNew
      ? null
      : ref.read(statsProvider(Dates.currentMonth())).valueOrNull?.accounts
          .where((a) => a.accountId == widget.account!.id)
          .firstOrNull
          ?.balanceCents;
  late final TextEditingController _current = TextEditingController(text: _now == null ? '' : Money.input(_now));

  /// 最后改的是「现在余额」：保存时发 currentBalanceCents，让服务端按当下的流水算初始余额（别用这边可能过时的差额）。
  bool _calibrating = false;
  bool _syncing = false;

  int get _flows => (_now ?? 0) - widget.account!.initialBalanceCents;

  void _onCurrentChanged(String text) {
    if (_syncing) return;
    final cents = Money.tryParse(text);
    _calibrating = true;
    if (cents == null) return;
    _syncing = true;
    _balance.text = Money.input(cents - _flows);
    _syncing = false;
  }

  void _onInitialChanged(String text) {
    if (_syncing || _now == null) return;
    final cents = Money.tryParse(text);
    _calibrating = false;
    if (cents == null) return;
    _syncing = true;
    _current.text = Money.input(cents + _flows);
    _syncing = false;
  }

  String _hintText(String key) {
    final raw = widget.account?.matchHints[key];
    if (raw is List) return raw.map((e) => '$e').join('，');
    return '';
  }

  /// 「6688，1234」「6688, 1234」都认，空的丢掉。
  List<String> _splitHints(TextEditingController controller) => controller.text
      .split(RegExp(r'[,，\s]+'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  @override
  void dispose() {
    _name.dispose();
    _balance.dispose();
    _current.dispose();
    _tails.dispose();
    _packages.dispose();
    _keywords.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '账户得有个名字，比如「工行储蓄卡」。');
      return;
    }
    final raw = _balance.text.trim();
    final cents = raw.isEmpty ? 0 : Money.tryParse(raw);
    if (cents == null) {
      setState(() => _error = '初始余额看不懂：$raw');
      return;
    }
    final current = _calibrating ? Money.tryParse(_current.text) : null;
    if (_calibrating && current == null) {
      setState(() => _error = '现在余额看不懂：${_current.text}（欠着就写负数）');
      return;
    }

    final hints = <String, dynamic>{};
    final tails = _splitHints(_tails);
    final packages = _splitHints(_packages);
    final keywords = _splitHints(_keywords);
    if (tails.isNotEmpty) hints['cardTails'] = tails;
    if (packages.isNotEmpty) hints['packages'] = packages;
    if (keywords.isNotEmpty) hints['keywords'] = keywords;

    final body = <String, dynamic>{
      'name': name,
      'kind': _kind,
      'ownerMemberId': _owner,
      if (current != null) 'currentBalanceCents': current else 'initialBalanceCents': cents,
      // 币种只在不是基准币（新建）或真改了（编辑）时才发：请求干净，也不会因为原样带回去碰到「有流水不能改」。
      if (_isNew ? _currency != ref.read(baseCurrencyProvider) : _currency != widget.account!.currency) 'currency': _currency,
      'icon': _icon,
      'color': _color,
      'matchHints': hints,
    };

    setState(() {
      _busy = true;
      _error = null;
    });
    final navigator = Navigator.of(context);
    final repo = ref.read(ledgerRepoProvider);
    try {
      if (_isNew) {
        await repo.createAccount(body);
      } else {
        await repo.updateAccount(widget.account!.id, body);
      }
      navigator.pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = describeError(e);
        });
      }
    }
  }

  /// 删账户：只有没流水的能删（服务端 409 account_in_use，原话照显示）；有流水的用「归档」。
  Future<void> _delete() async {
    final account = widget.account!;
    final ok = await confirmDestructive(
      context,
      title: '删掉「${account.name}」？',
      message: '只能删还没有流水的账户；有流水的请用「归档」，余额和流水都留着。',
      confirmLabel: '删掉',
    );
    if (!ok || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final navigator = Navigator.of(context);
    try {
      await ref.read(ledgerRepoProvider).deleteAccount(account.id);
      ref.invalidate(ledgerProvider);
      navigator.pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = describeError(e);
        });
      }
    }
  }

  /// 去账单页只看这个账户（账单是底部 tab：先关弹层再切过去）。
  void _showTransactions() {
    final id = widget.account!.id;
    final router = GoRouter.of(context);
    ref.read(txFilterProvider.notifier).state = TxFilter(accountId: id, limit: TxListController.pageSize);
    Navigator.of(context).pop();
    router.go('/transactions');
  }

  /// 归档 = `PATCH {archived}`，不是 `DELETE`。
  ///
  /// `DELETE /accounts/:id` 是软删（打墓碑，同步给各设备后这行就消失了），
  /// 而且账户下有已确认流水时服务端直接 409。归档要的是「记账时别再出现，
  /// 历史和余额都留着，随时能收回」—— 那是 `archived` 字段的事。
  Future<void> _setArchived(bool archived) async {
    final account = widget.account;
    if (account == null) return;
    if (archived) {
      final ok = await confirmDestructive(
        context,
        title: '归档「${account.name}」？',
        message: '归档后记账时不再出现，已有流水与余额都保留，随时可以取消归档。',
        confirmLabel: '归档',
      );
      if (!ok || !mounted) return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final navigator = Navigator.of(context);
    try {
      await ref.read(ledgerRepoProvider).updateAccount(account.id, {
        'archived': archived,
      });
      navigator.pop();
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final members = ref.watch(ledgerProvider).valueOrNull?.activeMembers ?? [];
    final tint = hexColor(_color);

    return ManageSheet(
      title: _isNew ? '添加账户' : '编辑账户',
      busy: _busy,
      error: _error,
      onSubmit: _submit,
      secondaryLabel: _isNew
          ? null
          : (widget.account!.archived ? '取消归档' : '归档'),
      onSecondary: _isNew
          ? null
          : () => _setArchived(!widget.account!.archived),
      secondaryDestructive: !(widget.account?.archived ?? false),
      children: [
        ManageField(
          label: '名称',
          child: TextField(
            controller: _name,
            autofocus: _isNew,
            decoration: const InputDecoration(hintText: '工行储蓄卡、我的支付宝…'),
          ),
        ),
        ManageField(
          label: '类型',
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final kind in Account.kinds)
                ChoiceChip(
                  label: Text(Account.kindLabels[kind] ?? kind),
                  selected: _kind == kind,
                  onSelected: (_) => setState(() => _kind = kind),
                ),
            ],
          ),
        ),
        ManagePicker<String>(
          label: '归属成员',
          value: _owner,
          options: [
            (null, '家庭共用'),
            for (final m in members) (m.id, m.label),
          ],
          onChanged: (value) => setState(() => _owner = value),
        ),
        if (_now != null)
          ManageField(
            label: '现在余额',
            child: TextField(
              key: const ValueKey('account-current-balance'),
              controller: _current,
              onChanged: _onCurrentChanged,
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              decoration: InputDecoration(
                prefixText: '${Money.symbolFor(_currency).trim()} ',
                helperText: '和实际对不上就直接改成实际的数：差额记进初始余额，不多记流水',
                helperMaxLines: 2,
              ),
            ),
          ),
        ManageField(
          label: '初始余额',
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('account-initial-balance'),
                  controller: _balance,
                  onChanged: _onInitialChanged,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  decoration: InputDecoration(
                    prefixText: '${Money.symbolFor(_currency).trim()} ',
                    hintText: '0.00',
                    helperText: [
                      _kind == 'credit' ? '信用卡已欠的钱填负数' : '开始记账那天这个账户里有多少',
                      // 有流水后服务端不让改币种（409 currency_locked，错误照常显示）。
                      if (!_isNew) '记过流水后币种不能改',
                    ].join('；'),
                    helperMaxLines: 2,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: CurrencyDropdown(
                  key: const ValueKey('account-currency'),
                  value: _currency,
                  keyPrefix: 'account-currency',
                  onChanged: (c) => setState(() => _currency = c),
                ),
              ),
            ],
          ),
        ),
        ManageIconPicker(
          value: _icon,
          color: tint,
          onChanged: (value) => setState(() => _icon = value),
        ),
        ManageColorPicker(
          value: _color,
          onChanged: (value) => setState(() => _color = value),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text('识别线索', style: theme.textTheme.titleMedium),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            '自动记账时用它们判断这笔钱走的是哪个账户。多个用逗号隔开。',
            style: theme.textTheme.bodySmall,
          ),
        ),
        ManageField(
          label: '卡尾号',
          child: TextField(
            controller: _tails,
            decoration: const InputDecoration(hintText: '6688，1234'),
          ),
        ),
        ManageField(
          label: '来源应用包名',
          child: TextField(
            controller: _packages,
            decoration: const InputDecoration(hintText: 'com.eg.android.AlipayGphone'),
          ),
        ),
        ManageField(
          label: '关键字',
          child: TextField(
            controller: _keywords,
            decoration: const InputDecoration(hintText: '工商银行，余额宝'),
          ),
        ),
        if (!_isNew)
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                key: const ValueKey('account-transactions'),
                onPressed: _busy ? null : _showTransactions,
                icon: const Icon(Icons.receipt_long_outlined, size: 18),
                label: const Text('看这个账户的流水'),
              ),
              TextButton.icon(
                key: const ValueKey('account-delete'),
                onPressed: _busy ? null : _delete,
                icon: Icon(Icons.delete_outline, size: 18, color: theme.colorScheme.error),
                label: Text('删除账户', style: TextStyle(color: theme.colorScheme.error)),
              ),
            ],
          ),
      ],
    );
  }
}
