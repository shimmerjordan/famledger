import 'package:famledger/data/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

// perk_math.dart 的表驱动测试（spec §8 App）：固定「今天」= 2026-09-23（周三）。
// 月末锚点、季度、term、叠加上限、三种 flow、N 选 1 汇总和置灰、跳过、超额、有效期交集、缺开通日回退、
// 推算本期和宽限期、回本取值顺序、潜在额度。

DateTime d(String s) => parseDay(s)!;
final DateTime today = d('2026-09-23');

int _ids = 0;
BenefitEvent ev(String benefitId, String on, {String kind = 'claim', int count = 1, int? value}) =>
    BenefitEvent(id: 'e${++_ids}', benefitId: benefitId, kind: kind, occurredOn: on, count: count, valueCents: value);

/// 88VIP：本期 2026-01-31 ~ 2027-01-30，¥88/年。
const Membership vip = Membership(
  id: 'vip',
  platformId: 'tb',
  name: '88VIP',
  feeCents: 8800,
  termStartOn: '2026-01-31',
  expiresOn: '2027-01-30',
);

Benefit perk(
  String id, {
  String flow = Benefit.flowClaim,
  List<PerkQuota> quota = const [],
  String anchor = Benefit.anchorCalendar,
  String? validFrom,
  String? validUntil,
  int? face,
  int? mine,
  String kind = 'coupon',
  String? parentId,
  String membershipId = 'vip',
  bool archived = false,
}) => Benefit(
  id: id,
  membershipId: membershipId,
  parentId: parentId,
  name: id,
  kind: kind,
  flow: flow,
  quota: quota,
  anchor: anchor,
  validFrom: validFrom,
  validUntil: validUntil,
  faceValueCents: face,
  myValueCents: mine,
  archived: archived,
);

PerkStatus status(Benefit b, List<BenefitEvent> events, {Membership card = vip, List<Benefit> options = const []}) =>
    perkStatus(benefit: b, membership: card, options: options, events: events, today: today);

void main() {
  group('日子', () {
    test('addMonthsClamped：日号从起点重新夹取（1/31 + 1 月 = 2/28，+ 2 月 = 3/31），可以往回推', () {
      expect(addMonthsClamped(d('2026-01-31'), 1), d('2026-02-28'));
      expect(addMonthsClamped(d('2026-01-31'), 2), d('2026-03-31'));
      expect(addMonthsClamped(d('2026-03-31'), -1), d('2026-02-28'));
      expect(addMonthsClamped(d('2024-02-29'), 12), d('2025-02-28'));
      expect(addMonthsClamped(d('2026-11-30'), 3), d('2027-02-28'));
      expect(addDays(d('2026-12-31'), 1), d('2027-01-01'));
      expect(today.weekday, DateTime.wednesday);
    });

    test('periodRange：自然周期（周一开始的周、自然月/季/年）、按本期起算（月末锚点）、term、total', () {
      final term = effectiveTerm(vip, today);
      final cases = <(String, String, DateTime?, DateTime, DayRange)>[
        ('day', '自然', null, today, DayRange(today, today)),
        ('week', '周一开始', null, today, DayRange(d('2026-09-21'), d('2026-09-27'))),
        ('month', '自然月', null, today, DayRange(d('2026-09-01'), d('2026-09-30'))),
        ('quarter', '自然季', null, today, DayRange(d('2026-07-01'), d('2026-09-30'))),
        ('year', '自然年', null, today, DayRange(d('2026-01-01'), d('2026-12-31'))),
        ('month', '锚 1/31：第 7 期是 8/31 ~ 9/29', d('2026-01-31'), today, DayRange(d('2026-08-31'), d('2026-09-29'))),
        ('month', '锚 1/31、今天 3/15：2/28 ~ 3/30', d('2026-01-31'), d('2026-03-15'), DayRange(d('2026-02-28'), d('2026-03-30'))),
        ('month', '锚 1/31、今天 2/27：还在第 0 期', d('2026-01-31'), d('2026-02-27'), DayRange(d('2026-01-31'), d('2026-02-27'))),
        ('quarter', '锚 1/31 的季度', d('2026-01-31'), today, DayRange(d('2026-07-31'), d('2026-10-30'))),
        ('year', '卡片年度 11/15 起', d('2025-11-15'), today, DayRange(d('2025-11-15'), d('2026-11-14'))),
        ('week', 'week 不看锚点', d('2026-01-31'), today, DayRange(d('2026-09-21'), d('2026-09-27'))),
        ('term', '有效本期', null, today, DayRange(d('2026-01-31'), d('2027-01-30'))),
        ('total', '不设限', null, today, const DayRange(null, null)),
      ];
      for (final (p, why, anchor, on, want) in cases) {
        expect(periodRange(p, on, anchorStart: anchor, term: term), want, reason: '$p $why');
      }
    });
  });

  group('有效本期与续费推算', () {
    test('effectiveTerm：没过期用存的；过期不到 15 天 + 自动续费 + 能续 → 推算本期；其余算已过期；提前续了看上一期；没填开通日按到期日估', () {
      Membership card({String? expires, String autoRenew = 'yes', String period = 'month', String? start}) => Membership(
        id: 'c',
        platformId: 'p',
        name: '卡',
        feePeriod: period,
        autoRenew: autoRenew,
        termStartOn: start,
        expiresOn: expires,
      );
      // (说明, 卡, 起, 止, 推算, 过期, 起点是估的, 下一期从哪天起)
      final cases = <(String, Membership, DateTime?, DateTime?, bool, bool, bool, DateTime?)>[
        ('没过期', card(expires: '2026-12-31', start: '2026-01-01'), d('2026-01-01'), d('2026-12-31'), false, false, false, null),
        ('今天到期还不算过期；没填开通日按到期日往前一期估', card(expires: '2026-09-23'), d('2026-08-24'), d('2026-09-23'), false, false, true, null),
        ('没填开通日、到期日还远：估出来在将来就不估', card(expires: '2027-09-23'), null, d('2027-09-23'), false, false, false, null),
        ('一次性的卡不估开通日', card(expires: '2026-12-31', period: 'once'), null, d('2026-12-31'), false, false, false, null),
        ('长期有效', card(), null, null, false, false, false, null),
        ('过期 3 天、自动续费、月付', card(expires: '2026-09-20'), d('2026-09-21'), d('2026-10-20'), true, false, false, null),
        ('过期 14 天还在宽限期', card(expires: '2026-09-09'), d('2026-09-10'), d('2026-10-09'), true, false, false, null),
        ('过期 15 天就算过期', card(expires: '2026-09-08', start: '2026-08-09'), d('2026-08-09'), d('2026-09-08'), false, true, false, null),
        ('不续费（开通日按到期日估）', card(expires: '2026-09-20', autoRenew: 'no'), d('2026-08-21'), d('2026-09-20'), false, true, true, null),
        ('续费方式不确定', card(expires: '2026-09-20', autoRenew: 'unknown'), d('2026-08-21'), d('2026-09-20'), false, true, true, null),
        ('一次性的卡没有下一期', card(expires: '2026-09-20', period: 'once'), null, d('2026-09-20'), false, true, false, null),
        ('年付：推一整年', card(expires: '2026-09-20', period: 'year'), d('2026-09-21'), d('2027-09-20'), true, false, false, null),
        (
          '9/30 到期的年卡 9/23 就续了（本期开始挪到 10/1）：眼下还是上一期',
          card(start: '2026-10-01', expires: '2027-09-30', period: 'year'),
          d('2025-10-01'),
          d('2026-09-30'),
          false,
          false,
          false,
          d('2026-10-01'),
        ),
        ('上一期的开始也还没到（预约开通的卡）：还是存的本期（未生效）', card(start: '2027-10-01', expires: '2028-09-30', period: 'year'), d('2027-10-01'), d('2028-09-30'), false, false, false, null),
        ('没有到期日的预约卡不往前推', card(start: '2026-10-01'), d('2026-10-01'), null, false, false, false, null),
      ];
      for (final (why, m, start, end, projected, expired, guessed, next) in cases) {
        final t = effectiveTerm(m, today);
        expect((t.start, t.end, t.projected, t.expired, t.guessedStart, t.nextStart), (start, end, projected, expired, guessed, next), reason: why);
      }
      // 月末：2/28 到期的月卡提前续了，上一期从 1/29 起（和服务端「往前一期的次日」一个算法）。
      final febEnd = effectiveTerm(card(start: '2027-03-01', expires: '2027-03-28'), d('2027-02-10'));
      expect((febEnd.start, febEnd.end, febEnd.nextStart), (d('2027-01-29'), d('2027-02-28'), d('2027-03-01')));
    });

    test('renewPlan：原到期日 + 一期；续一期还在今天之前就一期期往后推；没到期日按昨天；once/none 不能续', () {
      Membership card(String? expires, [String period = 'month']) =>
          Membership(id: 'c', platformId: 'p', name: '卡', feePeriod: period, expiresOn: expires);
      final cases = <(String, Membership, DateTime?)>[
        ('过期 8 天', card('2026-09-15'), d('2026-10-15')),
        ('还没到期', card('2026-12-31', 'year'), d('2027-12-31')),
        ('过了三期才想起来', card('2026-06-30'), d('2026-09-30')),
        ('月末截断', card('2026-01-31', 'quarter'), d('2026-10-31')),
        ('没有到期日', card(null), d('2026-10-22')),
      ];
      for (final (why, m, want) in cases) {
        expect(renewPlan(m, today), want, reason: why);
      }
      expect(renewPlan(card('2026-12-31', 'once'), today), isNull);
      expect(renewPlan(card('2026-12-31', 'none'), today), isNull);
    });
  });

  group('perkStatus', () {
    test('三种 flow、叠加上限、超额、跳过、有效期交集、自然周期 vs 按本期起算', () {
      const month4 = [PerkQuota('month', 4)];
      final cases = <(String, Benefit, List<BenefitEvent>, PerkState, int?, String?, int?)>[
        // (说明, 权益, 事件, 状态, 剩余, 进度, 截止天数)
        ('claim：本月领了 3 张（上月末那张不算）', perk('a', quota: month4), [ev('a', '2026-08-31'), ev('a', '2026-09-02'), ev('a', '2026-09-20', count: 2)], PerkState.available, 1, '本月 3/4', 7),
        ('claim 不数「用了」', perk('a', quota: month4), [ev('a', '2026-09-02', kind: 'use')], PerkState.available, 4, '本月 0/4', 7),
        ('use：只数「用了」', perk('a', flow: Benefit.flowUse, quota: const [PerkQuota('year', 6)]), [ev('a', '2026-09-01'), ev('a', '2026-09-10', kind: 'use', count: 2)], PerkState.available, 4, '本年 2/6', 99),
        ('claim_use：本月还没领 → 待领', perk('a', flow: Benefit.flowClaimUse, quota: month4), const [], PerkState.toClaim, 4, '本月 0/4', 7),
        ('claim_use：领了，一次还没用', perk('a', flow: Benefit.flowClaimUse, quota: month4), [ev('a', '2026-09-01')], PerkState.available, 4, '本月 0/4', 7),
        ('claim_use：上月领的不算本月领过', perk('a', flow: Benefit.flowClaimUse, quota: month4), [ev('a', '2026-08-01'), ev('a', '2026-09-01', kind: 'use')], PerkState.toClaim, 3, '本月 1/4', 7),
        ('claim_use：用满', perk('a', flow: Benefit.flowClaimUse, quota: month4), [ev('a', '2026-09-01'), ev('a', '2026-09-02', kind: 'use', count: 4)], PerkState.usedUp, 0, '本月 4/4', 7),
        ('超额：不拦，剩余是负数', perk('a', flow: Benefit.flowClaimUse, quota: month4), [ev('a', '2026-09-01'), ev('a', '2026-09-02', kind: 'use', count: 5)], PerkState.usedUp, -1, '本月 5/4', 7),
        ('叠加：年 6 次用满了，这个月还有 1 次也不行', perk('a', quota: const [PerkQuota('year', 6), PerkQuota('month', 2)]), [for (final m in ['03', '04', '05', '06', '07']) ev('a', '2026-$m-01'), ev('a', '2026-09-05')], PerkState.usedUp, 0, '本年 6/6', 7),
        ('叠加：年里还多，卡在月上', perk('a', quota: const [PerkQuota('year', 6), PerkQuota('month', 2)]), [ev('a', '2026-09-05')], PerkState.available, 1, '本月 1/2', 7),
        ('本期跳过（领取期 = 最细那条的本月）', perk('a', quota: month4), [ev('a', '2026-09-10', kind: 'skip')], PerkState.skipped, 4, '本月 0/4', 7),
        ('上个月跳过的不算', perk('a', quota: month4), [ev('a', '2026-08-20', kind: 'skip')], PerkState.available, 4, '本月 0/4', 7),
        ('有效期止在 9/25：本月窗口收窄到 9/25', perk('a', quota: month4, validUntil: '2026-09-25'), const [], PerkState.available, 4, '本月 0/4', 2),
        ('有效期止在 9/20：已过期', perk('a', quota: month4, validUntil: '2026-09-20'), const [], PerkState.expired, 4, '本月 0/4', -3),
        ('有效期从 9/30 起：未生效', perk('a', quota: month4, validFrom: '2026-09-30'), const [], PerkState.notYet, 4, '本月 0/4', 7),
        ('按本期起算：8/31 那张算在 8/31 ~ 9/29 这期', perk('a', quota: const [PerkQuota('month', 1)], anchor: Benefit.anchorTerm), [ev('a', '2026-08-31')], PerkState.usedUp, 0, '本月 1/1', 6),
        ('自然月：8/31 那张不算本月', perk('a', quota: const [PerkQuota('month', 1)]), [ev('a', '2026-08-31')], PerkState.available, 1, '本月 0/1', 7),
        ('季度（自然季）', perk('a', quota: const [PerkQuota('quarter', 1)]), [ev('a', '2026-07-01')], PerkState.usedUp, 0, '本季 1/1', 7),
        ('周（周一开始）：周日那次算上周', perk('a', quota: const [PerkQuota('week', 1)]), [ev('a', '2026-09-20')], PerkState.available, 1, '本周 0/1', 4),
        ('会籍期内 1 次', perk('a', kind: 'subscription', quota: const [PerkQuota('term', 1)]), [ev('a', '2026-02-10')], PerkState.usedUp, 0, '本期 1/1', 129),
        ('总共 3 次，有效期 2026 全年', perk('a', quota: const [PerkQuota('total', 3)], validFrom: '2026-01-01', validUntil: '2026-12-31'), [ev('a', '2026-02-01', count: 3)], PerkState.usedUp, 0, '总共 3/3', 99),
        ('不限次', perk('a'), [ev('a', '2026-09-01')], PerkState.unlimited, null, null, 129),
        ('不限次的 claim_use，本期没领：待领（领取期 = 本期）', perk('a', flow: Benefit.flowClaimUse), [ev('a', '2026-01-10')], PerkState.toClaim, null, null, 129),
      ];
      for (final (why, b, events, state, remaining, progress, daysLeft) in cases) {
        final s = status(b, events);
        expect((s.state, s.remaining, perkProgressLabel(s), s.daysLeft), (state, remaining, progress, daysLeft), reason: why);
      }
    });

    test('卡的状态：已过期、预约开通（未生效）、推算本期里「会籍期内」重新算、缺开通日时 anchor=term 退回自然周期', () {
      const expired = Membership(id: 'x', platformId: 'p', name: '过期卡', expiresOn: '2026-09-01', autoRenew: 'no');
      expect(status(perk('a', membershipId: 'x'), const [], card: expired).state, PerkState.expired);

      const later = Membership(id: 'x', platformId: 'p', name: '预约卡', termStartOn: '2026-10-01');
      expect(status(perk('a', membershipId: 'x'), const [], card: later).state, PerkState.notYet);

      const renewed = Membership(
        id: 'x',
        platformId: 'p',
        name: '月卡',
        feePeriod: 'month',
        autoRenew: 'yes',
        termStartOn: '2026-08-21',
        expiresOn: '2026-09-20',
      );
      final s = status(perk('a', membershipId: 'x', quota: const [PerkQuota('term', 1)]), [ev('a', '2026-09-01')], card: renewed);
      expect((s.state, s.termProjected, s.window), (PerkState.available, true, DayRange(d('2026-09-21'), d('2026-10-20'))), reason: '推算本期从 9/21 起，上一期领的不算');

      const noStart = Membership(id: 'x', platformId: 'p', name: '没填开通日', expiresOn: '2027-01-30');
      final f = status(perk('a', membershipId: 'x', quota: const [PerkQuota('month', 1)], anchor: Benefit.anchorTerm), [ev('a', '2026-08-31')], card: noStart);
      expect((f.state, f.anchorFallback, f.window), (PerkState.available, true, DayRange(d('2026-09-01'), d('2026-09-30'))));
      expect(status(perk('a', quota: const [PerkQuota('month', 1)], anchor: Benefit.anchorTerm), const []).anchorFallback, isFalse);
    });

    test('N 选 1：用量把所有选项加起来；用完后没选的选项置灰，撤销（事件没了）就恢复', () {
      final parent = perk('c', kind: 'choice', quota: const [PerkQuota('year', 1)]);
      final options = [perk('o1', parentId: 'c', face: 24800), perk('o2', parentId: 'c', mine: 19800)];
      final used = status(parent, [ev('o1', '2026-03-01')], options: options);
      expect((used.state, used.remaining), (PerkState.usedUp, 0));
      expect(used.picked, {'o1'});
      expect(perkOptionDimmed(used, 'o2'), isTrue, reason: '没选的置灰');
      expect(perkOptionDimmed(used, 'o1'), isFalse, reason: '选了的那个亮着');
      final fresh = status(parent, const [], options: options);
      expect((fresh.state, fresh.remaining), (PerkState.available, 1));
      expect(fresh.picked, isEmpty);
      expect(perkOptionDimmed(fresh, 'o2'), isFalse);
      expect(status(parent, [ev('o2', '2026-09-01', kind: 'skip')], options: options).state, PerkState.skipped, reason: '选项上记的跳过算整组跳过');
    });

    test('到期前 7 天点了「续了」：本期待领、回本、时间进度都不变（还在跑的是上一期），新一期到了再切过去', () {
      // 9/30 到期的年卡，¥88；每月 4 张的券 9/10 用过 1 张；「会籍期内 1 次」的年卡还没领。
      const before = Membership(
        id: 'y',
        platformId: 'p',
        name: '年卡',
        feeCents: 8800,
        termStartOn: '2025-10-01',
        expiresOn: '2026-09-30',
      );
      // 服务端 renew：到期日 + 一年，本期开始挪到原到期日次日，实付清空。
      const after = Membership(
        id: 'y',
        platformId: 'p',
        name: '年卡',
        feeCents: 8800,
        termStartOn: '2026-10-01',
        expiresOn: '2027-09-30',
      );
      final coupon = perk('q', membershipId: 'y', quota: const [PerkQuota('month', 4)], face: 1000);
      final yearly = perk('t', membershipId: 'y', kind: 'subscription', quota: const [PerkQuota('term', 1)], face: 5000);
      final events = [ev('q', '2026-09-10'), ev('t', '2025-10-05')];
      (PerkState, int?, int?) look(Benefit b, Membership m) {
        final s = status(b, events, card: m);
        return (s.state, s.remaining, s.daysLeft);
      }

      for (final b in [coupon, yearly]) {
        expect(look(b, after), look(b, before), reason: '${b.id}：续了之后本期待领不变');
      }
      expect(look(coupon, after), (PerkState.available, 3, 7));
      expect(look(yearly, after).$1, PerkState.usedUp, reason: '上一期（2025-10-01 起）领过的年卡照样算');
      PerkPayback pay(Membership m) => perkPayback(membership: m, benefits: [coupon, yearly], events: events, today: today);
      expect((pay(after).realizedCents, pay(after).ratioBp, pay(after).timeProgress), (pay(before).realizedCents, pay(before).ratioBp, pay(before).timeProgress));
      expect(pay(after).realizedCents, 6000);

      // 10/1 新一期开始：年卡、券都重新算。
      final s = perkStatus(benefit: yearly, membership: after, events: events, today: d('2026-10-02'));
      expect((s.state, s.remaining), (PerkState.available, 1));
    });

    test('没填本期开始：「会籍期内 1 次」和回本只看到期日往前一期，前年、去年的打卡不算', () {
      const noStart = Membership(id: 'x', platformId: 'p', name: '没填开通日', feeCents: 8800, expiresOn: '2027-02-28');
      final yearly = perk('t', membershipId: 'x', kind: 'subscription', quota: const [PerkQuota('term', 1)], face: 24800);
      final events = [ev('t', '2024-03-10'), ev('t', '2025-03-10')];
      final s = status(yearly, events, card: noStart);
      expect((s.state, s.used, s.window.start), (PerkState.available, 0, d('2026-03-01')));
      final p = perkPayback(membership: noStart, benefits: [yearly], events: events, today: today);
      expect((p.realizedCents, p.window.start), (0, d('2026-03-01')));
      expect(p.timeProgress, isNotNull, reason: '估出了起点，也有时间进度');
      final monthly = status(perk('m', membershipId: 'x', quota: const [PerkQuota('month', 1)], anchor: Benefit.anchorTerm), const [], card: noStart);
      expect((monthly.anchorFallback, monthly.window), (true, DayRange(d('2026-09-01'), d('2026-09-30'))), reason: 'anchor=term 照 spec 仍退回自然周期');
    });

    test('N 选 1：选过的选项后来归档了，这一期的额度照样算用掉，别的选项照样置灰', () {
      final parent = perk('c', kind: 'choice', quota: const [PerkQuota('year', 1)]);
      final visible = [perk('o2', parentId: 'c', mine: 19800)];
      final archived = [perk('o1', parentId: 'c', face: 24800, archived: true)];
      final s = perkStatus(benefit: parent, membership: vip, options: visible, archivedOptions: archived, events: [ev('o1', '2026-03-01')], today: today);
      expect((s.state, s.remaining), (PerkState.usedUp, 0));
      expect(perkOptionDimmed(s, 'o2'), isTrue);
      final tree = benefitTree('vip', [parent, ...visible, ...archived]);
      expect(tree.single.archivedOptions.map((b) => b.id), ['o1'], reason: 'benefitTree 带上归档了的选项（只用来数用量）');
      expect(tree.single.options.map((b) => b.id), ['o2']);
    });

    test('说法：状态、截止、大按钮记哪种事件', () {
      expect(perkStateLabel(const PerkStatus(state: PerkState.available, remaining: 3)), '可用 3 次');
      expect(perkStateLabel(const PerkStatus(state: PerkState.usedUp, remaining: 0)), '本期用完');
      expect(perkStateLabel(const PerkStatus(state: PerkState.usedUp, remaining: -2)), '超额 2');
      expect(perkStateLabel(const PerkStatus(state: PerkState.toClaim)), '待领');
      expect(perkStateLabel(const PerkStatus(state: PerkState.skipped)), '本期已跳过');
      expect(perkStateLabel(const PerkStatus(state: PerkState.notYet)), '未生效');
      expect(perkStateLabel(const PerkStatus(state: PerkState.expired)), '已过期');
      expect(perkStateLabel(const PerkStatus(state: PerkState.unlimited)), '不限次');
      expect(perkDeadlineLabel(const PerkStatus(state: PerkState.available, daysLeft: 0)), '今天截止');
      expect(perkDeadlineLabel(const PerkStatus(state: PerkState.available, daysLeft: 7)), '还剩 7 天');
      expect(perkDeadlineLabel(const PerkStatus(state: PerkState.unlimited)), isNull);

      const toClaim = PerkStatus(state: PerkState.toClaim);
      const open = PerkStatus(state: PerkState.available, remaining: 1);
      expect(perkActionKind(perk('a'), open), 'claim');
      expect(perkActionKind(perk('a', flow: Benefit.flowUse), open), 'use');
      expect(perkActionKind(perk('a', flow: Benefit.flowClaimUse), toClaim), 'claim', reason: '先领');
      expect(perkActionKind(perk('a', flow: Benefit.flowClaimUse), open), 'use', reason: '领过再用');
      expect(perkActionLabel('claim'), '领了');
      expect(perkActionLabel('use'), '用了');
    });
  });
}
