import 'package:famledger/data/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

// 「本期」视图的分组 currentPerks 和「我 / 全家」过滤 perkMemberships（spec §5）。固定「今天」= 2026-09-23。

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

void main() {
  group('currentPerks', () {
    const platforms = [
      PerkPlatform(id: 'tb', name: '淘宝', sortOrder: 0),
      PerkPlatform(id: 'yk', name: '优酷', sortOrder: 1),
      PerkPlatform(id: 'jd', name: '京东', sortOrder: 2),
    ];
    final ms = [
      card('88VIP', start: '2026-01-31', expires: '2027-01-30'),
      card('PLUS', platformId: 'jd', memberId: 'u2', sort: 1),
      card('老卡', archived: true, sort: 2),
    ];
    const benefits = [
      Benefit(id: 'yk', membershipId: '88VIP', name: '优酷年卡', claimPlatformId: 'yk', quota: [PerkQuota('term', 1)], sortOrder: 0),
      Benefit(id: 'coupon', membershipId: '88VIP', name: '购物券', quota: [PerkQuota('month', 4)], sortOrder: 1),
      Benefit(id: 'off', membershipId: '88VIP', name: '95 折', sortOrder: 2),
      Benefit(id: 'done', membershipId: '88VIP', name: '领完的', quota: [PerkQuota('month', 1)], sortOrder: 3),
      Benefit(id: 'skip', membershipId: '88VIP', name: '跳过的', quota: [PerkQuota('month', 1)], sortOrder: 4),
      Benefit(id: 'c', membershipId: '88VIP', name: '年卡二选一', kind: 'choice', quota: [PerkQuota('year', 1)], sortOrder: 5),
      Benefit(id: 'o1', membershipId: '88VIP', parentId: 'c', name: '芒果年卡', claimPlatformId: 'yk', sortOrder: 6),
      Benefit(id: 'empty', membershipId: '88VIP', name: '空的二选一', kind: 'choice', sortOrder: 7),
      Benefit(id: 'old', membershipId: '88VIP', name: '过期的', quota: [PerkQuota('month', 1)], validUntil: '2026-09-01', sortOrder: 8),
      Benefit(id: 'soon', membershipId: '88VIP', name: '还没开始', validFrom: '2026-10-01', sortOrder: 9),
      Benefit(id: 'ship', membershipId: 'PLUS', name: '运费券', quota: [PerkQuota('month', 2)]),
      Benefit(id: 'x', membershipId: '老卡', name: '老卡的券', quota: [PerkQuota('month', 2)]),
    ];
    const events = [
      BenefitEvent(id: 'e1', benefitId: 'coupon', occurredOn: '2026-09-02'),
      BenefitEvent(id: 'e2', benefitId: 'done', occurredOn: '2026-09-03'),
      BenefitEvent(id: 'e3', benefitId: 'skip', kind: 'skip', occurredOn: '2026-09-04'),
    ];

    test('本期待领按领取平台分组（N 选 1 按自己的领取平台、成一行），组里截止早的在前；不限次进「随时可用」；用完、跳过进「已完成」', () {
      final now = currentPerks(memberships: ms, benefits: benefits, events: events, platforms: platforms, today: today);
      expect(now.toClaim.map((g) => g.platformId), ['tb', 'yk', 'jd']);
      Iterable<String> ids(String platformId) => now.toClaim.firstWhere((g) => g.platformId == platformId).entries.map((e) => e.benefit.id);
      expect(ids('tb'), ['coupon', 'c'], reason: '购物券 9/30 截止在前，二选一年底');
      expect(ids('yk'), ['yk']);
      expect(ids('jd'), ['ship']);
      expect(now.toClaim.first.entries.last.options.map((o) => o.id), ['o1']);
      expect(now.anytime.map((e) => e.benefit.id), ['off']);
      expect(now.done.map((e) => e.benefit.id), ['done', 'skip']);
      expect(now.toClaimCount, 4);
      final all = [...now.toClaim.expand((g) => g.entries), ...now.anytime, ...now.done].map((e) => e.benefit.id);
      expect(all, isNot(contains('empty')), reason: '没有选项的 N 选 1 没东西可打卡');
      expect(all, isNot(anyOf(contains('old'), contains('soon'), contains('x'))), reason: '过期、未生效、归档卡的不进本期');
    });

    test('「我」：只看自己的和全家共用的', () {
      final mine = currentPerks(memberships: ms, benefits: benefits, events: events, platforms: platforms, today: today, memberId: 'm1');
      expect(mine.toClaim.map((g) => g.platformId), ['tb', 'yk']);
      expect(perkMemberships(ms, memberId: 'u2').map((m) => m.id), ['88VIP', 'PLUS']);
      expect(perkMemberships(ms).map((m) => m.id), ['88VIP', 'PLUS'], reason: '归档的卡不算');
    });
  });
}
