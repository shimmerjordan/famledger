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
//   6. 新建可以带 settledCents（已经收回 / 还掉的部分，0..总数）：同一个事务里收回一次，省得建完再去详情里点「收回」。
//      钱怎么走跟着「同时记账」：记了借出那笔，收回的也经同一个账户记（不然那个账户多出一截、净资产凭空变了）；
//      没记就只改期初、memo_log 留一行「之前已收回 / 之前已还」。日子记在起始日（哪天收回的不知道，排在起始后面）。
//   7. 手动微调：总额（amountCents）随时能改；还剩多少（remainingCents）= 校准，差额进内部账户期初、留一行「校准」备忘；
//      方向、币种在内部账户还没有流水时能改（有流水就是两种钱/两个方向混着算，409）。备忘行能改金额、日期、说明，
//      也能删：改 / 删会把它当初对期初的影响一起改回来（起始、追加那几行连总额一起改）。
//   8. 关联已有流水：借出 / 收回 / 借入 / 还款的钱常常已经被自动记账或导入记成一笔支出 / 收入了，再记一笔转账
//      账户就被扣两次。新建的 recordTransaction 多一种 `{ transactionId }`，收回 / 追加多一个顶层 `transactionId`
//      （都和 accountId 二选一）：借款类把那笔改成「真账户 ↔ 内部账户」的转账（类别、板块清掉；金额、日期、商户、
//      备注、状态、off_balance 都不动），不再新记；人情不改那笔（随礼本来就是支出），只当钱那一边已经记过，
//      改期初、备忘 recorded。那笔「不计入账户余额」也照样不动：真账户照旧靠校准，内部账户那一侧照常算
//      （lib/stats_sql.js 的 deltaMap）。校验都是 400：invalid_transactionId（不存在 / 已删 / 作废 / 还没确认 / 已是转账 /
//      没账户 / 挂在别的债务上 / 类型和方向不配）、currency_mismatch、amount_mismatch。

const crypto = require('node:crypto');

const { HttpError, sendJson } = require('../lib/router');
const { makeCrud, currencyColumns, requireSameCurrency } = require('../lib/crud');
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

const txJson = (row) => rowToJson(row, { json: ['tags'], bools: ['off_balance'] });

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

  /** 钱从哪个真账户走：必须存在、不能是另一笔债务的内部账户、和债务同币种。 */
  function moneyAccount(raw, field, currency) {
    const id = v.str(raw, field, { max: 64 });
    if (!realAccount(id)) v.bad(field, '账户不存在');
    requireSameCurrency(db, id, currency, field, '这笔债务');
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

  /** 错误消息里的金额：人民币带 ¥，别的币种带代码。 */
  const money = (cents, currency) => `${currency === 'CNY' ? '¥' : `${currency} `}${(cents / 100).toFixed(2)}`;

  /**
   * 「关联已有流水」（文件头第 8 条）：找出那笔并核对它能不能当这次往来。借款类接着会把它改成转账
   * （借出 / 还款是花出去的钱，要一笔支出；收回 / 借入是收进来的钱，要一笔收入），人情只核对不改。
   * @param {number} effect 对内部账户余额的影响（> 0 要支出，< 0 要收入）
   * @param {number} amount 这次的金额，必须和那笔一样
   * @returns {object} 那笔流水的行
   */
  function linkedTransaction(debt, rawId, effect, amount) {
    const id = v.str(rawId, 'transactionId', { max: 64 });
    const reject = (message) => {
      throw new HttpError(400, 'invalid_transactionId', message);
    };
    const tx = db.get('SELECT * FROM transactions WHERE id = ? AND deleted_at IS NULL', id);
    if (!tx) reject('那笔流水不存在或已经删了');
    if (tx.status === 'duplicate' || tx.status === 'void') reject('那笔流水已经作废（或是重复的），换一笔');
    // 待确认的不行：余额只算已确认的流水，关联了也不会动债务的「还剩多少」，之后一确认钱就进了内部账户。
    if (tx.status !== 'confirmed') reject('那笔流水还没确认；先在待确认里确认它，再关联');
    if (tx.type === 'transfer') reject('那笔流水已经是转账了，不能再当作往来');
    if (!tx.account_id) reject('那笔流水没有账户，不知道钱从哪走；先给它选个账户');
    const acc = db.get('SELECT name, kind, deleted_at FROM accounts WHERE id = ?', tx.account_id);
    if (!acc || acc.deleted_at) reject('那笔流水的账户已经删了');
    if (acc.kind === 'debt') reject('那笔流水已经是另一笔债务的往来了');
    // 人情关联不改那笔流水，只在备忘里记下它的 id（move 里）；同一笔不能再关联第二次，不然期初就加两遍。
    const prior = db.get(
      'SELECT counterparty FROM debts WHERE deleted_at IS NULL AND instr(memo_log, ?) > 0 LIMIT 1',
      `"transactionId":"${id}"`,
    );
    if (prior) reject(`那笔流水已经关联到人情「${prior.counterparty}」了，不能再用一次`);
    if (tx.type !== (effect > 0 ? 'expense' : 'income')) {
      reject(effect > 0
        ? '借出 / 还钱是花出去的钱，要关联一笔支出；那笔是收入'
        : '收回 / 借入是收进来的钱，要关联一笔收入；那笔是支出');
    }
    if (tx.currency !== debt.currency) {
      throw new HttpError(
        400, 'currency_mismatch',
        `这笔债务是 ${debt.currency}，那笔流水是 ${tx.currency}（「${acc.name}」）：钱要从同币种的账户走（换汇先在记一笔里转账）`,
        { field: 'transactionId' },
      );
    }
    if (Number(tx.amount_cents) !== amount) {
      throw new HttpError(
        400, 'amount_mismatch',
        `那笔流水是 ${money(tx.amount_cents, tx.currency)}，和这里填的 ${money(amount, debt.currency)} 不一样；改一边再试`,
        { field: 'transactionId' },
      );
    }
    return tx;
  }

  /**
   * 钱这一次怎么动。`effect` 是对内部账户余额的影响（+ 让「别人欠我」变多 / 「我欠别人」变少）。
   * 有 `accountId`：借款类记一笔转账；人情记一笔支出/收入并改期初。有 `transactionId`（关联已有流水，文件头第 8 条）：
   * 借款类把那笔改成转账；人情不动那笔，只改期初。都没有：只改期初、留一行备忘。
   * @returns {{txs: object[], memo: object|null}} 记下 / 改过的流水，和要追加的备忘
   */
  function move(debt, account, { effect, amount, accountId, transactionId, occurredOn, merchant, note }, reqCtx) {
    const txs = [];
    const linked = transactionId ? linkedTransaction(debt, transactionId, effect, amount) : null;
    if (debt.kind !== 'favor' && (accountId || linked)) {
      if (linked) {
        // 类别、板块清掉（借出不是花钱，板块余额回去）；金额、日期、商户、备注、状态、off_balance 都不传，沿用。
        const [from, to] = effect > 0 ? [linked.account_id, account.id] : [account.id, linked.account_id];
        txs.push(ctx.updateTransaction(linked.id, {
          type: 'transfer', accountId: from, toAccountId: to, categoryId: null, fundId: null, toFundId: null,
        }, reqCtx));
      } else {
        const [from, to] = effect > 0 ? [accountId, account.id] : [account.id, accountId];
        txs.push(record({
          type: 'transfer', amountCents: amount, occurredAt: noonOf(occurredOn), accountId: from, toAccountId: to,
          merchant, note: note || '',
        }, reqCtx));
      }
      return { txs, memo: null };
    }
    // 人情的钱：内部余额变多 = 我随礼出去了（支出），变少 = 我收到礼了（收入）。关联了已有流水的，那笔本来就记着，不动。
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
    return {
      txs,
      memo: {
        on: occurredOn, amountCents: effect * amount, note: note || merchant, recorded: !!(accountId || linked),
        ...(linked ? { transactionId: linked.id } : {}),
      },
    };
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

  /** 内部账户上的流水（POST /debts 幂等回放时的 transactions）。 */
  function flowsOf(accountId) {
    if (!accountId) return [];
    return db.all(
      'SELECT * FROM transactions WHERE deleted_at IS NULL AND (account_id = ? OR to_account_id = ?)' +
        ' ORDER BY occurred_at, created_at',
      accountId, accountId,
    ).map(txJson);
  }
  /** PATCH 里要在 onWrite 做的：校准还剩多少、翻转方向。键同样是请求体对象。 */
  const pendingPatch = new WeakMap();

  const parseLog = (raw) => {
    try {
      const log = JSON.parse(raw || '[]');
      return Array.isArray(log) ? log : [];
    } catch (_) {
      return [];
    }
  };

  /** 内部账户上有没有流水（不管状态）：有就不能改方向、币种。 */
  const hasFlows = (accountId) => !!(accountId && db.get(
    'SELECT 1 AS ok FROM transactions WHERE deleted_at IS NULL AND (account_id = ? OR to_account_id = ?) LIMIT 1',
    accountId, accountId,
  ));

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
    // 起始那笔钱（新记的转账 / 关联后改成转账的那笔，人情是空）也在建债务的回应里，App 不用再拉一次；
    // 幂等回放时按内部账户上的流水给。
    createExtra: (row, body) => ({ transactions: pendingCreate.get(body)?.txs ?? flowsOf(row.account_id) }),

    fromBody(body, isPatch, row) {
      const out = {};
      const given = (name) => body[name] !== undefined;
      if (isPatch) {
        if (!v.isMissing(body.settledCents)) v.bad('settledCents', '收回的钱经「收回」记；改还剩多少用 remainingCents');
        if (given('amountCents')) out.amount_cents = v.int(body.amountCents, 'amountCents', { min: 1, max: MAX_AMOUNT });
        const plan = {};
        if (given('direction')) {
          const direction = v.enumOf(body.direction, 'direction', DIRECTIONS);
          if (direction !== row.direction) {
            if (hasFlows(row.account_id)) {
              throw new HttpError(409, 'debt_has_flows', '这笔债务已经有往来流水了，不能改方向；先把流水删了，或者删了重记');
            }
            out.direction = direction;
            plan.flip = true;
          }
        }
        if (!v.isMissing(body.remainingCents)) {
          plan.remaining = v.int(body.remainingCents, 'remainingCents', { min: -MAX_AMOUNT, max: MAX_AMOUNT });
          plan.on = v.isMissing(body.remainingOn) ? today() : day(body.remainingOn, 'remainingOn');
        }
        if (plan.flip || plan.remaining !== undefined) pendingPatch.set(body, plan);
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
      // 币种：内部账户上的往来都是这个币种，有了流水再改就是两种钱混着加；只记了数（备忘）的随便改。
      Object.assign(out, currencyColumns(db, body, isPatch));
      if (isPatch && out.currency && out.currency !== row.currency && hasFlows(row.account_id)) {
        throw new HttpError(409, 'currency_locked', '这笔债务已经有往来流水了，不能改币种；删了重记');
      }
      if (!isPatch) {
        const rt = recordSpec(body.recordTransaction);
        const settled = v.isMissing(body.settledCents)
          ? 0
          : v.int(body.settledCents, 'settledCents', { min: 0, max: MAX_AMOUNT });
        if (settled > out.amount_cents) v.bad('settledCents', '已经收回的不能比总数还多');
        // 起始那笔钱：新记一笔（accountId）还是已经记过了（transactionId，文件头第 8 条），二选一。
        // 那笔流水本身在 onWrite 里核对、转换（要等内部账户建出来）。
        let accountId = null;
        let transactionId = null;
        if (rt) {
          if (!v.isMissing(rt.accountId) && !v.isMissing(rt.transactionId)) {
            throw new HttpError(400, 'invalid_recordTransaction', 'accountId 和 transactionId 只能给一个：钱是新记一笔，还是已经记过了？');
          }
          if (!v.isMissing(rt.transactionId)) transactionId = v.str(rt.transactionId, 'transactionId', { max: 64 });
          else accountId = moneyAccount(rt.accountId, 'accountId', out.currency);
        }
        pendingCreate.set(body, { accountId, transactionId, settled });
      }
      return out;
    },

    onWrite(row, { isPatch, body, reqCtx }) {
      if (isPatch) {
        // 名字、归属、归档、币种跟着债务走：流水里「借给 张三」要跟着改名。
        const account = row.account_id && db.get('SELECT * FROM accounts WHERE id = ?', row.account_id);
        if (!account) {
          if (pendingPatch.has(body)) throw new HttpError(409, 'debt_account_missing', '这笔债务的内部账户不见了，删了重记吧');
          return;
        }
        const name = accountName(row.direction, row.kind, row.counterparty);
        if (account.name !== name || account.owner_member_id !== row.member_id || account.archived !== row.archived
          || account.currency !== row.currency) {
          db.run(
            'UPDATE accounts SET name = ?, owner_member_id = ?, archived = ?, currency = ?, updated_at = ?, seq = ? WHERE id = ?',
            name, row.member_id, row.archived, row.currency, db.now(), db.nextSeq(), account.id,
          );
        }
        const plan = pendingPatch.get(body);
        if (!plan) return;
        // 翻方向（只有备忘、没有流水时才走到这）：余额正负对调，备忘里的影响也跟着对调。
        if (plan.flip) {
          const log = parseLog(row.memo_log).map((m) => ({ ...m, amountCents: -(Number(m.amountCents) || 0) }));
          db.run(
            'UPDATE accounts SET initial_balance_cents = -initial_balance_cents, updated_at = ?, seq = ? WHERE id = ?',
            db.now(), db.nextSeq(), account.id,
          );
          db.run('UPDATE debts SET memo_log = ? WHERE id = ?', JSON.stringify(log), row.id);
        }
        // 校准还剩多少：差额进期初，留一行「校准」。
        if (plan.remaining !== undefined) {
          const fresh = db.get('SELECT * FROM accounts WHERE id = ?', account.id);
          const sign = row.direction === 'lend' ? 1 : -1;
          const delta = sign * plan.remaining - balanceOf(fresh);
          if (delta !== 0) {
            db.run(
              'UPDATE accounts SET initial_balance_cents = initial_balance_cents + ?, updated_at = ?, seq = ? WHERE id = ?',
              delta, db.now(), db.nextSeq(), account.id,
            );
            const memo = { on: plan.on, amountCents: delta, note: '校准', recorded: false, action: 'calibrate' };
            db.run('UPDATE debts SET memo_log = ? WHERE id = ?', appendMemo(row.id, memo), row.id);
            logActivity(db, { memberId: reqCtx.member.id, action: 'calibrate', entity: 'debt', entityId: row.id });
          }
        }
        return;
      }
      const { accountId = null, transactionId = null, settled = 0 } = pendingCreate.get(body) || {};
      const sign = row.direction === 'lend' ? 1 : -1;
      const now = db.now();
      const id = crypto.randomUUID();
      const sort = db.get('SELECT MAX(sort_order) AS m FROM accounts WHERE deleted_at IS NULL');
      db.run(
        'INSERT INTO accounts(id, name, kind, owner_member_id, initial_balance_cents, currency, icon, color, sort_order,' +
          ' archived, match_hints, created_at, updated_at, seq) VALUES(?, ?, ?, ?, 0, ?, NULL, NULL, ?, 0, ?, ?, ?, ?)',
        id, accountName(row.direction, row.kind, row.counterparty), 'debt', row.member_id,
        row.currency, (typeof sort?.m === 'number' ? sort.m : -1) + 1, '{}', now, now, db.nextSeq(),
      );
      db.run('UPDATE debts SET account_id = ? WHERE id = ?', id, row.id);
      const account = db.get('SELECT * FROM accounts WHERE id = ?', id);
      const merchant = row.kind === 'favor'
        ? `人情 ${row.counterparty}`
        : `${row.direction === 'lend' ? '借给' : '借入'} ${row.counterparty}`;
      const { txs, memo } = move(row, account, {
        effect: sign, amount: row.amount_cents, accountId, transactionId, occurredOn: row.started_on, merchant,
        note: row.note || '',
      }, reqCtx);
      const pending = pendingCreate.get(body) || {};
      pending.txs = txs.map(txJson);
      pendingCreate.set(body, pending);
      if (memo) db.run('UPDATE debts SET memo_log = ? WHERE id = ?', appendMemo(row.id, { ...memo, note: '起始' }), row.id);
      // 已收回的部分：起始经账户记的，收回也经同一个账户；起始是关联已有流水的（accountId 为空），
      // 收回那笔没得关联，按「不记流水」处理 —— 改期初、留备忘。
      if (settled > 0) {
        const note = row.direction === 'lend' ? '之前已收回' : '之前已还';
        const backMerchant = row.kind === 'favor'
          ? `${row.direction === 'lend' ? '收回人情' : '还人情'} ${row.counterparty}`
          : `${row.direction === 'lend' ? '收回' : '还'} ${row.counterparty}`;
        const backMove = move(row, account, {
          effect: -sign, amount: settled, accountId, occurredOn: row.started_on, merchant: backMerchant, note,
        }, reqCtx);
        pending.txs.push(...backMove.txs.map(txJson));
        const back = backMove.memo;
        if (back) db.run('UPDATE debts SET memo_log = ? WHERE id = ?', appendMemo(row.id, { ...back, note, action: 'settle' }), row.id);
        logActivity(db, { memberId: reqCtx.member.id, action: 'settle', entity: 'debt', entityId: row.id });
      }
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
      // 钱怎么走：新记一笔（accountId）还是关联已有流水（transactionId，文件头第 8 条），二选一。
      if (!v.isMissing(b.accountId) && !v.isMissing(b.transactionId)) {
        throw new HttpError(400, 'invalid_transactionId', 'accountId 和 transactionId 只能给一个：钱是新记一笔，还是已经记过了？');
      }
      const accountId = v.isMissing(b.accountId) ? null : moneyAccount(b.accountId, 'accountId', d.currency);
      const transactionId = v.isMissing(b.transactionId) ? null : v.str(b.transactionId, 'transactionId', { max: 64 });

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
      const { txs, memo } = move(d, account, { effect, amount, accountId, transactionId, occurredOn, merchant, note }, reqCtx);

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

  /**
   * 改 / 删一行备忘（`/debts/:id/memo/:index`，index 是 memo_log 里的下标，老的在前）。这行当初改过内部账户期初
   * （amountCents 带正负号，就是它对余额的影响），改金额就按差额改回期初、删就整个减掉；起始和追加那几行当初还加过
   * 总额，总额跟着改。人情记过流水的那几行（recorded）只改数，流水另外改。
   */
  function memoEdit(remove) {
    return (req, res, reqCtx) => {
      const b = remove ? {} : v.body(reqCtx.body);
      const out = db.tx(() => {
        const d = crud.mustExist(reqCtx.params.id);
        const log = parseLog(d.memo_log);
        const i = Number(reqCtx.params.index);
        if (!Number.isInteger(i) || i < 0 || i >= log.length) throw new HttpError(404, 'not_found', '这行备忘不存在了，刷新一下');
        const old = log[i];
        const oldSigned = Number(old.amountCents) || 0;
        let newSigned = 0;
        if (!remove) {
          const next = { ...old };
          if (b.amountCents !== undefined) {
            const abs = v.int(b.amountCents, 'amountCents', { min: 0, max: MAX_AMOUNT });
            newSigned = (oldSigned < 0 ? -1 : 1) * abs;
            next.amountCents = newSigned;
          } else {
            newSigned = oldSigned;
          }
          if (b.on !== undefined) next.on = day(b.on, 'on');
          if (b.note !== undefined) next.note = v.optStr(b.note, 'note', { max: 200 }) || '';
          log[i] = next;
        } else {
          log.splice(i, 1);
        }
        const delta = newSigned - oldSigned;
        const sets = ['memo_log = ?', 'updated_at = ?', 'seq = ?'];
        const args = [JSON.stringify(log), db.now(), db.nextSeq()];
        // 起始（没有 action）和追加（add）当初把总额也抬高了。
        if (delta !== 0 && (!old.action || old.action === 'add')) {
          const total = Number(d.amount_cents) + Math.abs(newSigned) - Math.abs(oldSigned);
          if (total < 1) v.bad('amountCents', '这样总额就没了；整笔不要了就删掉这笔债务');
          sets.push('amount_cents = ?');
          args.push(total);
        }
        if (delta !== 0) {
          const account = d.account_id && db.get('SELECT id FROM accounts WHERE id = ? AND deleted_at IS NULL', d.account_id);
          if (!account) throw new HttpError(409, 'debt_account_missing', '这笔债务的内部账户不见了，删了重记吧');
          db.run(
            'UPDATE accounts SET initial_balance_cents = initial_balance_cents + ?, updated_at = ?, seq = ? WHERE id = ?',
            delta, db.now(), db.nextSeq(), account.id,
          );
        }
        db.run(`UPDATE debts SET ${sets.join(', ')} WHERE id = ?`, ...args, d.id);
        return { debt: crud.toJson(db.get('SELECT * FROM debts WHERE id = ?', d.id)) };
      });
      sendJson(res, 200, out);
    };
  }

  return {
    name: 'debts',
    routes: [
      ...crud.routes,
      { method: 'POST', pattern: '/debts/:id/settle', handler: settle },
      { method: 'PATCH', pattern: '/debts/:id/memo/:index', handler: memoEdit(false) },
      { method: 'DELETE', pattern: '/debts/:id/memo/:index', handler: memoEdit(true), maxBody: 0 },
    ],
  };
};
