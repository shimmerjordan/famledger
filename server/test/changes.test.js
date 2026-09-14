'use strict';

// GET /changes —— 同步游标。一次请求跨所有可同步的表按 seq 取增量。

const test = require('node:test');
const assert = require('node:assert/strict');

const { household } = require('./fixtures');

const TABLES = ['members', 'accounts', 'funds', 'categories', 'transactions', 'budgets', 'rules'];

test('since=0 返回全部实体，且不泄漏口令散列', async (t) => {
  const { a, auth } = await household(t);
  const r = await a.get('/changes?since=0', auth);
  assert.equal(r.status, 200, r.text);

  for (const k of TABLES) assert.ok(Array.isArray(r.json[k]), `缺少 ${k} 数组`);
  assert.equal(r.json.since, 0);
  assert.equal(r.json.more, false);
  assert.ok(r.json.next > 0);

  assert.equal(r.json.members.length, 1);
  assert.equal(r.json.members[0].username, 'admin');
  assert.ok(!('passwordHash' in r.json.members[0]), '口令散列不能进同步流');
  assert.ok(!('password_hash' in r.json.members[0]));
  assert.equal(r.json.categories.length, 21);
  assert.equal(r.json.funds.length, 1);
  assert.equal(r.json.accounts.length, 1);
  assert.deepEqual(r.json.transactions, []);
  assert.deepEqual(r.json.budgets, []);
  assert.deepEqual(r.json.rules, []);

  const maxSeq = Math.max(...TABLES.flatMap((k) => r.json[k].map((x) => x.seq)));
  assert.equal(r.json.next, maxSeq, 'next 是本次返回的最大 seq');
});

test('写一笔之后 since=上次的 next 只返回新行', async (t) => {
  const { a, auth, fund, put } = await household(t);
  const first = (await a.get('/changes?since=0', auth)).json;

  const tx = (await a.post('/transactions', {
    type: 'expense', amountCents: 4200, fundId: fund.id, merchant: '菜市场',
  }, auth)).json.transaction;
  await put('/budgets', { scope: 'fund', refId: fund.id, month: '*', amountCents: 300000 });

  const delta = await a.get(`/changes?since=${first.next}`, auth);
  assert.equal(delta.status, 200, delta.text);
  assert.equal(delta.json.since, first.next);
  assert.deepEqual(delta.json.transactions.map((x) => x.id), [tx.id]);
  assert.equal(delta.json.transactions[0].amountCents, 4200);
  assert.deepEqual(delta.json.transactions[0].tags, [], 'tags 是解析过的数组');
  assert.equal(delta.json.budgets.length, 1);
  assert.deepEqual(delta.json.members, []);
  assert.deepEqual(delta.json.categories, []);
  assert.equal(delta.json.more, false);
  assert.ok(delta.json.next > first.next);

  const empty = await a.get(`/changes?since=${delta.json.next}`, auth);
  assert.equal(empty.json.next, delta.json.next, '没有新行时 next 原地不动');
  assert.equal(empty.json.more, false);
  for (const k of TABLES) assert.deepEqual(empty.json[k], [], `${k} 应当为空`);
});

test('软删的行带 deletedAt 进增量', async (t) => {
  const { a, auth, fund } = await household(t);
  const tx = (await a.post('/transactions', { type: 'expense', amountCents: 100, fundId: fund.id }, auth)).json.transaction;
  const mid = (await a.get('/changes?since=0', auth)).json.next;

  assert.equal((await a.del(`/transactions/${tx.id}`, auth)).status, 200);

  const delta = await a.get(`/changes?since=${mid}`, auth);
  assert.equal(delta.json.transactions.length, 1);
  assert.equal(delta.json.transactions[0].id, tx.id);
  assert.ok(delta.json.transactions[0].deletedAt, '墓碑行必须带 deletedAt，客户端才知道要删');
});

test('limit 封顶：more:true，且逐页取能把每一行都取到', async (t) => {
  const { a, auth, fund } = await household(t);
  // 设新的默认基金会同时改两行（新基金 + 被清掉默认的老基金）
  const made = (await a.post('/funds', { name: '旅行基金', kind: 'goal', isDefault: true }, auth)).json.fund;

  const page = await a.get('/changes?since=0&limit=1', auth);
  assert.equal(page.status, 200, page.text);
  assert.equal(page.json.more, true);
  assert.equal(TABLES.reduce((n, k) => n + page.json[k].length, 0), 1, 'limit 是跨表总数');

  let cursor = 0;
  const seen = [];
  for (let i = 0; i < 200; i++) {
    const r = await a.get(`/changes?since=${cursor}&limit=1`, auth);
    const rows = TABLES.flatMap((k) => r.json[k].map((x) => `${k}:${x.id}`));
    seen.push(...rows);
    assert.ok(r.json.next >= cursor);
    if (!r.json.more) break;
    assert.ok(r.json.next > cursor, `next 必须前进，否则客户端死循环 (since=${cursor})`);
    cursor = r.json.next;
  }
  assert.equal(new Set(seen).size, seen.length, '逐页拉取不能重复');
  assert.ok(seen.includes(`funds:${made.id}`));
  assert.ok(seen.includes(`funds:${fund.id}`), '被动改掉 isDefault 的老基金也要能同步到');
});

test('since / limit 非法 → 400；未登录 → 401', async (t) => {
  const { a, auth } = await household(t);
  assert.equal((await a.get('/changes?since=abc', auth)).json.error.code, 'invalid_since');
  assert.equal((await a.get('/changes?since=-1', auth)).json.error.code, 'invalid_since');
  assert.equal((await a.get('/changes?limit=99999', auth)).json.error.code, 'invalid_limit');
  assert.equal((await a.get('/changes')).status, 401);
});
