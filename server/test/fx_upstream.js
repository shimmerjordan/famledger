'use strict';

// 假的腾讯外汇源，供 fx.test.js 与 stats.test.js 共用（多币种聚合的折算要靠它把
// fx_rates 填起来）。只认 `/q=whXXXYYY,…`：`state.rates[symbol]`（symbol 照腾讯的写法大写，
// 如 `whUSDCNY`）是现价串。**和真的腾讯一样区分大小写**：请求里写成小写的 `whusdcny` 查不到，
// 回 `v_pv_none_match` —— 之前假源不分大小写，源码小写请求的 bug 在测试里一直是绿的。字段位照真实
// 返回拼：
//   [0]=310 [1]=名 [2]=代码 [3]=现价 [4]=0（外汇恒 0，不是昨收） [5]=时间戳 … 末位=日期
// `state.fail = true` 时整页 500，用来演练上游挂了也不炸。

const http = require('node:http');

async function startFakeFx() {
  const state = { rates: {}, requests: [], fail: false };
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://x');
    state.requests.push(url.pathname);
    if (!url.pathname.startsWith('/q=')) {
      res.writeHead(404);
      return res.end();
    }
    if (state.fail) {
      res.writeHead(500);
      return res.end('nope');
    }
    const parts = [];
    for (const sym of url.pathname.slice(3).split(',')) {
      const price = state.rates[sym];
      if (price === undefined) {
        parts.push(Buffer.from('v_pv_none_match="1";\n'));
        continue;
      }
      const code = sym.slice(2).toUpperCase();
      parts.push(
        Buffer.from(`v_${sym}="310~${code}~${code}~${price}~0~20261013180539~${price}~${price}~0~0~${price}~0~2026-10-13";\n`),
      );
    }
    res.writeHead(200, { 'content-type': 'text/html; charset=GBK' });
    res.end(Buffer.concat(parts));
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return {
    base: `http://127.0.0.1:${server.address().port}`,
    state,
    stop: () =>
      new Promise((resolve) => {
        server.closeAllConnections?.();
        server.close(() => resolve());
      }),
  };
}

module.exports = { startFakeFx };
