'use strict';

// POST /asset-import/apply（spec §4、§6、§8「apply」「实物」）：单个事务落库、只增改不删；服务端重新校验、重新比对
// （预览之后别人刚建了同名平台 → create 自动转成 merge）；坏引用整体回滚、一次报全；物品关联已有流水不另记账、
// 同时记一笔按导入 + key 幂等；本人发起的才能导、导过的不能再导；undo 里给 P5 的撤销记好了东西。
// 两条验收的服务端一半也在这里：88VIP 改领取平台 → 导入 → 本期能看到的数据；订单 → 物品关联唯一流水、带估值、不重复记账。

const test = require('node:test');
const assert = require('node:assert/strict');

const { household } = require('./fixtures');
const { openDb } = require('../src/lib/db');
const { startFakeAnthropic } = require('./fake_upstream');
const { ANT_KEY, addProvider, extractDraft, applyBodyOf } = require('./import_fixtures');

async function setup(t) {
  const up = await startFakeAnthropic({ key: ANT_KEY });
  t.after(() => up.stop());
  const h = await household(t);
  await addProvider(h, up);
  return { up, h };
}

const items = async (h, p) => (await h.a.get(p, h.auth)).json.items;

test('验收（服务端）：88VIP 权益说明 → 领取平台「优酷视频」并入已有的「优酷」→ 导入；N 选 1、限制条件、来源标记都落库', async (t) => {
  const { up, h } = await setup(t);
  const tb = (await h.a.post('/platforms', { name: '淘宝' }, h.auth)).json.platform;
  const yk = (await h.a.post('/platforms', { name: '优酷' }, h.auth)).json.platform;
  const done = await extractDraft(h, up, 'vip88.output.txt', 'vip88.source.txt', { want: 'virtual' });
  const ykNode = done.draft.platforms.find((p) => p.fields.name === '优酷视频');
  const body = applyBodyOf(done, {
    edit: (n, item) => {
      if (n === ykNode) Object.assign(item, { action: 'merge', targetId: yk.id }); // 映射视图里选「并入… 优酷」
    },
  });
  const r = await h.a.post('/asset-import/apply', body, h.auth);
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.json.created, { platforms: 4, memberships: 1, benefits: 7, items: 0, transactions: 0 });
  assert.deepEqual(r.json.updated, { platforms: 1, memberships: 0, benefits: 0 }, '优酷多了一个别名');
  assert.deepEqual(r.json.autoMerged, []);
  assert.equal(r.json.ids[ykNode.key], yk.id);

  const platforms = await items(h, '/platforms');
  assert.deepEqual(platforms.find((p) => p.id === yk.id).aliases, ['优酷视频'], '并入时把名字写进目标的别名');
  assert.equal(platforms.filter((p) => p.name === '淘宝').length, 1, '淘宝并入已有的，不新建');
  const vip = (await items(h, '/memberships')).find((m) => m.name === '88VIP');
  assert.deepEqual(
    [vip.platformId, vip.feeCents, vip.feePeriod, vip.expiresOn, vip.autoRenew],
    [tb.id, 8800, 'year', '2026-12-31', 'yes'],
  );
  assert.deepEqual(vip.origin, { src: 'ai_text', importId: done.importId, ev: '年费 88 元（淘气值 1000 分以上），到期日 2026-12-31', unverified: [] });
  const benefits = await items(h, '/benefits');
  const byName = Object.fromEntries(benefits.map((b) => [b.name, b]));
  assert.deepEqual([byName['优酷视频年卡'].claimPlatformId, byName['优酷视频年卡'].membershipId], [yk.id, vip.id]);
  assert.deepEqual(byName['88 折购物券'].limits.map((l) => l.type), ['min_spend', 'stacking']);
  assert.equal(byName['88 折购物券'].flow, 'claim_use');
  assert.equal(byName['三选一'].kind, 'choice');
  for (const o of ['网易云音乐黑胶年卡', 'QQ 音乐豪华绿钻年卡', '芒果 TV 年卡']) {
    assert.equal(byName[o].parentId, byName['三选一'].id);
    assert.deepEqual(byName[o].quota, []);
  }
  // 别的设备靠 /changes 拿到（App 的「本期」就吃这些行）
  const changes = (await h.a.get('/changes?since=0', h.auth)).json;
  assert.equal(changes.benefits.length, 7);

  // 同一个 clientId 重发：原样回第一次的结果；换个 clientId 再导：409（这批已经用过了）
  const again = await h.a.post('/asset-import/apply', body, h.auth);
  assert.equal(again.json.replayed, true);
  assert.deepEqual(again.json.ids, r.json.ids);
  assert.equal((await items(h, '/benefits')).length, 7, '重发不会再建一遍');
  const other = await h.a.post('/asset-import/apply', { ...body, clientId: 'apply-2' }, h.auth);
  assert.equal(other.status, 409);
  assert.equal(other.json.error.code, 'import_used');
});

test('验收（服务端）：订单文字 → 物品关联唯一匹配的流水 → 带估值，流水条数不变', async (t) => {
  const { up, h } = await setup(t);
  const tx = (await h.tx({ type: 'expense', amountCents: 899900, occurredAt: '2026-09-21T09:00:00+08:00', fundId: h.fund.id, merchant: 'Apple Store' })).json.transaction;
  const before = (await h.a.get('/transactions?limit=200', h.auth)).json.items.length;
  const done = await extractDraft(h, up, 'order.output.txt', 'order.source.txt', { want: 'items' });
  // App 把预设 apple 换成估值字段（ValuationInput.toCreateJson）
  const body = applyBodyOf(done, {
    edit: (n, item) => Object.assign(item.fields, { valuationMethod: 'declining', rateBp: 2000, residualBp: 1000 }),
  });
  assert.equal(body.items[0].linkTransactionId, tx.id);
  const r = await h.a.post('/asset-import/apply', body, h.auth);
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.json.created, { platforms: 0, memberships: 0, benefits: 0, items: 1, transactions: 0 });
  const asset = (await items(h, '/assets'))[0];
  assert.deepEqual(
    [asset.name, asset.priceCents, asset.purchasedOn, asset.transactionId, asset.valuationMethod, asset.rateBp, asset.residualBp],
    ['iPhone 16 Pro 256GB', 899900, '2026-09-20', tx.id, 'declining', 2000, 1000],
  );
  assert.equal(asset.origin.src, 'ai_text');
  assert.equal((await h.a.get('/transactions?limit=200', h.auth)).json.items.length, before, '关联已有流水，不另记账');
  const physical = (await h.a.get('/stats/overview', h.auth)).json.physical;
  assert.equal(physical.count, 1);
  assert.ok(physical.valueCents > 0 && physical.valueCents <= 899900, '导入后物品带估值');
});

test('物品：同一笔流水不关联两次；关联和记账只能二选一；收入不能关联；同时记一笔按导入 + key 幂等（重放不再记）', async (t) => {
  const { up, h } = await setup(t);
  const spent = (await h.tx({ type: 'expense', amountCents: 89900, occurredAt: '2026-09-20T10:00:00+08:00', fundId: h.fund.id })).json.transaction;
  const income = (await h.tx({ type: 'income', amountCents: 5000, occurredAt: '2026-09-19T10:00:00+08:00', fundId: h.fund.id })).json.transaction;
  const output = JSON.stringify({ records: [{ t: 'item', name: '降噪耳机', category: 'digital', price: 899, purchasedOn: '2026-09-20', ev: '降噪耳机' }], done: true });
  const first = await extractDraft(h, up, output, '降噪耳机 899 元 2026-09-20');
  assert.equal((await h.a.post('/asset-import/apply', applyBodyOf(first), h.auth)).status, 200);
  assert.equal((await items(h, '/assets'))[0].transactionId, spent.id);

  // 再导一次同一张订单：候选里不再有那笔（已经关联了），硬塞也 400
  const second = await extractDraft(h, up, output, '降噪耳机 899 元 2026-09-20');
  assert.deepEqual([second.draft.items[0].txCandidates, second.draft.items[0].action], [[], 'skip'], '同名同价已存在，默认跳过');
  const base = applyBodyOf(second, { clientId: 'apply-2', edit: (n, item) => Object.assign(item, { action: 'create' }) });
  const dup = await h.a.post('/asset-import/apply', { ...base, items: [{ ...base.items[0], linkTransactionId: spent.id }] }, h.auth);
  assert.deepEqual(dup.json.error.details.errors, [{ key: 'i1', field: 'linkTransactionId', message: '这笔流水已经关联了别的物品' }]);
  const both = await h.a.post('/asset-import/apply', { ...base, items: [{ ...base.items[0], linkTransactionId: income.id, recordTransaction: {} }] }, h.auth);
  assert.equal(both.json.error.details.errors[0].message, '关联已有流水和同时记一笔只能选一个');
  const wrong = await h.a.post('/asset-import/apply', { ...base, items: [{ ...base.items[0], linkTransactionId: income.id }] }, h.auth);
  assert.equal(wrong.json.error.details.errors[0].message, '只能关联一笔已确认的支出');
  const notObject = await h.a.post('/asset-import/apply', { ...base, items: [{ ...base.items[0], recordTransaction: true }] }, h.auth);
  assert.deepEqual(notObject.json.error.details.errors, [{ key: 'i1', field: 'recordTransaction', message: 'recordTransaction 必须是对象' }], '和物品接口一样：不是对象就 400，不悄悄不记');

  const txCount = async () => (await h.a.get('/transactions?limit=200', h.auth)).json.items.length;
  const n0 = await txCount();
  const body = { ...base, items: [{ ...base.items[0], recordTransaction: { fundId: h.fund.id } }] };
  const r = await h.a.post('/asset-import/apply', body, h.auth);
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.created.transactions, 1);
  assert.equal(await txCount(), n0 + 1);
  const made = (await items(h, '/assets')).find((a) => a.transactionId && a.transactionId !== spent.id);
  const tx = (await h.a.get(`/transactions/${made.transactionId}`, h.auth)).json.transaction;
  assert.deepEqual(
    [tx.type, tx.amountCents, tx.occurredAt, tx.merchant, tx.clientId],
    ['expense', 89900, '2026-09-20T12:00:00+08:00', '降噪耳机', `${second.importId}:i1`],
  );
  assert.equal((await h.a.post('/asset-import/apply', body, h.auth)).json.replayed, true);
  assert.equal(await txCount(), n0 + 1, '重放不再记');
});

test('同名两张卡（持有人不明）：预览是 pick，选了哪张就更新哪张；没归属的权益勾着导入 → 400 缺卡', async (t) => {
  const { up, h } = await setup(t);
  const jd = (await h.a.post('/platforms', { name: '京东' }, h.auth)).json.platform;
  const a = (await h.a.post('/memberships', { platformId: jd.id, name: 'PLUS', expiresOn: '2026-10-01' }, h.auth)).json.membership;
  const b = (await h.a.post('/memberships', { platformId: jd.id, name: 'PLUS', expiresOn: '2026-11-01' }, h.auth)).json.membership;
  const done = await extractDraft(h, up, JSON.stringify({ records: [
    { t: 'platform', name: '京东', ev: '京东 PLUS' },
    { t: 'membership', name: 'PLUS', platform: '京东', expiresOn: '2027-11-01', ev: '京东 PLUS' },
    { t: 'benefit', name: '免运费券', membership: 'PLUS', quota: [{ p: 'month', n: 5 }], ev: '每月 5 张免运费券' },
  ], done: true }), '京东 PLUS 到期 2027-11-01，每月 5 张免运费券');
  assert.equal(done.draft.memberships[0].action, 'pick');
  const r = await h.a.post('/asset-import/apply', applyBodyOf(done, {
    picks: { m1: { action: 'update', targetId: b.id } },
    edit: (n, item) => {
      if (n.t === 'membership') item.take = ['expiresOn'];
    },
  }), h.auth);
  assert.equal(r.status, 200, r.text);
  const cards = await items(h, '/memberships');
  assert.deepEqual([cards.find((c) => c.id === a.id).expiresOn, cards.find((c) => c.id === b.id).expiresOn], ['2026-10-01', '2027-11-01']);
  assert.equal((await items(h, '/benefits'))[0].membershipId, b.id, '权益挂到选中的那张');

  const orphan = await extractDraft(h, up, JSON.stringify({ records: [{ t: 'benefit', name: '免费停车', ev: '免费停车' }], done: true }), '免费停车');
  assert.equal(orphan.draft.benefits[0].checked, false, '未归属默认不勾');
  const forced = await h.a.post('/asset-import/apply', applyBodyOf(orphan, {
    clientId: 'apply-orphan',
    edit: (n, item) => Object.assign(item, { action: 'create' }),
  }), h.auth);
  assert.deepEqual(forced.json.error.details.errors, [{ key: 'b1', field: 'membership', message: '还没选会员卡' }]);
});

test('坏引用整体回滚：一次报全（key + 字段 + 原因），什么都没写；卡本身出错时挂在它下面的也报出来；改好再发照常执行', async (t) => {
  const { up, h } = await setup(t);
  const done = await extractDraft(h, up, 'vip88.output.txt', 'vip88.source.txt');
  const keyOf = (name) => [...done.draft.memberships, ...done.draft.benefits].find((n) => n.fields.name === name).key;
  const r = await h.a.post('/asset-import/apply', applyBodyOf(done, {
    edit: (n, item) => {
      if (n.fields.name === '饿了么超级会员年卡') item.fields.membership = 'key:m9';
      if (n.fields.name === '88 折购物券') item.fields.quota = [{ p: 'month', n: 0 }];
      if (n.fields.name === '优酷视频年卡') item.fields.claimPlatform = 'id:nope';
    },
  }), h.auth);
  assert.equal(r.status, 400);
  assert.equal(r.json.error.code, 'import_invalid');
  assert.match(r.json.error.message, /有 3 处要改/);
  assert.deepEqual(r.json.error.details.errors, [
    { key: keyOf('优酷视频年卡'), field: 'claimPlatform', message: '领取平台已经不在了' },
    { key: keyOf('饿了么超级会员年卡'), field: 'membership', message: '会员卡没有导入（没勾选或它自己出错了）' },
    { key: keyOf('88 折购物券'), field: 'quota', message: 'quota 必须在 1~9999 之间' },
  ]);
  assert.deepEqual(await items(h, '/platforms'), [], '一个平台都没留下');
  assert.deepEqual(await items(h, '/memberships'), []);

  const card = await h.a.post('/asset-import/apply', applyBodyOf(done, {
    edit: (n, item) => {
      if (n.t === 'membership') item.fields.expiresOn = '2026-02-30';
    },
  }), h.auth);
  const errs = card.json.error.details.errors;
  assert.deepEqual(errs[0], { key: 'm1', field: 'expiresOn', message: 'expiresOn 不是有效日期' });
  assert.ok(errs.some((e) => e.key === keyOf('优酷视频年卡') && e.field === 'membership'));

  // 改好再发（同一个 clientId）照常执行：失败的请求什么都不记
  assert.equal((await h.a.post('/asset-import/apply', applyBodyOf(done), h.auth)).status, 200);
});

test('并发：预览之后别人刚建了同名平台 → create 自动转成 merge 并报 autoMerged，不出第二个同名平台', async (t) => {
  const { up, h } = await setup(t);
  const done = await extractDraft(
    h, up,
    JSON.stringify({ records: [
      { t: 'platform', name: '京东', ev: '京东 PLUS' },
      { t: 'membership', name: 'PLUS', platform: '京东', fee: 99, feePeriod: 'year', ev: '京东 PLUS' },
    ], done: true }),
    '京东 PLUS 年费 99 元',
  );
  assert.equal(done.draft.platforms[0].action, 'create');
  const jd = (await h.a.post('/platforms', { name: 'JD' }, h.auth)).json.platform; // 种子表：京东 = JD
  const r = await h.a.post('/asset-import/apply', applyBodyOf(done), h.auth);
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.json.autoMerged, [{ key: 'p1', id: jd.id, name: 'JD', table: 'platforms' }]);
  assert.deepEqual(r.json.created.platforms, 0);
  const ps = await items(h, '/platforms');
  assert.equal(ps.length, 1);
  assert.deepEqual(ps[0].aliases, ['京东']);
  assert.equal((await items(h, '/memberships'))[0].platformId, jd.id);
});

test('更新：只写勾了的差异字段；limits 取库里现在的 ∪ 这次的；origin 换成这次导入的', async (t) => {
  const { up, h } = await setup(t);
  const tb = (await h.a.post('/platforms', { name: '淘宝' }, h.auth)).json.platform;
  const vip = (await h.a.post('/memberships', { platformId: tb.id, name: '88VIP', feeCents: 8800, expiresOn: '2026-06-30' }, h.auth)).json.membership;
  const perk = (await h.a.post('/benefits', {
    membershipId: vip.id, name: '88 折购物券', limits: [{ type: 'other', text: '限本人' }], origin: { src: 'manual' },
  }, h.auth)).json.benefit;
  const done = await extractDraft(h, up, 'vip88.output.txt', 'vip88.source.txt');
  const m = done.draft.memberships[0];
  assert.deepEqual([m.action, m.targetId], ['update', vip.id]);
  assert.deepEqual(m.diff.map((d) => [d.field, d.take]), [['expiresOn', true], ['autoRenew', true]], '费用一样不列');
  const r = await h.a.post('/asset-import/apply', applyBodyOf(done, {
    edit: (n, item) => {
      if (n.t === 'membership') item.take = ['expiresOn']; // 用户取消了 autoRenew 的勾
    },
  }), h.auth);
  assert.equal(r.status, 200, r.text);
  const after = (await items(h, '/memberships')).find((x) => x.id === vip.id);
  assert.deepEqual([after.expiresOn, after.autoRenew, after.feeCents], ['2026-12-31', 'unknown', 8800]);
  assert.equal(after.origin.importId, done.importId);
  const b = (await items(h, '/benefits')).find((x) => x.id === perk.id);
  assert.deepEqual(b.limits, [{ type: 'other', text: '限本人' }, { type: 'min_spend', text: '单笔满 200 元可用' }, { type: 'stacking', text: '不与其他优惠同享' }]);
  assert.equal(b.origin.src, 'ai_text');
  assert.equal(r.json.updated.memberships, 1);
});

test('归属与上限：别人的导入 403、不存在 404、缺 clientId 400、超上限 400 too_many；undo 记好了 P5 要的东西', async (t) => {
  const { up, h } = await setup(t);
  const tb = (await h.a.post('/platforms', { name: '淘宝' }, h.auth)).json.platform;
  const tx = (await h.tx({ type: 'expense', amountCents: 899900, occurredAt: '2026-09-21T09:00:00+08:00', fundId: h.fund.id })).json.transaction;
  const done = await extractDraft(h, up, 'vip88.output.txt', 'vip88.source.txt');
  const body = applyBodyOf(done);

  await h.a.post('/members', { username: 'xiaohong', password: 'hunter22', displayName: '小红', role: 'member' }, h.auth);
  const her = { token: (await h.a.post('/auth/login', { username: 'xiaohong', password: 'hunter22' })).json.token };
  assert.equal((await h.a.post('/asset-import/apply', { ...body, clientId: 'x1' }, her)).status, 403);
  assert.equal((await h.a.post('/asset-import/apply', { ...body, importId: 'nope' }, h.auth)).status, 404);
  const noClient = await h.a.post('/asset-import/apply', { ...body, clientId: undefined }, h.auth);
  assert.equal(noClient.json.error.code, 'invalid_clientId');
  const many = await h.a.post('/asset-import/apply', {
    ...body, platforms: Array.from({ length: 51 }, (_, i) => ({ key: `p${i}`, action: 'create', fields: { name: `平台${i}` } })),
  }, h.auth);
  assert.equal(many.json.error.code, 'too_many');
  // 没勾的（skip）不算进上限：50 个新建 + 1 个 skip 过了上限这一关（这里故意让一张卡出错，整体回滚、什么都不写）
  const skipped = await h.a.post('/asset-import/apply', {
    ...body,
    platforms: Array.from({ length: 51 }, (_, i) => ({ key: `p${i}`, action: i === 50 ? 'skip' : 'create', fields: { name: `平台${i}` } })),
    memberships: [{ key: 'mx', action: 'create', fields: { name: '坏卡' } }],
    benefits: [],
  }, h.auth);
  assert.equal(skipped.json.error.code, 'import_invalid', skipped.text);

  const order = await extractDraft(h, up, 'order.output.txt', 'order.source.txt', { want: 'items' });
  const ok1 = await h.a.post('/asset-import/apply', body, h.auth);
  assert.equal(ok1.status, 200, ok1.text);
  const stolen = await h.a.post('/asset-import/apply', body, her);
  assert.equal(stolen.status, 403, '重放也先核对是不是本人：别人拿同一个 clientId 拿不到结果');
  const ok2 = await h.a.post('/asset-import/apply', applyBodyOf(order, { clientId: 'apply-order' }), h.auth);
  assert.equal(ok2.status, 200, ok2.text);

  await h.srv.stop();
  const db = openDb(h.srv.dataDir);
  try {
    const row = db.get('SELECT status, applied_at, undo, summary FROM ai_imports WHERE id = ?', done.importId);
    assert.equal(row.status, 'applied');
    assert.ok(row.applied_at);
    const undo = JSON.parse(row.undo);
    assert.equal(undo.created.filter((c) => c.table === 'benefits').length, 7);
    assert.equal(undo.created.filter((c) => c.table === 'platforms').length, 5, '优酷视频这回没并入，新建');
    assert.deepEqual(undo.updated, [], '淘宝并入时名字一样，不改它');
    assert.deepEqual(undo.aliases, []);
    assert.deepEqual(JSON.parse(row.summary).applied.created.benefits, 7);
    const orderUndo = JSON.parse(db.get('SELECT undo FROM ai_imports WHERE id = ?', order.importId).undo);
    assert.deepEqual(orderUndo.created.map((c) => c.table), ['assets']);
    assert.deepEqual(orderUndo.transactions, [], '关联的旧流水不算导入建的');
    assert.equal(db.get('SELECT transaction_id FROM assets').transaction_id, tx.id);
    assert.ok(tb.id);
  } finally {
    db.close();
  }
});

test('同一段材料导两次（Review Focus ①）：第二次全是并入 / 更新且没有差异、物品已存在默认跳过；导完不多出卡、权益、物品和流水', async (t) => {
  const { up, h } = await setup(t);
  const vip1 = await extractDraft(h, up, 'vip88.output.txt', 'vip88.source.txt');
  assert.equal((await h.a.post('/asset-import/apply', applyBodyOf(vip1), h.auth)).status, 200);
  const vip2 = await extractDraft(h, up, 'vip88.output.txt', 'vip88.source.txt');
  assert.ok(vip2.draft.platforms.every((p) => p.action === 'merge'));
  assert.deepEqual([vip2.draft.memberships[0].action, vip2.draft.memberships[0].diff], ['update', []]);
  assert.ok(vip2.draft.benefits.every((b) => b.action === 'update' && b.diff.length === 0));
  const r = await h.a.post('/asset-import/apply', applyBodyOf(vip2, { clientId: 'apply-2' }), h.auth);
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.json.created, { platforms: 0, memberships: 0, benefits: 0, items: 0, transactions: 0 });
  assert.deepEqual(r.json.updated, { platforms: 0, memberships: 0, benefits: 0 }, '什么都没变就不算「更新了」（结果页不该写「更新：会员卡 1 张」）');
  assert.equal((await items(h, '/memberships')).length, 1);
  assert.equal((await items(h, '/benefits')).length, 7);
  assert.equal((await items(h, '/platforms')).length, 6);

  const order1 = await extractDraft(h, up, 'order.output.txt', 'order.source.txt', { want: 'items' });
  const withRecord = (n, item) => Object.assign(item, { recordTransaction: { fundId: h.fund.id } });
  assert.equal((await h.a.post('/asset-import/apply', applyBodyOf(order1, { clientId: 'o-1', edit: withRecord }), h.auth)).status, 200);
  const txs = (await h.a.get('/transactions?limit=200', h.auth)).json.items.length;
  const order2 = await extractDraft(h, up, 'order.output.txt', 'order.source.txt', { want: 'items' });
  assert.deepEqual([order2.draft.items[0].action, order2.draft.items[0].checked, order2.draft.items[0].match.kind], ['skip', false, 'exists']);
  assert.equal((await h.a.post('/asset-import/apply', applyBodyOf(order2, { clientId: 'o-2', edit: withRecord }), h.auth)).status, 200);
  assert.equal((await items(h, '/assets')).length, 1);
  assert.equal((await h.a.get('/transactions?limit=200', h.auth)).json.items.length, txs, '跳过的物品不记账');
});

test('物品价格超过 10 万元（Review Focus ⑤）：抽取时当没写（缺价格），预览里填上后 apply 照收', async (t) => {
  const { up, h } = await setup(t);
  const done = await extractDraft(
    h, up,
    JSON.stringify({ records: [{ t: 'item', name: '小鹏 MONA M03', category: 'vehicle', preset: 'ev', price: 119800, purchasedOn: '2026-09-01', ev: '小鹏 MONA M03' }], done: true }),
    '小鹏 MONA M03 落地价 119800 元 2026-09-01 提车',
  );
  const car = done.draft.items[0];
  assert.deepEqual([car.fields.priceCents, car.missing, car.fields.preset], [null, ['priceCents'], 'ev']);
  const r = await h.a.post('/asset-import/apply', applyBodyOf(done, {
    edit: (n, item) => Object.assign(item.fields, { priceCents: 11980000, valuationMethod: 'declining', rateBp: 2300, residualBp: 1000 }),
  }), h.auth);
  assert.equal(r.status, 200, r.text);
  assert.equal((await items(h, '/assets'))[0].priceCents, 11980000);
});

test('同名两张卡选定一张（Review ⑧）：App 换上那张的差异和权益比对 → 卡按差异更新、已有的权益更新不重复；老样子发 create 也不会重复建', async (t) => {
  const { up, h } = await setup(t);
  const jd = (await h.a.post('/platforms', { name: '京东' }, h.auth)).json.platform;
  const a = (await h.a.post('/memberships', { platformId: jd.id, name: 'PLUS', expiresOn: '2026-10-01' }, h.auth)).json.membership;
  const b = (await h.a.post('/memberships', { platformId: jd.id, name: 'PLUS', expiresOn: '2026-11-01' }, h.auth)).json.membership;
  const ship = (await h.a.post('/benefits', { membershipId: b.id, name: '免运费券' }, h.auth)).json.benefit;
  const output = JSON.stringify({ records: [
    { t: 'platform', name: '京东', ev: '京东 PLUS' },
    { t: 'membership', name: 'PLUS', platform: '京东', expiresOn: '2027-11-01', ev: '京东 PLUS' },
    { t: 'benefit', name: '免运费券', membership: 'PLUS', quota: [{ p: 'month', n: 5 }], ev: '每月 5 张免运费券' },
    { t: 'benefit', name: '运费险', membership: 'PLUS', ev: '运费险' },
  ], done: true });
  const source = '京东 PLUS 到期 2027-11-01，每月 5 张免运费券，运费险';
  const done = await extractDraft(h, up, output, source);
  const card = done.draft.memberships[0];
  const pickB = card.match.candidates.find((c) => c.id === b.id);
  // 照 App 的 pickMembership：卡换成 update + 那张的差异，权益换成 byCard 里那张的比对结果
  const r = await h.a.post('/asset-import/apply', applyBodyOf(done, {
    edit: (n, item) => {
      if (n.t === 'membership') Object.assign(item, { action: 'update', targetId: b.id, take: pickB.diff.filter((d) => d.take).map((d) => d.field) });
      const hit = n.byCard && n.byCard[b.id];
      if (hit) Object.assign(item, { action: 'update', targetId: hit.targetId, take: hit.diff.filter((d) => d.take).map((d) => d.field) });
    },
  }), h.auth);
  assert.equal(r.status, 200, r.text);
  const cards = await items(h, '/memberships');
  assert.deepEqual([cards.find((c) => c.id === a.id).expiresOn, cards.find((c) => c.id === b.id).expiresOn], ['2026-10-01', '2027-11-01'], '选中那张的差异写进去');
  const benefits = await items(h, '/benefits');
  assert.deepEqual(benefits.filter((x) => x.membershipId === b.id).map((x) => x.name).sort(), ['免运费券', '运费险'], '已有的免运费券没有第二份');
  assert.deepEqual(benefits.find((x) => x.id === ship.id).quota, [{ p: 'month', n: 5 }], '原来空的额度补上');
  assert.deepEqual(r.json.autoMerged, []);

  // 老样子（权益仍发 create）：服务端重新比对，同卡同名转成更新，报 autoMerged，不建第二份
  const again = await extractDraft(h, up, output, source);
  const r2 = await h.a.post('/asset-import/apply', applyBodyOf(again, {
    clientId: 'apply-2',
    picks: { m1: { action: 'update', targetId: b.id } },
    edit: (n, item) => {
      if (n.t === 'membership') item.take = [];
      if (n.t === 'benefit') Object.assign(item, { action: 'create', targetId: undefined, take: undefined, edited: n.fields.name === '运费险' ? ['faceValueCents'] : undefined });
      if (n.fields.name === '运费险') item.fields.faceValueCents = 300;
    },
  }), h.auth);
  assert.equal(r2.status, 200, r2.text);
  assert.deepEqual(r2.json.autoMerged.map((m) => [m.table, m.name]), [['benefits', '免运费券'], ['benefits', '运费险']]);
  assert.equal(r2.json.created.benefits, 0);
  const after = (await items(h, '/benefits')).filter((x) => x.membershipId === b.id);
  assert.equal(after.length, 2);
  assert.equal(after.find((x) => x.name === '运费险').faceValueCents, 300, '预览里改过的字段（edited）转成更新时照样写');
});

test('归档的卡（Review ⑩）：命中归档的那张时默认恢复 —— 导入后回到本期；选「新建一张」就另建一张', async (t) => {
  const { up, h } = await setup(t);
  const tb = (await h.a.post('/platforms', { name: '淘宝' }, h.auth)).json.platform;
  const old = (await h.a.post('/memberships', { platformId: tb.id, name: '88VIP', expiresOn: '2025-12-31' }, h.auth)).json.membership;
  const yk = (await h.a.post('/benefits', { membershipId: old.id, name: '优酷视频年卡' }, h.auth)).json.benefit;
  await h.a.patch(`/benefits/${yk.id}`, { archived: true }, h.auth);
  await h.a.patch(`/memberships/${old.id}`, { archived: true }, h.auth);
  const output = JSON.stringify({ records: [
    { t: 'membership', name: '88VIP', platform: '淘宝', expiresOn: '2026-12-31', ev: '88VIP 到期日 2026-12-31' },
    { t: 'benefit', name: '优酷视频年卡', membership: '88VIP', ev: '优酷视频年卡' },
  ], done: true });
  const done = await extractDraft(h, up, output, '88VIP 到期日 2026-12-31；优酷视频年卡');
  const card = done.draft.memberships[0];
  assert.deepEqual([card.action, card.targetId, card.match.archived], ['update', old.id, true]);
  const r = await h.a.post('/asset-import/apply', applyBodyOf(done), h.auth);
  assert.equal(r.status, 200, r.text);
  const back = (await items(h, '/memberships')).find((m) => m.id === old.id);
  assert.deepEqual([back.archived, back.expiresOn], [false, '2026-12-31'], '恢复了，到期日也更新了');
  assert.equal((await items(h, '/benefits')).find((b) => b.id === yk.id).archived, false, '归档的同名权益也恢复');

  await h.a.patch(`/memberships/${old.id}`, { archived: true }, h.auth);
  const second = await extractDraft(h, up, output, '88VIP 到期日 2026-12-31；优酷视频年卡');
  const r2 = await h.a.post('/asset-import/apply', applyBodyOf(second, {
    clientId: 'apply-new',
    edit: (n, item) => {
      if (n.t !== 'platform') Object.assign(item, { action: 'create', targetId: undefined, take: undefined }); // 「都不是，新建一张」
    },
  }), h.auth);
  assert.equal(r2.status, 200, r2.text);
  assert.deepEqual(r2.json.autoMerged, [], '只有归档的同名卡时不会被重新比对并进去');
  const all = await items(h, '/memberships?archived=1');
  assert.deepEqual(all.filter((m) => m.name === '88VIP').map((m) => m.archived).sort(), [false, true], '归档的那张不动，另建了一张');
});

test('平台：预览里就是别名、用户选了「新建」的照建（Review ⑪）；名字撞上已有平台只能并入', async (t) => {
  const { up, h } = await setup(t);
  const tb = (await h.a.post('/platforms', { name: '淘宝' }, h.auth)).json.platform;
  const done = await extractDraft(h, up, JSON.stringify({ records: [
    { t: 'platform', name: '天猫', ev: '天猫' },
    { t: 'platform', name: '淘宝', ev: '淘宝' },
  ], done: true }), '天猫 淘宝');
  const [tm, taobao] = done.draft.platforms;
  assert.deepEqual([tm.match.kind, tm.action, taobao.match.kind], ['alias', 'merge', 'exact']);
  const r = await h.a.post('/asset-import/apply', applyBodyOf(done, {
    edit: (n, item) => Object.assign(item, { action: 'create', targetId: undefined, match: n.match.kind }),
  }), h.auth);
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.json.autoMerged.map((m) => [m.key, m.name]), [[taobao.key, '淘宝']], '同名的只能并入');
  const ps = await items(h, '/platforms');
  assert.deepEqual(ps.map((p) => p.name).sort(), ['天猫', '淘宝'], '天猫照用户的选择新建');
  assert.deepEqual(ps.find((p) => p.id === tb.id).aliases, [], '没把天猫悄悄记成淘宝的别名');
});

test('预览里把挂着卡的平台并入已有的（Review ⑧ 同类）：那个平台下恰好一张同名卡 → 转成更新它，权益也不重复', async (t) => {
  const { up, h } = await setup(t);
  const tb = (await h.a.post('/platforms', { name: '淘宝' }, h.auth)).json.platform;
  const vip = (await h.a.post('/memberships', { platformId: tb.id, name: '88VIP', expiresOn: '2026-06-30' }, h.auth)).json.membership;
  await h.a.post('/benefits', { membershipId: vip.id, name: '88 折购物券' }, h.auth);
  const done = await extractDraft(h, up, JSON.stringify({ records: [
    { t: 'platform', name: '淘宝网', ev: '淘宝网 88VIP' },
    { t: 'membership', name: '88VIP', platform: '淘宝网', expiresOn: '2026-12-31', ev: '淘宝网 88VIP 到期日 2026-12-31' },
    { t: 'benefit', name: '88 折购物券', membership: '88VIP', quota: [{ p: 'month', n: 4 }], ev: '88 折购物券' },
  ], done: true }), '淘宝网 88VIP 到期日 2026-12-31；每月 4 张 88 折购物券');
  assert.deepEqual([done.draft.platforms[0].match.kind, done.draft.memberships[0].action], ['maybe', 'create']);
  const r = await h.a.post('/asset-import/apply', applyBodyOf(done, {
    edit: (n, item) => {
      if (n.t === 'platform') Object.assign(item, { action: 'merge', targetId: tb.id, match: 'maybe' }); // 平台表单里「并入淘宝」
    },
  }), h.auth);
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.json.autoMerged.map((m) => [m.table, m.id]), [['memberships', vip.id], ['benefits', r.json.ids.b1]]);
  assert.equal((await items(h, '/memberships')).length, 1);
  assert.equal((await items(h, '/memberships'))[0].expiresOn, '2026-12-31', '更晚的到期日按默认勾选写进去');
  const perks = await items(h, '/benefits');
  assert.equal(perks.length, 1);
  assert.deepEqual(perks[0].quota, [{ p: 'month', n: 4 }]);
});

test('重新比对只在同一个「N 选 1」下比：新建的「N 选 1」里的选项不会被并进卡里同名的顶层权益', async (t) => {
  const { up, h } = await setup(t);
  const tb = (await h.a.post('/platforms', { name: '淘宝' }, h.auth)).json.platform;
  const vip = (await h.a.post('/memberships', { platformId: tb.id, name: '88VIP' }, h.auth)).json.membership;
  const top = (await h.a.post('/benefits', { membershipId: vip.id, name: '芒果 TV 年卡', quota: [{ p: 'term', n: 1 }] }, h.auth)).json.benefit;
  const done = await extractDraft(h, up, JSON.stringify({ records: [
    { t: 'membership', name: '88VIP', platform: '淘宝', ev: '88VIP' },
    { t: 'benefit', name: '芒果 TV 年卡', membership: '88VIP', choice: { group: '音乐三选一', pick: 1 }, ev: '芒果 TV 年卡' },
    { t: 'benefit', name: 'QQ 音乐年卡', membership: '88VIP', choice: { group: '音乐三选一', pick: 1 }, ev: 'QQ 音乐年卡' },
  ], done: true }), '88VIP 音乐三选一：芒果 TV 年卡、QQ 音乐年卡');
  assert.equal(done.draft.benefits.find((b) => b.fields.name === '芒果 TV 年卡').action, 'create');
  const r = await h.a.post('/asset-import/apply', applyBodyOf(done), h.auth);
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.json.autoMerged, []);
  const benefits = await items(h, '/benefits');
  const group = benefits.find((b) => b.name === '音乐三选一');
  assert.deepEqual(benefits.filter((b) => b.parentId === group.id).map((b) => b.name).sort(), ['QQ 音乐年卡', '芒果 TV 年卡']);
  assert.equal(benefits.find((b) => b.id === top.id).parentId, null, '顶层那项原样');
});

test('「N 选 1」的父权益导入时改了 flow：选项跟着改（Review ⑱）；关联的流水金额和价格对不上 400', async (t) => {
  const { up, h } = await setup(t);
  const vip1 = await extractDraft(h, up, 'vip88.output.txt', 'vip88.source.txt');
  assert.equal((await h.a.post('/asset-import/apply', applyBodyOf(vip1), h.auth)).status, 200);
  const vip2 = await extractDraft(h, up, 'vip88.output.txt', 'vip88.source.txt');
  const r = await h.a.post('/asset-import/apply', applyBodyOf(vip2, {
    clientId: 'apply-2',
    edit: (n, item) => {
      if (n.fields.name === '三选一') Object.assign(item, { take: ['flow'], fields: { ...item.fields, flow: 'use' } });
    },
  }), h.auth);
  assert.equal(r.status, 200, r.text);
  const benefits = await items(h, '/benefits');
  const parent = benefits.find((b) => b.name === '三选一');
  assert.deepEqual([parent.flow, ...benefits.filter((b) => b.parentId === parent.id).map((b) => b.flow)], ['use', 'use', 'use', 'use']);

  const tx = (await h.tx({ type: 'expense', amountCents: 88800, occurredAt: '2026-09-20T10:00:00+08:00', fundId: h.fund.id })).json.transaction;
  const order = await extractDraft(h, up, JSON.stringify({ records: [{ t: 'item', name: '耳机', price: 899, purchasedOn: '2026-09-20', ev: '耳机' }], done: true }), '耳机 899 元 2026-09-20');
  const bad = await h.a.post('/asset-import/apply', applyBodyOf(order, { clientId: 'o-1', edit: (n, item) => Object.assign(item, { linkTransactionId: tx.id }) }), h.auth);
  assert.deepEqual(bad.json.error.details.errors, [{ key: 'i1', field: 'linkTransactionId', message: '要关联的那笔流水金额和价格对不上' }]);
});
