import 'package:famledger/data/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

// 88VIP（淘宝）：优酷年卡去优酷领、购物券在淘宝领、「年卡二选一」的两个选项一个去芒果一个没写；
// 京东 PLUS（京东）：运费券；归档的老卡；还有一张挂在本地找不到的平台下的卡。
const platforms = [
  PerkPlatform(id: 'tb', name: '淘宝', sortOrder: 0),
  PerkPlatform(id: 'yk', name: '优酷', sortOrder: 1),
  PerkPlatform(id: 'jd', name: '京东', sortOrder: 2),
  PerkPlatform(id: 'mg', name: '芒果TV', sortOrder: 3),
];

const memberships = [
  Membership(id: 'vip', platformId: 'tb', name: '88VIP', sortOrder: 0),
  Membership(id: 'plus', platformId: 'jd', name: '京东PLUS', sortOrder: 1),
  Membership(id: 'old', platformId: 'tb', name: '老卡', sortOrder: 2, archived: true),
  Membership(id: 'ghost', platformId: 'gone', name: '孤儿卡', sortOrder: 3),
];

const benefits = [
  Benefit(id: 'b1', membershipId: 'vip', name: '优酷年卡', claimPlatformId: 'yk', sortOrder: 0),
  Benefit(id: 'b2', membershipId: 'vip', name: '购物券', sortOrder: 1),
  Benefit(id: 'c1', membershipId: 'vip', name: '年卡二选一', kind: 'choice', sortOrder: 2),
  Benefit(id: 'o1', membershipId: 'vip', parentId: 'c1', name: '芒果年卡', claimPlatformId: 'mg', sortOrder: 3),
  Benefit(id: 'o2', membershipId: 'vip', parentId: 'c1', name: '饿了么月卡', sortOrder: 4),
  Benefit(id: 'b3', membershipId: 'vip', name: '归档的券', archived: true, sortOrder: 5),
  Benefit(id: 'b4', membershipId: 'plus', name: '运费券', sortOrder: 0),
  Benefit(id: 'b5', membershipId: 'old', name: '老卡的券', sortOrder: 0),
  Benefit(id: 'b6', membershipId: 'ghost', name: '孤儿券', sortOrder: 0),
];

void main() {
  test('按会员：在用的卡按顺序，顶层权益里 N 选 1 带着选项；归档的权益不出现', () {
    final groups = groupByMembership(memberships: memberships, benefits: benefits, platforms: platforms);
    expect(groups.map((g) => g.membership.id), ['vip', 'plus', 'ghost']);
    final vip = groups.first;
    expect(vip.platform?.name, '淘宝');
    expect(vip.benefits.map((n) => n.benefit.id), ['b1', 'b2', 'c1']);
    expect(vip.benefits[2].options.map((o) => o.id), ['o1', 'o2']);
    expect(vip.itemCount, 4, reason: 'N 选 1 的父权益不算一项，算它的两个选项');
    expect(groups.last.platform, isNull, reason: '平台本地找不到时是 null，界面用 platformLabel 兜底');
    expect(platformLabel(groups.last.platform), '平台已删除');

    final archived = groupByMembership(memberships: memberships, benefits: benefits, platforms: platforms, archived: true);
    expect(archived.map((g) => g.membership.id), ['old']);
  });

  test('按领取平台：选项各按自己的领取平台，没写的跟会员本平台；组按平台顺序，找不到的平台排最后', () {
    final groups = groupByClaimPlatform(memberships: memberships, benefits: benefits, platforms: platforms);
    expect(groups.map((g) => g.platformId), ['tb', 'yk', 'jd', 'mg', 'gone']);
    Iterable<String> names(String id) => groups.firstWhere((g) => g.platformId == id).entries.map((e) => e.benefit.name);
    expect(names('tb'), ['购物券', '饿了么月卡']);
    expect(names('yk'), ['优酷年卡']);
    expect(names('jd'), ['运费券']);
    expect(names('mg'), ['芒果年卡']);
    expect(names('gone'), ['孤儿券']);
    final mango = groups.firstWhere((g) => g.platformId == 'mg').entries.single;
    expect(mango.membership.id, 'vip', reason: '每行都知道来自哪张卡');
    expect(mango.parent?.id, 'c1', reason: '选项带着它的 N 选 1');
    expect(groups.expand((g) => g.entries).any((e) => e.benefit.id == 'c1'), isFalse, reason: 'N 选 1 的父权益本身不是一行');
    expect(groups.expand((g) => g.entries).any((e) => e.benefit.id == 'b5'), isFalse, reason: '归档的卡不进来');
  });

  test('选项自己没写领取平台、它的 N 选 1 写了：跟 N 选 1', () {
    const m = Membership(id: 'm', platformId: 'tb', name: '卡');
    const parent = Benefit(id: 'c', membershipId: 'm', name: '二选一', kind: 'choice', claimPlatformId: 'yk');
    const option = Benefit(id: 'o', membershipId: 'm', parentId: 'c', name: '选项');
    expect(effectiveClaimPlatformId(option, m, parent), 'yk');
    expect(effectiveClaimPlatformId(option, m), 'tb');
  });

  test('选项的父权益本地找不到时当顶层画，不让它消失', () {
    final tree = benefitTree('vip', const [Benefit(id: 'o9', membershipId: 'vip', parentId: 'missing', name: '孤儿选项')]);
    expect(tree.single.benefit.id, 'o9');
  });

  test('归档 = 隐藏：归档的 N 选 1 连选项一起收进「已归档」，不把选项冒成顶层；单独归档的选项各成一行', () {
    const list = [
      Benefit(id: 'c1', membershipId: 'vip', name: '旧的二选一', kind: 'choice', archived: true, sortOrder: 0),
      Benefit(id: 'o1', membershipId: 'vip', parentId: 'c1', name: '旧选项甲', sortOrder: 1),
      Benefit(id: 'o2', membershipId: 'vip', parentId: 'c1', name: '旧选项乙', archived: true, sortOrder: 2),
      Benefit(id: 'c2', membershipId: 'vip', name: '在用的二选一', kind: 'choice', sortOrder: 3),
      Benefit(id: 'o3', membershipId: 'vip', parentId: 'c2', name: '在用选项', sortOrder: 4),
      Benefit(id: 'o4', membershipId: 'vip', parentId: 'c2', name: '下架的选项', archived: true, sortOrder: 5),
      Benefit(id: 'b1', membershipId: 'vip', name: '去年的券', archived: true, sortOrder: 6),
    ];
    final live = benefitTree('vip', list);
    expect(live.map((n) => n.benefit.id), ['c2']);
    expect(live.single.options.map((o) => o.id), ['o3']);
    expect(perkItemCount(live), 1);

    final archived = archivedBenefitTree('vip', list);
    expect(archived.map((n) => n.benefit.id), ['c1', 'o4', 'b1']);
    expect(archived.first.options.map((o) => o.id), ['o1', 'o2'], reason: '归档的 N 选 1 带着它的全部选项');
    expect(perkItemCount(archived), 4);
  });

  test('quotaLabel：预设的几种说法和叠加', () {
    expect(quotaLabel(const []), '不限次');
    expect(quotaLabel(const [PerkQuota('month', 4)]), '每月 4 次');
    expect(quotaLabel(const [PerkQuota('year', 6), PerkQuota('month', 2)]), '每年 6 次 · 每月最多 2 次');
    expect(quotaLabel(const [PerkQuota('term', 1)]), '会籍期内 1 次');
    expect(quotaLabel(const [PerkQuota('total', 1)]), '一次性');
    expect(quotaLabel(const [PerkQuota('total', 3)]), '总共 3 次');
  });

  test('feeLabel / expiryLabel', () {
    expect(feeLabel(const Membership(id: 'm', platformId: 'p', name: 'x', feeCents: 8800)), '¥88.00/年');
    expect(feeLabel(const Membership(id: 'm', platformId: 'p', name: 'x', feeCents: 2500, feePeriod: 'month')), '¥25.00/月');
    expect(feeLabel(const Membership(id: 'm', platformId: 'p', name: 'x', feeCents: 19900, feePeriod: 'once')), '一次性 ¥199.00');
    expect(feeLabel(const Membership(id: 'm', platformId: 'p', name: 'x', feePeriod: 'none')), '不收费');
    expect(feeLabel(const Membership(id: 'm', platformId: 'p', name: 'x')), isNull);

    final today = DateTime(2026, 9, 23, 10);
    expect(expiryLabel(const Membership(id: 'm', platformId: 'p', name: 'x'), today), '长期有效');
    expect(expiryLabel(const Membership(id: 'm', platformId: 'p', name: 'x', expiresOn: '2026-09-23'), today), '今天到期');
    expect(expiryLabel(const Membership(id: 'm', platformId: 'p', name: 'x', expiresOn: '2027-02-28'), today), '还有 158 天到期');
    expect(expiryLabel(const Membership(id: 'm', platformId: 'p', name: 'x', expiresOn: '2026-09-20'), today), '已过期 3 天');
  });
}
