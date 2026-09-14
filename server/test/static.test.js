'use strict';

// Static hosting of the Flutter web build: SPA fallback, cache headers,
// path-traversal refusal, and the "web not built yet" placeholder.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const { startServer, api, tmpDir } = require('./helpers');

const IMMUTABLE = 'public, max-age=31536000, immutable';

function buildWebRoot() {
  const dir = tmpDir('web');
  fs.writeFileSync(path.join(dir, 'index.html'), '<!doctype html><title>famledger</title><body>SPA</body>');
  fs.writeFileSync(path.join(dir, 'main.dart.js'), 'console.log("flutter");');
  fs.writeFileSync(path.join(dir, 'flutter_service_worker.js'), 'self.addEventListener("install",()=>{});');
  fs.writeFileSync(path.join(dir, 'version.json'), '{"version":"1.0.0"}');
  fs.mkdirSync(path.join(dir, 'assets'));
  fs.writeFileSync(path.join(dir, 'assets', 'FontManifest.json'), '[]');
  return dir;
}

async function served(t) {
  const webRoot = buildWebRoot();
  const srv = await startServer({ WEB_ROOT: webRoot });
  t.after(() => srv.stop());
  return { srv, a: api(srv.base), webRoot };
}

test('index.html 与 SPA 回退不缓存，带 hash 的资源长缓存', async (t) => {
  const { a } = await served(t);

  const root = await a.raw('GET', '/');
  assert.equal(root.status, 200);
  assert.match(root.headers.get('content-type'), /^text\/html/);
  assert.match(root.text, /SPA/);
  assert.match(root.headers.get('cache-control'), /no-cache/);

  const js = await a.raw('GET', '/main.dart.js');
  assert.equal(js.status, 200);
  assert.match(js.headers.get('content-type'), /javascript/);
  assert.equal(js.headers.get('cache-control'), IMMUTABLE);
  assert.match(js.text, /flutter/);

  const asset = await a.raw('GET', '/assets/FontManifest.json');
  assert.equal(asset.status, 200);
  assert.equal(asset.headers.get('cache-control'), IMMUTABLE);

  for (const p of ['/flutter_service_worker.js', '/version.json', '/index.html']) {
    const r = await a.raw('GET', p);
    assert.equal(r.status, 200, p);
    assert.match(r.headers.get('cache-control'), /no-cache/, `${p} must not be cached`);
  }

  // Unknown, non-/api path → the SPA shell, so deep links work on reload.
  const deep = await a.raw('GET', '/funds/abc?x=1');
  assert.equal(deep.status, 200);
  assert.match(deep.text, /SPA/);
  assert.match(deep.headers.get('cache-control'), /no-cache/);
});

test('未匹配的 /api/v1/* → 404 JSON，不回退到 index.html', async (t) => {
  const { a } = await served(t);
  const r = await a.raw('GET', '/api/v1/nope');
  assert.equal(r.status, 404);
  assert.match(r.headers.get('content-type'), /application\/json/);
  assert.equal(r.json.error.code, 'not_found');
  assert.doesNotMatch(r.text, /SPA/);
});

test('GET /healthz → 200 ok', async (t) => {
  const { a } = await served(t);
  const r = await a.raw('GET', '/healthz');
  assert.equal(r.status, 200);
  assert.equal(r.text, 'ok');
});

test('路径穿越不会泄漏 WEB_ROOT 之外的文件', async (t) => {
  const { srv, a, webRoot } = await served(t);
  fs.writeFileSync(path.join(webRoot, '..', 'famledger-secret.txt'), 'TOPSECRET');
  t.after(() => fs.rmSync(path.join(webRoot, '..', 'famledger-secret.txt'), { force: true }));

  for (const p of ['/../famledger-secret.txt', '/..%2ffamledger-secret.txt', '/assets/../../famledger-secret.txt']) {
    const r = await a.raw('GET', p);
    assert.doesNotMatch(r.text, /TOPSECRET/, `${p} leaked`);
  }
  // the secret.key next to the db must not be reachable either
  assert.doesNotMatch((await a.raw('GET', '/secret.key')).text || '', /[0-9a-f]{64}/);
  assert.ok(fs.existsSync(path.join(srv.dataDir, 'secret.key')));
});

test('WEB_ROOT 没有 index.html 时 / 返回说明页', async (t) => {
  const srv = await startServer({ WEB_ROOT: tmpDir('empty-web') });
  t.after(() => srv.stop());
  const a = api(srv.base);

  const r = await a.raw('GET', '/');
  assert.equal(r.status, 200);
  assert.match(r.headers.get('content-type'), /^text\/html/);
  assert.match(r.text, /Web 产物未构建/);

  // the API still works with no web build present
  assert.equal((await a.get('/setup/status')).status, 200);
  assert.equal((await a.raw('GET', '/main.dart.js')).status, 404);
});
