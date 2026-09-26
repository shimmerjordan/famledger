import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../assets/asset_providers.dart';
import 'perk_actions.dart';
import 'perk_providers.dart';
import 'perk_widgets.dart';

/// 首页、提醒行（以后还有通知）去会员权益 tab 的地址：先打开「本期」、按「我」看 —— 和首页同一个范围，
/// 首页说几项，过去就看得到这几项（不改本机记的选择，用户一动分段才以用户的为准）。
const String perkAgendaLocation = '/assets?tab=perks&view=current&scope=mine';

/// 一条提醒（perkAgenda 的一项）：首页「会员权益」段和会员权益 tab 的「要处理」共用。
///
/// 权益快到期的行右边直接点 ✓ 打卡（N 选 1 是「挑一个」，弹层里点选项）；续费扣费、快到期、过期后待确认有「续了」；
/// 过期后待确认还有「停了」（一次性、不收费的卡没有下一期，只有「归档」）。除了能续的「过期后待确认」（得答一句），
/// 都能点 ✕「知道了」（只记在本机）。点行本身打开那张卡；「本期没领完」去会员权益 tab（已经在 tab 里就不动）。
/// 请求还在路上时这张卡 / 这项权益的按钮转圈、再点不做事。
class PerkAlertTile extends ConsumerWidget {
  const PerkAlertTile({super.key, required this.alert, required this.data, this.onOpen, this.padding, this.hold = false});

  final PerkAlert alert;
  final LedgerData data;

  /// 打开一张卡；不给就推会员详情页（会员权益 tab 传进来：宽屏换右栏，手机推详情页）。
  final void Function(String membershipId)? onOpen;
  final EdgeInsetsGeometry? padding;

  /// 先等一等（这张卡的扣费线索还没取回来，这一行可能马上被线索替掉）：「续了」转圈、「续了」「停了」点了都不做事。
  final bool hold;

  static const Map<PerkAlertKind, IconData> _icons = {
    PerkAlertKind.renewCheck: Icons.help_outline,
    PerkAlertKind.renewCharge: Icons.autorenew,
    PerkAlertKind.expiry: Icons.event_busy_outlined,
    PerkAlertKind.trialEnd: Icons.hourglass_bottom,
    PerkAlertKind.benefitExpiring: Icons.redeem_outlined,
    PerkAlertKind.unclaimed: Icons.checklist,
  };

  static const Set<PerkAlertKind> _renewRows = {PerkAlertKind.renewCheck, PerkAlertKind.renewCharge, PerkAlertKind.expiry};

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final busy = ref.watch(perkBusyProvider);
    final m = data.membership(alert.membershipId);
    final renewable = m != null && renewPeriodMonths.containsKey(m.feePeriod);
    final cardBusy = hold || (m != null && busy.contains(perkCardBusyKey(m.id)));
    final actions = <Widget>[
      if (alert.kind == PerkAlertKind.benefitExpiring) ?_checkButton(context, ref, busy),
      // 请求还在路上时转圈、再点不做事（renewNow / stopMembership 自己会忽略）。不真的置灰：置灰的按钮不接点击，
      // 这一下会漏到整行上去打开卡片。
      if (m != null && renewable && _renewRows.contains(alert.kind))
        TextButton(
          key: ValueKey('alert-renew-${m.id}'),
          onPressed: hold ? () {} : () => renewNow(context, ref, m),
          child: cardBusy ? const PerkBusySpinner() : const Text('续了'),
        ),
      if (m != null && alert.kind == PerkAlertKind.renewCheck)
        TextButton(
          key: ValueKey('alert-stop-${m.id}'),
          onPressed: hold ? () {} : () => stopMembership(context, ref, m),
          child: Text(renewable ? '停了' : '归档'),
        ),
      if (alert.kind != PerkAlertKind.renewCheck || !renewable)
        IconButton(
          key: ValueKey('alert-dismiss-${alert.key}'),
          tooltip: '知道了',
          icon: const Icon(Icons.close, size: 20),
          onPressed: () => ref.read(perkDismissedProvider.notifier).dismiss(alert.key, ref.read(assetClockProvider)()),
        ),
    ];
    final id = alert.membershipId;
    return ListTile(
      key: ValueKey('alert-${alert.key}'),
      contentPadding: padding ?? const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
      leading: Icon(
        _icons[alert.kind],
        color: alert.kind == PerkAlertKind.renewCheck || alert.daysLeft <= 1 ? LedgerColors.of(context).warning : null,
      ),
      title: Text(alert.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(alert.detail, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
      trailing: actions.isEmpty ? null : Row(mainAxisSize: MainAxisSize.min, children: actions),
      // 「本期没领完」在 tab 里就不跳了：下面就是本期待领。
      onTap: id == null && onOpen != null
          ? null
          : () {
              if (id == null) {
                context.push(perkAgendaLocation);
              } else if (onOpen != null) {
                onOpen!(id);
              } else {
                context.push('/assets/memberships/$id');
              }
            },
    );
  }

  /// 权益快到期：直接打卡。N 选 1 得挑一个选项：「挑一个」弹出选项列表，点哪个打在哪个上。
  Widget? _checkButton(BuildContext context, WidgetRef ref, Set<String> busy) {
    final b = data.benefit(alert.benefitId);
    final m = data.membership(alert.membershipId);
    if (b == null || m == null) return null;
    final running = busy.contains(perkEventBusyKey(b));
    if (b.isChoice) {
      return TextButton(
        key: ValueKey('alert-pick-${b.id}'),
        onPressed: () => pickOptionAndCheckIn(context, ref, data: data, parent: b, membership: m),
        child: running ? const PerkBusySpinner() : const Text('挑一个'),
      );
    }
    final status = perkStatus(benefit: b, membership: m, events: data.benefitEvents, today: perkToday(ref));
    final kind = perkActionKind(b, status);
    return IconButton(
      key: ValueKey('alert-check-${b.id}'),
      tooltip: perkActionLabel(kind),
      icon: running ? const PerkBusySpinner() : const Icon(Icons.check),
      onPressed: () => checkInPerk(context, ref, data: data, benefit: b, kind: kind),
    );
  }
}

/// N 选 1 的「挑一个」：底部弹层列出看得见的选项（写着去哪领），点一个就打卡（打在选项上，和本期视图点 chip 一样）。
Future<void> pickOptionAndCheckIn(
  BuildContext context,
  WidgetRef ref, {
  required LedgerData data,
  required Benefit parent,
  required Membership membership,
}) async {
  BenefitNode? node;
  for (final n in benefitTree(membership.id, data.benefits)) {
    if (n.benefit.id == parent.id) node = n;
  }
  if (node == null || node.options.isEmpty) return;
  final status = data.statusOf(node, membership, perkToday(ref));
  final kind = perkActionKind(parent, status);
  final options = node.options;
  final picked = await showModalBottomSheet<Benefit>(
    context: context,
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: 8),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, LedgerLayout.pagePadding, LedgerLayout.pagePadding, 8),
            child: Text('${parent.name}：挑一个', style: Theme.of(context).textTheme.titleMedium),
          ),
          for (final o in options)
            ListTile(
              key: ValueKey('pick-option-${o.id}'),
              contentPadding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
              title: Text(o.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: switch (claimElsewhere(data, o, membership, parent)) {
                null => null,
                final where => Text('去$where领'),
              },
              trailing: Text(perkActionLabel(kind)),
              onTap: () => Navigator.of(context).pop(o),
            ),
        ],
      ),
    ),
  );
  if (picked == null || !context.mounted) return;
  await checkInPerk(context, ref, data: data, benefit: picked, parent: parent, kind: kind);
}
