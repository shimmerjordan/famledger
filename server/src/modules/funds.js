'use strict';

// 板块（App 里「我的 › 财富」，代码里仍叫 fund）= 这笔钱「属于哪件事」（家庭公共、个人零花、育儿…）。
// 账户回答钱在哪，板块回答钱归谁管 —— 一笔支出同时从某个账户和某个板块里扣。
// 板块可以挂「每月固定进账」规则：每月某天往某个账户记一笔真的收入（工资），生成见 fund_income.js。
// 余额 = 期初（按币种，opening_balances）+ 流水。「校准余额」= PATCH currentBalances（现在实际有多少），
// 差额进期初：不多记流水，不进月收支。

const { HttpError, sendJson } = require('../lib/router');
const { makeCrud } = require('../lib/crud');
const { rowToJson } = require('../lib/db');
const sql = require('../lib/stats_sql');
const v = require('../lib/validate');
const { FUND_TEMPLATES, PALETTE } = require('./seed');

const KINDS = ['personal', 'shared', 'goal', 'reserve', 'custom'];
const MAX_AMOUNT = 1e14;

/** `{"CNY": 1200, "USD": -50}` → `Map<币种, 分>`：键是 3 位币种代码，值是 ±1e14 以内的整数分。 */
function balanceMap(raw, field) {
  if (!v.isObject(raw)) v.bad(field, `${field} 要写成 {"CNY": 分, …}`);
  const entries = Object.entries(raw);
  if (entries.length > 30) v.bad(field, `${field} 币种太多了`);
  const out = new Map();
  for (const [k, n] of entries) out.set(v.currency(k, field), v.int(n, field, { min: -MAX_AMOUNT, max: MAX_AMOUNT }));
  return out;
}

const openingsJson = (m) =>
  JSON.stringify(Object.fromEntries([...m].filter(([, c]) => c !== 0).sort((a, b) => (a[0] < b[0] ? -1 : 1))));

module.exports = (ctx) => {
  const { db } = ctx;

  const crud = makeCrud({
    db,
    table: 'funds',
    resource: 'funds',
    singular: 'fund',
    label: '板块',
    toJson: (row) => rowToJson(row, { bools: ['archived', 'is_default'], json: ['opening_balances'] }),
    fields: {
      name: { type: 'string', required: true, max: 40 },
      kind: { type: 'enum', values: KINDS, default: 'custom' },
      ownerMemberId: { type: 'id' },
      icon: { type: 'string', max: 40 },
      // funds.color is NOT NULL — when the client sends none, take the next
      // palette entry so two funds created in a row do not look alike.
      color: { type: 'color', default: () => PALETTE[(db.get('SELECT COUNT(*) AS n FROM funds').n || 0) % PALETTE.length] },
      targetCents: { type: 'int', min: 0, max: 1e14 },
      monthlyBudgetCents: { type: 'int', min: 0, max: 1e14 },
      // 「每月固定进账」的金额（分，按进账账户的币种）；空值 / 0 = 不自动进账。其余规则字段走下面的 fromBody。
      monthlyIncomeCents: { type: 'int', min: 0, max: 1e14 },
      description: { type: 'string', max: 500 },
      isDefault: { type: 'bool', default: false },
    },

    /**
     * 每月进账规则：到账日 1–28（避开大小月）、进哪个账户（真账户，不能是债务的内部账户）、记成什么类别
     * （收入类，选填）、从哪个月起（`YYYY-MM`，默认本月）。开着规则（金额 > 0）时账户必填。
     * 未传的字段不动；传 null / 空串清掉。
     */
    fromBody(body, isPatch, row) {
      const out = {};
      const given = (k) => body[k] !== undefined;
      const blank = (k) => v.isMissing(body[k]) || body[k] === '';
      if (given('incomeStartMonth')) out.income_start_month = blank('incomeStartMonth') ? null : v.month(body.incomeStartMonth, 'incomeStartMonth');
      if (given('incomeDay')) out.income_day = blank('incomeDay') ? null : v.int(body.incomeDay, 'incomeDay', { min: 1, max: 28 });
      if (given('incomeAccountId')) {
        if (blank('incomeAccountId')) out.income_account_id = null;
        else {
          const id = v.str(body.incomeAccountId, 'incomeAccountId', { max: 64 });
          if (!db.get("SELECT 1 AS ok FROM accounts WHERE id = ? AND deleted_at IS NULL AND kind != 'debt'", id)) {
            v.bad('incomeAccountId', '进账账户不存在');
          }
          out.income_account_id = id;
        }
      }
      if (given('incomeCategoryId')) {
        if (blank('incomeCategoryId')) out.income_category_id = null;
        else {
          const id = v.str(body.incomeCategoryId, 'incomeCategoryId', { max: 64 });
          if (!db.get("SELECT 1 AS ok FROM categories WHERE id = ? AND kind = 'income' AND deleted_at IS NULL", id)) {
            v.bad('incomeCategoryId', '只能记成一个收入类别');
          }
          out.income_category_id = id;
        }
      }
      // 期初余额：openingBalances 整份替换；currentBalances（「现在实际有多少」）只改给了的币种，
      // 期初 = 目标 − 这个币种的流水合计。两个都给时先替换再校准。
      if (given('openingBalances') || given('currentBalances')) {
        const oldOpen = sql.parseOpenings(row?.opening_balances);
        const open = given('openingBalances') ? balanceMap(body.openingBalances, 'openingBalances') : new Map(oldOpen);
        if (given('currentBalances')) {
          const now = row ? sql.fundBalancesByCurrency(db, row.id).get(row.id) || new Map() : new Map();
          for (const [cur, target] of balanceMap(body.currentBalances, 'currentBalances')) {
            const flows = (now.get(cur) || 0) - (oldOpen.get(cur) || 0);
            if (Math.abs(target - flows) > MAX_AMOUNT) v.bad('currentBalances', '差得太多了');
            open.set(cur, target - flows);
          }
        }
        out.opening_balances = openingsJson(open);
      }

      const amount = given('monthlyIncomeCents') ? Number(body.monthlyIncomeCents) || 0 : Number(row?.monthly_income_cents) || 0;
      if (amount > 0) {
        const account = 'income_account_id' in out ? out.income_account_id : row?.income_account_id;
        if (!account) v.bad('incomeAccountId', '每月进账要选进哪个账户');
        if (!('income_day' in out ? out.income_day : row?.income_day)) out.income_day = 1;
        if (!('income_start_month' in out ? out.income_start_month : row?.income_start_month)) {
          out.income_start_month = v.localDay().slice(0, 7);
        }
      }
      return out;
    },

    /**
     * 只能有一个默认板块：谁设成默认就把别的取消。开着每月进账：记下是谁设的（流水记在他名下），
     * 再补记到今天为止该记的月份（同一个事务，出错整个保存回滚）。
     */
    onWrite(row, { reqCtx }) {
      const now = db.now();
      if (row.is_default) {
        for (const o of db.all('SELECT id FROM funds WHERE id != ? AND is_default = 1', row.id)) {
          db.run('UPDATE funds SET is_default = 0, updated_at = ?, seq = ? WHERE id = ?', now, db.nextSeq(), o.id);
        }
      }
      if (Number(row.monthly_income_cents) > 0) {
        if (!row.income_member_id && reqCtx?.member?.id) {
          db.run('UPDATE funds SET income_member_id = ? WHERE id = ?', reqCtx.member.id, row.id);
        }
        ctx.fundIncome?.runFund(row.id);
      }
    },

    canDelete(row) {
      const used = db.get(
        "SELECT 1 AS ok FROM transactions WHERE deleted_at IS NULL AND status = 'confirmed'" +
          ' AND (fund_id = ? OR to_fund_id = ?) LIMIT 1',
        row.id, row.id,
      );
      if (used) {
        throw new HttpError(409, 'fund_in_use', '这个板块下已有流水，不能删除；可以改成「归档」');
      }
    },
  });

  /** The starting points offered by the "新建板块" sheet. Static, not rows. */
  function templates(req, res) {
    sendJson(res, 200, { items: FUND_TEMPLATES });
  }

  return {
    name: 'funds',
    routes: [
      { method: 'GET', pattern: '/funds/templates', handler: templates, maxBody: 0 },
      ...crud.routes,
    ],
  };
};
