'use strict';

// 会员权益的共享校验（lib/perks_schema.js）。CRUD 三个模块和 P4 的导入 apply 用同一套，
// 所以边界值在这里逐条钉住；HTTP 层只再验「接上了」。

const test = require('node:test');
const assert = require('node:assert/strict');

const perks = require('../src/lib/perks_schema');

/** 跑一下，抛了就回 `状态 code`，没抛回 'ok'。 */
function outcome(fn) {
  try {
    fn();
    return 'ok';
  } catch (e) {
    return `${e.status} ${e.code}`;
  }
}

test('normalizeName：NFKC → 小写 → 去空白和标点', () => {
  assert.equal(perks.normalizeName('优酷'), '优酷');
  assert.equal(perks.normalizeName(' 优 酷 '), '优酷');
  assert.equal(perks.normalizeName('ＹＯＵＫＵ'), 'youku', '全角字母按 NFKC 折成半角');
  assert.equal(perks.normalizeName('Tencent·Video!'), 'tencentvideo');
  assert.equal(perks.normalizeName('京东 PLUS（年卡）'), '京东plus年卡');
  assert.equal(perks.normalizeName('88VIP'), '88vip');
  assert.equal(perks.normalizeName('！！！'), '', '全是标点就是空的');
  assert.equal(perks.normalizeName(null), '');
});

test('aliasesOf：去空白、丢空串、按规范化名去重，最多 20 个、每个 ≤30 字', () => {
  assert.deepEqual(perks.aliasesOf([' 天猫 ', '', 'Tmall', 'TMALL', '天 猫']), ['天猫', 'Tmall']);
  assert.deepEqual(perks.aliasesOf(undefined), []);
  assert.deepEqual(perks.aliasesOf(null), []);
  const many = Array.from({ length: 21 }, (_, i) => `别名${i}`);
  assert.equal(outcome(() => perks.aliasesOf(many)), '400 invalid_aliases');
  assert.equal(perks.aliasesOf([...many.slice(0, 20), '别名0']).length, 20, '去重之后没超就行');
  assert.equal(outcome(() => perks.aliasesOf(['x'.repeat(31)])), '400 invalid_aliases');
  assert.equal(outcome(() => perks.aliasesOf([1])), '400 invalid_aliases');
  assert.equal(outcome(() => perks.aliasesOf('天猫')), '400 invalid_aliases');
});

test('quotaOf：[{p,n}]，p 在周期表里且不重复，n 1–9999，最多 3 条；[] 表示不限次', () => {
  assert.deepEqual(perks.quotaOf([]), []);
  assert.deepEqual(perks.quotaOf(null), []);
  assert.deepEqual(
    perks.quotaOf([{ p: 'year', n: 6, extra: 1 }, { p: 'month', n: '2' }]),
    [{ p: 'year', n: 6 }, { p: 'month', n: 2 }],
    '叠加上限；多余的键丢掉，数字字符串照认',
  );
  for (const bad of [
    [{ p: 'decade', n: 1 }],
    [{ p: 'month', n: 0 }],
    [{ p: 'month', n: 10000 }],
    [{ p: 'month', n: 1.5 }],
    [{ p: 'month', n: 1 }, { p: 'month', n: 2 }],
    [{ p: 'day', n: 1 }, { p: 'week', n: 1 }, { p: 'month', n: 1 }, { p: 'year', n: 1 }],
    ['month'],
    { p: 'month', n: 1 },
  ]) {
    assert.equal(outcome(() => perks.quotaOf(bad)), '400 invalid_quota', JSON.stringify(bad));
  }
});

test('limitsOf：[{type,text}]，type 在表里，text 1–200 字，最多 12 条', () => {
  assert.deepEqual(perks.limitsOf([{ type: 'min_spend', text: ' 满 99 可用 ' }]), [{ type: 'min_spend', text: '满 99 可用' }]);
  assert.equal(outcome(() => perks.limitsOf([{ type: 'weather', text: '晴天' }])), '400 invalid_limits');
  assert.equal(outcome(() => perks.limitsOf([{ type: 'other', text: '' }])), '400 invalid_limits');
  assert.equal(outcome(() => perks.limitsOf([{ type: 'other', text: 'x'.repeat(201) }])), '400 invalid_limits');
  const thirteen = Array.from({ length: 13 }, () => ({ type: 'other', text: '限一次' }));
  assert.equal(outcome(() => perks.limitsOf(thirteen)), '400 invalid_limits');
});

test('originOf：只留 src/importId/ev/unverified，ev ≤200 字', () => {
  assert.deepEqual(perks.originOf({}), {});
  assert.deepEqual(
    perks.originOf({ src: 'ai', importId: 'imp-1', ev: '每月 4 张', unverified: ['claimPlatformId'], junk: 1 }),
    { src: 'ai', importId: 'imp-1', ev: '每月 4 张', unverified: ['claimPlatformId'] },
  );
  assert.equal(outcome(() => perks.originOf({ ev: 'x'.repeat(201) })), '400 invalid_origin');
  assert.equal(outcome(() => perks.originOf([])), '400 invalid_origin');
  assert.equal(outcome(() => perks.originOf({ unverified: 'name' })), '400 invalid_origin');
});

test('httpUrl：只收 http/https，≤500；空串是清掉', () => {
  assert.equal(perks.httpUrl('https://vip.youku.com/', 'url'), 'https://vip.youku.com/');
  assert.equal(perks.httpUrl(' http://a.cn ', 'url'), 'http://a.cn');
  assert.equal(perks.httpUrl('', 'url'), null);
  assert.equal(perks.httpUrl(null, 'url'), null);
  assert.equal(outcome(() => perks.httpUrl('javascript:alert(1)', 'claimUrl')), '400 invalid_claimUrl');
  assert.equal(outcome(() => perks.httpUrl('taobao://open', 'url')), '400 invalid_url');
  assert.equal(outcome(() => perks.httpUrl('不是网址', 'url')), '400 invalid_url');
  assert.equal(outcome(() => perks.httpUrl(`https://a.cn/${'x'.repeat(500)}`, 'url')), '400 invalid_url');
});

test('dateOrder：两头都有时止不早于起', () => {
  assert.equal(outcome(() => perks.dateOrder('2026-01-01', '2026-01-01', 'expiresOn', '')), 'ok');
  assert.equal(outcome(() => perks.dateOrder(null, '2020-01-01', 'expiresOn', '')), 'ok');
  assert.equal(outcome(() => perks.dateOrder('2026-02-01', '2026-01-31', 'expiresOn', '')), '400 invalid_expiresOn');
});

test('benefitParentRules：N 选 1 只许一层，选项和父权益同卡、不设额度、flow 跟父权益', () => {
  const choice = { id: 'c', membership_id: 'm1', parent_id: null, kind: 'choice', flow: 'use', quota: '[{"p":"year","n":1}]' };
  const option = (o) => ({ id: 'o', membership_id: 'm1', kind: 'subscription', quota: '[]', ...o });

  assert.deepEqual(perks.benefitParentRules(option({}), choice, 0), { flow: 'use' }, '选项的 flow 跟随父权益');
  assert.deepEqual(perks.benefitParentRules(option({ quota: [] }), null, 0), {}, '没有父权益就没什么要强制的');

  const cases = [
    [option({}), { ...choice, kind: 'coupon' }, 0, '400 invalid_parentId'],
    [option({}), { ...choice, parent_id: 'x' }, 0, '400 invalid_parentId'],
    [option({ membership_id: 'm2' }), choice, 0, '400 invalid_parentId'],
    [option({ kind: 'choice' }), choice, 2, '400 invalid_parentId'],
    [option({ id: 'c', kind: 'choice' }), choice, 0, '400 invalid_parentId'],
    [option({ kind: 'choice' }), choice, 0, '400 invalid_kind'],
    [option({ quota: '[{"p":"month","n":1}]' }), choice, 0, '400 invalid_quota'],
    [option({ quota: [{ p: 'month', n: 1 }] }), choice, 0, '400 invalid_quota'],
    [{ ...choice, kind: 'coupon' }, null, 3, '409 has_options'],
  ];
  for (const [b, parent, n, expected] of cases) {
    assert.equal(outcome(() => perks.benefitParentRules(b, parent, n)), expected, JSON.stringify({ b, parent, n }));
  }
  assert.equal(outcome(() => perks.benefitParentRules(choice, null, 3)), 'ok', '有选项的 choice 自己照常能改');
});

test('checkSourceChain：来源权益存在、不成环、最多查 5 层', () => {
  // m1 ← b1 ;  m2.source = b1 ; b2 属于 m2 ; m3.source = b2 ; b3 属于 m3
  const benefits = {
    b1: { id: 'b1', membership_id: 'm1' },
    b2: { id: 'b2', membership_id: 'm2' },
    b3: { id: 'b3', membership_id: 'm3' },
  };
  const memberships = {
    m1: { id: 'm1', source_benefit_id: null },
    m2: { id: 'm2', source_benefit_id: 'b1' },
    m3: { id: 'm3', source_benefit_id: 'b2' },
  };
  const check = (membershipId, sourceBenefitId, bs = benefits, ms = memberships) => outcome(() => perks.checkSourceChain({
    membershipId,
    sourceBenefitId,
    benefitOf: (id) => bs[id] || null,
    membershipOf: (id) => ms[id] || null,
  }));

  assert.equal(check(null, 'b3'), 'ok', '新建：沿链到头没碰到自己');
  assert.equal(check('m9', 'b1'), 'ok');
  assert.equal(check(null, 'gone'), '400 invalid_sourceBenefitId', '来源权益不存在');
  assert.equal(check('m1', 'b1'), '400 invalid_sourceBenefitId', '自己的权益派生自己');
  assert.equal(check('m1', 'b3'), '400 invalid_sourceBenefitId', 'm1 → m2 → m3 → 又回到 m1');
  assert.equal(check('m2', 'b3'), '400 invalid_sourceBenefitId');

  // 一条 6 层的链：k1 ← k2 ← … ← k6，每张卡都派生自上一张卡的权益。
  const bs = {};
  const ms = {};
  for (let i = 1; i <= 6; i++) {
    bs[`kb${i}`] = { id: `kb${i}`, membership_id: `k${i}` };
    ms[`k${i}`] = { id: `k${i}`, source_benefit_id: i === 1 ? null : `kb${i - 1}` };
  }
  assert.equal(check(null, 'kb4', bs, ms), 'ok', '4 层以内');
  assert.equal(check(null, 'kb6', bs, ms), '400 invalid_sourceBenefitId', '查了 5 层还没到头');
});

test('checkBenefitMove：权益（连选项）不能挪进由它带出来的卡，隔几层都算；最多查 5 层', () => {
  // 同上：m2.source = b1（b1 属于 m1），m3.source = b2（b2 属于 m2）。
  const benefits = {
    b1: { id: 'b1', membership_id: 'm1' },
    b2: { id: 'b2', membership_id: 'm2' },
    o1: { id: 'o1', membership_id: 'm1' },
  };
  const memberships = {
    m1: { id: 'm1', source_benefit_id: null },
    m2: { id: 'm2', source_benefit_id: 'b1' },
    m3: { id: 'm3', source_benefit_id: 'b2' },
    m4: { id: 'm4', source_benefit_id: 'o1' },
  };
  const check = (benefitIds, targetMembershipId, bs = benefits, ms = memberships) => outcome(() => perks.checkBenefitMove({
    benefitIds,
    targetMembershipId,
    benefitOf: (id) => bs[id] || null,
    membershipOf: (id) => ms[id] || null,
  }));

  assert.equal(check(['b1'], 'm2'), '400 invalid_membershipId', 'b1 带出了 m2');
  assert.equal(check(['b1'], 'm3'), '400 invalid_membershipId', 'm3 ← b2 ∈ m2 ← b1：隔一层');
  assert.equal(check(['c1', 'o1'], 'm4'), '400 invalid_membershipId', 'N 选 1 连选项一起搬：选项带出了 m4');
  assert.equal(check(['b2'], 'm1'), 'ok', 'm1 不是 b2 带出来的');
  assert.equal(check(['b1'], 'm4'), 'ok', 'm4 ← o1 ∈ m1，和 b1 无关');
  assert.equal(check(['b1'], 'gone'), 'ok', '目标卡不存在由调用方先 400');

  const bs = {};
  const ms = {};
  for (let i = 1; i <= 7; i++) {
    bs[`kb${i}`] = { id: `kb${i}`, membership_id: `k${i}` };
    ms[`k${i}`] = { id: `k${i}`, source_benefit_id: i === 1 ? null : `kb${i - 1}` };
  }
  assert.equal(check(['x'], 'k5', bs, ms), 'ok', '4 层以内到头');
  assert.equal(check(['x'], 'k7', bs, ms), '400 invalid_membershipId', '查了 5 层还没到头');
});

test('addDays / addPeriod：按 UTC 日历数；续费周期的日号从起点重新夹取（月末截断），once/none 不能续', () => {
  assert.equal(perks.addDays('2026-12-31', 1), '2027-01-01');
  assert.equal(perks.addDays('2026-03-01', -1), '2026-02-28');
  assert.equal(perks.addPeriod('2026-01-31', 'month'), '2026-02-28', '31 号遇到 2 月取月末');
  assert.equal(perks.addPeriod('2026-01-31', 'month', 2), '2026-03-31', '从起点重新夹取，不是 2/28 再加一个月');
  assert.equal(perks.addPeriod('2026-03-31', 'month', -1), '2026-02-28', '往回推也一样');
  assert.equal(perks.addPeriod('2026-11-30', 'quarter'), '2027-02-28');
  assert.equal(perks.addPeriod('2024-02-29', 'year'), '2025-02-28', '闰日');
  assert.equal(perks.addPeriod('2026-09-15', 'year'), '2027-09-15');
  assert.equal(perks.addPeriod('2026-09-15', 'once'), null);
  assert.equal(perks.addPeriod('2026-09-15', 'none'), null);
});

test('取值表：spec §2 列出的枚举一个不少', () => {
  assert.deepEqual(perks.PLATFORM_KINDS, ['shopping', 'video', 'music', 'reading', 'cloud', 'food', 'travel', 'bank', 'telecom', 'game', 'tool', 'other']);
  assert.deepEqual(perks.MEMBERSHIP_KINDS, ['membership', 'subscription', 'credit_card', 'bundle', 'other']);
  assert.deepEqual(perks.FEE_PERIODS, ['month', 'quarter', 'year', 'once', 'none']);
  assert.deepEqual(perks.AUTO_RENEW, ['yes', 'no', 'unknown']);
  assert.deepEqual(perks.BENEFIT_KINDS, ['subscription', 'coupon', 'discount', 'cashback', 'points', 'service', 'lounge', 'shipping', 'insurance', 'choice', 'other']);
  assert.deepEqual(perks.FLOWS, ['claim', 'use', 'claim_use']);
  assert.deepEqual(perks.ANCHORS, ['calendar', 'term']);
  assert.deepEqual(perks.QUOTA_PERIODS, ['day', 'week', 'month', 'quarter', 'year', 'term', 'total']);
  assert.deepEqual(perks.LIMIT_TYPES, ['min_spend', 'scope', 'channel', 'holder', 'device', 'time', 'region', 'stacking', 'other']);
  assert.deepEqual(perks.EVENT_KINDS, ['claim', 'use', 'skip']);
  assert.deepEqual(perks.PERIOD_MONTHS, { month: 1, quarter: 3, year: 12 });
});
