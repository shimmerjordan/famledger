'use strict';

// 板块的「每月固定进账」（modules/fund_income.js）：每月到账日往指定账户记一笔真的工资收入。
// 钉死：真流水（账户、板块、净资产一起动）；补记起算月以来的月份、最多 24 个；生成过的月份永不重来
// （删掉也不补）；改额度只影响以后；规则校验；美元账户记美元。

const test = require('node:test');
const assert = require('node:assert/strict');

const { household } = require('./fixtures');
const { dueMonths, shiftMonth } = require('../src/modules/fund_income');

function ok(r, what) {
  assert.ok(r.status >= 200 && r.status < 300, `${what} → ${r.status} ${r.text}`);
  return r.json;
}

function fail(r, status, code, what) {
  assert.equal(r.status, status, `${what} → ${r.status} ${r.text}`);
  assert.equal(r.json.error.code, code, `${what} 的错误码`);
}

/** 服务端的本地日（Asia/Shanghai），和 v.localDay 一个口径。 */
function shanghaiToday() {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Shanghai', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
}

test('dueMonths：到账日到了才算这个月；起算月以前不算；最多往回 24 个月', () => {
  const f = (o) => ({ income_day: 15, income_start_month: '2026-08', ...o });
  assert.deepEqual(dueMonths(f({}), '2026-10-13'), ['2026-08', '2026-09'], '10 月 15 号还没到');
  assert.deepEqual(dueMonths(f({}), '2026-10-15'), ['2026-08', '2026-09', '2026-10'], '到账当天就记');
  assert.deepEqual(dueMonths(f({ income_start_month: '2026-11' }), '2026-10-20'), [], '起算月在将来');
  assert.equal(dueMonths(f({ income_start_month: '2020-01', income_day: 1 }), '2026-10-13').length, 24);
  assert.equal(dueMonths(f({ income_start_month: '2020-01', income_day: 1 }), '2026-10-13')[0], '2024-11');
  assert.equal(shiftMonth('2026-01', -1), '2025-12');
});

test('开了每月进账：从起算月补记到本月，真流水（账户、板块、净资产一起涨），类别「工资」，来源 recurring', async (t) => {
  const h = await household(t);
  const { a, auth } = h;
  const today = shanghaiToday();
  const start = shiftMonth(today.slice(0, 7), -2);

  fail(await a.post('/funds', { name: '工资', monthlyIncomeCents: 1000000 }, auth), 400, 'invalid_incomeAccountId', '没说进哪个账户');
  fail(await a.post('/funds', { name: '工资', monthlyIncomeCents: 1, incomeAccountId: h.account.id, incomeDay: 29 }, auth), 400, 'invalid_incomeDay', '29 号');
  const food = h.categories.find((c) => c.kind === 'expense');
  fail(
    await a.post('/funds', { name: '工资', monthlyIncomeCents: 1, incomeAccountId: h.account.id, incomeCategoryId: food.id }, auth),
    400, 'invalid_incomeCategoryId', '记成支出类别',
  );

  const fund = ok(await a.post('/funds', {
    name: '工资结余', kind: 'reserve', monthlyIncomeCents: 1000000, incomeDay: 1, incomeAccountId: h.account.id, incomeStartMonth: start,
  }, auth), 'POST 板块').fund;
  assert.equal(fund.incomeDay, 1);

  const txs = ok(await a.get('/transactions?limit=50', auth), 'GET /transactions').items.filter((x) => x.source === 'recurring');
  assert.equal(txs.length, 3, '起算月、上个月、本月（1 号已过）');
  for (const x of txs) {
    assert.equal(x.type, 'income');
    assert.equal(x.amountCents, 1000000);
    assert.equal(x.accountId, h.account.id);
    assert.equal(x.fundId, fund.id);
    assert.equal(x.note, '每月固定进账');
    assert.match(x.occurredAt, /-01T09:00:00/);
  }
  const cats = ok(await a.get('/categories', auth), 'GET /categories').items;
  assert.equal(cats.find((c) => c.id === txs[0].categoryId).name, '工资', '没有就建一个「工资」收入类别');

  const o = ok(await a.get('/stats/overview', auth), 'GET /stats/overview');
  assert.equal(o.funds.find((f) => f.fundId === fund.id).balanceCents, 3000000);
  assert.equal(o.accounts.find((x) => x.accountId === h.account.id).balanceCents, 3000000, '账户也真的进了钱');
  assert.equal(o.netWorthCents, 3000000);
});

test('幂等：再保存不重记；删掉某个月那笔不会被补回来；改额度只影响以后；清空 = 不再生成', async (t) => {
  const h = await household(t);
  const { a, auth } = h;
  const start = shiftMonth(shanghaiToday().slice(0, 7), -1);
  const fund = ok(await a.post('/funds', {
    name: '工资', monthlyIncomeCents: 500000, incomeDay: 1, incomeAccountId: h.account.id, incomeStartMonth: start,
  }, auth), 'POST').fund;
  const recurring = async () => ok(await a.get('/transactions?limit=50', auth), 'GET').items.filter((x) => x.source === 'recurring');
  assert.equal((await recurring()).length, 2);

  ok(await a.patch(`/funds/${fund.id}`, { description: '改个说明' }, auth), 'PATCH 说明');
  assert.equal((await recurring()).length, 2, '再保存不重记');

  const [first] = await recurring();
  ok(await a.del(`/transactions/${first.id}`, auth), 'DELETE 一笔');
  ok(await a.patch(`/funds/${fund.id}`, { monthlyIncomeCents: 800000 }, auth), 'PATCH 改额度');
  const left = await recurring();
  assert.equal(left.length, 1, '删掉的那个月不补回来');
  assert.equal(left[0].amountCents, 500000, '已经记的照旧，改额度只影响以后的月份');

  ok(await a.patch(`/funds/${fund.id}`, { monthlyIncomeCents: null, incomeStartMonth: shiftMonth(start, -5) }, auth), 'PATCH 清空');
  assert.equal((await recurring()).length, 1, '关掉之后不再生成，往前挪起算月也不补');
});

test('进美元账户：记的是美元，板块的美元余额涨；补记最多 24 个月；债务的内部账户不能当进账账户', async (t) => {
  const h = await household(t);
  const { a, auth } = h;
  const usd = ok(await a.post('/accounts', { name: '美元户', kind: 'bank', currency: 'USD' }, auth), 'POST 美元户').account;
  const fund = ok(await a.post('/funds', {
    name: '美元工资', monthlyIncomeCents: 300000, incomeDay: 1, incomeAccountId: usd.id, incomeStartMonth: '2020-01',
  }, auth), 'POST').fund;
  const txs = ok(await a.get('/transactions?limit=100', auth), 'GET').items.filter((x) => x.fundId === fund.id);
  assert.equal(txs.length, 24, '最多往回补 24 个月');
  assert.ok(txs.every((x) => x.currency === 'USD'));
  const o = ok(await a.get('/stats/overview', auth), 'GET /stats/overview');
  assert.deepEqual(o.funds.find((f) => f.fundId === fund.id).balances, { USD: 300000 * 24 });

  const debt = ok(await a.post('/debts', { direction: 'lend', counterparty: '张三', amountCents: 100 }, auth), 'POST 债务').debt;
  fail(
    await a.post('/funds', { name: 'x', monthlyIncomeCents: 1, incomeAccountId: debt.accountId }, auth),
    400, 'invalid_incomeAccountId', '债务的内部账户',
  );
});
