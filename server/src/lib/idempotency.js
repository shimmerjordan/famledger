'use strict';

// 写接口的幂等键。流水走 transactions.client_id 那一套；这里管的是「一次请求改好几样东西」
// 的接口 —— 开仓、加减仓、记物品、卖物品 —— 它们没有一行可以挂 client_id 的流水
// （加仓可以不记账，卖出记的是两笔），只能单独记一张 clientId → 第一次结果的表。
//
//   const idem = require('../lib/idempotency');
//   const clientId = idem.clientIdOf(body);           // 可选；格式不对是 400 invalid_clientId
//   const hit = idem.lookup(db, 'holding.trade', clientId);   // 命中 → 回放，不再执行
//   db.tx(() => { …写…; idem.remember(db, 'holding.trade', clientId, holdingId, response); });
//
// remember 必须和写入在同一个事务里：先写后记，中间崩了就又回到「落库了却认不出重发」。
// 请求失败（校验 400、事务回滚）什么都不记，同一个 clientId 改好再发会照常执行。

const v = require('./validate');

// App 只会在表单还开着、刚失败的那几分钟里重发；留一个月足够，也不让表无限长。
const KEEP_MS = 30 * 24 * 3600 * 1000;

/** 请求体里的 clientId；没给就是 null（不做幂等，和以前一样）。 */
function clientIdOf(body) {
  return v.optStr(body && body.clientId, 'clientId', { max: 64 });
}

/** @returns {{refId: string, response: object|null}|null} */
function lookup(db, scope, clientId) {
  if (!clientId) return null;
  const row = db.get('SELECT ref_id, response FROM idempotency WHERE scope = ? AND client_id = ?', scope, clientId);
  if (!row) return null;
  return { refId: row.ref_id, response: row.response ? JSON.parse(row.response) : null };
}

function remember(db, scope, clientId, refId, response = null) {
  if (!clientId) return;
  const now = new Date();
  // 命中却找不到当初那行（只有手工动过库才会）时调用方会照常执行，这里覆盖掉那条死键。
  db.run(
    'INSERT INTO idempotency(scope, client_id, ref_id, response, created_at) VALUES(?, ?, ?, ?, ?)' +
      ' ON CONFLICT(scope, client_id) DO UPDATE SET ref_id = excluded.ref_id, response = excluded.response,' +
      ' created_at = excluded.created_at',
    scope, clientId, refId, response === null ? null : JSON.stringify(response), now.toISOString(),
  );
  db.run('DELETE FROM idempotency WHERE created_at < ?', new Date(now.getTime() - KEEP_MS).toISOString());
}

module.exports = { clientIdOf, lookup, remember, KEEP_MS };
