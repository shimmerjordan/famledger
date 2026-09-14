'use strict';

// famledger server — one process, one SQLite file, zero npm dependencies.
//
//   HTTP ─▶ CORS ─▶ /healthz ─▶ router.dispatch (/api/v1/*, auth + body + JSON)
//                                    │ no match
//                                    ├─ /api/… → 404 JSON
//                                    └─ else   → modules/static.js fallback (SPA)
//
// Every file in `src/modules/` whose export is a *function* is a module
// factory `(ctx) => ({ name, routes, start?, stop?, fallback? })` and is loaded
// automatically, in filename order — adding an endpoint never means editing
// this file. Files exporting an object (seed.js, ai_prompts.js, …) are shared
// helpers and are skipped.
//
// Configuration is entirely environment variables; see README.

const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');

const log = require('./lib/log');
const { openDb } = require('./lib/db');
const { loadOrCreateSecret } = require('./lib/secret');
const { createAuthenticator } = require('./lib/auth');
const { Router, sendJson, sendError } = require('./lib/router');

const API_PREFIX = '/api/v1';

/** A number from the environment, or the default when it is absent or nonsense. */
function envInt(name, dflt, min = 0) {
  const n = Number(process.env[name]);
  return Number.isFinite(n) && Number.isInteger(n) && n >= min ? n : dflt;
}

const cfg = {
  port: envInt('PORT', 48090),
  host: process.env.HOST || '0.0.0.0',
  dataDir: process.env.DATA_DIR || './data',
  webRoot: process.env.WEB_ROOT || '/web',
  trustProxy: process.env.TRUST_PROXY === '1',
  setupToken: process.env.SETUP_TOKEN || '',
  corsOrigins: (process.env.CORS_ORIGINS || '').split(',').map((s) => s.trim()).filter(Boolean),
  logLevel: (process.env.LOG_LEVEL || 'info').toLowerCase(),
  // Never 0 and never NaN: either would turn a limiter into a lockout or into
  // a no-op, and both fail silently.
  loginPerMin: envInt('LOGIN_PER_MIN', 10, 1),
  setupPerMin: envInt('SETUP_PER_MIN', 5, 1),
};

const db = openDb(cfg.dataDir);
const secret = loadOrCreateSecret(cfg.dataDir);
/** What every module factory receives. */
const ctx = { cfg, db, secret, log };

/** Load `src/modules/*.js`; a function export is a module, anything else is a helper. */
function loadModules() {
  const dir = path.join(__dirname, 'modules');
  const loaded = [];
  for (const file of fs.readdirSync(dir).filter((f) => f.endsWith('.js')).sort()) {
    const factory = require(path.join(dir, file));
    if (typeof factory !== 'function') continue;
    const mod = factory(ctx);
    if (!mod || typeof mod.name !== 'string') {
      throw new Error(`modules/${file} must return { name, routes?, start?, stop?, fallback? }`);
    }
    loaded.push(mod);
  }
  return loaded;
}

const modules = loadModules();
const router = new Router({
  authenticate: createAuthenticator({ db }, secret),
  trustProxy: cfg.trustProxy,
  prefix: API_PREFIX,
});
for (const m of modules) {
  for (const r of m.routes || []) {
    router.add(r.method, r.pattern, r.handler, { maxBody: r.maxBody, auth: r.auth });
  }
}
const fallbacks = modules.filter((m) => typeof m.fallback === 'function');

/**
 * Set CORS headers when CORS_ORIGINS is configured (the app talks to the API
 * from its own origin, so this is only for a separately hosted web build).
 * @returns {boolean} true when the request was a preflight and is now answered.
 */
function handleCors(req, res) {
  if (cfg.corsOrigins.length === 0) return false;
  const origin = req.headers.origin;
  const any = cfg.corsOrigins.includes('*');
  if (any) res.setHeader('access-control-allow-origin', origin || '*');
  else if (origin && cfg.corsOrigins.includes(origin)) res.setHeader('access-control-allow-origin', origin);
  // Both branches answer with a value that depends on the request's Origin (the
  // `*` branch echoes it too), so any cache in between must key on that header.
  res.setHeader('vary', 'Origin');

  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'access-control-allow-methods': 'GET, POST, PATCH, PUT, DELETE, OPTIONS',
      'access-control-allow-headers': 'authorization, content-type, x-setup-token',
      'access-control-max-age': '600',
      'content-length': 0,
    });
    res.end();
    return true;
  }
  return false;
}

const server = http.createServer(async (req, res) => {
  try {
    if (handleCors(req, res)) return;

    const pathname = new URL(req.url, 'http://localhost').pathname;
    if (pathname === '/healthz') {
      res.writeHead(200, { 'content-type': 'text/plain; charset=utf-8', 'content-length': 2 });
      return res.end('ok');
    }

    if (await router.dispatch(req, res)) return;

    // Inside the API namespace an unmatched path is an error, never the SPA.
    if (pathname === '/api' || pathname.startsWith('/api/')) {
      return sendError(res, 404, 'not_found', `${req.method} ${pathname} 不存在`);
    }
    for (const m of fallbacks) {
      if (await m.fallback(req, res)) return;
    }
    sendError(res, 404, 'not_found', '资源不存在');
  } catch (e) {
    log.error('http', `${req.method} ${req.url} → ${e.stack || e}`);
    if (res.headersSent) res.destroy();
    else sendJson(res, 500, { error: { code: 'internal', message: '服务器内部错误' } });
  }
});

// Short timeouts keep half-open connections from pinning sockets. SSE replies
// set their own (see lib/sse.js) and are not bound by requestTimeout.
server.requestTimeout = 60000;
server.headersTimeout = 15000;
server.keepAliveTimeout = 20000;

for (const m of modules) m.start?.();

server.listen(cfg.port, cfg.host, () => {
  log.info(
    'main',
    `listening on ${cfg.host}:${cfg.port} data=${db.file} web=${cfg.webRoot} ` +
      `modules=${modules.map((m) => m.name).join('+')} ` +
      `setupToken=${cfg.setupToken ? 'on' : 'off'} cors=${cfg.corsOrigins.join(',') || 'off'}`,
  );
});

let shuttingDown = false;
function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  log.info('main', `${signal} — shutting down`);
  for (const m of modules) {
    try {
      m.stop?.();
    } catch (e) {
      log.error('main', `${m.name} stop: ${e.stack || e}`);
    }
  }
  // The database is closed only once every in-flight handler has finished — a
  // request still running would otherwise hit a closed handle — or when the
  // grace period is up (a client that never lets its request end; Docker's own
  // stop timeout is 10 s, so we give up well before it does). `server.close()`
  // stops accepting and ends idle keep-alive sockets on its own.
  let finished = false;
  const finish = (why) => {
    if (finished) return;
    finished = true;
    try {
      db.close();
    } catch (e) {
      log.error('main', `db close: ${e.stack || e}`);
    }
    log.info('main', `stopped (${why})`);
    process.exit(0);
  };
  server.close(() => finish('drained'));
  setTimeout(() => {
    server.closeAllConnections?.();
    finish('grace period over');
  }, 5000);
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

module.exports = { server, cfg, db, ctx };
