'use strict';

// 流水。这张表是整个账本，别的东西都是它的视角。四件事在这里定死：
//
//   1. 幂等：`clientId` 是客户端生成的主键。同一个 clientId 再来一次，返回已有
//      的那条（200，不是 201），离线补传和重试都安全。
//   2. 转账的正交性：账户对（钱在哪）与基金对（钱归谁管）各自可选，至少要有一对。
//   3. 服务端查重：只有通知/分享抓来的记录才查 —— 手工录入的「两杯一样的咖啡」
//      是真的两杯。命中就落成 status:'duplicate' 并把响应标上 duplicate:true。
//   4. 软删 + seq：删除只是墓碑，别的设备靠 GET /changes 才知道该删。
//
// 时间模型：`occurredAt` 原样存客户端给的「带时区偏移的本地时间」（如
// `2026-09-05T01:00:00+08:00`），服务端**不做时区换算**。所以按日期筛选比的是
// 字符串前 10 位（本地日期），排序与游标比的也是这个字符串；只有查重是按真实
// 瞬间（epoch 毫秒）判的。

const crypto = require('node:crypto');

const { HttpError, sendJson } = require('../lib/router');
const { rowToJson } = require('../lib/db');
const { logActivity } = require('../lib/activity');
const v = require('../lib/validate');

const TYPES = ['expense', 'income', 'transfer'];
const SOURCES = ['manual', 'notification', 'share', 'import', 'recurring'];
const STATUSES = ['confirmed', 'pending', 'duplicate', 'void'];
/** 新建时只能说「确认」或「待确认」——duplicate/void 是服务端和流转的结果。 */
const CREATE_STATUSES = ['confirmed', 'pending'];
/** 只有这两种来源会触发查重。 */
const DEDUPE_SOURCES = new Set(['notification', 'share']);
const DEDUPE_WINDOW_MS = 180 * 1000;
// occurred_at 存的是带偏移的本地时间，字符串粗筛时它可能比同一瞬间的 UTC 串前后
// 差一整个时区（-12:00 ~ +14:00）。粗筛放宽 26 小时，精确判定仍在 JS 里按毫秒做。
const OFFSET_SLACK_MS = 26 * 3600 * 1000;
const MAX_BATCH = 200;
const DEFAULT_LIMIT = 50;
const MAX_LIMIT = 200;
const MAX_AMOUNT = 1e14;

const txJson = (row) => rowToJson(row, { json: ['tags'] });

/** `YYYY-MM-DDTHH:MM:SS[.mmm](Z|±HH:MM)` —— 偏移必须写出来，否则「哪一天」没有答案。 */
const ISO_OFFSET_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$/;
const DATE_ONLY_RE = /^\d{4}-\d{2}-\d{2}$/;

/**
 * 服务器本地墙上时间 + 数字偏移（秒精度），如 `2026-09-13T01:00:00+08:00`。
 * `db.now()` 给的是 UTC `…Z`，拿它当 occurredAt 的默认值会让北京时间凌晨
 * 「记一笔（不填时间）」掉进前一个本地日/月，所有按前缀切分的统计都会错位。
 */
function localIso(date = new Date()) {
  const p = (n) => String(n).padStart(2, '0');
  const offsetMin = -date.getTimezoneOffset();
  const sign = offsetMin < 0 ? '-' : '+';
  const abs = Math.abs(offsetMin);
  return (
    `${date.getFullYear()}-${p(date.getMonth() + 1)}-${p(date.getDate())}` +
    `T${p(date.getHours())}:${p(date.getMinutes())}:${p(date.getSeconds())}` +
    `${sign}${p(Math.floor(abs / 60))}:${p(abs % 60)}`
  );
}

/**
 * 校验一个带偏移的 ISO 时刻，**原样返回**（不转 UTC）：客户端的本地日期才是
 * 用户心里的「那天」，换算成 UTC 会让 01:00 的早餐掉到前一天的账上。
 */
function isoInstant(raw, field) {
  if (typeof raw !== 'string' || !ISO_OFFSET_RE.test(raw) || Number.isNaN(Date.parse(raw))) {
    v.bad(field, `${field} 必须是带时区偏移的 ISO-8601 时间，如 2026-09-05T01:00:00+08:00`);
  }
  return raw;
}

/**
 * 找出这条新记录可能重复的那一笔：同 type、同金额、发生时间相差 ≤180s，
 * 且自己没被删/没被标成 duplicate 或 void 的行里最早的一条。
 * @returns {object|null} 原始那笔的行，没有就是 null
 */
function detectDuplicate(db, { type, amountCents, occurredAt, excludeId = null }) {
  const t = Date.parse(occurredAt);
  if (Number.isNaN(t)) return null;
  // ISO 串在 SQL 里按字典序粗筛一遍（走 idx_tx_dedupe），真正的判定在 JS 里按毫秒做。
  const rows = db.all(
    'SELECT * FROM transactions WHERE deleted_at IS NULL AND type = ? AND amount_cents = ?' +
      " AND status NOT IN ('duplicate', 'void') AND occurred_at >= ? AND occurred_at <= ?",
    type, amountCents,
    new Date(t - DEDUPE_WINDOW_MS - OFFSET_SLACK_MS).toISOString(),
    new Date(t + DEDUPE_WINDOW_MS + OFFSET_SLACK_MS).toISOString(),
  );
  let best = null;
  let bestAt = Infinity;
  for (const row of rows) {
    if (excludeId && row.id === excludeId) continue;
    const at = Date.parse(row.occurred_at);
    if (Number.isNaN(at) || Math.abs(at - t) > DEDUPE_WINDOW_MS) continue;
    if (at < bestAt || (at === bestAt && best && row.id < best.id)) {
      best = row;
      bestAt = at;
    }
  }
  return best;
}

module.exports = (ctx) => {
  const { db, log } = ctx;

  const byId = (id) => db.get('SELECT * FROM transactions WHERE id = ? AND deleted_at IS NULL', id);
  const reread = (id) => db.get('SELECT * FROM transactions WHERE id = ?', id);

  function mustExist(id) {
    const row = byId(id);
    if (!row) throw new HttpError(404, 'not_found', '这笔流水不存在');
    return row;
  }

  /** 支出/收入没写基金时的落脚点：默认基金，没有默认就用第一个还在用的基金。 */
  function fallbackFundId() {
    const row =
      db.get('SELECT id FROM funds WHERE is_default = 1 AND archived = 0 AND deleted_at IS NULL LIMIT 1') ||
      db.get('SELECT id FROM funds WHERE archived = 0 AND deleted_at IS NULL ORDER BY sort_order, created_at LIMIT 1');
    return row ? row.id : null;
  }

  /**
   * 请求体 → 待写入的列。`row` 为空是新建，否则是 PATCH（没传的字段沿用旧值）。
   * 返回的对象不含 id / client_id / created_by / created_at / updated_at / seq。
   */
  function normalize(body, { row = null, member }) {
    const b = v.body(body);
    const isNew = !row;
    const given = (name) => b[name] !== undefined;
    /** 新建时永远校验（缺就报错），PATCH 只在传了的时候校验。 */
    const take = (name, validate, existing) => (given(name) || isNew ? validate(b[name]) : existing);

    const type = take('type', (x) => v.enumOf(x, 'type', TYPES), row?.type);
    const amountCents = take('amountCents', (x) => v.int(x, 'amountCents', { min: 0, max: MAX_AMOUNT }), row?.amount_cents);
    const occurredAt = given('occurredAt')
      ? isoInstant(b.occurredAt, 'occurredAt')
      : (row ? row.occurred_at : localIso());
    const status = given('status')
      ? v.enumOf(b.status, 'status', isNew ? CREATE_STATUSES : STATUSES)
      : (row ? row.status : 'confirmed');
    const source = given('source') ? v.enumOf(b.source, 'source', SOURCES) : (row ? row.source : 'manual');
    const currency = given('currency')
      ? (() => {
          const c = v.str(b.currency, 'currency', { min: 3, max: 3 }).toUpperCase();
          if (!/^[A-Z]{3}$/.test(c)) v.bad('currency', '币种必须是 3 个字母的代码');
          return c;
        })()
      : (row ? row.currency : db.meta('currency', 'CNY'));

    /**
     * 引用列。客户端这次传了才校验「指到的东西还在不在」—— 已归档可以指，
     * 已删除不行；没传就沿用旧值，免得历史流水因为基金后来被删而改不动。
     */
    const ref = (name, col, table, label) => {
      if (!given(name)) return row ? row[col] : null;
      const id = v.optStr(b[name], name, { max: 64 });
      if (id && !db.get(`SELECT 1 AS ok FROM ${table} WHERE id = ? AND deleted_at IS NULL`, id)) {
        v.bad(name, `${label}不存在`);
      }
      return id;
    };
    const text = (name, col, max) => (given(name) ? (v.optStr(b[name], name, { max }) ?? '') : (row ? row[col] : ''));

    let accountId = ref('accountId', 'account_id', 'accounts', '账户');
    let toAccountId = ref('toAccountId', 'to_account_id', 'accounts', '转入账户');
    let fundId = ref('fundId', 'fund_id', 'funds', '基金');
    let toFundId = ref('toFundId', 'to_fund_id', 'funds', '转入基金');

    if (type === 'transfer') {
      // 一对要么都有要么都没有：只填了一半，钱就会从一边消失而没有落点。
      // PATCH 也走这里，比的是「旧行 + 本次改动」合并之后的结果。
      if (!accountId !== !toAccountId) {
        throw new HttpError(400, 'invalid_transfer', '账户转账要同时填 accountId 和 toAccountId');
      }
      if (!fundId !== !toFundId) {
        throw new HttpError(400, 'invalid_transfer', '基金拨款要同时填 fundId 和 toFundId');
      }
      if (!accountId && !fundId) {
        throw new HttpError(400, 'invalid_transfer', '转账至少要填一对：账户→账户，或基金→基金');
      }
      if (accountId && accountId === toAccountId) v.bad('toAccountId', '转出和转入不能是同一个账户');
      if (fundId && fundId === toFundId) v.bad('toFundId', '转出和转入不能是同一个基金');
    } else {
      // 支出/收入只有单边；对手方留着会让余额算两遍。
      toAccountId = null;
      toFundId = null;
      if (!fundId) {
        fundId = fallbackFundId();
        if (!fundId) v.bad('fundId', '请先建一个基金，或在请求里指定 fundId');
      }
    }

    return {
      type,
      amount_cents: amountCents,
      currency,
      occurred_at: occurredAt,
      account_id: accountId,
      to_account_id: toAccountId,
      fund_id: fundId,
      to_fund_id: toFundId,
      category_id: type === 'transfer' ? null : ref('categoryId', 'category_id', 'categories', '类别'),
      member_id: ref('memberId', 'member_id', 'members', '成员') || row?.member_id || member.id,
      merchant: text('merchant', 'merchant', 120),
      note: text('note', 'note', 1000),
      tags: given('tags')
        ? JSON.stringify(v.list(b.tags, 'tags', { max: 32 }).map((x) => v.str(x, 'tags', { max: 32 })))
        : (row ? row.tags : '[]'),
      source,
      status,
      confidence: given('confidence') ? (v.isMissing(b.confidence) ? null : v.num(b.confidence, 'confidence', { min: 0, max: 1 })) : (row ? row.confidence : null),
      raw_text: given('rawText') ? v.optStr(b.rawText, 'rawText', { max: 4000 }) : (row ? row.raw_text : null),
      source_app: given('sourceApp') ? v.optStr(b.sourceApp, 'sourceApp', { max: 120 }) : (row ? row.source_app : null),
      capture_id: given('captureId') ? v.optStr(b.captureId, 'captureId', { max: 64 }) : (row ? row.capture_id : null),
    };
  }

  /**
   * 写一条流水。校验先做（不占写锁），幂等检查与查重在同一个事务里。
   * @returns {{row: object, created: boolean, duplicate: boolean}}
   */
  function createOne(body, reqCtx) {
    const b = v.body(body);
    const clientId = v.optStr(b.clientId, 'clientId', { max: 64 });
    const existing = clientId ? db.get('SELECT * FROM transactions WHERE client_id = ?', clientId) : null;
    if (existing) return { row: existing, created: false, duplicate: false };

    const cols = normalize(b, { member: reqCtx.member });

    return db.tx(() => {
      if (clientId) {
        const again = db.get('SELECT * FROM transactions WHERE client_id = ?', clientId);
        if (again) return { row: again, created: false, duplicate: false };
      }
      let duplicate = false;
      if (DEDUPE_SOURCES.has(cols.source)) {
        const other = detectDuplicate(db, {
          type: cols.type,
          amountCents: cols.amount_cents,
          occurredAt: cols.occurred_at,
        });
        if (other) {
          duplicate = true;
          cols.status = 'duplicate';
          cols.duplicate_of_id = other.id;
        }
      }
      const id = crypto.randomUUID();
      const now = db.now();
      const all = {
        id,
        client_id: clientId,
        ...cols,
        created_by: reqCtx.member.id,
        created_at: now,
        updated_at: now,
        seq: db.nextSeq(),
      };
      const keys = Object.keys(all);
      db.run(
        `INSERT INTO transactions(${keys.join(', ')}) VALUES(${keys.map(() => '?').join(', ')})`,
        ...keys.map((k) => all[k]),
      );
      logActivity(db, { memberId: reqCtx.member.id, action: 'create', entity: 'transaction', entityId: id, at: now });
      return { row: reread(id), created: true, duplicate };
    });
  }

  function create(req, res, reqCtx) {
    const { row, created, duplicate } = createOne(reqCtx.body, reqCtx);
    const out = { transaction: txJson(row) };
    if (duplicate) out.duplicate = true;
    sendJson(res, created ? 201 : 200, out);
  }

  /** 批量导入/补传：每条各自成败，HTTP 恒 200，客户端按 results 逐条处理。 */
  function batch(req, res, reqCtx) {
    const b = v.body(reqCtx.body);
    const items = v.list(b.items, 'items', { max: MAX_BATCH, required: true });
    const results = items.map((item) => {
      const clientId = v.isObject(item) && typeof item.clientId === 'string' ? item.clientId : null;
      try {
        const { row, created, duplicate } = createOne(item, reqCtx);
        const out = { clientId, id: row.id, status: created ? 'created' : 'exists' };
        if (duplicate) out.duplicate = true;
        return out;
      } catch (e) {
        if (!(e instanceof HttpError)) log.error('transactions', `batch item failed: ${e.stack || e}`);
        return {
          clientId,
          status: 'error',
          error: e instanceof HttpError ? e.code : 'internal',
          message: e instanceof HttpError ? e.message : '服务器内部错误',
        };
      }
    });
    sendJson(res, 200, { results });
  }

  // ── 列表 ───────────────────────────────────────────────────────────────
  const encodeCursor = (row) => Buffer.from(`${row.occurred_at}|${row.id}`, 'utf8').toString('base64url');

  function decodeCursor(raw) {
    const text = Buffer.from(String(raw), 'base64url').toString('utf8');
    const at = text.indexOf('|');
    if (at <= 0 || at === text.length - 1) v.bad('cursor', '游标无效');
    return { occurredAt: text.slice(0, at), id: text.slice(at + 1) };
  }

  /**
   * 日期边界。只给日期（`2026-09-05`）时比的是 `occurred_at` 的前 10 位，也就是
   * **客户端本地的那一天** —— 北京时间凌晨 1 点的那顿夜宵算 5 号，不能因为它的
   * UTC 是 4 号就掉出去。给完整 ISO 时刻时按字符串原样比。
   * @returns {{sql: string, value: string}}
   */
  function bound(raw, field, upper) {
    const op = upper ? '<=' : '>=';
    if (DATE_ONLY_RE.test(raw)) {
      if (Number.isNaN(Date.parse(`${raw}T00:00:00Z`))) v.bad(field, `${field} 不是有效日期`);
      return { sql: `substr(occurred_at, 1, 10) ${op} ?`, value: raw };
    }
    return { sql: `occurred_at ${op} ?`, value: isoInstant(raw, field) };
  }

  function list(req, res, reqCtx) {
    const q = reqCtx.query;
    const where = ['deleted_at IS NULL'];
    const args = [];
    const add = (sql, ...vals) => {
      where.push(sql);
      args.push(...vals);
    };
    const has = (name) => q[name] !== undefined && q[name] !== '';

    if (has('type')) add('type = ?', v.enumOf(q.type, 'type', TYPES));
    if (has('status')) add('status = ?', v.enumOf(q.status, 'status', STATUSES));
    if (has('source')) add('source = ?', v.enumOf(q.source, 'source', SOURCES));
    // 基金/账户过滤把「转入这一侧」也算上：拨进某个基金的那笔，是这个基金的流水。
    if (has('fundId')) add('(fund_id = ? OR to_fund_id = ?)', q.fundId, q.fundId);
    if (has('accountId')) add('(account_id = ? OR to_account_id = ?)', q.accountId, q.accountId);
    if (has('categoryId')) add('category_id = ?', q.categoryId);
    if (has('memberId')) add('member_id = ?', q.memberId);
    for (const [param, upper] of [['from', false], ['to', true]]) {
      if (!has(param)) continue;
      const b = bound(q[param], param, upper);
      add(b.sql, b.value);
    }
    if (has('q')) {
      const needle = `%${String(q.q).replace(/[\\%_]/g, (c) => `\\${c}`)}%`;
      add("(merchant LIKE ? ESCAPE '\\' OR note LIKE ? ESCAPE '\\')", needle, needle);
    }
    if (has('cursor')) {
      const c = decodeCursor(q.cursor);
      add('(occurred_at < ? OR (occurred_at = ? AND id < ?))', c.occurredAt, c.occurredAt, c.id);
    }
    const limit = has('limit') ? v.int(q.limit, 'limit', { min: 1, max: MAX_LIMIT }) : DEFAULT_LIMIT;

    const rows = db.all(
      `SELECT * FROM transactions WHERE ${where.join(' AND ')} ORDER BY occurred_at DESC, id DESC LIMIT ?`,
      ...args, limit + 1,
    );
    const page = rows.slice(0, limit);
    const out = { items: page.map(txJson) };
    if (rows.length > limit) out.nextCursor = encodeCursor(page[page.length - 1]);
    sendJson(res, 200, out);
  }

  // ── 单条 ───────────────────────────────────────────────────────────────
  function read(req, res, reqCtx) {
    sendJson(res, 200, { transaction: txJson(mustExist(reqCtx.params.id)) });
  }

  function patch(req, res, reqCtx) {
    const row = mustExist(reqCtx.params.id);
    const cols = normalize(reqCtx.body, { row, member: reqCtx.member });
    const next = db.tx(() => {
      const keys = Object.keys(cols);
      db.run(
        `UPDATE transactions SET ${[...keys.map((k) => `${k} = ?`), 'updated_at = ?', 'seq = ?'].join(', ')} WHERE id = ?`,
        ...keys.map((k) => cols[k]), db.now(), db.nextSeq(), row.id,
      );
      logActivity(db, { memberId: reqCtx.member.id, action: 'update', entity: 'transaction', entityId: row.id });
      return reread(row.id);
    });
    sendJson(res, 200, { transaction: txJson(next) });
  }

  function remove(req, res, reqCtx) {
    const row = mustExist(reqCtx.params.id);
    const next = db.tx(() => {
      const now = db.now();
      db.run('UPDATE transactions SET deleted_at = ?, updated_at = ?, seq = ? WHERE id = ?', now, now, db.nextSeq(), row.id);
      logActivity(db, { memberId: reqCtx.member.id, action: 'delete', entity: 'transaction', entityId: row.id, at: now });
      return reread(row.id);
    });
    sendJson(res, 200, { transaction: txJson(next) });
  }

  /** confirm / void：状态流转是单独的接口，客户端不用拼 PATCH 体。 */
  const setStatus = (status) => (req, res, reqCtx) => {
    const row = mustExist(reqCtx.params.id);
    const next = db.tx(() => {
      db.run('UPDATE transactions SET status = ?, updated_at = ?, seq = ? WHERE id = ?', status, db.now(), db.nextSeq(), row.id);
      logActivity(db, { memberId: reqCtx.member.id, action: status, entity: 'transaction', entityId: row.id });
      return reread(row.id);
    });
    sendJson(res, 200, { transaction: txJson(next) });
  };

  return {
    name: 'transactions',
    routes: [
      { method: 'GET', pattern: '/transactions', handler: list, maxBody: 0 },
      { method: 'POST', pattern: '/transactions', handler: create },
      // 一批 200 条，64KB 的默认上限不够。
      { method: 'POST', pattern: '/transactions/batch', handler: batch, maxBody: 2 * 1024 * 1024 },
      { method: 'GET', pattern: '/transactions/:id', handler: read, maxBody: 0 },
      { method: 'PATCH', pattern: '/transactions/:id', handler: patch },
      { method: 'DELETE', pattern: '/transactions/:id', handler: remove, maxBody: 0 },
      { method: 'POST', pattern: '/transactions/:id/confirm', handler: setStatus('confirmed') },
      { method: 'POST', pattern: '/transactions/:id/void', handler: setStatus('void') },
    ],
  };
};

// 查重规则给导入/恢复这类「不走 HTTP 的写入」共用（导出函数上的属性，装载器只看
// 导出本身是不是函数，所以不影响自动装载）。
module.exports.detectDuplicate = detectDuplicate;
