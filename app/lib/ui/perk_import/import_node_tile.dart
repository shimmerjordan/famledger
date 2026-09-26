import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/money.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../assets/asset_widgets.dart';
import 'perk_import_draft.dart';

/// 节点的徽章（spec §6）：新建 / 合并到「淘宝」/ 更新 3 项 / 可能重复 / 低置信 / 领取平台待确认 / 缺字段 / 依据未核实 /
/// 疑似照抄示例，外加「同名 2 张，要选」「已存在」「原来归档了」。第二个值为真 = 要提醒（warning 色）。
List<(String, bool)> importBadges(PerkImportDraft draft, ImportNode n, LedgerData ledger) {
  final out = <(String, bool)>[];
  switch (n.action) {
    case 'create':
      out.add(('新建', false));
      if (n.t == ImportNode.item && n.matchKind == 'exists') out.add(('已存在，再建一件', true));
    case 'merge':
      final name = ledger.platform(n.targetId)?.name ?? jsonStringOrNull(n.match['name']) ?? '已有平台';
      out.add(('合并到「$name」', false));
    case 'update':
      final taken = n.diff.where((d) => d.take).length;
      out.add((taken == 0 ? '已有，没有变化' : '更新 $taken 项', false));
      if (n.match['archived'] == true) {
        final restore = n.diff.any((d) => d.field == 'archived' && d.take);
        out.add((restore ? '原来归档了，导入后恢复' : '原来归档了，不恢复就看不到', true));
      }
    case 'pick':
      out.add(('同名 ${n.candidates.length} 张，要选', true));
    case 'skip':
      if (n.matchKind == 'exists') out.add(('已存在', false));
  }
  const labels = {
    'maybe_dup': '可能重复',
    'low_conf': '低置信',
    'claim_unsure': '领取平台待确认',
    'ev_unverified': '依据未核实',
    'copied_example': '疑似照抄示例',
  };
  for (final e in labels.entries) {
    // 截图来源每条都「依据未核实」，不逐条挂（预览顶上整批说一次）。
    if (e.key == 'ev_unverified' && draft.fromImages) continue;
    if (n.badges.contains(e.key)) out.add((e.value, true));
  }
  if (draft.missingOf(n).isNotEmpty) out.add(('缺字段', true));
  return out;
}

/// 一个引用（'key:p1' / 'id:…'）指的平台叫什么；并入了已有平台的写那个平台的名字。
String? refPlatformName(PerkImportDraft draft, Object? ref, LedgerData ledger) {
  if (ref is! String) return null;
  if (ref.startsWith('id:')) return ledger.platform(ref.substring(3))?.name;
  final n = draft.refNode(ref);
  if (n == null) return null;
  return n.action == 'merge' ? (ledger.platform(n.targetId)?.name ?? n.name) : n.name;
}

/// 节点的第二行：会员「¥88.00/年 · 到期 2026-12-31 · 自动续费」；权益「会籍期内 1 次 · 去「优酷视频」领」；
/// 物品「¥8,999.00 · 2026-09-20 · 关联 9/21 Apple Store 的支出」。
String importNodeSubtitle(PerkImportDraft draft, ImportNode n, LedgerData ledger) {
  final f = n.fields;
  switch (n.t) {
    case ImportNode.platform:
      return n.implied ? '材料里提到的领取平台' : (PerkPlatform.kindLabels[f['kind']] ?? '平台');
    case ImportNode.membership:
      final fee = jsonIntOrNull(f['feeCents']);
      final period = Membership.feePeriodLabels[f['feePeriod']] ?? '';
      return [
        if (fee != null) '${Money.format(fee)} $period',
        f['expiresOn'] == null ? '长期有效' : '到期 ${f['expiresOn']}',
        Membership.autoRenewLabels[f['autoRenew']] ?? '',
      ].where((s) => s.isNotEmpty).join(' · ');
    case ImportNode.benefit:
      final claim = refPlatformName(draft, draft.claimRefOf(n), ledger);
      final isOption = f['parent'] != null;
      return [
        if (!isOption) quotaLabel(PerkQuota.listFrom(f['quota'])),
        if (claim != null) '去「$claim」领',
        if (jsonIntOrNull(f['faceValueCents']) != null) '面值 ${Money.format(jsonInt(f['faceValueCents']))}',
      ].join(' · ');
    default:
      final price = jsonIntOrNull(f['priceCents']);
      final tx = n.txCandidates.where((c) => c.id == n.linkTransactionId).firstOrNull;
      return [
        price == null ? '没写价格' : Money.format(price),
        jsonStringOrNull(f['purchasedOn']) ?? '没写日期',
        Asset.categoryLabels[f['category']] ?? '其他',
        switch (n.link) {
          ItemLink.link => tx == null ? '关联一笔已有支出' : '关联 ${tx.day.substring(5)} ${tx.merchant} 的支出',
          ItemLink.record => '同时记一笔支出',
          ItemLink.none => '不记账',
        },
      ].join(' · ');
  }
}

/// 预览树里的一行：勾选框（多选时换成选中圈）、名字、第二行、徽章、导入失败时的原因。点开改，长按进多选。
class ImportNodeTile extends StatelessWidget {
  const ImportNodeTile({
    super.key,
    required this.draft,
    required this.node,
    required this.ledger,
    this.depth = 0,
    this.selecting = false,
    this.selected = false,
    this.current = false,
    required this.onTap,
    this.onLongPress,
    this.where,
  });

  final PerkImportDraft draft;
  final ImportNode node;
  final LedgerData ledger;

  /// 缩进层级：平台 0、会员 1、权益 2、选项 3。
  final int depth;
  final bool selecting;
  final bool selected;

  /// 宽屏右栏正在改的就是这一行。
  final bool current;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// 筛选后平铺时写在名字后面的「在 88VIP 下」。
  final String? where;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = LedgerColors.of(context);
    final n = node;
    final error = draft.errorOf(n.key);
    final Widget leading = selecting
        ? (n.t == ImportNode.benefit
              ? Icon(
                  selected ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                )
              : const SizedBox.shrink())
        : Checkbox(
            key: ValueKey('import-check-${n.key}'),
            value: n.checked,
            onChanged: (v) => draft.setChecked(n.key, v ?? false),
          );
    final title = n.name.isEmpty ? '未命名' : n.name;
    return Material(
      color: selected || current ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5) : Colors.transparent,
      child: InkWell(
        key: ValueKey('import-node-${n.key}'),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: EdgeInsets.fromLTRB(4.0 + depth * 20, 4, LedgerLayout.pagePadding, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 48, height: 48, child: Center(child: leading)),
              const SizedBox(width: 4),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        where == null ? title : '$title  ·  $where',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: (depth == 0 ? theme.textTheme.titleSmall : theme.textTheme.bodyLarge)?.copyWith(
                          color: n.checked ? null : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        importNodeSubtitle(draft, n, ledger),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (final (label, warn) in importBadges(draft, n, ledger))
                            TagLabel(label, tone: warn ? TagTone.warning : TagTone.neutral),
                        ],
                      ),
                      if (error != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          error,
                          key: ValueKey('import-error-${n.key}'),
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                        ),
                      ],
                      if (n.t == ImportNode.membership && n.notMentioned.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          '本次材料未提及：${n.notMentioned.map((m) => m['name']).join('、')}（不会删）',
                          style: theme.textTheme.bodySmall?.copyWith(color: colors.warning),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
