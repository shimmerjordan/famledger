'use strict';

// 流水「不计入账户余额」（transactions.off_balance，口径在 lib/stats_sql.js 的 deltaMap）：
//   · 不进真账户的余额 → 不进现金流、净资产；账户「现在余额」校准也不算它；
//   · 照常进月收支、板块余额、预算、按类别聚合、日历、趋势；
//   · 债务内部账户那一侧照常算：不计余额的支出关联成借出后，真账户不动、应收冒出来。
// 所有数字手算。

const test = require('node:test');
const assert = require('node:assert/strict');

const { household } = require('./fixtures');

const MONTH = '2026-09';

function ok(r, what) {
  assert.ok(r.status >= 200 && r.status < 300, `${what} → ${r.status} ${r.text}`);
  return r.json;
}

function fail(r, status, code, what) {
  assert.equal(r.status, status, `${what} → ${r.status} ${r.text}`);
  assert.equal(r.json.error.code, code, `${what} 的错误码`);
  return r.json.error;
}

async function setup(t) {
  const h = await household(t);
  const { a, auth } = h;
  const bank = ok(await a.post('/accounts', { name: '招行卡', kind: 'bank', initialBalanceCents: 1000000 }, auth), 'POST 招行卡').account;
  const food = h.categories.find((c) => c.name === '餐饮' && c.kind === 'expense');
  assert.ok(food, '种子类别里要有餐饮/expense');
  return {
    ...h, bank, food,
    mk: async (body) => ok(await a.post('/transactions', body, auth), `POST ${body.merchant || body.type}`).transaction,
    get: async (id) => ok(await a.get(`/transactions/${id}`, auth), 'GET /transactions/:id').transaction,
    list: async (q = '') => ok(await a.get(`/transactions?limit=200${q}`, auth), 'GET /transactions').items,
    overview: async () => ok(await a.get(`/stats/overview?month=${MONTH}`, auth), 'GET /stats/overview'),
  };
}

const balanceOf = (o, id) => o.accounts.find((x) => x.accountId === id)?.balanceCents;
const fundOf = (o, id) => o.funds.find((x) => x.fundId === id);
const budgetOf = (o, scope, refId) => o.month.budgets.find((b) => b.scope === scope && b.refId === refId);

test('不计余额的支出：账户余额不变，月支出 / 板块 / 预算 / 类别 / 日历 / 趋势照算；PATCH 翻转余额跟着变；bulk 改回；筛选与布尔输出', async (t) => {
  const h = await setup(t);
  const { a, auth, bank, food, fund } = h;
  ok(await h.put('/budgets', { scope: 'fund', refId: fund.id, month: '*', amountCents: 100000 }), 'PUT 预算');
  const before = await h.overview();

  const t1 = await h.mk({
    type: 'expense', amountCents: 5000, occurredAt: '2026-09-03T10:00:00+08:00', accountId: bank.id, fundId: fund.id,
    categoryId: food.id, merchant: '账单导入', offBalance: true,
  });
  assert.equal(t1.offBalance, true, '响应里是布尔 true');
  const t2 = await h.mk({
    type: 'expense', amountCents: 300, occurredAt: '2026-09-04T10:00:00+08:00', accountId: bank.id, fundId: fund.id,
    categoryId: food.id, merchant: '手记',
  });
  assert.equal(t2.offBalance, false, '缺省计入');

  let o = await h.overview();
  assert.equal(balanceOf(o, bank.id), 1000000 - 300, '不计余额的 50.00 不扣账户，只扣手记的 3.00');
  assert.equal(o.cashCents, before.cashCents - 300, '现金流同样只少 3.00');
  assert.equal(o.netWorthCents, before.netWorthCents - 300, '净资产同样只少 3.00');
  assert.equal(o.month.expenseCents, 5300, '月支出照算');
  assert.deepEqual(fundOf(o, fund.id), { fundId: fund.id, balanceCents: -5300, balances: { CNY: -5300 } }, '板块余额照减');
  assert.equal(budgetOf(o, 'fund', fund.id).spentCents, 5300, '预算照算');
  assert.deepEqual(o.month.byCategory, [{ categoryId: food.id, expenseCents: 5300 }], '按类别照算');
  const cal = ok(await a.get(`/stats/calendar?month=${MONTH}`, auth), 'GET /stats/calendar').days;
  assert.deepEqual(cal, [
    { date: '2026-09-03', expenseCents: 5000, incomeCents: 0, count: 1 },
    { date: '2026-09-04', expenseCents: 300, incomeCents: 0, count: 1 },
  ], '日历照算');
  const trend = ok(await a.get(`/stats/trend?months=1&endMonth=${MONTH}`, auth), 'GET /stats/trend').series;
  assert.deepEqual(trend, [{ month: MONTH, expenseCents: 5300, incomeCents: 0 }], '趋势照算');
  const fs = ok(await a.get(`/stats/fund/${fund.id}?month=${MONTH}`, auth), 'GET /stats/fund/:id');
  assert.equal(fs.monthExpenseCents, 5300, '板块详情的月支出照算');
  assert.deepEqual(fs.balances, { CNY: -5300 }, '板块详情的余额照减');

  // PATCH 翻成计入：余额跟着减；月支出不变。
  const flipped = ok(await a.patch(`/transactions/${t1.id}`, { offBalance: false }, auth), 'PATCH offBalance:false').transaction;
  assert.equal(flipped.offBalance, false);
  o = await h.overview();
  assert.equal(balanceOf(o, bank.id), 1000000 - 5300, '翻成计入后余额跟着减');
  assert.equal(o.netWorthCents, before.netWorthCents - 5300);
  assert.equal(o.month.expenseCents, 5300, '月支出不变');
  const renamed = ok(await a.patch(`/transactions/${t1.id}`, { merchant: '改个名' }, auth), 'PATCH merchant').transaction;
  assert.equal(renamed.offBalance, false, 'PATCH 没传 offBalance 就沿用');

  // bulk 改回不计。
  assert.equal(ok(await a.post('/transactions/bulk', { ids: [t1.id], patch: { offBalance: true } }, auth), 'bulk').updated, 1);
  assert.equal((await h.get(t1.id)).offBalance, true);
  o = await h.overview();
  assert.equal(balanceOf(o, bank.id), 1000000 - 300, 'bulk 改回后余额也回去');
  fail(await a.post('/transactions/bulk', { ids: [t1.id], patch: { offBalance: 'yes' } }, auth), 400, 'invalid_offBalance', 'bulk 非布尔');
  fail(await a.post('/transactions', { type: 'expense', amountCents: 1, offBalance: 'yes' }, auth), 400, 'invalid_offBalance', 'POST 非布尔');

  // 筛选与布尔输出。
  assert.deepEqual((await h.list('&offBalance=1')).map((x) => x.id), [t1.id], 'offBalance=1 只出不计的');
  assert.deepEqual((await h.list('&offBalance=true')).map((x) => x.id), [t1.id]);
  assert.deepEqual((await h.list('&offBalance=0')).map((x) => x.id), [t2.id], 'offBalance=0 只出计入的');
  fail(await a.get('/transactions?offBalance=yes', auth), 400, 'invalid_offBalance', '筛选值不对');
  const all = await h.list();
  assert.equal(all.find((x) => x.id === t1.id).offBalance, true, '列表里是布尔');
  assert.equal(all.find((x) => x.id === t2.id).offBalance, false);
  const changes = ok(await a.get('/changes?since=0', auth), 'GET /changes');
  assert.equal(changes.transactions.find((x) => x.id === t1.id).offBalance, true, '同步里也是布尔');
  assert.equal(changes.transactions.find((x) => x.id === t2.id).offBalance, false);
});

test('batch 每项各自带 offBalance；不计余额的转账两头都不动', async (t) => {
  const h = await setup(t);
  const { a, auth, bank } = h;
  const other = ok(await a.post('/accounts', { name: '支付宝', kind: 'alipay', initialBalanceCents: 20000 }, auth), 'POST 支付宝').account;
  const r = ok(await a.post('/transactions/batch', {
    items: [
      { clientId: 'ob-1', type: 'expense', amountCents: 100, occurredAt: '2026-09-01T12:00:00+08:00', accountId: bank.id, offBalance: true },
      { clientId: 'ob-2', type: 'income', amountCents: 200, occurredAt: '2026-09-01T12:00:00+08:00', accountId: bank.id, offBalance: false },
      { clientId: 'ob-3', type: 'expense', amountCents: 50, occurredAt: '2026-09-01T12:00:00+08:00', accountId: bank.id },
      { clientId: 'ob-4', type: 'transfer', amountCents: 700, occurredAt: '2026-09-02T12:00:00+08:00', accountId: bank.id, toAccountId: other.id, offBalance: true },
      { clientId: 'ob-5', type: 'expense', amountCents: 1, accountId: bank.id, offBalance: 'yes' },
    ],
  }, auth), 'POST /transactions/batch');
  assert.deepEqual(r.results.map((x) => x.status), ['created', 'created', 'created', 'created', 'error']);
  assert.equal(r.results[4].error, 'invalid_offBalance');
  const flags = [];
  for (const x of r.results.slice(0, 4)) flags.push((await h.get(x.id)).offBalance);
  assert.deepEqual(flags, [true, false, false, true], '每项各自的 offBalance');

  const o = await h.overview();
  assert.equal(balanceOf(o, bank.id), 1000000 + 200 - 50, '不计余额的支出、转账都不动招行卡');
  assert.equal(balanceOf(o, other.id), 20000, '不计余额的转账转入侧也不动');
  assert.equal(o.month.expenseCents, 150, '月支出照算');
  assert.equal(o.month.incomeCents, 200);
});

test('账户校准不算不计余额的流水：期初 = 目标 − 计入的流水', async (t) => {
  const h = await setup(t);
  const { a, auth } = h;
  const card = ok(await a.post('/accounts', { name: '工资卡', kind: 'bank', initialBalanceCents: 50000 }, auth), 'POST 工资卡').account;
  await h.mk({ type: 'expense', amountCents: 12000, occurredAt: '2026-09-02T12:00:00+08:00', accountId: card.id, merchant: '计入的' });
  const off = await h.mk({ type: 'expense', amountCents: 3000, occurredAt: '2026-09-02T13:00:00+08:00', accountId: card.id, merchant: '不计的', offBalance: true });

  const fixed = ok(await a.patch(`/accounts/${card.id}`, { currentBalanceCents: 100000 }, auth), 'PATCH 校准').account;
  assert.equal(fixed.initialBalanceCents, 112000, '期初 = 100000 − (−12000)，不计的 30.00 不在里面');
  let o = await h.overview();
  assert.equal(balanceOf(o, card.id), 100000);

  // 把那笔翻成计入，余额才少 30.00 —— 证明校准时确实没算它。
  ok(await a.patch(`/transactions/${off.id}`, { offBalance: false }, auth), 'PATCH 翻成计入');
  o = await h.overview();
  assert.equal(balanceOf(o, card.id), 97000);
});

test('关键：不计余额的支出关联成借出 → 真账户不变、内部账户 +50.00、月支出 −50.00、净资产 +50.00；不计余额的收入关联成收回同理', async (t) => {
  const h = await setup(t);
  const { a, auth, bank, fund, food } = h;
  const t1 = await h.mk({
    type: 'expense', amountCents: 5000, occurredAt: '2026-09-03T10:00:00+08:00', accountId: bank.id, fundId: fund.id,
    categoryId: food.id, merchant: '转给张三', offBalance: true,
  });
  const before = await h.overview();
  assert.equal(balanceOf(before, bank.id), 1000000, '导入的账单不动余额');
  assert.equal(before.month.expenseCents, 5000);
  assert.equal(fundOf(before, fund.id).balanceCents, -5000);

  const d = ok(await a.post('/debts', {
    direction: 'lend', counterparty: '张三', amountCents: 5000, startedOn: '2026-09-03', recordTransaction: { transactionId: t1.id },
  }, auth), 'POST 借出（关联）').debt;
  assert.deepEqual(d.memoLog, [], '经流水走的不留备忘');
  const linked = await h.get(t1.id);
  assert.equal(linked.type, 'transfer');
  assert.equal(linked.accountId, bank.id);
  assert.equal(linked.toAccountId, d.accountId);
  assert.equal(linked.offBalance, true, 'off_balance 不动');
  assert.equal(linked.categoryId, null);
  assert.equal(linked.fundId, null);
  assert.equal(linked.merchant, '转给张三');

  let o = await h.overview();
  assert.equal(balanceOf(o, bank.id), 1000000, '真账户余额不变（它靠校准）');
  assert.equal(balanceOf(o, d.accountId), 5000, '内部账户那一侧照常算');
  assert.equal(o.debts.receivableCents, 5000);
  assert.equal(o.month.expenseCents, before.month.expenseCents - 5000, '月支出少了这笔');
  assert.equal(o.netWorthCents, before.netWorthCents + 5000, '应收冒出来了');
  assert.equal(o.cashCents, before.cashCents, '现金流不变');
  assert.equal(fundOf(o, fund.id).balanceCents, 0, '板块余额回去了');

  const t2 = await h.mk({
    type: 'income', amountCents: 2000, occurredAt: '2026-09-10T10:00:00+08:00', accountId: bank.id, fundId: fund.id,
    merchant: '张三还钱', offBalance: true,
  });
  const mid = await h.overview();
  assert.equal(balanceOf(mid, bank.id), 1000000);
  assert.equal(mid.month.incomeCents, 2000);
  const s = ok(await a.post(`/debts/${d.id}/settle`, { amountCents: 2000, occurredOn: '2026-09-10', transactionId: t2.id }, auth), 'settle（关联）');
  assert.equal(s.transactions.length, 1);
  assert.equal(s.transactions[0].id, t2.id);
  assert.equal(s.transactions[0].type, 'transfer');
  assert.equal(s.transactions[0].accountId, d.accountId);
  assert.equal(s.transactions[0].toAccountId, bank.id);
  assert.equal(s.transactions[0].offBalance, true);
  o = await h.overview();
  assert.equal(balanceOf(o, bank.id), 1000000, '收回的钱也不动真账户');
  assert.equal(balanceOf(o, d.accountId), 3000, '还剩 30.00');
  assert.equal(o.month.incomeCents, 0, '月收入少了这笔');
  assert.equal(o.netWorthCents, mid.netWorthCents - 2000, '应收少了 20.00，真账户没变');
});
