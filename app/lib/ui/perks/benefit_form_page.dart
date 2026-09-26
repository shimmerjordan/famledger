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
import '../add_tx/picker_field.dart';
import '../assets/asset_providers.dart';
import '../assets/asset_widgets.dart';
import '../widgets/widgets.dart';
import 'perk_providers.dart';
import 'perk_widgets.dart';
import 'platform_picker.dart';
import 'quota_editor.dart';

/// 一条限制条件的编辑行。
class _LimitRow {
  _LimitRow(this.type, String text) : text = TextEditingController(text: text);

  String type;
  final TextEditingController text;
}

/// 新建 / 编辑权益（spec §5「表单」）。额度用预设 chip，「高级」里能叠加上限、选起算点；
/// 算法（flow）是三个直白的选项。给 N 选 1 加选项时（[parentId]）不设额度和算法，跟着父权益。
/// 编辑时能归档 / 取消归档（归档 = 隐藏，spec §2）。
class BenefitFormPage extends ConsumerStatefulWidget {
  const BenefitFormPage({super.key, this.id, this.membershipId, this.parentId});

  /// null = 新建（此时 [membershipId] 必填）。
  final String? id;
  final String? membershipId;

  /// 新建选项时它的 N 选 1。
  final String? parentId;

  @override
  ConsumerState<BenefitFormPage> createState() => _BenefitFormPageState();
}

class _BenefitFormPageState extends ConsumerState<BenefitFormPage> {
  static const Map<String, String> _flowHints = {
    Benefit.flowClaim: '会员年卡、券这类：领到手就算用掉一次。',
    Benefit.flowUse: '贵宾厅、体检这类：真用了才算一次。',
    Benefit.flowClaimUse: '每月领 4 张的红包这类：先领再用，按用了几次算；本期还没领会提示「待领」。',
  };

  final TextEditingController _name = TextEditingController();
  final TextEditingController _claimHow = TextEditingController();
  final TextEditingController _claimUrl = TextEditingController();
  final TextEditingController _face = TextEditingController();
  final TextEditingController _myValue = TextEditingController();
  final TextEditingController _note = TextEditingController();
  final QuotaEditor _quota = QuotaEditor();
  final List<_LimitRow> _limits = [];

  String _kind = 'other';
  String? _claimPlatformId;
  String _flow = Benefit.flowClaim;
  String _anchor = Benefit.anchorCalendar;
  DateTime? _validFrom;
  DateTime? _validUntil;
  bool _remind = true;
  bool _archived = false;

  bool _bound = false;
  bool _busy = false;
  String? _error;

  /// 幂等键：这张表单的每次重试都沿用它，回应丢了再点保存也只加一条。
  final String _clientId = newClientId();

  bool get _editing => widget.id != null;

  @override
  void dispose() {
    for (final c in [_name, _claimHow, _claimUrl, _face, _myValue, _note]) {
      c.dispose();
    }
    for (final l in _limits) {
      l.text.dispose();
    }
    _quota.dispose();
    super.dispose();
  }

  void _bind(Benefit b) {
    if (_bound) return;
    _bound = true;
    _name.text = b.name;
    _claimHow.text = b.claimHow ?? '';
    _claimUrl.text = b.claimUrl ?? '';
    _face.text = b.faceValueCents == null ? '' : Money.plain(b.faceValueCents!).replaceAll(',', '');
    _myValue.text = b.myValueCents == null ? '' : Money.plain(b.myValueCents!).replaceAll(',', '');
    _note.text = b.note ?? '';
    _kind = b.kind;
    _claimPlatformId = b.claimPlatformId;
    _flow = b.flow;
    _anchor = b.anchor;
    _validFrom = localDate(b.validFrom);
    _validUntil = localDate(b.validUntil);
    _remind = b.remind;
    _archived = b.archived;
    for (final q in b.quota.take(QuotaEditor.maxRows)) {
      _quota.rows.add(QuotaRow(q.p, '${q.n}'));
    }
    for (final l in b.limits) {
      _limits.add(_LimitRow(l.type, l.text));
    }
  }

  Future<void> _pickDay({required DateTime? current, required String help, required ValueChanged<DateTime> onPicked}) async {
    final picked = await pickAnyDay(context, initial: current ?? ref.read(assetClockProvider)(), help: help);
    if (picked != null) setState(() => onPicked(picked));
  }

  Future<void> _save({required String membershipId, required bool option}) async {
    final name = _name.text.trim();
    if (name.isEmpty) return setState(() => _error = '给这项权益起个名字，例如「优酷年卡」');
    final quota = option ? const QuotaRead.ok([]) : _quota.read();
    if (quota.error != null) return setState(() => _error = quota.error);
    final url = _claimUrl.text.trim();
    if (url.isNotEmpty && !RegExp(r'^https?://\S+$', caseSensitive: false).hasMatch(url)) {
      return setState(() => _error = '链接要以 http:// 或 https:// 开头');
    }
    final face = parseMoneyField(_face.text);
    if (face == -1) return setState(() => _error = '面值填得不对，例如 25');
    final mine = parseMoneyField(_myValue.text);
    if (mine == -1) return setState(() => _error = '我的估值填得不对，例如 10');
    final from = _validFrom;
    final until = _validUntil;
    if (from != null && until != null && until.isBefore(from)) return setState(() => _error = '有效期的结束不能早于开始');
    final limits = [
      for (final l in _limits)
        if (l.text.text.trim().isNotEmpty) PerkLimit(l.type, l.text.text.trim()),
    ];
    if (limits.any((l) => l.text.length > 200)) return setState(() => _error = '每条限制最多 200 个字');

    final how = _claimHow.text.trim();
    final note = _note.text.trim();
    final body = <String, dynamic>{
      'name': name,
      'kind': _kind,
      'claimPlatformId': _claimPlatformId,
      'claimHow': how.isEmpty ? null : how,
      'claimUrl': url.isEmpty ? null : url,
      if (!option) 'flow': _flow,
      if (!option) 'quota': [for (final q in quota.quota!) q.toJson()],
      if (!option) 'anchor': _anchor,
      'validFrom': from == null ? null : Dates.isoDate(from),
      'validUntil': until == null ? null : Dates.isoDate(until),
      'faceValueCents': face,
      'myValueCents': mine,
      'limits': [for (final l in limits) l.toJson()],
      'remind': _remind,
      'note': note.isEmpty ? null : note,
    };
    setState(() {
      _busy = true;
      _error = null;
    });
    final repo = ref.read(perksRepoProvider);
    try {
      if (_editing) {
        await repo.updateBenefit(widget.id!, {...body, 'archived': _archived});
      } else {
        // 新建只带填了的：null 和空列表交给服务端默认，请求体干净。
        body.removeWhere((k, v) => v == null || (v is List && v.isEmpty && k == 'limits'));
        await repo.createBenefit({
          'membershipId': membershipId,
          if (widget.parentId != null) 'parentId': widget.parentId,
          ...body,
          'clientId': _clientId,
        });
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_editing ? '已保存' : '加好了')));
      context.canPop() ? context.pop() : context.go('/assets/memberships/$membershipId');
    } catch (error) {
      if (mounted) setState(() => _error = describeWriteError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirmDelete(Benefit b, String detail) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删掉「${b.name}」？'),
        content: Text(detail),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('算了')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('删掉')),
        ],
      ),
    );
    return ok == true;
  }

  /// 删除确认里的那句话：连带删掉几个选项、几条打卡记录；由它（或它的选项）带出来的卡会留着、只是不再关联
  /// （服务端删权益时总会把它们的 sourceBenefitId 置空）。[changed] = 服务端说有本地不知道的子项。
  static String _deleteDetail({required int options, required int events, required List<String> derived, bool changed = false}) {
    final parts = [if (options > 0) '$options 个选项', if (events > 0) '$events 条打卡记录'];
    final what = parts.isEmpty ? '删掉后找不回来。' : '它下面的 ${parts.join('和')}会一起删掉。';
    final kept = derived.isEmpty ? '' : '由它带出来的${derived.map((t) => '「$t」').join('、')}会留着，只是不再关联。';
    return '${changed ? '别的设备刚给它加了选项或打卡记录。' : ''}$what$kept';
  }

  Future<void> _delete(LedgerData data, Benefit b) async {
    final family = {b.id, for (final o in data.benefits) if (o.parentId == b.id) o.id};
    final options = family.length - 1;
    final events = data.benefitEvents.where((e) => family.contains(e.benefitId)).length;
    final derived = [
      for (final m in data.memberships)
        if (family.contains(m.sourceBenefitId)) m.title,
    ];
    if (!await _confirmDelete(b, _deleteDetail(options: options, events: events, derived: derived)) || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final repo = ref.read(perksRepoProvider);
    try {
      try {
        await repo.deleteBenefit(b.id, cascade: options > 0 || events > 0);
      } on ApiException catch (e) {
        // 本地不知道的子项（别的设备刚加的选项、打卡记录）：按服务端给的数说清楚，再问一次。
        if (e.code != 'has_children' || !mounted) rethrow;
        int count(String key) => e.details[key] is int ? e.details[key] as int : 0;
        final detail = _deleteDetail(options: count('options'), events: count('events'), derived: derived, changed: true);
        if (!await _confirmDelete(b, detail)) {
          if (mounted) setState(() => _busy = false);
          return;
        }
        await repo.deleteBenefit(b.id, cascade: true);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已删掉')));
      context.canPop() ? context.pop() : context.go('/assets/memberships/${b.membershipId}');
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = describeError(error);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(ledgerProvider).valueOrNull;
    final benefit = _editing ? data?.benefit(widget.id) : null;
    if (benefit != null) _bind(benefit);
    final parent = data?.benefit(benefit?.parentId ?? widget.parentId);
    final option = parent != null;
    final title = _editing ? '编辑权益' : (option ? '加一个选项' : '加一项权益');
    if (data == null) {
      return Scaffold(appBar: AppBar(title: Text(title)), body: const SkeletonList(rows: 5));
    }
    final membership = data.membership(benefit?.membershipId ?? widget.membershipId);
    if ((_editing && benefit == null) || membership == null) {
      return Scaffold(appBar: AppBar(title: Text(title)), body: const InlineError(message: '这项权益或它的会员卡已经不在了。'));
    }
    final home = platformLabel(data.platform(membership.platformId));
    // 选项没写领取平台时跟它的 N 选 1（perk_groups.dart effectiveClaimPlatformId），N 选 1 也没写才是会员本平台。
    final inherited = parent?.claimPlatformId;
    final noneLabel = parent == null || inherited == null
        ? '会员本平台（$home）'
        : '跟着「${parent.name}」（${platformLabel(data.platform(inherited))}）';

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          if (benefit != null)
            IconButton(
              key: const ValueKey('benefit-delete'),
              tooltip: '删除',
              icon: const Icon(Icons.delete_outline),
              onPressed: _busy ? null : () => _delete(data, benefit),
            ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, box) => ListView(
          padding: readableInsets(box.maxWidth, maxWidth: 720).copyWith(bottom: LedgerLayout.groupGap),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, LedgerLayout.pagePadding, LedgerLayout.pagePadding, 0),
              child: Text(
                option ? '${membership.title} ·「${parent.name}」的一个选项：额度和算法跟着它' : membership.title,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            PickerField(
              label: '名称',
              topGap: LedgerLayout.itemGap,
              child: TextField(
                key: const ValueKey('benefit-name'),
                controller: _name,
                decoration: const InputDecoration(hintText: '例如「优酷年卡」「每月 4 张红包」「贵宾厅」'),
              ),
            ),
            PickerField(
              label: '类型',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final e in Benefit.kindLabels.entries)
                        if (!(option && e.key == Benefit.kindChoice))
                          ChoiceChip(
                            key: ValueKey('benefit-kind-${e.key}'),
                            selected: _kind == e.key,
                            onSelected: (_) => setState(() => _kind = e.key),
                            label: Text(e.value),
                          ),
                    ],
                  ),
                  if (_kind == Benefit.kindChoice) ...[
                    const SizedBox(height: 8),
                    Text(
                      'N 选 1：先建这一条（额度写能选几次，比如每年 1 次），保存后在会员详情里往下加选项。',
                      key: const ValueKey('benefit-choice-hint'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
            PickerField(
              label: '在哪领',
              trailing: _kind == Benefit.kindChoice
                  ? Text('选项没写时跟这里', key: const ValueKey('benefit-claim-choice-hint'), style: Theme.of(context).textTheme.bodySmall)
                  : null,
              child: PlatformPickerField(
                buttonKey: const ValueKey('benefit-claim-platform'),
                selectedId: _claimPlatformId,
                noneLabel: noneLabel,
                onChanged: (id) => setState(() => _claimPlatformId = id),
              ),
            ),
            PickerField(
              label: '领取路径（选填）',
              child: Column(
                children: [
                  TextField(
                    key: const ValueKey('benefit-claim-how'),
                    controller: _claimHow,
                    decoration: const InputDecoration(hintText: '例如「优酷App › 我的 › 88VIP 专区」'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const ValueKey('benefit-claim-url'),
                    controller: _claimUrl,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(hintText: '领取链接 https://…'),
                  ),
                ],
              ),
            ),
            if (!option) ...[
              PickerField(
                label: '怎么算一次',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final e in Benefit.flowLabels.entries)
                          ChoiceChip(
                            key: ValueKey('benefit-flow-${e.key}'),
                            selected: _flow == e.key,
                            onSelected: (_) => setState(() => _flow = e.key),
                            label: Text(e.value),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(_flowHints[_flow]!, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              QuotaFields(editor: _quota, anchor: _anchor, onAnchor: (v) => setState(() => _anchor = v)),
            ],
            PickerField(
              label: '有效期（选填）',
              trailing: Text('权益自己的起止，可以在将来', style: Theme.of(context).textTheme.bodySmall),
              child: Column(
                children: [
                  OptionalDayButton(
                    key: const ValueKey('benefit-valid-from'),
                    day: _validFrom,
                    emptyLabel: '开始：不限',
                    onPressed: () => _pickDay(current: _validFrom, help: '从哪天起能用', onPicked: (d) => _validFrom = d),
                    onClear: () => setState(() => _validFrom = null),
                  ),
                  const SizedBox(height: 8),
                  OptionalDayButton(
                    key: const ValueKey('benefit-valid-until'),
                    day: _validUntil,
                    emptyLabel: '结束：不限',
                    onPressed: () => _pickDay(current: _validUntil, help: '用到哪天', onPicked: (d) => _validUntil = d),
                    onClear: () => setState(() => _validUntil = null),
                  ),
                ],
              ),
            ),
            PickerField(
              label: '一次值多少（选填）',
              trailing: Text('算回本用', style: Theme.of(context).textTheme.bodySmall),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('benefit-face'),
                      controller: _face,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: '面值', prefixText: '¥ '),
                    ),
                  ),
                  const SizedBox(width: LedgerLayout.itemGap),
                  Expanded(
                    child: TextField(
                      key: const ValueKey('benefit-my-value'),
                      controller: _myValue,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: '我觉得值', prefixText: '¥ '),
                    ),
                  ),
                ],
              ),
            ),
            PickerField(
              label: '限制条件（选填）',
              trailing: Text('一条一条写', style: Theme.of(context).textTheme.bodySmall),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < _limits.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          DropdownButton<String>(
                            key: ValueKey('benefit-limit-type-$i'),
                            value: _limits[i].type,
                            items: [
                              for (final e in PerkLimit.typeLabels.entries)
                                DropdownMenuItem(value: e.key, child: Text(e.value)),
                            ],
                            onChanged: (v) => setState(() => _limits[i].type = v ?? 'other'),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              key: ValueKey('benefit-limit-text-$i'),
                              controller: _limits[i].text,
                              decoration: const InputDecoration(hintText: '例如「满 99 可用」'),
                            ),
                          ),
                          IconButton(
                            tooltip: '去掉这条',
                            onPressed: () => setState(() => _limits.removeAt(i).text.dispose()),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                    ),
                  if (_limits.length < 12)
                    TextButton.icon(
                      key: const ValueKey('benefit-limit-add'),
                      onPressed: () => setState(() => _limits.add(_LimitRow('other', ''))),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('加一条限制'),
                    ),
                ],
              ),
            ),
            SwitchListTile(
              key: const ValueKey('benefit-remind'),
              value: _remind,
              onChanged: (v) => setState(() => _remind = v),
              title: const Text('本期没领完时提醒我'),
            ),
            if (benefit != null)
              SwitchListTile(
                key: const ValueKey('benefit-archived'),
                value: _archived,
                onChanged: (v) => setState(() => _archived = v),
                title: const Text('归档'),
                subtitle: Text(
                  benefit.isChoice ? '连同它的选项收进会员详情底部的「已归档」，随时能取消' : '收进会员详情底部的「已归档」，随时能取消',
                ),
              ),
            PickerField(
              label: '备注（选填）',
              child: TextField(key: const ValueKey('benefit-note'), controller: _note, maxLines: 2),
            ),
            const SizedBox(height: LedgerLayout.itemGap),
            FormSubmit(
              label: _editing ? '保存' : '加好了',
              busy: _busy,
              error: _error,
              onPressed: () => _save(membershipId: membership.id, option: option),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「额度」：五个预设 chip（每月 / 每年要填次数），「高级」里叠加上限、选起算点。
/// 权益表单和 AI 导入预览里改权益（ui/perk_import/import_node_form.dart）共用。
class QuotaFields extends StatelessWidget {
  const QuotaFields({super.key, required this.editor, required this.anchor, required this.onAnchor});

  static const Map<QuotaPreset, String> presetLabels = {
    QuotaPreset.monthly: '每月 N 次',
    QuotaPreset.yearly: '每年 N 次',
    QuotaPreset.termOnce: '会籍期内 1 次',
    QuotaPreset.once: '一次性',
    QuotaPreset.unlimited: '不限次',
  };

  final QuotaEditor editor;
  final String anchor;
  final ValueChanged<String> onAnchor;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: editor,
    builder: (context, _) {
      final theme = Theme.of(context);
      final preset = editor.preset;
      final counted = preset == QuotaPreset.monthly || preset == QuotaPreset.yearly;
      final periodic = editor.rows.any((r) => r.period == 'month' || r.period == 'quarter' || r.period == 'year');
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PickerField(
            label: '额度',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final e in presetLabels.entries)
                      ChoiceChip(
                        key: ValueKey('quota-preset-${e.key.name}'),
                        selected: preset == e.key,
                        onSelected: (_) => editor.applyPreset(e.key),
                        label: Text(e.value),
                      ),
                  ],
                ),
                if (counted) ...[
                  const SizedBox(height: 8),
                  TextField(
                    key: const ValueKey('quota-count'),
                    controller: editor.rows.first.count,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => editor.touched(),
                    decoration: InputDecoration(
                      prefixText: preset == QuotaPreset.monthly ? '每月 ' : '每年 ',
                      suffixText: '次',
                      hintText: '4',
                    ),
                  ),
                ],
                if (preset == QuotaPreset.custom) ...[
                  const SizedBox(height: 8),
                  Text('自定义额度：${quotaLabel(editor.read().quota ?? const [])}，在「高级」里改', style: theme.textTheme.bodySmall),
                ],
              ],
            ),
          ),
          ExpansionTile(
            key: const ValueKey('quota-advanced'),
            initiallyExpanded: editor.rows.length > 1 || preset == QuotaPreset.custom || anchor != Benefit.anchorCalendar,
            expansionAnimationStyle: MediaQuery.disableAnimationsOf(context)
                ? AnimationStyle.noAnimation
                : AnimationStyle(duration: const Duration(milliseconds: 200), curve: Easing.emphasizedDecelerate),
            shape: const Border(),
            collapsedShape: const Border(),
            tilePadding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
            childrenPadding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
            expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
            title: const Text('高级'),
            subtitle: const Text('叠加上限（如每年 6 次且每月最多 2 次）、起算点'),
            children: [
              for (var i = editor.extraStart; i < editor.rows.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      // 第一条（自定义额度）直接读「每周 最多 2 次」；叠加的读「另外 每年 最多 6 次」。
                      if (i > 0) ...[
                        Text('另外', style: theme.textTheme.bodyMedium),
                        const SizedBox(width: 8),
                      ],
                      DropdownButton<String>(
                        key: ValueKey('quota-period-$i'),
                        value: editor.rows[i].period,
                        items: [
                          for (final p in QuotaEditor.extraPeriods)
                            DropdownMenuItem(value: p, child: Text(PerkQuota.periodLabels[p]!)),
                        ],
                        onChanged: (v) => editor.setPeriod(i, v ?? 'year'),
                      ),
                      const SizedBox(width: 8),
                      Text('最多', style: theme.textTheme.bodyMedium),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          key: ValueKey('quota-extra-count-$i'),
                          controller: editor.rows[i].count,
                          keyboardType: TextInputType.number,
                          onChanged: (_) => editor.touched(),
                          decoration: const InputDecoration(suffixText: '次', hintText: '6'),
                        ),
                      ),
                      IconButton(tooltip: '去掉这条', onPressed: () => editor.removeAt(i), icon: const Icon(Icons.close)),
                    ],
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('quota-add-extra'),
                  onPressed: editor.canAddExtra ? editor.addExtra : null,
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(editor.rows.isEmpty ? '先选一个额度，再叠加上限' : '再加一条上限（最多 3 条）'),
                ),
              ),
              if (periodic) ...[
                const SizedBox(height: 8),
                Text('按月、季、年的额度从哪天算起', style: theme.textTheme.labelMedium),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      key: const ValueKey('benefit-anchor-calendar'),
                      selected: anchor == Benefit.anchorCalendar,
                      onSelected: (_) => onAnchor(Benefit.anchorCalendar),
                      label: const Text('自然月/季/年'),
                    ),
                    ChoiceChip(
                      key: const ValueKey('benefit-anchor-term'),
                      selected: anchor == Benefit.anchorTerm,
                      onSelected: (_) => onAnchor(Benefit.anchorTerm),
                      label: const Text('从会员本期开始算'),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: LedgerLayout.itemGap),
            ],
          ),
        ],
      );
    },
  );
}
