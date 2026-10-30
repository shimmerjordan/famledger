'use strict';

// 测试脚手架自己的行为：startServer 起服务端子进程这一步不能偶发失败。

const test = require('node:test');
const assert = require('node:assert/strict');
const net = require('node:net');

const { startServer, freePort } = require('./helpers');

test('startServer：问到的端口在子进程 listen 之前被别人占了（EADDRINUSE），换一个端口重起', async (t) => {
  // 占住一个端口；连进来的直接断开，让健康检查快速失败而不是挂着等。
  const blocker = net.createServer((s) => s.destroy());
  await new Promise((r) => blocker.listen(0, '127.0.0.1', r));
  t.after(() => blocker.close());
  const busy = blocker.address().port;

  const tried = [];
  const srv = await startServer({}, {
    pickPort: async () => {
      const p = tried.length === 0 ? busy : await freePort();
      tried.push(p);
      return p;
    },
  });
  t.after(() => srv.stop());

  assert.equal(tried.length, 2, '第一次撞上，第二次起来');
  assert.equal(tried[0], busy);
  assert.equal(srv.port, tried[1]);
  const r = await fetch(`${srv.base}/healthz`);
  assert.equal(await r.text(), 'ok');
});
