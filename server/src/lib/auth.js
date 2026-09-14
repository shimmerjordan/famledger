'use strict';

// Passwords, session tokens, and the request authenticator the router calls.
//
// Password  scrypt(N=16384, r=8, p=1, keylen=64) with a 16-byte random salt,
//           stored as `scrypt$N$r$p$saltB64$hashB64` so the cost parameters can
//           be raised later without invalidating existing rows.
// Token     base64url(JSON{sub,tid,exp,iat}) '.' base64url(HMAC-SHA256) — a
//           JWT-shaped string without the algorithm-confusion foot-gun, since
//           only one algorithm is ever accepted. Revocation is by `tid`: the
//           matching `devices` row must exist and not be revoked.

const crypto = require('node:crypto');

const { HttpError } = require('./router');
const { rowToJson } = require('./db');

const SCRYPT = { N: 16384, r: 8, p: 1, keylen: 64 };
const TOKEN_TTL_SEC = 30 * 24 * 60 * 60;
// A real hash to compare against when the username does not exist, so a probe
// cannot tell "no such user" from "wrong password" by timing.
const DUMMY_HASH = hashPassword('famledger-dummy-password');

function hashPassword(pw) {
  const salt = crypto.randomBytes(16);
  const hash = crypto.scryptSync(String(pw), salt, SCRYPT.keylen, { N: SCRYPT.N, r: SCRYPT.r, p: SCRYPT.p });
  return `scrypt$${SCRYPT.N}$${SCRYPT.r}$${SCRYPT.p}$${salt.toString('base64')}$${hash.toString('base64')}`;
}

function verifyPassword(pw, stored) {
  if (typeof stored !== 'string') return false;
  const parts = stored.split('$');
  if (parts.length !== 6 || parts[0] !== 'scrypt') return false;
  const [, N, r, p, saltB64, hashB64] = parts;
  try {
    const expected = Buffer.from(hashB64, 'base64');
    const salt = Buffer.from(saltB64, 'base64');
    // Base64 decoding silently drops invalid characters, so a corrupt or
    // truncated row can decode to an empty buffer — and an empty derived key
    // compares equal to an empty expected key, i.e. every password would pass.
    // A hash that is not plausibly a hash never verifies.
    if (expected.length < 16 || salt.length < 8) return false;
    const got = crypto.scryptSync(String(pw), salt, expected.length, {
      N: Number(N),
      r: Number(r),
      p: Number(p),
    });
    return got.length === expected.length && crypto.timingSafeEqual(got, expected);
  } catch {
    return false;
  }
}

/** Burn the same CPU as a real check so timing does not leak account existence. */
function dummyVerify(pw) {
  verifyPassword(pw, DUMMY_HASH);
}

function signToken(secret, { sub, tid, exp, iat } = {}) {
  const nowSec = Math.floor(Date.now() / 1000);
  const payload = { sub, tid, iat: iat ?? nowSec, exp: exp ?? nowSec + TOKEN_TTL_SEC };
  const head = Buffer.from(JSON.stringify(payload), 'utf8').toString('base64url');
  const sig = crypto.createHmac('sha256', secret).update(head).digest('base64url');
  return `${head}.${sig}`;
}

/** @returns {{sub:string,tid:string,exp:number,iat:number}|null} */
function verifyToken(secret, token) {
  if (typeof token !== 'string') return null;
  const dot = token.indexOf('.');
  if (dot <= 0 || token.indexOf('.', dot + 1) !== -1) return null;
  const head = token.slice(0, dot);
  const want = crypto.createHmac('sha256', secret).update(head).digest();
  const got = Buffer.from(token.slice(dot + 1), 'base64url');
  if (got.length !== want.length || !crypto.timingSafeEqual(got, want)) return null;
  let payload;
  try {
    payload = JSON.parse(Buffer.from(head, 'base64url').toString('utf8'));
  } catch {
    return null;
  }
  if (!payload || typeof payload.sub !== 'string' || typeof payload.tid !== 'string') return null;
  if (!Number.isFinite(payload.exp) || payload.exp * 1000 <= Date.now()) return null;
  return payload;
}

/** DB row → the member object every endpoint returns. Never leaks the hash. */
function memberJson(row) {
  return rowToJson(row, { omit: ['password_hash'], bools: ['archived'] });
}

/**
 * Build the function the router calls for every `auth: 'member'|'admin'` route.
 * Throws HttpError(401) for anything it cannot resolve to a live member.
 */
function createAuthenticator({ db, lastSeenThrottleMs = 60000 } = {}, secret) {
  /** @type {Map<string, number>} deviceId → last time we wrote last_seen_at */
  const seen = new Map();

  return function authenticate(req) {
    const header = String(req.headers.authorization || '').trim();
    const m = /^Bearer\s+(\S+)$/i.exec(header);
    if (!m) throw new HttpError(401, 'unauthorized', '缺少访问令牌');

    const payload = verifyToken(secret, m[1]);
    if (!payload) throw new HttpError(401, 'unauthorized', '令牌无效或已过期');

    const device = db.get('SELECT * FROM devices WHERE token_id = ?', payload.tid);
    if (!device || device.revoked_at || device.member_id !== payload.sub) {
      throw new HttpError(401, 'unauthorized', '会话已失效，请重新登录');
    }
    const member = db.get('SELECT * FROM members WHERE id = ?', device.member_id);
    if (!member || member.archived || member.deleted_at) {
      throw new HttpError(401, 'unauthorized', '账号已停用');
    }

    // One write per device per minute: `last_seen_at` is for the device list,
    // not an access log, and a write per request would fsync the WAL constantly.
    const now = Date.now();
    if (now - (seen.get(device.id) || 0) > lastSeenThrottleMs) {
      if (seen.size > 1000) seen.clear();
      seen.set(device.id, now);
      db.run('UPDATE devices SET last_seen_at = ? WHERE id = ?', new Date(now).toISOString(), device.id);
    }

    return { member: memberJson(member), deviceId: device.id, device, row: member };
  };
}

/**
 * Register a device and mint its token. Called by POST /setup and POST /auth/login —
 * the only two places a session is born.
 */
function createSession(db, secret, { memberId, deviceName = null, platform = null } = {}) {
  return db.tx(() => {
    const now = db.now();
    const deviceId = crypto.randomUUID();
    const tokenId = crypto.randomUUID();
    db.run(
      'INSERT INTO devices(id, member_id, name, platform, token_id, created_at, last_seen_at) VALUES(?, ?, ?, ?, ?, ?, ?)',
      deviceId, memberId, deviceName, platform, tokenId, now, now,
    );
    return { deviceId, token: signToken(secret, { sub: memberId, tid: tokenId }) };
  });
}

/** Revoke every live session of a member (optionally sparing one device). */
function revokeSessions(db, memberId, { exceptDeviceId = null } = {}) {
  return db.run(
    'UPDATE devices SET revoked_at = ? WHERE member_id = ? AND revoked_at IS NULL AND id IS NOT ?',
    db.now(), memberId, exceptDeviceId,
  ).changes;
}

module.exports = {
  hashPassword,
  verifyPassword,
  dummyVerify,
  signToken,
  verifyToken,
  memberJson,
  createAuthenticator,
  createSession,
  revokeSessions,
  TOKEN_TTL_SEC,
  SCRYPT,
};
