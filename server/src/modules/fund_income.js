'use strict';

// 板块的「每月固定进账」：每月 income_day 号往 income_account_id 记一笔**真实的**收入流水
// （类别 income_category_id，没设就用「工资」，没有「工资」就建一个），落在这个板块里。
// 家里接不了银行，工资本来就靠手记；开了它就不用每月手记，也不会重复（表单上说了别再手记）。
//
//   · 什么时候跑：服务启动时、每小时、以及板块保存后（funds.js 的 onWrite 调 ctx.fundIncome.runFund）。
//   · 记哪几个月：从起算月到本月，凡是「那个月的到账日已经到了」的；一次最多往回补 24 个月。
//   · 幂等：生成过的月份记进 fund_income_runs（主键 fund_id + month），永不重来 —— 用户删掉某个月那笔，
//     也不会被补回来。流水本身也带 clientId `fund-income:<板块>:<月份>`，双保险。
//   · 改额度、换账户只影响以后的月份（以前的是真流水，照常在）；清空金额 = 不再生成。
//   · 币种跟账户走（transactions.js 强制），金额就是那个账户币种的金额。

const crypto = require('node:crypto');
const v = require('../lib/validate');

const MAX_BACKFILL_MONTHS = 24;
const DEFAULT_TICK_MS = 60 * 60 * 1000;

/** `YYYY-MM` 往前 / 往后挪 n 个月。 */
function shiftMonth(month, n) {
  const idx = Number(month.slice(0, 4)) * 12 + Number(month.slice(5, 7)) - 1 + n;
  return `${String(Math.floor(idx / 12)).padStart(4, '0')}-${String((idx % 12) + 1).padStart(2, '0')}`;
}

/**
 * 到 `today`（`YYYY-MM-DD`，服务器本地日）为止该记的月份：起算月 ~ 最近一个「到账日已到」的月，
 * 最多 24 个。起算月没填按本月。
 */
function dueMonths(fund, today) {
  const day = Number(fund.income_day) || 1;
  const thisMonth = today.slice(0, 7);
  const last = Number(today.slice(8, 10)) >= day ? thisMonth : shiftMonth(thisMonth, -1);
  const start = fund.income_start_month || thisMonth;
  const floor = shiftMonth(last, -(MAX_BACKFILL_MONTHS - 1));
  const out = [];
  for (let m = start < floor ? floor : start; m <= last; m = shiftMonth(m, 1)) out.push(m);
  return out;
}

module.exports = (ctx) => {
  const { db, log } = ctx;
  let timer = null;

  const alive = (table, id) => !!(id && db.get(`SELECT 1 AS ok FROM ${table} WHERE id = ? AND deleted_at IS NULL`, id));

  /** 记成什么类别：规则里指定的（还在、是收入类）> 名叫「工资」的收入类别 > 当场建一个「工资」。 */
  function salaryCategoryId(preferred) {
    if (preferred && db.get("SELECT 1 AS ok FROM categories WHERE id = ? AND kind = 'income' AND deleted_at IS NULL", preferred)) {
      return preferred;
    }
    const found = db.get(
      "SELECT id FROM categories WHERE name = '工资' AND kind = 'income' AND deleted_at IS NULL ORDER BY archived, sort_order LIMIT 1",
    );
    if (found) return found.id;
    const id = crypto.randomUUID();
    const now = db.now();
    const sort = db.get('SELECT MAX(sort_order) AS m FROM categories WHERE deleted_at IS NULL');
    db.run(
      'INSERT INTO categories(id, name, kind, parent_id, icon, color, sort_order, archived, created_at, updated_at, seq)' +
        ' VALUES(?, ?, ?, NULL, ?, ?, ?, 0, ?, ?, ?)',
      id, '工资', 'income', 'payments', '#3f8f6b', (typeof sort?.m === 'number' ? sort.m : -1) + 1, now, now, db.nextSeq(),
    );
    return id;
  }

  /** 这笔流水记在谁名下：设规则的那个人；他不在了就记给最早的管理员。 */
  function memberFor(fund) {
    if (alive('members', fund.income_member_id)) return fund.income_member_id;
    const admin = db.get("SELECT id FROM members WHERE role = 'admin' AND deleted_at IS NULL ORDER BY created_at LIMIT 1");
    return admin ? admin.id : null;
  }

  /**
   * 给一个板块补记到今天为止该记的月份，返回这次新记了几笔。规则不全、板块归档、账户没了就什么都不做。
   * 在一个事务里：先记流水再登记月份，任何一步出错整批回滚（下次再试，不会漏也不会重）。
   */
  function runFund(fundId, today = v.localDay()) {
    const fund = db.get('SELECT * FROM funds WHERE id = ? AND deleted_at IS NULL', fundId);
    if (!fund || fund.archived || !(Number(fund.monthly_income_cents) > 0)) return 0;
    if (!alive('accounts', fund.income_account_id)) return 0;
    const months = dueMonths(fund, today).filter(
      (m) => !db.get('SELECT 1 AS ok FROM fund_income_runs WHERE fund_id = ? AND month = ?', fund.id, m),
    );
    if (months.length === 0) return 0;
    const memberId = memberFor(fund);
    if (!memberId) return 0;
    return db.tx(() => {
      const categoryId = salaryCategoryId(fund.income_category_id);
      const day = String(Number(fund.income_day) || 1).padStart(2, '0');
      for (const month of months) {
        const { row } = ctx.createTransaction({
          clientId: `fund-income:${fund.id}:${month}`,
          type: 'income',
          amountCents: Number(fund.monthly_income_cents),
          occurredAt: `${month}-${day}T09:00:00+08:00`,
          accountId: fund.income_account_id,
          fundId: fund.id,
          categoryId,
          memberId,
          merchant: fund.name,
          note: '每月固定进账',
          source: 'recurring',
        }, { member: { id: memberId }, query: {} });
        db.run(
          'INSERT INTO fund_income_runs(fund_id, month, transaction_id, created_at) VALUES(?, ?, ?, ?)',
          fund.id, month, row.id, db.now(),
        );
      }
      return months.length;
    });
  }

  /** 所有设了规则的板块各补一遍；一个出错只记日志，不挡别的。 */
  function runAll(today = v.localDay()) {
    let made = 0;
    for (const f of db.all('SELECT id FROM funds WHERE deleted_at IS NULL AND archived = 0 AND monthly_income_cents > 0')) {
      try {
        made += runFund(f.id, today);
      } catch (e) {
        log.error('fund_income', `板块 ${f.id} 的每月进账没记上：${e.stack || e}`);
      }
    }
    if (made > 0) log.info('fund_income', `补记了 ${made} 笔每月固定进账`);
    return made;
  }

  ctx.fundIncome = { runFund };

  return {
    name: 'fund_income',
    routes: [],
    start() {
      const ms = Number(process.env.FUND_INCOME_TICK_MS) > 0 ? Number(process.env.FUND_INCOME_TICK_MS) : DEFAULT_TICK_MS;
      timer = setInterval(() => runAll(), ms);
      timer.unref();
      setTimeout(() => runAll(), 0).unref();
    },
    stop() {
      if (timer) clearInterval(timer);
      timer = null;
    },
    runFund,
    runAll,
  };
};

module.exports.dueMonths = dueMonths;
module.exports.shiftMonth = shiftMonth;
