'use strict';

// 账户 = 钱实际待着的地方（现金、储蓄卡、支付宝…）。余额不存在这张表里：
// 它永远是 initialBalanceCents + Σ流水，由 stats 现算。

const { HttpError } = require('../lib/router');
const { makeCrud } = require('../lib/crud');
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
    fromBody(body, isPatch) {
      if (body.currency === undefined || body.currency === null) {
        return isPatch ? {} : { currency: db.meta('currency', 'CNY') };
      }
      const cur = v.str(body.currency, 'currency', { min: 3, max: 3 }).toUpperCase();
      if (!/^[A-Z]{3}$/.test(cur)) v.bad('currency', '币种必须是 3 个字母的代码');
      return { currency: cur };
    },

    canDelete(row) {
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
