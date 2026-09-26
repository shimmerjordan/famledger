'use strict';

// 从流水识别 · 直接生成（spec §4 POST /asset-import/extract kind=transactions、§6「从流水」）：真服务 + 真 HTTP。
// 钉死：全程不调 AI（假上游一个请求都没收到）、没有渠道也能用、不占导入限流；草稿的费用 = 中位数、到期日 = 最近一次扣费 + 周期、
// 带扣费特征和上次扣费那笔；落库写 pay_pattern / last_charge_tx_id，origin.src = ai_transactions；导入后这组标「已关联」、撤销后
// 回来；最近那笔已经挂在别的卡上、或者是某件物品的购买流水时新卡不抢（物品那笔在候选里也标「已关联」）；已有同名卡转成更新、
// 默认补上扣费特征，原来设过、不一样的只展示、不改；groups / months / useAi 校验与 groups_stale。

const test = require('node:test');
const assert = require('node:assert/strict');

const { openDb } = require('../src/lib/db');
const perks = require('../src/lib/perks_schema');
const { applyBodyOf } = require('./import_fixtures');
const { localDay, setupSubscriptions, seedAcceptance } = require('./subscription_fixtures');

test('验收：候选名单只有腾讯视频、88VIP（顺序确定、两次一样），噪声全排除；直接生成出草稿，全程不调 AI', async (t) => {
  const ctx = await setupSubscriptions(t);
  const { up, h, candidates, extract } = ctx;
  const { tv, vip } = await seedAcceptance(ctx);
  const first = await candidates();
  assert.deepEqual(first.items.map((g) => g.merchant), ['腾讯视频', '88VIP']);
  assert.deepEqual([first.months, first.total, first.today, first.from], [13, 2, localDay(0), perks.addPeriod(localDay(0), 'month', -13)]);
  const [g1, g2] = first.items;
  assert.deepEqual(
    [g1.amountCents, g1.count, g1.period, g1.lastOn, g1.nextOn, g1.score, g1.checked, g1.linked, g1.lastTransactionId],
    [3000, 7, 'month', localDay(-5), perks.addPeriod(localDay(-5), 'month'), 7, true, null, tv[0].id],
  );
  assert.deepEqual([g2.count, g2.period, g2.score, g2.checked, g2.lastTransactionId], [1, 'year', 5, true, vip.id]);
  assert.deepEqual(await candidates(), first, '同样的流水、同样的名单');

  const r = await extract({ groups: [g1.key, g2.key] });
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.events.map((e) => e.event), ['stage', 'done']);
  const { importId, draft } = r.of('done')[0].data;
  assert.deepEqual([draft.importId, draft.want, draft.source, draft.providerId, draft.truncated], [importId, 'virtual', { kind: 'transactions', groups: 2 }, null, false]);
  assert.deepEqual(draft.platforms.map((p) => [p.fields.name, p.action]), [['腾讯视频', 'create'], ['88VIP', 'create']]);
  const [m1, m2] = draft.memberships;
  assert.deepEqual(m1.fields, {
    platform: `key:${draft.platforms[0].key}`, name: '腾讯视频', tier: null, kind: 'subscription', feeCents: 3000, feePeriod: 'month',
    termStartOn: localDay(-5), expiresOn: perks.addPeriod(localDay(-5), 'month'), autoRenew: 'yes', isTrial: false,
    payPattern: { keywords: ['腾讯视频'], minCents: 2400, maxCents: 3600 }, lastChargeTxId: tv[0].id,
  });
  assert.deepEqual([m1.unverified, m1.badges, m1.checked, m1.ev], [[], [], true, `腾讯视频 ¥30.00 × 7 次（${localDay(-185)} 至 ${localDay(-5)}）`]);
  assert.deepEqual([m2.fields.feeCents, m2.fields.feePeriod, m2.fields.autoRenew, m2.fields.expiresOn], [8800, 'year', 'unknown', perks.addPeriod(localDay(-40), 'year')]);
  assert.equal(draft.benefits.length + draft.items.length, 0);
  assert.equal(up.requests.length, 0, '直接生成一个请求都不该打到上游');

  await h.srv.stop();
  const db = openDb(h.srv.dataDir);
  try {
    const row = db.get('SELECT status, source_kind, provider_id, usage_in, usage_out FROM ai_imports WHERE id = ?', importId);
    assert.deepEqual({ ...row }, { status: 'extracted', source_kind: 'transactions', provider_id: null, usage_in: 0, usage_out: 0 });
  } finally {
    db.close();
  }
});

test('落库：会员写上扣费特征、上次扣费、到期日，origin 记 ai_transactions；导入后这两组标「已关联」、不再默认勾；撤销后又回来', async (t) => {
  const ctx = await setupSubscriptions(t, { provider: false });
  const { h, candidates, extract } = ctx;
  const { tv, vip } = await seedAcceptance(ctx);
  const keys = (await candidates()).items.map((g) => g.key);
  const done = (await extract({ groups: keys })).of('done')[0].data;
  const r = await h.a.post('/asset-import/apply', applyBodyOf(done, { clientId: 'tx-apply-1' }), h.auth);
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.json.created, { platforms: 2, memberships: 2, benefits: 0, items: 0, transactions: 0 });

  const cards = (await h.a.get('/changes?since=0', h.auth)).json.memberships;
  const tvCard = cards.find((m) => m.name === '腾讯视频');
  assert.deepEqual(
    [tvCard.payPattern, tvCard.lastChargeTxId, tvCard.feeCents, tvCard.feePeriod, tvCard.termStartOn, tvCard.expiresOn, tvCard.autoRenew, tvCard.origin.src],
    [{ keywords: ['腾讯视频'], minCents: 2400, maxCents: 3600 }, tv[0].id, 3000, 'month', localDay(-5), perks.addPeriod(localDay(-5), 'month'), 'yes', 'ai_transactions'],
  );
  assert.equal(cards.find((m) => m.name === '88VIP').lastChargeTxId, vip.id);
  assert.deepEqual((await h.a.get('/memberships/charge-hints', h.auth)).json.items, [], '最近那笔在上一期，不会被当成这一期的扣费');

  const after = await candidates();
  assert.deepEqual(after.items.map((g) => [g.merchant, g.linked && g.linked.name, g.checked]), [['腾讯视频', '腾讯视频', false], ['88VIP', '88VIP', false]]);

  const undo = await h.a.post(`/asset-import/${done.importId}/undo`, {}, h.auth);
  assert.equal(undo.status, 200, undo.text);
  assert.deepEqual((await candidates()).items.map((g) => [g.linked, g.checked]), [[null, true], [null, true]]);
});

test('最近那笔已经挂在别的卡上（续费关联过）还勾了这组：照样导入，新卡不抢那笔（一笔流水只算一张卡）', async (t) => {
  const ctx = await setupSubscriptions(t, { provider: false });
  const { h, spend, candidates, extract } = ctx;
  const txs = [];
  for (let i = 0; i < 3; i++) txs.push(await spend(-5 - 30 * i, 3000, '腾讯视频'));
  const p = (await h.a.post('/platforms', { name: '视频会员' }, h.auth)).json.platform;
  const other = (await h.a.post('/memberships', { platformId: p.id, name: '家庭影音', feeCents: 3000, feePeriod: 'month', expiresOn: localDay(-6) }, h.auth)).json.membership;
  const renew = await h.a.post(`/memberships/${other.id}/renew`, { chargeTransactionId: txs[0].id, paidCents: 3000, clientId: 'renew-other' }, h.auth);
  assert.equal(renew.status, 200, renew.text);
  const [g] = (await candidates()).items;
  assert.deepEqual([g.linked, g.checked], [{ membershipId: other.id, name: '家庭影音' }, false]);
  const done = (await extract({ groups: [g.key] })).of('done')[0].data;
  assert.equal(done.draft.memberships[0].fields.lastChargeTxId, txs[0].id);
  const r = await h.a.post('/asset-import/apply', applyBodyOf(done, { clientId: 'tx-apply-taken' }), h.auth);
  assert.equal(r.status, 200, r.text);
  const cards = (await h.a.get('/changes?since=0', h.auth)).json.memberships;
  assert.equal(cards.find((m) => m.id === r.json.ids.m1).lastChargeTxId, null, '那笔还算在「家庭影音」上');
  assert.equal(cards.find((m) => m.id === other.id).lastChargeTxId, txs[0].id);
});

test('物品的购买流水（和 charge_hints 一个口径）：候选里标「已关联」那件物品、不默认勾；硬勾上导入，新卡也不拿它当上次扣费', async (t) => {
  const ctx = await setupSubscriptions(t, { provider: false });
  const { h, candidates, extract } = ctx;
  const item = await h.a.post('/assets', {
    name: '山姆会员年卡', category: 'other', priceCents: 26000, purchasedOn: localDay(-3), recordTransaction: { accountId: h.account.id },
  }, h.auth);
  assert.equal(item.status, 201, item.text);
  const [g] = (await candidates()).items;
  assert.deepEqual([g.merchant, g.linked, g.checked], ['山姆会员年卡', { assetId: item.json.asset.id, name: '山姆会员年卡' }, false]);
  const done = (await extract({ groups: [g.key] })).of('done')[0].data;
  assert.equal(done.draft.memberships[0].fields.lastChargeTxId, item.json.asset.transactionId);
  const r = await h.a.post('/asset-import/apply', applyBodyOf(done, { clientId: 'tx-apply-asset' }), h.auth);
  assert.equal(r.status, 200, r.text);
  const card = (await h.a.get('/changes?since=0', h.auth)).json.memberships.find((m) => m.id === r.json.ids.m1);
  assert.equal(card.lastChargeTxId, null, '那笔是物品的，不再挂到卡上');
});

test('已有同名卡、原来设过不一样的扣费特征：差异只展示、默认不勾；按默认提交，库里的扣费特征保持原样', async (t) => {
  const ctx = await setupSubscriptions(t, { provider: false });
  const { h, spend, candidates, extract } = ctx;
  for (let i = 0; i < 3; i++) await spend(-5 - 30 * i, 3000, '腾讯视频');
  const p = (await h.a.post('/platforms', { name: '腾讯视频' }, h.auth)).json.platform;
  const mine = { keywords: ['腾讯视频VIP'], minCents: 2800, maxCents: 3200 };
  const old = (await h.a.post('/memberships', { platformId: p.id, name: '腾讯视频', feeCents: 3000, feePeriod: 'month', expiresOn: localDay(-20), payPattern: mine }, h.auth)).json.membership;
  const [g] = (await candidates()).items;
  const done = (await extract({ groups: [g.key] })).of('done')[0].data;
  const m = done.draft.memberships[0];
  assert.deepEqual([m.action, m.targetId], ['update', old.id]);
  const pay = m.diff.find((d) => d.field === 'payPattern');
  assert.deepEqual([pay.old, pay.take], [mine, false]);
  const r = await h.a.post('/asset-import/apply', applyBodyOf(done, { clientId: 'tx-apply-keep' }), h.auth);
  assert.equal(r.status, 200, r.text);
  const card = (await h.a.get('/changes?since=0', h.auth)).json.memberships.find((x) => x.id === old.id);
  assert.deepEqual([card.payPattern, card.expiresOn], [mine, perks.addPeriod(localDay(-5), 'month')], '扣费特征没动，到期日照样取更晚的');
});

test('已有同名卡：转成更新，默认补上扣费特征、到期日取更晚的，费用不同只提示', async (t) => {
  const ctx = await setupSubscriptions(t, { provider: false });
  const { h, spend, candidates, extract } = ctx;
  for (let i = 0; i < 3; i++) await spend(-5 - 30 * i, 3000, '腾讯视频');
  const p = (await h.a.post('/platforms', { name: '腾讯视频' }, h.auth)).json.platform;
  const old = (await h.a.post('/memberships', { platformId: p.id, name: '腾讯视频', feeCents: 2500, feePeriod: 'month', expiresOn: localDay(-20) }, h.auth)).json.membership;
  const [g] = (await candidates()).items;
  assert.deepEqual([g.linked, g.checked], [null, true], '没设扣费特征的卡不算关联');
  const done = (await extract({ groups: [g.key] })).of('done')[0].data;
  const m = done.draft.memberships[0];
  assert.deepEqual([m.action, m.targetId], ['update', old.id]);
  const diff = Object.fromEntries(m.diff.map((d) => [d.field, d.take]));
  assert.deepEqual(diff, { kind: false, feeCents: false, termStartOn: true, expiresOn: true, autoRenew: true, payPattern: true });
  const r = await h.a.post('/asset-import/apply', applyBodyOf(done, { clientId: 'tx-apply-2' }), h.auth);
  assert.equal(r.status, 200, r.text);
  const card = (await h.a.get('/changes?since=0', h.auth)).json.memberships.find((x) => x.id === old.id);
  assert.deepEqual([card.payPattern, card.feeCents, card.expiresOn, card.lastChargeTxId], [
    { keywords: ['腾讯视频'], minCents: 2400, maxCents: 3600 }, 2500, perks.addPeriod(localDay(-5), 'month'), null,
  ]);
});

test('校验：groups 必填（1–40 个）、months 1–24、不能指定卡；勾的组全对不上 409 groups_stale，对上一部分照做并说明', async (t) => {
  const ctx = await setupSubscriptions(t, { provider: false });
  const { h, spend, candidates, extract } = ctx;
  for (let i = 0; i < 3; i++) await spend(-5 - 30 * i, 3000, '腾讯视频');
  const [g] = (await candidates()).items;
  const cases = [
    [{}, 400, 'invalid_groups'],
    [{ groups: [] }, 400, 'invalid_groups'],
    [{ groups: 'g_1' }, 400, 'invalid_groups'],
    [{ groups: Array.from({ length: 41 }, (_, i) => `g_${i}`) }, 400, 'invalid_groups'],
    [{ groups: [g.key], months: 0 }, 400, 'invalid_months'],
    [{ groups: [g.key], months: 25 }, 400, 'invalid_months'],
    [{ groups: [g.key], useAi: 'maybe' }, 400, 'invalid_useAi'],
    [{ groups: [g.key], targetMembershipId: 'x' }, 400, 'invalid_targetMembershipId'],
    [{ groups: ['g_000000000000'] }, 409, 'groups_stale'],
  ];
  for (const [body, status, code] of cases) {
    const r = await extract(body);
    assert.equal(r.status, status, `${JSON.stringify(body).slice(0, 60)} → ${r.text.slice(0, 200)}`);
    assert.equal(r.json.error.code, code);
  }
  assert.equal((await h.a.get('/asset-import/candidates?months=abc', h.auth)).json.error.code, 'invalid_months');
  assert.equal((await h.a.get('/asset-import/candidates?months=25', h.auth)).status, 400);
  const partly = (await extract({ groups: [g.key, 'g_000000000000'] })).of('done')[0].data;
  assert.equal(partly.draft.memberships.length, 1);
  assert.deepEqual(partly.draft.notices, ['有 1 组和现在的流水对不上了（刚记了新流水？），没算进来']);
  assert.equal((await h.a.get('/asset-import/candidates')).status, 401);
});

test('直接生成不占导入限流：每小时只许 1 次时连着生成 3 次都行', async (t) => {
  const { spend, candidates, extract } = await setupSubscriptions(t, { provider: false, env: { AI_IMPORT_PER_HOUR: '1' } });
  for (let i = 0; i < 3; i++) await spend(-5 - 30 * i, 3000, '腾讯视频');
  const [g] = (await candidates()).items;
  for (let i = 0; i < 3; i++) assert.equal((await extract({ groups: [g.key] })).of('done').length, 1, `第 ${i + 1} 次直接生成`);
});
