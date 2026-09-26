import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../assets/asset_widgets.dart';
import '../perks/benefit_form_page.dart' show QuotaFields;
import '../perks/quota_editor.dart';
import 'perk_import_draft.dart';

// 预览里长按多选后的批量操作（spec §6）：设领取平台、设周期、设价值、移到另一张卡下（取消勾选直接在底栏做）。
// 都只改草稿，不往库里写。

Future<T?> _sheet<T>(BuildContext context, String title, List<Widget> children) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  useSafeArea: true,
  builder: (context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 0, LedgerLayout.pagePadding, 8),
          child: Text(title, style: Theme.of(context).textTheme.titleMedium),
        ),
        ...children,
      ],
    ),
  ),
);

/// 设领取平台：草稿里的平台、账本里已有的平台，或「会员本平台」。
Future<void> showBatchClaimSheet(BuildContext context, {required PerkImportDraft draft, required List<String> keys, required LedgerData ledger}) async {
  const self = '__self__';
  final picked = await _sheet<String>(context, '这 ${keys.length} 项去哪领', [
    ListTile(key: const ValueKey('batch-claim-self'), title: const Text('就在会员本平台领'), onTap: () => Navigator.of(context).pop(self)),
    for (final p in draft.platforms)
      ListTile(
        key: ValueKey('batch-claim-key:${p.key}'),
        title: Text(p.name),
        subtitle: Text(p.action == 'merge' ? '账本里已有' : '这次新建'),
        onTap: () => Navigator.of(context).pop('key:${p.key}'),
      ),
    for (final p in ledger.platforms)
      if (!p.archived && !draft.platforms.any((d) => d.action == 'merge' && d.targetId == p.id))
        ListTile(key: ValueKey('batch-claim-id:${p.id}'), title: Text(p.name), subtitle: const Text('账本里已有'), onTap: () => Navigator.of(context).pop('id:${p.id}')),
  ]);
  if (picked != null) draft.batchClaimPlatform(keys, picked == self ? null : picked);
}

/// 设周期：五个预设 chip 和叠加上限，和权益表单同一套（QuotaFields）。
Future<void> showBatchQuotaSheet(BuildContext context, {required PerkImportDraft draft, required List<String> keys}) async {
  final quota = await showModalBottomSheet<List<PerkQuota>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => _QuotaSheet(count: keys.length),
  );
  if (quota != null) draft.batchQuota(keys, quota);
}

/// 设价值：单次面值（元），空 = 清掉。
Future<void> showBatchValueSheet(BuildContext context, {required PerkImportDraft draft, required List<String> keys}) async {
  // 弹层回 (cents,)：记录里的 null 是「清掉面值」，整个结果 null 是划掉没选。
  final picked = await showModalBottomSheet<(int?,)>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => _ValueSheet(count: keys.length),
  );
  if (picked != null) draft.batchFaceValue(keys, picked.$1);
}

/// 弹层自己拿着编辑器：弹层收起的动画里还在用它，不能在 await 回来时就 dispose。
class _QuotaSheet extends StatefulWidget {
  const _QuotaSheet({required this.count});

  final int count;

  @override
  State<_QuotaSheet> createState() => _QuotaSheetState();
}

class _QuotaSheetState extends State<_QuotaSheet> {
  final QuotaEditor _editor = QuotaEditor();

  @override
  void dispose() {
    _editor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView(
    shrinkWrap: true,
    padding: const EdgeInsets.only(bottom: 24),
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 0, LedgerLayout.pagePadding, 0),
        child: Text('这 ${widget.count} 项的额度', style: Theme.of(context).textTheme.titleMedium),
      ),
      QuotaFields(editor: _editor, anchor: Benefit.anchorCalendar, onAnchor: (_) {}),
      Padding(
        padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, LedgerLayout.itemGap, LedgerLayout.pagePadding, 0),
        child: FilledButton(
          key: const ValueKey('batch-quota-apply'),
          onPressed: () {
            final read = _editor.read();
            if (read.quota != null) Navigator.of(context).pop(read.quota);
          },
          child: const Text('用这个额度'),
        ),
      ),
    ],
  );
}

class _ValueSheet extends StatefulWidget {
  const _ValueSheet({required this.count});

  final int count;

  @override
  State<_ValueSheet> createState() => _ValueSheetState();
}

class _ValueSheetState extends State<_ValueSheet> {
  final TextEditingController _text = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 0, LedgerLayout.pagePadding, 24),
      children: [
        Text('这 ${widget.count} 项每次值多少', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('batch-value-field'),
          controller: _text,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(prefixText: '¥ ', hintText: '空着 = 不写面值', errorText: _error),
        ),
        const SizedBox(height: LedgerLayout.itemGap),
        FilledButton(
          key: const ValueKey('batch-value-apply'),
          onPressed: () {
            final cents = parseMoneyField(_text.text);
            if (cents == -1) {
              setState(() => _error = '金额写错了');
              return;
            }
            Navigator.of(context).pop((cents,));
          },
          child: const Text('用这个价值'),
        ),
      ],
    ),
  );
}

/// 移到另一张卡下：草稿里的卡、账本里已有的卡。回跳过了几项（库里已有的权益导入时不换卡）。
Future<int> showBatchMoveSheet(BuildContext context, {required PerkImportDraft draft, required List<String> keys, required LedgerData ledger}) async {
  final picked = await _sheet<String>(context, '这 ${keys.length} 项归到哪张卡', [
    for (final m in draft.memberships)
      ListTile(
        key: ValueKey('batch-move-key:${m.key}'),
        title: Text(m.name),
        subtitle: Text(m.action == 'update' ? '更新账本里那张' : '这次新建'),
        onTap: () => Navigator.of(context).pop('key:${m.key}'),
      ),
    for (final m in ledger.memberships)
      if (!m.archived && !draft.memberships.any((d) => d.action == 'update' && d.targetId == m.id))
        ListTile(
          key: ValueKey('batch-move-id:${m.id}'),
          title: Text(m.title),
          subtitle: Text(ledger.platform(m.platformId)?.name ?? ''),
          onTap: () => Navigator.of(context).pop('id:${m.id}'),
        ),
  ]);
  return picked == null ? 0 : draft.batchMoveTo(keys, picked);
}
