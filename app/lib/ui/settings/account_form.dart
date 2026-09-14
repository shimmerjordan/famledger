import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/colors.dart';
import '../../core/money.dart';
import '../../data/models/models.dart';
import '../widgets/widgets.dart';
import 'manage_widgets.dart';

/// 新建/编辑账户。
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
  late String? _owner = widget.account?.ownerMemberId;
  late String? _icon = widget.account?.icon;
  late String? _color = widget.account?.color;

  bool _busy = false;
  String? _error;

  bool get _isNew => widget.account == null;

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
      'initialBalanceCents': cents,
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
        ManageField(
          label: '初始余额',
          child: TextField(
            controller: _balance,
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
              signed: true,
            ),
            decoration: InputDecoration(
              prefixText: '${Money.symbol} ',
              hintText: '0.00',
              helperText: _kind == 'credit' ? '信用卡已欠的钱填负数' : '开始记账那天这个账户里有多少',
            ),
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
      ],
    );
  }
}
