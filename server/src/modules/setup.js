'use strict';

// First-run wizard. Open while the household has no members; afterwards every
// call is a 409. `SETUP_TOKEN` locks it down for a server that is reachable
// from the internet before anyone has claimed it.

const crypto = require('node:crypto');

const { HttpError, sendJson } = require('../lib/router');
const { RateLimiter } = require('../lib/ratelimit');
const v = require('../lib/validate');
const { hashPassword, memberJson, createSession } = require('../lib/auth');
const { seedDefaults, PALETTE } = require('./seed');

// 2–32 characters, no whitespace and no control characters. Deliberately
// permissive about script so a Chinese username works.
const USERNAME_RE = /^[^\s\p{Cc}]{2,32}$/u;

function timingEqual(a, b) {
  const x = Buffer.from(String(a), 'utf8');
  const y = Buffer.from(String(b), 'utf8');
  return x.length === y.length && crypto.timingSafeEqual(x, y);
}

/**
 * The setup token may arrive either as the `x-setup-token` header or as a
 * `setupToken` field in the JSON body — the Flutter first-run wizard sends the
 * body form, curl and the docs use the header, and rejecting either half would
 * lock one of them out of a `SETUP_TOKEN`-protected instance.
 *
 * Both candidates are always compared (no early exit) so response time cannot
 * reveal which channel matched, and the token is never echoed or logged.
 */
function setupTokenAccepted(configured, req, body) {
  if (!configured) return true;
  let ok = false;
  for (const presented of [req.headers['x-setup-token'], body.setupToken]) {
    if (typeof presented === 'string' && timingEqual(presented, configured)) ok = true;
  }
  return ok;
}

module.exports = (ctx) => {
  const { db, cfg, secret, log } = ctx;
  // Deliberately its own bucket, not the one modules/auth.js uses for login:
  // sharing would let a failed wizard attempt eat a family member's login
  // budget (and vice versa), and the two have very different sane rates.
  const limiter = new RateLimiter(cfg.setupPerMin);

  function status(req, res) {
    // The same predicate `create` uses inside its transaction: any member row
    // means the wizard has run. Disagreeing here would let the app show the
    // wizard on an instance that then answers every submit with 409.
    const first = db.get('SELECT 1 AS ok FROM members LIMIT 1');
    const name = db.meta('household_name', null);
    sendJson(res, 200, first ? { needsSetup: false, householdName: name } : { needsSetup: true });
  }

  function create(req, res, reqCtx) {
    // Before the SETUP_TOKEN comparison, not after: a wrong token is otherwise
    // a zero-cost failure, so an unclaimed instance exposed to the internet
    // could be brute-forced at line speed.
    if (!limiter.allow(reqCtx.ip)) {
      throw new HttpError(429, 'rate_limited', '初始化尝试过于频繁，请稍后再试');
    }
    const b = v.body(reqCtx.body);
    if (!setupTokenAccepted(cfg.setupToken, req, b)) {
      // Deliberately does not include the presented token: this line lands in
      // the container log, which is far less protected than the token itself.
      log.warn('setup', `rejected setup attempt from ${reqCtx.ip} (bad setup token)`);
      throw new HttpError(403, 'forbidden', '初始化令牌不正确');
    }
    const householdName = v.str(b.householdName, 'householdName', { max: 60 });
    const username = v.str(b.username, 'username', { max: 32 });
    if (!USERNAME_RE.test(username)) v.bad('username', '用户名需 2~32 个字符，且不能包含空格');
    const password = v.str(b.password, 'password', { min: 6, max: 128, trim: false });
    const displayName = v.str(b.displayName, 'displayName', { max: 40 });
    const currency = (v.optStr(b.currency, 'currency', { max: 3 }) || 'CNY').toUpperCase();
    if (!/^[A-Z]{3}$/.test(currency)) v.bad('currency', '币种必须是 3 个字母的代码');

    const member = db.tx(() => {
      // Inside the transaction: two clients racing the wizard must not both win.
      if (db.get('SELECT 1 AS ok FROM members LIMIT 1')) {
        throw new HttpError(409, 'already_setup', '该家庭账本已经初始化过了');
      }
      const now = db.now();
      const id = crypto.randomUUID();
      db.run(
        'INSERT INTO members(id, username, password_hash, display_name, color, avatar_emoji, role, archived, created_at, updated_at, seq)' +
          " VALUES(?, ?, ?, ?, ?, ?, 'admin', 0, ?, ?, ?)",
        id, username, hashPassword(password), displayName, PALETTE[0], '🙂', now, now, db.nextSeq(),
      );
      db.setMeta('household_name', householdName);
      db.setMeta('currency', currency);
      seedDefaults(db, { adminId: id });
      db.run('INSERT INTO activity(member_id, action, entity, entity_id, at) VALUES(?, ?, ?, ?, ?)',
        id, 'setup', 'household', id, now);
      return db.get('SELECT * FROM members WHERE id = ?', id);
    });

    const session = createSession(db, secret, {
      memberId: member.id,
      deviceName: v.optStr(b.deviceName, 'deviceName', { max: 60 }),
      platform: v.optStr(b.platform, 'platform', { max: 24 }),
    });
    log.info('setup', `household "${householdName}" initialised by ${username}`);
    sendJson(res, 200, { token: session.token, member: memberJson(member), deviceId: session.deviceId });
  }

  return {
    name: 'setup',
    routes: [
      { method: 'GET', pattern: '/setup/status', handler: status, auth: 'none', maxBody: 0 },
      { method: 'POST', pattern: '/setup', handler: create, auth: 'none' },
    ],
  };
};
