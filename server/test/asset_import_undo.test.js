'use strict';

// 撤销（spec §4 `POST /asset-import/:id/undo`、§7 P5 验收「撤销后恢复原状」、§8「undo 会跳过期间被改过的行」「undo 删掉随物品新建的流水、
// 不动关联的旧流水」）：7 天内、本人或管理员；新建的行软删（墓碑经 /changes 同步）、随物品新建的流水一并软删、关联的旧流水不动；
// 更新过的行 seq 没变就恢复原字段，变了报 skippedChanged；追加的别名拿掉；还被导入之外的数据用着的行留下报 skippedInUse
// （卖出过的物品连同随它新建的流水都留着）。撤销不能把「N 选 1」撤坏：导入改成 N 选 1、下面有后加选项的那一行不恢复；
// 选项的 flow 永远跟父权益一致。GET /asset-import/recent 列出 7 天内能撤的（本人的；管理员看全家）。

const test = require('node:test');
const assert = require('node:assert/strict');

const { household } = require('./fixtures');
const { startServer, api } = require('./helpers');
const { openDb } = require('../src/lib/db');
const { startFakeAnthropic } = require('./fake_upstream');
const { ANT_KEY, addProvider, extractDraft, applyBodyOf, sse } = require('./import_fixtures');

async function setup(t) {
  const up = await startFakeAnthropic({ key: ANT_KEY });
  t.after(() => up.stop());
  const h = await household(t);
  await addProvider(h, up);
  return { up, h };
}

const items = async (h, p, auth = h.auth) => (await h.a.get(p, auth)).json.items;
const undo = (h, id, auth = h.auth) => h.a.post(`/asset-import/${id}/undo`, {}, auth);

const ORDER = JSON.stringify({ records: [
  { t: 'item', name: 'iPhone 16 Pro 256GB', category: 'digital', preset: 'apple', price: 8999, purchasedOn: '2026-09-20', ev: 'iPhone 16 Pro 256GB' },
  { t: 'item', name: 'AirPods Pro', category: 'digital', price: 1899, purchasedOn: '2026-09-20', ev: 'AirPods Pro' },
], done: true });
const ORDER_SOURCE = '订单：iPhone 16 Pro 256GB ¥8999；AirPods Pro ¥1899，2026-09-20';

test('验收（服务端）：订单导入的两件物品撤销 → 物品没了、随物品新建的那笔流水一并撤掉、关联的旧流水原样还在；/changes 带墓碑', async (t) => {
  const { up, h } = await setup(t);
  const old = (await h.tx({ type: 'expense', amountCents: 899900, occurredAt: '2026-09-21T09:00:00+08:00', fundId: h.fund.id, merchant: 'Apple Store' })).json.transaction;
  const txCount = async () => (await h.a.get('/transactions?limit=200', h.auth)).json.items.length;
  const before = await txCount();
  const done = await extractDraft(h, up, ORDER, ORDER_SOURCE, { want: 'items' });
  const applied = await h.a.post('/asset-import/apply', applyBodyOf(done, {
    edit: (n, item) => {
      if (n.fields.name === 'AirPods Pro') item.recordTransaction = { fundId: h.fund.id };
    },
  }), h.auth);
  assert.equal(applied.status, 200, applied.text);
  assert.deepEqual([applied.json.created.items, applied.json.created.transactions], [2, 1]);
  assert.equal(await txCount(), before + 1);
  const made = (await items(h, '/assets')).find((a) => a.name === 'AirPods Pro').transactionId;
  const { next: since } = (await h.a.get('/changes?since=0', h.auth)).json;

  const r = await undo(h, done.importId);
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.json.undone, { platforms: 0, memberships: 0, benefits: 0, items: 2, transactions: 1, events: 0 });
  assert.deepEqual([r.json.skippedChanged, r.json.skippedInUse], [[], []]);
  assert.deepEqual(await items(h, '/assets'), []);
  assert.equal(await txCount(), before, '随物品新建的那笔撤掉了');
  assert.equal((await h.a.get(`/transactions/${old.id}`, h.auth)).status, 200, '关联的旧流水不动');
  assert.equal((await h.a.get(`/transactions/${made}`, h.auth)).status, 404);
  const changes = (await h.a.get(`/changes?since=${since}`, h.auth)).json;
  assert.equal(changes.assets.filter((a) => a.deletedAt).length, 2, '别的设备靠墓碑删掉');
  assert.ok(changes.transactions.some((x) => x.id === made && x.deletedAt));
});

test('更新过的行恢复原字段、并入时追加的别名拿掉、新建的平台 / 权益删掉 —— 回到导入前的样子', async (t) => {
  const { up, h } = await setup(t);
  const tb = (await h.a.post('/platforms', { name: '淘宝' }, h.auth)).json.platform;
  const yk = (await h.a.post('/platforms', { name: '优酷' }, h.auth)).json.platform;
  const vip = (await h.a.post('/memberships', { platformId: tb.id, name: '88VIP', feeCents: 8800, expiresOn: '2026-06-30' }, h.auth)).json.membership;
  const coupon = (await h.a.post('/benefits', { membershipId: vip.id, name: '88 折购物券', limits: [{ type: 'other', text: '限本人' }] }, h.auth)).json.benefit;
  const done = await extractDraft(h, up, 'vip88.output.txt', 'vip88.source.txt');
  const ykNode = done.draft.platforms.find((p) => p.fields.name === '优酷视频');
  const applied = await h.a.post('/asset-import/apply', applyBodyOf(done, {
    edit: (n, item) => {
      if (n === ykNode) Object.assign(item, { action: 'merge', targetId: yk.id });
    },
  }), h.auth);
  assert.equal(applied.status, 200, applied.text);
  assert.equal((await items(h, '/memberships'))[0].expiresOn, '2026-12-31');
  assert.equal((await items(h, '/benefits')).length, 7);

  const r = await undo(h, done.importId);
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.json.restored, { memberships: 1, benefits: 1 });
  assert.deepEqual(r.json.undone, { platforms: 4, memberships: 0, benefits: 6, items: 0, transactions: 0, events: 0 });
  assert.equal(r.json.aliasesRemoved, 1);
  const card = (await items(h, '/memberships'))[0];
  assert.deepEqual([card.id, card.expiresOn, card.autoRenew, card.feeCents, card.origin], [vip.id, '2026-06-30', 'unknown', 8800, {}]);
  const perks = await items(h, '/benefits');
  assert.deepEqual(perks.map((b) => b.id), [coupon.id]);
  assert.deepEqual(perks[0].limits, [{ type: 'other', text: '限本人' }], 'limits 回到导入前（不是并集）');
  assert.deepEqual(perks[0].quota, []);
  const platforms = await items(h, '/platforms');
  assert.deepEqual(platforms.map((p) => p.name).sort(), ['优酷', '淘宝']);
  assert.deepEqual(platforms.find((p) => p.id === yk.id).aliases, []);
});

test('期间被改过的行不动（skippedChanged）；导入的权益上打过的卡跟着撤掉；导入前就有的东西原样', async (t) => {
  const { up, h } = await setup(t);
  const tb = (await h.a.post('/platforms', { name: '淘宝' }, h.auth)).json.platform;
  const vip = (await h.a.post('/memberships', { platformId: tb.id, name: '88VIP', expiresOn: '2026-06-30' }, h.auth)).json.membership;
  const done = await extractDraft(h, up, 'vip88.output.txt', 'vip88.source.txt');
  assert.equal((await h.a.post('/asset-import/apply', applyBodyOf(done), h.auth)).status, 200);
  await h.a.patch(`/memberships/${vip.id}`, { note: '导入后我自己记了一句' }, h.auth);
  const eleme = (await items(h, '/benefits')).find((b) => b.name === '饿了么超级会员年卡');
  assert.equal((await h.a.post('/benefit-events', { benefitId: eleme.id, kind: 'claim', occurredOn: '2026-09-22' }, h.auth)).status, 201);

  const r = await undo(h, done.importId);
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.json.skippedChanged, [{ table: 'memberships', id: vip.id, name: '88VIP', deleted: false }]);
  assert.equal(r.json.undone.events, 1);
  assert.equal(r.json.undone.benefits, 7);
  const card = (await items(h, '/memberships'))[0];
  assert.deepEqual([card.expiresOn, card.note], ['2026-12-31', '导入后我自己记了一句'], '改过的那行一个字都不动');
  assert.deepEqual(await items(h, '/benefit-events'), [], '打卡跟着权益撤掉');
  assert.deepEqual(await items(h, '/benefits'), []);
});

test('还被导入之外的数据用着的行留下（skippedInUse）：卡下手动加了权益 → 卡和平台留着；物品卖出记过收入 → 物品和随它记的流水留着', async (t) => {
  const { up, h } = await setup(t);
  const done = await extractDraft(h, up, 'vip88.output.txt', 'vip88.source.txt');
  const applied = await h.a.post('/asset-import/apply', applyBodyOf(done), h.auth);
  const vipId = applied.json.ids.m1;
  const tbId = applied.json.ids.p1;
  const mine = (await h.a.post('/benefits', { membershipId: vipId, name: '我自己加的' }, h.auth)).json.benefit;
  const r = await undo(h, done.importId);
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.json.skippedInUse.map((s) => [s.table, s.id, s.reason]), [['memberships', vipId, 'has_benefits'], ['platforms', tbId, 'in_use']]);
  assert.deepEqual((await items(h, '/benefits')).map((b) => b.id), [mine.id]);
  assert.deepEqual((await items(h, '/platforms')).map((p) => p.name), ['淘宝'], '领取平台都撤了，挂着卡的淘宝留着');

  const order = await extractDraft(h, up, ORDER, ORDER_SOURCE, { want: 'items' });
  const sold = await h.a.post('/asset-import/apply', applyBodyOf(order, {
    clientId: 'apply-order',
    edit: (n, item) => {
      if (n.fields.name === 'iPhone 16 Pro 256GB') Object.assign(item, { linkTransactionId: undefined, recordTransaction: { fundId: h.fund.id } });
    },
  }), h.auth);
  assert.equal(sold.status, 200, sold.text);
  const phone = (await items(h, '/assets')).find((a) => a.name === 'iPhone 16 Pro 256GB');
  assert.equal((await h.a.post(`/assets/${phone.id}/sell`, { saleCents: 500000, endedOn: '2026-09-23', recordTransaction: { fundId: h.fund.id } }, h.auth)).status, 200);
  const r2 = await undo(h, order.importId);
  assert.deepEqual(r2.json.skippedInUse.map((s) => [s.name, s.reason]), [['iPhone 16 Pro 256GB', 'sold']]);
  assert.deepEqual(r2.json.undone.items, 1);
  assert.equal(r2.json.undone.transactions, 0, '留下的物品，随它记的那笔也留着');
  assert.equal((await h.a.get(`/transactions/${phone.transactionId}`, h.auth)).status, 200);
});

test('谁能撤、什么时候能撤：本人或管理员；没导入的 409；撤过的再撤原样回（replayed）；撤过之后拿旧 clientId 重发 apply → 409 import_undone；超过 7 天 409', async (t) => {
  const { up, h } = await setup(t);
  await h.a.post('/members', { username: 'xiaohong', password: 'hunter22', displayName: '小红', role: 'member' }, h.auth);
  const her = { token: (await h.a.post('/auth/login', { username: 'xiaohong', password: 'hunter22' })).json.token };

  up.state.completions.push(ORDER);
  const hers = (await sse(h.srv.base, '/asset-import/extract', { token: her.token, body: { kind: 'text', text: ORDER_SOURCE, want: 'items' } })).of('done')[0].data;
  assert.equal((await h.a.post('/asset-import/apply', applyBodyOf(hers, { clientId: 'her-1' }), her)).status, 200);
  const mine = await extractDraft(h, up, ORDER, ORDER_SOURCE, { want: 'items' });
  const mineBody = applyBodyOf(mine, { clientId: 'mine-1', edit: (n, item) => Object.assign(item, { action: 'create' }) });
  assert.equal((await h.a.post('/asset-import/apply', mineBody, h.auth)).status, 200);
  const pending = await extractDraft(h, up, ORDER, ORDER_SOURCE, { want: 'items' });

  assert.equal((await undo(h, mine.importId, her)).status, 403, '普通成员不能撤别人的');
  assert.equal((await undo(h, 'nope')).status, 404);
  const notYet = await undo(h, pending.importId);
  assert.deepEqual([notYet.status, notYet.json.error.code], [409, 'import_not_applied']);

  const byAdmin = await undo(h, hers.importId);
  assert.equal(byAdmin.status, 200, '管理员能撤家里人的');
  const first = await undo(h, mine.importId);
  const again = await undo(h, mine.importId);
  assert.equal(again.status, 200);
  assert.equal(again.json.replayed, true);
  assert.deepEqual(again.json.undone, first.json.undone);
  const replay = await h.a.post('/asset-import/apply', mineBody, h.auth);
  assert.deepEqual([replay.status, replay.json.error.code], [409, 'import_undone'], '不能拿旧回应假装导进去了');

  // 超过 7 天：把 applied_at 往回拨 8 天，同一个数据目录重起
  const late = await extractDraft(h, up, ORDER, ORDER_SOURCE, { want: 'items' });
  assert.equal((await h.a.post('/asset-import/apply', applyBodyOf(late, { clientId: 'late-1', edit: (n, item) => Object.assign(item, { action: 'create' }) }), h.auth)).status, 200);
  await h.srv.stop();
  const db = openDb(h.srv.dataDir);
  try {
    db.run('UPDATE ai_imports SET applied_at = ? WHERE id = ?', new Date(Date.now() - 8 * 86400000).toISOString(), late.importId);
  } finally {
    db.close();
  }
  const srv = await startServer({ DATA_DIR: h.srv.dataDir, WEB_ROOT: h.srv.webRoot });
  t.after(() => srv.stop());
  const expired = await api(srv.base).post(`/asset-import/${late.importId}/undo`, {}, h.auth);
  assert.deepEqual([expired.status, expired.json.error.code], [409, 'undo_expired']);
});

test('撤销不把「N 选 1」撤坏：导入把已有权益改成 N 选 1、之后手动加了选项 → 那一行不恢复（choice_in_use），导入的选项删掉、手动的留着且还能改', async (t) => {
  const { up, h } = await setup(t);
  const tb = (await h.a.post('/platforms', { name: '淘宝' }, h.auth)).json.platform;
  const vip = (await h.a.post('/memberships', { platformId: tb.id, name: '88VIP', feeCents: 8800, expiresOn: '2026-12-31' }, h.auth)).json.membership;
  const old = (await h.a.post('/benefits', { membershipId: vip.id, name: '三选一', kind: 'other' }, h.auth)).json.benefit;
  const done = await extractDraft(h, up, 'vip88.output.txt', 'vip88.source.txt');
  const parentNode = done.draft.benefits.find((b) => b.fields.name === '三选一');
  assert.equal(parentNode.action, 'update');
  const applied = await h.a.post('/asset-import/apply', applyBodyOf(done, {
    edit: (n, item) => {
      if (n === parentNode) item.take = [...new Set([...(item.take || []), 'kind'])];
    },
  }), h.auth);
  assert.equal(applied.status, 200, applied.text);
  assert.equal((await items(h, '/benefits')).find((b) => b.id === old.id).kind, 'choice');
  const mine = await h.a.post('/benefits', { membershipId: vip.id, parentId: old.id, name: '我后来加的选项' }, h.auth);
  assert.equal(mine.status, 201, mine.text);

  const r = await undo(h, done.importId);
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.json.skippedInUse.filter((x) => x.table === 'benefits').map((x) => [x.id, x.reason]), [[old.id, 'choice_in_use']]);
  const all = await items(h, '/benefits');
  const parent = all.find((b) => b.id === old.id);
  assert.equal(parent.kind, 'choice', '还挂着后加的选项，不能改回非 N 选 1');
  assert.deepEqual(all.filter((b) => b.parentId === old.id).map((b) => b.name), ['我后来加的选项'], '导入建的三个选项删了');
  const patched = await h.a.patch(`/benefits/${mine.json.benefit.id}`, { name: '改个名' }, h.auth);
  assert.equal(patched.status, 200, `撤完那个选项还能改：${patched.text}`);
});

test('撤销后「N 选 1」的父权益和选项 flow 一致：父权益导入后又被改过（跳过）→ 选项不单独恢复 flow；父权益恢复了 → 选项跟着回去', async (t) => {
  const { up, h } = await setup(t);
  const tb = (await h.a.post('/platforms', { name: '淘宝' }, h.auth)).json.platform;
  const vip = (await h.a.post('/memberships', { platformId: tb.id, name: '88VIP', feeCents: 8800, expiresOn: '2026-12-31' }, h.auth)).json.membership;
  const par = await h.a.post('/benefits', { membershipId: vip.id, name: '三选一', kind: 'choice', flow: 'claim_use', quota: [{ p: 'term', n: 1 }] }, h.auth);
  assert.equal(par.status, 201, par.text);
  const parent = par.json.benefit;
  const kid = (await h.a.post('/benefits', { membershipId: vip.id, parentId: parent.id, name: '我原来的选项' }, h.auth)).json.benefit;
  const importFlow = async (clientId) => {
    const done = await extractDraft(h, up, 'vip88.output.txt', 'vip88.source.txt');
    const node = done.draft.benefits.find((b) => b.fields.name === '三选一');
    const r = await h.a.post('/asset-import/apply', applyBodyOf(done, {
      clientId,
      edit: (n, item) => {
        if (n === node) item.take = [...new Set([...(item.take || []), 'flow'])];
      },
    }), h.auth);
    assert.equal(r.status, 200, r.text);
    const mid = await items(h, '/benefits');
    assert.deepEqual([mid.find((b) => b.id === parent.id).flow, mid.find((b) => b.id === kid.id).flow], ['claim', 'claim']);
    return done;
  };

  const first = await importFlow('flow-1');
  assert.equal((await h.a.patch(`/benefits/${parent.id}`, { name: '音乐三选一' }, h.auth)).status, 200);
  const r = await undo(h, first.importId);
  assert.equal(r.status, 200, r.text);
  assert.ok(r.json.skippedChanged.some((x) => x.id === parent.id));
  let all = await items(h, '/benefits');
  assert.deepEqual([all.find((b) => b.id === parent.id).flow, all.find((b) => b.id === kid.id).flow], ['claim', 'claim'], '父权益没恢复，选项也别单独回去');

  // 把父权益改回原样再导一次，这回导入后谁都没动 → 父权益恢复，选项跟着回到 claim_use
  assert.equal((await h.a.patch(`/benefits/${parent.id}`, { name: '三选一', flow: 'claim_use' }, h.auth)).status, 200);
  const second = await importFlow('flow-2');
  const r2 = await undo(h, second.importId);
  assert.equal(r2.status, 200, r2.text);
  all = await items(h, '/benefits');
  assert.deepEqual([all.find((b) => b.id === parent.id).flow, all.find((b) => b.id === kid.id).flow], ['claim_use', 'claim_use']);
});

test('新建的「N 选 1」下面手动加了选项 → 父权益留着（has_options），导入的选项删掉；新建的行导入后被改过照样删', async (t) => {
  const { up, h } = await setup(t);
  const done = await extractDraft(h, up, 'vip88.output.txt', 'vip88.source.txt');
  const applied = await h.a.post('/asset-import/apply', applyBodyOf(done), h.auth);
  assert.equal(applied.status, 200, applied.text);
  const choice = (await items(h, '/benefits')).find((b) => b.name === '三选一');
  const mine = (await h.a.post('/benefits', { membershipId: choice.membershipId, parentId: choice.id, name: '爱奇艺年卡' }, h.auth)).json.benefit;
  const eleme = (await items(h, '/benefits')).find((b) => b.name === '饿了么超级会员年卡');
  assert.equal((await h.a.patch(`/benefits/${eleme.id}`, { note: '导入后记了一句' }, h.auth)).status, 200);

  const r = await undo(h, done.importId);
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.json.skippedInUse.map((x) => [x.table, x.name, x.reason]), [
    ['benefits', '三选一', 'has_options'],
    ['memberships', '88VIP', 'has_benefits'],
    ['platforms', '淘宝', 'in_use'],
  ]);
  const left = await items(h, '/benefits');
  assert.deepEqual(left.map((b) => b.id).sort(), [choice.id, mine.id].sort(), '改过备注的饿了么年卡照样删（它本来就是这次导入的）');
  assert.deepEqual(r.json.skippedChanged, []);
});

test('更新过的行导入后被删了 → skippedChanged 标 deleted；恢复的领取平台已经删了就写 null', async (t) => {
  const { up, h } = await setup(t);
  const tb = (await h.a.post('/platforms', { name: '淘宝' }, h.auth)).json.platform;
  const tx = (await h.a.post('/platforms', { name: '腾讯视频' }, h.auth)).json.platform;
  const vip = (await h.a.post('/memberships', { platformId: tb.id, name: '88VIP', feeCents: 8800, expiresOn: '2026-12-31' }, h.auth)).json.membership;
  const yk = (await h.a.post('/benefits', { membershipId: vip.id, name: '优酷视频年卡', claimPlatformId: tx.id }, h.auth)).json.benefit;
  const coupon = (await h.a.post('/benefits', { membershipId: vip.id, name: '88 折购物券' }, h.auth)).json.benefit;
  const done = await extractDraft(h, up, 'vip88.output.txt', 'vip88.source.txt');
  const ykNode = done.draft.benefits.find((b) => b.fields.name === '优酷视频年卡');
  const applied = await h.a.post('/asset-import/apply', applyBodyOf(done, {
    edit: (n, item) => {
      if (n === ykNode) item.take = ['claimPlatform'];
    },
  }), h.auth);
  assert.equal(applied.status, 200, applied.text);
  assert.notEqual((await items(h, '/benefits')).find((b) => b.id === yk.id).claimPlatformId, tx.id);
  assert.equal((await h.a.del(`/platforms/${tx.id}`, h.auth)).status, 200, '原来的领取平台没人用了，删掉');
  assert.equal((await h.a.del(`/benefits/${coupon.id}`, h.auth)).status, 200, '导入更新过的购物券删掉');

  const r = await undo(h, done.importId);
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.json.skippedChanged.filter((x) => x.id === coupon.id).map((x) => [x.name, x.deleted]), [['88 折购物券', true]]);
  const back = (await items(h, '/benefits')).find((b) => b.id === yk.id);
  assert.equal(back.claimPlatformId, null, '原来的平台不在了：写 null（会员本平台），不指向已删的');
  assert.ok(!(await items(h, '/platforms')).some((p) => p.name === '优酷视频'), '导入建的优酷视频没人用了，删掉');
});

test('最近的 AI 导入（GET /asset-import/recent）：7 天内导入了、没撤销的；本人只看自己的，管理员看全家（带是谁）；撤了就不在；只识别没导入的不在', async (t) => {
  const { up, h } = await setup(t);
  await h.a.post('/members', { username: 'xiaohong', password: 'hunter22', displayName: '小红', role: 'member' }, h.auth);
  const her = { token: (await h.a.post('/auth/login', { username: 'xiaohong', password: 'hunter22' })).json.token };

  up.state.completions.push(ORDER);
  const hers = (await sse(h.srv.base, '/asset-import/extract', { token: her.token, body: { kind: 'text', text: ORDER_SOURCE, want: 'items' } })).of('done')[0].data;
  assert.equal((await h.a.post('/asset-import/apply', applyBodyOf(hers, { clientId: 'her-r' }), her)).status, 200);
  const mine = await extractDraft(h, up, 'vip88.output.txt', 'vip88.source.txt');
  assert.equal((await h.a.post('/asset-import/apply', applyBodyOf(mine, { clientId: 'mine-r' }), h.auth)).status, 200);
  await extractDraft(h, up, ORDER, ORDER_SOURCE, { want: 'items' }); // 只识别、没导入

  const admin = await h.a.get('/asset-import/recent', h.auth);
  assert.equal(admin.status, 200, admin.text);
  assert.deepEqual(admin.json.items.map((x) => [x.importId, x.mine, x.memberName]), [[mine.importId, true, '小明'], [hers.importId, false, '小红']]);
  const top = admin.json.items[0];
  assert.equal(top.sourceKind, 'text');
  assert.equal(top.daysLeft, 7);
  assert.deepEqual(top.created, { platforms: 6, memberships: 1, benefits: 7, items: 0, transactions: 0 });
  assert.ok(top.appliedAt && top.createdAt);

  const hersOnly = await h.a.get('/asset-import/recent', her);
  assert.deepEqual(hersOnly.json.items.map((x) => [x.importId, x.mine]), [[hers.importId, true]], '普通成员只看自己的');

  assert.equal((await undo(h, mine.importId)).status, 200);
  assert.deepEqual((await h.a.get('/asset-import/recent', h.auth)).json.items.map((x) => x.importId), [hers.importId], '撤了就不在');
});
