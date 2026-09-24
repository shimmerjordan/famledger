'use strict';

// 统计用到的流水聚合 SQL，集中一处。**口径只在这里写一遍**：别的地方要算钱，
// 调这里的函数，不要再拼一遍 CASE WHEN —— 少一个 `status = 'confirmed'` 就是
// 一份对不上的账。
//
//   · 参与计算的行：`deleted_at IS NULL AND status = 'confirmed'`。
//     pending / duplicate / void 一律不进余额与聚合（pending 只在别处报个数）。
//   · 月份、日期 = `occurred_at` 的**字符串前缀**，绝不能改成 `strftime()` 或
//     UTC 区间。写入侧（transactions.js）把 occurredAt **原样**存成客户端给的
//     「带时区偏移的本地时间」（`2026-09-01T01:00:00+08:00`），所以前缀就是用户
//     心里的那个本地月/日；`strftime('%Y-%m', …)` 会把它折算成 UTC 的 2026-08，
//     早餐钱就掉到上个月去了。`test/stats.test.js` 里有一条用例专钉这个。
//   · 转账的两头各算各的：`account_id`/`fund_id` 是转出侧，`to_*` 是转入侧。
//     「拨款」只有基金对 → 账户余额不动；「还信用卡」只有账户对 → 基金余额不动。

/** 只有确认且未软删的流水算数。 */
const CONFIRMED = "deleted_at IS NULL AND status = 'confirmed'";

// 本地日期的前缀。不要换成 strftime —— 见文件头。
const MONTH_OF = 'substr(occurred_at, 1, 7)';
const DATE_OF = 'substr(occurred_at, 1, 10)';

const EXPENSE_SUM = "SUM(CASE WHEN type = 'expense' THEN amount_cents ELSE 0 END)";
const INCOME_SUM = "SUM(CASE WHEN type = 'income' THEN amount_cents ELSE 0 END)";

/** SUM 在空集上返回 NULL；余额从来不是 NULL，是 0。 */
const cents = (x) => Number(x) || 0;

/** 能拿来分组的列。只在代码里出现，不接受用户输入 —— 但还是挡一道。 */
const GROUPABLE = new Set(['fund_id', 'category_id', 'member_id', 'account_id']);

function groupColumn(column) {
  if (!GROUPABLE.has(column)) throw new Error(`stats_sql: 不能按 ${column} 分组`);
  return column;
}

/**
 * `{fundId, categoryId}` → 附加的 WHERE 片段。基金过滤把转入的一侧也算上
 * （拨进这个基金的那笔，是这个基金的流水），与 `GET /transactions?fundId=` 一致。
 * 对支出/收入两种类型来说两种写法等价（它们的 `to_fund_id` 恒为 NULL）。
 */
function filterClause({ fundId = null, categoryId = null } = {}) {
  let sql = '';
  const args = [];
  if (fundId) {
    sql += ' AND (fund_id = ? OR to_fund_id = ?)';
    args.push(fundId, fundId);
  }
  if (categoryId) {
    sql += ' AND category_id = ?';
    args.push(categoryId);
  }
  return { sql, args };
}

/**
 * 每个账户（或基金）的流水净额，**不含** `initial_balance_cents`。
 * 转出侧：收入 +、支出 −、转账 −；转入侧：+。
 * @param {object} db lib/db.js 的句柄
 * @param {'account'|'fund'} side
 * @param {string|null} [onlyId] 只算这一个 id（省掉全表分组）
 * @returns {Map<string, number>} id → 净额（分）
 */
function deltaMap(db, side, onlyId = null) {
  const [from, to] = side === 'fund' ? ['fund_id', 'to_fund_id'] : ['account_id', 'to_account_id'];
  const only = onlyId ? '= ?' : 'IS NOT NULL';
  const args = onlyId ? [onlyId, onlyId] : [];
  const rows = db.all(
    `SELECT ref, SUM(delta) AS delta FROM (
       SELECT ${from} AS ref, SUM(CASE WHEN type = 'income' THEN amount_cents ELSE -amount_cents END) AS delta
         FROM transactions WHERE ${CONFIRMED} AND ${from} ${only} GROUP BY ${from}
       UNION ALL
       SELECT ${to} AS ref, SUM(amount_cents) AS delta
         FROM transactions WHERE ${CONFIRMED} AND type = 'transfer' AND ${to} ${only} GROUP BY ${to}
     ) AS both GROUP BY ref`,
    ...args,
  );
  return new Map(rows.map((r) => [r.ref, cents(r.delta)]));
}

/**
 * 某个月的支出/收入合计。
 * @returns {{expenseCents: number, incomeCents: number}}
 */
function monthSums(db, month, filter) {
  const f = filterClause(filter);
  const row = db.get(
    `SELECT ${EXPENSE_SUM} AS expense, ${INCOME_SUM} AS income
       FROM transactions WHERE ${CONFIRMED} AND ${MONTH_OF} = ?${f.sql}`,
    month, ...f.args,
  );
  return { expenseCents: cents(row && row.expense), incomeCents: cents(row && row.income) };
}

/**
 * 某个月按某一列分组的支出 + 收入。只看 expense/income —— 转账既不是支出也不是
 * 收入，放进来只会多出一堆全零的分组。没填该列的行不参与。
 * @returns {{ref: string, expenseCents: number, incomeCents: number}[]} 支出多的在前
 */
function totalsByColumn(db, month, column, filter) {
  const col = groupColumn(column);
  const f = filterClause(filter);
  return db.all(
    `SELECT ${col} AS ref, ${EXPENSE_SUM} AS expense, ${INCOME_SUM} AS income
       FROM transactions WHERE ${CONFIRMED} AND ${MONTH_OF} = ? AND type IN ('expense', 'income')
       AND ${col} IS NOT NULL${f.sql}
      GROUP BY ref ORDER BY expense DESC, income DESC, ref ASC`,
    month, ...f.args,
  ).map((r) => ({ ref: r.ref, expenseCents: cents(r.expense), incomeCents: cents(r.income) }));
}

/**
 * 某个月按某一列分组的**支出**。没填该列的行会汇成 `ref: null` 的一组
 * （「未分类」是真实存在的开销，藏起来会让环形图对不上总数）。
 * @returns {{ref: string|null, expenseCents: number}[]} 金额大的在前
 */
function expenseByColumn(db, month, column, filter) {
  const col = groupColumn(column);
  const f = filterClause(filter);
  return db.all(
    `SELECT ${col} AS ref, SUM(amount_cents) AS expense
       FROM transactions WHERE ${CONFIRMED} AND ${MONTH_OF} = ? AND type = 'expense'${f.sql}
      GROUP BY ref ORDER BY expense DESC, ref ASC`,
    month, ...f.args,
  ).map((r) => ({ ref: r.ref === undefined ? null : r.ref, expenseCents: cents(r.expense) }));
}

/**
 * `fromMonth`~`toMonth`（闭区间）内**有流水的那些月**的支出/收入。
 * 缺的月份这里不补 —— 补零是调用方的事（它才知道要几个月）。
 * @returns {{month: string, expenseCents: number, incomeCents: number}[]}
 */
function monthlyTotals(db, fromMonth, toMonth, filter) {
  const f = filterClause(filter);
  return db.all(
    `SELECT ${MONTH_OF} AS month, ${EXPENSE_SUM} AS expense, ${INCOME_SUM} AS income
       FROM transactions WHERE ${CONFIRMED} AND ${MONTH_OF} >= ? AND ${MONTH_OF} <= ?${f.sql}
      GROUP BY month ORDER BY month`,
    fromMonth, toMonth, ...f.args,
  ).map((r) => ({ month: r.month, expenseCents: cents(r.expense), incomeCents: cents(r.income) }));
}

/**
 * 某个月里**有流水的每一天**。转账不进支出也不进收入，但算一笔（`count`）。
 * @returns {{date: string, expenseCents: number, incomeCents: number, count: number}[]}
 */
function dailyTotals(db, month, filter) {
  const f = filterClause(filter);
  return db.all(
    `SELECT ${DATE_OF} AS date, ${EXPENSE_SUM} AS expense, ${INCOME_SUM} AS income, COUNT(*) AS n
       FROM transactions WHERE ${CONFIRMED} AND ${MONTH_OF} = ?${f.sql}
      GROUP BY date ORDER BY date ASC`,
    month, ...f.args,
  ).map((r) => ({
    date: r.date,
    expenseCents: cents(r.expense),
    incomeCents: cents(r.income),
    count: Number(r.n) || 0,
  }));
}

/**
 * 持仓市值（分）= 份额E4 × 价格E4 / 1e6，四舍五入。两个 ×10000 的数一乘就越过 2^53，
 * 所以走 BigInt；App 端按同一个式子算，两边对得上。
 */
function marketCents(quantityE4, priceE4) {
  return Number((BigInt(quantityE4) * BigInt(priceE4) + 500000n) / 1000000n);
}

/**
 * 计入投资统计的持仓：有价格、未归档未删除、份额 > 0（清了仓的只剩已实现盈亏，不算市值）。
 * @returns {{accountId: string|null, costCents: number, marketCents: number}[]}
 */
function investPositions(db) {
  return db.all(
    `SELECT account_id, quantity_e4, cost_cents, price_e4 FROM holdings
      WHERE deleted_at IS NULL AND archived = 0 AND quantity_e4 > 0 AND price_e4 IS NOT NULL`,
  ).map((r) => ({
    accountId: r.account_id,
    costCents: cents(r.cost_cents),
    marketCents: marketCents(r.quantity_e4, r.price_e4),
  }));
}

module.exports = {
  CONFIRMED, MONTH_OF, DATE_OF, EXPENSE_SUM, INCOME_SUM,
  filterClause, deltaMap, monthSums, totalsByColumn, expenseByColumn, monthlyTotals, dailyTotals,
  marketCents, investPositions,
};
