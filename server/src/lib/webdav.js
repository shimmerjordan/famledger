'use strict';

// A WebDAV client small enough to read in one sitting and tolerant enough for
// the servers people actually point famledger at — 坚果云, Nextcloud/ownCloud,
// Synology, Alist. There is no XML parser in Node's standard library and a
// PROPFIND reply is a fixed, machine-generated shape, so the 207 multistatus is
// picked apart with namespace-agnostic regexes (`<d:href>`, `<D:href>`,
// `<href>` and `<lp1:href>` all parse).
//
//   const c = new WebDavClient({url, username, password});
//   await c.test();                       → {ok, message, status?}   never throws
//   await c.mkcolp('/famledger/2026');    create every missing segment
//   await c.propfind('/famledger', 1);    → [{href, name, isDir, size, modifiedAt}]
//   await c.put(path, buffer, type); await c.get(path); await c.delete(path);
//
// Everything except test() throws WebDavError{status} — status 0 means the
// request never got an answer (DNS, refused, TLS, timeout).
//
// Quirks handled: collections come back with a trailing slash; hrefs are
// percent-encoded and may be absolute URLs; `Depth` is mandatory; MKCOL on an
// existing collection answers 405 (坚果云) or 301 (a redirect to the
// trailing-slash form) rather than a success code; one redirect hop is
// followed by hand because `redirect: 'follow'` turns PROPFIND into GET; a
// NAS that mounts DAV under each shared folder (QNAP) answers PROPFIND on its
// bare root with 405, which test() turns into "add the folder name".

const DEFAULT_TIMEOUT_MS = 60000;
const REDIRECTS = new Set([301, 302, 307, 308]);

const PROPFIND_BODY =
  '<?xml version="1.0" encoding="utf-8"?>\n' +
  '<d:propfind xmlns:d="DAV:"><d:prop>' +
  '<d:getcontentlength/><d:getlastmodified/><d:resourcetype/>' +
  '</d:prop></d:propfind>';

class WebDavError extends Error {
  /**
   * @param {number} status HTTP status, or 0 when the request never completed.
   * @param {string} message
   * @param {string|null} [code] a machine-readable reason, where one exists
   */
  constructor(status, message, code = null) {
    super(message);
    this.name = 'WebDavError';
    this.status = status;
    this.code = code;
  }
}

/** `<ns:name …>inner</ns:name>` → inner. Self-closing tags deliberately miss. */
function tagText(xml, name) {
  const re = new RegExp(`<(?:[\\w.-]+:)?${name}(?:\\s[^>]*)?>([\\s\\S]*?)</(?:[\\w.-]+:)?${name}\\s*>`, 'i');
  const m = re.exec(xml);
  return m ? m[1] : null;
}

const COLLECTION_RE = /<(?:[\w.-]+:)?collection[\s/>]/i;

function unescapeXml(s) {
  return String(s)
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(Number(d)))
    .replace(/&amp;/g, '&');
}

/** Same path, comparable: percent-decoded, no duplicate or trailing slashes. */
function normPath(p) {
  let s = String(p || '/');
  try {
    s = decodeURIComponent(s);
  } catch {
    /* a malformed escape stays as-is rather than losing the whole entry */
  }
  s = s.replace(/\/{2,}/g, '/');
  return s.length > 1 ? s.replace(/\/+$/, '') : s;
}

/** A network failure worth showing a human — never carries credentials. */
function netMessage(e) {
  if (e && (e.name === 'TimeoutError' || e.name === 'AbortError')) return '请求超时';
  const cause = e && e.cause ? e.cause.message || e.cause.code : null;
  const msg = (e && e.message) || String(e);
  return cause && cause !== msg ? `${msg}（${cause}）` : msg;
}

function statusMessage(status, text) {
  if (status === 401 || status === 403) return `认证失败：用户名或口令不对（${status}）`;
  if (status === 404) return `路径不存在（404）`;
  if (status === 405) return `服务器不接受该操作（405）`;
  if (status === 409) return `上级目录不存在（409）`;
  if (status === 507) return `网盘空间不足（507）`;
  const detail = String(text || '').trim().replace(/\s+/g, ' ').slice(0, 200);
  return `WebDAV 返回 ${status}${detail ? `：${detail}` : ''}`;
}

class WebDavClient {
  /**
   * @param {{url:string, username?:string, password?:string, timeoutMs?:number}} opts
   */
  constructor({ url, username = '', password = '', timeoutMs = DEFAULT_TIMEOUT_MS } = {}) {
    const raw = String(url || '').trim();
    if (!raw) throw new WebDavError(0, 'WebDAV 地址未配置');
    let u;
    try {
      u = new URL(raw);
    } catch {
      throw new WebDavError(0, 'WebDAV 地址不是合法的 URL');
    }
    if (u.protocol !== 'http:' && u.protocol !== 'https:') {
      throw new WebDavError(0, 'WebDAV 地址必须以 http:// 或 https:// 开头');
    }
    // Credentials embedded in the URL are accepted but immediately moved out of
    // it, so no error message or log line can ever echo them back.
    this.username = username || decodeURIComponent(u.username || '');
    this.password = password || decodeURIComponent(u.password || '');
    u.username = '';
    u.password = '';
    u.search = '';
    u.hash = '';
    this.base = u.toString().replace(/\/+$/, '');
    this.origin = u.origin;
    this.hostname = u.hostname;
    this.insecure = u.protocol === 'http:';
    this.timeoutMs = Number(timeoutMs) > 0 ? Number(timeoutMs) : DEFAULT_TIMEOUT_MS;
  }

  get authHeader() {
    return 'Basic ' + Buffer.from(`${this.username}:${this.password}`).toString('base64');
  }

  /** `/famledger/a b.db` → `<base>/famledger/a%20b.db` */
  _url(p) {
    const segs = String(p ?? '')
      .split('/')
      .filter(Boolean)
      .map(encodeURIComponent);
    return segs.length ? `${this.base}/${segs.join('/')}` : `${this.base}/`;
  }

  /**
   * One request, at most one redirect hop.
   * @returns {Promise<{res: Response, url: string}>} url = where it ended up
   */
  async _req(method, p, { body, headers, follow = true } = {}) {
    let url = this._url(p);
    for (let hop = 0; ; hop++) {
      let res;
      try {
        res = await fetch(url, {
          method,
          headers: { authorization: this.authHeader, ...headers },
          body,
          redirect: 'manual',
          signal: AbortSignal.timeout(this.timeoutMs),
        });
      } catch (e) {
        throw new WebDavError(0, `连接 WebDAV 失败：${netMessage(e)}`);
      }
      const loc = res.headers.get('location');
      if (hop === 0 && follow && REDIRECTS.has(res.status) && loc) {
        // Drain first: an unconsumed body pins the socket in the undici pool.
        await res.body?.cancel().catch(() => {});
        let next;
        try {
          next = new URL(loc, url);
        } catch {
          throw new WebDavError(res.status, `WebDAV 重定向地址无法解析：${loc}`);
        }
        // Every request carries Basic credentials. Following a redirect to a
        // different site — another host, or https→http — would hand the
        // household's drive password to whoever controls that address, so we
        // stop instead. The one exception is the same host hardening a plain
        // http base to https (see `sameSite`).
        if (!this.sameSite(next)) {
          throw new WebDavError(
            res.status,
            `WebDAV 把请求重定向到了别的地址（${next.origin}），为避免把口令发过去已中止`,
            'redirect_cross_origin',
          );
        }
        url = next.toString();
        continue;
      }
      return { res, url };
    }
  }

  /**
   * Where a redirect may carry the credentials: the same origin, or the same
   * host upgrading a plain-http base to https (the usual "we moved to TLS"
   * bounce, port change included — the NAS behind it is the same machine).
   * A downgrade to http, or any other host, is a stranger.
   * @param {URL} next
   */
  sameSite(next) {
    if (next.origin === this.origin) return true;
    return this.insecure && next.protocol === 'https:' && next.hostname === this.hostname;
  }

  /** Non-2xx → WebDavError; the body is always drained. */
  async _expectOk(res, extraOk = []) {
    if (res.ok || extraOk.includes(res.status)) return;
    let text = '';
    try {
      text = await res.text();
    } catch {
      /* a body we cannot read adds nothing to the message */
    }
    throw new WebDavError(res.status, statusMessage(res.status, text));
  }

  /**
   * @param {string} p
   * @param {number|string} [depth] 0 = the resource itself, 1 = its children
   * @returns {Promise<Array<{href:string, name:string, isDir:boolean, size:number, modifiedAt:string|null}>>}
   */
  async propfind(p, depth = 1) {
    const { res, url } = await this._req('PROPFIND', p, {
      body: PROPFIND_BODY,
      headers: { depth: String(depth), 'content-type': 'application/xml; charset=utf-8' },
    });
    await this._expectOk(res, [207]);
    const xml = await res.text();

    const self = normPath(new URL(url).pathname);
    const out = [];
    // Built per call: a shared /g regex would carry lastIndex between requests.
    const responses = /<(?:[\w.-]+:)?response(?:\s[^>]*)?>([\s\S]*?)<\/(?:[\w.-]+:)?response\s*>/gi;
    for (let m = responses.exec(xml); m; m = responses.exec(xml)) {
      const block = m[1];
      const rawHref = tagText(block, 'href');
      if (rawHref === null) continue;
      const href = unescapeXml(rawHref).trim();
      let pathname;
      try {
        pathname = new URL(href, url).pathname;
      } catch {
        pathname = href;
      }
      const full = normPath(pathname);
      // Depth ≥ 1 lists the collection itself first; only its children matter.
      if (String(depth) !== '0' && full === self) continue;
      const isDir = COLLECTION_RE.test(tagText(block, 'resourcetype') || '');
      const lenText = tagText(block, 'getcontentlength');
      const modText = tagText(block, 'getlastmodified');
      const modMs = modText ? Date.parse(unescapeXml(modText).trim()) : NaN;
      out.push({
        href: full,
        name: full.split('/').filter(Boolean).pop() || '/',
        isDir,
        size: lenText && Number.isFinite(Number(lenText.trim())) ? Number(lenText.trim()) : 0,
        modifiedAt: Number.isFinite(modMs) ? new Date(modMs).toISOString() : null,
      });
    }
    return out;
  }

  /** Create `p` and every missing parent. Already-there is success. */
  async mkcolp(p) {
    const segs = String(p ?? '')
      .split('/')
      .filter(Boolean);
    let cur = '';
    for (const seg of segs) {
      cur += `/${seg}`;
      // A redirect here is either "the DAV root moved" (follow it) or 坚果云's
      // "that is already a collection, ask for the trailing-slash form" — and
      // the retry then answers 405, which is the same success either way.
      // 405/301/302 = already a collection; 200/201/204 = we made it.
      const { res } = await this._req('MKCOL', cur);
      await res.body?.cancel().catch(() => {});
      if (res.ok || res.status === 405 || REDIRECTS.has(res.status)) continue;
      throw new WebDavError(res.status, `创建目录 ${cur} 失败：${statusMessage(res.status, '')}`);
    }
  }

  async put(p, buffer, contentType = 'application/octet-stream') {
    const body = Buffer.isBuffer(buffer) ? buffer : Buffer.from(buffer);
    const { res } = await this._req('PUT', p, {
      body,
      headers: { 'content-type': contentType },
    });
    await this._expectOk(res);
    await res.body?.cancel().catch(() => {});
  }

  /** @returns {Promise<Buffer>} */
  async get(p) {
    const { res } = await this._req('GET', p);
    await this._expectOk(res);
    return Buffer.from(await res.arrayBuffer());
  }

  /** 404 is success: the caller wanted the thing gone and it is. */
  async delete(p) {
    const { res } = await this._req('DELETE', p);
    await this._expectOk(res, [404]);
    await res.body?.cancel().catch(() => {});
  }

  /**
   * Connectivity + credentials, as a value. Never throws.
   * On failure `status` is the HTTP status (0 = no answer), for callers that
   * want to add their own hint; the message already stands on its own.
   */
  async test() {
    try {
      await this.propfind('/', 0);
      return { ok: true, message: '连接成功' };
    } catch (e) {
      if (!(e instanceof WebDavError)) return { ok: false, status: 0, message: netMessage(e) };
      // PROPFIND is the one method every DAV collection must take, so a 405 on
      // the probe means this URL is not a collection at all — typically a NAS
      // (QNAP: `Allow: HEAD,GET,POST,OPTIONS` on `/`) whose DAV lives under
      // each shared folder. Only the probe says so: a 405 anywhere else keeps
      // its generic wording.
      if (e.status === 405) {
        const where = this.base === this.origin ? '这个地址的根目录' : '这个地址';
        return {
          ok: false,
          status: 405,
          message:
            `${where}不是 WebDAV 目录（405）。威联通（QNAP）等 NAS 的 WebDAV 挂在共享文件夹下，` +
            `请在地址后面加上共享文件夹名，比如 ${this.origin}/Web/`,
        };
      }
      return { ok: false, status: e.status, message: e.message };
    }
  }
}

module.exports = { WebDavClient, WebDavError, normPath };
