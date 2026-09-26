import 'perk_agenda.dart';
import 'perk_math.dart';
import 'perks.dart';

// Android 每日摘要（spec §5「Android 通知」）的纯计算：未来 30 天里哪天发、发什么、通知 id 是几、几点发。
// 内容全从 perkAgenda 来（首页、tab、通知共用一套规则表）：对每一天调一次，挑 [PerkAlert.remindToday] 为真的拼成一条。
// 排给系统、先取消再排在 platform/perk_reminders.dart。

/// 一天的摘要：每天最多一条。
class PerkDigest {
  const PerkDigest({required this.day, required this.title, required this.body, required this.keys});

  /// 哪天发（UTC 零点，perk_math 的「今天」口径）。
  final DateTime day;
  final String title;
  final String body;

  /// 拼进来的提醒（[PerkAlert.key]）。
  final List<String> keys;
}

/// 多项合成一条时正文最多几行：不多于这么多项就全列；多了列前 `perkDigestMaxLines - 1` 项，最后一行写「还有 N 项」。
const int perkDigestMaxLines = 4;

/// 通知标题的前缀：通知栏里只剩应用名「家账」，得说清楚是会员权益的事（「本月还有 2 项没领」单看像记账提醒）。
const String perkDigestTitlePrefix = '会员权益 · ';

/// 预排多少天。
const int perkDigestDays = 30;

/// 从 [firstDay] 起 [days] 天的每日摘要（没有要提醒的那天不出现）。
///
/// [memberId] 是「我」：只看我的和全家共用的卡（spec §3「首页和通知只看我的加上全家共用的」）；
/// [dismissed] 是本机点过「知道了」的键，点过的通知里也不再提。
List<PerkDigest> reminderDigests({
  required List<Membership> memberships,
  required List<Benefit> benefits,
  required List<BenefitEvent> events,
  required DateTime firstDay,
  int days = perkDigestDays,
  String? memberId,
  Set<String> dismissed = const {},
}) {
  final out = <PerkDigest>[];
  for (var i = 0; i < days; i++) {
    final day = addDays(firstDay, i);
    final due = [
      for (final a in perkAgenda(memberships: memberships, benefits: benefits, events: events, today: day, memberId: memberId))
        if (a.remindToday && !dismissed.contains(a.key)) a,
    ];
    if (due.isNotEmpty) out.add(perkDigestOf(day, due));
  }
  return out;
}

/// 一天要提醒的几项 → 一条通知：只有一项就用它自己的标题（带「会员权益 · 」）和说明；多项标题写件数，正文一行一项，
/// 最多 [perkDigestMaxLines] 行。
PerkDigest perkDigestOf(DateTime day, List<PerkAlert> due) {
  final keys = [for (final a in due) a.key];
  if (due.length == 1) {
    return PerkDigest(day: day, title: '$perkDigestTitlePrefix${due.single.title}', body: due.single.detail, keys: keys);
  }
  final shown = due.length <= perkDigestMaxLines ? due.length : perkDigestMaxLines - 1;
  final lines = [
    for (final a in due.take(shown)) a.title,
    if (due.length > shown) '还有 ${due.length - shown} 项',
  ];
  return PerkDigest(day: day, title: '$perkDigestTitlePrefix${due.length} 件事', body: lines.join('\n'), keys: keys);
}

/// 通知 id = 那天的 yyyymmdd（20260924）：同一天永远同一个 id，重排时直接顶掉。
int perkNotificationId(DateTime day) => day.year * 10000 + day.month * 100 + day.day;

/// 这个 id 是不是会员提醒排的（yyyymmdd 形状）。取消「系统里还排着的」时只动这些。
bool isPerkNotificationId(int id) {
  final month = id ~/ 100 % 100;
  final day = id % 100;
  return id >= 20000101 && id <= 29991231 && month >= 1 && month <= 12 && day >= 1 && day <= 31;
}

/// 未来 [days] 个提醒时刻（本地时间）：今天的 [hour]:[minute] 还没到就从今天起，到了或过了从明天起。
/// [skipToday]：今天那条已经到过点了（弹过，或者非精确闹钟还在路上）—— 改晚了钟点也从明天起，一天不发两条。
/// 每天单独算（`DateTime(y, m, d + i, h, m)`），跨夏令时也落在当地的那个钟点。
List<DateTime> perkReminderSlots(DateTime now, {required int hour, required int minute, int days = perkDigestDays, bool skipToday = false}) {
  final local = now.isUtc ? now.toLocal() : now;
  final todayAt = DateTime(local.year, local.month, local.day, hour, minute);
  final start = !skipToday && todayAt.isAfter(local) ? 0 : 1;
  return [for (var i = start; i < start + days; i++) DateTime(local.year, local.month, local.day + i, hour, minute)];
}
