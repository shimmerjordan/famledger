import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/shell.dart';
import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../core/ids.dart';
import '../../core/money.dart';
import '../../data/models/models.dart';
import '../../data/repos/assets_repo.dart';
import '../../data/repos/ledger_repo.dart';
import '../add_tx/account_picker.dart';
import '../add_tx/picker_field.dart';
import '../assets/asset_providers.dart';
import '../assets/asset_widgets.dart';
import '../widgets/widgets.dart';
import 'perk_providers.dart';
import 'perk_widgets.dart';
import 'platform_picker.dart';

/// 新建 / 编辑会员卡（spec §5「表单」）。只必填平台和名称；到期日可以留空（长期有效）；
/// 其余收进「更多」。日期都能选将来（[pickAnyDay]）。新建可选「同时记一笔支出」，默认不记。
class MembershipFormPage extends ConsumerStatefulWidget {
  const MembershipFormPage({super.key, this.id, this.initialPlatformId, this.initialSourceBenefitId});

  /// null = 新建。
  final String? id;

  /// 新建时预填（`/assets/memberships/new?platformId=&sourceBenefitId=`；P3「打卡后建子会员」从这进来）。
  final String? initialPlatformId;
  final String? initialSourceBenefitId;

  @override
  ConsumerState<MembershipFormPage> createState() => _MembershipFormPageState();
}

class _MembershipFormPageState extends ConsumerState<MembershipFormPage> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _tier = TextEditingController();
  final TextEditingController _fee = TextEditingController();
  final TextEditingController _paid = TextEditingController();
  final TextEditingController _remind = TextEditingController();
  final TextEditingController _note = TextEditingController();

  late String? _platformId = widget.initialPlatformId;
  late String? _sourceBenefitId = widget.initialSourceBenefitId;
  DateTime? _expiresOn;
  DateTime? _termStartOn;
  String _kind = 'membership';
  String? _memberId;
  String _feePeriod = 'year';
  String _autoRenew = 'unknown';
  bool _trial = false;
  String? _accountId;

  bool _record = false;
  String? _recordAccountId;
  String? _fundId;
  bool _fundTouched = false;
  String? _categoryId;

  bool _bound = false;
  bool _busy = false;
  String? _error;

  /// 幂等键：这张表单的每次重试都沿用它，回应丢了再点保存也只建一张卡、只记一笔。
  final String _clientId = newClientId();

  bool get _editing => widget.id != null;

  @override
  void dispose() {
    for (final c in [_name, _tier, _fee, _paid, _remind, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  void _bind(Membership m) {
    if (_bound) return;
    _bound = true;
    _platformId = m.platformId;
    _sourceBenefitId = m.sourceBenefitId;
    _name.text = m.name;
    _tier.text = m.tier ?? '';
    _fee.text = m.feeCents == null ? '' : Money.plain(m.feeCents!).replaceAll(',', '');
    _paid.text = m.termPaidCents == null ? '' : Money.plain(m.termPaidCents!).replaceAll(',', '');
    _remind.text = m.remindDays?.toString() ?? '';
    _note.text = m.note ?? '';
    _expiresOn = localDate(m.expiresOn);
    _termStartOn = localDate(m.termStartOn);
    _kind = m.kind;
    _memberId = m.memberId;
    _feePeriod = m.feePeriod;
    _autoRenew = m.autoRenew;
    _trial = m.isTrial;
    _accountId = m.accountId;
  }

  /// 编辑时「更多」里填过东西就直接展开。
  bool get _moreFilled =>
      _tier.text.isNotEmpty ||
      _kind != 'membership' ||
      _memberId != null ||
      _fee.text.isNotEmpty ||
      _paid.text.isNotEmpty ||
      _termStartOn != null ||
      _autoRenew != 'unknown' ||
      _trial ||
      _remind.text.isNotEmpty ||
      _sourceBenefitId != null ||
      _note.text.isNotEmpty;

  /// 「同时记一笔」记多少：本期实付，没填按续费价；填错或没有是 0。
  int get _recordAmount {
    final paid = parseMoneyField(_paid.text);
    if (paid != null) return paid < 0 ? 0 : paid;
    final fee = parseMoneyField(_fee.text);
    return fee == null || fee < 0 ? 0 : fee;
  }

  /// 那笔支出记在哪天：本期开始那天；没填或还没到（预约开通）记今天 —— 和服务端 memberships.js 的 onWrite 一样。
  String _recordDayLabel() {
    final today = localDay(ref.read(assetClockProvider)());
    final start = _termStartOn;
    if (start != null && !start.isAfter(today)) return '记在本期开始那天（${Dates.isoDate(start)}）';
    return start == null ? '记在今天（没填本期开始）' : '记在今天（本期还没开始）';
  }

  Future<void> _pickDay({required DateTime? current, required String help, required ValueChanged<DateTime> onPicked}) async {
    final picked = await pickAnyDay(context, initial: current ?? ref.read(assetClockProvider)(), help: help);
    if (picked != null) setState(() => onPicked(picked));
  }

  Future<void> _save(LedgerData ledger) async {
    final name = _name.text.trim();
    if (_platformId == null) return setState(() => _error = '先选一个平台（没有就新建一个）');
    if (name.isEmpty) return setState(() => _error = '给这张卡起个名字，例如「88VIP」');
    final fee = parseMoneyField(_fee.text);
    if (fee == -1) return setState(() => _error = '续费价填得不对，例如 88');
    final paid = parseMoneyField(_paid.text);
    if (paid == -1) return setState(() => _error = '本期实付填得不对，例如 0');
    int? remind;
    if (_remind.text.trim().isNotEmpty) {
      remind = int.tryParse(_remind.text.trim());
      if (remind == null || remind < 0 || remind > 365) return setState(() => _error = '到期提醒填 0 到 365 天，0 = 不提醒');
    }
    final start = _termStartOn;
    final end = _expiresOn;
    if (start != null && end != null && end.isBefore(start)) return setState(() => _error = '到期日不能早于本期开始');

    setState(() {
      _busy = true;
      _error = null;
    });
    final tier = _tier.text.trim();
    final note = _note.text.trim();
    final repo = ref.read(perksRepoProvider);
    try {
      if (_editing) {
        await repo.updateMembership(widget.id!, {
          'platformId': _platformId,
          'name': name,
          'tier': tier.isEmpty ? null : tier,
          'kind': _kind,
          'memberId': _memberId,
          'accountId': _kind == 'credit_card' ? _accountId : null,
          'feeCents': fee,
          'feePeriod': _feePeriod,
          'termPaidCents': paid,
          'termStartOn': start == null ? null : Dates.isoDate(start),
          'expiresOn': end == null ? null : Dates.isoDate(end),
          'autoRenew': _autoRenew,
          'isTrial': _trial,
          'remindDays': remind,
          'sourceBenefitId': _sourceBenefitId,
          'note': note.isEmpty ? null : note,
        });
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已保存')));
        context.canPop() ? context.pop() : context.go('/assets?tab=perks');
        return;
      }
      final record = _record && _recordAmount > 0;
      final body = <String, dynamic>{'platformId': _platformId, 'name': name, 'clientId': _clientId};
      if (tier.isNotEmpty) body['tier'] = tier;
      if (_kind != 'membership') body['kind'] = _kind;
      putIfNotNull(body, 'memberId', _memberId);
      if (_kind == 'credit_card') putIfNotNull(body, 'accountId', _accountId);
      putIfNotNull(body, 'feeCents', fee);
      if (_feePeriod != 'year') body['feePeriod'] = _feePeriod;
      putIfNotNull(body, 'termPaidCents', paid);
      if (start != null) body['termStartOn'] = Dates.isoDate(start);
      if (end != null) body['expiresOn'] = Dates.isoDate(end);
      if (_autoRenew != 'unknown') body['autoRenew'] = _autoRenew;
      if (_trial) body['isTrial'] = true;
      putIfNotNull(body, 'remindDays', remind);
      putIfNotNull(body, 'sourceBenefitId', _sourceBenefitId);
      if (note.isNotEmpty) body['note'] = note;
      if (record) {
        body['recordTransaction'] = AssetRecord(
          accountId: _recordAccountId,
          fundId: _fundTouched ? _fundId : defaultFundId(ledger),
          categoryId: _categoryId,
        ).toJson();
      }
      final made = await repo.createMembership(body);
      if (record) refreshMoneyViews(ref);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(record ? '记好了，也记了一笔支出' : '记好了，接着加权益吧')),
      );
      // 建完直接到详情：下一步就是往卡里加权益。宽屏的详情在会员权益 tab 的右栏：选中新卡、回到 tab。
      if (widthClassOf(context) == WidthClass.expanded) {
        ref.read(selectedMembershipProvider.notifier).state = made.id;
        context.canPop() ? context.pop() : context.go('/assets?tab=perks');
      } else {
        context.pushReplacement('/assets/memberships/${made.id}');
      }
    } catch (error) {
      if (mounted) setState(() => _error = describeWriteError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ledger = ref.watch(ledgerProvider).valueOrNull;
    final membership = _editing ? ledger?.membership(widget.id) : null;
    if (membership != null) _bind(membership);
    final title = _editing ? '编辑会员卡' : '记一张会员卡';
    if (ledger == null) {
      return Scaffold(appBar: AppBar(title: Text(title)), body: const SkeletonList(rows: 5));
    }
    if (_editing && membership == null) {
      return Scaffold(appBar: AppBar(title: Text(title)), body: const InlineError(message: '这张卡已经不在了。'));
    }
    final sources = [
      for (final b in ledger.activeBenefits)
        if (!b.isChoice && b.membershipId != widget.id && ledger.membership(b.membershipId) != null) b,
    ];

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: LayoutBuilder(
        builder: (context, box) => ListView(
          padding: readableInsets(box.maxWidth, maxWidth: 720).copyWith(bottom: LedgerLayout.groupGap),
          children: [
            PickerField(
              label: '平台',
              topGap: LedgerLayout.pagePadding,
              trailing: Text('会员挂在哪', style: theme.textTheme.bodySmall),
              child: PlatformPickerField(
                buttonKey: const ValueKey('membership-platform'),
                selectedId: _platformId,
                onChanged: (id) => setState(() => _platformId = id),
              ),
            ),
            PickerField(
              label: '名称',
              child: TextField(
                key: const ValueKey('membership-name'),
                controller: _name,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(hintText: '例如「88VIP」「京东 PLUS」「经典白」'),
              ),
            ),
            PickerField(
              label: '到期日（选填）',
              trailing: Text('不填 = 长期有效', style: theme.textTheme.bodySmall),
              child: OptionalDayButton(
                key: const ValueKey('membership-expires'),
                day: _expiresOn,
                emptyLabel: '长期有效',
                onPressed: () => _pickDay(current: _expiresOn, help: '哪天到期', onPicked: (d) => _expiresOn = d),
                onClear: () => setState(() => _expiresOn = null),
              ),
            ),
            const SizedBox(height: LedgerLayout.itemGap),
            ExpansionTile(
              key: const ValueKey('membership-more'),
              initiallyExpanded: (_editing && _moreFilled) || widget.initialSourceBenefitId != null,
              expansionAnimationStyle: MediaQuery.disableAnimationsOf(context)
                  ? AnimationStyle.noAnimation
                  : AnimationStyle(duration: const Duration(milliseconds: 200), curve: Easing.emphasizedDecelerate),
              shape: const Border(),
              collapsedShape: const Border(),
              tilePadding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
              expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
              title: const Text('更多'),
              subtitle: const Text('档位、持有人、续费价、本期、提醒……'),
              children: _more(context, ledger, sources),
            ),
            if (!_editing && _recordAmount > 0) ...[
              SwitchListTile(
                key: const ValueKey('membership-record'),
                value: _record,
                onChanged: (v) => setState(() => _record = v),
                title: const Text('同时记一笔支出'),
                subtitle: Text('记 ${Money.format(_recordAmount)}，${_recordDayLabel()}'),
              ),
              if (_record)
                RecordTargetFields(
                  ledger: ledger,
                  income: false,
                  accountId: _recordAccountId,
                  fundId: _fundTouched ? _fundId : defaultFundId(ledger),
                  categoryId: _categoryId,
                  onAccount: (id) => setState(() => _recordAccountId = id),
                  onFund: (id) => setState(() {
                    _fundTouched = true;
                    _fundId = id;
                  }),
                  onCategory: (id) => setState(() => _categoryId = id),
                ),
            ],
            const SizedBox(height: LedgerLayout.itemGap),
            FormSubmit(
              label: _editing ? '保存' : '记好了',
              busy: _busy,
              error: _error,
              onPressed: () => _save(ledger),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _more(BuildContext context, LedgerData ledger, List<Benefit> sources) {
    final theme = Theme.of(context);
    Widget chips<T>(String keyPrefix, Map<T, String> labels, T selected, ValueChanged<T> onSelected) => Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final e in labels.entries)
          ChoiceChip(
            key: ValueKey('$keyPrefix-${e.key}'),
            selected: e.key == selected,
            onSelected: (_) => setState(() => onSelected(e.key)),
            label: Text(e.value),
          ),
      ],
    );
    return [
      PickerField(
        label: '档位（选填）',
        topGap: 0,
        child: TextField(
          key: const ValueKey('membership-tier'),
          controller: _tier,
          decoration: const InputDecoration(hintText: '例如「年卡」「金卡」'),
        ),
      ),
      PickerField(label: '类型', child: chips('membership-kind', Membership.kindLabels, _kind, (v) => _kind = v)),
      PickerField(
        label: '持有人',
        child: chips<String?>(
          'membership-holder',
          {null: '全家共用', for (final m in ledger.activeMembers) m.id: m.label},
          _memberId,
          (v) => _memberId = v,
        ),
      ),
      PickerField(
        label: '续费价（选填）',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('membership-fee'),
              controller: _fee,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(prefixText: '¥ ', hintText: '88'),
            ),
            const SizedBox(height: 8),
            chips('membership-period', Membership.feePeriodLabels, _feePeriod, (v) => _feePeriod = v),
          ],
        ),
      ),
      PickerField(
        label: '本期实付（选填）',
        trailing: Text('不填按续费价', style: theme.textTheme.bodySmall),
        child: TextField(
          key: const ValueKey('membership-paid'),
          controller: _paid,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(prefixText: '¥ ', hintText: '免年费、试用填 0'),
        ),
      ),
      PickerField(
        label: '本期开始（选填）',
        child: OptionalDayButton(
          key: const ValueKey('membership-start'),
          day: _termStartOn,
          emptyLabel: '不设',
          onPressed: () => _pickDay(current: _termStartOn, help: '本期哪天开始', onPicked: (d) => _termStartOn = d),
          onClear: () => setState(() => _termStartOn = null),
        ),
      ),
      PickerField(label: '续费', child: chips('membership-renew', Membership.autoRenewLabels, _autoRenew, (v) => _autoRenew = v)),
      SwitchListTile(
        key: const ValueKey('membership-trial'),
        value: _trial,
        onChanged: (v) => setState(() => _trial = v),
        title: const Text('试用中'),
        subtitle: const Text('试用结束前多提醒一次'),
      ),
      PickerField(
        label: '到期提醒（选填）',
        trailing: Text('不填按默认，0 = 不提醒', style: theme.textTheme.bodySmall),
        child: TextField(
          key: const ValueKey('membership-remind'),
          controller: _remind,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: '7', suffixText: '天前'),
        ),
      ),
      if (_kind == 'credit_card')
        PickerField(
          label: '关联账户（选填）',
          child: AccountPicker(
            keyPrefix: 'membership-account',
            accounts: ledger.activeAccounts,
            selectedId: _accountId,
            onSelected: (id) => setState(() => _accountId = id),
          ),
        ),
      PickerField(
        label: '由哪项权益带来（选填）',
        trailing: Text('比如 88VIP 送的优酷会员', style: theme.textTheme.bodySmall),
        child: DropdownButtonFormField<String?>(
          key: const ValueKey('membership-source'),
          value: sources.any((b) => b.id == _sourceBenefitId) ? _sourceBenefitId : null,
          isExpanded: true,
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('不是别的卡带来的')),
            for (final b in sources)
              DropdownMenuItem<String?>(
                value: b.id,
                child: Text('${ledger.membership(b.membershipId)!.title} · ${b.name}', overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (v) => setState(() => _sourceBenefitId = v),
        ),
      ),
      PickerField(
        label: '备注（选填）',
        child: TextField(
          key: const ValueKey('membership-note'),
          controller: _note,
          maxLines: 2,
          decoration: const InputDecoration(hintText: '谁的账号、绑的哪张卡'),
        ),
      ),
      const SizedBox(height: LedgerLayout.itemGap),
    ];
  }
}
