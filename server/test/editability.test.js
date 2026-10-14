'use strict';

// 手动微调：算出来的数也要能改。
//   · 板块余额：期初按币种（openingBalances），校准 = currentBalances（现在实际有多少）→ 差额进期初，不记流水、不进月收支。
//   · 账户余额：currentBalanceCents → 差额进 initialBalanceCents；债务的内部账户只能到债务里改。
//   · 理财：「更新金额」能补记以前的日子，不能是将来。
//   · 债务：总额、还剩多少（留一行「校准」）、只记了数时的方向；备忘行能改能删，期初和总额跟着改回来。
//   · 汇率：手填的自动抓取不覆盖，「恢复自动」删掉手填的再抓。

const test = require('node:test');
const assert = require('node:assert/strict');

const { household } = require('./fixtures');
const { startFakeFx } = require('./fx_upstream');

function ok(r, what) {
  assert.ok(r.status >= 200 && r.status < 300, `${what} → ${r.status} ${r.text}`);
  return r.json;
}

function fail(r, status, code, what) {
  assert.equal(r.status, status, `${what} → ${r.status} ${r.text}`);
  assert.equal(r.json.error.code, code, `${what} 的错误码`);
  return r.json.error;
}

const localDay = (d = new Date()) =>
  `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;

async function setup(t, env) {
  const h = await household(t, env);
  const { a, auth } = h;
  return {
    ...h,
    overview: async () => ok(await a.get('/stats/overview', auth), 'GET /stats/overview'),
    tx: async (body) => ok(await a.post('/transactions', body, auth), 'POST /transactions').transaction,
  };
}

test('板块校准：填现在实际有多少，差额进期初；只动给了的币种；不记流水、不进本月收支；同步带期初', async (t) => {
  const h = await setup(t);
  const { a, auth } = h;
  const usd = ok(await a.post('/accounts', { name: '美元户', kind: 'bank', currency: 'USD' }, auth), 'POST 美元户').account;
  const fund = ok(await a.post('/funds', { name: '旅行' }, auth), 'POST 板块').fund;
  assert.deepEqual(fund.openingBalances, {}, '新板块期初为空');

  await h.tx({ type: 'expense', amountCents: 3000, accountId: h.account.id, fundId: fund.id, categoryId: h.category.id });
  await h.tx({ type: 'expense', amountCents: 500, accountId: usd.id, fundId: fund.id, categoryId: h.category.id });
  const before = await h.overview();
  const monthBefore = before.month.expenseCents;

  const fixed = ok(await a.patch(`/funds/${fund.id}`, { currentBalances: { CNY: 100000 } }, auth), 'PATCH 校准人民币').fund;
  assert.deepEqual(fixed.openingBalances, { CNY: 103000 }, '期初 = 目标 − 流水（−30.00）');
  let o = await h.overview();
  assert.deepEqual(o.funds.find((f) => f.fundId === fund.id).balances, { CNY: 100000, USD: -500 }, '美元那份不动');
  assert.equal(o.month.expenseCents, monthBefore, '校准不进本月支出');
  assert.equal(o.month.incomeCents, before.month.incomeCents, '也不进本月收入');

  ok(await a.patch(`/funds/${fund.id}`, { currentBalances: { USD: 0, EUR: 2000 } }, auth), 'PATCH 校准美元、加一个欧元');
  o = await h.overview();
  assert.deepEqual(o.funds.find((f) => f.fundId === fund.id).balances, { CNY: 100000, EUR: 2000 });
  const stats = ok(await a.get(`/stats/fund/${fund.id}`, auth), 'GET /stats/fund/:id');
  assert.deepEqual(stats.balances, { CNY: 100000, EUR: 2000 }, '板块详情同一个口径');

  // 期初整份替换；再记一笔流水，余额照常跟着变。
  ok(await a.patch(`/funds/${fund.id}`, { openingBalances: { CNY: 0 } }, auth), 'PATCH 清掉期初');
  await h.tx({ type: 'income', amountCents: 1000, accountId: h.account.id, fundId: fund.id });
  o = await h.overview();
  assert.deepEqual(o.funds.find((f) => f.fundId === fund.id).balances, { CNY: -2000, USD: -500 });

  const changes = ok(await a.get('/changes?since=0', auth), 'GET /changes');
  assert.deepEqual(changes.funds.find((f) => f.id === fund.id).openingBalances, {}, '同步里期初是对象不是字符串');

  fail(await a.patch(`/funds/${fund.id}`, { currentBalances: { C1: 1 } }, auth), 400, 'invalid_currentBalances', '币种要三位字母');
  fail(await a.patch(`/funds/${fund.id}`, { currentBalances: 100 }, auth), 400, 'invalid_currentBalances', '不是对象');
  fail(await a.patch(`/funds/${fund.id}`, { openingBalances: { CNY: 1.5 } }, auth), 400, 'invalid_openingBalances', '不是整数分');
});

test('账户校准：currentBalanceCents → 差额进初始余额；债务的内部账户只能到债务里改', async (t) => {
  const h = await setup(t);
  const { a, auth } = h;
  const card = ok(await a.post('/accounts', { name: '工资卡', kind: 'bank', initialBalanceCents: 50000 }, auth), 'POST 工资卡').account;
  await h.tx({ type: 'expense', amountCents: 12000, accountId: card.id });
  const fixed = ok(await a.patch(`/accounts/${card.id}`, { currentBalanceCents: 100000 }, auth), 'PATCH 校准').account;
  assert.equal(fixed.initialBalanceCents, 112000, '初始 = 目标 − 流水（−120.00）');
  const o = await h.overview();
  assert.equal(o.accounts.find((x) => x.accountId === card.id).balanceCents, 100000);

  const debt = ok(await a.post('/debts', { direction: 'lend', counterparty: '张三', amountCents: 5000 }, auth), 'POST 债务').debt;
  fail(await a.patch(`/accounts/${debt.accountId}`, { currentBalanceCents: 1 }, auth), 400, 'invalid_currentBalanceCents', '内部账户校准');
  fail(await a.patch(`/accounts/${debt.accountId}`, { initialBalanceCents: 1 }, auth), 400, 'invalid_initialBalanceCents', '内部账户改期初');
  fail(await a.patch(`/accounts/${debt.accountId}`, { kind: 'cash' }, auth), 400, 'invalid_kind', '内部账户改类型');
});

test('理财：更新金额能补记以前的日子；不能是将来；份额类没有金额日期', async (t) => {
  const h = await setup(t);
  const { a, auth } = h;
  const demand = ok(await a.post('/holdings', { kind: 'demand', name: '余额宝', costCents: 100000 }, auth), 'POST 活期').holding;
  const upd = ok(await a.patch(`/holdings/${demand.id}`, { valueCents: 100300, valueOn: '2026-01-31' }, auth), 'PATCH 补记').holding;
  assert.equal(upd.valueCents, 100300);
  assert.equal(upd.valueOn, '2026-01-31');
  const moved = ok(await a.patch(`/holdings/${demand.id}`, { valueOn: '2026-02-01' }, auth), 'PATCH 只改日期').holding;
  assert.equal(moved.valueOn, '2026-02-01');
  fail(await a.patch(`/holdings/${demand.id}`, { valueCents: 1, valueOn: '2999-01-01' }, auth), 400, 'invalid_valueOn', '将来');
  const fund = ok(await a.post('/holdings', { kind: 'fund', name: '指数', quantityE4: 10000, costCents: 100 }, auth), 'POST 基金').holding;
  fail(await a.patch(`/holdings/${fund.id}`, { valueOn: '2026-01-01' }, auth), 400, 'invalid_valueOn', '份额类没有金额日期');
  const closed = ok(await a.patch(`/holdings/${demand.id}`, { quantityE4: 0 }, auth), 'PATCH 标成已结清').holding;
  assert.equal(closed.quantityE4, 0);
  fail(await a.patch(`/holdings/${demand.id}`, { quantityE4: 5 }, auth), 400, 'invalid_quantityE4', '金额类只有持有 / 结清');
});

test('债务：改总额；校准还剩多少留一行「校准」；只记了数时能翻方向；备忘行改金额 / 删，期初和总额跟着改回来', async (t) => {
  const h = await setup(t);
  const { a, auth } = h;
  const remaining = async (d) => {
    const o = await h.overview();
    const bal = o.accounts.find((x) => x.accountId === d.accountId).balanceCents;
    return d.direction === 'lend' ? bal : -bal;
  };
  let d = ok(await a.post('/debts', { direction: 'lend', counterparty: '张三', amountCents: 500000, startedOn: '2026-01-01' }, auth), 'POST').debt;
  assert.equal(await remaining(d), 500000);
  assert.equal(d.memoLog.length, 1, '起始一行');

  // 起始那行记错了：5000 → 3000，总额和还剩一起变。
  d = ok(await a.patch(`/debts/${d.id}/memo/0`, { amountCents: 300000, note: '起始（改过）' }, auth), 'PATCH 起始备忘').debt;
  assert.equal(d.amountCents, 300000);
  assert.equal(d.memoLog[0].amountCents, 300000);
  assert.equal(d.memoLog[0].note, '起始（改过）');
  assert.equal(await remaining(d), 300000);

  // 收回一部分（不记流水）再删掉这行：还剩回到 3000，总额不变。
  d = ok(await a.post(`/debts/${d.id}/settle`, { amountCents: 100000, occurredOn: '2026-02-01' }, auth), '收回 1000').debt;
  assert.equal(await remaining(d), 200000);
  d = ok(await a.del(`/debts/${d.id}/memo/1`, auth), 'DELETE 收回那行').debt;
  assert.equal(d.memoLog.length, 1);
  assert.equal(d.amountCents, 300000, '收回不影响总额');
  assert.equal(await remaining(d), 300000);

  // 校准：其实还剩 1234.56。
  d = ok(await a.patch(`/debts/${d.id}`, { remainingCents: 123456 }, auth), 'PATCH 校准还剩').debt;
  assert.equal(await remaining(d), 123456);
  const memo = d.memoLog.at(-1);
  assert.equal(memo.action, 'calibrate');
  assert.equal(memo.amountCents, 123456 - 300000);
  assert.equal(memo.on, localDay());
  assert.equal(d.amountCents, 300000, '校准不动总额');
  // 只改总额。
  d = ok(await a.patch(`/debts/${d.id}`, { amountCents: 350000 }, auth), 'PATCH 总额').debt;
  assert.equal(d.amountCents, 350000);
  assert.equal(await remaining(d), 123456);

  // 只记了数：翻成借入，还剩多少不变（变成我欠别人），内部账户改名。
  d = ok(await a.patch(`/debts/${d.id}`, { direction: 'borrow' }, auth), 'PATCH 翻方向').debt;
  assert.equal(d.direction, 'borrow');
  assert.equal(await remaining(d), 123456);
  const o = await h.overview();
  assert.equal(o.accounts.find((x) => x.accountId === d.accountId).balanceCents, -123456, '负数 = 我欠别人');

  fail(await a.patch(`/debts/${d.id}/memo/9`, { amountCents: 1 }, auth), 404, 'not_found', '没有这行');
  fail(await a.patch(`/debts/${d.id}/memo/0`, { amountCents: -1 }, auth), 400, 'invalid_amountCents', '金额是正数，方向跟着原来那行');
  fail(await a.patch(`/debts/${d.id}`, { settledCents: 1 }, auth), 400, 'invalid_settledCents', 'PATCH 不收 settledCents');
});

test('汇率手填：自动抓取不覆盖；恢复自动删掉手填的再抓', async (t) => {
  const up = await startFakeFx();
  t.after(() => up.stop());
  up.state.rates = { whUSDCNY: '6.6940' };
  const h = await setup(t, { FX_BASE: up.base });
  const { a, auth } = h;

  // 1 CNY = 0.140845 USD（1 USD = 7.1 CNY）。
  const put = ok(await a.put('/fx/rates/USD', { rateE6: 140845 }, auth), 'PUT 手填').rates;
  assert.equal(put.USD, 140845);
  ok(await a.post('/fx/refresh', {}, auth), 'POST /fx/refresh');
  const after = ok(await a.get('/fx/rates', auth), 'GET /fx/rates');
  assert.equal(after.rates.USD, 140845, '手填的不被自动抓取覆盖');
  assert.deepEqual(after.manual, ['USD']);
  assert.deepEqual((await h.overview()).fx.manual, ['USD'], '总览也说哪些是手填的');

  const back = ok(await a.del('/fx/rates/USD', auth), 'DELETE 恢复自动');
  assert.equal(back.rates.USD, 149388, '重抓回来的是自动汇率');
  assert.deepEqual(back.manual, []);
  fail(await a.put('/fx/rates/CNY', { rateE6: 1 }, auth), 400, 'invalid_currency', '基准币对自己');
  fail(await a.put('/fx/rates/USD', { rateE6: 0 }, auth), 400, 'invalid_rateE6', '汇率要大于 0');
});
