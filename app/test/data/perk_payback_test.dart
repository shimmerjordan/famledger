import 'package:famledger/data/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

// perk_math.dart 的回本部分（spec §3「回本」、§8 App「回本取值顺序、潜在额度」）：固定「今天」= 2026-09-23（周三）。

DateTime d(String s) => parseDay(s)!;
final DateTime today = d('2026-09-23');

int _ids = 0;
BenefitEvent ev(String benefitId, String on, {String kind = 'claim', int count = 1, int? value}) =>
    BenefitEvent(id: 'e${++_ids}', benefitId: benefitId, kind: kind, occurredOn: on, count: count, valueCents: value);

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

void main() {
  group('回本', () {
    test('perkUnitValue：事件自己写的 → 我的估值 → 面值 → 选项看 N 选 1 → 0（未估值）', () {
      final parent = perk('c', kind: 'choice', face: 20000);
      final cases = <(String, ({int cents, bool fromFace, bool known}), int, bool, bool)>[
        ('事件写了价值', perkUnitValue(perk('a', face: 500, mine: 400), override: 300), 300, false, true),
        ('我的估值优先于面值', perkUnitValue(perk('a', face: 500, mine: 400)), 400, false, true),
        ('只有面值：含面值估算', perkUnitValue(perk('a', face: 500)), 500, true, true),
        ('选项没填，看 N 选 1', perkUnitValue(perk('o', parentId: 'c'), parent: parent), 20000, true, true),
        ('选项自己填了用自己的', perkUnitValue(perk('o', parentId: 'c', mine: 100), parent: parent), 100, false, true),
        ('一样都没填', perkUnitValue(perk('a')), 0, false, false),
      ];
      for (final (why, v, cents, fromFace, known) in cases) {
        expect((v.cents, v.fromFace, v.known), (cents, fromFace, known), reason: why);
      }
    });

    test('perkPayback：窗口 = 本期到今天；计额度的事件 × 单价；成本 = 实付 ?? 续费价；时间进度；含面值、未估值', () {
      const card = Membership(
        id: 'mo',
        platformId: 'p',
        name: '月卡',
        feeCents: 2500,
        feePeriod: 'month',
        termStartOn: '2026-09-01',
        expiresOn: '2026-09-30',
      );
      final benefits = [
        perk('a', membershipId: 'mo', quota: const [PerkQuota('month', 4)], face: 500),
        perk('b', membershipId: 'mo', flow: Benefit.flowUse, mine: 1000),
        perk('c', membershipId: 'mo'),
        perk('z', membershipId: 'other', face: 99900),
      ];
      final events = [
        ev('a', '2026-09-10', count: 2),
        ev('a', '2026-08-31'),
        ev('b', '2026-09-21', kind: 'skip'),
        ev('b', '2026-09-15', kind: 'use', value: 300),
        ev('b', '2026-09-15'),
        ev('c', '2026-09-20'),
        ev('z', '2026-09-20'),
      ];
      final p = perkPayback(membership: card, benefits: benefits, events: events, today: today);
      expect(p.realizedCents, 1300, reason: '券 2 × ¥5（上月那张不算）+ 贵宾厅这次写了 ¥3（「领了」「跳过」不算）；别的卡（含派生会员）的不加');
      expect(p.costCents, 2500);
      expect(p.ratioBp, 5200);
      expect(p.timeProgress, closeTo(23 / 30, 1e-9));
      expect(p.usesFaceValue, isTrue);
      expect(p.unvalued, 1, reason: '「c」打过卡但一样价值都没填');
      expect(p.window, DayRange(d('2026-09-01'), today));
      expect(p.potentialCents, 1000, reason: '券本月还剩 2 张 × ¥5；贵宾厅不限次不算');

      final paid0 = perkPayback(membership: const Membership(id: 'mo', platformId: 'p', name: '卡', feeCents: 2500, termPaidCents: 0), benefits: benefits, events: events, today: today);
      expect((paid0.free, paid0.ratioBp, paid0.timeProgress), (true, null, null), reason: '本期实付 0 = 免费；缺本期开始不画时间进度');
      final none = perkPayback(membership: const Membership(id: 'mo', platformId: 'p', name: '卡'), benefits: benefits, events: events, today: today);
      expect(none.costCents, 0);
      const renewed = Membership(
        id: 'mo',
        platformId: 'p',
        name: '卡',
        feeCents: 2500,
        termPaidCents: 0,
        feePeriod: 'month',
        autoRenew: 'yes',
        termStartOn: '2026-08-21',
        expiresOn: '2026-09-20',
      );
      final projected = perkPayback(membership: renewed, benefits: benefits, events: events, today: today);
      expect((projected.costCents, projected.projected, projected.window), (2500, true, DayRange(d('2026-09-21'), today)), reason: '推算本期按续费价');
    });

    test('perkPotential：本期剩余 + 到期前各期；叠加取最小；跳过的本期不算；没到期日只算本期；N 选 1 每期取最贵的几个', () {
      Membership until(String? expires) => Membership(id: 'vip', platformId: 'tb', name: '88VIP', expiresOn: expires);
      int potential(Benefit b, List<BenefitEvent> events, String? expires, {List<Benefit> options = const []}) =>
          perkPotential(benefit: b, membership: until(expires), options: options, events: events, today: today);
      final month4 = perk('a', quota: const [PerkQuota('month', 4)], face: 500);
      expect(potential(month4, [ev('a', '2026-09-01')], '2026-11-30'), (3 + 4 + 4) * 500, reason: '本月剩 3 + 十月、十一月各 4');
      expect(potential(month4, [ev('a', '2026-09-10', kind: 'skip')], '2026-11-30'), 8 * 500, reason: '本月跳过了');
      expect(potential(month4, [ev('a', '2026-09-01')], null), 3 * 500, reason: '长期有效：只算本月剩的');
      final stacked = perk('s', quota: const [PerkQuota('year', 6), PerkQuota('month', 2)], mine: 1000);
      expect(
        potential(stacked, [for (final m in ['01', '02', '03', '04', '05']) ev('s', '2026-$m-01')], '2026-12-31'),
        1000,
        reason: '月上还能 2+2×3=8 次，年里只剩 1 次',
      );
      expect(potential(perk('u', mine: 1000), const [], '2026-12-31'), 0, reason: '不限次不算');
      expect(potential(month4, const [], '2026-09-01'), 0, reason: '已过期');

      final choice = perk('c', kind: 'choice', quota: const [PerkQuota('year', 1)]);
      final options = [perk('o1', parentId: 'c', face: 24800), perk('o2', parentId: 'c', mine: 19800), perk('o3', parentId: 'c')];
      expect(potential(choice, const [], '2027-02-28', options: options), 24800 * 2, reason: '今年挑 1 个 + 明年的那期挑 1 个，都挑最贵的');
      final pick2 = perk('c', kind: 'choice', quota: const [PerkQuota('month', 2)]);
      final cheap = [perk('o1', parentId: 'c', mine: 300), perk('o2', parentId: 'c', mine: 200), perk('o3', parentId: 'c', mine: 100)];
      expect(potential(pick2, const [], '2026-10-31', options: cheap), (300 + 200) * 2, reason: '每月 N 选 2：本月、十月各取最贵的两个');
      expect(potential(pick2, [ev('o1', '2026-09-02')], '2026-10-31', options: cheap), 300 + 500, reason: '本月只剩 1 次');
    });
  });
}
