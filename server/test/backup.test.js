'use strict';

// WebDAV backup: config → test → run → retention → list → restore/export/import.
//
// The remote is a real (tiny) WebDAV server spoken over real HTTP — an
// in-memory Map behind OPTIONS/PROPFIND/MKCOL/PUT/GET/DELETE with Basic auth,
// namespace-prefixed 207 XML and the redirect quirk 坚果云/Nextcloud show. The
// backup module never knows it is not talking to a real one.

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');

const { startServer, api } = require('./helpers');
const { WebDavClient } = require('../src/lib/webdav');
const { shouldRunNow, nextRunFrom, MAX_ATTEMPTS, RETRY_BACKOFF_MS } = require('../src/modules/backup');

const SETUP = { householdName: '小明家', username: 'admin', password: 'hunter22', displayName: '小明' };
const SNAPSHOT_RE = /^famledger-\d{8}-\d{6}\.db\.gz(\.enc)?$/;

// ---------------------------------------------------------------- fake WebDAV

/**
 * @param {{user?:string, pass?:string, mount?:string, ns?:string, legacyMount?:string}} [opts]
 *   mount        where the DAV root lives in the URL space (default `/dav`)
 *   ns           namespace prefix used in the 207 XML (`d:`, `D:`, or '')
 *   legacyMount  a second prefix that 301-redirects to `mount`
 *   legacyTarget where that redirect points (default: `mount`, same origin —
 *                pass another server's URL to test a cross-origin redirect)
 */
async function startFakeWebdav(opts = {}) {
  const user = opts.user ?? 'dav-user';
  const pass = opts.pass ?? 'dav-pass';
  const mount = opts.mount ?? '/dav';
  const ns = opts.ns ?? 'd:';
  const legacy = opts.legacyMount || null;
  const legacyTarget = opts.legacyTarget || mount;

  /** @type {Map<string, Buffer>} path → bytes */
  const files = new Map();
  const dirs = new Set(['/']);
  const mtimes = new Map();
  const hits = [];
  const seen = []; // every request, logged before the auth check
  const state = { delayMs: 0 };

  const parentOf = (p) => {
    const i = p.lastIndexOf('/');
    return i <= 0 ? '/' : p.slice(0, i);
  };
  const href = (p, isDir) => {
    const enc = p.split('/').map(encodeURIComponent).join('/');
    return mount + enc + (isDir && !enc.endsWith('/') ? '/' : '');
  };
  const xmlns = ns ? ` xmlns:${ns.slice(0, -1)}="DAV:"` : ' xmlns="DAV:"';
  const T = (name, inner) => `<${ns}${name}>${inner}</${ns}${name}>`;

  function entryXml(p, isDir) {
    const mtime = mtimes.get(p) || new Date();
    const props =
      T('resourcetype', isDir ? `<${ns}collection/>` : '') +
      (isDir ? '' : T('getcontentlength', String(files.get(p).length))) +
      T('getlastmodified', mtime.toUTCString()) +
      (isDir ? '' : T('getetag', `"${crypto.createHash('md5').update(files.get(p)).digest('hex')}"`));
    return T('response', T('href', href(p, isDir)) + T('propstat', T('prop', props) + T('status', 'HTTP/1.1 200 OK')));
  }

  function multistatus(entries) {
    return `<?xml version="1.0" encoding="utf-8"?>\n<${ns}multistatus${xmlns}>${entries.join('')}</${ns}multistatus>`;
  }

  const send = (res, status, body, headers = {}) => {
    const buf = body ? Buffer.from(body) : Buffer.alloc(0);
    res.writeHead(status, { 'content-length': buf.length, ...headers });
    res.end(buf);
  };

  const server = http.createServer((req, res) => {
    seen.push(`${req.method} ${req.url}`);
    const want = 'Basic ' + Buffer.from(`${user}:${pass}`).toString('base64');
    if ((req.headers.authorization || '') !== want) {
      req.resume();
      return send(res, 401, 'unauthorized', { 'www-authenticate': 'Basic realm="dav"' });
    }

    let raw;
    try {
      raw = decodeURIComponent(new URL(req.url, 'http://dav').pathname);
    } catch {
      return send(res, 400, 'bad path');
    }
    if (legacy && (raw === legacy || raw.startsWith(legacy + '/'))) {
      req.resume();
      return send(res, 301, '', { location: legacyTarget + raw.slice(legacy.length) });
    }
    if (raw !== mount && !raw.startsWith(mount + '/')) return send(res, 404, 'outside the dav root');

    let p = raw.slice(mount.length) || '/';
    if (p.length > 1) p = p.replace(/\/+$/, '');
    hits.push(`${req.method} ${p}`);

    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const body = Buffer.concat(chunks);
      switch (req.method) {
        case 'OPTIONS':
          return send(res, 200, '', { dav: '1,2', allow: 'OPTIONS,PROPFIND,MKCOL,PUT,GET,DELETE' });

        case 'PROPFIND': {
          const depth = req.headers.depth;
          if (depth === undefined) return send(res, 400, 'Depth header required');
          if (dirs.has(p)) {
            const entries = [entryXml(p, true)];
            if (depth !== '0') {
              for (const d of dirs) if (d !== p && parentOf(d) === p) entries.push(entryXml(d, true));
              for (const f of files.keys()) if (parentOf(f) === p) entries.push(entryXml(f, false));
            }
            return send(res, 207, multistatus(entries), { 'content-type': 'application/xml; charset=utf-8' });
          }
          if (files.has(p)) {
            return send(res, 207, multistatus([entryXml(p, false)]), { 'content-type': 'application/xml; charset=utf-8' });
          }
          return send(res, 404, 'not found');
        }

        case 'MKCOL':
          if (dirs.has(p) || files.has(p)) return send(res, 405, 'already exists');
          if (!dirs.has(parentOf(p))) return send(res, 409, 'missing parent');
          dirs.add(p);
          mtimes.set(p, new Date());
          return send(res, 201, '');

        case 'PUT': {
          if (!dirs.has(parentOf(p))) return send(res, 409, 'missing parent');
          const existed = files.has(p);
          files.set(p, body);
          mtimes.set(p, new Date());
          return send(res, existed ? 204 : 201, '');
        }

        case 'HEAD':
        case 'GET': {
          if (!files.has(p)) return send(res, 404, 'not found');
          const buf = files.get(p);
          if (req.method === 'HEAD') return send(res, 200, '', { 'content-type': 'application/octet-stream' });
          const reply = () => send(res, 200, buf, { 'content-type': 'application/octet-stream' });
          if (state.delayMs > 0) return void setTimeout(reply, state.delayMs);
          return reply();
        }

        case 'DELETE':
          if (files.delete(p)) return send(res, 204, '');
          if (p !== '/' && dirs.delete(p)) return send(res, 204, '');
          return send(res, 404, 'not found');

        default:
          return send(res, 405, 'method not allowed');
      }
    });
  });

  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  return {
    user,
    pass,
    port,
    url: `http://127.0.0.1:${port}${mount}`,
    legacyUrl: legacy ? `http://127.0.0.1:${port}${legacy}` : null,
    files,
    dirs,
    hits,
    seen,
    /** Make GET take `ms` — lets a test hold a restore open. */
    setDelay: (ms) => {
      state.delayMs = ms;
    },
    names: (dir = '/famledger') => [...files.keys()].filter((k) => k.startsWith(dir + '/')).map((k) => k.slice(dir.length + 1)).sort(),
    get: (p) => files.get(p),
    close: () => new Promise((r) => server.close(r)),
  };
}

// ---------------------------------------------------------------- fixtures

const put = (a, p, body, opts) => a.call('PUT', p, { ...opts, body });

/** Fresh server + fake WebDAV + a finished POST /setup. */
async function fixture(t, env = {}) {
  const srv = await startServer(env);
  t.after(() => srv.stop());
  const fake = await startFakeWebdav();
  t.after(() => fake.close());
  const a = api(srv.base);
  const r = await a.post('/setup', SETUP);
  assert.equal(r.status, 200, `setup failed: ${r.text}`);
  return { srv, a, fake, token: r.json.token, member: r.json.member };
}

async function configure(a, token, fake, over = {}) {
  const body = {
    webdav: { url: fake.url, username: fake.user, password: fake.pass, remoteDir: '/famledger' },
    schedule: { enabled: false, hour: 3, keep: 14 },
    encryption: { enabled: false, passphrase: '' },
    ...over,
  };
  const r = await put(a, '/backup/config', body, { token });
  assert.equal(r.status, 200, r.text);
  return r.json;
}

const sha256 = (b) => crypto.createHash('sha256').update(b).digest('hex');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------------------------------------------------------------- config

test('GET /backup/config 返回默认值，且永不回显口令/密语', async (t) => {
  const { a, token } = await fixture(t);

  const r = await a.get('/backup/config', { token });
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.json.webdav, { url: '', username: '', hasPassword: false, remoteDir: '/famledger' });
  assert.deepEqual(r.json.schedule, { enabled: false, hour: 3, keep: 14 });
  assert.deepEqual(r.json.encryption, { enabled: false, hasPassphrase: false });
  assert.equal(r.json.lastRun, null);
  assert.equal(r.json.nextRun, null);
  assert.ok(!/password|passphrase/i.test(JSON.stringify(r.json).replace(/hasPass\w+/g, '')), r.text);
});

test('backup 全部端点需要 admin', async (t) => {
  const { a, token } = await fixture(t);
  const m = await a.post('/members', { username: 'kid', password: 'hunter22', displayName: '小红' }, { token });
  assert.equal(m.status, 201, m.text);
  const login = await a.post('/auth/login', { username: 'kid', password: 'hunter22' });
  const kid = login.json.token;

  for (const [method, p] of [['GET', '/backup/config'], ['GET', '/backup/list'], ['GET', '/backup/status'],
    ['POST', '/backup/run'], ['POST', '/backup/test'], ['GET', '/backup/export']]) {
    const r = await a.call(method, p, { token: kid, body: method === 'POST' ? {} : undefined });
    assert.equal(r.status, 403, `${method} ${p} → ${r.status} ${r.text}`);
  }
});

test('PUT /backup/config 保存配置；password:"" 表示不修改', async (t) => {
  const { a, token, fake } = await fixture(t);

  const saved = await configure(a, token, fake, { schedule: { enabled: true, hour: 5, keep: 3 } });
  assert.equal(saved.webdav.url, fake.url);
  assert.equal(saved.webdav.username, fake.user);
  assert.equal(saved.webdav.hasPassword, true);
  assert.deepEqual(saved.schedule, { enabled: true, hour: 5, keep: 3 });
  assert.ok(saved.nextRun && Date.parse(saved.nextRun) > 0, 'enabled 时应给出 nextRun');

  const ok1 = await a.post('/backup/test', {}, { token });
  assert.equal(ok1.json.ok, true, ok1.text);

  // 只改 remoteDir，口令留空 → 口令必须还在
  const r = await put(a, '/backup/config', { webdav: { remoteDir: '/fam/nested' }, encryption: { enabled: false } }, { token });
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.webdav.hasPassword, true);
  assert.equal(r.json.webdav.remoteDir, '/fam/nested');
  assert.equal(r.json.webdav.url, fake.url, 'URL 不应被清空');
  assert.deepEqual(r.json.schedule, { enabled: true, hour: 5, keep: 3 }, 'schedule 不应被清空');

  const ok2 = await a.post('/backup/test', {}, { token });
  assert.equal(ok2.json.ok, true, ok2.text);
});

test('URL 里带的账号口令会被拆出来，存下的 URL 不含凭据', async (t) => {
  const { a, token, fake } = await fixture(t);
  const withCreds = fake.url.replace('http://', `http://${fake.user}:${encodeURIComponent(fake.pass)}@`);

  const r = await put(a, '/backup/config', { webdav: { url: withCreds } }, { token });
  assert.equal(r.status, 200, r.text);
  assert.ok(!r.json.webdav.url.includes('@'), `URL 不能回显凭据：${r.json.webdav.url}`);
  assert.ok(!JSON.stringify(r.json).includes(fake.pass), '口令绝不能出现在响应里');
  assert.equal(r.json.webdav.username, fake.user);
  assert.equal(r.json.webdav.hasPassword, true);

  const probe = await a.post('/backup/test', {}, { token });
  assert.equal(probe.json.ok, true, probe.text);
});

test('PUT /backup/config 校验 hour/keep/url，开加密必须给密语', async (t) => {
  const { a, token, fake } = await fixture(t);
  await configure(a, token, fake);

  for (const [body, code] of [
    [{ schedule: { hour: 24 } }, 'invalid_hour'],
    [{ schedule: { hour: -1 } }, 'invalid_hour'],
    [{ schedule: { keep: 0 } }, 'invalid_keep'],
    [{ webdav: { url: 'ftp://x/y' } }, 'invalid_url'],
    [{ encryption: { enabled: true, passphrase: '' } }, 'invalid_passphrase'],
    [{ encryption: { enabled: true, passphrase: 'short' } }, 'invalid_passphrase'],
  ]) {
    const r = await put(a, '/backup/config', body, { token });
    assert.equal(r.status, 400, JSON.stringify(body) + ' → ' + r.text);
    assert.equal(r.json.error.code, code, r.text);
  }
});

// ---------------------------------------------------------------- test 端点

test('POST /backup/test 错口令 → {ok:false}；对口令 → {ok:true} 并建好目录', async (t) => {
  const { a, token, fake } = await fixture(t);

  await configure(a, token, fake, { webdav: { url: fake.url, username: fake.user, password: 'WRONG', remoteDir: '/famledger' } });
  const bad = await a.post('/backup/test', {}, { token });
  assert.equal(bad.status, 200, bad.text);
  assert.equal(bad.json.ok, false);
  assert.ok(typeof bad.json.message === 'string' && bad.json.message.length > 0, bad.text);
  assert.ok(!bad.json.message.includes('WRONG'), '错误信息里不能带口令');

  await configure(a, token, fake);
  const good = await a.post('/backup/test', {}, { token });
  assert.equal(good.status, 200, good.text);
  assert.equal(good.json.ok, true, good.text);
  assert.ok(fake.dirs.has('/famledger'), '成功的 test 应该把 remoteDir 建出来');

  // 未配置 URL 时也是 {ok:false}，不是 500
  await put(a, '/backup/config', { webdav: { url: null, username: null, password: null } }, { token });
  const none = await a.post('/backup/test', {}, { token });
  assert.equal(none.status, 200, none.text);
  assert.equal(none.json.ok, false);
});

test('服务器不可达时 test → {ok:false}，run → 502 webdav_error 且不崩', async (t) => {
  const { a, token, fake } = await fixture(t);
  await configure(a, token, fake);
  await fake.close();

  const r = await a.post('/backup/test', {}, { token });
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.ok, false);

  const run = await a.post('/backup/run', {}, { token });
  assert.equal(run.status, 502, run.text);
  assert.equal(run.json.error.code, 'webdav_error');

  const st = await a.get('/backup/status', { token });
  assert.equal(st.status, 200, st.text);
  assert.equal(st.json.running, false);
  assert.equal(st.json.history[0].ok, false);
  assert.ok(st.json.history[0].message, '失败必须留下 message');
  assert.equal(st.json.lastRun.ok, false);

  // 进程还活着
  assert.equal((await a.get('/members', { token })).status, 200);
});

// ---------------------------------------------------------------- run

test('POST /backup/run 上传快照 + manifest，sha256 与内容一致', async (t) => {
  const { a, token, fake } = await fixture(t);
  await configure(a, token, fake);

  const r = await a.post('/backup/run', {}, { token });
  assert.equal(r.status, 200, r.text);
  assert.match(r.json.name, /^famledger-\d{8}-\d{6}\.db\.gz$/);
  assert.ok(r.json.bytes > 0);
  assert.ok(Number.isFinite(r.json.tookMs));

  const names = fake.names();
  assert.equal(names.length, 2, `远端应有 2 个对象，实际 ${names.join()}`);
  assert.deepEqual(names, [r.json.name, `${r.json.name}.json`].sort());

  const snap = fake.get(`/famledger/${r.json.name}`);
  assert.equal(snap.length, r.json.bytes);
  assert.equal(snap[0], 0x1f);
  assert.equal(snap[1], 0x8b);

  const man = JSON.parse(fake.get(`/famledger/${r.json.name}.json`).toString('utf8'));
  assert.equal(man.app, 'famledger');
  assert.equal(man.formatVersion, 1);
  assert.equal(man.encrypted, false);
  assert.equal(man.bytes, snap.length);
  assert.equal(man.sha256, sha256(snap));
  // 最新迁移的版本号；写死的话每加一个迁移都要回来改这里。
  const latest = Math.max(...fs.readdirSync(path.join(__dirname, '..', 'src', 'sql'))
    .filter((f) => /^\d+_.+\.sql$/.test(f)).map((f) => Number(f.split('_')[0])));
  assert.equal(man.schemaVersion, latest);
  assert.ok(Date.parse(man.createdAt) > 0);

  const list = await a.get('/backup/list', { token });
  assert.equal(list.status, 200, list.text);
  assert.deepEqual(list.json.items.map((i) => i.name), [r.json.name]);
  assert.equal(list.json.items[0].bytes, snap.length);
  assert.equal(list.json.items[0].encrypted, false);
  assert.ok(Date.parse(list.json.items[0].modifiedAt) > 0);

  const st = await a.get('/backup/status', { token });
  assert.equal(st.json.history.length, 1);
  assert.equal(st.json.history[0].ok, true);
  assert.equal(st.json.history[0].name, r.json.name);
  assert.equal(st.json.lastRun.name, r.json.name);
});

test('remoteDir 多级不存在时 run 会逐级 MKCOL', async (t) => {
  const { a, token, fake } = await fixture(t);
  await configure(a, token, fake, { webdav: { url: fake.url, username: fake.user, password: fake.pass, remoteDir: '/a/b/c' } });

  const r = await a.post('/backup/run', {}, { token });
  assert.equal(r.status, 200, r.text);
  assert.ok(fake.dirs.has('/a') && fake.dirs.has('/a/b') && fake.dirs.has('/a/b/c'), [...fake.dirs].join());
  assert.deepEqual(fake.names('/a/b/c'), [r.json.name, `${r.json.name}.json`].sort());
});

test('未配置 WebDAV 时 run → 400', async (t) => {
  const { a, token } = await fixture(t);
  const r = await a.post('/backup/run', {}, { token });
  assert.equal(r.status, 400, r.text);
  assert.equal(r.json.error.code, 'webdav_not_configured');
});

test('并发 run → 一个 200，一个 409 backup_running', async (t) => {
  const { a, token, fake } = await fixture(t);
  await configure(a, token, fake);

  const [r1, r2] = await Promise.all([a.post('/backup/run', {}, { token }), a.post('/backup/run', {}, { token })]);
  const codes = [r1.status, r2.status].sort();
  assert.deepEqual(codes, [200, 409], `${r1.status}/${r1.text} ${r2.status}/${r2.text}`);
  const busy = r1.status === 409 ? r1 : r2;
  assert.equal(busy.json.error.code, 'backup_running');
});

test('keep=2 连跑 3 次 → 远端只剩 2 组，最旧的一组连 manifest 一起删掉', async (t) => {
  const { a, token, fake } = await fixture(t);
  await configure(a, token, fake, { schedule: { enabled: false, hour: 3, keep: 2 } });

  const names = [];
  for (let i = 0; i < 3; i++) {
    const r = await a.post('/backup/run', {}, { token });
    assert.equal(r.status, 200, r.text);
    names.push(r.json.name);
  }
  assert.equal(new Set(names).size, 3, `同秒内连跑也必须产生不同文件名：${names.join()}`);

  const remote = fake.names();
  assert.equal(remote.length, 4, `应剩 2 组共 4 个对象，实际 ${remote.join()}`);
  assert.ok(!remote.includes(names[0]), '最旧的快照应被删除');
  assert.ok(!remote.includes(`${names[0]}.json`), '最旧的 manifest 应被删除');
  assert.ok(remote.includes(names[1]) && remote.includes(names[2]));

  const list = await a.get('/backup/list', { token });
  assert.deepEqual(list.json.items.map((i) => i.name), [names[2], names[1]], 'list 按时间倒序');
});

// ---------------------------------------------------------------- 加密

test('开加密后文件名带 .enc、文件头是 FLBK1，且能恢复', async (t) => {
  const { a, token, fake } = await fixture(t);
  await configure(a, token, fake, { encryption: { enabled: true, passphrase: 'correct horse battery' } });

  const cfg = await a.get('/backup/config', { token });
  assert.equal(cfg.json.encryption.enabled, true);
  assert.equal(cfg.json.encryption.hasPassphrase, true);

  const r = await a.post('/backup/run', {}, { token });
  assert.equal(r.status, 200, r.text);
  assert.match(r.json.name, /^famledger-\d{8}-\d{6}\.db\.gz\.enc$/);

  const blob = fake.get(`/famledger/${r.json.name}`);
  assert.equal(blob.subarray(0, 5).toString('latin1'), 'FLBK1');
  assert.ok(blob.length > 5 + 16 + 12 + 16, '结构 = magic|salt16|nonce12|ct|tag16，密文不能是空的');
  assert.ok(!blob.subarray(5, 21).equals(Buffer.alloc(16)), 'salt 必须是随机的');
  assert.ok(!blob.subarray(21, 33).equals(Buffer.alloc(12)), 'nonce 必须是随机的');
  assert.notEqual(blob[5 + 16 + 12], 0x1f, '密文不应看得出 gzip 头');

  const man = JSON.parse(fake.get(`/famledger/${r.json.name}.json`).toString('utf8'));
  assert.equal(man.encrypted, true);
  assert.equal(man.sha256, sha256(blob));

  const list = await a.get('/backup/list', { token });
  assert.equal(list.json.items[0].encrypted, true);

  // 恢复：密语在配置里 → 直接可用
  const back = await a.post('/backup/restore', { name: r.json.name }, { token });
  assert.equal(back.status, 200, back.text);
  assert.equal(back.json.ok, true);
  assert.equal(back.json.restoredFrom, r.json.name);
  assert.equal((await a.get('/members', { token })).status, 200);
});

test('没有配置密语时恢复 .enc → 400 passphrase_required', async (t) => {
  const { a, token, fake } = await fixture(t);
  await configure(a, token, fake, { encryption: { enabled: true, passphrase: 'correct horse battery' } });
  const r = await a.post('/backup/run', {}, { token });
  assert.equal(r.status, 200, r.text);

  await put(a, '/backup/config', { encryption: { enabled: false, passphrase: null } }, { token });
  const back = await a.post('/backup/restore', { name: r.json.name }, { token });
  assert.equal(back.status, 400, back.text);
  assert.equal(back.json.error.code, 'passphrase_required');
});

test('密语不对 → 400 decrypt_failed，库没被换掉', async (t) => {
  const { a, token, fake } = await fixture(t);
  await configure(a, token, fake, { encryption: { enabled: true, passphrase: 'correct horse battery' } });
  const r = await a.post('/backup/run', {}, { token });
  assert.equal(r.status, 200, r.text);

  await put(a, '/backup/config', { encryption: { enabled: true, passphrase: 'another wrong one' } }, { token });
  const back = await a.post('/backup/restore', { name: r.json.name }, { token });
  assert.equal(back.status, 400, back.text);
  assert.equal(back.json.error.code, 'decrypt_failed');
  assert.equal((await a.get('/members', { token })).status, 200, '失败的恢复不能破坏当前库');
});

// ---------------------------------------------------------------- restore

test('restore 把数据带回备份时刻，且令牌仍然可用', async (t) => {
  const { a, token, srv, fake } = await fixture(t);
  await configure(a, token, fake);

  // 备份之前建的成员必须还在；备份之后建的必须消失。
  const before = await a.post('/members', { username: 'before', password: 'hunter22', displayName: '备份前' }, { token });
  assert.equal(before.status, 201, before.text);

  const run = await a.post('/backup/run', {}, { token });
  assert.equal(run.status, 200, run.text);

  const after = await a.post('/members', { username: 'after', password: 'hunter22', displayName: '备份后' }, { token });
  assert.equal(after.status, 201, after.text);
  assert.equal((await a.get('/members', { token })).json.items.length, 3);

  const back = await a.post('/backup/restore', { name: run.json.name }, { token });
  assert.equal(back.status, 200, back.text);
  assert.equal(back.json.ok, true);
  assert.equal(back.json.restoredFrom, run.json.name);
  assert.match(back.json.preRestoreCopy, /^pre-restore-\d{8}-\d{6}\.db$/);
  assert.ok(fs.existsSync(path.join(srv.dataDir, back.json.preRestoreCopy)), '恢复前必须留下本地副本');

  // 快照是在那次备份「进行中」拍下来的，里面那条 ok=NULL 的记录不能一直显示成
  // 「备份进行中」。
  const st = await a.get('/backup/status', { token });
  assert.equal(st.json.running, false);
  assert.ok(st.json.history.length > 0);
  assert.ok(st.json.history.every((h) => h.ok !== null), `不能留下未完成的记录：${st.text}`);
  assert.match(st.json.history[0].message, /中断|恢复/);

  const now = await a.get('/members', { token });
  assert.equal(now.status, 200, '恢复后原 token 必须仍然有效');
  const usernames = now.json.items.map((m) => m.username).sort();
  assert.deepEqual(usernames, ['admin', 'before']);

  // 恢复后还能继续写
  const more = await a.post('/members', { username: 'later', password: 'hunter22', displayName: '之后' }, { token });
  assert.equal(more.status, 201, more.text);
});

test('备份进行中不许恢复/导入（否则会把库从跑着的备份底下抽走）', async (t) => {
  const { srv, a, token, fake } = await fixture(t);
  await configure(a, token, fake);
  const first = await a.post('/backup/run', {}, { token });
  assert.equal(first.status, 200, first.text);

  const [run, restore, imported] = await Promise.all([
    a.post('/backup/run', {}, { token }),
    a.post('/backup/restore', { name: first.json.name }, { token }),
    fetch(`${srv.base}/api/v1/backup/import`, {
      method: 'POST',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/gzip' },
      body: Buffer.from('x'),
    }).then(async (r) => ({ status: r.status, json: await r.json() })),
  ]);
  assert.equal(run.status, 200, run.text);
  for (const r of [restore, imported]) {
    assert.equal(r.status, 409, JSON.stringify(r.json));
    assert.equal(r.json.error.code, 'backup_running');
  }
});

test('恢复全程持锁：下载途中开始的备份被挡掉，恢复照常完成', async (t) => {
  const { a, token, fake } = await fixture(t);
  await configure(a, token, fake);
  const first = await a.post('/backup/run', {}, { token });
  assert.equal(first.status, 200, first.text);

  fake.setDelay(700); // 让 restore 卡在下载上
  const restoring = a.post('/backup/restore', { name: first.json.name }, { token });
  await sleep(400); // 确保锁已经被 restore 拿走（对 700ms 的下载延迟留足余量）

  const blocked = await a.post('/backup/run', {}, { token });
  assert.equal(blocked.status, 409, blocked.text);
  assert.equal(blocked.json.error.code, 'restore_running', blocked.text);

  const done = await restoring;
  assert.equal(done.status, 200, done.text);
  assert.equal(done.json.ok, true);

  fake.setDelay(0);
  const after = await a.post('/backup/run', {}, { token });
  assert.equal(after.status, 200, `锁必须在 finally 里放掉：${after.text}`);
});

test('restore 校验文件名与 sha256', async (t) => {
  const { a, token, fake } = await fixture(t);
  await configure(a, token, fake);
  const run = await a.post('/backup/run', {}, { token });
  assert.equal(run.status, 200, run.text);

  for (const name of ['../secret.key', '/etc/passwd', 'famledger-x.db.gz', '', 'famledger-20260101-000000.db.gz.json']) {
    const r = await a.post('/backup/restore', { name }, { token });
    assert.equal(r.status, 400, `${name} → ${r.status} ${r.text}`);
    assert.equal(r.json.error.code, 'invalid_name', r.text);
  }

  const missing = await a.post('/backup/restore', { name: 'famledger-20200101-000000.db.gz' }, { token });
  assert.equal(missing.status, 404, missing.text);

  // 篡改内容 → manifest 的 sha256 对不上
  const p = `/famledger/${run.json.name}`;
  const blob = Buffer.from(fake.get(p));
  blob[blob.length - 1] ^= 0xff;
  fake.files.set(p, blob);
  const bad = await a.post('/backup/restore', { name: run.json.name }, { token });
  assert.equal(bad.status, 400, bad.text);
  assert.equal(bad.json.error.code, 'checksum_mismatch', bad.text);
  assert.equal((await a.get('/members', { token })).status, 200);
});

test('内容不是 SQLite 时 restore 拒绝替换', async (t) => {
  const { a, token, fake } = await fixture(t);
  await configure(a, token, fake);
  const run = await a.post('/backup/run', {}, { token });
  assert.equal(run.status, 200, run.text);

  const zlib = require('node:zlib');
  const junk = zlib.gzipSync(Buffer.from('this is definitely not a database'));
  fake.files.set(`/famledger/${run.json.name}`, junk);
  fake.files.set(
    `/famledger/${run.json.name}.json`,
    Buffer.from(JSON.stringify({ app: 'famledger', formatVersion: 1, bytes: junk.length, sha256: sha256(junk), encrypted: false })),
  );

  const bad = await a.post('/backup/restore', { name: run.json.name }, { token });
  assert.equal(bad.status, 400, bad.text);
  assert.equal(bad.json.error.code, 'bad_snapshot', bad.text);
  assert.equal((await a.get('/members', { token })).status, 200, '当前库必须毫发无伤');
});

// ---------------------------------------------------------------- export / import

test('GET /backup/export 返回 gzip 快照（魔数 1f 8b）', async (t) => {
  const { srv, token } = await fixture(t);
  const r = await fetch(`${srv.base}/api/v1/backup/export`, { headers: { authorization: `Bearer ${token}` } });
  assert.equal(r.status, 200);
  assert.match(r.headers.get('content-type'), /application\/gzip/);
  assert.match(r.headers.get('content-disposition'), /^attachment; filename="famledger-\d{8}-\d{6}\.db\.gz"$/);
  const buf = Buffer.from(await r.arrayBuffer());
  assert.equal(buf[0], 0x1f);
  assert.equal(buf[1], 0x8b);
  assert.ok(buf.length > 100);
});

test('POST /backup/import 吃回 export 的字节，数据回到导出时刻', async (t) => {
  const { srv, a, token } = await fixture(t);
  const dump = await fetch(`${srv.base}/api/v1/backup/export`, { headers: { authorization: `Bearer ${token}` } });
  const gz = Buffer.from(await dump.arrayBuffer());

  const added = await a.post('/members', { username: 'ghost', password: 'hunter22', displayName: '幽灵' }, { token });
  assert.equal(added.status, 201, added.text);

  const r = await fetch(`${srv.base}/api/v1/backup/import`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/gzip' },
    body: gz,
  });
  const json = await r.json();
  assert.equal(r.status, 200, JSON.stringify(json));
  assert.equal(json.ok, true);
  assert.ok(json.preRestoreCopy);

  const list = await a.get('/members', { token });
  assert.equal(list.status, 200);
  assert.deepEqual(list.json.items.map((m) => m.username), ['admin']);
});

test('POST /backup/import 接受 FLBK1 加密包，坏包被拒', async (t) => {
  const { srv, a, token, fake } = await fixture(t);
  await configure(a, token, fake, { encryption: { enabled: true, passphrase: 'correct horse battery' } });
  const run = await a.post('/backup/run', {}, { token });
  assert.equal(run.status, 200, run.text);
  const blob = Buffer.from(fake.get(`/famledger/${run.json.name}`));

  const post = (body) =>
    fetch(`${srv.base}/api/v1/backup/import`, {
      method: 'POST',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/gzip', 'x-famledger-encrypted': '1' },
      body,
    });

  const ok = await post(blob);
  assert.equal(ok.status, 200, await ok.text());

  const torn = Buffer.from(blob);
  torn[torn.length - 3] ^= 0xff;
  const bad = await post(torn);
  const badBody = await bad.text();
  assert.equal(bad.status, 400, badBody);
  assert.equal(JSON.parse(badBody).error.code, 'decrypt_failed');

  const r = await post(Buffer.from('not a snapshot at all'));
  assert.equal(r.status, 400, await r.text());
  assert.equal((await a.get('/members', { token })).status, 200);
});

// ---------------------------------------------------------------- 调度

test('到点自动跑一次，同一天不会跑第二次', async (t) => {
  const { a, token, fake } = await fixture(t, { BACKUP_TICK_MS: '120' });
  await configure(a, token, fake, { schedule: { enabled: true, hour: new Date().getHours(), keep: 14 } });

  let items = [];
  for (let i = 0; i < 80 && items.length === 0; i++) {
    await sleep(50);
    items = (await a.get('/backup/list', { token })).json.items;
  }
  assert.equal(items.length, 1, '到点后应自动跑出一个快照');

  await sleep(600);
  const again = (await a.get('/backup/list', { token })).json.items;
  assert.equal(again.length, 1, '同一天不应重复跑');

  const st = await a.get('/backup/status', { token });
  assert.equal(st.json.history.length, 1);
  assert.equal(st.json.history[0].ok, true);
  assert.ok(Date.parse(st.json.nextRun) > Date.now(), '跑过之后 nextRun 应指向明天');
});

test('定时备份失败不判死当天：退避重试的名额还在', async (t) => {
  const { a, token, fake } = await fixture(t, { BACKUP_TICK_MS: '120' });
  await configure(a, token, fake, { schedule: { enabled: true, hour: new Date().getHours(), keep: 14 } });
  await fake.close(); // 网盘挂了

  // ok === null 表示那一次还在跑：要等它真的失败完，别在半路上断言。
  let history = [];
  for (let i = 0; i < 80 && !(history.length > 0 && history[0].ok !== null); i++) {
    await sleep(50);
    history = (await a.get('/backup/status', { token })).json.history;
  }
  assert.equal(history.length, 1, '应该试过一次');
  assert.equal(history[0].ok, false, '那一次必须是失败收场');

  await sleep(500); // 又过了好几个 tick
  const st = await a.get('/backup/status', { token });
  assert.equal(st.json.history.length, 1, '10 分钟退避内不该每分钟重试一次');
  const next = Date.parse(st.json.nextRun);
  assert.ok(
    next > Date.now() && next <= Date.now() + RETRY_BACKOFF_MS + 60000,
    `失败后应在 10 分钟后重试，而不是推到明天：${st.json.nextRun}`,
  );
});

test('调度未开 / 不在点上 → 不跑', async (t) => {
  const { a, token, fake } = await fixture(t, { BACKUP_TICK_MS: '120' });
  const otherHour = (new Date().getHours() + 5) % 24;
  await configure(a, token, fake, { schedule: { enabled: true, hour: otherHour, keep: 14 } });
  await sleep(500);
  assert.equal((await a.get('/backup/list', { token })).json.items.length, 0);

  await put(a, '/backup/config', { schedule: { enabled: false, hour: new Date().getHours() } }, { token });
  await sleep(500);
  assert.equal((await a.get('/backup/list', { token })).json.items.length, 0);
});

// ---------------------------------------------------------------- shouldRunNow

// 纯函数，不碰时钟也不碰数据库：调度的全部判断都在这里直接验。
const at = (h, min = 0) => new Date(2026, 8, 13, h, min, 0); // 2026-09-13 本地时间
const TODAY = '2026-09-13';
const schedCfg = (over = {}) => ({
  schedule: { enabled: true, hour: 3, keep: 14, ...(over.schedule || {}) },
  webdav: { url: 'http://nas.local/dav', ...(over.webdav || {}) },
});

test('shouldRunNow：关掉/没配/不在点上/今天已了结 → 不跑', async () => {
  assert.equal(shouldRunNow(at(3), schedCfg({ schedule: { enabled: false } }), {}).reason, 'disabled');
  assert.equal(shouldRunNow(at(3), schedCfg({ webdav: { url: '' } }), {}).reason, 'not_configured');
  assert.equal(shouldRunNow(at(4), schedCfg(), {}).reason, 'off_hour');
  assert.equal(shouldRunNow(at(3), schedCfg(), { lastDay: TODAY }).reason, 'settled_today');
  for (const c of [
    schedCfg({ schedule: { enabled: false } }),
    schedCfg({ webdav: { url: '' } }),
  ]) {
    assert.equal(shouldRunNow(at(3), c, {}).run, false);
  }
});

test('shouldRunNow：到点且今天没跑过 → 跑', async () => {
  const d = shouldRunNow(at(3, 0), schedCfg(), {});
  assert.deepEqual(d, { run: true, reason: 'scheduled' });
  assert.equal(shouldRunNow(at(3, 59), schedCfg(), { lastDay: '2026-09-12' }).run, true, '昨天跑过不算今天');
});

test('shouldRunNow：失败后 10 分钟退避，最多 3 次', async () => {
  const c = schedCfg();
  const attempted = (min, n) => ({ attemptDay: TODAY, attempts: n, lastAttempt: at(3, min).toISOString() });

  assert.equal(shouldRunNow(at(3, 5), c, attempted(0, 1)).reason, 'backoff', '5 分钟太早');
  assert.equal(shouldRunNow(at(3, 9), c, attempted(0, 1)).reason, 'backoff');
  assert.deepEqual(shouldRunNow(at(3, 10), c, attempted(0, 1)), { run: true, reason: 'retry_1' });
  assert.deepEqual(shouldRunNow(at(3, 25), c, attempted(12, 2)), { run: true, reason: 'retry_2' });
  assert.equal(shouldRunNow(at(3, 59), c, attempted(30, MAX_ATTEMPTS)).reason, 'attempts_exhausted');

  // 昨天用完的名额不能拖累今天
  assert.equal(shouldRunNow(at(3), c, { attemptDay: '2026-09-12', attempts: 9 }).run, true);
  // 时间戳坏了也不能变成每分钟重试
  assert.equal(shouldRunNow(at(3, 30), c, { attemptDay: TODAY, attempts: 1, lastAttempt: 'not a date' }).reason, 'backoff');
  assert.equal(RETRY_BACKOFF_MS, 10 * 60 * 1000);
});

test('nextRunFrom：未跑=当下，退避中=上次尝试+10 分钟，已了结=明天这个点', async () => {
  const c = schedCfg();
  assert.equal(nextRunFrom(at(3, 0), c, {}), at(3, 0).toISOString());
  assert.equal(nextRunFrom(at(10), c, {}), new Date(2026, 8, 14, 3).toISOString(), '过了点就是明天');
  assert.equal(nextRunFrom(at(3, 30), c, { lastDay: TODAY }), new Date(2026, 8, 14, 3).toISOString());
  assert.equal(
    nextRunFrom(at(3, 5), c, { attemptDay: TODAY, attempts: 1, lastAttempt: at(3, 0).toISOString() }),
    at(3, 10).toISOString(),
    '退避中给出的是重试时刻',
  );
  assert.equal(
    nextRunFrom(at(3, 59), c, { attemptDay: TODAY, attempts: MAX_ATTEMPTS, lastAttempt: at(3, 40).toISOString() }),
    new Date(2026, 8, 14, 3).toISOString(),
    '名额用完就等明天',
  );
  assert.equal(nextRunFrom(at(3), schedCfg({ schedule: { enabled: false } }), {}), null);
});

// ---------------------------------------------------------------- WebDavClient

test('WebDavClient: mkcolp 逐级建目录，已存在不报错', async (t) => {
  const fake = await startFakeWebdav();
  t.after(() => fake.close());
  const c = new WebDavClient({ url: fake.url, username: fake.user, password: fake.pass });

  await c.mkcolp('/x/y/z');
  assert.ok(fake.dirs.has('/x') && fake.dirs.has('/x/y') && fake.dirs.has('/x/y/z'));
  await c.mkcolp('/x/y/z'); // 405 → 幂等
  await c.mkcolp('/');
});

test('WebDavClient: propfind 解析中文/空格名、跳过集合自身', async (t) => {
  const fake = await startFakeWebdav();
  t.after(() => fake.close());
  const c = new WebDavClient({ url: fake.url, username: fake.user, password: fake.pass });

  await c.mkcolp('/famledger');
  await c.put('/famledger/测 试.db.gz', Buffer.from('hello'), 'application/gzip');
  await c.mkcolp('/famledger/sub');

  const items = await c.propfind('/famledger', 1);
  assert.equal(items.length, 2, JSON.stringify(items));
  const file = items.find((i) => !i.isDir);
  assert.equal(file.name, '测 试.db.gz');
  assert.equal(file.size, 5);
  assert.ok(Date.parse(file.modifiedAt) > 0);
  assert.equal(items.find((i) => i.isDir).name, 'sub');

  assert.deepEqual(await c.get('/famledger/测 试.db.gz'), Buffer.from('hello'));
  await c.delete('/famledger/测 试.db.gz');
  assert.equal((await c.propfind('/famledger', 1)).length, 1);
});

test('WebDavClient: 大写/无前缀命名空间都能解析', async (t) => {
  for (const ns of ['D:', '', 'lp1:']) {
    const fake = await startFakeWebdav({ ns });
    const c = new WebDavClient({ url: fake.url, username: fake.user, password: fake.pass });
    await c.mkcolp('/famledger');
    await c.put('/famledger/a.db.gz', Buffer.from('xx'), 'application/gzip');
    const items = await c.propfind('/famledger', 1);
    assert.equal(items.length, 1, `ns=${ns} → ${JSON.stringify(items)}`);
    assert.equal(items[0].name, 'a.db.gz');
    assert.equal(items[0].isDir, false);
    assert.equal(items[0].size, 2);
    await fake.close();
  }
});

test('WebDavClient: 跟随一次 301 重定向', async (t) => {
  const fake = await startFakeWebdav({ legacyMount: '/old' });
  t.after(() => fake.close());
  const c = new WebDavClient({ url: fake.legacyUrl, username: fake.user, password: fake.pass });

  await c.mkcolp('/famledger');
  await c.put('/famledger/a.db.gz', Buffer.from('xyz'), 'application/gzip');
  assert.deepEqual(await c.get('/famledger/a.db.gz'), Buffer.from('xyz'));
  const items = await c.propfind('/famledger', 1);
  assert.deepEqual(items.map((i) => i.name), ['a.db.gz']);
});

test('WebDavClient: 重定向到别的站点时，绝不把口令带过去', async (t) => {
  const other = await startFakeWebdav(); // 「第三方」
  t.after(() => other.close());
  const fake = await startFakeWebdav({ legacyMount: '/old', legacyTarget: other.url });
  t.after(() => fake.close());

  const c = new WebDavClient({ url: fake.legacyUrl, username: fake.user, password: fake.pass });
  await assert.rejects(
    () => c.propfind('/famledger', 1),
    (e) => {
      assert.equal(e.code, 'redirect_cross_origin', e.message);
      assert.match(e.message, /重定向/);
      return true;
    },
  );
  const probe = await c.test();
  assert.equal(probe.ok, false);
  assert.equal(other.seen.length, 0, '一个请求都不能发到第三方去');
});

test('WebDavClient.sameSite: 同主机 http→https 升级放行，降级与换主机一律拒绝', () => {
  const plain = new WebDavClient({ url: 'http://nas.local:5005/dav', username: 'u', password: 'p' });
  assert.equal(plain.sameSite(new URL('http://nas.local:5005/dav/famledger/')), true, '同源');
  assert.equal(plain.sameSite(new URL('https://nas.local:5006/dav/famledger/')), true, '同主机升级到 https，换端口也算');
  assert.equal(plain.sameSite(new URL('http://nas.local:5006/dav/')), false, '同主机换端口但没升级 = 别的源');
  assert.equal(plain.sameSite(new URL('https://evil.example/dav/')), false, '别的主机');

  const secure = new WebDavClient({ url: 'https://nas.local/dav', username: 'u', password: 'p' });
  assert.equal(secure.sameSite(new URL('https://nas.local/dav/x/')), true);
  assert.equal(secure.sameSite(new URL('http://nas.local/dav/x/')), false, 'https→http 降级');
  assert.equal(secure.sameSite(new URL('https://nas.local:8443/dav/x/')), false, 'https 基址换端口 = 别的源');
});

test('WebDavClient: 401 与连不上都是 test()→{ok:false}，get 缺文件抛 404', async (t) => {
  const fake = await startFakeWebdav();
  const good = new WebDavClient({ url: fake.url, username: fake.user, password: fake.pass });
  assert.equal((await good.test()).ok, true);

  const wrong = new WebDavClient({ url: fake.url, username: fake.user, password: 'nope' });
  const r = await wrong.test();
  assert.equal(r.ok, false);
  assert.match(r.message, /401|认证|口令/);

  await assert.rejects(() => good.get('/famledger/nope.db.gz'), (e) => e.status === 404);

  await fake.close();
  const dead = new WebDavClient({ url: fake.url, username: fake.user, password: fake.pass, timeoutMs: 2000 });
  assert.equal((await dead.test()).ok, false);
});
