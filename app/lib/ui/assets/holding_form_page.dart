import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../core/ids.dart';
import '../../core/money.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../add_tx/account_picker.dart';
import '../add_tx/picker_field.dart';
import '../widgets/widgets.dart';
import 'asset_providers.dart';
import 'asset_widgets.dart';

/// 服务端对代码的限制（会拼进行情 URL）。
final RegExp _codePattern = RegExp(r'^[0-9A-Za-z._-]{1,20}$');

/// 新建 / 编辑持仓。新建时默认「同时记一笔转账」：买基金是把钱挪到投资账户，不是花掉。
///
/// 编辑只改基础信息；份额与成本只能在详情页加仓/减仓。
///
/// 投资账户跟着转账走：净资产只给挂了账户的持仓补浮盈，前提是成本已经以转账记进那个账户
/// （`server/src/modules/holdings.js`）。所以新建时关掉转账就不让挂账户；编辑时有成本的持仓
/// 挂上要说清成本从哪个账户转进来、换账户会补一笔移仓转账、不能直接解绑。
class HoldingFormPage extends ConsumerStatefulWidget {
  const HoldingFormPage({super.key, this.id});

  final String? id;

  @override
  ConsumerState<HoldingFormPage> createState() => _HoldingFormPageState();
}

class _HoldingFormPageState extends ConsumerState<HoldingFormPage> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _code = TextEditingController();
  final TextEditingController _quantity = TextEditingController();
  final TextEditingController _cost = TextEditingController();
  final TextEditingController _price = TextEditingController();
  final TextEditingController _note = TextEditingController();

  String _market = 'fund';
  bool _auto = true;
  DateTime _openedOn = DateTime.now();
  String? _accountId;
  bool _record = true;
  String? _fromAccountId;

  /// 编辑前挂着、而且账户还在的那个；账户删了就当没挂（服务端也这么算）。
  String? _boundAccountId;
  bool _bound = false;

  /// 幂等键：这张表单的每次重试都沿用它，回应丢了再点保存也只开一次仓。
  final String _clientId = newClientId();
  bool _busy = false;
  String? _error;

  bool get _editing => widget.id != null;

  bool get _canAuto =>
      Holding.autoMarkets.contains(_market) && _code.text.trim().isNotEmpty;

  @override
  void dispose() {
    for (final c in [_name, _code, _quantity, _cost, _price, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  void _bind(Holding h, LedgerData ledger) {
    if (_bound) return;
    _bound = true;
    _name.text = h.name;
    _code.text = h.code ?? '';
    _market = Holding.markets.contains(h.market) ? h.market : 'other';
    _auto = h.isAuto;
    _openedOn = localDate(h.openedOn) ?? DateTime.now();
    _boundAccountId = ledger.account(h.accountId) == null ? null : h.accountId;
    _accountId = _boundAccountId;
    _note.text = h.note ?? '';
  }

  /// 编辑有成本的持仓时，这次换账户要不要补转账、补哪种。
  _AccountChange _changeFor(Holding? h) {
    if (h == null || h.costCents <= 0 || _accountId == _boundAccountId) {
      return _AccountChange.none;
    }
    if (_accountId == null) return _AccountChange.detach;
    return _boundAccountId == null
        ? _AccountChange.attach
        : _AccountChange.move;
  }

  Future<void> _pickDate() async {
    final picked = await pickPastDay(context, initial: _openedOn, help: '哪天买的');
    if (picked != null) setState(() => _openedOn = picked);
  }

  void _fail(String message) => setState(() => _error = message);

  Future<void> _save() async {
    final name = _name.text.trim();
    final code = _code.text.trim();
    if (name.isEmpty && code.isEmpty) return _fail('名称和代码至少填一个');
    if (code.isNotEmpty && !_codePattern.hasMatch(code)) {
      return _fail('代码只能是字母和数字，例如 161725');
    }
    final auto = _auto && _canAuto;
    final note = _note.text.trim();
    final repo = ref.read(holdingsRepoProvider);

    if (_editing) {
      final holding = ref.read(ledgerProvider).valueOrNull?.holding(widget.id);
      final change = _changeFor(holding);
      if (change == _AccountChange.detach) {
        return _fail('这笔持仓的成本记在投资账户里，不能直接解绑；可以换一个投资账户');
      }
      if (change == _AccountChange.attach && _fromAccountId == null) {
        return _fail('挂上投资账户要选成本从哪个账户转进来');
      }
      final cost = holding?.costCents ?? 0;
      return _submit(() async {
        await repo.edit(
          widget.id!,
          name: name,
          code: code,
          market: _market,
          autoPrice: auto,
          openedOn: Dates.isoDate(_openedOn),
          accountId: _accountId,
          note: note,
          fromAccountId: change == _AccountChange.attach
              ? _fromAccountId
              : null,
        );
        if (change == _AccountChange.none) return '已保存';
        refreshMoneyViews(ref);
        return change == _AccountChange.attach
            ? '已保存，也记了一笔 ${Money.format(cost)} 的转账'
            : '已保存，成本 ${Money.format(cost)} 跟着转到了新账户';
      });
    }

    final quantity = parseE4(_quantity.text);
    if (quantity == null || quantity <= 0) return _fail('份额填得不对，例如 1000');
    final cost = parseMoneyField(_cost.text);
    if (cost == null || cost < 0) return _fail('成本填得不对，总共花了多少，例如 10000');
    int? price;
    if (!auto && _price.text.trim().isNotEmpty) {
      price = parseE4(_price.text);
      if (price == null) return _fail('现价填得不对，例如 1.0230');
    }
    if (_record) {
      if (_accountId == null) return _fail('选一个投资账户，或关掉「同时记一笔转账」');
      if (_fromAccountId == null) return _fail('选一下钱从哪个账户转出');
    }

    return _submit(() async {
      await repo.create(
        name: name,
        code: code,
        market: _market,
        quantityE4: quantity,
        costCents: cost,
        openedOn: Dates.isoDate(_openedOn),
        autoPrice: auto,
        priceE4: price,
        // 不记转账就不挂：挂了账户的持仓净资产只补浮盈，成本没进账户就会凭空少一份。
        accountId: _record ? _accountId : null,
        note: note,
        fromAccountId: _record ? _fromAccountId : null,
        clientId: _clientId,
      );
      if (_record && cost > 0) refreshMoneyViews(ref);
      // 刚加的自动行情持仓还没价格，后台顺手拉一次：行情源慢起来要好几秒，不让保存按钮陪着转。
      if (auto) {
        final last = ref.read(quoteRefreshProvider.notifier);
        unawaited(
          repo
              .refresh(now: ref.read(assetClockProvider)())
              .then<void>((result) => last.state = result)
              .catchError((Object _) {}),
        );
      }
      return _record && cost > 0
          ? '记好了，也记了一笔 ${Money.format(cost)} 的转账'
          : '记好了';
    });
  }

  Future<void> _submit(Future<String> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final done = await action();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/assets?tab=invest');
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = describeWriteError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ledger = ref.watch(ledgerProvider).valueOrNull;
    final holding = _editing ? ledger?.holding(widget.id) : null;
    if (holding != null && ledger != null) _bind(holding, ledger);
    final title = _editing ? '编辑持仓' : '添加持仓';

    if (ledger == null) {
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: const SkeletonList(rows: 5),
      );
    }
    if (_editing && holding == null) {
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: const InlineError(message: '这笔持仓已经不在了。'),
      );
    }

    final investAccounts = ledger.activeAccounts
        .where((a) => a.kind == 'invest')
        .toList();
    final fromAccounts = ledger.activeAccounts
        .where((a) => a.kind != 'invest' && a.id != _accountId)
        .toList();
    final change = _changeFor(holding);
    // 有成本、挂着还在的账户：再点一下选中的芯片不是解绑，只能换到另一个。
    final locked =
        _editing && (holding?.costCents ?? 0) > 0 && _boundAccountId != null;

    final investField = PickerField(
      label: '投资账户',
      topGap: _editing ? LedgerLayout.groupGap : LedgerLayout.itemGap,
      trailing: Text('证券户、基金户', style: theme.textTheme.bodySmall),
      child: investAccounts.isEmpty
          ? _NoInvestAccount(onCreate: () => context.push('/settings/accounts'))
          : AccountPicker(
              keyPrefix: 'invest-account',
              accounts: investAccounts,
              selectedId: _accountId,
              onSelected: (id) {
                if (id == null && locked) return;
                setState(() {
                  _accountId = id;
                  if (_fromAccountId == id) _fromAccountId = null;
                });
              },
            ),
    );
    final fromField = PickerField(
      label: _editing ? '成本从哪个账户转进来' : '从哪个账户转出',
      topGap: LedgerLayout.itemGap,
      child: AccountPicker(
        keyPrefix: 'from-account',
        accounts: fromAccounts,
        selectedId: _fromAccountId,
        emptyHint: '还没有别的账户',
        onSelected: (id) => setState(() => _fromAccountId = id),
      ),
    );
    final cost = holding?.costCents ?? 0;
    final editHint = !_editing || cost <= 0
        ? null
        : switch (change) {
            _AccountChange.attach =>
              '挂上会补记一笔 ${Money.format(cost)} 的转账，把成本从下面选的账户转进来。'
                  '早就持有、钱不是从账本里的账户出的，就别挂',
            _AccountChange.move =>
              '换账户会补记一笔 ${Money.format(cost)} 的移仓转账，成本跟着挪过去',
            _ when locked => '成本记在这个账户里，不能直接解绑，可以换一个投资账户',
            _ => '没挂账户时市值整份算进净资产；挂上要补记成本从哪转进来',
          };

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: LayoutBuilder(
        builder: (context, box) => ListView(
          padding: readableInsets(
            box.maxWidth,
            maxWidth: 720,
          ).copyWith(bottom: LedgerLayout.groupGap),
          children: [
            PickerField(
              label: '名称',
              topGap: LedgerLayout.pagePadding,
              trailing: Text('填了代码可以留空', style: theme.textTheme.bodySmall),
              child: TextField(
                key: const ValueKey('holding-name'),
                controller: _name,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(hintText: '例如「沪深300ETF」'),
              ),
            ),
            PickerField(
              label: '代码',
              child: TextField(
                key: const ValueKey('holding-code'),
                controller: _code,
                textInputAction: TextInputAction.next,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(hintText: '161725'),
              ),
            ),
            PickerField(
              label: '市场',
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final m in Holding.markets)
                    ChoiceChip(
                      key: ValueKey('holding-market-$m'),
                      selected: _market == m,
                      onSelected: (_) => setState(() => _market = m),
                      label: Text(Holding.marketLabels[m]!),
                    ),
                ],
              ),
            ),
            const SizedBox(height: LedgerLayout.itemGap),
            SwitchListTile(
              key: const ValueKey('holding-auto'),
              value: _auto && _canAuto,
              onChanged: _canAuto ? (v) => setState(() => _auto = v) : null,
              title: const Text('自动行情'),
              subtitle: Text(
                _canAuto ? '进投资页时自动拉最新价（基金是上一交易日净值）' : '填了代码、选了基金或沪深北市场才能自动拉价',
              ),
            ),
            if (!_editing) ...[
              if (!(_auto && _canAuto))
                PickerField(
                  key: const ValueKey('holding-field-price'),
                  label: '现价（选填）',
                  trailing: Text('不填就先不算市值', style: theme.textTheme.bodySmall),
                  child: TextField(
                    key: const ValueKey('holding-price'),
                    controller: _price,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(hintText: '1.0230'),
                  ),
                ),
              // 上面的现价会随自动行情开关出没，带 key 才不会让下面输入框的状态跟着错位。
              PickerField(
                key: const ValueKey('holding-field-quantity'),
                label: '份额',
                child: TextField(
                  key: const ValueKey('holding-quantity'),
                  controller: _quantity,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    hintText: '1000.00',
                    suffixText: '份',
                  ),
                ),
              ),
              PickerField(
                key: const ValueKey('holding-field-cost'),
                label: '成本',
                trailing: Text('总共花了多少，含手续费', style: theme.textTheme.bodySmall),
                child: TextField(
                  key: const ValueKey('holding-cost'),
                  controller: _cost,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    prefixText: '¥ ',
                    hintText: '10000',
                  ),
                ),
              ),
            ],
            PickerField(
              label: '哪天买的',
              child: DayButton(day: _openedOn, onPressed: _pickDate),
            ),
            if (_editing) ...[
              investField,
              if (editHint != null)
                Padding(
                  key: const ValueKey('holding-account-hint'),
                  padding: const EdgeInsets.fromLTRB(
                    LedgerLayout.pagePadding,
                    LedgerLayout.itemGap,
                    LedgerLayout.pagePadding,
                    0,
                  ),
                  child: Text(editHint, style: theme.textTheme.bodySmall),
                ),
              if (change == _AccountChange.attach) fromField,
            ] else ...[
              const SizedBox(height: LedgerLayout.itemGap),
              SwitchListTile(
                key: const ValueKey('holding-record'),
                value: _record,
                onChanged: (v) => setState(() => _record = v),
                title: const Text('同时记一笔转账'),
                subtitle: Text(
                  !_record
                      ? '不记就不挂投资账户，市值整份算进净资产'
                      : investAccounts.isEmpty
                      ? '要先有一个投资账户，不记就关掉'
                      : '成本从转出账户挪到投资账户，不算支出',
                ),
              ),
              if (_record) ...[investField, fromField],
            ],
            PickerField(
              key: const ValueKey('holding-field-note'),
              label: '备注（选填）',
              child: TextField(
                controller: _note,
                maxLines: 2,
                decoration: const InputDecoration(hintText: '定投、谁的'),
              ),
            ),
            const SizedBox(height: LedgerLayout.itemGap),
            FormSubmit(
              label: _editing ? '保存' : '记好了',
              busy: _busy,
              error: _error,
              onPressed: _save,
            ),
          ],
        ),
      ),
    );
  }
}

class _NoInvestAccount extends StatelessWidget {
  const _NoInvestAccount({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          '还没有「投资」类型的账户，建一个才能记转账',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
      TextButton(onPressed: onCreate, child: const Text('去建一个')),
    ],
  );
}

/// 编辑时换投资账户的几种情形（只对有成本的持仓有意义）。
enum _AccountChange { none, attach, move, detach }
