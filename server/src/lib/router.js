'use strict';

// Minimal path router. Patterns are literal segments or `:param`; matching is
// exact on segment count. The dispatcher owns three cross-cutting concerns so
// no module has to repeat them:
//
//   1. body buffering + JSON parsing (per-route `maxBody`, 0 = stream it
//      yourself),
//   2. authentication and the role gate (`auth: 'none' | 'member' | 'admin'`),
//   3. turning a thrown HttpError into the `{error:{code,message}}` body.
//
// handler(req, res, ctx) with ctx = {params, query, body, member?, deviceId?, ip}.

const { clientIp } = require('./clientip');

const DEFAULT_MAX_BODY = 64 * 1024;
const BODY_METHODS = new Set(['POST', 'PUT', 'PATCH', 'DELETE']);

/**
 * An error the client is allowed to see. Anything else becomes a 500.
 * `details` (optional, a plain object) rides along as `error.details` — e.g. the
 * id of the row a name collided with, so the client can offer to use that one.
 */
class HttpError extends Error {
  constructor(status, code, message, details = null) {
    super(message || code);
    this.name = 'HttpError';
    this.status = status;
    this.code = code;
    this.details = details;
  }
}

function sendJson(res, status, obj, extraHeaders = {}) {
  const body = Buffer.from(JSON.stringify(obj ?? null), 'utf8');
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': body.length,
    ...extraHeaders,
  });
  res.end(body);
}

/** Every error body in this API has the same shape. */
function sendError(res, status, code, message, details = null) {
  sendJson(res, status, { error: { code, message: message || code, ...(details ? { details } : {}) } });
}

class Router {
  /**
   * @param {{authenticate?: (req:import('node:http').IncomingMessage)=>{member:object, deviceId:string},
   *          trustProxy?: boolean, prefix?: string}} [opts]
   */
  constructor(opts = {}) {
    this.routes = [];
    this.authenticate = opts.authenticate || null;
    this.trustProxy = !!opts.trustProxy;
    this.prefix = opts.prefix || '';
  }

  /**
   * @param {string} method
   * @param {string} pattern e.g. `/members/:id/reset-password`
   * @param {Function} handler async (req, res, ctx) => void
   * @param {{maxBody?: number, auth?: 'none'|'member'|'admin'}} [opts]
   */
  add(method, pattern, handler, opts = {}) {
    const auth = opts.auth || 'member';
    if (!['none', 'member', 'admin'].includes(auth)) {
      throw new Error(`route ${method} ${pattern}: unknown auth level "${auth}"`);
    }
    this.routes.push({
      method: method.toUpperCase(),
      pattern: this.prefix + pattern,
      segs: (this.prefix + pattern).split('/').filter(Boolean),
      handler,
      auth,
      maxBody: opts.maxBody ?? DEFAULT_MAX_BODY,
    });
  }

  /** Find a route; returns null when nothing matches. */
  match(method, segs) {
    for (const r of this.routes) {
      if (r.method !== method) continue;
      if (r.segs.length !== segs.length) continue;
      const params = {};
      let ok = true;
      for (let i = 0; i < segs.length; i++) {
        const p = r.segs[i];
        if (p.charCodeAt(0) === 58 /* : */) params[p.slice(1)] = segs[i];
        else if (p !== segs[i]) {
          ok = false;
          break;
        }
      }
      if (ok) return { route: r, params };
    }
    return null;
  }

  /** Handle a request. Returns false when no route matched. */
  async dispatch(req, res) {
    const url = new URL(req.url, 'http://localhost');
    let segs;
    try {
      segs = url.pathname.split('/').filter(Boolean).map(decodeURIComponent);
    } catch {
      sendError(res, 400, 'bad_path', '路径编码无效');
      return true;
    }
    const m = this.match(req.method, segs);
    if (!m) return false;

    const ctx = {
      params: m.params,
      query: Object.fromEntries(url.searchParams),
      body: null,
      member: null,
      deviceId: null,
      ip: clientIp(req, this.trustProxy),
    };

    try {
      if (m.route.auth !== 'none') {
        if (!this.authenticate) throw new HttpError(500, 'no_authenticator', 'router has no authenticator');
        const who = await this.authenticate(req);
        ctx.member = who.member;
        ctx.deviceId = who.deviceId;
        if (m.route.auth === 'admin' && who.member.role !== 'admin') {
          throw new HttpError(403, 'forbidden', '需要管理员权限');
        }
      }
      if (m.route.maxBody > 0 && BODY_METHODS.has(req.method)) {
        ctx.body = parseJsonBody(await readBody(req, m.route.maxBody));
      }
      await m.route.handler(req, res, ctx);
    } catch (e) {
      if (!(e instanceof HttpError)) throw e;
      if (res.headersSent) res.destroy();
      else sendError(res, e.status, e.code, e.message, e.details);
    }
    return true;
  }
}

/** Buffer a request body up to maxBytes; rejects oversize early. */
function readBody(req, maxBytes) {
  return new Promise((resolve, reject) => {
    const len = Number(req.headers['content-length'] || 0);
    if (len > maxBytes) {
      // Declared oversize: nothing has been uploaded yet, so answer cleanly and
      // let Node drain the rest — the client gets a 413 instead of a reset.
      return reject(new HttpError(413, 'body_too_large', '请求体过大'));
    }
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > maxBytes) {
        // Already streaming past the cap (chunked, or a lying content-length):
        // cutting the socket is the only way to stop an unbounded upload.
        req.destroy();
        return reject(new HttpError(413, 'body_too_large', '请求体过大'));
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', (e) => reject(new HttpError(400, 'bad_request', e.message)));
  });
}

/** `{}` for an empty body so handlers can read fields without a null check. */
function parseJsonBody(buf) {
  if (!buf || buf.length === 0) return {};
  let v;
  try {
    v = JSON.parse(buf.toString('utf8'));
  } catch {
    throw new HttpError(400, 'bad_json', '请求体不是合法 JSON');
  }
  if (v === null || typeof v !== 'object') {
    throw new HttpError(400, 'bad_json', '请求体必须是 JSON 对象');
  }
  return v;
}

module.exports = { Router, HttpError, sendJson, sendError, readBody, DEFAULT_MAX_BODY };
