import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../assets/asset_widgets.dart';
import 'perk_import_draft.dart';

/// 「领取平台」映射视图（spec §6）：每个被权益当作领取平台的平台一行，四个选项 —— 已有平台（比对命中的那个）/ 新建 /
/// 并入…（另选一个已有平台，名字写进它的别名）/ 就是会员本平台。比对只是「可能重复」的，把候选单独列成一个 chip，
/// 但不预选。顶上「全部确认」一键让所有「领取平台待确认」「可能重复」消失。
Future<void> showClaimMappingSheet(BuildContext context, {required PerkImportDraft draft, required LedgerData ledger}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        maxChildSize: 0.95,
        builder: (context, scroll) => ListenableBuilder(
          listenable: draft,
          builder: (context, _) => _ClaimMapping(draft: draft, ledger: ledger, scroll: scroll),
        ),
      ),
    );

/// 挑一个库里已有的平台（「并入…」用）：只列没归档的，不在这里新建 —— 预览阶段不往库里写任何东西。
Future<String?> pickExistingPlatform(BuildContext context, LedgerData ledger, {String title = '并入哪个平台'}) =>
    showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 0, LedgerLayout.pagePadding, 8),
            child: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
          for (final p in ledger.platforms)
            if (!p.archived)
              ListTile(
                key: ValueKey('pick-platform-${p.id}'),
                title: Text(p.name),
                subtitle: p.aliases.isEmpty ? null : Text('也叫 ${p.aliases.join('、')}'),
                onTap: () => Navigator.of(context).pop(p.id),
              ),
          if (!ledger.platforms.any((p) => !p.archived))
            const ListTile(title: Text('账本里还没有平台')),
        ],
      ),
    );

class _ClaimMapping extends StatelessWidget {
  const _ClaimMapping({required this.draft, required this.ledger, required this.scroll});

  final PerkImportDraft draft;
  final LedgerData ledger;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = draft.claimRows;
    return ListView(
      controller: scroll,
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 0, LedgerLayout.pagePadding, 0),
          child: Row(
            children: [
              Expanded(child: Text('领取平台 · ${rows.length} 个', style: theme.textTheme.titleMedium)),
              FilledButton.tonal(
                key: const ValueKey('claim-confirm-all'),
                onPressed: () {
                  draft.confirmAllClaims();
                  Navigator.of(context).pop();
                },
                child: const Text('全部确认'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 4, LedgerLayout.pagePadding, 8),
          child: Text('什么权益去哪领。材料里的名字和账本里已有的平台是一个的，选「并入…」，名字会记成它的别名。', style: theme.textTheme.bodySmall),
        ),
        for (final row in rows) _row(context, row),
      ],
    );
  }

  Widget _row(BuildContext context, ClaimRow row) {
    final theme = Theme.of(context);
    final p = row.node;
    final unsure = row.benefits.any((b) => b.badges.contains('claim_unsure'));
    return Padding(
      key: ValueKey('claim-row-${p.key}'),
      padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 8, LedgerLayout.pagePadding, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(p.name, style: theme.textTheme.titleSmall)),
              if (unsure) const TagLabel('待确认', tone: TagTone.warning),
            ],
          ),
          const SizedBox(height: 2),
          Text('${row.benefits.map((b) => b.name).join('、')} 去这里领', style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          PlatformMappingChips(draft: draft, node: p, ledger: ledger),
        ],
      ),
    );
  }
}

/// 一个平台节点「到底是谁」的几个选项（映射视图的每一行、平台节点的表单共用）：已有「X」（比对命中的那个）/ 新建 /
/// 并入「候选」（可能重复的，不预选）/ 并入…（另挑一个已有平台）/ 就是会员本平台（[allowSelf]，只当领取平台用的才有）。
/// 名字和已有平台一模一样（exact）时不给「新建」：存活平台的规范化名唯一，导入时也只能并进去。
class PlatformMappingChips extends StatelessWidget {
  const PlatformMappingChips({super.key, required this.draft, required this.node, required this.ledger, this.allowSelf = true});

  final PerkImportDraft draft;
  final ImportNode node;
  final LedgerData ledger;
  final bool allowSelf;

  @override
  Widget build(BuildContext context) {
    final p = node;
    final mode = draft.claimModeOf(p);
    final matchName = jsonStringOrNull(p.match['name']);
    final hasMatch = p.matchKind == 'exact' || p.matchKind == 'alias';
    final mergedName = mode == ClaimMode.mergeInto ? ledger.platform(p.targetId)?.name : null;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (hasMatch)
          ChoiceChip(
            key: ValueKey('claim-${p.key}-existing'),
            label: Text('已有「${matchName ?? ''}」'),
            selected: mode == ClaimMode.existing,
            onSelected: (_) => draft.mapClaim(p.key, ClaimMode.existing),
          ),
        if (p.matchKind != 'exact')
          ChoiceChip(
            key: ValueKey('claim-${p.key}-create'),
            label: const Text('新建'),
            selected: mode == ClaimMode.create,
            onSelected: (_) => draft.mapClaim(p.key, ClaimMode.create),
          ),
        // 「可能重复」的候选：单独给个 chip 方便一点就并，但不预选。
        for (final c in p.candidates)
          ChoiceChip(
            key: ValueKey('claim-${p.key}-candidate-${c['id']}'),
            label: Text('并入「${c['name']}」'),
            selected: mode == ClaimMode.mergeInto && p.targetId == c['id'],
            onSelected: (_) => draft.mapClaim(p.key, ClaimMode.mergeInto, targetId: jsonString(c['id'])),
          ),
        ChoiceChip(
          key: ValueKey('claim-${p.key}-merge'),
          label: Text(mergedName != null && !p.candidates.any((c) => c['id'] == p.targetId) ? '并入「$mergedName」' : '并入…'),
          selected: mode == ClaimMode.mergeInto && !p.candidates.any((c) => c['id'] == p.targetId),
          onSelected: (_) async {
            final id = await pickExistingPlatform(context, ledger);
            if (id != null) draft.mapClaim(p.key, ClaimMode.mergeInto, targetId: id);
          },
        ),
        if (allowSelf)
          ChoiceChip(
            key: ValueKey('claim-${p.key}-self'),
            label: const Text('就是会员本平台'),
            selected: mode == ClaimMode.self,
            onSelected: (_) => draft.mapClaim(p.key, ClaimMode.self),
          ),
      ],
    );
  }
}
