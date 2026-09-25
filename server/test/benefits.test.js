'use strict';

// 权益：CRUD 与校验（额度、限制条件、链接、有效期、领取平台）、N 选 1 的父子规则（只许一层、选项不设额度、
// flow 跟父权益、父权益换卡选项跟着搬、有选项时不能改类型）、删除（有选项 409、?cascade=1 一起删）、同步墓碑；
// 以及 P2 的验收：手工建出 88VIP 和它的 3 项权益，其中 1 项去优酷领。打卡事件走真的 /benefit-events。

const test = require('node:test');
const assert = require('node:assert/strict');

const { household } = require('./fixtures');

const pad = (n) => String(n).padStart(2, '0');
function localDay(days = 0) {
  const d = new Date();
  d.setDate(d.getDate() + days);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

/** 一户人家 + 淘宝 / 优酷 + 淘宝下的 88VIP。 */
async function withVip(t) {
  const h = await household(t);
  const tb = (await h.a.post('/platforms', { name: '淘宝' }, h.auth)).json.platform;
  const yk = (await h.a.post('/platforms', { name: '优酷' }, h.auth)).json.platform;
  const vip = (await h.a.post('/memberships', { platformId: tb.id, name: '88VIP', feeCents: 8800 }, h.auth)).json.membership;
  const post = (body) => h.a.post('/benefits', { membershipId: vip.id, ...body }, h.auth);
  return { ...h, tb, yk, vip, post };
}

test('验收：手工建出 88VIP 和它的 3 项权益，其中 1 项去优酷领', async (t) => {
  const { a, auth, tb, yk, vip, post } = await withVip(t);

  const youku = await post({
    name: '优酷VIP年卡', kind: 'subscription', claimPlatformId: yk.id, claimHow: '优酷App › 我的 › 88VIP 专区',
    claimUrl: 'https://vip.youku.com/88vip', flow: 'claim', quota: [{ p: 'term', n: 1 }], faceValueCents: 24800,
  });
  const coupon = await post({
    name: '淘宝购物券', kind: 'coupon', flow: 'claim_use', quota: [{ p: 'month', n: 4 }],
    limits: [{ type: 'min_spend', text: '满 99 可用' }], faceValueCents: 500,
  });
  const discount = await post({ name: '天猫超市 95 折', kind: 'discount', flow: 'use', quota: [] });
  for (const r of [youku, coupon, discount]) assert.equal(r.status, 201, r.text);

  const perk = youku.json.benefit;
  assert.equal(perk.membershipId, vip.id);
  assert.equal(perk.claimPlatformId, yk.id, '去优酷领');
  assert.equal(perk.claimHow, '优酷App › 我的 › 88VIP 专区');
  assert.deepEqual(perk.quota, [{ p: 'term', n: 1 }]);
  assert.equal(coupon.json.benefit.claimPlatformId, null, '空 = 在会员本平台（淘宝）领');
  assert.deepEqual(coupon.json.benefit.limits, [{ type: 'min_spend', text: '满 99 可用' }]);
  assert.deepEqual(discount.json.benefit.quota, [], '[] = 不限次');

  const all = (await a.get('/changes?since=0', auth)).json;
  assert.deepEqual(all.platforms.map((p) => p.name).sort(), ['优酷', '淘宝']);
  assert.deepEqual(all.memberships.map((m) => [m.name, m.platformId]), [['88VIP', tb.id]]);
  assert.deepEqual(all.benefits.map((b) => b.name), ['优酷VIP年卡', '淘宝购物券', '天猫超市 95 折']);
  assert.deepEqual(all.benefits.filter((b) => b.claimPlatformId === yk.id).map((b) => b.name), ['优酷VIP年卡']);
});

test('权益默认值；PATCH 不动没传的字段；有效期可以在将来', async (t) => {
  const { a, auth, post } = await withVip(t);
  const r = await post({ name: '券' });
  assert.equal(r.status, 201, r.text);
  const b = r.json.benefit;
  assert.equal(b.kind, 'other');
  assert.equal(b.flow, 'claim');
  assert.deepEqual(b.quota, []);
  assert.equal(b.anchor, 'calendar');
  assert.deepEqual(b.limits, []);
  assert.equal(b.remind, true);
  assert.deepEqual(b.origin, {});
  assert.equal(b.parentId, null);
  assert.equal(b.archived, false);

  const patched = await a.patch(`/benefits/${b.id}`, {
    quota: [{ p: 'year', n: 6 }, { p: 'month', n: 2 }], anchor: 'term', validFrom: localDay(10), validUntil: localDay(400),
    myValueCents: 3000, remind: false,
  }, auth);
  assert.equal(patched.status, 200, patched.text);
  assert.deepEqual(patched.json.benefit.quota, [{ p: 'year', n: 6 }, { p: 'month', n: 2 }], '叠加上限');
  assert.equal(patched.json.benefit.validUntil, localDay(400));
  assert.equal(patched.json.benefit.remind, false);
  const renamed = await a.patch(`/benefits/${b.id}`, { name: '贵宾厅' }, auth);
  assert.deepEqual(renamed.json.benefit.quota, [{ p: 'year', n: 6 }, { p: 'month', n: 2 }]);
  assert.equal(renamed.json.benefit.validFrom, localDay(10));
  const moved = await a.patch(`/benefits/${b.id}`, { validFrom: localDay(401) }, auth);
  assert.equal(moved.status, 400, '只挪开始日到结束日之后也不行');
  assert.equal(moved.json.error.code, 'invalid_validFrom');
});

test('权益校验：非法输入一律 400', async (t) => {
  const { a, auth, post } = await withVip(t);
  const cases = [
    [{ membershipId: undefined, name: '券' }, 'invalid_membershipId'],
    [{ membershipId: '', name: '券' }, 'invalid_membershipId'],
    [{ membershipId: 'nope', name: '券' }, 'invalid_membershipId'],
    [{ name: '' }, 'invalid_name'],
    [{ name: 'x'.repeat(61) }, 'invalid_name'],
    [{ name: '券', kind: 'gift' }, 'invalid_kind'],
    [{ name: '券', flow: 'grant' }, 'invalid_flow'],
    [{ name: '券', anchor: 'date' }, 'invalid_anchor'],
    [{ name: '券', claimPlatformId: 'nope' }, 'invalid_claimPlatformId'],
    [{ name: '券', claimHow: 'x'.repeat(201) }, 'invalid_claimHow'],
    [{ name: '券', claimUrl: 'taobao://x' }, 'invalid_claimUrl'],
    [{ name: '券', quota: [{ p: 'month', n: 0 }] }, 'invalid_quota'],
    [{ name: '券', quota: [{ p: 'month', n: 1 }, { p: 'month', n: 2 }] }, 'invalid_quota'],
    [{ name: '券', quota: 'month' }, 'invalid_quota'],
    [{ name: '券', limits: [{ type: 'weather', text: '晴天' }] }, 'invalid_limits'],
    [{ name: '券', validFrom: '2026-02-30' }, 'invalid_validFrom'],
    [{ name: '券', validFrom: '2026-09-01', validUntil: '2026-08-31' }, 'invalid_validUntil'],
    [{ name: '券', faceValueCents: -1 }, 'invalid_faceValueCents'],
    [{ name: '券', myValueCents: 1.5 }, 'invalid_myValueCents'],
    [{ name: '券', parentId: 'nope' }, 'invalid_parentId'],
    [{ name: '券', origin: 'ai' }, 'invalid_origin'],
    [{ name: '券', note: 'x'.repeat(501) }, 'invalid_note'],
  ];
  for (const [body, code] of cases) {
    const r = await post(body);
    assert.equal(r.status, 400, `${JSON.stringify(body)} → ${r.status} ${r.text}`);
    assert.equal(r.json.error.code, code, JSON.stringify(body));
  }
  assert.deepEqual((await a.get('/benefits?archived=1', auth)).json.items, [], '校验失败一条都不落库');
});

test('N 选 1：选项挂在同卡的 choice 下，flow 跟父权益、不设额度；只许一层', async (t) => {
  const { a, auth, tb, yk, post } = await withVip(t);
  const choice = (await post({ name: '年卡四选一', kind: 'choice', flow: 'use', quota: [{ p: 'year', n: 1 }] })).json.benefit;

  const opt = await post({ name: '优酷年卡', kind: 'subscription', parentId: choice.id, claimPlatformId: yk.id, flow: 'claim' });
  assert.equal(opt.status, 201, opt.text);
  assert.equal(opt.json.benefit.parentId, choice.id);
  assert.equal(opt.json.benefit.flow, 'use', 'flow 跟随父权益，不看请求里写的');

  const withQuota = await post({ name: '爱奇艺年卡', parentId: choice.id, quota: [{ p: 'year', n: 1 }] });
  assert.equal(withQuota.json.error.code, 'invalid_quota', '选项不单独设额度');
  const nested = await post({ name: '套娃', parentId: opt.json.benefit.id });
  assert.equal(nested.json.error.code, 'invalid_parentId', '选项下面不能再挂');
  const notChoice = (await post({ name: '普通券' })).json.benefit;
  assert.equal((await post({ name: '挂错', parentId: notChoice.id })).json.error.code, 'invalid_parentId');
  const choiceOption = await post({ name: '选项也是 choice', kind: 'choice', parentId: choice.id });
  assert.equal(choiceOption.json.error.code, 'invalid_kind');

  const other = (await a.post('/memberships', { platformId: tb.id, name: '淘宝省钱卡' }, auth)).json.membership;
  const cross = await a.post('/benefits', { membershipId: other.id, name: '跨卡', parentId: choice.id }, auth);
  assert.equal(cross.json.error.code, 'invalid_parentId', '选项要和父权益同卡');

  // 有选项的 choice 不能改成别的类型；挂到别的权益下（变两层）也不行。
  const kind = await a.patch(`/benefits/${choice.id}`, { kind: 'coupon' }, auth);
  assert.equal(kind.status, 409, kind.text);
  assert.equal(kind.json.error.code, 'has_options');
  assert.deepEqual(kind.json.error.details, { options: 1 });
  const choice2 = (await post({ name: '另一组', kind: 'choice' })).json.benefit;
  assert.equal((await a.patch(`/benefits/${choice.id}`, { parentId: choice2.id }, auth)).json.error.code, 'invalid_parentId');
  assert.equal((await a.patch(`/benefits/${choice.id}`, { parentId: choice.id }, auth)).json.error.code, 'invalid_parentId');

  // 选项脱离父权益后就能自己设额度了。
  const freed = await a.patch(`/benefits/${opt.json.benefit.id}`, { parentId: null, quota: [{ p: 'term', n: 1 }] }, auth);
  assert.equal(freed.status, 200, freed.text);
  assert.equal(freed.json.benefit.parentId, null);
});

test('父权益换卡、改 flow：选项跟着一起改，各拿新的 seq', async (t) => {
  const { a, auth, tb, post } = await withVip(t);
  const choice = (await post({ name: '年卡二选一', kind: 'choice', flow: 'claim' })).json.benefit;
  const o1 = (await post({ name: '优酷', parentId: choice.id })).json.benefit;
  const o2 = (await post({ name: '芒果', parentId: choice.id })).json.benefit;
  const other = (await a.post('/memberships', { platformId: tb.id, name: '淘宝省钱卡' }, auth)).json.membership;
  const before = (await a.get('/changes?since=0', auth)).json.next;

  const r = await a.patch(`/benefits/${choice.id}`, { membershipId: other.id, flow: 'use' }, auth);
  assert.equal(r.status, 200, r.text);
  const delta = (await a.get(`/changes?since=${before}`, auth)).json.benefits;
  const byId = Object.fromEntries(delta.map((b) => [b.id, b]));
  for (const o of [o1, o2]) {
    assert.equal(byId[o.id].membershipId, other.id, '选项跟着搬到新卡');
    assert.equal(byId[o.id].flow, 'use');
  }
  assert.equal(new Set(delta.map((b) => b.seq)).size, delta.length, '每行各拿一个 seq');

  // 单独把选项挪到别的卡：父权益还在原卡，不行。
  const lone = await a.patch(`/benefits/${o1.id}`, { membershipId: (await a.get('/memberships', auth)).json.items[0].id }, auth);
  assert.equal(lone.json.error.code, 'invalid_parentId');
});

test('删权益：有选项时 409 has_children；?cascade=1 连选项一起软删', async (t) => {
  const { a, auth, post } = await withVip(t);
  const choice = (await post({ name: '年卡二选一', kind: 'choice' })).json.benefit;
  const o1 = (await post({ name: '优酷', parentId: choice.id })).json.benefit;
  const lone = (await post({ name: '单独的券' })).json.benefit;

  const refused = await a.del(`/benefits/${choice.id}`, auth);
  assert.equal(refused.status, 409, refused.text);
  assert.equal(refused.json.error.code, 'has_children');
  assert.deepEqual(refused.json.error.details, { options: 1, events: 0 });

  assert.equal((await a.del(`/benefits/${lone.id}`, auth)).status, 200, '没有子项直接删');
  const before = (await a.get('/changes?since=0', auth)).json.next;
  const r = await a.del(`/benefits/${choice.id}?cascade=1`, auth);
  assert.equal(r.status, 200, r.text);
  const tomb = (await a.get(`/changes?since=${before}`, auth)).json.benefits;
  assert.deepEqual(tomb.map((b) => b.id).sort(), [choice.id, o1.id].sort());
  assert.ok(tomb.every((b) => b.deletedAt));
  assert.deepEqual((await a.get('/benefits?archived=1', auth)).json.items, []);
});

test('删权益：有打卡事件时 409 has_children；?cascade=1 连选项的事件一起软删', async (t) => {
  const { a, auth, post } = await withVip(t);
  const lone = (await post({ name: '贵宾厅' })).json.benefit;
  const choice = (await post({ name: '二选一', kind: 'choice' })).json.benefit;
  const option = (await post({ name: '芒果', parentId: choice.id })).json.benefit;
  const e1 = (await a.post('/benefit-events', { benefitId: lone.id, kind: 'use' }, auth)).json.event;
  const e2 = (await a.post('/benefit-events', { benefitId: option.id }, auth)).json.event;

  const refused = await a.del(`/benefits/${lone.id}`, auth);
  assert.equal(refused.status, 409, refused.text);
  assert.deepEqual(refused.json.error.details, { options: 0, events: 1 });
  const refused2 = await a.del(`/benefits/${choice.id}`, auth);
  assert.deepEqual(refused2.json.error.details, { options: 1, events: 1 }, '选项的事件也算');

  const before = (await a.get('/changes?since=0', auth)).json.next;
  assert.equal((await a.del(`/benefits/${lone.id}?cascade=1`, auth)).status, 200);
  assert.equal((await a.del(`/benefits/${choice.id}?cascade=1`, auth)).status, 200);
  const delta = (await a.get(`/changes?since=${before}`, auth)).json;
  assert.deepEqual(delta.benefit_events.filter((e) => e.deletedAt).map((e) => e.id).sort(), [e1.id, e2.id].sort());
  assert.deepEqual(delta.benefits.filter((b) => b.deletedAt).map((b) => b.id).sort(), [lone.id, choice.id, option.id].sort());
});

test('/changes 同步 benefits：quota / limits 还原成数组、remind 布尔', async (t) => {
  const { a, auth, post } = await withVip(t);
  const before = (await a.get('/changes?since=0', auth)).json.next;
  const b = (await post({ name: '券', quota: [{ p: 'month', n: 1 }], limits: [{ type: 'channel', text: '仅 App' }], remind: false })).json.benefit;
  const row = (await a.get(`/changes?since=${before}`, auth)).json.benefits[0];
  assert.equal(row.id, b.id);
  assert.deepEqual(row.quota, [{ p: 'month', n: 1 }]);
  assert.deepEqual(row.limits, [{ type: 'channel', text: '仅 App' }]);
  assert.equal(row.remind, false);
  assert.equal(row.archived, false);
});

test('新建权益带 clientId：回应丢了再点保存，只建一条（重发回第一次的那行）', async (t) => {
  const { a, auth, post } = await withVip(t);
  const first = await post({ name: '优酷年卡', clientId: 'benefit-1' });
  assert.equal(first.status, 201, first.text);
  const again = await post({ name: '优酷年卡', clientId: 'benefit-1' });
  assert.equal(again.status, 200, again.text);
  assert.equal(again.json.replayed, true);
  assert.equal(again.json.benefit.id, first.json.benefit.id);
  const other = await post({ name: '优酷年卡', clientId: 'benefit-2' });
  assert.equal(other.status, 201, '换一个 clientId 就是另一条');
  assert.equal((await a.get('/benefits', auth)).json.items.length, 2);
  assert.equal((await post({ name: '券', clientId: 'x'.repeat(65) })).json.error.code, 'invalid_clientId');
});
