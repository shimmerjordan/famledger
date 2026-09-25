'use strict';

// 会员权益的跨表关系：派生会员（source_benefit_id）不成环；删会员时有权益 409、?cascade=1 在同一事务里
// 连权益、选项、打卡事件一起软删；删掉的权益若带出过派生会员，那张卡的 sourceBenefitId 置空；备份带上新表。
// P2 还没有 /benefit-events 接口：打卡事件用 perks_fixtures.js 的 restartWithEvents 直接写进库里。

const test = require('node:test');
const assert = require('node:assert/strict');

const { household } = require('./fixtures');
const { api } = require('./helpers');
const { restartWithEvents } = require('./perks_fixtures');

/** 一户人家 + 淘宝 / 优酷 + 88VIP 和它的「优酷年卡」+ 由这条权益带出来的优酷VIP。 */
async function withDerived(t) {
  const h = await household(t);
  const { a, auth } = h;
  const tb = (await a.post('/platforms', { name: '淘宝' }, auth)).json.platform;
  const yk = (await a.post('/platforms', { name: '优酷' }, auth)).json.platform;
  const vip = (await a.post('/memberships', { platformId: tb.id, name: '88VIP' }, auth)).json.membership;
  const card = (await a.post('/benefits', { membershipId: vip.id, name: '优酷年卡', kind: 'subscription', claimPlatformId: yk.id }, auth)).json.benefit;
  const made = await a.post('/memberships', { platformId: yk.id, name: '优酷VIP', sourceBenefitId: card.id, termPaidCents: 0 }, auth);
  assert.equal(made.status, 201, made.text);
  return { ...h, tb, yk, vip, card, derived: made.json.membership };
}

test('派生会员：记下是哪条权益带出来的；自己的权益、会成环的链一律 400', async (t) => {
  const { a, auth, tb, vip, card, derived } = await withDerived(t);
  assert.equal(derived.sourceBenefitId, card.id);

  const gone = await a.post('/memberships', { platformId: tb.id, name: '无源卡', sourceBenefitId: 'nope' }, auth);
  assert.equal(gone.status, 400, gone.text);
  assert.equal(gone.json.error.code, 'invalid_sourceBenefitId', '来源权益不存在');

  // 88VIP 不能说自己是它自己的「优酷年卡」带出来的。
  const self = await a.patch(`/memberships/${vip.id}`, { sourceBenefitId: card.id }, auth);
  assert.equal(self.status, 400, self.text);
  assert.equal(self.json.error.code, 'invalid_sourceBenefitId');

  // 88VIP → 优酷VIP；再让 88VIP 派生自优酷VIP 的权益 = 环。
  const perk = (await a.post('/benefits', { membershipId: derived.id, name: '优酷送的淘宝券' }, auth)).json.benefit;
  const loop = await a.patch(`/memberships/${vip.id}`, { sourceBenefitId: perk.id }, auth);
  assert.equal(loop.status, 400, loop.text);
  assert.equal(loop.json.error.code, 'invalid_sourceBenefitId');

  // 不成环的照常：另一张卡派生自优酷VIP 的权益。
  const third = await a.post('/memberships', { platformId: tb.id, name: '淘宝券包', sourceBenefitId: perk.id }, auth);
  assert.equal(third.status, 201, third.text);
  const unlink = await a.patch(`/memberships/${derived.id}`, { sourceBenefitId: null }, auth);
  assert.equal(unlink.json.membership.sourceBenefitId, null, '可以解开');
});

test('权益换卡也不能成环：挪进由它自己（或它的选项）带出来的卡一律 400，什么都不改', async (t) => {
  const { a, auth, tb, yk, vip, card, derived } = await withDerived(t);
  const before = (await a.get('/changes?since=0', auth)).json.next;

  // 「优酷年卡」带出了优酷VIP；把它挪进优酷VIP = 优酷VIP 由它自己名下的权益带出来。
  const self = await a.patch(`/benefits/${card.id}`, { membershipId: derived.id }, auth);
  assert.equal(self.status, 400, self.text);
  assert.equal(self.json.error.code, 'invalid_membershipId');

  // 隔一层也算：优酷VIP 的权益又带出了第三张卡，「优酷年卡」挪进第三张卡照样成环。
  const perk = (await a.post('/benefits', { membershipId: derived.id, name: '优酷送的券' }, auth)).json.benefit;
  const third = (await a.post('/memberships', { platformId: tb.id, name: '券包', sourceBenefitId: perk.id }, auth)).json.membership;
  const deep = await a.patch(`/benefits/${card.id}`, { membershipId: third.id }, auth);
  assert.equal(deep.json.error.code, 'invalid_membershipId');

  // N 选 1 连选项一起搬：选项带出过目标卡时同样拒绝。
  const choice = (await a.post('/benefits', { membershipId: vip.id, name: '年卡二选一', kind: 'choice' }, auth)).json.benefit;
  const option = (await a.post('/benefits', { membershipId: vip.id, name: '芒果年卡', parentId: choice.id }, auth)).json.benefit;
  const mango = (await a.post('/memberships', { platformId: yk.id, name: '芒果VIP', sourceBenefitId: option.id }, auth)).json.membership;
  const withOptions = await a.patch(`/benefits/${choice.id}`, { membershipId: mango.id }, auth);
  assert.equal(withOptions.status, 400, withOptions.text);
  assert.equal(withOptions.json.error.code, 'invalid_membershipId');

  const delta = (await a.get(`/changes?since=${before}`, auth)).json.benefits;
  const byId = Object.fromEntries(delta.map((b) => [b.id, b]));
  assert.equal(byId[card.id], undefined, '被拒的 PATCH 没动这一行');
  assert.equal(byId[option.id].membershipId, vip.id, '选项还在原卡');

  // 不成环的换卡照常：「优酷年卡」挪到和它无关的芒果VIP 下面。
  const ok = await a.patch(`/benefits/${card.id}`, { membershipId: mango.id }, auth);
  assert.equal(ok.status, 200, ok.text);
  assert.equal(ok.json.benefit.membershipId, mango.id);
});

test('删会员：名下有权益时 409 has_children；?cascade=1 连权益、选项、打卡事件一起删，派生会员解开', async (t) => {
  const { srv, auth, vip, card, derived } = await withDerived(t);
  let a = api(srv.base);
  const choice = (await a.post('/benefits', { membershipId: vip.id, name: '二选一', kind: 'choice' }, auth)).json.benefit;
  const option = (await a.post('/benefits', { membershipId: vip.id, name: '芒果', parentId: choice.id }, auth)).json.benefit;

  const refused = await a.del(`/memberships/${vip.id}`, auth);
  assert.equal(refused.status, 409, refused.text);
  assert.equal(refused.json.error.code, 'has_children');
  assert.deepEqual(refused.json.error.details, { benefits: 3 });

  a = await restartWithEvents(t, srv, [{ id: 'e1', benefitId: card.id }, { id: 'e2', benefitId: option.id }]);
  const before = (await a.get('/changes?since=0', auth)).json.next;
  const r = await a.del(`/memberships/${vip.id}?cascade=1`, auth);
  assert.equal(r.status, 200, r.text);

  const delta = (await a.get(`/changes?since=${before}`, auth)).json;
  assert.ok(delta.memberships.find((m) => m.id === vip.id).deletedAt);
  assert.deepEqual(delta.benefits.filter((b) => b.deletedAt).map((b) => b.id).sort(), [card.id, choice.id, option.id].sort());
  assert.deepEqual(delta.benefit_events.filter((e) => e.deletedAt).map((e) => e.id).sort(), ['e1', 'e2']);
  const unlinked = delta.memberships.find((m) => m.id === derived.id);
  assert.equal(unlinked.sourceBenefitId, null, '派生会员还在，只是不再指向被删的权益');
  assert.equal(unlinked.deletedAt, null);
  const seqs = [...delta.memberships, ...delta.benefits, ...delta.benefit_events].map((x) => x.seq);
  assert.equal(new Set(seqs).size, seqs.length, '每行各拿一个 seq');
});

test('删权益（有没有 cascade 都一样）会解开它带出的派生会员', async (t) => {
  const { a, auth, card, derived } = await withDerived(t);
  assert.equal((await a.del(`/benefits/${card.id}`, auth)).status, 200);
  const m = (await a.get('/memberships', auth)).json.items.find((x) => x.id === derived.id);
  assert.equal(m.sourceBenefitId, null);
});

test('备份导出/导入带上平台、会员、权益', async (t) => {
  const { srv, a, auth, token, tb, vip, card } = await withDerived(t);
  const dump = await fetch(`${srv.base}/api/v1/backup/export`, { headers: { authorization: `Bearer ${token}` } });
  assert.equal(dump.status, 200);
  const gz = Buffer.from(await dump.arrayBuffer());

  await a.post('/platforms', { name: '导出之后建的' }, auth);
  await a.del(`/benefits/${card.id}`, auth);
  const r = await fetch(`${srv.base}/api/v1/backup/import`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/gzip' },
    body: gz,
  });
  assert.equal(r.status, 200, await r.text());
  assert.deepEqual((await a.get('/platforms', auth)).json.items.map((p) => p.name), ['淘宝', '优酷']);
  assert.ok((await a.get('/memberships', auth)).json.items.find((m) => m.id === vip.id && m.platformId === tb.id));
  assert.deepEqual((await a.get('/benefits', auth)).json.items.map((b) => b.id), [card.id], '导出之后删的回来了');
});
