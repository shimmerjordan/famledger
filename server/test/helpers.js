'use strict';

// Test helpers: spawn `src/server.js` as a real child process on a free port
// with a throw-away DATA_DIR and WEB_ROOT, and talk to it over real HTTP.
// Nothing is stubbed — every test exercises the same binary the deploy runs.

const { spawn } = require('node:child_process');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');

const SERVER = path.join(__dirname, '..', 'src', 'server.js');

// 找到了一个真实 bug：只钉死下面 startServer() 生成的子进程的 TZ 是不够的——
// 这个测试文件自己（node --test 的外层进程）也会调 `new Date().getHours()`
// 去配置「这个点」跑一次定时备份（见 backup.test.js 的调度用例），如果外层
// 进程和被钉死 Asia/Shanghai 的子进程站在两个不同时区，两边对「现在几点」
// 各说各话，调度器永远对不上「到点了」，定时备份一次都不会触发。
// 本地开发机通常本来就是 Asia/Shanghai（外层/子进程天然一致，测试怎么跑都是
// 绿的），但 GitHub Actions 的 ubuntu-latest 默认是 UTC——外层还是 UTC、子
// 进程被钉成 +8，两边正好差 8 小时，这两条调度测试在 CI 上必然失败（已用
// `TZ=UTC node --test test/backup.test.js` 在本地实锤复现，报错与 CI 日志
// 逐字一致）。在这里把外层进程自己也钉成 Asia/Shanghai，之前对子进程的钉法
// 才真正生效、两边才会一致——顺序很重要：必须在任何测试文件调用
// `new Date()` 之前执行，所以放在 helpers.js 最顶上，且每个测试文件都会
// require 这个模块。
process.env.TZ = 'Asia/Shanghai';

/** Ask the OS for a port nobody is using, then release it. */
function freePort() {
  return new Promise((resolve, reject) => {
    const s = net.createServer();
    s.on('error', reject);
    s.listen(0, '127.0.0.1', () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
  });
}

function tmpDir(tag) {
  return fs.mkdtempSync(path.join(os.tmpdir(), `famledger-${tag}-`));
}

/**
 * Start a server. `env` overrides any environment variable; DATA_DIR and
 * WEB_ROOT default to fresh temp directories.
 * @returns {Promise<{base:string, port:number, dataDir:string, webRoot:string, stderr:()=>string, stdout:()=>string, stop:()=>Promise<void>}>}
 */
async function startServer(env = {}) {
  const dataDir = env.DATA_DIR || tmpDir('data');
  const webRoot = env.WEB_ROOT || tmpDir('web');
  const port = await freePort();
  const child = spawn(process.execPath, [SERVER], {
    env: {
      ...process.env,
      PORT: String(port),
      HOST: '127.0.0.1',
      DATA_DIR: dataDir,
      WEB_ROOT: webRoot,
      LOG_LEVEL: 'error',
      // 部署镜像永远是 Asia/Shanghai（见 deploy/Dockerfile），本地开发机通常也是；
      // CI 的 ubuntu-latest 默认是 UTC。不钉死这个，任何按「本地日期/月份」判断
      // 的用例就会在本地和 CI 之间跑出不同结果——钉在这里而不是逐个测试里设，
      // 是因为所有测试都经这一个函数起服务端，钉一处即可，且仍可被 `env` 覆盖。
      TZ: 'Asia/Shanghai',
      ...env,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let err = '';
  child.stderr.on('data', (d) => {
    err += d.toString();
  });
  // info/debug 走 stdout（lib/log.js）；默认 LOG_LEVEL=error 时这里几乎是空的，
  // 只有传了 LOG_LEVEL 的用例（比如检查日志里不漏口令）才会攒下内容。
  let out = '';
  child.stdout.on('data', (d) => {
    out += d.toString();
  });

  const base = `http://127.0.0.1:${port}`;
  let up = false;
  for (let i = 0; i < 200 && !up; i++) {
    if (child.exitCode !== null) break;
    try {
      const r = await fetch(`${base}/healthz`);
      if (r.ok && (await r.text()) === 'ok') up = true;
    } catch {
      await new Promise((r) => setTimeout(r, 25));
    }
  }
  if (!up) {
    child.kill('SIGKILL');
    throw new Error(`server did not start on ${port}\n--- stderr ---\n${err}`);
  }

  return {
    base,
    port,
    dataDir,
    webRoot,
    stderr: () => err,
    stdout: () => out,
    stop: () =>
      new Promise((resolve) => {
        if (child.exitCode !== null) return resolve();
        child.on('exit', () => resolve());
        child.kill('SIGTERM');
        setTimeout(() => child.kill('SIGKILL'), 3000).unref();
      }),
  };
}

/**
 * HTTP client. `call`/`get`/`post`/… take a path relative to `/api/v1`;
 * `raw` takes an absolute path (for /healthz and static assets).
 */
function api(base) {
  async function raw(method, p, { token, body, headers, setupToken } = {}) {
    const h = { ...headers };
    if (token) h.authorization = `Bearer ${token}`;
    if (setupToken) h['x-setup-token'] = setupToken;
    let payload;
    if (body !== undefined) {
      h['content-type'] = 'application/json';
      payload = typeof body === 'string' ? body : JSON.stringify(body);
    }
    const r = await fetch(base + p, { method, headers: h, body: payload });
    const text = await r.text();
    let json = null;
    try {
      json = text ? JSON.parse(text) : null;
    } catch {
      /* not JSON — callers use .text */
    }
    return { status: r.status, json, text, headers: r.headers };
  }
  const call = (method, p, opts) => raw(method, `/api/v1${p}`, opts);
  return {
    raw,
    call,
    get: (p, opts) => call('GET', p, opts),
    post: (p, body, opts) => call('POST', p, { ...opts, body }),
    patch: (p, body, opts) => call('PATCH', p, { ...opts, body }),
    del: (p, opts) => call('DELETE', p, opts),
  };
}

module.exports = { startServer, api, freePort, tmpDir };
