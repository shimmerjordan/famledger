'use strict';

// 物品资产：买来一件东西，一直用到退役或卖掉。「每天花多少钱」只在客户端算，
// 这里守住的是日期与状态之间不能自相矛盾、「同时记账」和资产同生共死，以及一件东西
// 最多挂着一笔还算数的卖出收入。新建和卖出都收 clientId 做幂等（lib/idempotency.js）：
// 回应丢了 App 重发，不能多出一件物品、多记一笔支出。

const { HttpError, sendJson } = require('../lib/router');
const { makeCrud } = require('../lib/crud');
const idem = require('../lib/idempotency');
const v = require('../lib/validate');

const CATEGORIES = ['digital', 'appliance', 'furniture', 'clothing', 'vehicle', 'sports', 'other'];
const STATUSES = ['in_use', 'idle', 'retired', 'sold'];
const ENDED = new Set(['retired', 'sold']);
const MAX_AMOUNT = 1e14;
const RECORD_KEYS = ['accountId', 'fundId', 'categoryId', 'memberId'];

const pad = (n) => String(n).padStart(2, '0');

/** 服务器本地日期：和 transactions.js 的 localIso 同一个口径（部署镜像钉在 Asia/Shanghai）。 */
function today(d = new Date()) {
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

/** `YYYY-MM-DD`，要是真实存在的日子，且不能晚于今天——还没发生的事不该有账。 */
function pastDate(raw, field) {
  if (typeof raw !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(raw)) v.bad(field, `${field} 必须是 YYYY-MM-DD 日期`);
  const d = new Date(`${raw}T00:00:00Z`);
  if (Number.isNaN(d.getTime()) || d.toISOString().slice(0, 10) !== raw) v.bad(field, `${field} 不是有效日期`);
  if (raw > today()) v.bad(field, `${field} 不能晚于今天`);
  return raw;
}

// 物品只记到「哪一天」：钉在当天中午，前后差几个时区也换算不到别的日子去。
const noonOf = (day) => `${day}T12:00:00+08:00`;

module.exports = (ctx) => {
  const { db } = ctx;

  const memberAlive = (id) => !!db.get('SELECT 1 AS ok FROM members WHERE id = ? AND deleted_at IS NULL', id);

  /** 删掉或作废的流水不进统计，那笔卖出收入就和没记过一样。 */
  const saleCounts = (row) => !!row.sale_transaction_id && !!db.get(
    "SELECT 1 AS ok FROM transactions WHERE id = ? AND deleted_at IS NULL AND status NOT IN ('duplicate', 'void')",
    row.sale_transaction_id,
  );

  /**
   * 「同时记账」请求体 → createTransaction 的一部分。只收这几个键：类型、金额、时间
   * 由资产本身决定，不能被请求体顺手改掉。成员缺省跟着资产走。
   */
  function recordFrom(raw, asset) {
    if (raw === undefined || raw === null || raw === false) return null;
    if (!v.isObject(raw)) v.bad('recordTransaction', 'recordTransaction 必须是对象');
    const out = {};
    for (const k of RECORD_KEYS) if (raw[k] !== undefined) out[k] = raw[k];
    if (out.memberId === undefined && asset.member_id && memberAlive(asset.member_id)) out.memberId = asset.member_id;
    return out;
  }

  const crud = makeCrud({
    db,
    table: 'assets',
    resource: 'assets',
    singular: 'asset',
    label: '物品',
    idempotency: 'asset.create',
    fields: {
      name: { type: 'string', required: true, max: 60 },
      category: { type: 'enum', values: CATEGORIES, default: 'other' },
      icon: { type: 'string', max: 40 },
      priceCents: { type: 'int', required: true, min: 0, max: MAX_AMOUNT },
      status: { type: 'enum', values: STATUSES, default: 'in_use' },
      saleCents: { type: 'int', min: 0, max: MAX_AMOUNT },
      expectedDays: { type: 'int', min: 1, max: 36500 },
      note: { type: 'string', max: 500 },
      memberId: { type: 'id' },
    },

    /** 字段已各自校验过；这里只管跨字段的规则，比的是「旧行 + 本次改动」合并后的结果。 */
    fromBody(body, isPatch, row) {
      const given = (k) => body[k] !== undefined;
      const blank = (k) => v.isMissing(body[k]) || body[k] === '';
      const out = {};

      const purchasedOn = !isPatch || given('purchasedOn') ? pastDate(body.purchasedOn, 'purchasedOn') : row.purchased_on;
      out.purchased_on = purchasedOn;

      const status = given('status') ? (body.status ?? 'in_use') : (row ? row.status : 'in_use');
      const ended = ENDED.has(status);
      let endedOn;
      if (!blank('endedOn')) {
        if (!ended) v.bad('endedOn', '只有退役或卖出的物品才有结束日期');
        endedOn = pastDate(body.endedOn, 'endedOn');
      } else if (given('endedOn') || !ended) {
        endedOn = null;
      } else if (row && ENDED.has(row.status)) {
        endedOn = row.ended_on;
      } else {
        // 刚转成退役/卖出却没给日期就记今天：留空的话客户端会一直按「今天」往后数天数。
        endedOn = today();
      }
      if (endedOn && endedOn < purchasedOn) {
        v.bad(given('endedOn') ? 'endedOn' : 'purchasedOn', '结束日期不能早于买入日期');
      }
      out.ended_on = endedOn;

      if (!ended) {
        if (!blank('saleCents')) v.bad('saleCents', '只有退役或卖出的物品才有卖出价');
        out.sale_cents = null;
        if (row && row.sale_transaction_id) {
          // 留着关联是「没卖却挂着卖出收入」；悄悄清掉又会让它能再卖一次、记出第二笔收入。
          if (saleCounts(row)) throw new HttpError(409, 'sale_recorded', '卖出时记过一笔收入，先把那笔删掉再改回来');
          out.sale_transaction_id = null;
        }
      }

      if (!blank('memberId') && !memberAlive(String(body.memberId).trim())) v.bad('memberId', '成员不存在');
      return out;
    },

    onWrite(row, { isPatch, body, reqCtx }) {
      if (isPatch || row.price_cents === 0) return;
      const rec = recordFrom(body.recordTransaction, row);
      if (!rec) return;
      // 流水校验失败会直接抛出，外层事务连同刚插入的资产一起回滚。
      const { row: tx } = ctx.createTransaction({
        ...rec,
        type: 'expense',
        amountCents: row.price_cents,
        occurredAt: noonOf(row.purchased_on),
        merchant: row.name,
        source: 'manual',
      }, reqCtx);
      db.run('UPDATE assets SET transaction_id = ? WHERE id = ?', tx.id, row.id);
    },
  });

  function sell(req, res, reqCtx) {
    const body = v.body(reqCtx.body);
    const clientId = idem.clientIdOf(body);
    // 重发的那次会撞上下面的 already_sold；认出是同一次就照成功回，App 不必对着 409 猜记上没有。
    const hit = idem.lookup(db, 'asset.sell', clientId);
    if (hit) {
      if (hit.refId !== reqCtx.params.id) {
        throw new HttpError(409, 'client_id_reused', '这个 clientId 已经用在另一件物品上了');
      }
      const prev = db.get('SELECT * FROM assets WHERE id = ?', hit.refId);
      return sendJson(res, 200, { asset: crud.toJson(prev), replayed: true });
    }
    const row = crud.mustExist(reqCtx.params.id);
    // 连点两下就会记两笔收入；要改卖出价走 PATCH。
    if (row.status === 'sold') throw new HttpError(409, 'already_sold', '这件已经卖出了');
    // 卖出后改成退役，状态不再是 sold，那笔收入却还在。
    if (saleCounts(row)) throw new HttpError(409, 'sale_recorded', '上次卖出记的收入还在，先把那笔删掉再卖');
    const saleCents = v.int(body.saleCents, 'saleCents', { min: 0, max: MAX_AMOUNT });
    const endedOn = pastDate(body.endedOn, 'endedOn');
    if (endedOn < row.purchased_on) v.bad('endedOn', '卖出日期不能早于买入日期');
    const rec = saleCents > 0 ? recordFrom(body.recordTransaction, row) : null;

    const next = db.tx(() => {
      const made = rec
        ? ctx.createTransaction({
            ...rec,
            type: 'income',
            amountCents: saleCents,
            occurredAt: noonOf(endedOn),
            merchant: `卖出 ${row.name}`,
            source: 'manual',
          }, reqCtx)
        : null;
      db.run(
        'UPDATE assets SET status = ?, ended_on = ?, sale_cents = ?, sale_transaction_id = ?, updated_at = ?, seq = ? WHERE id = ?',
        'sold', endedOn, saleCents, made ? made.row.id : null, db.now(), db.nextSeq(), row.id,
      );
      idem.remember(db, 'asset.sell', clientId, row.id);
      return db.get('SELECT * FROM assets WHERE id = ?', row.id);
    });
    sendJson(res, 200, { asset: crud.toJson(next) });
  }

  return {
    name: 'assets',
    routes: [
      ...crud.routes,
      { method: 'POST', pattern: '/assets/:id/sell', handler: sell },
    ],
  };
};
