import 'package:famledger/data/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

// perkAgenda（spec §3 提醒规则表）：默认提前天数、remind_days 覆盖、合并成一句、成员过滤、过期后待确认、权益快到期。
// 固定「今天」= 2026-09-23。每日摘要（reminderDigests）和 30 天窗口是 P6 的事，它们挑 remindToday 为真的项。

DateTime d(String s) => parseDay(s)!;
final DateTime today = d('2026-09-23');

Membership card(
  String id, {
  String? expires,
  String period = 'year',
  String autoRenew = 'unknown',
  bool trial = false,
  int? remindDays,
  int? fee,
  String? start,
  String? memberId,
  bool archived = false,
  String platformId = 'tb',
  int sort = 0,
}) => Membership(
  id: id,
  platformId: platformId,
  name: id,
  feeCents: fee,
  feePeriod: period,
  autoRenew: autoRenew,
  isTrial: trial,
  remindDays: remindDays,
  termStartOn: start,
  expiresOn: expires,
  memberId: memberId,
  archived: archived,
  sortOrder: sort,
);

List<PerkAlert> agenda(List<Membership> ms, {List<Benefit> benefits = const [], List<BenefitEvent> events = const [], String? memberId}) =>
    perkAgenda(memberships: ms, benefits: benefits, events: events, today: today, memberId: memberId);

void main() {
  test('alertLeads：remind_days 覆盖第一次，比它晚的默认留着，T−1 固定保留', () {
    expect(alertLeads(const [30, 7, 1], null), [30, 7, 1]);
    expect(alertLeads(const [30, 7, 1], 15), [15, 7, 1]);
    expect(alertLeads(const [30, 7, 1], 60), [60, 7, 1]);
    expect(alertLeads(const [30, 7, 1], 3), [3, 1]);
    expect(alertLeads(const [7, 1], 1), [1]);
  });

  test('卡片级提醒：默认提前天数、覆盖、试用、自动续费扣费、过期后待确认；页面里窗口内一直在，通知只在提醒日', () {
    final cases = <(String, Membership, PerkAlertKind?, int?, bool?, String?, String?)>[
      // (说明, 卡, 种类, 剩几天, 今天是提醒日, 标题, 详情)
      ('年付 30 天后到期：T−30', card('88VIP', expires: '2026-10-23'), PerkAlertKind.expiry, 30, true, '88VIP 快到期', '10月23日到期 · 还有 30 天'),
      ('年付 31 天后：还不提醒', card('88VIP', expires: '2026-10-24'), null, null, null, null, null),
      ('年付 17 天后：在窗口里，但不是提醒日', card('88VIP', expires: '2026-10-10'), PerkAlertKind.expiry, 17, false, null, null),
      ('今天到期', card('88VIP', expires: '2026-09-23'), PerkAlertKind.expiry, 0, false, null, '9月23日到期 · 今天'),
      ('一次性的也按年付的默认', card('课', expires: '2026-10-23', period: 'once'), PerkAlertKind.expiry, 30, true, null, null),
      ('月付 3 天后：T−3', card('腾讯视频', expires: '2026-09-26', period: 'month'), PerkAlertKind.expiry, 3, true, null, null),
      ('月付 4 天后：还不提醒', card('腾讯视频', expires: '2026-09-27', period: 'month'), null, null, null, null, null),
      ('自动续费：目标日 = 到期日 + 1，T−7', card('腾讯视频', expires: '2026-09-29', period: 'month', autoRenew: 'yes', fee: 2500), PerkAlertKind.renewCharge, 7, true, '腾讯视频 将自动续费', '9月30日扣 ¥25.00 · 还有 7 天'),
      ('自动续费 8 天后才扣：还不提醒', card('腾讯视频', expires: '2026-09-30', period: 'month', autoRenew: 'yes'), null, null, null, null, null),
      ('试用：T−3、T−1', card('优酷', expires: '2026-09-25', trial: true, autoRenew: 'yes'), PerkAlertKind.trialEnd, 2, false, '优酷 试用快结束', '9月25日结束 · 还有 2 天'),
      ('remind_days = 15 覆盖 T−30', card('88VIP', expires: '2026-10-08', remindDays: 15), PerkAlertKind.expiry, 15, true, null, null),
      ('remind_days = 15：16 天后还不提醒', card('88VIP', expires: '2026-10-09', remindDays: 15), null, null, null, null, null),
      ('remind_days = 0：关掉', card('88VIP', expires: '2026-09-24', remindDays: 0), null, null, null, null, null),
      ('归档的卡不提醒', card('88VIP', expires: '2026-09-24', archived: true), null, null, null, null, null),
      ('长期有效的不提醒', card('88VIP'), null, null, null, null, null),
      ('自动续费过期 1 天：问续上了吗（次日提醒）', card('88VIP', expires: '2026-09-22', autoRenew: 'yes'), PerkAlertKind.renewCheck, -1, true, '88VIP 应已自动续费，续上了吗？', '9月22日到期 · 已过 1 天'),
      ('不续费的过期 3 天：续了还是停了', card('88VIP', expires: '2026-09-20', autoRenew: 'no'), PerkAlertKind.renewCheck, -3, false, '88VIP 已过期 3 天', '9月20日到期 · 续了还是停了？'),
      ('过期 15 天：不再问', card('88VIP', expires: '2026-09-08', autoRenew: 'yes'), null, null, null, null, null),
      ('一次性的课过期 3 天：没有下一期，只问还留不留', card('网课', expires: '2026-09-20', period: 'once'), PerkAlertKind.renewCheck, -3, false, '网课 已过期 3 天', '9月20日到期 · 还留着吗？'),
      ('不收费的卡过期也一样', card('试用卡', expires: '2026-09-22', period: 'none', autoRenew: 'yes'), PerkAlertKind.renewCheck, -1, true, '试用卡 已过期 1 天', '9月22日到期 · 还留着吗？'),
      ('9/30 到期的年卡已经提前续到明年：不再提醒快到期', card('88VIP', start: '2026-10-01', expires: '2027-09-30'), null, null, null, null, null),
    ];
    for (final (why, m, kind, daysLeft, remindToday, title, detail) in cases) {
      final alerts = agenda([m]);
      if (kind == null) {
        expect(alerts, isEmpty, reason: why);
        continue;
      }
      final a = alerts.single;
      expect((a.kind, a.daysLeft, a.remindToday, a.membershipId), (kind, daysLeft, remindToday, m.id), reason: why);
      if (title != null) expect(a.title, title, reason: why);
      if (detail != null) expect(a.detail, detail, reason: why);
    }
  });

  test('成员过滤：给了 memberId 只看这个人的和全家共用的；null 看全家', () {
    final ms = [
      card('妈妈的', expires: '2026-09-25', memberId: 'm1'),
      card('爸爸的', expires: '2026-09-25', memberId: 'u2'),
      card('全家的', expires: '2026-09-25'),
    ];
    expect(agenda(ms, memberId: 'm1').map((a) => a.membershipId).toSet(), {'妈妈的', '全家的'});
    expect(agenda(ms).map((a) => a.membershipId).toSet(), {'妈妈的', '爸爸的', '全家的'});
  });

  test('权益快到期（还有剩余时）：T−7 起；用完的、8 天后的不提醒；和「没领完」不重复', () {
    final m = card('88VIP', expires: '2027-01-30');
    const benefits = [
      Benefit(id: 'yk', membershipId: '88VIP', name: '优酷年卡', quota: [PerkQuota('term', 1)], validUntil: '2026-09-30'),
      Benefit(id: 'used', membershipId: '88VIP', name: '用完的', quota: [PerkQuota('term', 1)], validUntil: '2026-09-25'),
      Benefit(id: 'later', membershipId: '88VIP', name: '还早', quota: [PerkQuota('term', 1)], validUntil: '2026-10-01'),
      Benefit(id: 'wk', membershipId: '88VIP', name: '周券', quota: [PerkQuota('month', 2)], validUntil: '2026-09-24'),
    ];
    final alerts = agenda([m], benefits: benefits, events: const [
      BenefitEvent(id: 'e1', benefitId: 'used', occurredOn: '2026-09-01'),
      BenefitEvent(id: 'e2', benefitId: 'wk', occurredOn: '2026-09-01'),
    ]);
    expect(alerts.map((a) => (a.kind, a.benefitId, a.daysLeft, a.remindToday)), [
      (PerkAlertKind.benefitExpiring, 'wk', 1, true),
      (PerkAlertKind.benefitExpiring, 'yk', 7, true),
    ]);
    expect(alerts.last.title, '优酷年卡 快到期');
    expect(alerts.last.detail, '来自 88VIP · 9月30日到期 · 还剩 1 次');
    expect(alerts.first.detail, '来自 88VIP · 9月24日到期 · 还剩 1 次');
  });

  test('提前续了的卡：还在跑的这一期里没领完的权益照样提醒快到期', () {
    const benefits = [
      Benefit(id: 'yk', membershipId: '88VIP', name: '优酷年卡', quota: [PerkQuota('term', 1)], validUntil: '2026-09-28'),
    ];
    final before = agenda([card('88VIP', start: '2025-10-01', expires: '2026-09-30')], benefits: benefits);
    final after = agenda([card('88VIP', start: '2026-10-01', expires: '2027-09-30')], benefits: benefits);
    expect(before.map((a) => (a.kind, a.benefitId)), [(PerkAlertKind.benefitExpiring, 'yk'), (PerkAlertKind.expiry, null)]);
    expect(after.map((a) => (a.kind, a.benefitId, a.detail)), [(PerkAlertKind.benefitExpiring, 'yk', '来自 88VIP · 9月28日到期 · 还剩 1 次')]);
  });

  test('本期没领完：期末前 3 天，合并成一句「本月还有 2 项没领」；跳过 remind=false、用完的、每天一期的；刚进窗口那天是提醒日', () {
    // 本期 1/26 起，按本期起算的月份：这一期是 8/26 ~ 9/25，还剩 2 天。
    final m = card('88VIP', start: '2026-01-26', expires: '2027-01-25');
    Benefit b(String id, {String flow = 'claim', List<PerkQuota> quota = const [PerkQuota('month', 4)], bool remind = true, String anchor = 'term'}) =>
        Benefit(id: id, membershipId: '88VIP', name: id, flow: flow, quota: quota, anchor: anchor, remind: remind);
    final benefits = [
      b('购物券'),
      b('红包', flow: Benefit.flowClaimUse),
      b('领完的', quota: const [PerkQuota('month', 1)]),
      b('不提醒的', remind: false),
      b('签到', quota: const [PerkQuota('day', 1)]),
      b('自然月的', anchor: 'calendar'),
    ];
    final alerts = agenda([m], benefits: benefits, events: const [BenefitEvent(id: 'e', benefitId: '领完的', occurredOn: '2026-09-01')]);
    final a = alerts.single;
    expect((a.kind, a.daysLeft, a.remindToday, a.title), (PerkAlertKind.unclaimed, 2, false, '本月还有 2 项没领'));
    expect(a.detail, '9月25日前 · 购物券、红包');
    expect(a.benefitIds, ['购物券', '红包']);
    expect(a.membershipId, isNull);

    // 这一期 8/27 ~ 9/26：今天正好是期末前 3 天。
    final first = agenda([card('88VIP', start: '2026-01-27', expires: '2027-01-26')], benefits: benefits).single;
    expect((first.daysLeft, first.remindToday), (3, true));
  });

  test('周期不一样时换个说法；排序：过期后待确认最前，其余按剩几天', () {
    final ms = [
      card('月卡', start: '2026-01-26', expires: '2027-01-25', sort: 0),
      card('快到期的卡', expires: '2026-09-25', sort: 1),
      card('过期的卡', expires: '2026-09-21', autoRenew: 'yes', sort: 2),
    ];
    const benefits = [
      Benefit(id: 'q', membershipId: '月卡', name: '月券', quota: [PerkQuota('month', 4)], anchor: 'term'),
      Benefit(id: 't', membershipId: '快到期的卡', name: '会籍券', quota: [PerkQuota('term', 1)]),
    ];
    final alerts = agenda(ms, benefits: benefits);
    expect(alerts.map((a) => a.kind), [PerkAlertKind.renewCheck, PerkAlertKind.expiry, PerkAlertKind.unclaimed]);
    expect(alerts.last.title, '还有 2 项快到期没领');
    expect(alerts.last.key, 'unclaimed::2026-09-25');
    expect(alerts[1].key, 'expiry:快到期的卡:2026-09-25');
  });
}
