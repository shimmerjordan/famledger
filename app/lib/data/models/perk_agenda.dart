import '../../core/dates.dart';
import '../../core/money.dart';
import 'asset_math.dart';
import 'perk_current.dart';
import 'perk_groups.dart';
import 'perk_math.dart';
import 'perks.dart';

// 会员权益的提醒规则表（spec §3「提醒」）：续费扣费、到期、试用结束、过期后待确认、本期没领完（合并成一句）、
// 权益快到期。纯函数 perkAgenda：首页「会员权益」段、会员权益 tab 的「要处理」、以后的 Android 每日摘要（P6）
// 共用一套 —— P6 对未来 30 天每一天调一次，挑 [PerkAlert.remindToday] 为真的拼摘要。
// 「知道了」只记在本机（ui/perks/perk_providers.dart），这里不管；[PerkAlert.key] 是它记的键。

enum PerkAlertKind {
  /// 过期后 15 天内：自动续费的问「续上了吗」，其余能续的问「续了还是停了」，一次性、不收费的问「还留着吗」。
  renewCheck,

  /// 自动续费扣费：目标日 = 有效到期日 + 1，T−7、T−1。
  renewCharge,

  /// 到期（不续费或状态不明）：年付、一次性 T−30、T−7、T−1；月付、季付 T−3、T−1。
  expiry,

  /// 试用结束：T−3、T−1。
  trialEnd,

  /// 权益快到期（还有剩余时）：valid_until，T−7、T−1。
  benefitExpiring,

  /// 本期没领完 / 没用完：最细上限区间的末日，期末前 3 天（周周期前 1 天），全部合并成一句。
  unclaimed,
}

class PerkAlert {
  const PerkAlert({
    required this.kind,
    required this.due,
    required this.daysLeft,
    required this.remindToday,
    required this.title,
    required this.detail,
    this.membershipId,
    this.benefitId,
    this.benefitIds = const [],
  });

  final PerkAlertKind kind;

  /// 目标日（renewCheck 是原到期日）。
  final DateTime due;

  /// 目标日 − 今天；renewCheck 是负数（已过期几天）。
  final int daysLeft;

  /// 今天正好是提醒日（T−30 / T−7 / T−1……；renewCheck 是过期次日；unclaimed 是刚进提醒窗口那天）。
  /// 页面里只要在窗口内就一直显示，通知（P6）只在这一天发。
  final bool remindToday;
  final String title;
  final String detail;

  /// 卡片级提醒的卡；benefitExpiring 是权益所属的卡；unclaimed 为 null。
  final String? membershipId;

  /// benefitExpiring 的那项权益（N 选 1 是父权益）。
  final String? benefitId;

  /// unclaimed 合并进来的那几项。
  final List<String> benefitIds;

  /// 「知道了」记的键：换了目标日（续过费、下个月）就是新的一条。
  String get key => '${kind.name}:${benefitId ?? membershipId ?? ''}:${Dates.isoDate(due)}';
}

/// 「9月30日」。
String perkShortDay(DateTime day) => '${day.month}月${day.day}日';

/// 提醒提前几天（降序）：[remindDays] 覆盖第一次，比它晚的默认提醒留着，T−1 固定保留。
List<int> alertLeads(List<int> defaults, int? remindDays) {
  if (remindDays == null) return defaults;
  return ({remindDays, ...defaults.skip(1).where((d) => d < remindDays), 1}.toList()..sort((a, b) => b.compareTo(a)));
}

const Map<PerkAlertKind, int> _kindOrder = {
  PerkAlertKind.renewCheck: 0,
  PerkAlertKind.renewCharge: 1,
  PerkAlertKind.expiry: 2,
  PerkAlertKind.trialEnd: 3,
  PerkAlertKind.benefitExpiring: 4,
  PerkAlertKind.unclaimed: 5,
};

/// 本期没领完的「本月」「本周」……
const Map<String, String> _unclaimedWords = {
  'week': '本周',
  'month': '本月',
  'quarter': '本季',
  'year': '本年',
  'term': '本期',
  'total': '有效期内',
};

/// 此刻该提醒的事（spec §3 规则表），「过期后待确认」排最前，其余按剩几天排。
///
/// [memberId] 为 null 看全家；否则只看这个人的和全家共用的（首页、通知就这么调）。归档的卡不提醒；
/// `remind_days = 0` 关掉这张卡的卡片级提醒（续费、到期、试用、过期后待确认），它的权益照常；
/// `benefit.remind = false` 只把这项排除出「本期没领完」的汇总。
List<PerkAlert> perkAgenda({
  required List<Membership> memberships,
  required List<Benefit> benefits,
  required List<BenefitEvent> events,
  required DateTime today,
  String? memberId,
}) {
  final out = <PerkAlert>[];
  final unclaimed = <(Benefit, DateTime, String, bool)>[];
  for (final m in perkMemberships(memberships, memberId: memberId)) {
    final card = _cardAlert(m, today);
    if (card != null) out.add(card);

    for (final node in benefitTree(m.id, benefits)) {
      final b = node.benefit;
      if (b.isChoice && node.options.isEmpty) continue;
      final s = perkStatus(
        benefit: b,
        membership: m,
        options: node.options,
        archivedOptions: node.archivedOptions,
        events: events,
        today: today,
      );
      if (s.state != PerkState.available && s.state != PerkState.toClaim) continue;
      final left = s.state == PerkState.toClaim ? '还没领' : '还剩 ${s.remaining} 次';

      final until = parseDay(b.validUntil);
      final untilIn = until?.difference(today).inDays;
      if (until != null && untilIn! >= 0 && untilIn <= 7) {
        out.add(PerkAlert(
          kind: PerkAlertKind.benefitExpiring,
          membershipId: m.id,
          benefitId: b.id,
          due: until,
          daysLeft: untilIn,
          remindToday: untilIn == 7 || untilIn == 1,
          title: '${b.name} 快到期',
          detail: '来自 ${m.title} · ${perkShortDay(until)}到期 · $left',
        ));
        continue;
      }

      // 本期没领完：每天一期的不汇总（天天都「期末」，只会变成噪音）。
      final finest = _finestPeriod(b.quota);
      final end = s.window.end;
      final d = s.daysLeft;
      if (!b.remind || finest == null || finest == 'day' || end == null || d == null) continue;
      final lead = finest == 'week' ? 1 : 3;
      if (d >= 0 && d <= lead) unclaimed.add((b, end, finest, d == lead));
    }
  }

  if (unclaimed.isNotEmpty) {
    final due = unclaimed.map((u) => u.$2).reduce((a, b) => a.isBefore(b) ? a : b);
    final periods = {for (final u in unclaimed) u.$3};
    final word = periods.length == 1 ? _unclaimedWords[periods.first] : null;
    final n = unclaimed.length;
    final names = unclaimed.map((u) => u.$1.name).take(3).join('、');
    out.add(PerkAlert(
      kind: PerkAlertKind.unclaimed,
      due: due,
      daysLeft: due.difference(today).inDays,
      remindToday: unclaimed.any((u) => u.$4),
      title: word == null ? '还有 $n 项快到期没领' : '$word还有 $n 项没领',
      detail: '${perkShortDay(due)}前 · $names${n > 3 ? ' 等' : ''}',
      benefitIds: [for (final u in unclaimed) u.$1.id],
    ));
  }

  out.sort((a, b) {
    final byCheck = (a.kind == PerkAlertKind.renewCheck ? 0 : 1).compareTo(b.kind == PerkAlertKind.renewCheck ? 0 : 1);
    if (byCheck != 0) return byCheck;
    if (a.daysLeft != b.daysLeft) return a.daysLeft.compareTo(b.daysLeft);
    final byKind = _kindOrder[a.kind]!.compareTo(_kindOrder[b.kind]!);
    return byKind != 0 ? byKind : a.title.compareTo(b.title);
  });
  return out;
}

String? _finestPeriod(List<PerkQuota> quota) {
  String? best;
  for (final q in quota) {
    if (best == null || quotaPeriodOrder.indexOf(q.p) < quotaPeriodOrder.indexOf(best)) best = q.p;
  }
  return best;
}

/// 一张卡此刻的卡片级提醒（最多一条）。
PerkAlert? _cardAlert(Membership m, DateTime today) {
  final end = parseDay(m.expiresOn);
  if (m.remindDays == 0 || end == null) return null;
  final late = today.difference(end).inDays;
  final renewable = renewPeriodMonths.containsKey(m.feePeriod);

  if (late >= 1) {
    if (late >= renewGraceDays) return null;
    final auto = m.autoRenew == 'yes' && renewable;
    return PerkAlert(
      kind: PerkAlertKind.renewCheck,
      membershipId: m.id,
      due: end,
      daysLeft: -late,
      remindToday: late == 1,
      title: auto ? '${m.title} 应已自动续费，续上了吗？' : '${m.title} 已过期 $late 天',
      // 一次性、不收费的卡没有下一期，只问还留不留（界面上是「归档」和「知道了」）。
      detail: '${perkShortDay(end)}到期 · ${auto ? '已过 $late 天' : (renewable ? '续了还是停了？' : '还留着吗？')}',
    );
  }

  // 试用优先于自动续费（is_trial 只影响提醒的默认值），自动续费优先于普通到期。
  final kind = m.isTrial
      ? PerkAlertKind.trialEnd
      : (m.autoRenew == 'yes' && renewable ? PerkAlertKind.renewCharge : PerkAlertKind.expiry);
  final due = kind == PerkAlertKind.renewCharge ? addDays(end, 1) : end;
  final defaults = switch (kind) {
    PerkAlertKind.trialEnd => const [3, 1],
    PerkAlertKind.renewCharge => const [7, 1],
    _ => m.feePeriod == 'month' || m.feePeriod == 'quarter' ? const [3, 1] : const [30, 7, 1],
  };
  final leads = alertLeads(defaults, m.remindDays);
  final title = switch (kind) {
    PerkAlertKind.trialEnd => '${m.title} 试用快结束',
    PerkAlertKind.renewCharge => '${m.title} 将自动续费',
    _ => '${m.title} 快到期',
  };
  final daysLeft = due.difference(today).inDays;
  if (daysLeft > leads.first) return null;
  final when = daysLeft == 0 ? '今天' : '还有 $daysLeft 天';
  final fee = m.feeCents;
  final detail = switch (kind) {
    PerkAlertKind.renewCharge => '${perkShortDay(due)}扣${fee == null ? '费' : ' ${Money.format(fee)}'} · $when',
    PerkAlertKind.trialEnd => '${perkShortDay(due)}结束 · $when',
    _ => '${perkShortDay(due)}到期 · $when',
  };
  return PerkAlert(
    kind: kind,
    membershipId: m.id,
    due: due,
    daysLeft: daysLeft,
    remindToday: leads.contains(daysLeft),
    title: title,
    detail: detail,
  );
}
