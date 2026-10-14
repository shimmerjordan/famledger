'use strict';

// 统计。这个套件钉死的是**口径**，不是接口形状：
//
//   · 余额 = 初始额 + Σ确认流水（pending 不算、软删不算、转账两头都要算）
//   · 信用卡为负 → 进 liabilities，不进 assets
//   · 月份 = occurred_at 的 YYYY-MM 前缀，上月的流水进余额但不进本月聚合
//   · 趋势缺月补 0，基金明细区分「本月」与「全部」
//
// 所有数字都是手算好的常量：口径一变就红。

const test = require('node:test');
const assert = require('node:assert/strict');

const { household } = require('./fixtures');
const { startFakeFx } = require('./fx_upstream');

const MONTH = '2026-09';
const PREV = '2026-08';

/** 服务端按本地时区算「当前月」；测试用同一套算法，跨月不会红。 */
function currentMonth() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;
}

function ok(r, what) {
  assert.ok(r.status >= 200 && r.status < 300, `${what} → ${r.status} ${r.text}`);
  return r.json;
}

/**
 * brief 里的那个场景：2 账户（现金初始 1000.00、信用卡 0）、2 基金、3 类别、
 * 2 成员，以及 12 笔流水（含 pending、软删、duplicate、void、拨款、跨账户转账、
 * 收入、上月支出）—— duplicate 与 void 那两笔是**加固**：它们在库里、在流水列表里，
 * 但下面每一个数字都当它们不存在，谁把它们算进聚合谁就红。
 *
 * 手算出来的口径（下面每个用例都用这些数字）：
 *
 *   现金  = 100000 − 2500(T1) + 900000(T4) − 2000(T6 转出) − 6000(T9) = 989500
 *   信用卡 =      0 − 1200(T2) −   3000(T3) + 2000(T6 转入)           =  −2200
 *   基金A = −2500 − 1200 + 900000 − 50000(T5 拨出) − 6000            = 840300
 *   基金B = −3000 + 50000(T5 拨入)                                   =  47000
 *   本月支出 = 2500 + 1200 + 3000 = 6700；本月收入 = 900000
 */
async function seedLedger(h) {
  const { a, auth, funds, accounts, categories } = h;

  // ── 主数据 ──────────────────────────────────────────────────────────────
  const cash = ok(
    await a.patch(`/accounts/${accounts[0].id}`, { initialBalanceCents: 100000 }, auth),
    'PATCH 现金',
  ).account;
  const credit = ok(
    await a.post('/accounts', { name: '信用卡', kind: 'credit', initialBalanceCents: 0 }, auth),
    'POST 信用卡',
  ).account;

  const fundA = funds[0]; // 种子基金：家庭公共基金
  const fundB = ok(
    await a.post('/funds', { name: '宠物基金', kind: 'goal', targetCents: 1000000, monthlyBudgetCents: 20000 }, auth),
    'POST 宠物基金',
  ).fund;

  const cat = (name, kind) => {
    const c = categories.find((x) => x.name === name && x.kind === kind);
    assert.ok(c, `种子类别里没有 ${kind}/${name}`);
    return c;
  };
  const food = cat('餐饮', 'expense');
  const bus = cat('交通', 'expense');
  const salary = cat('工资', 'income');

  const m2 = ok(
    await a.post('/members', { username: 'xiaohong', password: 'hunter22', displayName: '小红', role: 'member' }, auth),
    'POST /members',
  ).member;

  // ── 流水 ────────────────────────────────────────────────────────────────
  const mk = async (body) => ok(await a.post('/transactions', body, auth), `POST ${body.note}`).transaction;

  const t1 = await mk({ note: 'T1 本月餐饮', type: 'expense', amountCents: 2500, occurredAt: '2026-09-03T10:00:00+08:00', fundId: fundA.id, accountId: cash.id, categoryId: food.id });
  const t2 = await mk({ note: 'T2 本月交通', type: 'expense', amountCents: 1200, occurredAt: '2026-09-03T13:00:00+08:00', fundId: fundA.id, accountId: credit.id, categoryId: bus.id });
  const t3 = await mk({ note: 'T3 小红的餐饮', type: 'expense', amountCents: 3000, occurredAt: '2026-09-10T12:00:00+08:00', fundId: fundB.id, accountId: credit.id, categoryId: food.id, memberId: m2.id });
  const t4 = await mk({ note: 'T4 工资', type: 'income', amountCents: 900000, occurredAt: '2026-09-05T09:00:00+08:00', fundId: fundA.id, accountId: cash.id, categoryId: salary.id });
  const t5 = await mk({ note: 'T5 拨款 A→B', type: 'transfer', amountCents: 50000, occurredAt: '2026-09-06T09:00:00+08:00', fundId: fundA.id, toFundId: fundB.id });
  const t6 = await mk({ note: 'T6 还信用卡', type: 'transfer', amountCents: 2000, occurredAt: '2026-09-07T09:00:00+08:00', accountId: cash.id, toAccountId: credit.id });
  const t7 = await mk({ note: 'T7 待确认', type: 'expense', amountCents: 999, occurredAt: '2026-09-08T09:00:00+08:00', fundId: fundA.id, accountId: cash.id, categoryId: food.id, status: 'pending' });
  const t8 = await mk({ note: 'T8 待软删', type: 'expense', amountCents: 777, occurredAt: '2026-09-09T09:00:00+08:00', fundId: fundA.id, accountId: cash.id, categoryId: bus.id });
  const t9 = await mk({ note: 'T9 上月餐饮', type: 'expense', amountCents: 6000, occurredAt: '2026-08-20T10:00:00+08:00', fundId: fundA.id, accountId: cash.id, categoryId: food.id });
  const t10 = await mk({ note: 'T10 上月待确认', type: 'expense', amountCents: 111, occurredAt: '2026-08-21T10:00:00+08:00', fundId: fundA.id, accountId: cash.id, categoryId: food.id, status: 'pending' });

  ok(await a.del(`/transactions/${t8.id}`, auth), 'DELETE T8');

  // T11：三分钟内又来一条同金额的「通知」→ 服务端判成 duplicate。
  // T12：先记一笔再作废 → void。两者都**不该**进任何余额/聚合，但都还在流水列表里
  // （用户得看得见才能处理），所以下面每个用例的数字都不会因为它们变。
  const t11 = await mk({
    note: 'T11 通知重复', type: 'expense', amountCents: 2500, occurredAt: '2026-09-03T10:01:00+08:00',
    fundId: fundA.id, accountId: cash.id, categoryId: food.id, source: 'notification',
  });
  assert.equal(t11.status, 'duplicate', '造不出 duplicate 的话这条加固就是空的');
  assert.equal(t11.duplicateOfId, t1.id);

  const t12 = await mk({
    note: 'T12 待作废', type: 'expense', amountCents: 8888, occurredAt: '2026-09-04T09:00:00+08:00',
    fundId: fundA.id, accountId: cash.id, categoryId: bus.id,
  });
  ok(await a.post(`/transactions/${t12.id}/void`, {}, auth), 'VOID T12');
  assert.equal(
    ok(await a.get(`/transactions/${t12.id}`, auth), 'GET T12').transaction.status, 'void',
  );

  // ── 预算 ────────────────────────────────────────────────────────────────
  // 「本月专属压过每月默认」跟行的先后无关：下面两组**故意按相反的顺序写入**，
  // 谁要是把解析写成「取第一条」或「取最后一条」，必定有一组会露馅。
  ok(await h.put('/budgets', { scope: 'fund', refId: fundA.id, month: '*', amountCents: 500000 }), 'PUT 预算 A/*');
  ok(await h.put('/budgets', { scope: 'fund', refId: fundA.id, month: MONTH, amountCents: 400000 }), 'PUT 预算 A/本月');
  ok(await h.put('/budgets', { scope: 'category', refId: bus.id, month: MONTH, amountCents: 30000 }), 'PUT 预算 交通/本月');
  ok(await h.put('/budgets', { scope: 'category', refId: bus.id, month: '*', amountCents: 90000 }), 'PUT 预算 交通/*');
  // 只有每月默认的一组。基金 B 没有预算行，靠 funds.monthlyBudgetCents 兜底。
  ok(await h.put('/budgets', { scope: 'category', refId: food.id, month: '*', amountCents: 80000 }), 'PUT 预算 餐饮/*');

  return { cash, credit, fundA, fundB, food, bus, salary, m2, t1, t2, t3, t4, t5, t6, t7, t8, t9, t10, t11, t12 };
}

const getStats = async (h, p) => {
  const r = await h.a.get(p, h.auth);
  assert.equal(r.status, 200, `GET ${p} → ${r.status} ${r.text}`);
  return r.json;
};

test('overview：净资产/资产/负债与账户、基金余额（pending 与软删不进余额）', async (t) => {
  const h = await household(t);
  const s = await seedLedger(h);

  const o = await getStats(h, `/stats/overview?month=${MONTH}`);

  assert.equal(o.assetsCents, 989500, '资产 = 所有正余额之和');
  assert.equal(o.liabilitiesCents, 2200, '负债 = 信用卡欠的 22.00');
  assert.equal(o.netWorthCents, 987300, '净资产 = 资产 − 负债');

  const acct = Object.fromEntries(o.accounts.map((x) => [x.accountId, x.balanceCents]));
  assert.deepEqual(acct, { [s.cash.id]: 989500, [s.credit.id]: -2200 });

  const fund = Object.fromEntries(o.funds.map((x) => [x.fundId, x.balanceCents]));
  assert.deepEqual(fund, { [s.fundA.id]: 840300, [s.fundB.id]: 47000 });

  assert.equal(o.pendingCount, 2, '待确认是全局计数，不限本月');

  // 归档 ≠ 删除：钱还在里面，余额照给（要不要显示是客户端的事）。
  ok(await h.a.patch(`/accounts/${s.credit.id}`, { archived: true }, h.auth), '归档信用卡');
  ok(await h.a.patch(`/funds/${s.fundB.id}`, { archived: true }, h.auth), '归档宠物基金');
  const after = await getStats(h, `/stats/overview?month=${MONTH}`);
  assert.deepEqual(after.accounts, o.accounts, '归档的账户仍在余额表里');
  assert.deepEqual(after.funds, o.funds, '归档的基金仍在余额表里');
});

test('overview：空账本不炸也不出 null，全是 0', async (t) => {
  const h = await household(t);
  const o = await getStats(h, `/stats/overview?month=${MONTH}`);

  assert.deepEqual(o.month, {
    expenseCents: 0, incomeCents: 0, byFund: [], byCategory: [], byMember: [], budgets: [],
  });
  assert.equal(o.netWorthCents, 0);
  assert.equal(o.assetsCents, 0);
  assert.equal(o.liabilitiesCents, 0);
  assert.equal(o.pendingCount, 0);
  assert.deepEqual(o.funds, [{ fundId: h.fund.id, balanceCents: 0, balances: {} }], '没流水的板块余额是 0 不是 null');
  assert.deepEqual(o.accounts, [{ accountId: h.account.id, currency: 'CNY', balanceCents: 0 }]);
  assert.deepEqual((await getStats(h, `/stats/calendar?month=${MONTH}`)).days, []);
  assert.deepEqual((await getStats(h, `/stats/trend?months=2&endMonth=${MONTH}`)).series, [
    { month: PREV, expenseCents: 0, incomeCents: 0 },
    { month: MONTH, expenseCents: 0, incomeCents: 0 },
  ]);
});

// ---------------------------------------------------------------- 多币种折算（需求4c）

test('overview 多币种：非基准币余额按汇率折进净资产，缺汇率按 0 计并记入 fx.missing', async (t) => {
  const up = await startFakeFx();
  t.after(() => up.stop());
  up.state.rates = { whUSDCNY: '6.6940' }; // 1 USD = 6.694 CNY → 库里存 1 CNY = 149388e-6 USD

  const h = await household(t, { FX_BASE: up.base });
  const { a, auth } = h;

  const usd = ok(await a.post('/accounts', { name: '美元户', kind: 'bank', currency: 'USD', initialBalanceCents: 10000 }, auth), 'POST 美元户').account;
  const eur = ok(await a.post('/accounts', { name: '欧元户', kind: 'bank', currency: 'EUR', initialBalanceCents: 5000 }, auth), 'POST 欧元户').account;

  // 建完账户再刷新：neededCurrencies 才会把 EUR 也带上（上游没有 EUR → 抓不到）。
  ok(await a.post('/fx/refresh', {}, auth), 'POST /fx/refresh');

  const o = await getStats(h, `/stats/overview?month=${MONTH}`);

  // $100.00 折成 ¥669.40；€50.00 抓不到汇率 → 按 0 计入（绝不臆造），原生币余额照给。
  assert.equal(o.assetsCents, 66940, 'USD 折算入账，EUR 缺汇率按 0');
  assert.equal(o.netWorthCents, 66940);
  const byId = Object.fromEntries(o.accounts.map((x) => [x.accountId, x]));
  assert.deepEqual(byId[usd.id], { accountId: usd.id, currency: 'USD', balanceCents: 10000 }, '每实体仍以原生币返回');
  assert.deepEqual(byId[eur.id], { accountId: eur.id, currency: 'EUR', balanceCents: 5000 }, '缺汇率也要给出原生币余额');

  assert.equal(o.fx.base, 'CNY');
  assert.equal(o.fx.rates.USD, 149388);
  assert.ok(o.fx.asOf, '带上汇率时间');
  assert.deepEqual(o.fx.missing, ['EUR'], '抓不到汇率的币种记进 missing，客户端据此标「汇率缺失」');

  // 按币种分开的原生分项：客户端按币种分行显示合计。全是 0 的人民币不占一行。
  assert.deepEqual(Object.keys(o.byCurrency), ['EUR', 'USD']);
  assert.equal(o.byCurrency.USD.netWorthCents, 10000);
  assert.equal(o.byCurrency.USD.cashCents, 10000);
  assert.equal(o.byCurrency.EUR.netWorthCents, 5000, '缺汇率的币种照样有自己的原生合计');
});

test('多币种月度聚合：每笔流水按自己的币种折到基准币再合并（byCategory/byFund/calendar/trend）', async (t) => {
  const up = await startFakeFx();
  t.after(() => up.stop());
  up.state.rates = { whUSDCNY: '6.6940' };

  const h = await household(t, { FX_BASE: up.base });
  const { a, auth } = h;

  const usdAcct = ok(await a.post('/accounts', { name: '美元户', kind: 'bank', currency: 'USD', initialBalanceCents: 0 }, auth), 'POST 美元户').account;
  const usdFund = ok(await a.post('/funds', { name: '美元模块', kind: 'custom', currency: 'USD' }, auth), 'POST 美元模块').fund;
  ok(await a.post('/fx/refresh', {}, auth), 'POST /fx/refresh');

  const food = h.categories.find((c) => c.name === '餐饮' && c.kind === 'expense');
  assert.ok(food, '种子类别里要有餐饮/expense');

  // 同一天两笔餐饮：¥25.00（CNY）+ $10.00（USD，折 ¥66.94）。金额不同、相隔两小时，不会被判重。
  ok(await a.post('/transactions', { type: 'expense', amountCents: 2500, currency: 'CNY', occurredAt: '2026-09-03T10:00:00+08:00', fundId: h.fund.id, accountId: h.account.id, categoryId: food.id, note: 'CNY 餐饮' }, auth), 'POST CNY 餐饮');
  ok(await a.post('/transactions', { type: 'expense', amountCents: 1000, currency: 'USD', occurredAt: '2026-09-03T12:00:00+08:00', fundId: usdFund.id, accountId: usdAcct.id, categoryId: food.id, note: 'USD 餐饮' }, auth), 'POST USD 餐饮');

  const o = await getStats(h, `/stats/overview?month=${MONTH}`);
  assert.equal(o.month.expenseCents, 2500 + 6694, 'CNY 原样 + USD 折算');
  assert.deepEqual(o.month.byCategory, [{ categoryId: food.id, expenseCents: 9194 }], '同类别跨币种折算后合并成一组');
  assert.deepEqual(o.month.byFund, [
    { fundId: usdFund.id, expenseCents: 6694, incomeCents: 0 },
    { fundId: h.fund.id, expenseCents: 2500, incomeCents: 0 },
  ], 'byFund 也按币种折算后排序（支出多的在前）');
  assert.deepEqual(o.fx.missing, []);

  const cal = await getStats(h, `/stats/calendar?month=${MONTH}`);
  assert.deepEqual(cal.days, [{ date: '2026-09-03', expenseCents: 9194, incomeCents: 0, count: 2 }], '同一天跨币种折算相加，笔数照计');

  const trend = await getStats(h, `/stats/trend?months=1&endMonth=${MONTH}`);
  assert.deepEqual(trend.series, [{ month: MONTH, expenseCents: 9194, incomeCents: 0 }]);
});
