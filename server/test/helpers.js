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
 * @returns {Promise<{base:string, port:number, dataDir:string, webRoot:string, stderr:()=>string, stop:()=>Promise<void>}>}
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
  child.stdout.resume();

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
