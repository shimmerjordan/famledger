'use strict';

// 投资持仓。三件事在这里定死：
//
//   1. 份额与成本只能经开仓/加仓/减仓改（移动平均成本），PATCH 碰它们就 400 ——
//      手改成本会让已实现盈亏凭空多出或少掉一截，而且再也查不出是哪一笔。
//   2. 「同时记账」一律记成账户间转账：买基金是换个地方存钱，记成支出会把月支出撑爆；
//      只有卖出时的盈亏才是真正的收入/支出，单记一笔并落到「投资收益/投资亏损」。
//   3. 行情刷新全局节流：行情是非官方接口，打得太勤会被封 IP，家里谁点都算一次。
//   4. 挂着投资账户（且账户还在）的持仓，成本一定已经以转账的形式进了那个账户的余额 ——
//      stats.js 的净资产只给它补浮盈，靠的就是这一条。所以有成本的持仓：开仓时挂账户必须同时
//      记转账；事后挂上要说清成本从哪个账户转进来；换账户自动补一笔移仓转账；不许直接解绑。
//   5. 开仓、加减仓收 clientId 做幂等（lib/idempotency.js）：回应丢了 App 重发，份额、
//      移动平均成本和已实现盈亏不能被改第二遍 —— 它们只能经交易改，改错了没法手工改回来。

const crypto = require('node:crypto');

const { HttpError, sendJson } = require('../lib/router');
const { makeCrud } = require('../lib/crud');
const { rowToJson } = require('../lib/db');
const { logActivity } = require('../lib/activity');
const idem = require('../lib/idempotency');
const quotes = require('../lib/quotes');
const v = require('../lib/validate');

const MARKETS = ['fund', 'sh', 'sz', 'bj', 'other'];
const AUTO_MARKETS = ['fund', 'sh', 'sz', 'bj'];
const MAX_AMOUNT = 1e14;
const MAX_QTY_E4 = 1e14;
const MAX_PRICE_E4 = 1e12;
// 行情回填的名称绕过了 CRUD 校验，也得截到这个长度：拼成「买入 <名称>」要落在流水 merchant 的 120 字以内。
const NAME_MAX = 60;
// 代码会拼进行情 URL，只放行字母数字和少量分隔符。
const CODE_RE = /^[0-9A-Za-z._-]{1,20}$/;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const DEFAULT_THROTTLE_MS = 10 * 60 * 1000;

const PNL_CATEGORY = {
  income: { name: '投资收益', icon: 'trending_up', color: '#009d82' },
  expense: { name: '投资亏损', icon: 'trending_down', color: '#c3656f' },
};

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

/** round(cost × q / qty)。三个数都可能到 1e14 量级，乘积要走 BigInt 才不丢精度。 */
function proportionalCost(cost, q, qty) {
  if (q === qty) return cost;
  return Number((BigInt(cost) * BigInt(q) * 2n + BigInt(qty)) / (2n * BigInt(qty)));
}

module.exports = (ctx) => {
  const { db, log } = ctx;

  const throttleMs = (() => {
    const n = Number(process.env.QUOTE_THROTTLE_MS);
    return Number.isInteger(n) && n > 0 ? n : DEFAULT_THROTTLE_MS;
  })();

  const investAccount = (id) =>
    db.get("SELECT 1 AS ok FROM accounts WHERE id = ? AND kind = 'invest' AND deleted_at IS NULL", id);
  const accountExists = (id) => db.get('SELECT 1 AS ok FROM accounts WHERE id = ? AND deleted_at IS NULL', id);

  /** `recordTransaction` 里那个账户：必须存在，且不能就是持仓挂的投资账户（自己转给自己）。 */
  function counterAccount(raw, field, holdingAccountId) {
    const id = v.str(raw, field, { max: 64 });
    if (!accountExists(id)) v.bad(field, '账户不存在');
    if (id === holdingAccountId) v.bad(field, '转出和转入不能是同一个账户');
    return id;
  }

  function recordSpec(raw) {
    if (v.isMissing(raw)) return null;
    if (!v.isObject(raw)) v.bad('recordTransaction', 'recordTransaction 必须是对象');
    return raw;
  }

  const needsAccount = () => new HttpError(400, 'holding_needs_account', '这笔持仓还没挂投资账户，没法同时记账');
  const needsTransfer = () => new HttpError(
    400, 'holding_needs_transfer',
    '挂投资账户要同时记一笔转账，把成本从别的账户转进来，净资产才对得上；不想记账就先别挂账户',
  );

  /** 挂着的账户还在才算挂着：删掉的账户连同成本一起从余额里消失了，统计也按没挂算。 */
  const liveAccountOf = (row) => (row && row.account_id && accountExists(row.account_id) ? row.account_id : null);

  /** PATCH 换账户时要补的那笔转账：fromBody 定下来，onWrite 在同一个事务里记。键是同一个请求体对象。 */
  const pendingMoves = new WeakMap();

  const labelOf = (h) => h.name || h.code || '持仓';

  /** 找不到就在当前事务里建一个：用户删过/从来没有，卖出盈亏也得有地方落。 */
  function pnlCategoryId(kind) {
    const spec = PNL_CATEGORY[kind];
    const found = db.get(
      'SELECT id FROM categories WHERE name = ? AND kind = ? AND deleted_at IS NULL ORDER BY archived, sort_order LIMIT 1',
      spec.name, kind,
    );
    if (found) return found.id;
    const id = crypto.randomUUID();
    const now = db.now();
    const sort = db.get('SELECT MAX(sort_order) AS m FROM categories WHERE deleted_at IS NULL');
    db.run(
      'INSERT INTO categories(id, name, kind, parent_id, icon, color, sort_order, archived, created_at, updated_at, seq)' +
        ' VALUES(?, ?, ?, NULL, ?, ?, ?, 0, ?, ?, ?)',
      id, spec.name, kind, spec.icon, spec.color, (typeof sort?.m === 'number' ? sort.m : -1) + 1, now, now, db.nextSeq(),
    );
    return id;
  }

  /** 走 transactions.js 的同一套校验与写入；它按字母序后加载，所以只能在请求时取。 */
  function record(body, reqCtx) {
    return ctx.createTransaction({ source: 'manual', ...body }, reqCtx).row;
  }

  const crud = makeCrud({
    db,
    table: 'holdings',
    resource: 'holdings',
    singular: 'holding',
    label: '持仓',
    idempotency: 'holding.create',
    fields: {
      name: { type: 'string', max: NAME_MAX, default: '' },
      market: { type: 'enum', values: MARKETS, default: 'other' },
      priceSource: { type: 'enum', values: ['auto', 'manual'], default: 'manual' },
      note: { type: 'string', max: 500 },
    },

    fromBody(body, isPatch, row) {
      const out = {};
      const given = (name) => body[name] !== undefined;

      if (isPatch) {
        for (const f of ['quantityE4', 'costCents']) {
          if (given(f)) v.bad(f, `${f} 只能通过加仓/减仓修改`);
        }
      } else {
        out.quantity_e4 = v.int(body.quantityE4, 'quantityE4', { min: 1, max: MAX_QTY_E4 });
        out.cost_cents = v.int(body.costCents, 'costCents', { min: 0, max: MAX_AMOUNT });
      }

      if (!isPatch || given('code')) {
        const code = v.optStr(body.code, 'code', { max: 20 });
        if (code && !CODE_RE.test(code)) v.bad('code', '代码只能是字母、数字');
        out.code = code;
      }
      if (!isPatch || given('openedOn')) {
        out.opened_on = !isPatch && v.isMissing(body.openedOn) ? today() : day(body.openedOn, 'openedOn');
      }
      if (!isPatch || given('accountId')) {
        const id = v.optStr(body.accountId, 'accountId', { max: 64 });
        // 没变就不再校验：挂的账户删了以后，编辑页原样带回旧 id 不该让整次保存失败。
        if (id && id !== row?.account_id && !investAccount(id)) v.bad('accountId', '只能挂在「投资」类型的账户上');
        out.account_id = id;
      }
      if (given('priceE4')) {
        out.price_e4 = v.optInt(body.priceE4, 'priceE4', { min: 0, max: MAX_PRICE_E4 });
        out.price_at = out.price_e4 === null ? null : db.now();
        // 手填的价没有「昨收」可比，留着旧的会让今日涨跌拿两个不相干的价相减。
        out.prev_close_e4 = null;
      }

      // 下面按「旧行 + 本次改动」合并后的样子判断，PATCH 只改一半也逃不掉。
      const pick = (name, col, dflt) => (given(name) ? (body[name] ?? dflt) : (row ? row[col] : dflt));
      const code = 'code' in out ? out.code : row?.code;
      const name = given('name') ? String(body.name ?? '').trim() : (row ? row.name : '');
      if (!name && !code) v.bad('name', '名称和代码至少填一个');
      const market = pick('market', 'market', 'other');
      if (pick('priceSource', 'price_source', 'manual') === 'auto' && (!AUTO_MARKETS.includes(market) || !code)) {
        v.bad('priceSource', '自动行情要填代码，并选场外基金或沪/深/北市场');
      }
      // 价格跟着具体那只证券走：换了代码或市场还留着旧价，净资产就是拿别的证券的价乘这边的份额，
      // price_at 还会让它看着像新鲜价。宁可先没价格、退出统计，等刷新或手填；同一次给了新价的以新价为准。
      if (isPatch && !given('priceE4')
        && quotes.quoteKey(market, code || '') !== quotes.quoteKey(row.market, row.code || '')) {
        out.price_e4 = null;
        out.prev_close_e4 = null;
        out.price_at = null;
      }

      if (!isPatch) {
        const rt = recordSpec(body.recordTransaction);
        if (rt) {
          if (!out.account_id) throw needsAccount();
          counterAccount(rt.fromAccountId, 'fromAccountId', out.account_id);
        } else if (out.account_id && out.cost_cents > 0) {
          throw needsTransfer();
        }
      } else if (given('accountId') && row.cost_cents > 0) {
        const was = liveAccountOf(row);
        const next = out.account_id && accountExists(out.account_id) ? out.account_id : null;
        if (next !== was) {
          if (!next) {
            throw new HttpError(
              400, 'holding_account_locked',
              '这笔持仓的成本记在投资账户里，直接解绑净资产会多算一份；可以换到另一个投资账户，或者卖完再解绑',
            );
          }
          if (was) {
            pendingMoves.set(body, { from: was, to: next, verb: '移仓' });
          } else {
            const rt = recordSpec(body.recordTransaction);
            if (!rt) throw needsTransfer();
            pendingMoves.set(body, { from: counterAccount(rt.fromAccountId, 'fromAccountId', next), to: next, verb: '转入' });
          }
        }
      }
      return out;
    },

    onWrite(row, { isPatch, body, reqCtx }) {
      if (isPatch) {
        const move = pendingMoves.get(body);
        if (!move) return;
        record({
          type: 'transfer',
          amountCents: row.cost_cents,
          occurredAt: noonOf(today()),
          accountId: move.from,
          toAccountId: move.to,
          merchant: `${move.verb} ${labelOf(row)}`,
        }, reqCtx);
        return;
      }
      if (!body.recordTransaction || row.cost_cents === 0) return;
      record({
        type: 'transfer',
        amountCents: row.cost_cents,
        occurredAt: noonOf(row.opened_on),
        accountId: body.recordTransaction.fromAccountId,
        toAccountId: row.account_id,
        merchant: `买入 ${labelOf(row)}`,
      }, reqCtx);
    },
  });

  function trade(req, res, reqCtx) {
    const b = v.body(reqCtx.body);
    const side = v.enumOf(b.side, 'side', ['buy', 'sell']);
    const q = v.int(b.quantityE4, 'quantityE4', { min: 1, max: MAX_QTY_E4 });
    const amount = v.int(b.amountCents, 'amountCents', { min: 0, max: MAX_AMOUNT });
    const occurredOn = v.isMissing(b.occurredOn) ? today() : day(b.occurredOn, 'occurredOn');
    const rt = recordSpec(b.recordTransaction);
    const clientId = idem.clientIdOf(b);

    const hit = idem.lookup(db, 'holding.trade', clientId);
    if (hit) {
      if (hit.refId !== reqCtx.params.id) {
        throw new HttpError(409, 'client_id_reused', '这个 clientId 已经用在另一笔持仓的交易上了');
      }
      return sendJson(res, 200, { ...hit.response, replayed: true });
    }

    const out = db.tx(() => {
      const h = crud.mustExist(reqCtx.params.id);
      let counter = null;
      if (rt) {
        if (!h.account_id) throw needsAccount();
        // 挂的账户被删了，下面记转账会报成请求里的账户字段不存在，用户会以为是自己选错了卡。
        if (!accountExists(h.account_id)) {
          throw new HttpError(400, 'holding_needs_account', '这笔持仓挂的投资账户已经删了，重新挂一个才能同时记账');
        }
        counter = counterAccount(rt.accountId, 'accountId', h.account_id);
      }

      let qty = h.quantity_e4;
      let cost = h.cost_cents;
      let realized = 0;
      if (side === 'buy') {
        qty += q;
        cost += amount;
        if (qty > MAX_QTY_E4) v.bad('quantityE4', '持有份额太大了');
        if (cost > MAX_AMOUNT) v.bad('amountCents', '持仓成本太大了');
      } else {
        if (q > qty) throw new HttpError(400, 'insufficient_quantity', '卖出份额超过了持有份额');
        const propCost = proportionalCost(cost, q, qty);
        realized = amount - propCost;
        qty -= q;
        cost -= propCost;
        // 累计值没有单笔金额那道闸：越过 2^53 后 node:sqlite 回读这一行直接抛错，接口只剩 500。
        if (Math.abs(h.realized_cents + realized) > MAX_AMOUNT) v.bad('amountCents', '累计已实现盈亏太大了');
      }

      db.run(
        'UPDATE holdings SET quantity_e4 = ?, cost_cents = ?, realized_cents = realized_cents + ?, updated_at = ?, seq = ? WHERE id = ?',
        qty, cost, realized, db.now(), db.nextSeq(), h.id,
      );
      logActivity(db, { memberId: reqCtx.member.id, action: side, entity: 'holding', entityId: h.id });

      const txs = [];
      if (counter) {
        const label = labelOf(h);
        const at = noonOf(occurredOn);
        if (amount > 0) {
          const [from, to] = side === 'buy' ? [counter, h.account_id] : [h.account_id, counter];
          txs.push(record({
            type: 'transfer', amountCents: amount, occurredAt: at, accountId: from, toAccountId: to,
            merchant: `${side === 'buy' ? '买入' : '卖出'} ${label}`,
          }, reqCtx));
        }
        if (realized !== 0) {
          const kind = realized > 0 ? 'income' : 'expense';
          txs.push(record({
            type: kind, amountCents: Math.abs(realized), occurredAt: at, accountId: h.account_id,
            categoryId: pnlCategoryId(kind), merchant: `卖出 ${label}`,
            note: realized > 0 ? '已实现盈利' : '已实现亏损',
          }, reqCtx));
        }
      }
      const response = {
        holding: crud.toJson(db.get('SELECT * FROM holdings WHERE id = ?', h.id)),
        transactions: txs.map(txJson),
      };
      idem.remember(db, 'holding.trade', clientId, h.id, response);
      return response;
    });
    sendJson(res, 200, out);
  }

  // ── 行情刷新 ──────────────────────────────────────────────────────────────
  /** 上一次真正去拉行情的时刻与结果；并发进来的请求等同一个 promise，不重复打上游。 */
  let last = null;

  async function pullQuotes() {
    const rows = db.all(
      "SELECT id, market, code FROM holdings WHERE deleted_at IS NULL AND archived = 0 AND price_source = 'auto'" +
        " AND market IN ('fund', 'sh', 'sz', 'bj') AND code IS NOT NULL AND code != ''",
    );
    const found = rows.length ? await quotes.fetchQuotes(rows) : new Map();
    const refreshedAt = db.now();
    const failed = [];
    let updated = 0;
    db.tx(() => {
      for (const r of rows) {
        const got = found.get(quotes.quoteKey(r.market, r.code));
        if (!got || got.error) {
          failed.push({ id: r.id, code: r.code, message: got?.error || '没拿到行情' });
          continue;
        }
        // 拉行情要好几秒，这期间被删、被改成手动价或换了代码的，都不该被这次结果覆盖。
        const res = db.run(
          "UPDATE holdings SET price_e4 = ?, prev_close_e4 = ?, price_at = ?, name = CASE WHEN name = '' THEN ? ELSE name END," +
            " updated_at = ?, seq = ? WHERE id = ? AND deleted_at IS NULL AND price_source = 'auto' AND market = ? AND code = ?",
          got.priceE4, got.prevCloseE4, refreshedAt, got.name.slice(0, NAME_MAX), refreshedAt, db.nextSeq(), r.id, r.market, r.code,
        );
        if (res.changes) updated++;
      }
    });
    return { updated, failed, refreshedAt };
  }

  async function refresh(req, res) {
    const now = Date.now();
    if (last && now - last.at < throttleMs) {
      const result = await last.promise;
      return sendJson(res, 200, { ...result, throttled: true });
    }
    const promise = pullQuotes().catch((e) => {
      log.error('holdings', `refresh failed: ${e.stack || e}`);
      return { updated: 0, failed: [], refreshedAt: db.now() };
    });
    last = { at: now, promise };
    sendJson(res, 200, { ...(await promise), throttled: false });
  }

  return {
    name: 'holdings',
    routes: [
      ...crud.routes,
      { method: 'POST', pattern: '/holdings/refresh', handler: refresh, maxBody: 1024 },
      { method: 'POST', pattern: '/holdings/:id/trade', handler: trade },
    ],
  };
};
