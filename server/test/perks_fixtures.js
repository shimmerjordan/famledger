'use strict';

// 会员权益测试共用的一招：接口写不出来的东西（比如形状不规整的老 pay_pattern —— P6 起 payPattern 有接口写，但只收
// 规整过的形状）只能直接写进库里。服务端进程独占着库，所以先停掉它、写完再用同一个数据目录起一个新的
// （同一把密钥，原来的令牌照样能用）。

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

module.exports = { restartWith };
