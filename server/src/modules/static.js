'use strict';

// The Flutter web build, served from WEB_ROOT. Not a router module: it has no
// routes, it exports a `fallback` the server calls after every real route has
// missed and the path is not under /api — i.e. it is the last thing tried.
//
// Cache policy: nothing in a Flutter web build is content-addressed —
// main.dart.js, assets/*, canvaskit/* keep the same names from one release to
// the next. Marking them immutable (as this file once did) meant an upgraded
// container kept serving the old app: browsers never asked again, and a CDN in
// front (Cloudflare) kept its copy. So every file revalidates (ETag → 304,
// which is cheap).
//
// On top of that each build gets its own URLs: index.html is served with
// `flutter_bootstrap.js?v=<build>` and flutter_bootstrap.js with
// `"mainJsPath":"main.dart.js?v=<build>"`, the build id following
// main.dart.js. A browser or CDN still holding an old copy under the bare name
// (from the immutable days, or because Cloudflare turns `no-cache` on .js into
// a 4-hour browser TTL) never gets asked for it again. `main.dart.js?v=<current
// build>` names exactly one content, so that one URL may be cached for a year.
// Flutter's service worker already strips `?v=` when it looks up its cache.

const fs = require('node:fs');
const path = require('node:path');

const NO_CACHE = 'no-cache, must-revalidate';
const IMMUTABLE = 'public, max-age=31536000, immutable';

/** Files served with their references pinned to the current build (see above). */
const PIN = {
  'index.html': [/(src=["'])flutter_bootstrap\.js(["'])/g, 'flutter_bootstrap.js'],
  'flutter_bootstrap.js': [/("mainJsPath"\s*:\s*")main\.dart\.js(")/g, 'main.dart.js'],
};

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.map': 'application/json; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.wasm': 'application/wasm',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.avif': 'image/avif',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.bin': 'application/octet-stream',
};

const NOT_BUILT_HTML = `<!doctype html>
<html lang="zh-CN"><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>famledger 家账</title>
<style>
  :root { color-scheme: light dark; }
  body { margin:0; min-height:100vh; display:grid; place-items:center;
         font:16px/1.7 system-ui,-apple-system,"PingFang SC","Microsoft YaHei",sans-serif;
         background:#faf7f4; color:#2c2622; }
  main { max-width:34rem; padding:2rem; }
  h1 { font-size:1.5rem; margin:0 0 .75rem; }
  code { background:rgba(0,0,0,.06); padding:.15em .4em; border-radius:4px; }
  p { margin:.6rem 0; }
  @media (prefers-color-scheme: dark) { body { background:#1c1917; color:#e7e2dc; }
    code { background:rgba(255,255,255,.1); } }
</style>
<main>
  <h1>Web 产物未构建</h1>
  <p>后端已经跑起来了，但 <code>WEB_ROOT</code> 里没有 <code>index.html</code>。</p>
  <p>先构建 Flutter Web 产物（<code>flutter build web</code>），再把 <code>app/build/web</code>
     挂到容器的 <code>/web</code>，或把 <code>WEB_ROOT</code> 指过去。详见 README。</p>
  <p>API 本身不受影响：<code>GET /api/v1/setup/status</code> 可以直接调。</p>
</main>
</html>
`;

module.exports = (ctx) => {
  const { cfg, log } = ctx;
  const root = path.resolve(cfg.webRoot);
  const indexFile = path.join(root, 'index.html');

  /** Map a URL path to a file inside WEB_ROOT, or null if it escapes. */
  function resolveFile(pathname) {
    if (pathname.includes('\0')) return null;
    // Normalise *after* decoding, so `%2e%2e%2f` cannot smuggle a `../` past us.
    const target = path.resolve(root, '.' + path.posix.normalize(pathname));
    if (target !== root && !target.startsWith(root + path.sep)) return null;
    return target;
  }

  function statFile(file) {
    try {
      const st = fs.statSync(file);
      return st.isFile() ? st : null;
    } catch {
      return null;
    }
  }

  function sendFile(req, res, file, st, cacheControl) {
    const etag = `W/"${st.size.toString(16)}-${st.mtimeMs.toString(16)}"`;
    const headers = {
      'content-type': TYPES[path.extname(file).toLowerCase()] || 'application/octet-stream',
      'cache-control': cacheControl,
      'last-modified': st.mtime.toUTCString(),
      etag,
      'x-content-type-options': 'nosniff',
    };
    if (req.headers['if-none-match'] === etag) {
      res.writeHead(304, headers);
      return res.end();
    }
    headers['content-length'] = st.size;
    res.writeHead(200, headers);
    if (req.method === 'HEAD') return res.end();
    const stream = fs.createReadStream(file);
    stream.on('error', (e) => {
      log.error('static', `${file}: ${e.message}`);
      res.destroy();
    });
    stream.pipe(res);
  }

  /** Changes whenever main.dart.js does. Read per request: `scripts/dev.sh` rebuilds the web
   * without restarting the server. null = no build (nothing to pin). */
  function buildId() {
    const st = statFile(path.join(root, 'main.dart.js'));
    return st ? st.size.toString(36) + Math.floor(st.mtimeMs).toString(36) : null;
  }

  /** index.html / flutter_bootstrap.js with their references pinned to [id]. The ETag carries the
   * build id: after an upgrade a browser's old ETag must not earn a 304. */
  function sendPinned(req, res, file, st, id) {
    const [pattern, ref] = PIN[path.basename(file)];
    let text;
    try {
      text = fs.readFileSync(file, 'utf8');
    } catch (e) {
      log.error('static', `${file}: ${e.message}`);
      res.writeHead(500);
      return res.end();
    }
    const body = Buffer.from(text.replace(pattern, `$1${ref}?v=${id}$2`), 'utf8');
    const etag = `W/"${st.size.toString(16)}-${st.mtimeMs.toString(16)}-${id}"`;
    const headers = {
      'content-type': TYPES[path.extname(file).toLowerCase()],
      'cache-control': NO_CACHE,
      'last-modified': st.mtime.toUTCString(),
      etag,
      'x-content-type-options': 'nosniff',
    };
    if (req.headers['if-none-match'] === etag) {
      res.writeHead(304, headers);
      return res.end();
    }
    headers['content-length'] = body.length;
    res.writeHead(200, headers);
    res.end(req.method === 'HEAD' ? undefined : body);
  }

  function sendHtml(res, status, html) {
    const body = Buffer.from(html, 'utf8');
    res.writeHead(status, {
      'content-type': 'text/html; charset=utf-8',
      'content-length': body.length,
      'cache-control': NO_CACHE,
    });
    res.end(body);
  }

  /** @returns {boolean} true when the request was answered here. */
  function fallback(req, res) {
    if (req.method !== 'GET' && req.method !== 'HEAD') return false;

    let pathname;
    let url;
    try {
      url = new URL(req.url, 'http://localhost');
      pathname = decodeURIComponent(url.pathname);
    } catch {
      return false; // malformed encoding — let the caller 404 it
    }

    const index = statFile(indexFile);
    if (!index) {
      if (pathname === '/' || pathname === '/index.html') {
        sendHtml(res, 200, NOT_BUILT_HTML);
        return true;
      }
      return false;
    }

    const id = buildId();
    const target = resolveFile(pathname);
    const st = target && target !== root ? statFile(target) : null;
    if (st) {
      const name = path.basename(target);
      const atRoot = path.dirname(target) === root;
      if (id && atRoot && PIN[name]) {
        sendPinned(req, res, target, st, id);
      } else {
        const pinned = id && atRoot && name === 'main.dart.js' && url.searchParams.get('v') === id;
        sendFile(req, res, target, st, pinned ? IMMUTABLE : NO_CACHE);
      }
      return true;
    }

    // Unknown path → the SPA shell, so a deep link survives a reload.
    if (id) sendPinned(req, res, indexFile, index, id);
    else sendFile(req, res, indexFile, index, NO_CACHE);
    return true;
  }

  return { name: 'static', fallback };
};
