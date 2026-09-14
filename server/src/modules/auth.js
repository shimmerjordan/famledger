'use strict';

// Sessions: login, logout, who-am-I, and changing your own password.
// Login is the only unauthenticated write in the API, so it is the only thing
// rate-limited (LOGIN_PER_MIN per client IP).

const { HttpError, sendJson } = require('../lib/router');
const { RateLimiter } = require('../lib/ratelimit');
const v = require('../lib/validate');
const {
  hashPassword, verifyPassword, dummyVerify, memberJson, createSession, revokeSessions,
} = require('../lib/auth');

module.exports = (ctx) => {
  const { db, cfg, secret, log } = ctx;
  const limiter = new RateLimiter(cfg.loginPerMin);

  function household() {
    return { name: db.meta('household_name', ''), currency: db.meta('currency', 'CNY') };
  }

  function login(req, res, reqCtx) {
    if (!limiter.allow(reqCtx.ip)) {
      throw new HttpError(429, 'rate_limited', '登录尝试过于频繁，请稍后再试');
    }
    const b = v.body(reqCtx.body);
    const username = v.str(b.username, 'username', { max: 32 });
    const password = typeof b.password === 'string' ? b.password : '';

    const row = db.get('SELECT * FROM members WHERE username = ? AND deleted_at IS NULL', username);
    if (!row || row.archived) {
      dummyVerify(password); // keep the timing of a real check
      throw new HttpError(401, 'invalid_credentials', '用户名或密码不正确');
    }
    if (!verifyPassword(password, row.password_hash)) {
      log.warn('auth', `failed login for ${username} from ${reqCtx.ip}`);
      throw new HttpError(401, 'invalid_credentials', '用户名或密码不正确');
    }

    const session = createSession(db, secret, {
      memberId: row.id,
      deviceName: v.optStr(b.deviceName, 'deviceName', { max: 60 }),
      platform: v.optStr(b.platform, 'platform', { max: 24 }),
    });
    sendJson(res, 200, {
      token: session.token,
      member: memberJson(row),
      deviceId: session.deviceId,
      household: household(),
    });
  }

  function logout(req, res, reqCtx) {
    db.run('UPDATE devices SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL', db.now(), reqCtx.deviceId);
    sendJson(res, 200, { ok: true });
  }

  function me(req, res, reqCtx) {
    sendJson(res, 200, { member: reqCtx.member, household: household(), deviceId: reqCtx.deviceId });
  }

  function changePassword(req, res, reqCtx) {
    const b = v.body(reqCtx.body);
    const oldPassword = typeof b.oldPassword === 'string' ? b.oldPassword : '';
    const newPassword = v.str(b.newPassword, 'newPassword', { min: 6, max: 128, trim: false });

    const row = db.get('SELECT * FROM members WHERE id = ?', reqCtx.member.id);
    if (!row || !verifyPassword(oldPassword, row.password_hash)) {
      throw new HttpError(401, 'invalid_credentials', '当前密码不正确');
    }
    db.tx(() => {
      db.run('UPDATE members SET password_hash = ?, updated_at = ?, seq = ? WHERE id = ?',
        hashPassword(newPassword), db.now(), db.nextSeq(), row.id);
      // Every other device still holds a token minted under the old password.
      revokeSessions(db, row.id, { exceptDeviceId: reqCtx.deviceId });
    });
    sendJson(res, 200, { ok: true });
  }

  return {
    name: 'auth',
    routes: [
      { method: 'POST', pattern: '/auth/login', handler: login, auth: 'none' },
      { method: 'POST', pattern: '/auth/logout', handler: logout },
      { method: 'GET', pattern: '/auth/me', handler: me, maxBody: 0 },
      { method: 'POST', pattern: '/auth/password', handler: changePassword },
    ],
  };
};
