'use strict';

// 债务：借出（别人欠我）、借入（我欠别人）、人情。
//
//   1. 每笔债务背后有一个 kind = 'debt' 的内部账户（「借给 张三」「欠 李四」「人情 王五」），余额就是
//      还剩多少：借出为正、借入为负，和普通账户同一套算法（stats.js），净资产照常按正负号分资产负债，
//      只是 `counted` 关着的（人情默认关）不算进去。账户页、记账时选账户都看不到它（App 按 kind 过滤）。
//   2. 钱经真账户走（「同时记账」）就是普通转账：借出 真账户 → 内部账户、收回 内部账户 → 真账户，
//      借入、还钱反过来。流水照常能改能删，余额跟着变，债务永远和流水对得上。
//   3. 不记流水（以前的旧账、对方抵了、免了）就改内部账户的期初，并在 memo_log 里留一行，
//      详情页把它和流水合在一起按日期排。
//   4. 人情：钱那一边是真花出去 / 收进来的（随礼、收礼），记成普通支出 / 收入（类别「人情」），
//      内部账户只记个数（改期初），所以人情不会把月支出漏掉。
//   5. 新建和收回 / 追加都收 clientId 做幂等：回应丢了 App 重发，钱不能记两遍。

const crypto = require('node:crypto');

const { HttpError, sendJson } = require('../lib/router');
const { makeCrud } = require('../lib/crud');
const { rowToJson } = require('../lib/db');
const { logActivity } = require('../lib/activity');
const idem = require('../lib/idempotency');
const sql = require('../lib/stats_sql');
const v = require('../lib/validate');

const DIRECTIONS = ['lend', 'borrow'];
const KINDS = ['loan', 'credit', 'favor', 'other'];
const MAX_AMOUNT = 1e14;
const MEMO_MAX = 200;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

const txJson = (row) => rowToJson(row, { json: ['tags'] });

function day(raw, field) {
  if (typeof raw !== 'string' || !DATE_RE.test(raw)) v.bad(field, `${field} 必须是 YYYY-MM-DD`);
  const d = new Date(`${raw}T00:00:00Z`);
  if (Number.isNaN(d.getTime()) || d.toISOString().slice(0, 10) !== raw) v.bad(field, `${field} 不是有效日期`);
  return raw;
}

function today() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

// 契约规定流水时间一律带 +08:00；取中午是为了日期在任何一侧偏移下都不会滑到前后一天。
const noonOf = (date) => `${date}T12:00:00+08:00`;

/** 内部账户的名字，流水里显示成「招商银行 → 借给 张三」。 */
function accountName(direction, kind, counterparty) {
  if (kind === 'favor') return `人情 ${counterparty}`;
  return direction === 'lend' ? `借给 ${counterparty}` : `欠 ${counterparty}`;
}

module.exports = (ctx) => {
  const { db } = ctx;

  const realAccount = (id) =>
    db.get("SELECT id FROM accounts WHERE id = ? AND deleted_at IS NULL AND kind != 'debt'", id);

  /** 钱从哪个真账户走：必须存在、不能是另一笔债务的内部账户。 */
  function moneyAccount(raw, field) {
    const id = v.str(raw, field, { max: 64 });
    if (!realAccount(id)) v.bad(field, '账户不存在');
    return id;
  }

  function recordSpec(raw) {
    if (v.isMissing(raw)) return null;
    if (!v.isObject(raw)) v.bad('recordTransaction', 'recordTransaction 必须是对象');
    return raw;
  }

  /** 「人情」类别：种子里有支出的；收入的没有就在当前事务里建一个。 */
  function favorCategoryId(kind) {
    const found = db.get(
      "SELECT id FROM categories WHERE name = '人情' AND kind = ? AND deleted_at IS NULL ORDER BY archived, sort_order LIMIT 1",
      kind,
    );
    if (found) return found.id;
    const id = crypto.randomUUID();
    const now = db.now();
    const sort = db.get('SELECT MAX(sort_order) AS m FROM categories WHERE deleted_at IS NULL');
    db.run(
      'INSERT INTO categories(id, name, kind, parent_id, icon, color, sort_order, archived, created_at, updated_at, seq)' +
        ' VALUES(?, ?, ?, NULL, ?, ?, ?, 0, ?, ?, ?)',
      id, '人情', kind, 'redeem', '#bb6690', (typeof sort?.m === 'number' ? sort.m : -1) + 1, now, now, db.nextSeq(),
    );
    return id;
  }

  /** 走 transactions.js 的同一套校验与写入；它按字母序后加载，所以只能在请求时取。 */
  function record(body, reqCtx) {
    return ctx.createTransaction({ source: 'manual', ...body }, reqCtx).row;
  }

  const balanceOf = (account) =>
    (Number(account.initial_balance_cents) || 0) + (sql.deltaMap(db, 'account', account.id).get(account.id) || 0);

  /**
   * 钱这一次怎么动。`effect` 是对内部账户余额的影响（+ 让「别人欠我」变多 / 「我欠别人」变少）。
   * 有 `accountId`：借款类记一笔转账；人情记一笔支出/收入并改期初。没有：只改期初、留一行备忘。
   * @returns {object[]} 记下的流水
   */
  function move(debt, account, { effect, amount, accountId, occurredOn, merchant, note }, reqCtx) {
    const txs = [];
    if (accountId && debt.kind !== 'favor') {
      const [from, to] = effect > 0 ? [accountId, account.id] : [account.id, accountId];
      txs.push(record({
        type: 'transfer', amountCents: amount, occurredAt: noonOf(occurredOn), accountId: from, toAccountId: to,
        merchant, note: note || '',
      }, reqCtx));
      return { txs, memo: null };
    }
    // 人情的钱：内部余额变多 = 我随礼出去了（支出），变少 = 我收到礼了（收入）。
    if (accountId) {
      const kind = effect > 0 ? 'expense' : 'income';
      txs.push(record({
        type: kind, amountCents: amount, occurredAt: noonOf(occurredOn), accountId,
        categoryId: favorCategoryId(kind), merchant, note: note || '',
      }, reqCtx));
    }
    db.run(
      'UPDATE accounts SET initial_balance_cents = initial_balance_cents + ?, updated_at = ?, seq = ? WHERE id = ?',
      effect * amount, db.now(), db.nextSeq(), account.id,
    );
    return { txs, memo: { on: occurredOn, amountCents: effect * amount, note: note || merchant, recorded: !!accountId } };
  }

  function appendMemo(debtId, memo) {
    const row = db.get('SELECT memo_log FROM debts WHERE id = ?', debtId);
    let log = [];
    try {
      log = JSON.parse(row.memo_log || '[]');
    } catch (_) {
      log = [];
    }
    log.push(memo);
    // 老的在前；只留最近 200 行，免得一笔来回几百次的债务把同步包撑大。
    return JSON.stringify(log.slice(-MEMO_MAX));
  }

  /** 每次新建都是同一个请求体对象，onWrite 靠它拿到 fromBody 里校验过的东西。 */
  const pendingCreate = new WeakMap();

  const crud = makeCrud({
    db,
    table: 'debts',
    resource: 'debts',
    singular: 'debt',
    label: '债务',
    idempotency: 'debt.create',
    listOrder: 'archived ASC, sort_order ASC, created_at ASC',
    fields: {
      kind: { type: 'enum', values: KINDS, default: 'loan' },
      counterparty: { type: 'string', required: true, max: 40 },
      memberId: { type: 'id' },
      note: { type: 'string', max: 500 },
    },
    toJson: (row) => rowToJson(row, { bools: ['archived', 'counted'], json: ['memo_log'] }),

    fromBody(body, isPatch, row) {
      const out = {};
      const given = (name) => body[name] !== undefined;
      if (isPatch) {
        if (given('direction')) v.bad('direction', '方向不能改，删了重记');
        if (given('amountCents')) v.bad('amountCents', '金额经「收回 / 追加」改');
      } else {
        out.direction = v.enumOf(body.direction, 'direction', DIRECTIONS);
        out.amount_cents = v.int(body.amountCents, 'amountCents', { min: 1, max: MAX_AMOUNT });
        out.memo_log = '[]';
      }
      if (!isPatch || given('startedOn')) {
        out.started_on = !isPatch && v.isMissing(body.startedOn) ? today() : day(body.startedOn, 'startedOn');
      }
      if (!isPatch || given('dueOn')) out.due_on = v.isMissing(body.dueOn) ? null : day(body.dueOn, 'dueOn');
      if (given('counted')) {
        out.counted = v.bool(body.counted, 'counted') ? 1 : 0;
      } else if (!isPatch) {
        // 人情是情分不是钱：默认不进净资产。
        out.counted = body.kind === 'favor' ? 0 : 1;
      }
      if (!isPatch) {
        const rt = recordSpec(body.recordTransaction);
        pendingCreate.set(body, rt ? moneyAccount(rt.accountId, 'accountId') : null);
      }
      return out;
    },

    onWrite(row, { isPatch, body, reqCtx }) {
      if (isPatch) {
        // 名字、归属、归档跟着债务走：流水里「借给 张三」要跟着改名。
        const account = row.account_id && db.get('SELECT * FROM accounts WHERE id = ?', row.account_id);
        if (!account) return;
        const name = accountName(row.direction, row.kind, row.counterparty);
        if (account.name !== name || account.owner_member_id !== row.member_id || account.archived !== row.archived) {
          db.run(
            'UPDATE accounts SET name = ?, owner_member_id = ?, archived = ?, updated_at = ?, seq = ? WHERE id = ?',
            name, row.member_id, row.archived, db.now(), db.nextSeq(), account.id,
          );
        }
        return;
      }
      const accountId = pendingCreate.get(body) || null;
      const sign = row.direction === 'lend' ? 1 : -1;
      const now = db.now();
      const id = crypto.randomUUID();
      const sort = db.get('SELECT MAX(sort_order) AS m FROM accounts WHERE deleted_at IS NULL');
      db.run(
        'INSERT INTO accounts(id, name, kind, owner_member_id, initial_balance_cents, currency, icon, color, sort_order,' +
          ' archived, match_hints, created_at, updated_at, seq) VALUES(?, ?, ?, ?, 0, ?, NULL, NULL, ?, 0, ?, ?, ?, ?)',
        id, accountName(row.direction, row.kind, row.counterparty), 'debt', row.member_id,
        db.meta('currency', 'CNY'), (typeof sort?.m === 'number' ? sort.m : -1) + 1, '{}', now, now, db.nextSeq(),
      );
      db.run('UPDATE debts SET account_id = ? WHERE id = ?', id, row.id);
      const account = db.get('SELECT * FROM accounts WHERE id = ?', id);
      const merchant = row.kind === 'favor'
        ? `人情 ${row.counterparty}`
        : `${row.direction === 'lend' ? '借给' : '借入'} ${row.counterparty}`;
      const { memo } = move(row, account, {
        effect: sign, amount: row.amount_cents, accountId, occurredOn: row.started_on, merchant,
        note: row.note || '',
      }, reqCtx);
      if (memo) db.run('UPDATE debts SET memo_log = ? WHERE id = ?', appendMemo(row.id, { ...memo, note: '起始' }), row.id);
    },

    canDelete(row) {
      if (!row.account_id) return;
      const used = db.get(
        "SELECT 1 AS ok FROM transactions WHERE deleted_at IS NULL AND status = 'confirmed'" +
          ' AND (account_id = ? OR to_account_id = ?) LIMIT 1',
        row.account_id, row.account_id,
      );
      if (used) throw new HttpError(409, 'debt_in_use', '这笔债务已经有往来流水，不能删；结清后可以归档');
    },

    onDelete(row) {
      if (!row.account_id) return;
      const now = db.now();
      db.run(
        'UPDATE accounts SET deleted_at = ?, updated_at = ?, seq = ? WHERE id = ? AND deleted_at IS NULL',
        now, now, db.nextSeq(), row.account_id,
      );
    },
  });

  /** 收回 / 还钱（settle）或再借（add）。 */
  function settle(req, res, reqCtx) {
    const b = v.body(reqCtx.body);
    const action = v.enumOf(b.action ?? 'settle', 'action', ['settle', 'add']);
    const amount = v.int(b.amountCents, 'amountCents', { min: 1, max: MAX_AMOUNT });
    const occurredOn = v.isMissing(b.occurredOn) ? today() : day(b.occurredOn, 'occurredOn');
    const note = v.optStr(b.note, 'note', { max: 200 }) || '';
    const clientId = idem.clientIdOf(b);

    const hit = idem.lookup(db, 'debt.settle', clientId);
    if (hit) {
      if (hit.refId !== reqCtx.params.id) {
        throw new HttpError(409, 'client_id_reused', '这个 clientId 已经用在另一笔债务上了');
      }
      return sendJson(res, 200, { ...hit.response, replayed: true });
    }

    const out = db.tx(() => {
      const d = crud.mustExist(reqCtx.params.id);
      const account = d.account_id && db.get('SELECT * FROM accounts WHERE id = ? AND deleted_at IS NULL', d.account_id);
      if (!account) throw new HttpError(409, 'debt_account_missing', '这笔债务的内部账户不见了，删了重记吧');
      const accountId = v.isMissing(b.accountId) ? null : moneyAccount(b.accountId, 'accountId');

      const sign = d.direction === 'lend' ? 1 : -1;
      const outstanding = sign * balanceOf(account);
      if (action === 'settle' && amount > outstanding) {
        throw new HttpError(400, 'over_settle', `比还剩的（${(outstanding / 100).toFixed(2)}）多了`);
      }
      const effect = action === 'settle' ? -sign : sign;
      const cp = d.counterparty;
      const merchant = d.kind === 'favor'
        ? `${action === 'settle' ? (d.direction === 'lend' ? '收回人情' : '还人情') : '人情'} ${cp}`
        : action === 'settle'
          ? `${d.direction === 'lend' ? '收回' : '还'} ${cp}`
          : `${d.direction === 'lend' ? '借给' : '借入'} ${cp}`;
      const { txs, memo } = move(d, account, { effect, amount, accountId, occurredOn, merchant, note }, reqCtx);

      const sets = ['updated_at = ?', 'seq = ?'];
      const args = [db.now(), db.nextSeq()];
      if (action === 'add') {
        sets.push('amount_cents = amount_cents + ?');
        args.push(amount);
      }
      if (memo) {
        sets.push('memo_log = ?');
        args.push(appendMemo(d.id, { ...memo, action }));
      }
      db.run(`UPDATE debts SET ${sets.join(', ')} WHERE id = ?`, ...args, d.id);
      logActivity(db, { memberId: reqCtx.member.id, action, entity: 'debt', entityId: d.id });

      const response = {
        debt: crud.toJson(db.get('SELECT * FROM debts WHERE id = ?', d.id)),
        transactions: txs.map(txJson),
      };
      idem.remember(db, 'debt.settle', clientId, d.id, response);
      return response;
    });
    sendJson(res, 200, out);
  }

  return {
    name: 'debts',
    routes: [...crud.routes, { method: 'POST', pattern: '/debts/:id/settle', handler: settle }],
  };
};
