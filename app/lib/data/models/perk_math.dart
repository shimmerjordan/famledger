import 'dart:math' as math;

import '../../core/dates.dart';
import 'asset_math.dart';
import 'perk_groups.dart';
import 'perks.dart';

// 会员权益的派生数（spec §3「周期额度」「有效本期与续费推算」「回本」）：本期窗口、用量、剩余、状态、
// 回本和潜在额度。服务端不存这些（打卡事件不存 period_key），全在这里按当前规则现算；首页、会员权益 tab、
// 会员详情、以后的通知（P6）吃同一套。全是纯函数，「今天」由调用方传进来（`localDay(clock())`）。
//
// 日子一律用 UTC 零点的 DateTime（和 asset_math.dart 的 parseDay / localDay 一样），加减天数不碰夏令时。

// —— 日子 ——

/// [day] 往后 [n] 天（n 可以是负数）。
DateTime addDays(DateTime day, int n) => DateTime.utc(day.year, day.month, day.day + n);

/// [day] 往后 [months] 个月，日号从 [day] 重新夹取：1/31 + 1 月 = 2/28，+ 2 月 = 3/31（不做链式累加）。
/// 服务端 lib/perks_schema.js 的 addPeriod 是同一个口径。
DateTime addMonthsClamped(DateTime day, int months) {
  final first = DateTime.utc(day.year, day.month + months);
  final last = DateTime.utc(first.year, first.month + 1, 0).day;
  return DateTime.utc(first.year, first.month, math.min(day.day, last));
}

/// 续费周期各是几个月；once / none 不在表里 = 没有下一期（服务端 renew 回 409 not_renewable）。
const Map<String, int> renewPeriodMonths = {'month': 1, 'quarter': 3, 'year': 12};

DateTime? _later(DateTime? a, DateTime? b) => a == null ? b : (b == null || !b.isAfter(a) ? a : b);
DateTime? _earlier(DateTime? a, DateTime? b) => a == null ? b : (b == null || !b.isBefore(a) ? a : b);

/// 一段日子，两头都算；null = 那头不设限。
class DayRange {
  const DayRange(this.start, this.end);

  final DateTime? start;
  final DateTime? end;

  bool contains(DateTime day) => (start == null || !day.isBefore(start!)) && (end == null || !day.isAfter(end!));

  /// 和 [from, until] 取交集（null 那头不收窄）。
  DayRange clip(DateTime? from, DateTime? until) => DayRange(_later(start, from), _earlier(end, until));

  @override
  bool operator ==(Object other) => other is DayRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'DayRange(${start == null ? '…' : Dates.isoDate(start!)} ~ ${end == null ? '…' : Dates.isoDate(end!)})';
}

// —— 有效本期 ——

/// 过期不到这么多天、又是自动续费的卡，按续费周期推出「推算本期」（spec §3）。
const int renewGraceDays = 15;

/// 有效本期：没过期直接用存的本期；过期不到 15 天、自动续费、周期能续的，推出下一期并标 [projected]；
/// 其余过期的标 [expired]（界面算已过期，不静默往后滚）。另外两种要补一手的（见 [effectiveTerm]）：
/// 到期前就续上了的标 [nextStart]，没填本期开始的标 [guessedStart]。
class PerkTerm {
  const PerkTerm({
    this.start,
    this.end,
    this.projected = false,
    this.expired = false,
    this.guessedStart = false,
    this.nextStart,
  });

  /// null = 没填本期开始（也估不出来）。
  final DateTime? start;

  /// null = 长期有效。
  final DateTime? end;
  final bool projected;
  final bool expired;

  /// 没填本期开始，[start] 是按到期日往前推一期估的：回本窗口、「会籍期内」的额度有了下界，
  /// 但 anchor=term 照 spec 仍退回自然周期（界面提示去补）。
  final bool guessedStart;

  /// 到期前就点了「续了」：存的本期从这天才开始，[start] ~ [end] 是眼下还在跑的上一期。
  final DateTime? nextStart;

  DayRange get range => DayRange(start, end);
}

/// 到期日为 [end]、周期 [months] 个月的那一期从哪天开始：往前一期的次日（服务端 renew 推本期开始也这么算）。
DateTime _termStartBefore(DateTime end, int months) => addDays(addMonthsClamped(end, -months), 1);

/// 有效本期（spec §3「有效本期与续费推算」），外加两种库里的样子要补一手：
/// - 存的本期还没开始、周期能续：多半是到期前就点了「续了」（服务端把本期开始挪到原到期日次日，快到期的提醒上就有
///   「续了」）。眼下还在跑的是上一期 [原到期日往前一期的次日, 原到期日]，状态、回本、提醒都跟它走，不然还没用完的
///   这一期会整个变成「未生效」。上一期的开始也还没到（预约开通的卡）才算未生效。库里分不出「提前续了」和
///   「预约开通、一期之内就开始」，这两种按前者算。
/// - 没填本期开始、周期能续：按到期日往前一期估一个起点（估出来在将来就不估），不然回本和「会籍期内 1 次」
///   会把历史上所有打卡都算进来。
PerkTerm effectiveTerm(Membership m, DateTime today) {
  final start = parseDay(m.termStartOn);
  final end = parseDay(m.expiresOn);
  final months = renewPeriodMonths[m.feePeriod];
  if (end != null && today.isAfter(end)) {
    if (m.autoRenew == 'yes' && months != null && today.difference(end).inDays < renewGraceDays) {
      return PerkTerm(start: addDays(end, 1), end: addMonthsClamped(end, months), projected: true);
    }
    final guess = start == null && months != null ? _termStartBefore(end, months) : null;
    return PerkTerm(start: start ?? guess, end: end, expired: true, guessedStart: guess != null);
  }
  if (months == null || end == null) return PerkTerm(start: start, end: end);
  if (start == null) {
    final guess = _termStartBefore(end, months);
    return today.isBefore(guess) ? PerkTerm(end: end) : PerkTerm(start: guess, end: end, guessedStart: true);
  }
  if (today.isBefore(start)) {
    final prevEnd = addDays(start, -1);
    final prevStart = _termStartBefore(prevEnd, months);
    if (!today.isBefore(prevStart)) return PerkTerm(start: prevStart, end: prevEnd, nextStart: start);
  }
  return PerkTerm(start: start, end: end);
}

/// 「续了」续到哪天（spec §4 renew）：原到期日 + 一个周期（月末截断；没到期日按昨天算）。续一期还在今天之前的
/// （自动续费过了好几期才想起来点），一期一期往后推到不早于今天那期。once / none 没有下一期，返回 null。
/// App 总是把它发给服务端（ui/perks/perk_actions.dart renewNow）：本地过时的那台会撞上「不晚于原到期日」的 400，不会续出两期。
DateTime? renewPlan(Membership m, DateTime today) {
  final months = renewPeriodMonths[m.feePeriod];
  if (months == null) return null;
  final base = parseDay(m.expiresOn) ?? addDays(today, -1);
  var k = 1;
  while (addMonthsClamped(base, k * months).isBefore(today) && k < 1200) {
    k++;
  }
  return addMonthsClamped(base, k * months);
}

// —— 周期额度 ——

/// 周期由细到粗；「最细那条上限」按这个顺序挑。
const List<String> quotaPeriodOrder = ['day', 'week', 'month', 'quarter', 'year', 'term', 'total'];

int _rank(String p) => quotaPeriodOrder.indexOf(p);

/// 进度、提醒里的「本月」「本周」……
const Map<String, String> perkPeriodWords = {
  'day': '今天',
  'week': '本周',
  'month': '本月',
  'quarter': '本季',
  'year': '本年',
  'term': '本期',
  'total': '总共',
};

/// 周期 [p] 在 [today] 所在的那一期（spec §3 表），还没和有效期、本期止日取交集。
/// [anchorStart] 非空 = 按会员本期起算（只对 month / quarter / year 生效）：第 k 期 = [A + k 个周期, 下一期起点 − 1 天]，
/// 日号每次都从 A 重新夹取。term = 有效本期；total 不设限（取交集后就是 [valid_from, valid_until]）。
DayRange periodRange(String p, DateTime today, {DateTime? anchorStart, required PerkTerm term}) {
  switch (p) {
    case 'day':
      return DayRange(today, today);
    case 'week':
      final monday = addDays(today, 1 - today.weekday);
      return DayRange(monday, addDays(monday, 6));
    case 'month':
    case 'quarter':
    case 'year':
      final len = p == 'month' ? 1 : (p == 'quarter' ? 3 : 12);
      if (anchorStart != null) return _anchored(anchorStart, len, today);
      final first = p == 'month' ? today.month : (p == 'quarter' ? (today.month - 1) ~/ 3 * 3 + 1 : 1);
      return DayRange(DateTime.utc(today.year, first), addDays(DateTime.utc(today.year, first + len), -1));
    case 'term':
      return term.range;
    default:
      return const DayRange(null, null);
  }
}

DayRange _anchored(DateTime anchor, int len, DateTime today) {
  var k = 0;
  if (!today.isBefore(anchor)) {
    k = ((today.year - anchor.year) * 12 + today.month - anchor.month) ~/ len;
    if (addMonthsClamped(anchor, k * len).isAfter(today)) k -= 1;
  }
  return DayRange(addMonthsClamped(anchor, k * len), addDays(addMonthsClamped(anchor, (k + 1) * len), -1));
}

/// 状态，按 spec §3 的判断顺序排：未生效 → 已过期 → 本期已跳过 → 待领 → 可用 N 次 → 本期用完 → 不限次。
enum PerkState { notYet, expired, skipped, toClaim, available, usedUp, unlimited }

/// 一项权益（N 选 1 看父权益，用量是全部选项加起来）此刻的样子。
class PerkStatus {
  const PerkStatus({
    required this.state,
    this.remaining,
    this.used = 0,
    this.limit,
    this.bindingPeriod,
    this.window = const DayRange(null, null),
    this.daysLeft,
    this.anchorFallback = false,
    this.termProjected = false,
    this.picked = const {},
  });

  final PerkState state;

  /// 所有上限里 (n − 用量) 的最小值；null = 不限次；负数 = 超额。
  final int? remaining;

  /// 起决定作用的那条上限（剩余最少；一样少取最细的）这一期用了几次 / 上限几次 / 周期 —— 进度「本月 1/4」。
  final int used;
  final int? limit;
  final String? bindingPeriod;

  /// 领取期 = 最细那条上限的这一期（上限为空取有效本期）∩ 有效期 ∩ 本期止日。跳过、待领、截止都看它。
  final DayRange window;

  /// 领取期末日 − 今天；不设限是 null。
  final int? daysLeft;

  /// anchor=term 但会员没填本期开始：退回自然周期算，界面提示去补。
  final bool anchorFallback;

  /// 用的是按自动续费推算的本期。
  final bool termProjected;

  /// N 选 1：领取期里打过卡的选项 id。
  final Set<String> picked;

  /// 超额几次（spec：超额只显示「超额 N」，不拦）。
  int get over => remaining != null && remaining! < 0 ? -remaining! : 0;

  /// 这一期还能领 / 用。
  bool get open => state == PerkState.toClaim || state == PerkState.available || state == PerkState.unlimited;
}

/// 一条上限这一期的用量。
class _QuotaUse {
  const _QuotaUse(this.quota, this.range, this.window, this.used);

  final PerkQuota quota;

  /// 没取交集的这一期（数「到期前还有几期」用）。
  final DayRange range;

  /// 取过交集的这一期（数用量用）。
  final DayRange window;
  final int used;

  int get left => quota.n - used;
}

/// 这项权益计额度的事件种类：claim 计「领了」，use / claim_use 计「用了」（spec §3）。
String countedKind(Benefit b) => b.flow == Benefit.flowClaim ? 'claim' : 'use';

class _Eval {
  _Eval(this.benefit, this.membership, this.options, List<BenefitEvent> events, this.today, {List<Benefit> archivedOptions = const []})
    : term = effectiveTerm(membership, today),
      validFrom = parseDay(benefit.validFrom),
      validUntil = parseDay(benefit.validUntil) {
    // N 选 1 的用量把所有选项的事件加起来 —— 归档了的选项也算：选过它，这一期的额度就用掉了（spec §3）。
    final ids = benefit.isChoice ? {for (final o in [...options, ...archivedOptions]) o.id} : {benefit.id};
    mine = [
      for (final e in events)
        if (ids.contains(e.benefitId) && parseDay(e.occurredOn) != null) e,
    ];
    uses = [];
    for (final q in benefit.quota) {
      final range = periodRange(q.p, today, anchorStart: anchorStart, term: term);
      final window = clip(range);
      uses.add(_QuotaUse(q, range, window, count(window, countedKind(benefit))));
    }
  }

  final Benefit benefit;
  final Membership membership;
  final List<Benefit> options;
  final DateTime today;
  final PerkTerm term;
  final DateTime? validFrom;
  final DateTime? validUntil;
  late final List<BenefitEvent> mine;
  late final List<_QuotaUse> uses;

  /// anchor=term 按有效本期的起点起算；本期开始是估出来的（没填）照 spec 退回自然周期。
  DateTime? get anchorStart => benefit.anchor == Benefit.anchorTerm && !term.guessedStart ? term.start : null;

  bool get anchorFallback => benefit.anchor == Benefit.anchorTerm && (term.start == null || term.guessedStart);

  DayRange clip(DayRange r) => r.clip(validFrom, _earlier(validUntil, term.end));

  int count(DayRange window, String kind) => mine.fold(
    0,
    (n, e) => e.kind == kind && window.contains(parseDay(e.occurredOn)!) ? n + e.count : n,
  );

  _QuotaUse? get finest {
    _QuotaUse? best;
    for (final u in uses) {
      if (best == null || _rank(u.quota.p) < _rank(best.quota.p)) best = u;
    }
    return best;
  }

  DayRange get claimWindow => finest?.window ?? clip(term.range);

  bool get skipped => mine.any((e) => e.kind == 'skip' && claimWindow.contains(parseDay(e.occurredOn)!));

  PerkStatus status() {
    _QuotaUse? binding;
    for (final u in uses) {
      if (binding == null || u.left < binding.left || (u.left == binding.left && _rank(u.quota.p) < _rank(binding.quota.p))) {
        binding = u;
      }
    }
    final window = claimWindow;
    final counted = countedKind(benefit);
    final PerkState state;
    if ((validFrom != null && today.isBefore(validFrom!)) || (term.start != null && today.isBefore(term.start!))) {
      state = PerkState.notYet;
    } else if (term.expired || (validUntil != null && today.isAfter(validUntil!))) {
      state = PerkState.expired;
    } else if (skipped) {
      state = PerkState.skipped;
    } else if (benefit.flow == Benefit.flowClaimUse && count(window, 'claim') == 0) {
      state = PerkState.toClaim;
    } else if (binding == null) {
      state = PerkState.unlimited;
    } else {
      state = binding.left > 0 ? PerkState.available : PerkState.usedUp;
    }
    return PerkStatus(
      state: state,
      remaining: binding?.left,
      used: binding?.used ?? 0,
      limit: binding?.quota.n,
      bindingPeriod: binding?.quota.p,
      window: window,
      daysLeft: window.end?.difference(today).inDays,
      anchorFallback: anchorFallback,
      termProjected: term.projected,
      picked: benefit.isChoice
          ? {
              for (final e in mine)
                if (e.kind == counted && window.contains(parseDay(e.occurredOn)!)) e.benefitId,
            }
          : const {},
    );
  }
}

/// 一项顶层权益此刻的状态。N 选 1 传父权益、它看得见的 [options] 和归档了的 [archivedOptions]
/// （[BenefitNode] 上都有）：用量把所有选项的事件加起来。
PerkStatus perkStatus({
  required Benefit benefit,
  required Membership membership,
  List<Benefit> options = const [],
  List<Benefit> archivedOptions = const [],
  required List<BenefitEvent> events,
  required DateTime today,
}) => _Eval(benefit, membership, options, events, today, archivedOptions: archivedOptions).status();

/// 「可用 3 次」「待领」「本期用完」「超额 2」……
String perkStateLabel(PerkStatus s) => switch (s.state) {
  PerkState.notYet => '未生效',
  PerkState.expired => '已过期',
  PerkState.skipped => '本期已跳过',
  PerkState.toClaim => '待领',
  PerkState.available => '可用 ${s.remaining} 次',
  PerkState.usedUp => s.over > 0 ? '超额 ${s.over}' : '本期用完',
  PerkState.unlimited => '不限次',
};

/// 进度「本月 1/4」；不限次没有。
String? perkProgressLabel(PerkStatus s) {
  final limit = s.limit;
  if (limit == null) return null;
  return '${perkPeriodWords[s.bindingPeriod] ?? '本期'} ${s.used}/$limit';
}

/// 截止「今天截止」「还剩 7 天」；领取期不设限的没有。
String? perkDeadlineLabel(PerkStatus s) {
  final d = s.daysLeft;
  if (d == null || d < 0) return null;
  return d == 0 ? '今天截止' : '还剩 $d 天';
}

/// 一键打卡记哪种事件：claim 记「领了」、use 记「用了」；claim_use 还没领时先记「领了」，领过之后记「用了」。
String perkActionKind(Benefit b, PerkStatus s) => switch (b.flow) {
  Benefit.flowClaim => 'claim',
  Benefit.flowClaimUse => s.state == PerkState.toClaim ? 'claim' : 'use',
  _ => 'use',
};

/// 大按钮上的字。
String perkActionLabel(String kind) => kind == 'claim' ? '领了' : '用了';

/// N 选 1 的选项要不要置灰（spec §3）：这一期领不了了（用完、跳过、过期……）而且这一期没选它。撤销打卡后自然恢复。
bool perkOptionDimmed(PerkStatus parent, String optionId) => !parent.open && !parent.picked.contains(optionId);

// —— 回本 ——

/// 一次打卡值多少（spec §3）：事件自己写的 → 我的估值 → 面值（选项都没填看它的 N 选 1）→ 0。
/// [fromFace] = 用到了面值（界面标「含面值估算」）；[known] 为假 = 一样都没填（「N 项未估值」）。
({int cents, bool fromFace, bool known}) perkUnitValue(Benefit b, {Benefit? parent, int? override}) {
  if (override != null) return (cents: override, fromFace: false, known: true);
  for (final x in [b, ?parent]) {
    if (x.myValueCents != null) return (cents: x.myValueCents!, fromFace: false, known: true);
    if (x.faceValueCents != null) return (cents: x.faceValueCents!, fromFace: true, known: true);
  }
  return (cents: 0, fromFace: false, known: false);
}

/// 一张卡的回本（spec §3）：窗口 = 有效本期 [起点, min(今天, 止)]；成本 = 本期实付 ?? 续费价 ?? 0（推算本期按续费价）；
/// 已兑现 = 窗口内计额度的事件 × 单价（派生会员的不加回来）；时间进度 = 本期过了几成；潜在额度见 [perkPotential]。
class PerkPayback {
  const PerkPayback({
    required this.costCents,
    required this.realizedCents,
    required this.window,
    this.timeProgress,
    this.usesFaceValue = false,
    this.unvalued = 0,
    this.potentialCents = 0,
    this.projected = false,
  });

  final int costCents;
  final int realizedCents;
  final DayRange window;

  /// 0–1；缺本期开始（也估不出来）或到期日时 null（不画时间刻度）。
  final double? timeProgress;
  final bool usesFaceValue;

  /// 有打卡、但单价一样都没填的权益数。
  final int unvalued;
  final int potentialCents;
  final bool projected;

  bool get free => costCents == 0;

  /// 已回本（基点）；免费的卡没有。
  int? get ratioBp => costCents == 0 ? null : (realizedCents * 10000 / costCents).round();
}

/// [benefits] 可以是全家的权益表（按 membershipId 挑，归档的也算：回本历史要留着）。
PerkPayback perkPayback({
  required Membership membership,
  required List<Benefit> benefits,
  required List<BenefitEvent> events,
  required DateTime today,
}) {
  final term = effectiveTerm(membership, today);
  final window = DayRange(term.start, _earlier(today, term.end));
  final byId = {
    for (final b in benefits)
      if (b.membershipId == membership.id) b.id: b,
  };
  var realized = 0;
  var face = false;
  final unknown = <String>{};
  for (final e in events) {
    final b = byId[e.benefitId];
    final day = parseDay(e.occurredOn);
    if (b == null || day == null || e.kind != countedKind(b) || !window.contains(day)) continue;
    final unit = perkUnitValue(b, parent: byId[b.parentId], override: e.valueCents);
    realized += e.count * unit.cents;
    face = face || unit.fromFace;
    if (!unit.known) unknown.add(b.id);
  }
  double? progress;
  final start = term.start;
  final end = term.end;
  if (start != null && end != null) {
    progress = today.isBefore(start)
        ? 0
        : math.min(1, daysInclusive(start, today.isAfter(end) ? end : today) / daysInclusive(start, end));
  }
  var potential = 0;
  for (final node in benefitTree(membership.id, benefits)) {
    potential += perkPotential(
      benefit: node.benefit,
      membership: membership,
      options: node.options,
      archivedOptions: node.archivedOptions,
      events: events,
      today: today,
    );
  }
  return PerkPayback(
    costCents: term.projected ? (membership.feeCents ?? 0) : (membership.termPaidCents ?? membership.feeCents ?? 0),
    realizedCents: realized,
    window: window,
    timeProgress: progress,
    usesFaceValue: face,
    unvalued: unknown.length,
    potentialCents: potential,
    projected: term.projected,
  );
}

/// 潜在额度（spec §3）：（本期剩余 + 到期前剩余各期）× 单价。不限次、未生效、已过期的不算；到期日和有效期都不设限的
/// 只算本期剩余。叠加上限取各条算出来的最小次数；本期跳过了的，最细那条的本期不算。
/// N 选 1：每一期只取价值最高的那几个选项（一期挑 n 个就取最贵的 n 个，归档了的不挑），不把所有选项加起来。
int perkPotential({
  required Benefit benefit,
  required Membership membership,
  List<Benefit> options = const [],
  List<Benefit> archivedOptions = const [],
  required List<BenefitEvent> events,
  required DateTime today,
}) {
  final ev = _Eval(benefit, membership, options, events, today, archivedOptions: archivedOptions);
  final state = ev.status().state;
  if (ev.uses.isEmpty || state == PerkState.notYet || state == PerkState.expired) return 0;
  final horizon = _earlier(ev.term.end, ev.validUntil);
  final anchorStart = ev.anchorStart;
  final finest = ev.finest!;

  /// 这条上限到期前还有几整期（这一期之后、起点不晚于 horizon 的）。
  int later(_QuotaUse u) {
    if (horizon == null || u.range.end == null || u.quota.p == 'term' || u.quota.p == 'total') return 0;
    var n = 0;
    var next = addDays(u.range.end!, 1);
    while (!next.isAfter(horizon) && n < 1000) {
      n++;
      next = addDays(periodRange(u.quota.p, next, anchorStart: anchorStart, term: ev.term).end!, 1);
    }
    return n;
  }

  int now(_QuotaUse u) => identical(u, finest) && state == PerkState.skipped ? 0 : math.max(0, u.left);
  var uses = -1;
  for (final u in ev.uses) {
    final total = now(u) + u.quota.n * later(u);
    if (uses < 0 || total < uses) uses = total;
  }
  if (!benefit.isChoice) return uses * perkUnitValue(benefit).cents;

  final units = [
    for (final o in options) perkUnitValue(o, parent: benefit).cents,
  ]..sort((a, b) => b.compareTo(a));
  int top(int k) => units.take(k).fold(0, (s, v) => s + v);
  var left = uses;
  var sum = top(math.min(now(finest), left));
  left -= math.min(now(finest), left);
  for (var i = later(finest); i > 0 && left > 0; i--) {
    final take = math.min(finest.quota.n, left);
    sum += top(take);
    left -= take;
  }
  return sum;
}
