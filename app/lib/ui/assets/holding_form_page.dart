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
import 'invest_tab.dart';

/// 服务端对代码的限制（会拼进行情 URL）。
final RegExp _codePattern = RegExp(r'^[0-9A-Za-z._-]{1,20}$');

/// 新建 / 编辑一笔理财。先挑品类（基金、股票、活期、定期……），下面的字段跟着记法变：
/// 份额类填份额、成本、价格；定期类填本金、年化、到期日；金额类填本金和当前金额。
/// 新建时默认「同时记一笔转账」：买理财是把钱挪到投资账户，不是花掉。
///
/// 编辑只改基础信息；份额、本金只能在详情页存取 / 加减仓。
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
  final TextEditingController _institution = TextEditingController();
  final TextEditingController _rate = TextEditingController();
  final TextEditingController _rateMax = TextEditingController();
  final TextEditingController _value = TextEditingController();

  String _kind = Holding.kindFund;
  DateTime? _maturesOn;
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

  InvestMode get _mode => Holding.modeOf(_kind);

  bool get _canAuto =>
      _mode == InvestMode.unit &&
      _kind != Holding.kindGold &&
      Holding.autoMarkets.contains(_market) &&
      _code.text.trim().isNotEmpty;

  /// 份额类各品类能选的市场：基金是场外 / 场内，股票是沪深北和其他（港美股），黄金不选。
  List<String> get _marketsForKind => switch (_kind) {
    Holding.kindFund => const ['fund', 'sh', 'sz'],
    Holding.kindStock => const ['sh', 'sz', 'bj', 'other'],
    _ => const ['other'],
  };

  @override
  void dispose() {
    for (final c in [_name, _code, _quantity, _cost, _price, _note, _institution, _rate, _rateMax, _value]) {
      c.dispose();
    }
    super.dispose();
  }

  /// 换品类：市场跟着换到这一类的默认值；跨记法时份额类的字段不带过去（没用）。
  void _setKind(String kind) {
    setState(() {
      _kind = kind;
      final markets = _marketsForKind;
      if (!markets.contains(_market)) _market = markets.first;
      _auto = _mode == InvestMode.unit && kind != Holding.kindGold && _auto;
      _error = null;
    });
  }

  /// 期限预设：定期按月，逆回购按天；点了从起息日往后推。
  static const Map<String, int> _termMonths = {'3 个月': 3, '6 个月': 6, '1 年': 12, '2 年': 24, '3 年': 36, '5 年': 60};
  static const Map<String, int> _repoDays = {'1 天': 1, '2 天': 2, '3 天': 3, '7 天': 7, '14 天': 14, '28 天': 28, '91 天': 91};

  DateTime _addMonths(DateTime from, int months) {
    final total = from.year * 12 + from.month - 1 + months;
    final year = total ~/ 12;
    final month = total % 12 + 1;
    final last = DateTime(year, month + 1, 0).day;
    return DateTime(year, month, from.day > last ? last : from.day);
  }

  void _bind(Holding h, LedgerData ledger) {
    if (_bound) return;
    _bound = true;
    _kind = h.kind;
    _institution.text = h.institution ?? '';
    _rate.text = h.rateE6 == null ? '' : formatRateE6(h.rateE6!).replaceAll('%', '');
    _rateMax.text = h.rateMaxE6 == null ? '' : formatRateE6(h.rateMaxE6!).replaceAll('%', '');
    _maturesOn = localDate(h.maturesOn);
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
    final picked = await pickPastDay(context, initial: _openedOn, help: _openedLabel);
    if (picked != null) setState(() => _openedOn = picked);
  }

  Future<void> _pickMaturity() async {
    final picked = await pickAnyDay(
      context,
      initial: _maturesOn ?? _addMonths(_openedOn, 12),
      first: _openedOn,
      help: '哪天到期',
    );
    if (picked != null) setState(() => _maturesOn = picked);
  }

  String get _openedLabel => switch (_mode) {
    InvestMode.unit => '哪天买的',
    InvestMode.deposit => '起息日',
    InvestMode.balance => '哪天存的',
  };

  /// 年化输入框：空 = 不填；填了就得认得出。返回 (值, 错误)。
  (int?, String?) _readRate(TextEditingController c, String what) {
    final t = c.text.trim();
    if (t.isEmpty) return (null, null);
    final v = parseRateE6(t);
    if (v == null || v > 1000000) return (null, '$what填得不对，例如 2.15');
    return (v, null);
  }

  void _fail(String message) => setState(() => _error = message);

  Future<void> _save() async {
    final name = _name.text.trim();
    final code = _code.text.trim();
    final unit = _mode == InvestMode.unit;
    if (unit) {
      if (name.isEmpty && code.isEmpty) return _fail('名称和代码至少填一个');
      if (code.isNotEmpty && !_codePattern.hasMatch(code)) {
        return _fail('代码只能是字母和数字，例如 161725');
      }
    } else if (name.isEmpty) {
      return _fail('起个名字，例如「招行三年定期」「余额宝」');
    }
    final (rate, rateError) = _readRate(_rate, '年化');
    if (rateError != null) return _fail(rateError);
    final (rateMax, rateMaxError) = _readRate(_rateMax, '最高年化');
    if (rateMaxError != null) return _fail(rateMaxError);
    if (rate != null && rateMax != null && rateMax < rate) return _fail('最高年化不能低于保底');
    if (_mode == InvestMode.deposit) {
      if (_maturesOn == null) return _fail('选一下到期日');
      if (_maturesOn!.isBefore(_openedOn)) return _fail('到期日不能早于起息日');
    }
    final maturesOn = _mode == InvestMode.deposit ? Dates.isoDate(_maturesOn!) : null;
    final auto = _auto && _canAuto;
    final note = _note.text.trim();
    final institution = _institution.text.trim();
    final repo = ref.read(holdingsRepoProvider);

    if (_editing) {
      final holding = ref.read(ledgerProvider).valueOrNull?.holding(widget.id);
      final change = _changeFor(holding);
      if (change == _AccountChange.detach) {
        return _fail('这笔理财的成本记在投资账户里，不能直接解绑；可以换一个投资账户');
      }
      if (change == _AccountChange.attach && _fromAccountId == null) {
        return _fail('挂上投资账户要选成本从哪个账户转进来');
      }
      final cost = holding?.costCents ?? 0;
      return _submit(() async {
        await repo.edit(
          widget.id!,
          name: name,
          kind: _kind,
          code: unit ? code : null,
          market: _market,
          autoPrice: auto,
          openedOn: Dates.isoDate(_openedOn),
          accountId: _accountId,
          institution: institution,
          rateE6: rate,
          rateMaxE6: _kind == Holding.kindStructured ? rateMax : null,
          maturesOn: maturesOn,
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

    int quantity = Holding.heldE4;
    int? price;
    if (unit) {
      final q = parseE4(_quantity.text);
      if (q == null || q <= 0) return _fail(_kind == Holding.kindGold ? '克数填得不对，例如 20' : '份额填得不对，例如 1000');
      quantity = q;
    }
    final cost = parseMoneyField(_cost.text);
    if (cost == null || cost < 0 || (_mode == InvestMode.deposit && cost == 0)) {
      return _fail(switch (_mode) {
        InvestMode.unit => '成本填得不对，总共花了多少，例如 10000',
        InvestMode.deposit => '本金填得不对，例如 50000',
        InvestMode.balance => '本金填得不对，存了多少，例如 10000',
      });
    }
    if (unit && !auto && _price.text.trim().isNotEmpty) {
      price = parseE4(_price.text);
      if (price == null) return _fail('现价填得不对，例如 1.0230');
    }
    int? value;
    if (_mode == InvestMode.balance && _value.text.trim().isNotEmpty) {
      value = parseMoneyField(_value.text);
      if (value == null || value < 0) return _fail('当前金额填得不对，例如 10230.55');
    }
    if (_record) {
      if (_accountId == null) return _fail('选一个投资账户，或关掉「同时记一笔转账」');
      if (_fromAccountId == null) return _fail('选一下钱从哪个账户转出');
    }

    return _submit(() async {
      await repo.create(
        name: name,
        kind: _kind,
        code: unit ? code : null,
        market: _market,
        quantityE4: quantity,
        costCents: cost,
        openedOn: Dates.isoDate(_openedOn),
        autoPrice: auto,
        priceE4: price,
        // 不记转账就不挂：挂了账户的理财净资产只补收益，成本没进账户就会凭空少一份。
        accountId: _record ? _accountId : null,
        institution: institution,
        rateE6: rate,
        rateMaxE6: _kind == Holding.kindStructured ? rateMax : null,
        maturesOn: maturesOn,
        valueCents: value,
        note: note,
        fromAccountId: _record ? _fromAccountId : null,
        clientId: _clientId,
      );
      if (_record && cost > 0) refreshMoneyViews(ref);
      refreshNetWorth(ref);
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

  /// 份额类：代码、市场、自动行情、现价、份额、成本、买入日。
  List<Widget> _unitFields(ThemeData theme) {
    final gold = _kind == Holding.kindGold;
    final unitName = gold ? '克' : '份';
    return [
      if (!gold) ...[
        PickerField(
          label: '代码',
          child: TextField(
            key: const ValueKey('holding-code'),
            controller: _code,
            textInputAction: TextInputAction.next,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(hintText: _kind == Holding.kindFund ? '005827' : '600036'),
          ),
        ),
        PickerField(
          label: '市场',
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in _marketsForKind)
                ChoiceChip(
                  key: ValueKey('holding-market-$m'),
                  selected: _market == m,
                  onSelected: (_) => setState(() => _market = m),
                  label: Text(_kind == Holding.kindFund && m != 'fund' ? '场内（${Holding.marketLabels[m]}）' : Holding.marketLabels[m]!),
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
            _canAuto ? '进理财页时自动拉最新价（基金是上一交易日净值）' : '填了代码、选了场外基金或沪深北市场才能自动拉价',
          ),
        ),
      ],
      if (!_editing) ...[
        if (!(_auto && _canAuto))
          PickerField(
            key: const ValueKey('holding-field-price'),
            label: gold ? '金价（选填）' : '现价（选填）',
            trailing: Text('不填就先不算市值', style: theme.textTheme.bodySmall),
            child: TextField(
              key: const ValueKey('holding-price'),
              controller: _price,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(hintText: gold ? '560.00' : '1.0230', suffixText: gold ? '元/克' : null),
            ),
          ),
        // 上面的现价会随自动行情开关出没，带 key 才不会让下面输入框的状态跟着错位。
        PickerField(
          key: const ValueKey('holding-field-quantity'),
          label: gold ? '克数' : '份额',
          child: TextField(
            key: const ValueKey('holding-quantity'),
            controller: _quantity,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(hintText: gold ? '20' : '1000.00', suffixText: unitName),
          ),
        ),
        PickerField(
          key: const ValueKey('holding-field-cost'),
          label: '成本',
          trailing: Text('总共花了多少，含手续费', style: theme.textTheme.bodySmall),
          child: TextField(
            key: const ValueKey('holding-cost'),
            controller: _cost,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(prefixText: '¥ ', hintText: '10000'),
          ),
        ),
      ],
      PickerField(
        label: _openedLabel,
        child: DayButton(day: _openedOn, onPressed: _pickDate),
      ),
    ];
  }

  /// 定期类：本金、年化（结构性多一个最高）、起息日、期限 / 到期日。
  List<Widget> _depositFields(ThemeData theme) {
    final structured = _kind == Holding.kindStructured;
    final repo = _kind == Holding.kindRepo;
    final presets = repo ? _repoDays : _termMonths;
    return [
      if (!_editing)
        PickerField(
          key: const ValueKey('holding-field-cost'),
          label: '本金',
          child: TextField(
            key: const ValueKey('holding-cost'),
            controller: _cost,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(prefixText: '¥ ', hintText: '50000'),
          ),
        ),
      PickerField(
        label: structured ? '年化（保底 ~ 最高）' : repo ? '年化' : '年利率',
        trailing: Text('按天算利息', style: theme.textTheme.bodySmall),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('holding-rate'),
                controller: _rate,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(hintText: structured ? '保底 1.50' : '2.15', suffixText: '%'),
              ),
            ),
            if (structured) ...[
              const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('~')),
              Expanded(
                child: TextField(
                  key: const ValueKey('holding-rate-max'),
                  controller: _rateMax,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(hintText: '最高 3.00', suffixText: '%'),
                ),
              ),
            ],
          ],
        ),
      ),
      PickerField(
        label: _openedLabel,
        child: DayButton(day: _openedOn, onPressed: _pickDate),
      ),
      PickerField(
        label: '到期日',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final e in presets.entries)
                  ChoiceChip(
                    key: ValueKey('holding-term-${e.value}'),
                    selected: _maturesOn != null &&
                        _maturesOn == (repo ? _openedOn.add(Duration(days: e.value)) : _addMonths(_openedOn, e.value)),
                    onSelected: (_) => setState(
                      () => _maturesOn = repo ? _openedOn.add(Duration(days: e.value)) : _addMonths(_openedOn, e.value),
                    ),
                    label: Text(e.key),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const ValueKey('holding-matures'),
                onPressed: _pickMaturity,
                icon: const Icon(Icons.event_outlined, size: 18),
                label: Text(_maturesOn == null ? '选到期日' : Dates.dayLabel(_maturesOn!)),
              ),
            ),
          ],
        ),
      ),
    ];
  }

  /// 金额类：本金、当前金额（选填，不填 = 本金）、年化（选填，只是看看）、存入日。
  List<Widget> _balanceFields(ThemeData theme) => [
    if (!_editing) ...[
      PickerField(
        key: const ValueKey('holding-field-cost'),
        label: _kind == Holding.kindInsurance ? '已交保费' : '本金',
        trailing: Text(_kind == Holding.kindInsurance ? '到今天一共交了多少' : '存了多少', style: theme.textTheme.bodySmall),
        child: TextField(
          key: const ValueKey('holding-cost'),
          controller: _cost,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(prefixText: '¥ ', hintText: '10000'),
        ),
      ),
      PickerField(
        label: _kind == Holding.kindInsurance ? '现金价值（选填）' : '当前金额（选填）',
        trailing: Text('不填就按本金，回头在详情里更新', style: theme.textTheme.bodySmall),
        child: TextField(
          key: const ValueKey('holding-value'),
          controller: _value,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(prefixText: '¥ ', hintText: '10230.55'),
        ),
      ),
    ],
    PickerField(
      label: _kind == Holding.kindDemand ? '七日年化（选填）' : '年化（选填）',
      trailing: Text('只是看看，收益按金额算', style: theme.textTheme.bodySmall),
      child: TextField(
        key: const ValueKey('holding-rate'),
        controller: _rate,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(hintText: '1.80', suffixText: '%'),
      ),
    ),
    PickerField(
      label: _openedLabel,
      child: DayButton(day: _openedOn, onPressed: _pickDate),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ledger = ref.watch(ledgerProvider).valueOrNull;
    final holding = _editing ? ledger?.holding(widget.id) : null;
    if (holding != null && ledger != null) _bind(holding, ledger);
    final title = _editing ? '编辑理财' : '添加理财';

    if (ledger == null) {
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: const SkeletonList(rows: 5),
      );
    }
    if (_editing && holding == null) {
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: const InlineError(message: '这笔理财已经不在了。'),
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
      // 宽屏两列：左边是这笔理财本身（品类、名称、金额、利率、日期），右边是挂账户、转账和备注。
      body: FormColumns(
        main: [
            PickerField(
              label: '品类',
              topGap: LedgerLayout.pagePadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final kind in Holding.kinds)
                        // 编辑时只能在同一种记法里换（服务端也拦）。
                        if (!_editing || Holding.modeOf(kind) == Holding.modeOf(holding!.kind))
                          ChoiceChip(
                            key: ValueKey('holding-kind-$kind'),
                            selected: _kind == kind,
                            onSelected: (_) => _setKind(kind),
                            // 选中时不换成对勾：图标就是这个品类的记号，底色变了已经说明选中了。
                            showCheckmark: false,
                            avatar: Icon(holdingIcon(kind), size: 16),
                            label: Text(Holding.kindLabels[kind]!),
                          ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    Holding.kindHints[_kind] ?? '',
                    key: const ValueKey('holding-kind-hint'),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            PickerField(
              label: '名称',
              trailing: _mode == InvestMode.unit && _kind != Holding.kindGold
                  ? Text('填了代码可以留空', style: theme.textTheme.bodySmall)
                  : null,
              child: TextField(
                key: const ValueKey('holding-name'),
                controller: _name,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  hintText: switch (_kind) {
                    Holding.kindFund => '例如「易方达蓝筹精选」',
                    Holding.kindStock => '例如「招商银行」「沪深300ETF」',
                    Holding.kindDemand => '例如「余额宝」「零钱通」',
                    Holding.kindFixed => '例如「招行三年定期」',
                    Holding.kindStructured => '例如「招行结构性存款 91 天」',
                    Holding.kindWealth => '例如「朝朝宝」「招银理财稳健」',
                    Holding.kindBond => '例如「2026 年第一期储蓄国债」',
                    Holding.kindRepo => '例如「GC007」',
                    Holding.kindInsurance => '例如「增额终身寿」「教育金」',
                    Holding.kindGold => '例如「积存金」「金条」',
                    _ => '起个名字',
                  },
                ),
              ),
            ),
            if (_mode != InvestMode.unit)
              PickerField(
                label: '在哪买的（选填）',
                child: TextField(
                  key: const ValueKey('holding-institution'),
                  controller: _institution,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(hintText: '例如「招商银行」「支付宝」'),
                ),
              ),
            if (_mode == InvestMode.unit) ..._unitFields(theme),
            if (_mode == InvestMode.deposit) ..._depositFields(theme),
            if (_mode == InvestMode.balance) ..._balanceFields(theme),
        ],
        side: [
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
        ],
        bottom: [
            const SizedBox(height: LedgerLayout.itemGap),
            FormSubmit(
              label: _editing ? '保存' : '记好了',
              busy: _busy,
              error: _error,
              onPressed: _save,
            ),
        ],
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
