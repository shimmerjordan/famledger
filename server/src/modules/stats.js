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
//   4. **理财进净资产**：估值按品类算（lib/invest.js：基金股票按份额×价、定期按天计息、
//      活期按手动更新的金额）。挂了投资账户的，成本已经以转账的形式记在账户余额里，
//      只补浮盈（估值 − 成本）；没挂账户的整份估值计入。只算估值算得出来、未归档未删除、
//      还持有着的。「成本已在余额里」这个前提由 holdings.js 守着（有成本的持仓
//      挂账户必须同时记转账、换账户补移仓转账、不许直接解绑），这里只管照算。
//      股票账户（kind = 'stock'）不挂持仓，按整户市值记：余额是投入，浮盈 = 市值 − 账户余额，
//      补进资产；没填过市值（value_cents 为空）的按投入算，只在 investAccountsCents 里。
//   6. **债务**：每笔债务背后一个 kind = 'debt' 的内部账户，余额就是还剩多少（借出为正、借入为负）。
//      `debts.counted` 的才进资产负债（人情默认不计）；分项里不算进现金流。
//   5. **实物估值进净资产**：物品估值按 lib/valuation.js 现算，只算未归档、在用或闲置的。
//      按单件三态和类别默认「该计入」的部分是 `physical.includedCents`；家庭设置
//      `assets.netWorthIncludesPhysical` 开着（`physical.counted`）才加进资产一侧，
//      「净资产 = 资产 − 负债」照样成立。`netWorthExPhysicalCents` 永远不含实物，
//      App 的净资产总览靠它分项。
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
const valuation = require('../lib/valuation');
const fxlib = require('../lib/fx');
const settings = require('./settings');

const TREND_DEFAULT_MONTHS = 12;
const TREND_MAX_MONTHS = 60;
const RECENT_LIMIT = 10;

// transactions.js 没有导出它的 txJson，这里保持同一份形状：tags 是 JSON 列，
// 其余原样 camelCase。`recent` 因此与 `GET /transactions` 的 items 逐字段一致。
const txJson = (row) => rowToJson(row, { json: ['tags'], bools: ['off_balance'] });

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

/** 家庭基准币（默认 CNY）：所有跨实体的聚合都折到它。 */
function baseCurrency(db) {
  return settings.currentSettings(db).currency || 'CNY';
}

/**
 * 建一个「把各币种金额折到基准币」的折算器，供 stats_sql 的跨实体聚合与实物估值用。
 * 一次把 base 的汇率读进内存，之后每笔查表折算（rate_e6 整数运算集中在 lib/fx.js）。
 * 缺某一对时绝不臆造：那部分金额按 0 计入基准币合计（各实体条目里的原生币金额照常显示），
 * 并把币种记进 `missing`，随 `overview.fx` 暴露给客户端标「汇率缺失」。
 * @returns {{(amount:number, currency?:string): number, base:string, rates:object, asOf:string|null, missing:Set<string>}}
 */
function makeConverter(db, base) {
  const { rates, asOf, manual } = fxlib.ratesForBase(db, base);
  const missing = new Set();
  const conv = (amount, currency) => {
    const c = String(currency || base || 'CNY').toUpperCase();
    if (c === base) return amount;
    const rate = rates[c];
    if (rate === undefined) {
      missing.add(c);
      return 0;
    }
    return fxlib.toBase(amount, rate);
  };
  conv.base = base;
  conv.rates = rates;
  conv.asOf = asOf;
  conv.manual = manual;
  conv.missing = missing;
  return conv;
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
 * 实物估值汇总（口径见文件头第 5 条）。`counted` 是家庭设置里的全局开关。
 * @returns {{valueCents: number, includedCents: number, count: number, counted: boolean}}
 */
function physicalOverview(db, conv) {
  const rows = db.all('SELECT * FROM assets WHERE deleted_at IS NULL AND archived = 0').map((r) => rowToJson(r));
  return {
    ...valuation.summarizePhysical(rows, valuation.localToday(), conv ? (v, a) => conv(v, a.currency) : null),
    counted: settings.currentSettings(db).assets.netWorthIncludesPhysical !== false,
  };
}

/**
 * 首页要的全部数字：净资产、本月聚合、待确认笔数、每个账户与基金的余额。
 * @param {object} db lib/db.js 的句柄
 * @param {string} [month] `YYYY-MM`，默认服务器本地时区的当前月
 */
/** 实物估值按币种分开（原生金额，不折算）：各币种一份 {valueCents, includedCents, count}。 */
function physicalByCurrency(db) {
  const rows = db.all('SELECT * FROM assets WHERE deleted_at IS NULL AND archived = 0').map((r) => rowToJson(r));
  const groups = new Map();
  for (const r of rows) {
    const cur = r.currency || 'CNY';
    if (!groups.has(cur)) groups.set(cur, []);
    groups.get(cur).push(r);
  }
  const out = new Map();
  for (const [cur, list] of groups) out.set(cur, valuation.summarizePhysical(list, valuation.localToday()));
  return out;
}

/** 总览发现缺汇率时的钩子（modules/fx.js 在 statsModule 里接上 ctx.fx.kick）；默认什么都不做。 */
const statsHooks = { onMissingRates: () => {} };

function computeOverview(db, month = currentMonth()) {
  const base = baseCurrency(db);
  const conv = makeConverter(db, base);
  const accountDelta = sql.deltaMap(db, 'account');
  const fundBalances = sql.fundBalancesByCurrency(db);

  /**
   * 每个币种一份原生金额的分项（不折算）：客户端按币种分行显示合计，人民币、美元常驻、其他收起。
   * 折成基准币的老字段（netWorthCents 等）照旧给，= Σ conv(各币种)。
   */
  const buckets = new Map();
  const bucket = (cur) => {
    if (!buckets.has(cur)) {
      buckets.set(cur, {
        assetsCents: 0, liabilitiesCents: 0, cashCents: 0, investAccountsCents: 0, investNetCents: 0,
        investMarketCents: 0, investCostCents: 0, physicalValueCents: 0, physicalIncludedCents: 0,
        debts: { receivableCents: 0, payableCents: 0, countedReceivableCents: 0, countedPayableCents: 0 },
        monthExpenseCents: 0, monthIncomeCents: 0,
      });
    }
    return buckets.get(cur);
  };

  // 归档的也给 —— 归档只是「别在记账时挑到它」，钱还在里面。债务的内部账户（kind = 'debt'）也在列，
  // App 靠它的余额算每笔债务还剩多少。
  const accountRows = db.all(
    'SELECT id, kind, currency, initial_balance_cents, value_cents, archived FROM accounts WHERE deleted_at IS NULL' +
      ' ORDER BY sort_order, created_at',
  );
  // 每个账户的 balanceCents 是它自己币种的原生值（流水就记在这个币种里）；只在往折成基准币的分项累加时才用 conv。
  const accounts = accountRows.map((r) => ({
    accountId: r.id,
    currency: r.currency || base,
    balanceCents: (Number(r.initial_balance_cents) || 0) + (accountDelta.get(r.id) || 0),
  }));
  // 板块没有币种：余额按币种分开（balances，原生），balanceCents 是折成基准币的合计（预算、进度条用）。
  const funds = db
    .all('SELECT id FROM funds WHERE deleted_at IS NULL ORDER BY sort_order, created_at')
    .map((r) => {
      const byCur = fundBalances.get(r.id) || new Map();
      let total = 0;
      const balances = {};
      for (const [cur, cents] of byCur) {
        balances[cur] = cents;
        total += conv(cents, cur);
      }
      return { fundId: r.id, balanceCents: total, balances };
    });

  // 债务账户 → 它那笔债务（方向、计不计入净资产）。账户在、债务被删了的不会有（删债务连账户一起删）。
  const debtByAccount = new Map(
    db.all('SELECT account_id, direction, counted FROM debts WHERE deleted_at IS NULL AND account_id IS NOT NULL')
      .map((d) => [d.account_id, d]),
  );
  const kindById = new Map(accountRows.map((r) => [r.id, r.kind]));
  // 股票账户填过的市值（原生币）；没填过的不在这里，按投入算。
  const valueById = new Map(
    accountRows.filter((r) => r.kind === 'stock' && r.value_cents !== null).map((r) => [r.id, Number(r.value_cents) || 0]),
  );

  // 正余额是资产，负余额（通常是信用卡的欠款）取绝对值进负债。信用卡还成正数
  // 了（多还了钱）就照样是资产 —— 按余额的正负分，不按账户类型分。
  // 分项：现金流 = 非投资、非债务账户；投资账户、股票账户单列（证券户里的钱算理财）；债务按方向分应收、应付，
  // 只有「计入净资产」的进资产负债（人情默认不计）。原生金额进各币种的桶，折算后进基准币的合计。
  let assetsCents = 0;
  let liabilitiesCents = 0;
  let cashCents = 0;
  let investAccountsCents = 0;
  const debts = { receivableCents: 0, payableCents: 0, countedReceivableCents: 0, countedPayableCents: 0, count: 0 };
  /** 股票账户：余额（投入）和填过的市值都是原生币，下面和持仓一起进理财分项。 */
  const stockAccounts = [];
  // 归档的股票账户当作销了户：投入（余额）和别的归档账户一样还算钱，但旧市值不再补浮盈、也不进 investByKind
  //（App 的理财估值同样只看没归档的）。
  const archivedIds = new Set(accountRows.filter((r) => r.archived).map((r) => r.id));
  for (const a of accounts) {
    const kind = kindById.get(a.accountId);
    const b = bucket(a.currency);
    const native = a.balanceCents;
    const bal = conv(native, a.currency);
    if (kind === 'debt') {
      const d = debtByAccount.get(a.accountId);
      if (!d) continue;
      debts.count++;
      debts.receivableCents += Math.max(0, bal);
      debts.payableCents += Math.max(0, -bal);
      b.debts.receivableCents += Math.max(0, native);
      b.debts.payableCents += Math.max(0, -native);
      if (!d.counted) continue;
      debts.countedReceivableCents += Math.max(0, bal);
      debts.countedPayableCents += Math.max(0, -bal);
      b.debts.countedReceivableCents += Math.max(0, native);
      b.debts.countedPayableCents += Math.max(0, -native);
    } else if (kind === 'invest' || kind === 'stock') {
      investAccountsCents += bal;
      b.investAccountsCents += native;
      if (kind === 'stock' && !archivedIds.has(a.accountId)) {
        stockAccounts.push({ currency: a.currency, balanceCents: native, valueCents: valueById.get(a.accountId) ?? null });
      }
    } else {
      cashCents += bal;
      b.cashCents += native;
    }
    if (bal >= 0) assetsCents += bal;
    else liabilitiesCents -= bal;
    if (native >= 0) b.assetsCents += native;
    else b.liabilitiesCents -= native;
  }

  // 挂的账户被删了，成本也跟着从余额里消失了，只能按没挂账户整份算。调整记在资产一侧，
  // 「净资产 = 资产 − 负债」才不会在首页对不上。
  const liveAccounts = new Set(accounts.map((a) => a.accountId));
  let investMarketCents = 0;
  let investCostCents = 0;
  let investNetCents = 0;
  /** @type {Map<string, {kind: string, valueCents: number, costCents: number, count: number}>} */
  const byKind = new Map();
  for (const p of sql.investPositions(db, valuation.localToday())) {
    const market = conv(p.marketCents, p.currency);
    const cost = conv(p.costCents, p.currency);
    investMarketCents += market;
    investCostCents += cost;
    const linked = p.accountId && liveAccounts.has(p.accountId);
    const net = linked ? market - cost : market;
    investNetCents += net;
    assetsCents += net;
    const b = bucket(p.currency);
    const nativeNet = linked ? p.marketCents - p.costCents : p.marketCents;
    b.investMarketCents += p.marketCents;
    b.investCostCents += p.costCents;
    b.investNetCents += nativeNet;
    b.assetsCents += nativeNet;
    const k = byKind.get(p.kind) || { kind: p.kind, valueCents: 0, costCents: 0, count: 0 };
    k.valueCents += market;
    k.costCents += cost;
    k.count++;
    byKind.set(p.kind, k);
  }
  // 股票账户按整户市值记（口径第 4 条）：投入已经在 investAccountsCents 里（账户余额），填过市值的只补浮盈
  // （市值 − 余额，可为负），和挂了账户的持仓同一个算法；没填过市值的不多算也不少算。
  // investByKind 里和逐只记的股票持仓合在同一个 'stock' 下，没市值的按投入当估值。
  for (const s of stockAccounts) {
    const k = byKind.get('stock') || { kind: 'stock', valueCents: 0, costCents: 0, count: 0 };
    k.valueCents += conv(s.valueCents ?? s.balanceCents, s.currency);
    k.costCents += conv(s.balanceCents, s.currency);
    k.count++;
    byKind.set('stock', k);
    if (s.valueCents === null) continue;
    const market = conv(s.valueCents, s.currency);
    const cost = conv(s.balanceCents, s.currency);
    investMarketCents += market;
    investCostCents += cost;
    investNetCents += market - cost;
    assetsCents += market - cost;
    const b = bucket(s.currency);
    b.investMarketCents += s.valueCents;
    b.investCostCents += s.balanceCents;
    b.investNetCents += s.valueCents - s.balanceCents;
    b.assetsCents += s.valueCents - s.balanceCents;
  }

  const netWorthExPhysicalCents = assetsCents - liabilitiesCents;
  const physical = physicalOverview(db, conv);
  if (physical.counted) assetsCents += physical.includedCents;
  for (const [cur, s] of physicalByCurrency(db)) {
    const b = bucket(cur);
    b.physicalValueCents += s.valueCents;
    b.physicalIncludedCents += s.includedCents;
  }

  const totals = sql.monthSums(db, month, undefined, conv);
  for (const m of sql.monthSumsByCurrency(db, month)) {
    const b = bucket(m.currency);
    b.monthExpenseCents += m.expenseCents;
    b.monthIncomeCents += m.incomeCents;
  }
  const fundSpent = new Map(sql.expenseByColumn(db, month, 'fund_id', undefined, conv).map((r) => [r.ref, r.expenseCents]));
  const categorySpent = new Map(sql.expenseByColumn(db, month, 'category_id', undefined, conv).map((r) => [r.ref, r.expenseCents]));

  const budgets = resolvedBudgets(db, month).map((b) => ({
    ...b,
    spentCents: (b.scope === 'fund' ? fundSpent.get(b.refId) : categorySpent.get(b.refId)) || 0,
  }));
  // 只在板块上填了「月预算」、没单独建预算行的，也要出现在这张表里：客户端的
  // 板块卡片靠它画进度条。
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

  // 各币种的净资产 = 资产 − 负债（+ 计入的实物）。全是 0 的币种不给（建过又清空的美元户不该占一行）。
  const byCurrency = {};
  for (const [cur, b] of [...buckets.entries()].sort((x, y) => cmp(x[0], y[0]))) {
    const netWorthExPhysicalCents = b.assetsCents - b.liabilitiesCents;
    const netWorthCents = netWorthExPhysicalCents + (physical.counted ? b.physicalIncludedCents : 0);
    const all = [netWorthCents, b.cashCents, b.investAccountsCents, b.investNetCents, b.investMarketCents,
      b.physicalValueCents, b.monthExpenseCents, b.monthIncomeCents, b.debts.receivableCents, b.debts.payableCents];
    if (all.every((x) => x === 0)) continue;
    byCurrency[cur] = { ...b, netWorthExPhysicalCents, netWorthCents };
  }

  // 用到的币种没有汇率：后台补抓一次（折成基准币的合计里那部分暂按 0）。
  if (conv.missing.size > 0) statsHooks.onMissingRates();

  return {
    netWorthCents: assetsCents - liabilitiesCents,
    assetsCents,
    liabilitiesCents,
    investMarketCents,
    investCostCents,
    investGainCents: investMarketCents - investCostCents,
    // 净资产的分项（加起来 = netWorthExPhysicalCents）：现金流 + 投资账户 + 投资补差 + 计入的债务净额。
    cashCents,
    investAccountsCents,
    investNetCents,
    investByKind: [...byKind.values()].sort((x, y) => y.valueCents - x.valueCents || cmp(x.kind, y.kind)),
    debts,
    netWorthExPhysicalCents,
    physical,
    byCurrency,
    month: {
      expenseCents: totals.expenseCents,
      incomeCents: totals.incomeCents,
      byFund: sql.totalsByColumn(db, month, 'fund_id', undefined, conv).map((r) => ({
        fundId: r.ref,
        expenseCents: r.expenseCents,
        incomeCents: r.incomeCents,
      })),
      byCategory: sql
        .expenseByColumn(db, month, 'category_id', undefined, conv)
        .map((r) => ({ categoryId: r.ref, expenseCents: r.expenseCents })),
      byMember: sql
        .expenseByColumn(db, month, 'member_id', undefined, conv)
        .map((r) => ({ memberId: r.ref, expenseCents: r.expenseCents })),
      budgets,
    },
    pendingCount: Number(pending && pending.n) || 0,
    funds,
    accounts,
    // 内嵌汇率：客户端拿它做与服务端一致的折算，杜绝两边数字对不上；missing 是抓不到汇率的币种。
    fx: { base, asOf: conv.asOf, rates: conv.rates, missing: [...conv.missing], manual: conv.manual },
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

  // 趋势是跨币种、跨月的支出/收入合计，一律折到基准币再画柱子。
  const conv = makeConverter(db, baseCurrency(db));
  const found = new Map(sql.monthlyTotals(db, from, end, { fundId, categoryId }, conv).map((r) => [r.month, r]));
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
 * 板块详情页要的一切。`recent` 不限月份也不限状态（待确认的正是要在这里被看到
 * 并确认的），其余数字都只算这个月、只算确认的流水。
 * @throws {HttpError} 404 not_found —— 板块不存在或已软删
 */
function computeFundStats(db, fundId, month = currentMonth()) {
  const fund = db.get('SELECT * FROM funds WHERE id = ? AND deleted_at IS NULL', fundId);
  if (!fund) throw new HttpError(404, 'not_found', '板块不存在');

  const base = baseCurrency(db);
  const conv = makeConverter(db, base);
  // 余额按币种分开（balances，原生）；balanceCents 和月度支出、分类是折成基准币的合计。
  const totals = sql.monthSums(db, month, { fundId }, conv);
  const monthlyBudgetCents = fund.monthly_budget_cents === null ? null : Number(fund.monthly_budget_cents);
  const budgetRow = budgetFor(db, month, 'fund', fundId);
  const balances = {};
  let balanceCents = 0;
  for (const [cur, cents] of sql.fundBalancesByCurrency(db, fundId).get(fundId) || new Map()) {
    balances[cur] = cents;
    balanceCents += conv(cents, cur);
  }

  return {
    fundId,
    balanceCents,
    balances,
    targetCents: fund.target_cents === null ? null : Number(fund.target_cents),
    monthlyBudgetCents,
    budgetCents: budgetRow === null ? monthlyBudgetCents : budgetRow,
    monthExpenseCents: totals.expenseCents,
    monthIncomeCents: totals.incomeCents,
    byCategory: sql
      .expenseByColumn(db, month, 'category_id', { fundId }, conv)
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
  // 每天的热力值也是跨币种合计，折到基准币。
  const conv = makeConverter(db, baseCurrency(db));
  return { days: sql.dailyTotals(db, month, undefined, conv) };
}

function statsModule(ctx) {
  const { db } = ctx;
  // 缺汇率时让汇率模块后台补抓（fx.js 按字母序先加载，ctx.fx 这时已经在了）。
  statsHooks.onMissingRates = () => ctx.fx?.kick?.();

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
module.exports.statsHooks = statsHooks;
module.exports.budgetFor = budgetFor;
module.exports.resolvedBudgets = resolvedBudgets;
