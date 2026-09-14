'use strict';

// 同步游标。客户端拿着上次的 `next` 来问「seq 比这个大的都给我」，一次请求跨
// 所有可同步的表，按 seq 升序取一页。含软删的墓碑行（带 deletedAt），客户端据此
// 删本地行。members 永远剔掉口令散列。
//
// `limit` 是跨表总数，不是每表；`next` 是本页返回的最大 seq。由于每写一行都取
// 一个新的 seq（没有两行共用一个），按 `since = next` 接着问不会漏行。

const { sendJson } = require('../lib/router');
const { rowToJson } = require('../lib/db');
const v = require('../lib/validate');

const DEFAULT_LIMIT = 500;
const MAX_LIMIT = 2000;

/**
 * 参与同步的表，以及各自哪些列要还原成布尔/JSON。
 * 加同步表 = 在这里加一行（响应里的键名就是表名）。
 */
const SYNCED = [
  ['members', { omit: ['password_hash'], bools: ['archived'] }],
  ['accounts', { bools: ['archived'], json: ['match_hints'] }],
  ['funds', { bools: ['archived', 'is_default'] }],
  ['categories', { bools: ['archived'] }],
  ['transactions', { json: ['tags'] }],
  ['budgets', {}],
  ['rules', { bools: ['enabled'] }],
];

module.exports = (ctx) => {
  const { db } = ctx;

  function changes(req, res, reqCtx) {
    const q = reqCtx.query;
    const since = q.since === undefined || q.since === '' ? 0 : v.int(q.since, 'since', { min: 0 });
    const limit = q.limit === undefined || q.limit === '' ? DEFAULT_LIMIT : v.int(q.limit, 'limit', { min: 1, max: MAX_LIMIT });

    const buckets = {};
    const pending = [];
    for (const [table, opts] of SYNCED) {
      buckets[table] = [];
      // limit + 1 per table: enough to know whether anything is left over once
      // every table's rows are merged and cut at `limit`.
      const rows = db.all(`SELECT * FROM ${table} WHERE seq > ? ORDER BY seq ASC LIMIT ?`, since, limit + 1);
      for (const row of rows) pending.push({ table, opts, row, seq: Number(row.seq) });
    }
    pending.sort((a, b) => a.seq - b.seq);

    const more = pending.length > limit;
    let next = since;
    for (const item of pending.slice(0, limit)) {
      buckets[item.table].push(rowToJson(item.row, item.opts));
      if (item.seq > next) next = item.seq;
    }

    sendJson(res, 200, { since, next, more, ...buckets });
  }

  return {
    name: 'changes',
    routes: [{ method: 'GET', pattern: '/changes', handler: changes, maxBody: 0 }],
  };
};

module.exports.SYNCED = SYNCED;
