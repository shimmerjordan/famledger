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
  assert.deepEqual(o.funds, [{ fundId: h.fund.id, balanceCents: 0 }], '没流水的基金余额是 0 不是 null');
  assert.deepEqual(o.accounts, [{ accountId: h.account.id, balanceCents: 0 }]);
  assert.deepEqual((await getStats(h, `/stats/calendar?month=${MONTH}`)).days, []);
  assert.deepEqual((await getStats(h, `/stats/trend?months=2&endMonth=${MONTH}`)).series, [
    { month: PREV, expenseCents: 0, incomeCents: 0 },
    { month: MONTH, expenseCents: 0, incomeCents: 0 },
  ]);
});

test('overview：本月聚合 byFund / byCategory / byMember / budgets', async (t) => {
  const h = await household(t);
  const s = await seedLedger(h);

  const o = await getStats(h, `/stats/overview?month=${MONTH}`);

  assert.equal(o.month.expenseCents, 6700, '本月支出不含上月、不含 pending、不含软删');
  assert.equal(o.month.incomeCents, 900000);

  assert.deepEqual(o.month.byFund, [
    { fundId: s.fundA.id, expenseCents: 3700, incomeCents: 900000 },
    { fundId: s.fundB.id, expenseCents: 3000, incomeCents: 0 },
  ]);

  assert.deepEqual(o.month.byCategory, [
    { categoryId: s.food.id, expenseCents: 5500 },
    { categoryId: s.bus.id, expenseCents: 1200 },
  ], 'byCategory 只统计支出，按金额倒序');

  assert.deepEqual(o.month.byMember, [
    { memberId: h.member.id, expenseCents: 3700 },
    { memberId: s.m2.id, expenseCents: 3000 },
  ]);

  const budgets = Object.fromEntries(o.month.budgets.map((b) => [`${b.scope}/${b.refId}`, b]));
  assert.deepEqual(budgets[`fund/${s.fundA.id}`], {
    scope: 'fund', refId: s.fundA.id, budgetCents: 400000, spentCents: 3700,
  }, '本月专属预算压过每月默认的 500000');
  assert.deepEqual(budgets[`fund/${s.fundB.id}`], {
    scope: 'fund', refId: s.fundB.id, budgetCents: 20000, spentCents: 3000,
  }, '没有预算行的基金用 monthlyBudgetCents 兜底');
  assert.deepEqual(budgets[`category/${s.food.id}`], {
    scope: 'category', refId: s.food.id, budgetCents: 80000, spentCents: 5500,
  }, '类别预算的已花 = 本月该类别全部支出（跨基金）');
  assert.deepEqual(budgets[`category/${s.bus.id}`], {
    scope: 'category', refId: s.bus.id, budgetCents: 30000, spentCents: 1200,
  }, '这一组是先写本月、后写每月默认的，结果必须一样');
  assert.equal(o.month.budgets.length, 4);

  // 不传 month 时就是「当前月」。
  const dflt = await getStats(h, '/stats/overview');
  assert.deepEqual(dflt, await getStats(h, `/stats/overview?month=${currentMonth()}`));
});

test('overview：没填类别的支出汇成 categoryId: null 一组，环形图才对得上总数', async (t) => {
  const h = await household(t);
  ok(await h.a.post('/transactions', {
    type: 'expense', amountCents: 4200, occurredAt: '2026-09-02T10:00:00+08:00', fundId: h.fund.id, note: '忘了选类别',
  }, h.auth), 'POST 无类别支出');

  const o = await getStats(h, `/stats/overview?month=${MONTH}`);
  assert.deepEqual(o.month.byCategory, [{ categoryId: null, expenseCents: 4200 }]);
  assert.equal(o.month.expenseCents, 4200, 'byCategory 之和 = 本月支出');
});

test('月份/日期按「带偏移的本地时间」的字符串前缀算，不是按 UTC', async (t) => {
  const h = await household(t);
  const mk = (occurredAt, amountCents) => h.a.post('/transactions', {
    type: 'expense', amountCents, occurredAt, fundId: h.fund.id, accountId: h.account.id, categoryId: h.category.id,
  }, h.auth);

  // 北京时间 9/1 01:00 == UTC 8/31 17:00。用户心里这是 9 月的第一笔，统计就得这么算。
  ok(await mk('2026-09-01T01:00:00+08:00', 700), '9/1 凌晨那笔');
  // 北京时间 8/31 23:30 == UTC 8/31 15:30，两边都还在 8 月。
  ok(await mk('2026-08-31T23:30:00+08:00', 300), '8/31 深夜那笔');

  assert.equal((await getStats(h, `/stats/overview?month=${MONTH}`)).month.expenseCents, 700,
    '按 UTC 分月的话这里会变成 0');
  assert.equal((await getStats(h, `/stats/overview?month=${PREV}`)).month.expenseCents, 300,
    '按 UTC 分月的话这里会变成 1000');

  assert.deepEqual((await getStats(h, `/stats/calendar?month=${MONTH}`)).days, [
    { date: '2026-09-01', expenseCents: 700, incomeCents: 0, count: 1 },
  ], '日历也按本地日期落格');
  assert.deepEqual((await getStats(h, `/stats/trend?months=2&endMonth=${MONTH}`)).series, [
    { month: PREV, expenseCents: 300, incomeCents: 0 },
    { month: MONTH, expenseCents: 700, incomeCents: 0 },
  ]);

  // 不带偏移量的时间串根本写不进来，所以前缀拿到的一定是某地确定的本地日期。
  const naive = await h.a.post('/transactions', {
    type: 'expense', amountCents: 100, occurredAt: '2026-09-01T01:00:00', fundId: h.fund.id,
  }, h.auth);
  assert.equal(naive.status, 400, naive.text);
  assert.equal(naive.json.error.code, 'invalid_occurredAt');
});

test('trend：12 个月、缺月补 0、位置正确，可按基金/类别过滤，months 夹到 1~60', async (t) => {
  const h = await household(t);
  const s = await seedLedger(h);

  const { series } = await getStats(h, `/stats/trend?months=12&endMonth=${MONTH}`);
  assert.equal(series.length, 12);
  assert.equal(series[0].month, '2025-10', '最老的在前');
  assert.equal(series[11].month, MONTH, '最新的在后，就是 endMonth');
  assert.deepEqual(series[11], { month: MONTH, expenseCents: 6700, incomeCents: 900000 });
  assert.deepEqual(series[10], { month: PREV, expenseCents: 6000, incomeCents: 0 }, '上月的 pending 不计入');
  for (const row of series.slice(0, 10)) {
    assert.deepEqual(row, { month: row.month, expenseCents: 0, incomeCents: 0 }, `${row.month} 应当补 0`);
  }

  const byFund = await getStats(h, `/stats/trend?months=3&endMonth=${MONTH}&fundId=${s.fundB.id}`);
  assert.deepEqual(byFund.series, [
    { month: '2026-07', expenseCents: 0, incomeCents: 0 },
    { month: PREV, expenseCents: 0, incomeCents: 0 },
    { month: MONTH, expenseCents: 3000, incomeCents: 0 },
  ]);

  const byCat = await getStats(h, `/stats/trend?months=2&endMonth=${MONTH}&categoryId=${s.food.id}`);
  assert.deepEqual(byCat.series, [
    { month: PREV, expenseCents: 6000, incomeCents: 0 },
    { month: MONTH, expenseCents: 5500, incomeCents: 0 },
  ]);

  assert.equal((await getStats(h, `/stats/trend?months=0&endMonth=${MONTH}`)).series.length, 1, 'months 下限 1');
  assert.equal((await getStats(h, `/stats/trend?months=999&endMonth=${MONTH}`)).series.length, 60, 'months 上限 60');

  const dflt = await getStats(h, '/stats/trend');
  assert.equal(dflt.series.length, 12, '默认 12 个月');
  assert.equal(dflt.series[11].month, currentMonth(), '默认以当前月收尾');

  const bad = await h.a.get('/stats/trend?months=abc', h.auth);
  assert.equal(bad.status, 400);
  assert.equal(bad.json.error.code, 'invalid_months');
});

test('stats/fund/:id：余额、目标、预算、本月类别构成与最近流水', async (t) => {
  const h = await household(t);
  const s = await seedLedger(h);

  const b = await getStats(h, `/stats/fund/${s.fundB.id}?month=${MONTH}`);
  assert.equal(b.fundId, s.fundB.id);
  assert.equal(b.balanceCents, 47000, '拨进来的 500.00 算这个基金的');
  assert.equal(b.targetCents, 1000000);
  assert.equal(b.monthlyBudgetCents, 20000);
  assert.equal(b.budgetCents, 20000, '没有预算行时回落到基金自己的月预算');
  assert.equal(b.monthExpenseCents, 3000);
  assert.equal(b.monthIncomeCents, 0);
  assert.deepEqual(b.byCategory, [{ categoryId: s.food.id, expenseCents: 3000 }]);
  assert.deepEqual(b.recent.map((x) => x.id), [s.t3.id, s.t5.id], '转入的那笔拨款也是这个基金的流水');
  assert.equal(b.recent[0].amountCents, 3000, 'recent 就是 GET /transactions 的那个形状');
  assert.deepEqual(b.recent[0].tags, []);
  assert.equal(b.recent[0].note, 'T3 小红的餐饮');

  const a = await getStats(h, `/stats/fund/${s.fundA.id}?month=${MONTH}`);
  assert.equal(a.balanceCents, 840300);
  assert.equal(a.targetCents, null);
  assert.equal(a.monthlyBudgetCents, null);
  assert.equal(a.budgetCents, 400000, '本月专属预算行胜出');
  assert.equal(a.monthExpenseCents, 3700);
  assert.equal(a.monthIncomeCents, 900000);
  assert.deepEqual(a.byCategory, [
    { categoryId: s.food.id, expenseCents: 2500 },
    { categoryId: s.bus.id, expenseCents: 1200 },
  ], '只算这个基金的，小红那 3000 餐饮在基金 B');

  assert.deepEqual(
    a.recent.map((x) => x.id),
    [s.t7.id, s.t5.id, s.t4.id, s.t12.id, s.t2.id, s.t11.id, s.t1.id, s.t10.id, s.t9.id],
    'recent 按发生时间倒序、不限本月、含 pending/duplicate/void、不含软删',
  );
  assert.ok(!a.recent.some((x) => x.id === s.t8.id), '软删的不在 recent 里');
});

test('stats/fund/:id：不存在或已删除的基金 → 404 not_found', async (t) => {
  const h = await household(t);
  await seedLedger(h);

  const miss = await h.a.get('/stats/fund/nope', h.auth);
  assert.equal(miss.status, 404, miss.text);
  assert.equal(miss.json.error.code, 'not_found');

  const doomed = ok(await h.a.post('/funds', { name: '临时基金', kind: 'custom' }, h.auth), 'POST 临时基金').fund;
  assert.equal((await h.a.get(`/stats/fund/${doomed.id}`, h.auth)).status, 200);
  ok(await h.a.del(`/funds/${doomed.id}`, h.auth), 'DELETE 临时基金');
  assert.equal((await h.a.get(`/stats/fund/${doomed.id}`, h.auth)).status, 404, '软删之后就不存在了');
});

test('stats/calendar：只给有流水的那几天，按天聚合并计数', async (t) => {
  const h = await household(t);
  await seedLedger(h);

  const { days } = await getStats(h, `/stats/calendar?month=${MONTH}`);
  assert.deepEqual(days, [
    { date: '2026-09-03', expenseCents: 3700, incomeCents: 0, count: 2 },
    { date: '2026-09-05', expenseCents: 0, incomeCents: 900000, count: 1 },
    { date: '2026-09-06', expenseCents: 0, incomeCents: 0, count: 1 },
    { date: '2026-09-07', expenseCents: 0, incomeCents: 0, count: 1 },
    { date: '2026-09-10', expenseCents: 3000, incomeCents: 0, count: 1 },
  ], '09-08（pending）与 09-09（软删）不出现');

  const prev = await getStats(h, `/stats/calendar?month=${PREV}`);
  assert.deepEqual(prev.days, [{ date: '2026-08-20', expenseCents: 6000, incomeCents: 0, count: 1 }]);

  const empty = await getStats(h, '/stats/calendar?month=2020-01');
  assert.deepEqual(empty.days, []);
});

test('month 格式非法 → 400 invalid_month；统计接口都要登录', async (t) => {
  const h = await household(t);

  for (const p of ['/stats/overview?month=2026-9', '/stats/calendar?month=九月', `/stats/fund/${h.fund.id}?month=2026-13`]) {
    const r = await h.a.get(p, h.auth);
    assert.equal(r.status, 400, `${p} → ${r.status} ${r.text}`);
    assert.equal(r.json.error.code, 'invalid_month', p);
  }
  const badEnd = await h.a.get('/stats/trend?endMonth=2026-9', h.auth);
  assert.equal(badEnd.status, 400);
  assert.equal(badEnd.json.error.code, 'invalid_endMonth');

  for (const p of ['/stats/overview', '/stats/trend', '/stats/calendar', `/stats/fund/${h.fund.id}`]) {
    const r = await h.a.get(p);
    assert.equal(r.status, 401, `${p} 无 token 应当 401，实际 ${r.status}`);
  }
});


test('duplicate / void 的流水对余额、月聚合、日历、pendingCount 全都隐形', async (t) => {
  const h = await household(t);
  const s = await seedLedger(h);

  // 基线：库里已经有 T11(duplicate) 与 T12(void) 了，下面再加一对，数字必须纹丝不动。
  const before = await getStats(h, `/stats/overview?month=${MONTH}`);
  const beforeCal = await getStats(h, `/stats/calendar?month=${MONTH}`);
  const beforeAug = await getStats(h, `/stats/overview?month=${PREV}`);

  // 又一条三分钟内的同额通知 → duplicate（这次挂在基金 B 的 T3 上）。
  const dup = ok(await h.a.post('/transactions', {
    note: 'T13 又一条重复', type: 'expense', amountCents: 3000, occurredAt: '2026-09-10T12:02:00+08:00',
    fundId: s.fundB.id, accountId: s.credit.id, categoryId: s.food.id, source: 'notification',
  }, h.auth), 'POST T13').transaction;
  assert.equal(dup.status, 'duplicate');
  assert.equal(dup.duplicateOfId, s.t3.id);

  // 再记一笔巨款然后作废 —— 作废之后它对账本没有任何影响。
  const doomed = ok(await h.a.post('/transactions', {
    note: 'T14 记错了', type: 'income', amountCents: 12345600, occurredAt: '2026-09-11T09:00:00+08:00',
    fundId: s.fundB.id, accountId: s.cash.id, categoryId: s.salary.id,
  }, h.auth), 'POST T14').transaction;
  ok(await h.a.post(`/transactions/${doomed.id}/void`, {}, h.auth), 'VOID T14');

  assert.deepEqual(await getStats(h, `/stats/overview?month=${MONTH}`), before,
    'duplicate/void 进来之后 overview 必须逐字节不变（余额、月聚合、预算已花、pendingCount）');
  assert.deepEqual(await getStats(h, `/stats/calendar?month=${MONTH}`), beforeCal,
    '09-10 的笔数不能因为 duplicate +1，09-11 更不该冒出来');
  assert.deepEqual(await getStats(h, `/stats/overview?month=${PREV}`), beforeAug);
  assert.equal(before.pendingCount, 2, 'duplicate/void 都不是 pending');

  // 但它们确实在库里，流水列表看得见 —— 否则上面的「不变」是因为根本没写进去。
  const all = ok(await h.a.get('/transactions?limit=200', h.auth), 'GET /transactions').items;
  const byId = Object.fromEntries(all.map((x) => [x.id, x.status]));
  assert.equal(byId[dup.id], 'duplicate');
  assert.equal(byId[doomed.id], 'void');
  assert.equal(byId[s.t11.id], 'duplicate');
  assert.equal(byId[s.t12.id], 'void');
});

test('预算口径与 budgets 模块一致：GET /budgets?month= 的金额 == overview 里的 budgetCents', async (t) => {
  const h = await household(t);
  const s = await seedLedger(h);

  const rows = ok(await h.a.get(`/budgets?month=${MONTH}`, h.auth), 'GET /budgets').items;
  const o = await getStats(h, `/stats/overview?month=${MONTH}`);
  const mine = new Map(o.month.budgets.map((b) => [`${b.scope}/${b.refId}`, b.budgetCents]));

  assert.ok(rows.length > 0, '这个场景里本来就有三条生效预算');
  for (const r of rows) {
    const key = `${r.scope}/${r.refId}`;
    assert.ok(mine.has(key), `overview 里少了 ${key}`);
    assert.equal(mine.get(key), r.amountCents,
      `${key}：budgets 模块说 ${r.amountCents}，stats 说 ${mine.get(key)} —— 两边的「本月生效值」必须是同一套解析`);
    mine.delete(key);
  }
  // stats 比 budgets 多出来的，只允许是「基金自己填了 monthlyBudgetCents、但没有预算行」的那种。
  assert.deepEqual([...mine.keys()], [`fund/${s.fundB.id}`]);
  assert.equal(o.month.budgets.find((b) => b.refId === s.fundB.id).budgetCents, 20000);
});

test('fundStats.recent 与 GET /transactions?fundId= 逐字段一致（同一个形状、同一套过滤）', async (t) => {
  const h = await household(t);
  const s = await seedLedger(h);

  for (const [name, fundId] of [['基金 B（含转入的拨款）', s.fundB.id], ['基金 A（含 pending/duplicate/void）', s.fundA.id]]) {
    const fromStats = (await getStats(h, `/stats/fund/${fundId}?month=${MONTH}`)).recent;
    const fromList = ok(await h.a.get(`/transactions?fundId=${fundId}&limit=10`, h.auth), 'GET /transactions').items;
    assert.deepEqual(fromStats, fromList,
      `${name}：recent 必须就是 GET /transactions 的那一页（Task 2 的过滤也匹配 to_fund_id）`);
  }
});

// ---------------------------------------------------------------- 实物估值（P1）

const pad2 = (n) => String(n).padStart(2, '0');
/** 本地今天；helpers.js 已把本进程钉在 Asia/Shanghai，和子进程一致。 */
function localToday() {
  const d = new Date();
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}

test('overview.physical：估值合计与计入额；全局开关开和关净资产不同；卖出后估值归零、不重复计', async (t) => {
  const h = await household(t);
  const { a, auth, account } = h;
  const today = localToday();

  const empty = await getStats(h, `/stats/overview?month=${MONTH}`);
  assert.deepEqual(empty.physical, { valueCents: 0, includedCents: 0, count: 0, counted: true });
  assert.equal(empty.netWorthExPhysicalCents, 0);

  ok(await a.patch(`/accounts/${account.id}`, { initialBalanceCents: 1000000 }, auth), 'PATCH 账户');
  // 都是今天买的（估值 = 原价）或锁定在手动估值上：数字不随跑测试的日子变。
  const phone = ok(await a.post('/assets', { name: '手机', category: 'digital', priceCents: 599900, purchasedOn: today }, auth), '手机').asset;
  ok(await a.post('/assets', { name: '冰箱', category: 'appliance', priceCents: 320000, purchasedOn: today }, auth), '冰箱：按类别不计入');
  ok(await a.post('/assets', { name: '金镯子', category: 'jewelry', priceCents: 1000000, purchasedOn: '2020-05-01', manualValueCents: 1200000, manualValueOn: today }, auth), '金镯子：锁定在锚点');
  ok(await a.post('/assets', { name: '钢琴', category: 'furniture', priceCents: 2000000, purchasedOn: today, netWorth: 'include' }, auth), '钢琴：单件计入');
  ok(await a.post('/assets', { name: '旧平板', category: 'digital', priceCents: 100000, purchasedOn: today, netWorth: 'exclude' }, auth), '旧平板：单件不计入');
  ok(await a.post('/assets', { name: '闲置耳机', category: 'digital', priceCents: 50000, purchasedOn: today, status: 'idle' }, auth), '闲置照算');
  ok(await a.post('/assets', { name: '收起来的相机', category: 'digital', priceCents: 500000, purchasedOn: today, archived: true }, auth), '归档不算');
  const gone = ok(await a.post('/assets', { name: '删掉的', category: 'digital', priceCents: 700000, purchasedOn: today }, auth), '删掉不算').asset;
  ok(await a.del(`/assets/${gone.id}`, auth), 'DELETE');

  const o = await getStats(h, `/stats/overview?month=${MONTH}`);
  assert.deepEqual(o.physical, {
    valueCents: 599900 + 320000 + 1200000 + 2000000 + 100000 + 50000,
    includedCents: 599900 + 1200000 + 2000000 + 50000,
    count: 6,
    counted: true,
  });
  assert.equal(o.netWorthExPhysicalCents, 1000000);
  assert.equal(o.netWorthCents, 1000000 + 3849900);
  assert.equal(o.assetsCents - o.liabilitiesCents, o.netWorthCents, '净资产 = 资产 − 负债 的恒等式不破');

  ok(await a.patch('/settings', { assets: { netWorthIncludesPhysical: false } }, auth), '关掉全局开关');
  const off = await getStats(h, `/stats/overview?month=${MONTH}`);
  assert.equal(off.physical.counted, false);
  assert.equal(off.physical.includedCents, 3849900, '计入额照给：App 要写「不含」的是多少');
  assert.equal(off.netWorthCents, 1000000);
  assert.equal(off.netWorthExPhysicalCents, 1000000);
  assert.equal(off.assetsCents - off.liabilitiesCents, off.netWorthCents);
  ok(await a.patch('/settings', { assets: { netWorthIncludesPhysical: true } }, auth), '再打开');

  // 卖掉手机、卖出款进账户：手机的估值退出汇总，这笔钱只在账户里算一次。
  ok(await a.post(`/assets/${phone.id}/sell`, { saleCents: 500000, endedOn: today, recordTransaction: { accountId: account.id } }, auth), '卖出');
  const sold = await getStats(h, `/stats/overview?month=${MONTH}`);
  assert.equal(sold.physical.valueCents, 4269900 - 599900);
  assert.equal(sold.physical.includedCents, 3849900 - 599900);
  assert.equal(sold.physical.count, 5);
  assert.equal(sold.netWorthExPhysicalCents, 1500000);
  assert.equal(sold.netWorthCents, 1500000 + 3250000);
});
