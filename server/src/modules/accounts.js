'use strict';

// 账户 = 钱实际待着的地方（现金、储蓄卡、支付宝…）。余额不存在这张表里：
// 它永远是 initialBalanceCents + Σ流水，由 stats 现算。「校准余额」= PATCH currentBalanceCents
// （现在实际有多少），差额进 initialBalanceCents，不多记流水。

const { HttpError } = require('../lib/router');
const { makeCrud, currencyColumns } = require('../lib/crud');
const sql = require('../lib/stats_sql');
const v = require('../lib/validate');

const KINDS = ['cash', 'bank', 'alipay', 'wechat', 'credit', 'invest', 'other'];

module.exports = (ctx) => {
  const { db } = ctx;

  const crud = makeCrud({
    db,
    table: 'accounts',
    resource: 'accounts',
    singular: 'account',
    label: '账户',
    fields: {
      name: { type: 'string', required: true, max: 40 },
      kind: { type: 'enum', values: KINDS, default: 'other' },
      ownerMemberId: { type: 'id' },
      initialBalanceCents: { type: 'int', min: -1e14, max: 1e14, default: 0 },
      icon: { type: 'string', max: 40 },
      color: { type: 'color' },
      matchHints: { type: 'json', max: 2000, default: '{}' },
    },

    // `currency` is not a plain field: a new account inherits the household's
    // currency rather than the column default, and it is always upper-cased.
    // 币种建好后有了流水就锁定：旧流水记的是旧币种，改了余额就是两种钱混着加。
    fromBody(body, isPatch, row) {
      const out = currencyColumns(db, body, isPatch);
      // 债务的内部账户：余额就是「还剩多少」，到债务里改（会留一行备忘）；类型改了它就成了普通账户。
      if (isPatch && row.kind === 'debt') {
        for (const f of ['initialBalanceCents', 'currentBalanceCents']) {
          if (body[f] !== undefined) v.bad(f, '这是债务的账户：还剩多少到「资产 › 债务」里改');
        }
        if (body.kind !== undefined) v.bad('kind', '这是债务的账户，不能改类型');
      }
      if (!v.isMissing(body.currentBalanceCents)) {
        const target = v.int(body.currentBalanceCents, 'currentBalanceCents', { min: -1e14, max: 1e14 });
        const flows = row ? sql.deltaMap(db, 'account', row.id).get(row.id) || 0 : 0;
        if (Math.abs(target - flows) > 1e14) v.bad('currentBalanceCents', '差得太多了');
        out.initial_balance_cents = target - flows;
      }
      if (isPatch && out.currency && out.currency !== row.currency) {
        if (row.kind === 'debt') v.bad('currency', '债务的内部账户跟着债务走，不能单独改币种');
        const used = db.get(
          'SELECT 1 AS ok FROM transactions WHERE deleted_at IS NULL AND (account_id = ? OR to_account_id = ?) LIMIT 1',
          row.id, row.id,
        );
        if (used) {
          throw new HttpError(409, 'currency_locked', '这个账户已经有流水了，不能改币种；换币种请新建一个账户');
        }
      }
      return out;
    },

    canDelete(row) {
      // 债务的内部账户（modules/debts.js）跟着债务删，从这里删掉债务就没了余额。
      if (row.kind === 'debt') {
        throw new HttpError(409, 'account_is_debt', '这是一笔债务的账户，到「资产 › 债务」里删');
      }
      const used = db.get(
        "SELECT 1 AS ok FROM transactions WHERE deleted_at IS NULL AND status = 'confirmed'" +
          ' AND (account_id = ? OR to_account_id = ?) LIMIT 1',
        row.id, row.id,
      );
      if (used) {
        throw new HttpError(409, 'account_in_use', '该账户下已有流水，不能删除；可以改成「归档」');
      }
    },
  });

  return { name: 'accounts', routes: crud.routes };
};
