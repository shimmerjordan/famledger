'use strict';

// 预算：`(scope, refId, month)` 三元组唯一。`month = '*'` 是「每月默认」，具体
// 月份的行覆盖它 —— 所以 `GET /budgets?month=2026-09` 返回的是「本月生效值」，
// 每个 refId 只给一条。没有单独的 POST/PATCH/DELETE：一个 PUT 就是 upsert，
// `amountCents: null` 表示把这条去掉（软删，同步得看得见墓碑）。

const crypto = require('node:crypto');

const { sendJson } = require('../lib/router');
const { rowToJson } = require('../lib/db');
const v = require('../lib/validate');

const SCOPES = ['fund', 'category'];
const toJson = (row) => rowToJson(row);

module.exports = (ctx) => {
  const { db } = ctx;

  /** `month` 精确 > `'*'` 默认。 */
  function list(req, res, reqCtx) {
    const month = reqCtx.query.month === undefined || reqCtx.query.month === ''
      ? null
      : v.month(reqCtx.query.month, 'month');

    if (!month) {
      const rows = db.all('SELECT * FROM budgets WHERE deleted_at IS NULL ORDER BY scope, ref_id, month');
      return sendJson(res, 200, { items: rows.map(toJson) });
    }

    const rows = db.all(
      "SELECT * FROM budgets WHERE deleted_at IS NULL AND month IN (?, '*') ORDER BY scope, ref_id, month",
      month,
    );
    const winner = new Map();
    for (const row of rows) {
      const key = `${row.scope}/${row.ref_id}`;
      if (!winner.has(key) || row.month === month) winner.set(key, row);
    }
    sendJson(res, 200, { items: [...winner.values()].map(toJson) });
  }

  function upsert(req, res, reqCtx) {
    const b = v.body(reqCtx.body);
    const scope = v.enumOf(b.scope, 'scope', SCOPES);
    const refId = v.str(b.refId, 'refId', { max: 64 });
    const month = v.month(b.month, 'month', { allowStar: true });
    const amountCents = v.isMissing(b.amountCents) ? null : v.int(b.amountCents, 'amountCents', { min: 0, max: 1e14 });

    const row = db.tx(() => {
      const now = db.now();
      // Look past the tombstone: UNIQUE(scope, ref_id, month) still holds the
      // slot, so a deleted row has to be revived rather than inserted again.
      const found = db.get('SELECT * FROM budgets WHERE scope = ? AND ref_id = ? AND month = ?', scope, refId, month);
      if (!found && amountCents === null) return null;

      if (found) {
        db.run(
          'UPDATE budgets SET amount_cents = ?, deleted_at = ?, updated_at = ?, seq = ? WHERE id = ?',
          amountCents === null ? found.amount_cents : amountCents,
          amountCents === null ? now : null,
          now, db.nextSeq(), found.id,
        );
        return db.get('SELECT * FROM budgets WHERE id = ?', found.id);
      }
      const id = crypto.randomUUID();
      db.run(
        'INSERT INTO budgets(id, scope, ref_id, month, amount_cents, created_at, updated_at, seq) VALUES(?, ?, ?, ?, ?, ?, ?, ?)',
        id, scope, refId, month, amountCents, now, now, db.nextSeq(),
      );
      return db.get('SELECT * FROM budgets WHERE id = ?', id);
    });

    sendJson(res, 200, { budget: row ? toJson(row) : null });
  }

  return {
    name: 'budgets',
    routes: [
      { method: 'GET', pattern: '/budgets', handler: list, maxBody: 0 },
      { method: 'PUT', pattern: '/budgets', handler: upsert },
    ],
  };
};
