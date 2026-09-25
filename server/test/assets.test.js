'use strict';

// 资产 · 物品：CRUD 与日期/状态校验、「同时记账」与资产同生共死、卖出、同步墓碑、
// 备份恢复带上新表。派生数（天数、日均）只在客户端算，这里不验。

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const { household } = require('./fixtures');
const { tmpDir } = require('./helpers');

const pad = (n) => String(n).padStart(2, '0');
/** 本地日期，偏移 `days` 天；helpers.js 已把本进程钉在 Asia/Shanghai，和子进程一致。 */
function localDay(days = 0) {
  const d = new Date();
  d.setDate(d.getDate() + days);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

const PHONE = { name: '手机', category: 'digital', priceCents: 599900, purchasedOn: '2025-03-01' };

test('物品 CRUD：默认值、PATCH、重排、软删后 404', async (t) => {
  const { a, auth, put } = await household(t);

  const created = await a.post('/assets', { ...PHONE, icon: 'smartphone', expectedDays: 1095, note: '主力机' }, auth);
  assert.equal(created.status, 201, created.text);
  const phone = created.json.asset;
  assert.ok(phone.id);
  assert.equal(phone.name, '手机');
  assert.equal(phone.category, 'digital');
  assert.equal(phone.priceCents, 599900);
  assert.equal(phone.purchasedOn, '2025-03-01');
  assert.equal(phone.status, 'in_use');
  assert.equal(phone.endedOn, null);
  assert.equal(phone.saleCents, null);
  assert.equal(phone.expectedDays, 1095);
  assert.equal(phone.transactionId, null, '没要求记账就不建流水');
  assert.equal(phone.archived, false);
  assert.ok(phone.seq > 0);

  const bare = (await a.post('/assets', { name: '椅子', priceCents: 30000, purchasedOn: '2024-01-01' }, auth)).json.asset;
  assert.equal(bare.category, 'other', '分类缺省 other');

  const patched = await a.patch(`/assets/${phone.id}`, { name: '旧手机', status: 'idle' }, auth);
  assert.equal(patched.status, 200, patched.text);
  assert.equal(patched.json.asset.name, '旧手机');
  assert.equal(patched.json.asset.status, 'idle');
  assert.equal(patched.json.asset.priceCents, 599900, 'PATCH 不动没传的字段');
  assert.ok(patched.json.asset.seq > phone.seq);

  const order = await put('/assets/reorder', { ids: [bare.id, phone.id] });
  assert.equal(order.status, 200, order.text);
  assert.deepEqual(order.json.items.map((x) => x.id), [bare.id, phone.id]);

  const removed = await a.del(`/assets/${phone.id}`, auth);
  assert.equal(removed.status, 200, removed.text);
  assert.ok(removed.json.asset.deletedAt);
  const list = (await a.get('/assets?archived=1', auth)).json.items;
  assert.deepEqual(list.map((x) => x.id), [bare.id], '软删行不出现在列表里');
  assert.equal((await a.patch(`/assets/${phone.id}`, { name: 'x' }, auth)).status, 404);

  assert.equal((await a.get('/assets')).status, 401);
});

test('新建校验：非法输入一律 400', async (t) => {
  const { a, auth } = await household(t);
  const cases = [
    [{ ...PHONE, name: undefined }, 'invalid_name'],
    [{ ...PHONE, priceCents: undefined }, 'invalid_priceCents'],
    [{ ...PHONE, priceCents: -1 }, 'invalid_priceCents'],
    [{ ...PHONE, priceCents: 1.5 }, 'invalid_priceCents'],
    [{ ...PHONE, category: 'toy' }, 'invalid_category'],
    [{ ...PHONE, status: 'lost' }, 'invalid_status'],
    [{ ...PHONE, purchasedOn: undefined }, 'invalid_purchasedOn'],
    [{ ...PHONE, purchasedOn: '2025/3/1' }, 'invalid_purchasedOn'],
    [{ ...PHONE, purchasedOn: '2025-02-30' }, 'invalid_purchasedOn'],
    [{ ...PHONE, purchasedOn: localDay(1) }, 'invalid_purchasedOn'],
    [{ ...PHONE, expectedDays: 0 }, 'invalid_expectedDays'],
    [{ ...PHONE, expectedDays: 36501 }, 'invalid_expectedDays'],
    [{ ...PHONE, endedOn: '2025-06-01' }, 'invalid_endedOn'],
    [{ ...PHONE, status: 'retired', endedOn: '2025-02-28' }, 'invalid_endedOn'],
    [{ ...PHONE, status: 'retired', endedOn: localDay(1) }, 'invalid_endedOn'],
    [{ ...PHONE, saleCents: 100 }, 'invalid_saleCents'],
    [{ ...PHONE, memberId: 'nobody' }, 'invalid_memberId'],
    [{ ...PHONE, recordTransaction: 'yes' }, 'invalid_recordTransaction'],
  ];
  for (const [body, code] of cases) {
    const r = await a.post('/assets', body, auth);
    assert.equal(r.status, 400, `${JSON.stringify(body)} → ${r.status} ${r.text}`);
    assert.equal(r.json.error.code, code, JSON.stringify(body));
  }
  assert.equal((await a.post('/assets', [1], auth)).json.error.code, 'bad_json');
  assert.deepEqual((await a.get('/assets', auth)).json.items, [], '校验失败一条都不落库');

  const today = await a.post('/assets', { ...PHONE, purchasedOn: localDay(0) }, auth);
  assert.equal(today.status, 201, `今天买的可以：${today.text}`);
});

test('状态与结束日期：退役记日期，改回在用清空结束日与卖出价', async (t) => {
  const { a, auth } = await household(t);
  const phone = (await a.post('/assets', PHONE, auth)).json.asset;

  const retired = await a.patch(`/assets/${phone.id}`, { status: 'retired' }, auth);
  assert.equal(retired.status, 200, retired.text);
  assert.equal(retired.json.asset.endedOn, localDay(0), '转成退役却没给日期，就记今天');

  const dated = await a.patch(`/assets/${phone.id}`, { endedOn: '2026-01-15', saleCents: 20000 }, auth);
  assert.equal(dated.status, 200, dated.text);
  assert.equal(dated.json.asset.endedOn, '2026-01-15');
  assert.equal(dated.json.asset.saleCents, 20000);

  const renamed = await a.patch(`/assets/${phone.id}`, { note: '碎屏' }, auth);
  assert.equal(renamed.json.asset.endedOn, '2026-01-15', '无关的 PATCH 不改结束日期');

  const late = await a.patch(`/assets/${phone.id}`, { purchasedOn: '2026-02-01' }, auth);
  assert.equal(late.status, 400, late.text);
  assert.equal(late.json.error.code, 'invalid_purchasedOn', '买入日期不能挪到结束日期之后');

  const mixed = await a.patch(`/assets/${phone.id}`, { status: 'in_use', endedOn: '2026-01-20' }, auth);
  assert.equal(mixed.status, 400, mixed.text);
  assert.equal(mixed.json.error.code, 'invalid_endedOn');

  const back = await a.patch(`/assets/${phone.id}`, { status: 'in_use' }, auth);
  assert.equal(back.status, 200, back.text);
  assert.equal(back.json.asset.status, 'in_use');
  assert.equal(back.json.asset.endedOn, null);
  assert.equal(back.json.asset.saleCents, null);

  const onlyEnd = await a.patch(`/assets/${phone.id}`, { endedOn: '2026-01-20' }, auth);
  assert.equal(onlyEnd.status, 400, '在用的物品不能单独写结束日期');
});

test('新建时同时记一笔支出：字段正确并写回 transactionId', async (t) => {
  const { a, auth, fund, account, categories, member } = await household(t);
  const cat = categories.find((c) => c.kind === 'expense');

  const r = await a.post('/assets', { ...PHONE, recordTransaction: { accountId: account.id, categoryId: cat.id } }, auth);
  assert.equal(r.status, 201, r.text);
  const asset = r.json.asset;
  assert.ok(asset.transactionId, '要写回 transactionId');

  const tx = (await a.get(`/transactions/${asset.transactionId}`, auth)).json.transaction;
  assert.equal(tx.type, 'expense');
  assert.equal(tx.amountCents, 599900);
  assert.equal(tx.occurredAt, '2025-03-01T12:00:00+08:00');
  assert.equal(tx.merchant, '手机');
  assert.equal(tx.source, 'manual');
  assert.equal(tx.status, 'confirmed');
  assert.equal(tx.accountId, account.id);
  assert.equal(tx.categoryId, cat.id);
  assert.equal(tx.fundId, fund.id, '没给基金走默认基金');
  assert.equal(tx.memberId, member.id);

  const free = await a.post('/assets', { ...PHONE, name: '赠品耳机', priceCents: 0, recordTransaction: { accountId: account.id } }, auth);
  assert.equal(free.status, 201, free.text);
  assert.equal(free.json.asset.transactionId, null, '价格为 0 不记账');
  assert.equal((await a.get('/transactions', auth)).json.items.length, 1);

  // 删资产不连带删流水：那笔钱是真花出去了。
  assert.equal((await a.del(`/assets/${asset.id}`, auth)).status, 200);
  assert.equal((await a.get(`/transactions/${asset.transactionId}`, auth)).status, 200);
});

test('记账失败时资产也不落库（同一事务）', async (t) => {
  const { a, auth } = await household(t);
  const r = await a.post('/assets', { ...PHONE, recordTransaction: { fundId: 'no-such-fund' } }, auth);
  assert.equal(r.status, 400, r.text);
  assert.equal(r.json.error.code, 'invalid_fundId');
  assert.deepEqual((await a.get('/assets', auth)).json.items, [], '流水校验失败，资产必须一起回滚');
  assert.deepEqual((await a.get('/transactions', auth)).json.items, []);
});

test('卖出：状态/日期/卖出价落库，可同时记一笔收入', async (t) => {
  const { a, auth, account, categories } = await household(t);
  const income = categories.find((c) => c.kind === 'income');
  const phone = (await a.post('/assets', PHONE, auth)).json.asset;

  const bad = [
    [{ endedOn: '2026-01-01' }, 'invalid_saleCents'],
    [{ saleCents: -1, endedOn: '2026-01-01' }, 'invalid_saleCents'],
    [{ saleCents: 100 }, 'invalid_endedOn'],
    [{ saleCents: 100, endedOn: '2025-02-01' }, 'invalid_endedOn'],
    [{ saleCents: 100, endedOn: localDay(1) }, 'invalid_endedOn'],
    [{ saleCents: 100, endedOn: '2026-01-01', recordTransaction: [] }, 'invalid_recordTransaction'],
  ];
  for (const [body, code] of bad) {
    const r = await a.post(`/assets/${phone.id}/sell`, body, auth);
    assert.equal(r.status, 400, `${JSON.stringify(body)} → ${r.text}`);
    assert.equal(r.json.error.code, code, JSON.stringify(body));
  }

  const rollback = await a.post(`/assets/${phone.id}/sell`, {
    saleCents: 150000, endedOn: '2026-08-01', recordTransaction: { accountId: 'nope' },
  }, auth);
  assert.equal(rollback.status, 400, rollback.text);
  const still = (await a.get('/assets', auth)).json.items.find((x) => x.id === phone.id);
  assert.equal(still.status, 'in_use', '收入没记成，卖出也不能生效');

  const sold = await a.post(`/assets/${phone.id}/sell`, {
    saleCents: 150000, endedOn: '2026-08-01', recordTransaction: { accountId: account.id, categoryId: income.id },
  }, auth);
  assert.equal(sold.status, 200, sold.text);
  const s = sold.json.asset;
  assert.equal(s.status, 'sold');
  assert.equal(s.endedOn, '2026-08-01');
  assert.equal(s.saleCents, 150000);
  assert.ok(s.saleTransactionId);
  assert.ok(s.seq > phone.seq);

  const tx = (await a.get(`/transactions/${s.saleTransactionId}`, auth)).json.transaction;
  assert.equal(tx.type, 'income');
  assert.equal(tx.amountCents, 150000);
  assert.equal(tx.merchant, '卖出 手机');
  assert.equal(tx.occurredAt, '2026-08-01T12:00:00+08:00');
  assert.equal(tx.accountId, account.id);
  assert.equal(tx.categoryId, income.id);

  const twice = await a.post(`/assets/${phone.id}/sell`, { saleCents: 1, endedOn: '2026-08-02' }, auth);
  assert.equal(twice.status, 409, '卖过的不能再卖一次（防重复记收入）');

  const gift = (await a.post('/assets', { ...PHONE, name: '旧自行车' }, auth)).json.asset;
  const given = await a.post(`/assets/${gift.id}/sell`, {
    saleCents: 0, endedOn: '2026-08-01', recordTransaction: { accountId: account.id },
  }, auth);
  assert.equal(given.status, 200, given.text);
  assert.equal(given.json.asset.saleTransactionId, null, '白送不记收入');
  assert.equal((await a.get('/transactions', auth)).json.items.length, 1);

  const lamp = (await a.post('/assets', { ...PHONE, name: '旧台灯' }, auth)).json.asset;
  const quiet = await a.post(`/assets/${lamp.id}/sell`, { saleCents: 100, endedOn: '2026-08-01' }, auth);
  assert.equal(quiet.status, 200, quiet.text);
  assert.equal(quiet.json.asset.saleCents, 100);
  assert.equal(quiet.json.asset.saleTransactionId, null, '卖了钱但没要 recordTransaction，就不记收入');
  assert.equal((await a.get('/transactions', auth)).json.items.length, 1);

  assert.equal((await a.post('/assets/nope/sell', { saleCents: 1, endedOn: '2026-01-01' }, auth)).status, 404);
});

test('卖出记的收入还在时，不能改回在用/闲置，也不能绕道退役再卖一次', async (t) => {
  const { a, auth, account } = await household(t);
  const incomes = async () => (await a.get('/transactions?type=income', auth)).json.items;
  const record = { recordTransaction: { accountId: account.id } };
  const phone = (await a.post('/assets', PHONE, auth)).json.asset;
  const sold = (await a.post(`/assets/${phone.id}/sell`, { saleCents: 50000, endedOn: '2026-08-01', ...record }, auth)).json.asset;
  assert.ok(sold.saleTransactionId);

  for (const status of ['in_use', 'idle']) {
    const r = await a.patch(`/assets/${phone.id}`, { status }, auth);
    assert.equal(r.status, 409, `${status}: ${r.text}`);
    assert.equal(r.json.error.code, 'sale_recorded');
  }
  const kept = (await a.get('/assets', auth)).json.items.find((x) => x.id === phone.id);
  assert.equal(kept.status, 'sold');
  assert.equal(kept.saleTransactionId, sold.saleTransactionId, '被拒的 PATCH 不能丢掉和收入的关联');

  const retired = await a.patch(`/assets/${phone.id}`, { status: 'retired' }, auth);
  assert.equal(retired.status, 200, retired.text);
  assert.equal(retired.json.asset.saleTransactionId, sold.saleTransactionId);
  const again = await a.post(`/assets/${phone.id}/sell`, { saleCents: 60000, endedOn: '2026-08-02', ...record }, auth);
  assert.equal(again.status, 409, again.text);
  assert.equal(again.json.error.code, 'sale_recorded');
  assert.equal((await incomes()).length, 1, '同一件物品不能记出两笔卖出收入');

  assert.equal((await a.del(`/transactions/${sold.saleTransactionId}`, auth)).status, 200);
  const back = await a.patch(`/assets/${phone.id}`, { status: 'in_use' }, auth);
  assert.equal(back.status, 200, back.text);
  assert.equal(back.json.asset.saleTransactionId, null, '收入删掉后改回在用，关联要一起清掉');
  assert.equal(back.json.asset.saleCents, null);
  assert.equal(back.json.asset.endedOn, null);

  const resold = await a.post(`/assets/${phone.id}/sell`, { saleCents: 60000, endedOn: '2026-08-02', ...record }, auth);
  assert.equal(resold.status, 200, resold.text);
  assert.deepEqual((await incomes()).map((x) => x.amountCents), [60000]);

  // 作废的流水不进统计，和删掉一样放行。
  const voided = await a.post(`/transactions/${resold.json.asset.saleTransactionId}/void`, {}, auth);
  assert.equal(voided.status, 200, voided.text);
  const idle = await a.patch(`/assets/${phone.id}`, { status: 'idle' }, auth);
  assert.equal(idle.status, 200, idle.text);
  assert.equal(idle.json.asset.saleTransactionId, null);

  const lamp = (await a.post('/assets', { ...PHONE, name: '台灯' }, auth)).json.asset;
  assert.equal((await a.post(`/assets/${lamp.id}/sell`, { saleCents: 100, endedOn: '2026-08-01' }, auth)).status, 200);
  const undo = await a.patch(`/assets/${lamp.id}`, { status: 'in_use' }, auth);
  assert.equal(undo.status, 200, `卖出时没记收入的，随时能改回来：${undo.text}`);
});

test('/changes 同步 assets，软删带墓碑', async (t) => {
  const { a, auth } = await household(t);
  const before = (await a.get('/changes?since=0', auth)).json;
  assert.deepEqual(before.assets, []);

  const phone = (await a.post('/assets', PHONE, auth)).json.asset;
  const delta = (await a.get(`/changes?since=${before.next}`, auth)).json;
  assert.deepEqual(delta.assets.map((x) => x.id), [phone.id]);
  assert.equal(delta.assets[0].archived, false, 'archived 要还原成布尔');
  assert.equal(delta.assets[0].priceCents, 599900);

  await a.del(`/assets/${phone.id}`, auth);
  const tomb = (await a.get(`/changes?since=${delta.next}`, auth)).json;
  assert.equal(tomb.assets.length, 1);
  assert.ok(tomb.assets[0].deletedAt, '墓碑行必须带 deletedAt');
});

test('备份导出/导入带上 assets 表', async (t) => {
  const { srv, a, auth, token } = await household(t);
  const kept = (await a.post('/assets', PHONE, auth)).json.asset;
  const dump = await fetch(`${srv.base}/api/v1/backup/export`, { headers: { authorization: `Bearer ${token}` } });
  assert.equal(dump.status, 200);
  const gz = Buffer.from(await dump.arrayBuffer());

  await a.post('/assets', { ...PHONE, name: '导出之后买的' }, auth);
  const r = await fetch(`${srv.base}/api/v1/backup/import`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/gzip' },
    body: gz,
  });
  assert.equal(r.status, 200, await r.text());
  assert.deepEqual((await a.get('/assets', auth)).json.items.map((x) => x.id), [kept.id]);
});

test('旧库（只有 001）重开时补上 assets 表 —— 恢复旧备份走的就是这条路', () => {
  const { openDb } = require('../src/lib/db');
  const dir = tmpDir('assets-migrate');
  const oldSql = tmpDir('assets-sql');
  const sqlDir = path.join(__dirname, '..', 'src', 'sql');
  fs.copyFileSync(path.join(sqlDir, '001_init.sql'), path.join(oldSql, '001_init.sql'));

  const old = openDb(dir, { sqlDir: oldSql });
  assert.equal(old.get("SELECT 1 AS ok FROM sqlite_master WHERE type='table' AND name='assets'"), null);
  old.close();

  const db = openDb(dir);
  try {
    assert.ok(db.get("SELECT 1 AS ok FROM sqlite_master WHERE type='table' AND name='assets'"));
    assert.ok(db.get('SELECT 1 AS ok FROM schema_migrations WHERE version = 2'));
  } finally {
    db.close();
    fs.rmSync(dir, { recursive: true, force: true });
    fs.rmSync(oldSql, { recursive: true, force: true });
  }
});

test('幂等：同一个 clientId 重发新建/卖出只算一次（回应丢了 App 会原样再发）', async (t) => {
  const { a, auth, account, categories } = await household(t);
  const cat = categories.find((c) => c.kind === 'expense');
  const body = { ...PHONE, recordTransaction: { accountId: account.id, categoryId: cat.id }, clientId: 'asset-1' };

  const first = await a.post('/assets', body, auth);
  assert.equal(first.status, 201, first.text);
  const again = await a.post('/assets', body, auth);
  assert.equal(again.status, 200, again.text);
  assert.equal(again.json.replayed, true);
  assert.equal(again.json.asset.id, first.json.asset.id);
  assert.equal(again.json.asset.transactionId, first.json.asset.transactionId);
  assert.equal((await a.get('/assets', auth)).json.items.length, 1, '不多出一件');
  assert.equal((await a.get('/transactions', auth)).json.items.length, 1, '不多记一笔支出');

  // 第一次成功之后那个账户删了（或改了），重发照样认得出，不因为校验失败让 App 以为没记上
  const other = (await a.post('/assets', { ...PHONE, name: '平板', clientId: 'asset-2' }, auth)).json.asset;
  const replay = await a.post('/assets', { ...PHONE, name: '平板', recordTransaction: { accountId: 'gone' }, clientId: 'asset-2' }, auth);
  assert.equal(replay.status, 200, replay.text);
  assert.equal(replay.json.asset.id, other.id);

  // 卖出：重发不再撞 409 already_sold，而是回放成功
  const sell = { saleCents: 150000, endedOn: '2026-08-01', recordTransaction: { accountId: account.id }, clientId: 'sell-1' };
  const s1 = await a.post(`/assets/${other.id}/sell`, sell, auth);
  assert.equal(s1.status, 200, s1.text);
  const s2 = await a.post(`/assets/${other.id}/sell`, sell, auth);
  assert.equal(s2.status, 200, s2.text);
  assert.equal(s2.json.replayed, true);
  assert.equal(s2.json.asset.saleTransactionId, s1.json.asset.saleTransactionId);
  assert.equal((await a.get('/transactions', auth)).json.items.length, 2, '只有买手机那笔支出 + 一笔卖出收入');
  // 不带 clientId 的重复卖出照旧 409
  assert.equal((await a.post(`/assets/${other.id}/sell`, { saleCents: 1, endedOn: '2026-08-02' }, auth)).status, 409);
  // 同一个 clientId 拿去卖另一件：说清楚
  const r = await a.post(`/assets/${first.json.asset.id}/sell`, sell, auth);
  assert.equal(r.status, 409, r.text);
  assert.equal(r.json.error.code, 'client_id_reused');
});

// ---------------------------------------------------------------- 估值字段（P1）

const VALUATION_KEYS = ['valuationMethod', 'rateBp', 'residualBp', 'manualValueCents', 'manualValueOn', 'netWorth'];
const valuationOf = (asset) => Object.fromEntries(VALUATION_KEYS.map((k) => [k, asset[k]]));

test('估值字段：默认 auto / null，可写可清；新类别 luxury、jewelry 可用；手动估值可以高于原价', async (t) => {
  const { a, auth } = await household(t);
  const phone = (await a.post('/assets', PHONE, auth)).json.asset;
  assert.deepEqual(valuationOf(phone), {
    valuationMethod: 'auto', rateBp: null, residualBp: null, manualValueCents: null, manualValueOn: null, netWorth: 'auto',
  });

  const set = await a.patch(`/assets/${phone.id}`, {
    valuationMethod: 'declining', rateBp: 2000, residualBp: 1000,
    manualValueCents: 700000, manualValueOn: '2026-01-01', netWorth: 'exclude',
  }, auth);
  assert.equal(set.status, 200, set.text);
  assert.deepEqual(valuationOf(set.json.asset), {
    valuationMethod: 'declining', rateBp: 2000, residualBp: 1000, manualValueCents: 700000, manualValueOn: '2026-01-01', netWorth: 'exclude',
  });
  const note = await a.patch(`/assets/${phone.id}`, { note: '换了壳' }, auth);
  assert.equal(note.json.asset.manualValueOn, '2026-01-01', '无关的 PATCH 不动锚点');

  const cleared = await a.patch(`/assets/${phone.id}`, {
    valuationMethod: null, rateBp: null, residualBp: null, manualValueCents: null, manualValueOn: null, netWorth: null,
  }, auth);
  assert.equal(cleared.status, 200, cleared.text);
  assert.deepEqual(valuationOf(cleared.json.asset), {
    valuationMethod: 'auto', rateBp: null, residualBp: null, manualValueCents: null, manualValueOn: null, netWorth: 'auto',
  });

  for (const category of ['luxury', 'jewelry']) {
    const r = await a.post('/assets', { ...PHONE, name: category, category }, auth);
    assert.equal(r.status, 201, r.text);
    assert.equal(r.json.asset.category, category);
  }
});

test('估值字段校验：非法一律 400；锚点金额和日期成对，日期不早于买入、不晚于今天', async (t) => {
  const { a, auth } = await household(t);
  const cases = [
    [{ ...PHONE, valuationMethod: 'fifo' }, 'invalid_valuationMethod'],
    [{ ...PHONE, rateBp: -1 }, 'invalid_rateBp'],
    [{ ...PHONE, rateBp: 9001 }, 'invalid_rateBp'],
    [{ ...PHONE, rateBp: 12.5 }, 'invalid_rateBp'],
    [{ ...PHONE, residualBp: 10001 }, 'invalid_residualBp'],
    [{ ...PHONE, netWorth: 'yes' }, 'invalid_netWorth'],
    [{ ...PHONE, netWorth: true }, 'invalid_netWorth'],
    [{ ...PHONE, manualValueCents: -1, manualValueOn: '2026-01-01' }, 'invalid_manualValueCents'],
    [{ ...PHONE, manualValueCents: 100000 }, 'invalid_manualValueOn'],
    [{ ...PHONE, manualValueOn: '2026-01-01' }, 'invalid_manualValueCents'],
    [{ ...PHONE, manualValueCents: 100000, manualValueOn: '2026/1/1' }, 'invalid_manualValueOn'],
    [{ ...PHONE, manualValueCents: 100000, manualValueOn: '2026-02-30' }, 'invalid_manualValueOn'],
    [{ ...PHONE, manualValueCents: 100000, manualValueOn: localDay(1) }, 'invalid_manualValueOn'],
    [{ ...PHONE, manualValueCents: 100000, manualValueOn: '2025-02-28' }, 'invalid_manualValueOn'],
  ];
  for (const [body, code] of cases) {
    const r = await a.post('/assets', body, auth);
    assert.equal(r.status, 400, `${JSON.stringify(body)} → ${r.status} ${r.text}`);
    assert.equal(r.json.error.code, code, JSON.stringify(body));
  }
  assert.deepEqual((await a.get('/assets', auth)).json.items, [], '校验失败一条都不落库');

  const made = await a.post('/assets', { ...PHONE, manualValueCents: 100000, manualValueOn: PHONE.purchasedOn }, auth);
  assert.equal(made.status, 201, `买入当天估的可以：${made.text}`);
  const id = made.json.asset.id;

  // PATCH 比的是「旧行 + 本次改动」合并后的样子。
  const half = await a.patch(`/assets/${id}`, { manualValueCents: null }, auth);
  assert.equal(half.status, 400, half.text);
  assert.equal(half.json.error.code, 'invalid_manualValueCents', '只清一列等于留下半个锚点');
  const moved = await a.patch(`/assets/${id}`, { purchasedOn: '2025-04-01' }, auth);
  assert.equal(moved.status, 400, moved.text);
  assert.equal(moved.json.error.code, 'invalid_purchasedOn', '买入日期不能挪到估值日期之后');
  const kept = (await a.get('/assets', auth)).json.items[0];
  assert.equal(kept.manualValueCents, 100000);
  assert.equal(kept.purchasedOn, '2025-03-01');
});

test('/changes 带上估值字段（别的设备靠它同步）', async (t) => {
  const { a, auth } = await household(t);
  const before = (await a.get('/changes?since=0', auth)).json;
  await a.post('/assets', {
    ...PHONE, valuationMethod: 'locked', manualValueCents: 650000, manualValueOn: '2026-01-01', netWorth: 'include',
  }, auth);
  const row = (await a.get(`/changes?since=${before.next}`, auth)).json.assets[0];
  assert.deepEqual(valuationOf(row), {
    valuationMethod: 'locked', rateBp: null, residualBp: null, manualValueCents: 650000, manualValueOn: '2026-01-01', netWorth: 'include',
  });
});

test('旧库（001–004）重开：补上估值列（老行按 auto、seq 不动）和 idx_holdings_seq', () => {
  const { openDb } = require('../src/lib/db');
  const dir = tmpDir('valuation-migrate');
  const oldSql = tmpDir('valuation-sql');
  const sqlDir = path.join(__dirname, '..', 'src', 'sql');
  for (const f of fs.readdirSync(sqlDir).filter((x) => /^00[1-4]_.+\.sql$/.test(x))) {
    fs.copyFileSync(path.join(sqlDir, f), path.join(oldSql, f));
  }

  const old = openDb(dir, { sqlDir: oldSql });
  old.run(
    'INSERT INTO assets(id, name, category, price_cents, purchased_on, created_at, updated_at, seq)' +
      " VALUES('old-1', '旧电视', 'appliance', 300000, '2020-01-01', '2020-01-01T00:00:00.000Z', '2020-01-01T00:00:00.000Z', 1)",
  );
  assert.equal(old.get("SELECT 1 AS ok FROM sqlite_master WHERE type='index' AND name='idx_holdings_seq'"), null);
  old.close();

  const db = openDb(dir);
  try {
    assert.ok(db.get('SELECT 1 AS ok FROM schema_migrations WHERE version = 5'));
    const row = db.get('SELECT * FROM assets WHERE id = ?', 'old-1');
    assert.equal(row.valuation_method, 'auto');
    assert.equal(row.net_worth, 'auto');
    assert.equal(row.rate_bp, null);
    assert.equal(row.residual_bp, null);
    assert.equal(row.manual_value_cents, null);
    assert.equal(row.manual_value_on, null);
    assert.equal(row.seq, 1, 'ALTER 不动 seq：客户端的老缓存靠 fromJson 兜底');
    assert.ok(db.get("SELECT 1 AS ok FROM sqlite_master WHERE type='index' AND name='idx_holdings_seq'"));
  } finally {
    db.close();
    fs.rmSync(dir, { recursive: true, force: true });
    fs.rmSync(oldSql, { recursive: true, force: true });
  }
});
