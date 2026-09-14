'use strict';

// accounts / funds / categories / budgets / rules —— 家庭的主数据。四种资源共用
// 同一个软删 CRUD 工厂，所以工厂的契约只在 accounts 上完整验一遍，其余各自只验
// 「不一样的那点」（唯一默认基金、模板、月度解析、正则校验）。

const test = require('node:test');
const assert = require('node:assert/strict');

const { household } = require('./fixtures');

// ── accounts ────────────────────────────────────────────────────────────
test('账户 CRUD：软删后列表不含；?archived=1 含归档但不含已删', async (t) => {
  const { a, auth } = await household(t);

  const created = await a.post('/accounts', {
    name: '招行储蓄卡',
    kind: 'bank',
    initialBalanceCents: 100000,
    icon: 'account_balance',
    color: '#1292C0',
    matchHints: { tail: '6688', apps: ['com.cmb'] },
  }, auth);
  assert.equal(created.status, 201, created.text);
  const acct = created.json.account;
  assert.ok(acct.id);
  assert.equal(acct.name, '招行储蓄卡');
  assert.equal(acct.kind, 'bank');
  assert.equal(acct.initialBalanceCents, 100000);
  assert.equal(acct.currency, 'CNY', '币种默认取家庭设置');
  assert.equal(acct.color, '#1292c0', '颜色统一小写');
  assert.deepEqual(acct.matchHints, { tail: '6688', apps: ['com.cmb'] });
  assert.equal(acct.archived, false);
  assert.ok(!('deleted_at' in acct), 'JSON 必须是 camelCase');
  assert.equal(acct.deletedAt, null);
  assert.ok(acct.seq > 0);

  const bad = await a.post('/accounts', { name: '乱写', kind: 'crypto' }, auth);
  assert.equal(bad.status, 400);
  assert.equal(bad.json.error.code, 'invalid_kind');

  const patched = await a.patch(`/accounts/${acct.id}`, { name: '招行(工资卡)' }, auth);
  assert.equal(patched.status, 200, patched.text);
  assert.equal(patched.json.account.name, '招行(工资卡)');
  assert.equal(patched.json.account.kind, 'bank', 'PATCH 不动没传的字段');
  assert.ok(patched.json.account.seq > acct.seq, '每次写都要推进 seq');

  const archived = await a.patch(`/accounts/${acct.id}`, { archived: true }, auth);
  assert.equal(archived.json.account.archived, true);

  const plain = await a.get('/accounts', auth);
  assert.equal(plain.json.items.find((x) => x.id === acct.id), undefined, '默认列表不含归档');
  const withArchived = await a.get('/accounts?archived=1', auth);
  assert.ok(withArchived.json.items.some((x) => x.id === acct.id), '?archived=1 含归档');

  const removed = await a.del(`/accounts/${acct.id}`, auth);
  assert.equal(removed.status, 200, removed.text);
  assert.ok(removed.json.account.deletedAt, '软删要写 deletedAt');

  const after = await a.get('/accounts?archived=1', auth);
  assert.equal(after.json.items.find((x) => x.id === acct.id), undefined, '软删行永远不出现在列表里');

  const gone = await a.patch(`/accounts/${acct.id}`, { name: '再改' }, auth);
  assert.equal(gone.status, 404);
  assert.equal(gone.json.error.code, 'not_found');
});

test('账户/基金/类别被已确认流水引用时不能删，返回 409', async (t) => {
  const { a, auth, fund, account, category } = await household(t);

  const tx = await a.post('/transactions', {
    type: 'expense', amountCents: 1990, fundId: fund.id, accountId: account.id, categoryId: category.id,
  }, auth);
  assert.equal(tx.status, 201, tx.text);

  const f = await a.del(`/funds/${fund.id}`, auth);
  assert.equal(f.status, 409);
  assert.equal(f.json.error.code, 'fund_in_use');
  const ac = await a.del(`/accounts/${account.id}`, auth);
  assert.equal(ac.status, 409);
  assert.equal(ac.json.error.code, 'account_in_use');
  const c = await a.del(`/categories/${category.id}`, auth);
  assert.equal(c.status, 409);
  assert.equal(c.json.error.code, 'category_in_use');

  // 归档是出路：归档后列表默认看不到，但历史流水仍指得住。
  const arch = await a.patch(`/funds/${fund.id}`, { archived: true }, auth);
  assert.equal(arch.json.fund.archived, true);
});

// ── funds ───────────────────────────────────────────────────────────────
test('GET /funds/templates 至少 6 条且含「宠物基金」', async (t) => {
  const { a, auth } = await household(t);
  const r = await a.get('/funds/templates', auth);
  assert.equal(r.status, 200, r.text);
  assert.ok(r.json.items.length >= 6, `模板只有 ${r.json.items.length} 条`);
  const pet = r.json.items.find((x) => x.name === '宠物基金');
  assert.ok(pet, '模板里应当有宠物基金');
  assert.equal(pet.kind, 'goal');
  assert.ok(pet.description);
});

test('基金 isDefault 唯一：设新的默认会清掉老的', async (t) => {
  const { a, auth, fund } = await household(t);
  assert.equal(fund.isDefault, true, '初始化种的基金就是默认基金');

  const made = await a.post('/funds', { name: '旅行基金', kind: 'goal', targetCents: 2000000, isDefault: true }, auth);
  assert.equal(made.status, 201, made.text);
  assert.equal(made.json.fund.isDefault, true);
  assert.ok(made.json.fund.color, '颜色必填，没传时自动配一个');

  const items = (await a.get('/funds', auth)).json.items;
  assert.deepEqual(items.filter((f) => f.isDefault).map((f) => f.id), [made.json.fund.id]);
  assert.ok(items.find((f) => f.id === fund.id).seq > fund.seq, '被清掉默认的那条也要推进 seq，否则同步不到');
});

test('PUT /funds/reorder 按 ids 顺序重排', async (t) => {
  const { a, auth, fund, put } = await household(t);
  const b = (await a.post('/funds', { name: '应急金', kind: 'reserve' }, auth)).json.fund;
  const c = (await a.post('/funds', { name: '育儿基金', kind: 'goal' }, auth)).json.fund;
  assert.deepEqual((await a.get('/funds', auth)).json.items.map((f) => f.id), [fund.id, b.id, c.id]);

  const r = await put('/funds/reorder', { ids: [c.id, fund.id, b.id] });
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.json.items.map((f) => f.id), [c.id, fund.id, b.id]);
  assert.deepEqual((await a.get('/funds', auth)).json.items.map((f) => f.id), [c.id, fund.id, b.id]);
  assert.deepEqual(r.json.items.map((f) => f.sortOrder), [0, 1, 2]);

  const missing = await put('/funds/reorder', { ids: [c.id, 'nope'] });
  assert.equal(missing.status, 404);
});

// ── categories ──────────────────────────────────────────────────────────
test('类别 POST：kind 非法 → 400；合法 → 201', async (t) => {
  const { a, auth } = await household(t);
  const bad = await a.post('/categories', { name: '打赏', kind: 'both' }, auth);
  assert.equal(bad.status, 400);
  assert.equal(bad.json.error.code, 'invalid_kind');

  const missing = await a.post('/categories', { name: '打赏' }, auth);
  assert.equal(missing.status, 400);
  assert.equal(missing.json.error.code, 'invalid_kind');

  const ok = await a.post('/categories', { name: '打赏', kind: 'expense', icon: 'redeem' }, auth);
  assert.equal(ok.status, 201, ok.text);
  assert.equal(ok.json.category.kind, 'expense');
  assert.ok(ok.json.category.sortOrder >= 21, '新类别排在种子类别后面');
});

// ── budgets ─────────────────────────────────────────────────────────────
test('预算：* 默认月生效，精确月覆盖，amountCents:null 删除', async (t) => {
  const { a, auth, fund, put } = await household(t);

  const star = await put('/budgets', { scope: 'fund', refId: fund.id, month: '*', amountCents: 50000 });
  assert.equal(star.status, 200, star.text);
  assert.equal(star.json.budget.month, '*');

  let g = await a.get('/budgets?month=2026-09', auth);
  assert.equal(g.status, 200, g.text);
  assert.equal(g.json.items.length, 1);
  assert.equal(g.json.items[0].month, '*');
  assert.equal(g.json.items[0].amountCents, 50000);
  assert.equal(g.json.items[0].scope, 'fund');
  assert.equal(g.json.items[0].refId, fund.id);

  const exact = await put('/budgets', { scope: 'fund', refId: fund.id, month: '2026-09', amountCents: 80000 });
  assert.equal(exact.status, 200, exact.text);

  g = await a.get('/budgets?month=2026-09', auth);
  assert.equal(g.json.items.length, 1, '同一个 refId 只返回一条生效预算');
  assert.equal(g.json.items[0].month, '2026-09');
  assert.equal(g.json.items[0].amountCents, 80000);

  g = await a.get('/budgets?month=2026-10', auth);
  assert.equal(g.json.items[0].amountCents, 50000, '别的月份仍然吃默认');

  // 不带 month：把所有原始行都给出来（编辑界面要用）
  const all = await a.get('/budgets', auth);
  assert.equal(all.json.items.length, 2);

  const again = await put('/budgets', { scope: 'fund', refId: fund.id, month: '2026-09', amountCents: 90000 });
  assert.equal(again.json.budget.id, exact.json.budget.id, '同一 (scope,refId,month) 走更新而不是新建');

  const del = await put('/budgets', { scope: 'fund', refId: fund.id, month: '2026-09', amountCents: null });
  assert.equal(del.status, 200, del.text);
  assert.ok(del.json.budget.deletedAt);

  g = await a.get('/budgets?month=2026-09', auth);
  assert.equal(g.json.items.length, 1);
  assert.equal(g.json.items[0].month, '*', '删掉精确月之后回落到默认');

  // 唯一键被墓碑占着，重新 PUT 必须复活同一行而不是 500
  const revived = await put('/budgets', { scope: 'fund', refId: fund.id, month: '2026-09', amountCents: 12345 });
  assert.equal(revived.status, 200, revived.text);
  assert.equal(revived.json.budget.id, exact.json.budget.id);
  assert.equal(revived.json.budget.deletedAt, null);

  const badMonth = await put('/budgets', { scope: 'fund', refId: fund.id, month: '2026-9', amountCents: 1 });
  assert.equal(badMonth.status, 400);
  assert.equal(badMonth.json.error.code, 'invalid_month');
  const badScope = await put('/budgets', { scope: 'member', refId: fund.id, month: '*', amountCents: 1 });
  assert.equal(badScope.status, 400);
  assert.equal(badScope.json.error.code, 'invalid_scope');
});

// ── rules ───────────────────────────────────────────────────────────────
test('规则 CRUD：按 priority 排序，regex 必须能编译', async (t) => {
  const { a, auth, fund, category } = await household(t);

  const r1 = await a.post('/rules', {
    field: 'merchant', op: 'contains', pattern: '星巴克', categoryId: category.id, fundId: fund.id, priority: 50,
  }, auth);
  assert.equal(r1.status, 201, r1.text);
  assert.equal(r1.json.rule.enabled, true);
  assert.equal(r1.json.rule.priority, 50);

  const r2 = await a.post('/rules', { field: 'text', op: 'regex', pattern: '滴滴|高德', priority: 10 }, auth);
  assert.equal(r2.status, 201, r2.text);

  const bad = await a.post('/rules', { field: 'text', op: 'regex', pattern: '([' }, auth);
  assert.equal(bad.status, 400);
  assert.equal(bad.json.error.code, 'invalid_pattern');
  const badField = await a.post('/rules', { field: 'sender', op: 'contains', pattern: 'x' }, auth);
  assert.equal(badField.status, 400);
  assert.equal(badField.json.error.code, 'invalid_field');

  const list = await a.get('/rules', auth);
  assert.deepEqual(list.json.items.map((x) => x.id), [r2.json.rule.id, r1.json.rule.id], '按 priority 升序');

  const off = await a.patch(`/rules/${r1.json.rule.id}`, { enabled: false, pattern: 'Starbucks' }, auth);
  assert.equal(off.json.rule.enabled, false);
  assert.equal(off.json.rule.pattern, 'Starbucks');

  assert.equal((await a.del(`/rules/${r2.json.rule.id}`, auth)).status, 200);
  assert.deepEqual((await a.get('/rules', auth)).json.items.map((x) => x.id), [r1.json.rule.id]);
});

test('主数据接口都要登录', async (t) => {
  const { a } = await household(t);
  for (const p of ['/accounts', '/funds', '/categories', '/budgets', '/rules']) {
    const r = await a.get(p);
    assert.equal(r.status, 401, `${p} 应当 401`);
  }
  const w = await a.post('/funds', { name: '偷偷建' });
  assert.equal(w.status, 401);
});
