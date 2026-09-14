'use strict';

// The household roster. Everyone can read it (the app colours transactions by
// member); only an admin may change it. Passwords are set here only by an
// admin resetting one — a member changes their own via POST /auth/password.

const crypto = require('node:crypto');

const { HttpError, sendJson } = require('../lib/router');
const v = require('../lib/validate');
const { hashPassword, memberJson, revokeSessions } = require('../lib/auth');
const { PALETTE } = require('./seed');

const USERNAME_RE = /^[^\s\p{Cc}]{2,32}$/u;

module.exports = (ctx) => {
  const { db, log } = ctx;

  const byId = (id) => db.get('SELECT * FROM members WHERE id = ? AND deleted_at IS NULL', id);

  function mustExist(id) {
    const row = byId(id);
    if (!row) throw new HttpError(404, 'not_found', '成员不存在');
    return row;
  }

  function takeUsername(value, field = 'username') {
    const username = v.str(value, field, { max: 32 });
    if (!USERNAME_RE.test(username)) v.bad(field, '用户名需 2~32 个字符，且不能包含空格');
    return username;
  }

  function assertUsernameFree(username, exceptId = null) {
    const clash = db.get('SELECT id FROM members WHERE username = ? AND id IS NOT ?', username, exceptId);
    if (clash) throw new HttpError(409, 'username_taken', '该用户名已被占用');
  }

  /** Refuse to leave the household without anyone who can administer it. */
  function assertNotLastAdmin(row) {
    if (row.role !== 'admin') return;
    const others = db.get(
      "SELECT COUNT(*) AS n FROM members WHERE role = 'admin' AND archived = 0 AND deleted_at IS NULL AND id IS NOT ?",
      row.id,
    );
    if (!others || others.n === 0) {
      throw new HttpError(409, 'last_admin', '至少要保留一位管理员');
    }
  }

  function list(req, res, reqCtx) {
    const withArchived = reqCtx.query.archived === '1' || reqCtx.query.archived === 'true';
    const rows = db.all(
      `SELECT * FROM members WHERE deleted_at IS NULL ${withArchived ? '' : 'AND archived = 0'} ORDER BY created_at, id`,
    );
    sendJson(res, 200, { items: rows.map(memberJson) });
  }

  function create(req, res, reqCtx) {
    const b = v.body(reqCtx.body);
    const username = takeUsername(b.username);
    const password = v.str(b.password, 'password', { min: 6, max: 128, trim: false });
    const displayName = v.str(b.displayName, 'displayName', { max: 40 });
    const role = b.role === undefined ? 'member' : v.enumOf(b.role, 'role', ['admin', 'member']);
    const avatarEmoji = v.emoji(b.avatarEmoji, 'avatarEmoji') || '🙂';

    const member = db.tx(() => {
      assertUsernameFree(username);
      const n = db.get('SELECT COUNT(*) AS n FROM members').n;
      const color = v.color(b.color, 'color') || PALETTE[n % PALETTE.length];
      const now = db.now();
      const id = crypto.randomUUID();
      db.run(
        'INSERT INTO members(id, username, password_hash, display_name, color, avatar_emoji, role, archived, created_at, updated_at, seq)' +
          ' VALUES(?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)',
        id, username, hashPassword(password), displayName, color, avatarEmoji, role, now, now, db.nextSeq(),
      );
      db.run('INSERT INTO activity(member_id, action, entity, entity_id, at) VALUES(?, ?, ?, ?, ?)',
        reqCtx.member.id, 'create', 'member', id, now);
      return db.get('SELECT * FROM members WHERE id = ?', id);
    });
    log.info('members', `${reqCtx.member.username} created member ${username}`);
    sendJson(res, 201, { member: memberJson(member) });
  }

  function patch(req, res, reqCtx) {
    const b = v.body(reqCtx.body);
    const row = mustExist(reqCtx.params.id);

    const next = {
      username: b.username === undefined ? row.username : takeUsername(b.username),
      display_name: b.displayName === undefined ? row.display_name : v.str(b.displayName, 'displayName', { max: 40 }),
      color: b.color === undefined ? row.color : v.color(b.color, 'color', { required: true }),
      avatar_emoji: b.avatarEmoji === undefined ? row.avatar_emoji : v.emoji(b.avatarEmoji, 'avatarEmoji') || row.avatar_emoji,
      role: b.role === undefined ? row.role : v.enumOf(b.role, 'role', ['admin', 'member']),
      archived: b.archived === undefined ? row.archived : (v.bool(b.archived, 'archived') ? 1 : 0),
    };

    const member = db.tx(() => {
      if (next.username !== row.username) assertUsernameFree(next.username, row.id);
      // Only guard the change that would actually remove the last admin.
      const losesAdmin = row.role === 'admin' && !row.archived && (next.role !== 'admin' || next.archived === 1);
      if (losesAdmin) assertNotLastAdmin(row);
      db.run(
        'UPDATE members SET username = ?, display_name = ?, color = ?, avatar_emoji = ?, role = ?, archived = ?, updated_at = ?, seq = ? WHERE id = ?',
        next.username, next.display_name, next.color, next.avatar_emoji, next.role, next.archived,
        db.now(), db.nextSeq(), row.id,
      );
      if (next.archived && !row.archived) revokeSessions(db, row.id);
      return db.get('SELECT * FROM members WHERE id = ?', row.id);
    });
    sendJson(res, 200, { member: memberJson(member) });
  }

  /** DELETE archives: transactions keep pointing at a member who left. */
  function archive(req, res, reqCtx) {
    const row = mustExist(reqCtx.params.id);
    const member = db.tx(() => {
      assertNotLastAdmin(row);
      db.run('UPDATE members SET archived = 1, updated_at = ?, seq = ? WHERE id = ?', db.now(), db.nextSeq(), row.id);
      revokeSessions(db, row.id);
      db.run('INSERT INTO activity(member_id, action, entity, entity_id, at) VALUES(?, ?, ?, ?, ?)',
        reqCtx.member.id, 'archive', 'member', row.id, db.now());
      return db.get('SELECT * FROM members WHERE id = ?', row.id);
    });
    sendJson(res, 200, { member: memberJson(member) });
  }

  function resetPassword(req, res, reqCtx) {
    const b = v.body(reqCtx.body);
    const password = v.str(b.password, 'password', { min: 6, max: 128, trim: false });
    const row = mustExist(reqCtx.params.id);
    db.tx(() => {
      db.run('UPDATE members SET password_hash = ?, updated_at = ?, seq = ? WHERE id = ?',
        hashPassword(password), db.now(), db.nextSeq(), row.id);
      // The old password may be what leaked; every session minted under it goes.
      revokeSessions(db, row.id);
    });
    log.info('members', `${reqCtx.member.username} reset the password of ${row.username}`);
    sendJson(res, 200, { ok: true });
  }

  return {
    name: 'members',
    routes: [
      { method: 'GET', pattern: '/members', handler: list, maxBody: 0 },
      { method: 'POST', pattern: '/members', handler: create, auth: 'admin' },
      { method: 'PATCH', pattern: '/members/:id', handler: patch, auth: 'admin' },
      { method: 'DELETE', pattern: '/members/:id', handler: archive, auth: 'admin' },
      { method: 'POST', pattern: '/members/:id/reset-password', handler: resetPassword, auth: 'admin' },
    ],
  };
};
