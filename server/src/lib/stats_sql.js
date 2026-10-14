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

const invest = require('./invest');

/** 只有确认且未软删的流水算数。 */
const CONFIRMED = "deleted_at IS NULL AND status = 'confirmed'";

// 本地日期的前缀。不要换成 strftime —— 见文件头。只用来**分组**；过滤某个月用 [monthRange]：
// `substr(occurred_at, 1, 7) = ?` 走不了 idx_tx_occurred，每次统计都全表扫；
// `occurred_at >= '2026-09' AND occurred_at < '2026-10'` 是同一回事（都是字符串前缀比较），能走索引。
const MONTH_OF = 'substr(occurred_at, 1, 7)';
const DATE_OF = 'substr(occurred_at, 1, 10)';

/** `2026-09` → `2026-10`（跨年也对）。 */
function nextMonth(month) {
  const y = Number(month.slice(0, 4));
  const m = Number(month.slice(5, 7));
  return m === 12 ? `${String(y + 1).padStart(4, '0')}-01` : `${month.slice(0, 5)}${String(m + 1).padStart(2, '0')}`;
}

/**
 * 「occurred_at 落在这几个月里」的 WHERE 片段 + 参数。闭区间 [fromMonth, toMonth]（都是 `YYYY-MM`）；
 * 只给一个月就 `monthRange(m)`。字符串比较：`'2026-09-01T00:00:00+08:00' >= '2026-09'` 且 `< '2026-10'`。
 */
function monthRange(fromMonth, toMonth = fromMonth) {
  return { sql: 'occurred_at >= ? AND occurred_at < ?', args: [fromMonth, nextMonth(toMonth)] };
}

const EXPENSE_SUM = "SUM(CASE WHEN type = 'expense' THEN amount_cents ELSE 0 END)";
const INCOME_SUM = "SUM(CASE WHEN type = 'income' THEN amount_cents ELSE 0 END)";

/** SUM 在空集上返回 NULL；余额从来不是 NULL，是 0。 */
const cents = (x) => Number(x) || 0;

/**
 * 折算器：`conv(amountNative, currency) → 基准币金额`。跨实体的月度聚合必须按每笔流水自己的
 * 币种折到基准币再相加（否则把美元和人民币的分直接加起来）。默认恒等 —— 只有一种币（或调用方
 * 要原生币）时忽略 currency、原样返回，数字和不分币种的旧写法逐分一致。
 */
const IDENTITY = (amount) => amount;

/** JS 里复刻 SQL 的 `ORDER BY … ref ASC`：NULL 最靠前，其余按字符串升序。 */
function cmpRefAsc(a, b) {
  if (a === b) return 0;
  if (a === null || a === undefined) return -1;
  if (b === null || b === undefined) return 1;
  return a < b ? -1 : 1;
}

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
       SELECT ${to} AS ref, SUM(COALESCE(to_amount_cents, amount_cents)) AS delta
         FROM transactions WHERE ${CONFIRMED} AND type = 'transfer' AND ${to} ${only} GROUP BY ${to}
     ) AS both GROUP BY ref`,
    ...args,
  );
  return new Map(rows.map((r) => [r.ref, cents(r.delta)]));
}

/** 板块的期初余额（`funds.opening_balances`，按币种的 JSON）→ `Map<currency, cents>`；坏数据当空。 */
function parseOpenings(raw) {
  const out = new Map();
  let obj = null;
  try {
    obj = JSON.parse(raw || '{}');
  } catch {
    obj = null;
  }
  if (obj && typeof obj === 'object' && !Array.isArray(obj)) {
    for (const [cur, c] of Object.entries(obj)) {
      const n = Math.trunc(Number(c));
      if (/^[A-Z]{3}$/.test(cur) && Number.isFinite(n) && n !== 0) out.set(cur, n);
    }
  }
  return out;
}

/**
 * 各板块按币种分开的余额：`Map<fundId, Map<currency, cents>>` = 期初（`opening_balances`，「校准余额」改的就是它）
 * + 已确认流水。板块没有币种 —— 美元户的支出挂在「家庭公共」上，就是家庭公共的美元余额少了，不能和人民币的分
 * 直接加。跨币种转账的转入一侧按到账币种 / 到账金额记（to_currency / to_amount_cents），同币种转账这两列为空。
 */
function fundBalancesByCurrency(db, onlyId = null) {
  const only = onlyId ? '= ?' : 'IS NOT NULL';
  const args = onlyId ? [onlyId, onlyId] : [];
  const rows = db.all(
    `SELECT ref, cur, SUM(delta) AS delta FROM (
       SELECT fund_id AS ref, currency AS cur,
              SUM(CASE WHEN type = 'income' THEN amount_cents ELSE -amount_cents END) AS delta
         FROM transactions WHERE ${CONFIRMED} AND fund_id ${only} GROUP BY fund_id, currency
       UNION ALL
       SELECT to_fund_id AS ref, COALESCE(to_currency, currency) AS cur, SUM(COALESCE(to_amount_cents, amount_cents)) AS delta
         FROM transactions WHERE ${CONFIRMED} AND type = 'transfer' AND to_fund_id ${only}
        GROUP BY to_fund_id, COALESCE(to_currency, currency)
     ) AS both GROUP BY ref, cur`,
    ...args,
  );
  const sums = new Map();
  const add = (ref, cur, v) => {
    if (!sums.has(ref)) sums.set(ref, new Map());
    const m = sums.get(ref);
    m.set(cur, (m.get(cur) || 0) + v);
  };
  for (const r of rows) add(r.ref, r.cur || 'CNY', cents(r.delta));
  const funds = onlyId
    ? db.all("SELECT id, opening_balances FROM funds WHERE id = ? AND opening_balances != '{}'", onlyId)
    : db.all("SELECT id, opening_balances FROM funds WHERE deleted_at IS NULL AND opening_balances != '{}'");
  for (const f of funds) for (const [cur, v] of parseOpenings(f.opening_balances)) add(f.id, cur, v);
  const out = new Map();
  for (const [ref, m] of sums) {
    const nonZero = new Map([...m].filter(([, v]) => v !== 0));
    out.set(ref, nonZero);
  }
  return out;
}

/**
 * 某个月按币种分开的支出/收入（原生金额，不折算）：首页「本月支出」按币种分行显示用。
 * @returns {{currency: string, expenseCents: number, incomeCents: number}[]}
 */
function monthSumsByCurrency(db, month, filter) {
  const f = filterClause(filter);
  const r = monthRange(month);
  return db.all(
    `SELECT currency, ${EXPENSE_SUM} AS expense, ${INCOME_SUM} AS income
       FROM transactions WHERE ${CONFIRMED} AND ${r.sql}${f.sql} GROUP BY currency`,
    ...r.args, ...f.args,
  ).map((x) => ({ currency: x.currency || 'CNY', expenseCents: cents(x.expense), incomeCents: cents(x.income) }))
    .filter((x) => x.expenseCents !== 0 || x.incomeCents !== 0);
}

/**
 * 某个月的支出/收入合计。
 * @returns {{expenseCents: number, incomeCents: number}}
 */
function monthSums(db, month, filter, conv = IDENTITY) {
  const f = filterClause(filter);
  const r = monthRange(month);
  // 按币种分组、各自折算再相加：把美元的分和人民币的分直接 SUM 到一起是没有意义的。
  const rows = db.all(
    `SELECT currency, ${EXPENSE_SUM} AS expense, ${INCOME_SUM} AS income
       FROM transactions WHERE ${CONFIRMED} AND ${r.sql}${f.sql} GROUP BY currency`,
    ...r.args, ...f.args,
  );
  let expenseCents = 0;
  let incomeCents = 0;
  for (const row of rows) {
    expenseCents += conv(cents(row.expense), row.currency);
    incomeCents += conv(cents(row.income), row.currency);
  }
  return { expenseCents, incomeCents };
}

/**
 * 某个月按某一列分组的支出 + 收入。只看 expense/income —— 转账既不是支出也不是
 * 收入，放进来只会多出一堆全零的分组。没填该列的行不参与。
 * @returns {{ref: string, expenseCents: number, incomeCents: number}[]} 支出多的在前
 */
function totalsByColumn(db, month, column, filter, conv = IDENTITY) {
  const col = groupColumn(column);
  const f = filterClause(filter);
  const r = monthRange(month);
  const rows = db.all(
    `SELECT ${col} AS ref, currency, ${EXPENSE_SUM} AS expense, ${INCOME_SUM} AS income
       FROM transactions WHERE ${CONFIRMED} AND ${r.sql} AND type IN ('expense', 'income')
       AND ${col} IS NOT NULL${f.sql}
      GROUP BY ref, currency`,
    ...r.args, ...f.args,
  );
  // 同一 ref 可能有多种币的行，折算到基准币后合并，再按 SQL 原本的次序排（支出多在前）。
  const acc = new Map();
  for (const x of rows) {
    const e = acc.get(x.ref) || { ref: x.ref, expenseCents: 0, incomeCents: 0 };
    e.expenseCents += conv(cents(x.expense), x.currency);
    e.incomeCents += conv(cents(x.income), x.currency);
    acc.set(x.ref, e);
  }
  return [...acc.values()].sort(
    (a, b) => b.expenseCents - a.expenseCents || b.incomeCents - a.incomeCents || cmpRefAsc(a.ref, b.ref),
  );
}

/**
 * 某个月按某一列分组的**支出**。没填该列的行会汇成 `ref: null` 的一组
 * （「未分类」是真实存在的开销，藏起来会让环形图对不上总数）。
 * @returns {{ref: string|null, expenseCents: number}[]} 金额大的在前
 */
function expenseByColumn(db, month, column, filter, conv = IDENTITY) {
  const col = groupColumn(column);
  const f = filterClause(filter);
  const r = monthRange(month);
  const rows = db.all(
    `SELECT ${col} AS ref, currency, SUM(amount_cents) AS expense
       FROM transactions WHERE ${CONFIRMED} AND ${r.sql} AND type = 'expense'${f.sql}
      GROUP BY ref, currency`,
    ...r.args, ...f.args,
  );
  const acc = new Map();
  for (const x of rows) {
    const key = x.ref === undefined ? null : x.ref;
    acc.set(key, (acc.get(key) || 0) + conv(cents(x.expense), x.currency));
  }
  return [...acc.entries()]
    .map(([ref, expenseCents]) => ({ ref, expenseCents }))
    .sort((a, b) => b.expenseCents - a.expenseCents || cmpRefAsc(a.ref, b.ref));
}

/**
 * `fromMonth`~`toMonth`（闭区间）内**有流水的那些月**的支出/收入。
 * 缺的月份这里不补 —— 补零是调用方的事（它才知道要几个月）。
 * @returns {{month: string, expenseCents: number, incomeCents: number}[]}
 */
function monthlyTotals(db, fromMonth, toMonth, filter, conv = IDENTITY) {
  const f = filterClause(filter);
  const r = monthRange(fromMonth, toMonth);
  const rows = db.all(
    `SELECT ${MONTH_OF} AS month, currency, ${EXPENSE_SUM} AS expense, ${INCOME_SUM} AS income
       FROM transactions WHERE ${CONFIRMED} AND ${r.sql}${f.sql}
      GROUP BY month, currency`,
    ...r.args, ...f.args,
  );
  const acc = new Map();
  for (const x of rows) {
    const e = acc.get(x.month) || { month: x.month, expenseCents: 0, incomeCents: 0 };
    e.expenseCents += conv(cents(x.expense), x.currency);
    e.incomeCents += conv(cents(x.income), x.currency);
    acc.set(x.month, e);
  }
  return [...acc.values()].sort((a, b) => (a.month < b.month ? -1 : a.month > b.month ? 1 : 0));
}

/**
 * 某个月里**有流水的每一天**。转账不进支出也不进收入，但算一笔（`count`）。
 * @returns {{date: string, expenseCents: number, incomeCents: number, count: number}[]}
 */
function dailyTotals(db, month, filter, conv = IDENTITY) {
  const f = filterClause(filter);
  const r = monthRange(month);
  const rows = db.all(
    `SELECT ${DATE_OF} AS date, currency, ${EXPENSE_SUM} AS expense, ${INCOME_SUM} AS income, COUNT(*) AS n
       FROM transactions WHERE ${CONFIRMED} AND ${r.sql}${f.sql}
      GROUP BY date, currency`,
    ...r.args, ...f.args,
  );
  const acc = new Map();
  for (const x of rows) {
    const e = acc.get(x.date) || { date: x.date, expenseCents: 0, incomeCents: 0, count: 0 };
    e.expenseCents += conv(cents(x.expense), x.currency);
    e.incomeCents += conv(cents(x.income), x.currency);
    e.count += Number(x.n) || 0; // 笔数与币种无关：各币种分组的 COUNT 相加就是当天总笔数
    acc.set(x.date, e);
  }
  return [...acc.values()].sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : 0));
}

/** 持仓市值（分）= 份额E4 × 价格E4 / 1e6，四舍五入。口径在 lib/invest.js。 */
const { marketCents } = invest;

/**
 * 计入投资统计的理财：未归档未删除、还持有着（份额 > 0）、估值算得出来（unit 没价格的跳过）。
 * 估值按品类算（lib/invest.js 的 valueOf）：定期按天计息、活期按手动更新的金额。
 * @param {string} today `YYYY-MM-DD`，定期计息算到哪天
 * @returns {{accountId: string|null, kind: string, costCents: number, marketCents: number}[]}
 */
function investPositions(db, today) {
  const out = [];
  for (const r of db.all(
    `SELECT * FROM holdings WHERE deleted_at IS NULL AND archived = 0 AND quantity_e4 > 0`,
  )) {
    const value = invest.valueOf(r, today);
    if (value === null) continue;
    // 市值/成本都是持仓自己的币种；由 stats.js 折到基准币再进净资产。
    out.push({
      accountId: r.account_id, kind: invest.kindOf(r), costCents: cents(r.cost_cents), marketCents: value,
      currency: r.currency || 'CNY',
    });
  }
  return out;
}

module.exports = {
  CONFIRMED, MONTH_OF, DATE_OF, EXPENSE_SUM, INCOME_SUM,
  nextMonth, monthRange, filterClause, deltaMap, fundBalancesByCurrency, parseOpenings, monthSums, monthSumsByCurrency, totalsByColumn,
  expenseByColumn, monthlyTotals, dailyTotals,
  marketCents, investPositions,
};
