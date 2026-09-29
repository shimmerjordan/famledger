'use strict';

// Static hosting of the Flutter web build: SPA fallback, cache headers,
// path-traversal refusal, and the "web not built yet" placeholder.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const { startServer, api, tmpDir } = require('./helpers');

function buildWebRoot() {
  const dir = tmpDir('web');
  fs.writeFileSync(
    path.join(dir, 'index.html'),
    '<!doctype html><title>famledger</title><body>SPA<script src="flutter_bootstrap.js" async></script></body>',
  );
  fs.writeFileSync(path.join(dir, 'main.dart.js'), 'console.log("flutter");');
  fs.writeFileSync(
    path.join(dir, 'flutter_bootstrap.js'),
    '_flutter.buildConfig = {"engineRevision":"x","builds":[{"compileTarget":"dart2js","renderer":"canvaskit","mainJsPath":"main.dart.js"}]};',
  );
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

test('Flutter 的文件名不带内容指纹：一律每次校验（ETag → 304），只有带当前构建号的 main.dart.js 长缓存', async (t) => {
  const { a } = await served(t);

  const root = await a.raw('GET', '/');
  assert.equal(root.status, 200);
  assert.match(root.headers.get('content-type'), /^text\/html/);
  assert.match(root.text, /SPA/);
  assert.match(root.headers.get('cache-control'), /no-cache/);

  // 升级后 main.dart.js、assets/*、canvaskit/* 还叫原来的名字：标成一年不变的话，浏览器和 Cloudflare
  // 会一直给旧版（容器换了新镜像，页面还是旧的）。
  for (const p of ['/main.dart.js', '/assets/FontManifest.json', '/flutter_bootstrap.js', '/flutter_service_worker.js', '/version.json', '/index.html']) {
    const r = await a.raw('GET', p);
    assert.equal(r.status, 200, p);
    assert.match(r.headers.get('cache-control'), /no-cache/, `${p} 每次都要校验`);
    assert.doesNotMatch(r.headers.get('cache-control'), /immutable/, p);
  }

  const js = await a.raw('GET', '/main.dart.js');
  assert.match(js.headers.get('content-type'), /javascript/);
  assert.match(js.text, /flutter/);
  const again = await a.raw('GET', '/main.dart.js', { headers: { 'if-none-match': js.headers.get('etag') } });
  assert.equal(again.status, 304, '没变就回 304，校验很便宜');

  // Unknown, non-/api path → the SPA shell, so deep links work on reload.
  const deep = await a.raw('GET', '/funds/abc?x=1');
  assert.equal(deep.status, 200);
  assert.match(deep.text, /SPA/);
  assert.match(deep.headers.get('cache-control'), /no-cache/);
});

test('每次构建换地址：index.html 引 flutter_bootstrap.js?v=，bootstrap 引 main.dart.js?v=；换了构建号就跟着变', async (t) => {
  const { a, webRoot } = await served(t);

  const v1 = (await a.raw('GET', '/')).text.match(/flutter_bootstrap\.js\?v=([0-9a-z]+)/)?.[1];
  assert.ok(v1, 'index.html 里带构建号');
  const deep = await a.raw('GET', '/assets?tab=perks');
  assert.match(deep.text, new RegExp(`flutter_bootstrap\\.js\\?v=${v1}`), 'SPA 回退也带');

  const boot = await a.raw('GET', `/flutter_bootstrap.js?v=${v1}`);
  assert.equal(boot.status, 200);
  assert.match(boot.text, new RegExp(`"mainJsPath":"main\\.dart\\.js\\?v=${v1}"`));
  assert.match(boot.headers.get('cache-control'), /no-cache/);

  // 地址里就是当前构建号：地址和内容一一对应，可以长缓存
  const pinned = await a.raw('GET', `/main.dart.js?v=${v1}`);
  assert.equal(pinned.status, 200);
  assert.match(pinned.headers.get('cache-control'), /immutable/);
  // 旧页面拿着过期的构建号来：给的是新内容，不能长缓存
  const stale = await a.raw('GET', '/main.dart.js?v=old');
  assert.match(stale.headers.get('cache-control'), /no-cache/);

  // 升级：main.dart.js 换了内容 → 构建号跟着变，index / bootstrap 引用的地址也变
  fs.writeFileSync(path.join(webRoot, 'main.dart.js'), 'console.log("flutter v2, a bit longer");');
  const v2 = (await a.raw('GET', '/')).text.match(/flutter_bootstrap\.js\?v=([0-9a-z]+)/)?.[1];
  assert.ok(v2 && v2 !== v1, `升级后构建号要变（${v1} → ${v2}）`);
  assert.match((await a.raw('GET', '/flutter_bootstrap.js')).text, new RegExp(`main\\.dart\\.js\\?v=${v2}`));
  assert.match((await a.raw('GET', `/main.dart.js?v=${v1}`)).headers.get('cache-control'), /no-cache/, '旧号不再长缓存');

  // 改写后的内容 ETag 跟着构建号走：浏览器拿旧 ETag 来问，不能回 304
  const idx = await a.raw('GET', '/');
  const idx2 = await a.raw('GET', '/', { headers: { 'if-none-match': idx.headers.get('etag') } });
  assert.equal(idx2.status, 304);
  fs.writeFileSync(path.join(webRoot, 'main.dart.js'), 'console.log("flutter v3 with even more bytes");');
  const idx3 = await a.raw('GET', '/', { headers: { 'if-none-match': idx.headers.get('etag') } });
  assert.equal(idx3.status, 200, '构建号变了，旧 ETag 不再算数');
  assert.equal(Number(idx3.headers.get('content-length')), Buffer.byteLength(idx3.text));
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
