import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../core/money.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../add_tx/picker_field.dart';
import '../assets/asset_widgets.dart';
import '../perks/benefit_form_page.dart' show QuotaFields;
import '../perks/perk_widgets.dart';
import '../perks/quota_editor.dart';
import 'claim_mapping_sheet.dart' show PlatformMappingChips;
import 'import_node_tile.dart' show refPlatformName;
import 'import_undo.dart' show ImportNote;
import 'perk_import_draft.dart';

/// 手机上点一行：底部弹层里改（改的就是草稿本身，没有「保存」，关掉就好）。宽屏在右栏直接放 [ImportNodeForm]。
/// 弹层给软键盘让位（名称、价格、领取路径这些输入框在下半截，不让位会被键盘盖住）。
Future<void> showImportNodeSheet(BuildContext context, {required PerkImportDraft draft, required String nodeKey, required LedgerData ledger}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.85,
          maxChildSize: 0.95,
          builder: (context, scroll) => ListenableBuilder(
            listenable: draft,
            builder: (context, _) => ImportNodeForm(
              key: ValueKey('node-form-$nodeKey'),
              draft: draft,
              nodeKey: nodeKey,
              ledger: ledger,
              scrollController: scroll,
              onDone: () => Navigator.of(context).pop(),
            ),
          ),
        ),
      ),
    );

/// 原文依据：高亮模型说的那句在原文里的位置（前后各带 40 字）；找不到就照抄模型给的依据并说明没核实到。
/// 截图来源（[fromImages]）：显示它出自的那片截图（[image]，点开全屏、能双指放大；从本机恢复的草稿没有图就说一声，
/// 用 [imageLabel]「图 2 的第 1/3 片」说清楚是哪一片），外加模型读到的原字 —— 截图没法自动核对。
/// 从流水识别（[fromTransactions]）：写它来自哪几笔扣费（「腾讯视频 ¥30.00 × 7 次（…）」）。
class EvidenceBlock extends StatelessWidget {
  const EvidenceBlock({
    super.key,
    required this.source,
    required this.node,
    this.fromImages = false,
    this.fromTransactions = false,
    this.image,
    this.imageLabel,
  });

  final String source;
  final ImportNode node;
  final bool fromImages;
  final bool fromTransactions;
  final Uint8List? image;
  final String? imageLabel;

  static const int _context = 40;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = LedgerColors.of(context);
    final span = node.span;
    final Widget body;
    if (fromTransactions) {
      body = Text(
        node.ev == null ? '从流水里归出来的。' : '从流水里看到：${node.ev}',
        key: const ValueKey('evidence-transactions'),
        style: theme.textTheme.bodyMedium,
      );
    } else if (fromImages) {
      final img = image;
      final where = imageLabel ?? (node.img == null ? null : '第 ${node.img} 片');
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (img != null)
            Semantics(
              button: true,
              label: '点开放大看截图',
              child: InkWell(
                key: const ValueKey('evidence-image-open'),
                borderRadius: BorderRadius.circular(LedgerShapes.control),
                onTap: () => showEvidenceImage(context, img, title: where),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(LedgerShapes.control),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 480),
                    child: Image.memory(img, key: const ValueKey('evidence-image'), fit: BoxFit.contain, gaplessPlayback: true),
                  ),
                ),
              ),
            ),
          Padding(
            padding: EdgeInsets.only(top: img == null ? 0 : 6),
            child: Text(
              where == null
                  ? '模型没说出自哪一片截图。'
                  : (img == null ? '出自$where（恢复的草稿没带截图，对照原图看）。' : '出自$where，点图放大看。'),
              key: const ValueKey('evidence-image-where'),
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (node.ev != null)
            ImportNote(
              '模型读到的是「${node.ev}」，截图里的字没法自动核对，先看一眼。',
              key: const ValueKey('evidence-image-ev'),
              padding: const EdgeInsets.only(top: 6),
            ),
        ],
      );
    } else if (span != null && span[0] >= 0 && span[1] <= source.length && span[0] < span[1]) {
      final from = math.max(0, span[0] - _context);
      final to = math.min(source.length, span[1] + _context);
      body = Text.rich(
        TextSpan(
          style: theme.textTheme.bodyMedium,
          children: [
            TextSpan(text: '${from > 0 ? '…' : ''}${source.substring(from, span[0])}'),
            TextSpan(
              text: source.substring(span[0], span[1]),
              style: TextStyle(backgroundColor: theme.colorScheme.primaryContainer, fontWeight: FontWeight.w600),
            ),
            TextSpan(text: '${source.substring(span[1], to)}${to < source.length ? '…' : ''}'),
          ],
        ),
        key: const ValueKey('evidence-highlight'),
      );
    } else if (node.ev != null) {
      body = Text(
        '模型说依据是「${node.ev}」，原文里没找到这句，先核对一下。',
        key: const ValueKey('evidence-missing'),
        style: theme.textTheme.bodyMedium?.copyWith(color: colors.warning),
      );
    } else {
      body = Text('材料里没单独写这一项，是从别的条目里提到的名字补上的。', style: theme.textTheme.bodySmall);
    }
    return Container(
      margin: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 8, LedgerLayout.pagePadding, 0),
      padding: const EdgeInsets.all(LedgerLayout.itemGap),
      decoration: BoxDecoration(color: colors.surface2, borderRadius: BorderRadius.circular(LedgerShapes.control)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(fromTransactions ? '来自这些扣费' : '原文依据', key: const ValueKey('evidence-title'), style: theme.textTheme.labelMedium),
          const SizedBox(height: 6),
          body,
        ],
      ),
    );
  }
}

/// 全屏看一片截图：能双指 / 滚轮放大、拖动，左上角关掉。依据块里那张缩得太小，字看不清时点开看。
Future<void> showEvidenceImage(BuildContext context, Uint8List png, {String? title}) => showDialog<void>(
  context: context,
  useSafeArea: false,
  builder: (context) => Dialog.fullscreen(
    key: const ValueKey('evidence-image-viewer'),
    child: Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '关掉', icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
        title: Text(title == null ? '截图' : '截图 · $title'),
      ),
      body: InteractiveViewer(
        minScale: 1,
        maxScale: 6,
        child: Center(child: Image.memory(png, fit: BoxFit.contain, gaplessPlayback: true)),
      ),
    ),
  ),
);

/// 改一个节点：顶上原文依据，下面按类型的字段（改完立刻写回草稿、算作确认过），更新的还有逐字段差异的勾选。
class ImportNodeForm extends StatefulWidget {
  const ImportNodeForm({
    super.key,
    required this.draft,
    required this.nodeKey,
    required this.ledger,
    this.scrollController,
    this.onDone,
  });

  final PerkImportDraft draft;
  final String nodeKey;
  final LedgerData ledger;
  final ScrollController? scrollController;
  final VoidCallback? onDone;

  @override
  State<ImportNodeForm> createState() => _ImportNodeFormState();
}

class _ImportNodeFormState extends State<ImportNodeForm> {
  late final ImportNode _node = widget.draft.node(widget.nodeKey)!;
  late final TextEditingController _name = TextEditingController(text: _node.name);
  late final TextEditingController _tier = TextEditingController(text: jsonString(_node.fields['tier']));
  late final TextEditingController _money = TextEditingController(text: _moneyText(_moneyField));
  late final TextEditingController _claimHow = TextEditingController(text: jsonString(_node.fields['claimHow']));
  late final QuotaEditor _quota = QuotaEditor(PerkQuota.listFrom(_node.fields['quota']));
  String? _moneyError;

  PerkImportDraft get draft => widget.draft;

  /// 这一类节点的金额字段：会员的续费价、权益的面值、物品的价格。
  String get _moneyField => switch (_node.t) {
    ImportNode.membership => 'feeCents',
    ImportNode.benefit => 'faceValueCents',
    _ => 'priceCents',
  };

  String _moneyText(String field) {
    final cents = jsonIntOrNull(_node.fields[field]);
    return cents == null ? '' : Money.plain(cents).replaceAll(',', '');
  }

  @override
  void initState() {
    super.initState();
    _quota.addListener(_onQuota);
  }

  @override
  void dispose() {
    _quota.removeListener(_onQuota);
    _quota.dispose();
    _name.dispose();
    _tier.dispose();
    _money.dispose();
    _claimHow.dispose();
    super.dispose();
  }

  void _onQuota() {
    final read = _quota.read();
    if (read.quota != null) draft.setField(_node.key, 'quota', [for (final q in read.quota!) q.toJson()]);
  }

  void _set(String field, Object? value) => draft.setField(_node.key, field, value);

  void _onMoney(String text) {
    final cents = parseMoneyField(text);
    setState(() => _moneyError = cents == -1 ? '金额写错了' : null);
    if (cents != -1) _set(_moneyField, cents);
  }

  Future<void> _pickDay(String field, {bool past = false}) async {
    final current = localDate(jsonStringOrNull(_node.fields[field])) ?? DateTime.now();
    final Future<DateTime?> pick = past ? pickPastDay(context, initial: current) : pickAnyDay(context, initial: current);
    final picked = await pick;
    if (picked != null) _set(field, Dates.isoDate(picked));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = _node;
    return ListView(
      controller: widget.scrollController,
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 0, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  switch (n.t) {
                    ImportNode.platform => '平台',
                    ImportNode.membership => '会员卡',
                    ImportNode.benefit => n.fields['parent'] != null ? '「N 选 1」的选项' : '权益',
                    _ => '物品',
                  },
                  style: theme.textTheme.titleMedium,
                ),
              ),
              Checkbox(key: const ValueKey('node-checked'), value: n.checked, onChanged: (v) => draft.setChecked(n.key, v ?? false)),
              Text(
                !n.checked ? '不导入' : (n.t == ImportNode.item && n.matchKind == 'exists' ? '再建一件' : '导入'),
                style: theme.textTheme.bodyMedium,
              ),
              if (widget.onDone != null) TextButton(onPressed: widget.onDone, child: const Text('好了')),
            ],
          ),
        ),
        EvidenceBlock(
          source: draft.sourceText,
          node: n,
          fromImages: draft.fromImages,
          fromTransactions: draft.fromTransactions,
          image: draft.imageOf(n),
          imageLabel: draft.imageLabelOf(n),
        ),
        if (draft.errorOf(n.key) != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 8, LedgerLayout.pagePadding, 0),
            child: Text(draft.errorOf(n.key)!, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error)),
          ),
        if (n.action == 'pick' || n.matchKind == 'ambiguous' || n.match['archived'] == true) ..._pick(context),
        PickerField(
          label: '名称',
          error: draft.missingOf(n).contains('name') ? '要填' : null,
          child: TextField(key: const ValueKey('node-name'), controller: _name, onChanged: (v) => _set('name', v.trim().isEmpty ? null : v.trim())),
        ),
        ...switch (n.t) {
          ImportNode.platform => _platform(context),
          ImportNode.membership => _membership(context),
          ImportNode.benefit => _benefit(context),
          ImportNode.item => _item(context),
          _ => const <Widget>[],
        },
        if (n.diff.isNotEmpty) ..._diff(context),
      ],
    );
  }

  /// 同名多张要选；或者命中的是归档的那张（停了又重开）：恢复并更新它，还是另建一张。
  List<Widget> _pick(BuildContext context) {
    final chosen = _node.action == 'pick' ? '' : _node.targetId;
    void choose(String? v) => draft.pickMembership(_node.key, v == '' ? null : v);
    final archived = _node.match['archived'] == true;
    return [
      PickerField(
        label: archived ? '库里同名的这张已经归档（停了），这次？' : '库里有同名的好几张，这次更新哪张？',
        child: Column(
          children: [
            for (final c in _node.candidates)
              RadioListTile<String?>(
                key: ValueKey('node-pick-${c['id']}'),
                contentPadding: EdgeInsets.zero,
                value: jsonString(c['id']),
                groupValue: chosen,
                onChanged: choose,
                title: Text([
                  jsonString(c['name']),
                  if (jsonStringOrNull(c['tier']) != null) jsonString(c['tier']),
                  widget.ledger.member(jsonStringOrNull(c['memberId']))?.displayName ?? '全家共用',
                ].join(' · ')),
                subtitle: Text([
                  if (c['archived'] == true) '已归档，选它会恢复到本期',
                  jsonStringOrNull(c['expiresOn']) == null ? '长期有效' : '到期 ${c['expiresOn']}',
                ].join(' · ')),
              ),
            RadioListTile<String?>(
              key: const ValueKey('node-pick-new'),
              contentPadding: EdgeInsets.zero,
              value: null,
              groupValue: chosen,
              onChanged: choose,
              title: const Text('都不是，新建一张'),
            ),
          ],
        ),
      ),
    ];
  }

  /// 平台：是新平台，还是账本里已有的（和映射视图同一组选项）。挂着卡的平台并入已有的之后，卡要是那边已经有了，导入时并进原来那张。
  List<Widget> _platform(BuildContext context) {
    final claimOnly = draft.claimRows.any((r) => r.node == _node) && !draft.rootPlatforms.contains(_node);
    return [
      PickerField(
        label: '是新平台，还是账本里已有的',
        child: PlatformMappingChips(draft: draft, node: _node, ledger: widget.ledger, allowSelf: claimOnly),
      ),
      if (draft.rootPlatforms.contains(_node) && _node.action == 'merge')
        Padding(
          padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 8, LedgerLayout.pagePadding, 0),
          child: Text('下面的卡要是账本里这个平台下已经有同名的，导入时会并进原来那张，不会重复建。', style: Theme.of(context).textTheme.bodySmall),
        ),
    ];
  }

  /// 挂到哪个平台：草稿里的平台（新建的标一下）、账本里已有的平台（草稿里已经有节点并入它的就不重复列）。
  List<(String, String)> _platformOptions() => [
    for (final p in draft.platforms) ('key:${p.key}', p.action == 'merge' ? refPlatformName(draft, 'key:${p.key}', widget.ledger) ?? p.name : '${p.name}（新建）'),
    for (final p in widget.ledger.platforms)
      if (!p.archived && !draft.platforms.any((d) => d.action == 'merge' && d.targetId == p.id)) ('id:${p.id}', p.name),
  ];

  List<Widget> _membership(BuildContext context) {
    final f = _node.fields;
    final platforms = _platformOptions();
    return [
      // 新建的卡能改挂在哪个平台（模型没写平台时只能在这里补上）；更新已有的卡不搬平台。
      if (_node.action == 'create')
        PickerField(
          label: '平台',
          error: draft.missingOf(_node).contains('platform') ? '要选' : null,
          child: DropdownButton<String>(
            key: const ValueKey('node-platform'),
            isExpanded: true,
            hint: const Text('选一个平台'),
            value: platforms.any((o) => o.$1 == f['platform']) ? f['platform'] as String : null,
            items: [for (final (value, label) in platforms) DropdownMenuItem(value: value, child: Text(label, overflow: TextOverflow.ellipsis))],
            onChanged: (v) => _set('platform', v),
          ),
        ),
      PickerField(
        label: '档位（选填）',
        child: TextField(key: const ValueKey('node-tier'), controller: _tier, onChanged: (v) => _set('tier', v.trim().isEmpty ? null : v.trim())),
      ),
      PickerField(
        label: '续费价',
        error: _moneyError,
        child: TextField(
          key: const ValueKey('node-money'),
          controller: _money,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: _onMoney,
          decoration: const InputDecoration(prefixText: '¥ '),
        ),
      ),
      PickerField(
        label: '多久续一次',
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          for (final p in Membership.feePeriods)
            ChoiceChip(
              key: ValueKey('node-period-$p'),
              label: Text(Membership.feePeriodLabels[p]!),
              selected: f['feePeriod'] == p,
              onSelected: (_) => _set('feePeriod', p),
            ),
        ]),
      ),
      PickerField(
        label: '到期日（空 = 长期有效）',
        child: OptionalDayButton(
          key: const ValueKey('node-expires'),
          day: parseDay(jsonStringOrNull(f['expiresOn'])),
          emptyLabel: '长期有效',
          onPressed: () => _pickDay('expiresOn'),
          onClear: () => _set('expiresOn', null),
        ),
      ),
      PickerField(
        label: '续费方式',
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          for (final a in Membership.autoRenewModes)
            ChoiceChip(
              key: ValueKey('node-renew-$a'),
              label: Text(Membership.autoRenewLabels[a]!),
              selected: f['autoRenew'] == a,
              onSelected: (_) => _set('autoRenew', a),
            ),
        ]),
      ),
      // 从流水识别的卡带着扣费特征（导入后扣费线索靠它），这里只说一声，导入后在卡的「更多」里能改。
      if (PerkPayPattern.tryParse(f['payPattern'] is Map ? jsonMap(f['payPattern']) : null) case final pay?)
        Padding(
          padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 8, LedgerLayout.pagePadding, 0),
          child: Text(
            _payPatternSkipped
                ? '这次不改原来的扣费特征；要换成${payPatternLabel(pay)}，在下面的差异里勾上「扣费特征」。'
                : '扣费特征：${payPatternLabel(pay)}。导入后流水里再出现对得上的扣款，会提示「续上」；在卡的「更多」里能改。',
            key: const ValueKey('node-pay-pattern'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
    ];
  }

  /// 更新已有的卡、而差异里的「扣费特征」没勾（原来设过、不一样的默认不勾；也可能是人取消了）：导入不会写它。
  bool get _payPatternSkipped =>
      _node.action == 'update' && _node.diff.any((d) => d.field == 'payPattern' && !d.take);

  /// 领取平台的选项：会员本平台、草稿里的平台（新建的标一下）、库里已有的平台。
  List<(String?, String)> _claimOptions() => [
    (null, '就在会员本平台领'),
    for (final p in draft.platforms) ('key:${p.key}', p.action == 'merge' ? p.name : '${p.name}（新建）'),
    for (final p in widget.ledger.platforms)
      if (!p.archived && !draft.platforms.any((d) => d.action == 'merge' && d.targetId == p.id)) ('id:${p.id}', p.name),
  ];

  /// 归到哪张卡：草稿里的卡（新建的标一下）、账本里已有的卡（草稿里已经在更新它的就不重复列）。
  List<(String, String)> _cardOptions() => [
    for (final m in draft.memberships) ('key:${m.key}', m.action == 'update' ? m.name : '${m.name.isEmpty ? '未命名' : m.name}（新建）'),
    for (final m in widget.ledger.memberships)
      if (!m.archived && !draft.memberships.any((d) => d.action == 'update' && d.targetId == m.id)) ('id:${m.id}', m.title),
  ];

  List<Widget> _benefit(BuildContext context) {
    final f = _node.fields;
    final options = _claimOptions();
    final current = options.any((o) => o.$1 == f['claimPlatform']) ? f['claimPlatform'] as String? : null;
    final cards = _cardOptions();
    return [
      // 顶层的新建权益能改归到哪张卡（「未归属」的就在这里挂上）；选项跟着它的「N 选 1」，库里已有的权益不换卡。
      if (f['parent'] == null && _node.action == 'create')
        PickerField(
          label: '归到哪张卡',
          error: draft.missingOf(_node).contains('membership') ? '要选' : null,
          child: DropdownButton<String>(
            key: const ValueKey('node-membership'),
            isExpanded: true,
            hint: const Text('选一张卡'),
            value: cards.any((o) => o.$1 == f['membership']) ? f['membership'] as String : null,
            items: [for (final (value, label) in cards) DropdownMenuItem(value: value, child: Text(label, overflow: TextOverflow.ellipsis))],
            onChanged: (v) {
              if (v != null) draft.batchMoveTo([_node.key], v);
            },
          ),
        ),
      PickerField(
        label: '去哪领',
        child: DropdownButton<String?>(
          key: const ValueKey('node-claim'),
          isExpanded: true,
          value: current,
          items: [for (final (value, label) in options) DropdownMenuItem(value: value, child: Text(label))],
          onChanged: (v) => _set('claimPlatform', v),
        ),
      ),
      PickerField(
        label: '领取路径（选填）',
        child: TextField(key: const ValueKey('node-claim-how'), controller: _claimHow, onChanged: (v) => _set('claimHow', v.trim().isEmpty ? null : v.trim())),
      ),
      if (f['parent'] == null) ...[
        PickerField(
          label: '怎么算一次',
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            for (final flow in Benefit.flows)
              ChoiceChip(
                key: ValueKey('node-flow-$flow'),
                label: Text(Benefit.flowLabels[flow]!),
                selected: f['flow'] == flow,
                onSelected: (_) => _set('flow', flow),
              ),
          ]),
        ),
        QuotaFields(editor: _quota, anchor: jsonString(f['anchor'], Benefit.anchorCalendar), onAnchor: (v) => _set('anchor', v)),
      ],
      PickerField(
        label: '单次面值（选填）',
        error: _moneyError,
        child: TextField(
          key: const ValueKey('node-money'),
          controller: _money,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: _onMoney,
          decoration: const InputDecoration(prefixText: '¥ '),
        ),
      ),
      PickerField(
        label: '权益自己的有效期到（选填）',
        child: OptionalDayButton(
          key: const ValueKey('node-valid-until'),
          day: parseDay(jsonStringOrNull(f['validUntil'])),
          emptyLabel: '跟着会员卡',
          onPressed: () => _pickDay('validUntil'),
          onClear: () => _set('validUntil', null),
        ),
      ),
      if (PerkLimit.listFrom(f['limits']).isNotEmpty)
        PickerField(
          label: '限制条件',
          child: Wrap(spacing: 6, runSpacing: 6, children: [
            for (final l in PerkLimit.listFrom(f['limits'])) TagLabel(l.text),
          ]),
        ),
    ];
  }

  List<Widget> _item(BuildContext context) {
    final theme = Theme.of(context);
    final f = _node.fields;
    final category = jsonString(f['category'], 'other');
    final missing = draft.missingOf(_node);
    final candidates = draft.txCandidatesOf(_node);
    return [
      if (_node.matchKind == 'exists')
        Padding(
          padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 8, LedgerLayout.pagePadding, 0),
          child: Text(
            '账本里已经有同名同价的「${jsonString(_node.match['name'])}」，默认不导；真是又买了一件，勾上就照样新建。',
            style: theme.textTheme.bodySmall,
          ),
        ),
      if (_node.matchKind == 'near' && _node.badges.contains('maybe_dup'))
        PickerField(
          label: '账本里有相近的，是同一件吗',
          trailing: TextButton(
            key: const ValueKey('node-not-dup'),
            onPressed: () => draft.dismissBadge(_node.key, 'maybe_dup'),
            child: const Text('不是同一件'),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final c in _node.candidates)
                Text(
                  [
                    jsonString(c['name']),
                    if (jsonIntOrNull(c['priceCents']) != null) Money.format(jsonInt(c['priceCents'])),
                    if (jsonStringOrNull(c['purchasedOn']) != null) jsonString(c['purchasedOn']),
                  ].join(' · '),
                  style: theme.textTheme.bodyMedium,
                ),
              const SizedBox(height: 4),
              Text('是同一件就别勾（取消勾选），免得记两份。', style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      PickerField(
        label: '类别',
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          for (final c in Asset.categories)
            ChoiceChip(
              key: ValueKey('node-category-$c'),
              label: Text(Asset.categoryLabels[c]!),
              selected: category == c,
              onSelected: (_) {
                _set('category', c);
                final preset = presetByKey(jsonString(f['preset']));
                if (preset != null && !preset.categories.contains(c)) _set('preset', null);
              },
            ),
        ]),
      ),
      PickerField(
        label: '价格',
        error: _moneyError ?? (missing.contains('priceCents') ? '要填' : null),
        child: TextField(
          key: const ValueKey('node-money'),
          controller: _money,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: _onMoney,
          decoration: const InputDecoration(prefixText: '¥ '),
        ),
      ),
      PickerField(
        label: '哪天买的',
        error: missing.contains('purchasedOn') ? '要填' : null,
        child: OutlinedButton.icon(
          key: const ValueKey('node-purchased'),
          onPressed: () => _pickDay('purchasedOn', past: true),
          icon: const Icon(Icons.today_outlined, size: 18),
          label: Text(jsonStringOrNull(f['purchasedOn']) ?? '选日期'),
        ),
      ),
      if (presetsFor(category).isNotEmpty)
        PickerField(
          label: '估值预设（选填）',
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            for (final p in presetsFor(category))
              ChoiceChip(
                key: ValueKey('node-preset-${p.key}'),
                label: Text(p.label),
                selected: f['preset'] == p.key,
                onSelected: (on) => _set('preset', on ? p.key : null),
              ),
          ]),
        ),
      PickerField(
        label: '计入净资产',
        child: SegmentedButton<String>(
          key: const ValueKey('node-net-worth'),
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: Asset.netWorthAuto, label: Text('跟随类别')),
            ButtonSegment(value: Asset.netWorthInclude, label: Text('计入')),
            ButtonSegment(value: Asset.netWorthExclude, label: Text('不计入')),
          ],
          selected: {jsonString(f['netWorth'], Asset.netWorthAuto)},
          onSelectionChanged: (s) => _set('netWorth', s.first),
        ),
      ),
      PickerField(
        label: '和流水的关系',
        child: Column(children: [
          if (candidates.length < _node.txCandidates.length)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                '改了价格或日期，原来找到的流水对不上了，不再列出。',
                key: const ValueKey('node-link-stale'),
                style: theme.textTheme.bodySmall?.copyWith(color: LedgerColors.of(context).warning),
              ),
            ),
          for (final c in candidates)
            RadioListTile<String>(
              key: ValueKey('node-link-${c.id}'),
              contentPadding: EdgeInsets.zero,
              value: 'tx:${c.id}',
              groupValue: _linkValue,
              onChanged: _onLink,
              title: Text('关联这笔：${c.day} ${c.merchant}'),
              subtitle: Text('${Money.format(c.amountCents)} · 不另记账'),
            ),
          RadioListTile<String>(
            key: const ValueKey('node-link-none'),
            contentPadding: EdgeInsets.zero,
            value: 'none',
            groupValue: _linkValue,
            onChanged: _onLink,
            title: const Text('不记账'),
          ),
          RadioListTile<String>(
            key: const ValueKey('node-link-record'),
            contentPadding: EdgeInsets.zero,
            value: 'record',
            groupValue: _linkValue,
            onChanged: _onLink,
            title: const Text('同时记一笔支出'),
            subtitle: const Text('按价格和购买日期记，落在默认基金；这笔钱已经记过账就别选，免得记两遍'),
          ),
        ]),
      ),
    ];
  }

  String get _linkValue => _node.link == ItemLink.link ? 'tx:${_node.linkTransactionId}' : _node.link.name;

  void _onLink(String? v) {
    if (v == null) return;
    if (v.startsWith('tx:')) {
      draft.setLink(_node.key, ItemLink.link, transactionId: v.substring(3));
    } else {
      draft.setLink(_node.key, v == 'record' ? ItemLink.record : ItemLink.none);
    }
  }

  static const Map<String, String> _diffLabels = {
    'name': '名称',
    'tier': '档位',
    'kind': '类型',
    'feeCents': '续费价',
    'feePeriod': '续费周期',
    'termStartOn': '本期开始',
    'expiresOn': '到期日',
    'autoRenew': '续费方式',
    'claimPlatform': '领取平台',
    'claimHow': '领取路径',
    'claimUrl': '领取链接',
    'flow': '怎么算一次',
    'quota': '额度',
    'anchor': '起算点',
    'validFrom': '有效期开始',
    'validUntil': '有效期到',
    'faceValueCents': '面值',
    'limits': '限制条件',
    'isTrial': '试用',
    'payPattern': '扣费特征',
    'archived': '归档',
  };

  String _value(String field, Object? v) {
    if (field == 'archived') return v == true ? '已归档' : '恢复到本期';
    if (field == 'claimPlatform') {
      final p = draft.refNode(v);
      if (v == null || (p != null && draft.claimModeOf(p) == ClaimMode.self)) return '会员本平台';
      return refPlatformName(draft, v, widget.ledger) ?? '新建的平台';
    }
    if (v == null) return '空';
    if (field.endsWith('Cents')) return Money.format(jsonInt(v));
    if (field == 'quota') return quotaLabel(PerkQuota.listFrom(v));
    if (field == 'limits') return '${(v as List).length} 条';
    if (field == 'autoRenew') return Membership.autoRenewLabels[v] ?? v.toString();
    if (field == 'feePeriod') return Membership.feePeriodLabels[v] ?? v.toString();
    if (field == 'flow') return Benefit.flowLabels[v] ?? v.toString();
    if (field == 'payPattern') {
      final pay = v is Map ? PerkPayPattern.tryParse(jsonMap(v)) : null;
      return pay == null ? '空' : payPatternLabel(pay);
    }
    if (v is bool) return v ? '是' : '否';
    return v.toString();
  }

  /// 「原来 → 这次」；原来的值是服务端给的（差异的 old，或者预览里改了没列差异的字段时取 current），不知道就只写改成什么。
  String _diffLine(ImportDiff d) {
    final now = _value(d.field, d.newValue);
    return d.hasOld ? '${_value(d.field, d.oldValue)} → $now' : '改成 $now';
  }

  List<Widget> _diff(BuildContext context) => [
    PickerField(
      label: '和库里不一样的（勾上的才写入，不删）',
      child: Column(children: [
        for (final d in _node.diff)
          CheckboxListTile(
            key: ValueKey('node-diff-${d.field}'),
            contentPadding: EdgeInsets.zero,
            value: d.take,
            onChanged: (v) => draft.setDiffTake(_node.key, d.field, v ?? false),
            title: Text(_diffLabels[d.field] ?? d.field),
            subtitle: Text(_diffLine(d)),
          ),
      ]),
    ),
  ];
}
