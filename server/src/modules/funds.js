'use strict';

// 基金 = 这笔钱「属于哪件事」（家庭公共、个人零花、育儿…）。账户回答钱在哪，
// 基金回答钱归谁管 —— 一笔支出同时从某个账户和某个基金里扣。

const { HttpError, sendJson } = require('../lib/router');
const { makeCrud } = require('../lib/crud');
const { FUND_TEMPLATES, PALETTE } = require('./seed');

const KINDS = ['personal', 'shared', 'goal', 'reserve', 'custom'];

module.exports = (ctx) => {
  const { db } = ctx;

  const crud = makeCrud({
    db,
    table: 'funds',
    resource: 'funds',
    singular: 'fund',
    label: '基金',
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
      description: { type: 'string', max: 500 },
      isDefault: { type: 'bool', default: false },
    },

    /** At most one default fund: whoever claims it takes it from the others. */
    onWrite(row) {
      if (!row.is_default) return;
      const others = db.all('SELECT id FROM funds WHERE id != ? AND is_default = 1', row.id);
      const now = db.now();
      for (const o of others) {
        db.run('UPDATE funds SET is_default = 0, updated_at = ?, seq = ? WHERE id = ?', now, db.nextSeq(), o.id);
      }
    },

    canDelete(row) {
      const used = db.get(
        "SELECT 1 AS ok FROM transactions WHERE deleted_at IS NULL AND status = 'confirmed'" +
          ' AND (fund_id = ? OR to_fund_id = ?) LIMIT 1',
        row.id, row.id,
      );
      if (used) {
        throw new HttpError(409, 'fund_in_use', '该基金下已有流水，不能删除；可以改成「归档」');
      }
    },
  });

  /** The starting points offered by the "新建基金" sheet. Static, not rows. */
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
