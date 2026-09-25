import 'perk_groups.dart';
import 'perk_math.dart';
import 'perks.dart';

// 会员权益 tab「本期」视图的分组（spec §5）：本期待领按领取平台分组、随时可用（不限次）、已完成（用完或跳过）。
// 「要处理」来自 perk_agenda.dart。纯函数，吃 LedgerData 里的几张表。

/// 「我 / 全家」（spec §3）：在用的卡里，[memberId] 为 null 看全家；否则只看这个人的和全家共用的。
List<Membership> perkMemberships(List<Membership> memberships, {String? memberId}) => [
  for (final m in memberships)
    if (!m.archived && (memberId == null || m.memberId == null || m.memberId == memberId)) m,
];

/// 「本期」里的一行：一项顶层权益（N 选 1 带着它的选项）、来自哪张卡、此刻的状态。
class CurrentEntry {
  const CurrentEntry({required this.benefit, required this.membership, required this.options, required this.status});

  final Benefit benefit;
  final Membership membership;
  final List<Benefit> options;
  final PerkStatus status;
}

/// 「本期待领」的一组：去哪个平台领（[platform] 为 null = 本地找不到了）。
class CurrentGroup {
  const CurrentGroup({required this.platformId, required this.platform, required this.entries});

  final String platformId;
  final PerkPlatform? platform;
  final List<CurrentEntry> entries;
}

class CurrentPerks {
  const CurrentPerks({this.toClaim = const [], this.anytime = const [], this.done = const []});

  /// 本期待领（待领、可用 N 次），按领取平台分组；组里截止早的在前。
  final List<CurrentGroup> toClaim;

  /// 随时可用：不限次的。
  final List<CurrentEntry> anytime;

  /// 已完成：本期用完、本期跳过。
  final List<CurrentEntry> done;

  int get toClaimCount => toClaim.fold(0, (n, g) => n + g.entries.length);
  bool get isEmpty => toClaim.isEmpty && anytime.isEmpty && done.isEmpty;
}

/// 「本期」：在用的卡（按 [memberId] 过滤）名下看得见的顶层权益，未生效、已过期的不进来（在「全部」里看）；
/// 没有选项的 N 选 1 没东西可打卡，也不进来。N 选 1 按它自己的领取平台（没写就是会员本平台）归组，显示成一行。
CurrentPerks currentPerks({
  required List<Membership> memberships,
  required List<Benefit> benefits,
  required List<BenefitEvent> events,
  required List<PerkPlatform> platforms,
  required DateTime today,
  String? memberId,
}) {
  final groups = <String, List<(int, CurrentEntry)>>{};
  final anytime = <CurrentEntry>[];
  final done = <CurrentEntry>[];
  var order = 0;
  final cards = perkMemberships(memberships, memberId: memberId)..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  for (final m in cards) {
    for (final node in benefitTree(m.id, benefits)) {
      final b = node.benefit;
      if (b.isChoice && node.options.isEmpty) continue;
      final status = perkStatus(
        benefit: b,
        membership: m,
        options: node.options,
        archivedOptions: node.archivedOptions,
        events: events,
        today: today,
      );
      final entry = CurrentEntry(benefit: b, membership: m, options: node.options, status: status);
      switch (status.state) {
        case PerkState.notYet:
        case PerkState.expired:
          break;
        case PerkState.skipped:
        case PerkState.usedUp:
          done.add(entry);
        case PerkState.unlimited:
          anytime.add(entry);
        case PerkState.toClaim:
        case PerkState.available:
          (groups[effectiveClaimPlatformId(b, m)] ??= []).add((order++, entry));
      }
    }
  }
  PerkPlatform? platformOf(String id) {
    for (final p in platforms) {
      if (p.id == id) return p;
    }
    return null;
  }

  final out = [
    for (final e in groups.entries)
      CurrentGroup(
        platformId: e.key,
        platform: platformOf(e.key),
        entries: [
          for (final (_, entry) in (e.value..sort((a, b) {
            final da = a.$2.status.daysLeft;
            final db = b.$2.status.daysLeft;
            if (da != db) return da == null ? 1 : (db == null ? -1 : da.compareTo(db));
            return a.$1.compareTo(b.$1);
          })))
            entry,
        ],
      ),
  ];
  out.sort((a, b) {
    final pa = a.platform;
    final pb = b.platform;
    if (pa == null || pb == null) return pa == null ? (pb == null ? 0 : 1) : -1;
    return pa.sortOrder.compareTo(pb.sortOrder);
  });
  return CurrentPerks(toClaim: out, anytime: anytime, done: done);
}
