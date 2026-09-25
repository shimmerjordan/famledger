import '../../core/money.dart';
import 'asset_math.dart';
import 'perks.dart';

// 会员权益「全部」视图的两种分组（spec §5），以及列表里那几句话（额度、到期、续费价）。
// 纯函数，吃的是 LedgerData 里的几张表；「本期」、剩余、回本这些要看打卡事件的放在 P3 的 perk_math.dart。

/// 一条顶层权益；N 选 1 的父权益带着它的选项。
class BenefitNode {
  const BenefitNode(this.benefit, [this.options = const []]);

  final Benefit benefit;
  final List<Benefit> options;
}

/// 「按会员」的一组：一张卡、它的平台（找不到是 null）、它名下的顶层权益。
class MembershipGroup {
  const MembershipGroup({required this.membership, required this.platform, required this.benefits});

  final Membership membership;
  final PerkPlatform? platform;
  final List<BenefitNode> benefits;

  int get itemCount => perkItemCount(benefits);
}

/// 能兑现的项数：N 选 1 的父权益本身不算，算它的选项。
int perkItemCount(List<BenefitNode> nodes) =>
    nodes.fold(0, (n, node) => n + (node.benefit.isChoice ? node.options.length : 1));

/// 「按领取平台」里的一行：一项要去这个平台领的权益，和它来自哪张卡（选项还带着它的 N 选 1）。
class ClaimEntry {
  const ClaimEntry({required this.benefit, required this.membership, this.parent});

  final Benefit benefit;
  final Membership membership;
  final Benefit? parent;
}

/// 「按领取平台」的一组。[platform] 为 null 表示这个平台在本地找不到了（被删、被并、还没同步到）。
class ClaimGroup {
  const ClaimGroup({required this.platformId, required this.platform, required this.entries});

  final String platformId;
  final PerkPlatform? platform;
  final List<ClaimEntry> entries;
}

/// 平台名；本地找不到（刚被并掉、还没同步到）时给一句兜底，不让列表开天窗。
String platformLabel(PerkPlatform? platform) => platform?.name ?? '平台已删除';

PerkPlatform? _platformOf(List<PerkPlatform> platforms, String? id) {
  if (id == null) return null;
  for (final p in platforms) {
    if (p.id == id) return p;
  }
  return null;
}

/// 这项权益实际去哪领：自己写了领取平台用自己的；选项没写跟它的 N 选 1；都没写就是会员本平台。
String effectiveClaimPlatformId(Benefit benefit, Membership membership, [Benefit? parent]) =>
    benefit.claimPlatformId ?? parent?.claimPlatformId ?? membership.platformId;

List<Benefit> _benefitsOf(String membershipId, List<Benefit> benefits) => [
  for (final b in benefits)
    if (b.membershipId == membershipId) b,
]..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

/// 归档 = 隐藏（spec §2）：自己归档了，或者它的 N 选 1 归档了（选项跟着藏进「已归档」）。
bool _hidden(Benefit b, Map<String, Benefit> byId) => b.archived || (b.parentId != null && byId[b.parentId]?.archived == true);

/// 某张卡名下看得见的顶层权益（按 sortOrder），choice 带上它看得见的选项。
List<BenefitNode> benefitTree(String membershipId, List<Benefit> benefits) {
  final all = _benefitsOf(membershipId, benefits);
  final byId = {for (final b in all) b.id: b};
  final mine = [
    for (final b in all)
      if (!_hidden(b, byId)) b,
  ];
  return [
    for (final b in mine)
      // 选项挂在找不到的父权益下（本地还没同步到父权益）时当顶层画，别让它消失。
      if (b.parentId == null || !byId.containsKey(b.parentId))
        BenefitNode(b, [
          for (final o in mine)
            if (o.parentId == b.id) o,
        ]),
  ];
}

/// 某张卡名下归档的权益（会员详情底部折叠的「已归档」，点开能取消归档）：归档的顶层权益带上它的全部选项；
/// 单独归档的选项（它的 N 选 1 还在用）各成一行。
List<BenefitNode> archivedBenefitTree(String membershipId, List<Benefit> benefits) {
  final all = _benefitsOf(membershipId, benefits);
  final byId = {for (final b in all) b.id: b};
  return [
    for (final b in all)
      if (b.archived && !(b.parentId != null && byId[b.parentId]?.archived == true))
        BenefitNode(b, [
          for (final o in all)
            if (o.parentId == b.id) o,
        ]),
  ];
}

/// 「按会员」：[archived] 为假给在用的卡，为真给归档的卡（「全部」底部折叠的那一段）。
List<MembershipGroup> groupByMembership({
  required List<Membership> memberships,
  required List<Benefit> benefits,
  required List<PerkPlatform> platforms,
  bool archived = false,
}) {
  final cards = [
    for (final m in memberships)
      if (m.archived == archived) m,
  ]..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  return [
    for (final m in cards)
      MembershipGroup(membership: m, platform: _platformOf(platforms, m.platformId), benefits: benefitTree(m.id, benefits)),
  ];
}

/// 「按领取平台」：直接回答「什么会员要去哪个平台领」。只看在用的卡和未归档的权益；
/// N 选 1 的父权益本身不是一行，它的选项各按自己的领取平台归组。组按平台的 sortOrder，找不到的平台排最后。
List<ClaimGroup> groupByClaimPlatform({
  required List<Membership> memberships,
  required List<Benefit> benefits,
  required List<PerkPlatform> platforms,
}) {
  final groups = <String, List<ClaimEntry>>{};
  for (final m in groupByMembership(memberships: memberships, benefits: benefits, platforms: platforms)) {
    for (final node in m.benefits) {
      final rows = node.benefit.isChoice
          ? [for (final o in node.options) ClaimEntry(benefit: o, membership: m.membership, parent: node.benefit)]
          : [ClaimEntry(benefit: node.benefit, membership: m.membership)];
      for (final row in rows) {
        final id = effectiveClaimPlatformId(row.benefit, row.membership, row.parent);
        (groups[id] ??= []).add(row);
      }
    }
  }
  final out = [
    for (final e in groups.entries) ClaimGroup(platformId: e.key, platform: _platformOf(platforms, e.key), entries: e.value),
  ];
  out.sort((a, b) {
    final pa = a.platform;
    final pb = b.platform;
    if (pa == null || pb == null) return pa == null ? (pb == null ? 0 : 1) : -1;
    return pa.sortOrder.compareTo(pb.sortOrder);
  });
  return out;
}

/// 额度的说法：「每月 4 次」「每年 6 次 · 每月最多 2 次」「会籍期内 1 次」「一次性」「不限次」。
String quotaLabel(List<PerkQuota> quota) {
  if (quota.isEmpty) return '不限次';
  String one(PerkQuota q, {required bool first}) {
    if (q.p == 'total') return q.n == 1 ? '一次性' : '总共 ${q.n} 次';
    final period = PerkQuota.periodLabels[q.p] ?? q.p;
    return first ? '$period ${q.n} 次' : '$period最多 ${q.n} 次';
  }

  return [for (var i = 0; i < quota.length; i++) one(quota[i], first: i == 0)].join(' · ');
}

/// 续费价：「¥88.00/年」「¥25.00/月」「一次性 ¥199.00」「不收费」；没填是 null。
String? feeLabel(Membership m) {
  if (m.feePeriod == 'none') return '不收费';
  final fee = m.feeCents;
  if (fee == null) return null;
  return switch (m.feePeriod) {
    'month' => '${Money.format(fee)}/月',
    'quarter' => '${Money.format(fee)}/季',
    'once' => '一次性 ${Money.format(fee)}',
    _ => '${Money.format(fee)}/年',
  };
}

/// 到期的说法：「长期有效」「还有 N 天到期」「今天到期」「已过期 N 天」。[today] 用本地日历。
String expiryLabel(Membership m, DateTime today) {
  final end = parseDay(m.expiresOn);
  if (end == null) return '长期有效';
  final days = end.difference(localDay(today)).inDays;
  if (days == 0) return '今天到期';
  return days > 0 ? '还有 $days 天到期' : '已过期 ${-days} 天';
}
