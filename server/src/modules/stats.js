'use strict';

// 统计。整个 App 的首页、基金页、分析页、以及 AI 的上下文都吃这里的数字，所以
// 口径写在这一个文件里，别处不要再算一遍：
//
//   1. **只有确认的流水算数**：`status = 'confirmed'` 且未软删。pending 不进余额
//      也不进聚合，只在 `pendingCount` 里报个数（全局计数，不限本月 —— 首页那张
//      「待确认」卡片要把积压的都显示出来）。
//   2. **余额**：账户 = `initial_balance_cents` + Σ(收入 − 支出 − 转出) + Σ转入；
//      基金一样，只是没有初始额。转账的账户对与基金对正交，所以「拨款」只动基金、
//      「还信用卡」只动账户。已归档但未删除的账户/基金照样给出余额（要不要显示
//      是客户端的事，钱还在)。
//   3. **月份 = `occurred_at` 的 `YYYY-MM` 字符串前缀**（日历是前 10 位）。
//      transactions.js 把 `occurredAt` 原样存成客户端给的「带偏移的本地时间」
//      （`2026-09-01T01:00:00+08:00`），服务端**不做时区换算** —— 所以前缀就是
//      用户心里的那个月份：北京时间 9/1 凌晨那笔算 9 月，尽管它的 UTC 还是 8/31。
//      **千万别改成 `strftime()` 或 UTC 区间**，那等于把每天最早的 8 小时记到
//      前一天。`month` 省略时按**服务器本地时区**算当前月（部署 `TZ=Asia/Shanghai`
//      时正好与家人的本地日期同一套），跨月那几个小时仍建议客户端显式传 `month`。
//   4. **投资持仓进净资产**：挂了投资账户的持仓，成本已经以转账的形式记在账户余额里，
//      只补浮盈（市值 − 成本）；没挂账户的整份市值计入。只算有价格、未归档未删除、
//      份额 > 0 的持仓。「成本已在余额里」这个前提由 holdings.js 守着（有成本的持仓
//      挂账户必须同时记转账、换账户补移仓转账、不许直接解绑），这里只管照算。
//
// 四个 `compute*` 是纯函数（只读 db、返回可直接 JSON 化的对象），AI 模块直接
// require 过去拼上下文，不用绕一圈 HTTP：
//
//   const stats = require('./stats');
//   stats.computeOverview(db, '2026-09');
//   stats.computeTrend(db, { months: 6, endMonth: '2026-09', fundId, categoryId });
//   stats.computeFundStats(db, fundId, '2026-09');   // 基金不存在 → 抛 HttpError(404)
//   stats.computeCalendar(db, '2026-09');

const { HttpError, sendJson } = require('../lib/router');
const { rowToJson } = require('../lib/db');
const v = require('../lib/validate');
const sql = require('../lib/stats_sql');

const TREND_DEFAULT_MONTHS = 12;
const TREND_MAX_MONTHS = 60;
const RECENT_LIMIT = 10;

// transactions.js 没有导出它的 txJson，这里保持同一份形状：tags 是 JSON 列，
// 其余原样 camelCase。`recent` 因此与 `GET /transactions` 的 items 逐字段一致。
const txJson = (row) => rowToJson(row, { json: ['tags'] });

const cmp = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

/** 服务器本地时区的当前月。 */
function currentMonth() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;
}

/** `2026-09` 前后挪 n 个月（n 可负）。 */
function shiftMonth(month, n) {
  const total = Number(month.slice(0, 4)) * 12 + (Number(month.slice(5, 7)) - 1) + n;
  const year = Math.floor(total / 12);
  const m = total - year * 12 + 1;
  return `${String(year).padStart(4, '0')}-${String(m).padStart(2, '0')}`;
}

/**
 * 这个月生效的全部预算：`(scope, refId)` 下具体月份的行压过 `'*'`（每月默认）。
 *
 * ⚠ **这段解析必须和 `modules/budgets.js` 的 `list()` 逐条等价** —— 同一个月、同一个
 * `(scope, refId)`，`GET /budgets?month=` 给出的金额和这里算出的 `budgetCents`
 * 必须是同一个数，否则预算页显示 500.00、首页进度条按 400.00 画，用户会以为账本坏了。
 * 两边是各自独立的实现（budgets 返回整行、这里只要金额并且还要配 `spentCents`），
 * 所以**改任何一边都要同步改另一边**；`test/stats.test.js` 里有一条跨模块用例
 * （「预算口径与 budgets 模块一致」）专门把这两个出口对起来，改漏了会红。
 *
 * @returns {{scope: string, refId: string, budgetCents: number}[]}
 */
function resolvedBudgets(db, month) {
  const rows = db.all(
    "SELECT scope, ref_id, month, amount_cents FROM budgets WHERE deleted_at IS NULL AND month IN (?, '*')",
    month,
  );
  /** @type {Map<string, object>} */
  const best = new Map();
  for (const r of rows) {
    const key = `${r.scope}/${r.ref_id}`;
    if (!best.has(key) || r.month === month) best.set(key, r);
  }
  return [...best.values()].map((r) => ({
    scope: r.scope,
    refId: r.ref_id,
    budgetCents: Number(r.amount_cents) || 0,
  }));
}

/** 单个 `(scope, refId)` 这个月生效的预算；没有预算行就是 null。 */
function budgetFor(db, month, scope, refId) {
  const row = db.get(
    "SELECT amount_cents FROM budgets WHERE deleted_at IS NULL AND scope = ? AND ref_id = ? AND month IN (?, '*')" +
      " ORDER BY CASE WHEN month = '*' THEN 1 ELSE 0 END LIMIT 1",
    scope, refId, month,
  );
  return row ? Number(row.amount_cents) || 0 : null;
}

/**
 * 首页要的全部数字：净资产、本月聚合、待确认笔数、每个账户与基金的余额。
 * @param {object} db lib/db.js 的句柄
 * @param {string} [month] `YYYY-MM`，默认服务器本地时区的当前月
 */
function computeOverview(db, month = currentMonth()) {
  const accountDelta = sql.deltaMap(db, 'account');
  const fundDelta = sql.deltaMap(db, 'fund');

  // 归档的也给 —— 归档只是「别在记账时挑到它」，钱还在里面。
  const accounts = db
    .all('SELECT id, initial_balance_cents FROM accounts WHERE deleted_at IS NULL ORDER BY sort_order, created_at')
    .map((r) => ({
      accountId: r.id,
      balanceCents: (Number(r.initial_balance_cents) || 0) + (accountDelta.get(r.id) || 0),
    }));
  const funds = db
    .all('SELECT id FROM funds WHERE deleted_at IS NULL ORDER BY sort_order, created_at')
    .map((r) => ({ fundId: r.id, balanceCents: fundDelta.get(r.id) || 0 }));

  // 正余额是资产，负余额（通常是信用卡的欠款）取绝对值进负债。信用卡还成正数
  // 了（多还了钱）就照样是资产 —— 按余额的正负分，不按账户类型分。
  let assetsCents = 0;
  let liabilitiesCents = 0;
  for (const a of accounts) {
    if (a.balanceCents >= 0) assetsCents += a.balanceCents;
    else liabilitiesCents -= a.balanceCents;
  }

  // 挂的账户被删了，成本也跟着从余额里消失了，只能按没挂账户整份算。调整记在资产一侧，
  // 「净资产 = 资产 − 负债」才不会在首页对不上。
  const liveAccounts = new Set(accounts.map((a) => a.accountId));
  let investMarketCents = 0;
  let investCostCents = 0;
  for (const p of sql.investPositions(db)) {
    investMarketCents += p.marketCents;
    investCostCents += p.costCents;
    assetsCents += p.accountId && liveAccounts.has(p.accountId) ? p.marketCents - p.costCents : p.marketCents;
  }

  const totals = sql.monthSums(db, month);
  const fundSpent = new Map(sql.expenseByColumn(db, month, 'fund_id').map((r) => [r.ref, r.expenseCents]));
  const categorySpent = new Map(sql.expenseByColumn(db, month, 'category_id').map((r) => [r.ref, r.expenseCents]));

  const budgets = resolvedBudgets(db, month).map((b) => ({
    ...b,
    spentCents: (b.scope === 'fund' ? fundSpent.get(b.refId) : categorySpent.get(b.refId)) || 0,
  }));
  // 只在基金上填了「月预算」、没单独建预算行的，也要出现在这张表里：客户端的
  // 基金卡片靠它画进度条。
  const hasBudgetRow = new Set(budgets.map((b) => `${b.scope}/${b.refId}`));
  for (const f of db.all(
    'SELECT id, monthly_budget_cents FROM funds WHERE deleted_at IS NULL AND monthly_budget_cents IS NOT NULL',
  )) {
    if (hasBudgetRow.has(`fund/${f.id}`)) continue;
    budgets.push({
      scope: 'fund',
      refId: f.id,
      budgetCents: Number(f.monthly_budget_cents) || 0,
      spentCents: fundSpent.get(f.id) || 0,
    });
  }
  budgets.sort((a, b) => (a.scope === b.scope ? cmp(a.refId, b.refId) : cmp(a.scope, b.scope)));

  const pending = db.get(
    "SELECT COUNT(*) AS n FROM transactions WHERE deleted_at IS NULL AND status = 'pending'",
  );

  return {
    netWorthCents: assetsCents - liabilitiesCents,
    assetsCents,
    liabilitiesCents,
    investMarketCents,
    investCostCents,
    investGainCents: investMarketCents - investCostCents,
    month: {
      expenseCents: totals.expenseCents,
      incomeCents: totals.incomeCents,
      byFund: sql.totalsByColumn(db, month, 'fund_id').map((r) => ({
        fundId: r.ref,
        expenseCents: r.expenseCents,
        incomeCents: r.incomeCents,
      })),
      byCategory: sql
        .expenseByColumn(db, month, 'category_id')
        .map((r) => ({ categoryId: r.ref, expenseCents: r.expenseCents })),
      byMember: sql
        .expenseByColumn(db, month, 'member_id')
        .map((r) => ({ memberId: r.ref, expenseCents: r.expenseCents })),
      budgets,
    },
    pendingCount: Number(pending && pending.n) || 0,
    funds,
    accounts,
  };
}

/**
 * 月度趋势柱状图的数据源：正好 `months` 条，最老的在前，缺的月份补 0。
 * @param {object} db
 * @param {{months?: number, fundId?: string|null, categoryId?: string|null, endMonth?: string|null}} [opts]
 */
function computeTrend(db, { months = TREND_DEFAULT_MONTHS, fundId = null, categoryId = null, endMonth = null } = {}) {
  const raw = Number(months);
  const n = Number.isFinite(raw)
    ? Math.min(TREND_MAX_MONTHS, Math.max(1, Math.trunc(raw)))
    : TREND_DEFAULT_MONTHS;
  const end = endMonth || currentMonth();
  const from = shiftMonth(end, -(n - 1));

  const found = new Map(sql.monthlyTotals(db, from, end, { fundId, categoryId }).map((r) => [r.month, r]));
  const series = [];
  for (let i = 0; i < n; i++) {
    const m = shiftMonth(from, i);
    const hit = found.get(m);
    series.push({
      month: m,
      expenseCents: hit ? hit.expenseCents : 0,
      incomeCents: hit ? hit.incomeCents : 0,
    });
  }
  return { series };
}

/**
 * 基金详情页要的一切。`recent` 不限月份也不限状态（待确认的正是要在这里被看到
 * 并确认的），其余数字都只算这个月、只算确认的流水。
 * @throws {HttpError} 404 not_found —— 基金不存在或已软删
 */
function computeFundStats(db, fundId, month = currentMonth()) {
  const fund = db.get('SELECT * FROM funds WHERE id = ? AND deleted_at IS NULL', fundId);
  if (!fund) throw new HttpError(404, 'not_found', '基金不存在');

  const totals = sql.monthSums(db, month, { fundId });
  const monthlyBudgetCents = fund.monthly_budget_cents === null ? null : Number(fund.monthly_budget_cents);
  const budgetRow = budgetFor(db, month, 'fund', fundId);

  return {
    fundId,
    balanceCents: sql.deltaMap(db, 'fund', fundId).get(fundId) || 0,
    targetCents: fund.target_cents === null ? null : Number(fund.target_cents),
    monthlyBudgetCents,
    budgetCents: budgetRow === null ? monthlyBudgetCents : budgetRow,
    monthExpenseCents: totals.expenseCents,
    monthIncomeCents: totals.incomeCents,
    byCategory: sql
      .expenseByColumn(db, month, 'category_id', { fundId })
      .map((r) => ({ categoryId: r.ref, expenseCents: r.expenseCents })),
    recent: db
      .all(
        'SELECT * FROM transactions WHERE deleted_at IS NULL AND (fund_id = ? OR to_fund_id = ?)' +
          ' ORDER BY occurred_at DESC, id DESC LIMIT ?',
        fundId, fundId, RECENT_LIMIT,
      )
      .map(txJson),
  };
}

/** 日历热力图：只给有流水的那几天，按日期升序。 */
function computeCalendar(db, month = currentMonth()) {
  return { days: sql.dailyTotals(db, month) };
}

function statsModule(ctx) {
  const { db } = ctx;

  /** 缺省即当前月；给了就必须是 `YYYY-MM`（`2026-13` 这种也拦掉）。 */
  const monthParam = (query, name = 'month') =>
    query[name] === undefined || query[name] === '' ? currentMonth() : v.month(query[name], name);

  return {
    name: 'stats',
    routes: [
      {
        method: 'GET',
        pattern: '/stats/overview',
        maxBody: 0,
        handler: (req, res, c) => sendJson(res, 200, computeOverview(db, monthParam(c.query))),
      },
      {
        method: 'GET',
        pattern: '/stats/trend',
        maxBody: 0,
        handler: (req, res, c) => {
          const q = c.query;
          // 越界的 months 夹到 1~60（图少画几根柱子总比报错好），但不是整数
          // 就是客户端写错了，照常 400。
          const months = q.months === undefined || q.months === '' ? TREND_DEFAULT_MONTHS : v.int(q.months, 'months');
          sendJson(res, 200, computeTrend(db, {
            months,
            endMonth: monthParam(q, 'endMonth'),
            fundId: q.fundId || null,
            categoryId: q.categoryId || null,
          }));
        },
      },
      {
        method: 'GET',
        pattern: '/stats/fund/:id',
        maxBody: 0,
        handler: (req, res, c) => sendJson(res, 200, computeFundStats(db, c.params.id, monthParam(c.query))),
      },
      {
        method: 'GET',
        pattern: '/stats/calendar',
        maxBody: 0,
        handler: (req, res, c) => sendJson(res, 200, computeCalendar(db, monthParam(c.query))),
      },
    ],
  };
}

module.exports = statsModule;
// 纯函数挂在工厂函数上（装载器只看导出本身是不是函数，所以不影响自动装载）。
module.exports.computeOverview = computeOverview;
module.exports.computeTrend = computeTrend;
module.exports.computeFundStats = computeFundStats;
module.exports.computeCalendar = computeCalendar;
module.exports.currentMonth = currentMonth;
module.exports.shiftMonth = shiftMonth;
module.exports.budgetFor = budgetFor;
module.exports.resolvedBudgets = resolvedBudgets;
