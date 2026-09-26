import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../assets/asset_providers.dart';
import '../assets/asset_widgets.dart';
import '../widgets/widgets.dart';
import 'charge_hint_tile.dart';
import 'perk_actions.dart';
import 'perk_alert_tile.dart';
import 'perk_providers.dart';
import 'perk_widgets.dart';

/// 会员权益 tab 的「本期」（spec §5），自上而下：要处理 → 本期待领（按领取平台分组）→ 随时可用（折叠）→ 已完成（折叠）。
/// 每行右边一个大按钮一键打卡（snackbar 撤销），长按记多份、改日期、改价值、本期跳过；N 选 1 一行，点选项打卡。
class PerksCurrentView extends ConsumerWidget {
  const PerksCurrentView({
    super.key,
    required this.data,
    required this.header,
    required this.memberId,
    required this.wide,
    required this.onOpen,
  });

  final LedgerData data;

  /// 顶上的同步横幅和「本期 | 全部」「我 / 全家」。
  final Widget header;

  /// 「我」= 这个成员的和全家共用的；null = 全家。
  final String? memberId;
  final bool wide;
  final void Function(String membershipId) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final today = localDay(ref.watch(assetClockProvider)());
    final dismissed = ref.watch(perkDismissedProvider);
    // 扣费线索排最前（spec §5）：只看这个范围里的卡（「我」= 我的和全家共用的），点过「不是这笔」的收起。
    final mine = {for (final m in perkMemberships(data.memberships, memberId: memberId)) m.id};
    final fetched = ref.watch(chargeHintsProvider);
    final hints = [
      for (final h in fetched.valueOrNull ?? const <ChargeHint>[])
        if (mine.contains(h.membershipId) && !dismissed.contains(h.key)) h,
    ];
    final hinted = {for (final h in hints) h.membershipId};
    // 线索第一次还没取回来（之后随同步重取时有旧值，不算）：可能有线索的卡，它的「续了 / 停了」先转圈、点了不做事 ——
    // 不然线索一到整行换掉，手快的人已经点了「续了」（不关联流水、实付按原值）。
    final waiting = fetched.hasValue
        ? const <String>{}
        : {for (final m in data.memberships) if (mine.contains(m.id) && mayHaveChargeHint(m, today)) m.id};
    // 和首页同一张单子（「本期没领完」那一句也在）：从首页「全部 N 项」、提醒、通知过来，看到的就是那 N 项、同一句话。
    // 有扣费线索的卡，它的续费 / 到期 / 过期待确认那一条由线索那一行替掉（一张卡不说两遍）。
    final alerts = [
      for (final a in data.perkAlerts(today, memberId: memberId))
        if (!dismissed.contains(a.key) && !(hinted.contains(a.membershipId) && _cardKinds.contains(a.kind))) a,
    ];
    final now = data.currentPerksOf(today, memberId: memberId);
    AnimationStyle expand() => MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : AnimationStyle(duration: const Duration(milliseconds: 200), curve: Easing.emphasizedDecelerate);
    Widget tile(CurrentEntry e) => e.benefit.isChoice
        ? ChoicePerkTile(key: ValueKey('current-${e.benefit.id}'), data: data, entry: e, onOpen: onOpen)
        : CurrentPerkTile(key: ValueKey('current-${e.benefit.id}'), data: data, entry: e, onOpen: onOpen);

    return LayoutBuilder(
      builder: (context, box) => ListView(
        padding: (wide ? EdgeInsets.zero : readableInsets(box.maxWidth)).copyWith(bottom: 96),
        children: [
          header,
          if (hints.isNotEmpty || alerts.isNotEmpty) ...[
            SectionHeader('要处理 · ${hints.length + alerts.length}', key: const ValueKey('perks-todo')),
            for (final h in hints) ChargeHintTile(hint: h, data: data, onOpen: onOpen),
            for (final a in alerts)
              PerkAlertTile(alert: a, data: data, onOpen: onOpen, hold: _cardKinds.contains(a.kind) && waiting.contains(a.membershipId)),
            const SizedBox(height: LedgerLayout.itemGap),
          ],
          if (now.toClaim.isNotEmpty) ...[
            SectionHeader('本期待领 · ${now.toClaimCount} 项', key: const ValueKey('perks-to-claim')),
            // 长按藏着记多份、改日期这些，界面上说一句（网页上用鼠标右键）。
            Padding(
              padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 0, LedgerLayout.pagePadding, 8),
              child: Text(
                '长按或右键一行：记多份、改日期、改价值、本期跳过',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
            for (final g in now.toClaim) ...[
              _GroupHeader(group: g),
              for (final e in g.entries) tile(e),
              const SizedBox(height: LedgerLayout.itemGap),
            ],
          ] else if (alerts.isEmpty && hints.isEmpty)
            EmptyState(
              title: now.isEmpty ? '本期没有要领的' : '本期的都领完了',
              message: now.isEmpty ? '给卡加上有次数的权益（每月几张券、每年几次贵宾厅），这里就按平台排好。' : '随时可用的和已完成的收在下面。',
              compact: true,
            ),
          if (now.anytime.isNotEmpty)
            ExpansionTile(
              key: const ValueKey('perks-anytime'),
              shape: const Border(),
              collapsedShape: const Border(),
              tilePadding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
              expansionAnimationStyle: expand(),
              title: Text('随时可用 · ${now.anytime.length} 项'),
              subtitle: const Text('不限次的折扣、服务'),
              children: [for (final e in now.anytime) tile(e)],
            ),
          if (now.done.isNotEmpty)
            ExpansionTile(
              key: const ValueKey('perks-done'),
              shape: const Border(),
              collapsedShape: const Border(),
              tilePadding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
              expansionAnimationStyle: expand(),
              title: Text('已完成 · ${now.done.length} 项'),
              subtitle: const Text('本期用完或跳过的；撤销打卡就回到上面'),
              children: [for (final e in now.done) tile(e)],
            ),
        ],
      ),
    );
  }
}

/// 卡片级的提醒：这张卡有扣费线索时由线索那一行替掉。
const Set<PerkAlertKind> _cardKinds = {
  PerkAlertKind.renewCheck,
  PerkAlertKind.renewCharge,
  PerkAlertKind.expiry,
  PerkAlertKind.trialEnd,
};

/// 组头「优酷 · 3 项」，平台填了网址的右边一个「打开」。
class _GroupHeader extends ConsumerWidget {
  const _GroupHeader({required this.group});

  final CurrentGroup group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = group.platform?.url;
    return Padding(
      key: ValueKey('current-group-${group.platformId}'),
      padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 0, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${platformLabel(group.platform)} · ${group.entries.length} 项',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          if (url != null)
            TextButton(
              key: ValueKey('current-group-open-${group.platformId}'),
              onPressed: () => openPerkLink(context, ref, url),
              child: const Text('打开'),
            ),
        ],
      ),
    );
  }
}

/// 「本期」里的一项：来源卡、进度、截止、领取路径（点击复制）；右边大按钮「领了」/「用了」。
/// 长按（网页上右键）记多份、改日期、改价值、本期跳过；请求还在路上时大按钮转圈、再点不做事。
class CurrentPerkTile extends ConsumerWidget {
  const CurrentPerkTile({super.key, required this.data, required this.entry, required this.onOpen});

  final LedgerData data;
  final CurrentEntry entry;
  final void Function(String membershipId) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final b = entry.benefit;
    final s = entry.status;
    final kind = perkActionKind(b, s);
    final how = b.claimHow;
    final running = ref.watch(perkBusyProvider).contains(perkEventBusyKey(b));
    // 本期用完的（已完成里）长按照样能记：超额只提示「超额 N」，不拦（spec §3）。
    final more = s.open || s.state == PerkState.usedUp
        ? () => showCheckInSheet(context, ref, data: data, benefit: b, kind: kind)
        : null;
    return GestureDetector(
      onSecondaryTap: more,
      child: ListTile(
        contentPadding: const EdgeInsets.only(left: LedgerLayout.pagePadding, right: 8),
        onTap: () => onOpen(entry.membership.id),
        onLongPress: more,
        title: Text(b.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            Wrap(
              spacing: 6,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TagLabel(entry.membership.title),
                if (s.termProjected) const TagLabel('推算本期', tone: TagTone.warning),
                Text(perkStatusLine(s), style: theme.textTheme.bodySmall),
              ],
            ),
            if (how != null) _ClaimHowCopy(benefitId: b.id, how: how),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (b.claimUrl != null) ClaimLinkButton(b.claimUrl!, key: ValueKey('claim-link-${b.id}')),
            if (s.open)
              FilledButton.tonal(
                key: ValueKey('check-in-${b.id}'),
                // 请求还在路上时转圈、再点不做事（checkInPerk 自己会忽略）。不真的置灰：置灰的按钮不接点击，
                // 这一下会漏到整行上去打开卡片。
                onPressed: () => checkInPerk(context, ref, data: data, benefit: b, kind: kind),
                child: running ? const PerkBusySpinner() : Text(perkActionLabel(kind)),
              ),
          ],
        ),
      ),
    );
  }
}

/// 领取路径面包屑，点一下复制（spec §5）。可点区域至少 48 高，和整行的「打开卡片」隔开，不容易点错。
class _ClaimHowCopy extends StatelessWidget {
  const _ClaimHowCopy({required this.benefitId, required this.how});

  final String benefitId;
  final String how;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: '复制领取路径：$how',
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('claim-how-$benefitId'),
        onTap: () async {
          final messenger = ScaffoldMessenger.of(context);
          await Clipboard.setData(ClipboardData(text: how));
          messenger.showSnackBar(const SnackBar(content: Text('领取路径已复制')));
        },
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(
            children: [
              Flexible(child: Text(how, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall)),
              const SizedBox(width: 6),
              Icon(Icons.copy_outlined, size: 16, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

/// N 选 1 显示成一行：父权益的进度，下面一排选项 chip，点 chip 就打卡（spec §5）；这一期领不了了，没选的置灰。
/// 选项填了领取链接的，chip 右边的小图标直接打开（「按领取平台」之外，这里也要能去领）。长按（网页上右键）chip
/// 记多份、改日期……chip 不带 tooltip：chip 里的 Tooltip 在触屏上自己认长按，会抢在外层的长按前面，只弹出一句提示。
/// 请求还在路上时整组 chip 点不动（一期只挑一个）。
class ChoicePerkTile extends ConsumerWidget {
  const ChoicePerkTile({super.key, required this.data, required this.entry, required this.onOpen});

  final LedgerData data;
  final CurrentEntry entry;
  final void Function(String membershipId) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final parent = entry.benefit;
    final s = entry.status;
    final kind = perkActionKind(parent, s);
    final running = ref.watch(perkBusyProvider).contains(perkEventBusyKey(parent));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          contentPadding: const EdgeInsets.only(left: LedgerLayout.pagePadding, right: 8),
          onTap: () => onOpen(entry.membership.id),
          title: Text(parent.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Wrap(
              spacing: 6,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TagLabel(entry.membership.title),
                if (s.termProjected) const TagLabel('推算本期', tone: TagTone.warning),
                Text(perkStatusLine(s), style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 0, LedgerLayout.pagePadding, 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final o in entry.options) _optionChip(context, ref, o, parent, s, kind, running),
            ],
          ),
        ),
      ],
    );
  }

  Widget _optionChip(BuildContext context, WidgetRef ref, Benefit o, Benefit parent, PerkStatus s, String kind, bool running) {
    final more = s.open ? () => showCheckInSheet(context, ref, data: data, benefit: o, parent: parent, kind: kind) : null;
    return GestureDetector(
      onLongPress: more,
      onSecondaryTap: more,
      child: Semantics(
        hint: s.open ? '点一下记「${perkActionLabel(kind)}」，长按记多份、改日期' : null,
        child: InputChip(
          key: ValueKey('option-check-in-${o.id}'),
          isEnabled: !perkOptionDimmed(s, o.id),
          selected: s.picked.contains(o.id),
          showCheckmark: true,
          label: Text(_optionLabel(o, parent)),
          onPressed: s.open && !running ? () => checkInPerk(context, ref, data: data, benefit: o, parent: parent, kind: kind) : null,
          onDeleted: o.claimUrl == null ? null : () => openPerkLink(context, ref, o.claimUrl!),
          deleteIcon: const Icon(Icons.open_in_new, size: 18),
          deleteButtonTooltipMessage: '打开领取链接',
        ),
      ),
    );
  }

  String _optionLabel(Benefit o, Benefit parent) {
    final where = claimElsewhere(data, o, entry.membership, parent);
    return where == null ? o.name : '${o.name} · 去$where领';
  }
}
