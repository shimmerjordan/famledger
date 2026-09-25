'use strict';

// 会员权益测试共用的一招：P2 还没有 /benefit-events 接口、也没有写 pay_pattern 的接口，这些只能直接写进库里。
// 服务端进程独占着库，所以先停掉它、写完再用同一个数据目录起一个新的（同一把密钥，原来的令牌照样能用）。

const { startServer, api } = require('./helpers');
const { openDb } = require('../src/lib/db');

/**
 * 停掉服务、在一个事务里跑 `write(db)`、再起一个新服务。
 *
 * @param {import('node:test').TestContext} t
 * @param {{dataDir:string, webRoot:string, stop:()=>Promise<void>}} srv household(t) 起的那个服务
 * @param {(db: ReturnType<typeof openDb>) => void} write
 * @returns {Promise<ReturnType<typeof api>>} 新服务的 HTTP 客户端
 */
async function restartWith(t, srv, write) {
  await srv.stop();
  const db = openDb(srv.dataDir);
  try {
    db.tx(() => write(db));
  } finally {
    db.close();
  }
  const next = await startServer({ DATA_DIR: srv.dataDir, WEB_ROOT: srv.webRoot });
  t.after(() => next.stop());
  return api(next.base);
}

/**
 * @param {import('node:test').TestContext} t
 * @param {{dataDir:string, webRoot:string, stop:()=>Promise<void>}} srv
 * @param {{id:string, benefitId:string}[]} events
 */
function restartWithEvents(t, srv, events) {
  return restartWith(t, srv, (db) => {
    const now = new Date().toISOString();
    for (const e of events) {
      db.run(
        "INSERT INTO benefit_events(id, benefit_id, kind, occurred_on, created_at, updated_at, seq) VALUES(?, ?, 'claim', '2026-09-01', ?, ?, ?)",
        e.id, e.benefitId, now, now, db.nextSeq(),
      );
    }
  });
}

module.exports = { restartWith, restartWithEvents };
