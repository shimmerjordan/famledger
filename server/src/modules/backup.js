'use strict';

// Scheduled encrypted snapshots to any WebDAV drive, plus restore/export/import.
//
//   VACUUM INTO tmp → gzip → [FLBK1 | salt16 | nonce12 | ciphertext | tag16]
//     → PUT <remoteDir>/famledger-YYYYMMDD-HHMMSS.db.gz[.enc]
//     → PUT the same name + `.json` (manifest: bytes, sha256, schemaVersion)
//     → delete everything past the newest `keep` snapshots
//
// VACUUM INTO rather than copying the file: it takes a consistent snapshot of
// a live WAL database without stopping writers, and it is the only way to get
// one without linking sqlite3_backup.
//
// Restore never writes into the open database. It downloads, verifies the
// manifest checksum, decrypts, gunzips, and opens the candidate as its own
// SQLite connection to run `PRAGMA integrity_check` — only a file that passes
// gets to replace the live one, and the live one is copied to
// `pre-restore-<stamp>.db` first. The swap is `db.close()` → rename →
// `db.reopen()` (which re-runs migrations), so the process never restarts.
//
// Everything here is admin-only. The WebDAV password and the backup passphrase
// are stored AES-256-GCM-encrypted under `DATA_DIR/secret.key` (lib/secret.js)
// and are never returned by the API, never logged, and never put in an error
// message. `GET /backup/config` answers with `hasPassword`/`hasPassphrase`.
// `POST /backup/test` can try unsaved form values, and the stored password only
// ever travels to the stored URL's origin (see testTarget).
//
// Environment: BACKUP_TICK_MS overrides the 60 s scheduler tick (tests only).

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');

const { HttpError, sendJson, readBody } = require('../lib/router');
const { swapDatabase, DbSwapError } = require('../lib/db_swap');
const v = require('../lib/validate');
const { encrypt, decrypt } = require('../lib/secret');
const { WebDavClient, WebDavError } = require('../lib/webdav');

const CONFIG_KEY = 'backup_config';
const LAST_DAY_KEY = 'backup_last_day';      // a day that is settled: no more attempts
const LAST_ATTEMPT_KEY = 'backup_last_attempt'; // ISO of the last scheduled attempt
const ATTEMPTS_KEY = 'backup_attempts';      // "<YYYY-MM-DD>:<n>" attempts made that day

const MAX_ATTEMPTS = 3;
const RETRY_BACKOFF_MS = 10 * 60 * 1000;

const MAGIC = Buffer.from('FLBK1', 'latin1');
const HEADER_LEN = MAGIC.length + 16 + 12; // magic | salt | nonce
const TAG_LEN = 16;
const SCRYPT = { N: 32768, r: 8, p: 1, maxmem: 64 * 1024 * 1024 };

const SNAPSHOT_RE = /^famledger-\d{8}-\d{6}\.db\.gz(\.enc)?$/;
const MAX_IMPORT = 200 * 1024 * 1024;
const HISTORY_KEEP = 100;
const HISTORY_PAGE = 20;
const WEBDAV_TIMEOUT_MS = 120000;
const DEFAULT_TICK_MS = 60000;

const DEFAULTS = { remoteDir: '/famledger', hour: 3, keep: 14 };

const sha256hex = (buf) => crypto.createHash('sha256').update(buf).digest('hex');
const pad = (n, w = 2) => String(n).padStart(w, '0');

/** Local-time `YYYYMMDD-HHMMSS` — the household reads these names, not UTC. */
function stampOf(d) {
  return (
    `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-` +
    `${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`
  );
}
const dayOf = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;

/** `/a//b/` → `/a/b`; rejects `..`. Empty → the default directory. */
function normalizeDir(value, field = 'remoteDir') {
  if (value === undefined || value === null || value === '') return DEFAULTS.remoteDir;
  if (typeof value !== 'string') v.bad(field, 'remoteDir 必须是字符串');
  const segs = value.split('/').filter(Boolean);
  if (segs.some((s) => s === '.' || s === '..')) v.bad(field, 'remoteDir 不能包含 . 或 ..');
  if (segs.length === 0) return DEFAULTS.remoteDir;
  const dir = '/' + segs.join('/');
  if (dir.length > 200) v.bad(field, 'remoteDir 太长了');
  return dir;
}

/** `https://nas:5006/dav` → `https://nas:5006`; anything unparseable (or '') → null. */
function originOf(url) {
  try {
    const o = new URL(url).origin;
    return o === 'null' ? null : o; // opaque origins (file:, data:) never match anything
  } catch {
    return null;
  }
}

/**
 * The whole scheduling decision as one pure function — no timers, no database,
 * so it can be unit-tested directly instead of by waiting on the clock.
 *
 * A transient drive failure used to cost the household that day's backup: the
 * day was claimed before the attempt, so nothing tried again until tomorrow.
 * Now the day is only settled on success or after MAX_ATTEMPTS tries, spaced
 * RETRY_BACKOFF_MS apart, and only inside the configured hour.
 *
 * @param {Date} now
 * @param {{schedule:{enabled:boolean, hour:number}, webdav:{url:string}}} c
 * @param {{lastDay?:string|null, lastAttempt?:string|null, attemptDay?:string|null, attempts?:number}} m
 * @returns {{run:boolean, reason:string}}
 */
function shouldRunNow(now, c, m = {}) {
  if (!c.schedule.enabled) return { run: false, reason: 'disabled' };
  if (!c.webdav.url) return { run: false, reason: 'not_configured' };
  if (now.getHours() !== c.schedule.hour) return { run: false, reason: 'off_hour' };

  const day = dayOf(now);
  if (m.lastDay === day) return { run: false, reason: 'settled_today' };

  const attempts = m.attemptDay === day ? Number(m.attempts) || 0 : 0;
  if (attempts >= MAX_ATTEMPTS) return { run: false, reason: 'attempts_exhausted' };
  if (attempts > 0) {
    const last = Date.parse(m.lastAttempt || '');
    // An unparseable timestamp must not unlock an immediate retry loop.
    if (!Number.isFinite(last)) return { run: false, reason: 'backoff' };
    if (now.getTime() - last < RETRY_BACKOFF_MS) return { run: false, reason: 'backoff' };
  }
  return { run: true, reason: attempts === 0 ? 'scheduled' : `retry_${attempts}` };
}

/** When the next attempt is due, given the same inputs. @returns {string|null} ISO */
function nextRunFrom(now, c, m = {}) {
  if (!c.schedule.enabled) return null;
  const day = dayOf(now);
  const attempts = m.attemptDay === day ? Number(m.attempts) || 0 : 0;
  if (m.lastDay !== day && now.getHours() === c.schedule.hour && attempts < MAX_ATTEMPTS) {
    const last = Date.parse(m.lastAttempt || '');
    const earliest = attempts > 0 && Number.isFinite(last) ? last + RETRY_BACKOFF_MS : now.getTime();
    return new Date(Math.max(earliest, now.getTime())).toISOString();
  }
  const at = new Date(now);
  at.setHours(c.schedule.hour, 0, 0, 0);
  if (m.lastDay === day || at <= now) at.setDate(at.getDate() + 1);
  return at.toISOString();
}

module.exports = (ctx) => {
  const { db, secret, log } = ctx;

  // One mutual exclusion for every operation that owns the database file:
  // a backup reads it, a restore/import replaces it, and none of the three may
  // overlap — a restore that closed the database under a running backup used to
  // leave that backup writing into a null connection.
  /** @type {null|'backup'|'restore'|'import'} */
  let busy = null;
  let timer = null;
  let lastStamp = '';

  // ------------------------------------------------------------------ config

  function stored() {
    try {
      const raw = JSON.parse(db.meta(CONFIG_KEY, '{}'));
      return v.isObject(raw) ? raw : {};
    } catch {
      return {};
    }
  }

  /** Stored config with every field defaulted — the only shape the rest reads. */
  function config() {
    const c = stored();
    const w = v.isObject(c.webdav) ? c.webdav : {};
    const s = v.isObject(c.schedule) ? c.schedule : {};
    const e = v.isObject(c.encryption) ? c.encryption : {};
    const str = (x) => (typeof x === 'string' ? x : '');
    const int = (x, dflt, min, max) => (Number.isInteger(x) && x >= min && x <= max ? x : dflt);
    return {
      webdav: {
        url: str(w.url),
        username: str(w.username),
        passwordEnc: str(w.passwordEnc),
        remoteDir: typeof w.remoteDir === 'string' && w.remoteDir ? w.remoteDir : DEFAULTS.remoteDir,
      },
      schedule: {
        enabled: !!s.enabled,
        hour: int(s.hour, DEFAULTS.hour, 0, 23),
        keep: int(s.keep, DEFAULTS.keep, 1, 3650),
      },
      encryption: { enabled: !!e.enabled, passphraseEnc: str(e.passphraseEnc) },
    };
  }

  const BUSY_LABEL = { backup: '备份', restore: '恢复', import: '导入' };

  /**
   * Take the lock for the whole operation — download included, not just the
   * moment the file is swapped. Throws 409 when someone else holds it.
   * Always call it OUTSIDE the try whose finally releases, so a request that
   * never got the lock cannot release someone else's.
   */
  function acquire(kind) {
    if (busy) {
      const code = busy === 'backup' ? 'backup_running' : 'restore_running';
      throw new HttpError(409, code, `${BUSY_LABEL[busy]}正在进行，请稍后再试`);
    }
    busy = kind;
  }

  /** A stored secret, or null when absent/unreadable (a rotated secret.key). */
  function reveal(enc) {
    if (!enc) return null;
    try {
      return decrypt(secret, enc);
    } catch {
      log.warn('backup', '存储的口令/密语无法解密（secret.key 换过了？），请重新填写');
      return null;
    }
  }

  function lastRunRow() {
    return db.get('SELECT * FROM backup_runs ORDER BY started_at DESC, rowid DESC LIMIT 1');
  }

  function runJson(row) {
    if (!row) return null;
    return {
      id: row.id,
      startedAt: row.started_at,
      finishedAt: row.finished_at ?? null,
      ok: row.ok === null || row.ok === undefined ? null : !!row.ok,
      name: row.name ?? null,
      bytes: row.bytes ?? null,
      message: row.message ?? null,
    };
  }

  /** Everything shouldRunNow/nextRunFrom need, read out of `meta`. */
  function scheduleMeta() {
    const [attemptDay, n] = String(db.meta(ATTEMPTS_KEY, '') || '').split(':');
    return {
      lastDay: db.meta(LAST_DAY_KEY, null),
      lastAttempt: db.meta(LAST_ATTEMPT_KEY, null),
      attemptDay: attemptDay || null,
      attempts: Number(n) || 0,
    };
  }

  /** When the scheduler will next fire, as an instant the client can render. */
  function nextRunAt(c = config()) {
    return nextRunFrom(new Date(), c, scheduleMeta());
  }

  function publicConfig() {
    const c = config();
    return {
      webdav: {
        url: c.webdav.url,
        username: c.webdav.username,
        hasPassword: !!c.webdav.passwordEnc,
        remoteDir: c.webdav.remoteDir,
      },
      schedule: { ...c.schedule },
      encryption: { enabled: c.encryption.enabled, hasPassphrase: !!c.encryption.passphraseEnc },
      lastRun: runJson(lastRunRow()),
      nextRun: nextRunAt(c),
    };
  }

  function getConfig(req, res) {
    sendJson(res, 200, publicConfig());
  }

  /**
   * `https://u:p@host/dav` → `{url:'https://host/dav', username:'u', password:'p'}`.
   * Credentials are split out of the URL before it is stored, because the
   * stored URL is handed straight back by GET /backup/config.
   */
  function parseWebdavUrl(value) {
    if (value === null || value === undefined || value === '') return { url: '', username: null, password: null };
    const s = v.str(value, 'url', { max: 500 });
    let u;
    try {
      u = new URL(s);
    } catch {
      v.bad('url', 'WebDAV 地址不是合法的 URL');
    }
    if (u.protocol !== 'http:' && u.protocol !== 'https:') v.bad('url', 'WebDAV 地址必须以 http:// 或 https:// 开头');
    const username = u.username ? decodeURIComponent(u.username) : null;
    const password = u.password ? decodeURIComponent(u.password) : null;
    u.username = '';
    u.password = '';
    u.search = '';
    u.hash = '';
    return { url: u.toString().replace(/\/+$/, ''), username, password };
  }

  /**
   * PUT /backup/config — merged one level deep so the app can send just the
   * section it changed. `''` for a secret means "leave it alone" (the UI shows
   * a blank password box on a configured server); `null` clears it.
   */
  function putConfig(req, res, reqCtx) {
    const b = v.body(reqCtx.body);
    const cur = config();
    const next = { webdav: { ...cur.webdav }, schedule: { ...cur.schedule }, encryption: { ...cur.encryption } };

    if (b.webdav !== undefined) {
      const w = v.isObject(b.webdav) ? b.webdav : v.bad('webdav', 'webdav 必须是对象');
      if (w.url !== undefined) {
        const parsed = parseWebdavUrl(w.url);
        next.webdav.url = parsed.url;
        // Credentials pasted into the URL only count when the request did not
        // spell them out separately.
        if (parsed.username && w.username === undefined) next.webdav.username = parsed.username;
        if (parsed.password && w.password === undefined) next.webdav.passwordEnc = encrypt(secret, parsed.password);
      }
      if (w.username !== undefined) next.webdav.username = v.optStr(w.username, 'username', { max: 200 }) || '';
      if (w.remoteDir !== undefined) next.webdav.remoteDir = normalizeDir(w.remoteDir);
      if (w.password !== undefined) {
        if (w.password === null) next.webdav.passwordEnc = '';
        else {
          const pw = v.str(w.password, 'password', { min: 0, max: 512, trim: false });
          if (pw !== '') next.webdav.passwordEnc = encrypt(secret, pw);
        }
      }
    }
    if (b.schedule !== undefined) {
      const s = v.isObject(b.schedule) ? b.schedule : v.bad('schedule', 'schedule 必须是对象');
      if (s.enabled !== undefined) next.schedule.enabled = v.bool(s.enabled, 'enabled');
      if (s.hour !== undefined) next.schedule.hour = v.int(s.hour, 'hour', { min: 0, max: 23 });
      if (s.keep !== undefined) next.schedule.keep = v.int(s.keep, 'keep', { min: 1, max: 3650 });
    }
    if (b.encryption !== undefined) {
      const e = v.isObject(b.encryption) ? b.encryption : v.bad('encryption', 'encryption 必须是对象');
      if (e.passphrase !== undefined) {
        if (e.passphrase === null) next.encryption.passphraseEnc = '';
        else {
          const pass = v.str(e.passphrase, 'passphrase', { min: 0, max: 512, trim: false });
          if (pass !== '') {
            if (pass.length < 8) v.bad('passphrase', '密语至少 8 个字符');
            next.encryption.passphraseEnc = encrypt(secret, pass);
          }
        }
      }
      if (e.enabled !== undefined) next.encryption.enabled = v.bool(e.enabled, 'enabled');
    }
    // A passphrase that is not stored is a passphrase nobody can restore with.
    if (next.encryption.enabled && !next.encryption.passphraseEnc) {
      v.bad('passphrase', '开启备份加密必须先设置密语');
    }

    db.setMeta(CONFIG_KEY, JSON.stringify(next));
    log.info(
      'backup',
      `config updated: url=${next.webdav.url ? 'set' : 'empty'} dir=${next.webdav.remoteDir} ` +
        `schedule=${next.schedule.enabled ? `${next.schedule.hour}:00` : 'off'} keep=${next.schedule.keep} ` +
        `encryption=${next.encryption.enabled ? 'on' : 'off'}`,
    );
    sendJson(res, 200, publicConfig());
  }

  // ------------------------------------------------------------------ remote

  function makeClient(c = config()) {
    return new WebDavClient({
      url: c.webdav.url,
      username: c.webdav.username,
      password: reveal(c.webdav.passwordEnc) || '',
      timeoutMs: WEBDAV_TIMEOUT_MS,
    });
  }

  /** Anything thrown below the HTTP layer, as something the client can read. */
  function toHttp(e) {
    if (e instanceof HttpError) return e;
    if (e instanceof WebDavError) return new HttpError(502, 'webdav_error', e.message);
    return new HttpError(500, 'backup_failed', `备份失败：${e.message || e}`);
  }

  /**
   * What POST /backup/test should connect to: the stored WebDAV settings with
   * whatever the form sent (`{url, username, password, remoteDir}`, all
   * optional) laid over them, so a setting can be tried before it is saved.
   * Nothing here is written anywhere. Validation and the blank/absent rules are
   * putConfig's — `''` or no password means "the stored one", `null` means none
   * — so a value that tests fine is a value that saves fine.
   *
   * The stored password only follows a URL on the stored URL's origin (scheme,
   * host and port). Otherwise any admin session could point the test at a
   * server it controls and read the drive password out of the Basic header.
   *
   * @returns {{url:string, username:string, password:string, remoteDir:string,
   *   overridden:boolean, passwordFrom:'typed'|'url'|'saved'|'withheld'|'none'}}
   */
  function testTarget(b) {
    const cur = config().webdav;
    const t = {
      url: cur.url,
      username: cur.username,
      password: '',
      remoteDir: cur.remoteDir,
      overridden: ['url', 'username', 'password', 'remoteDir'].some((k) => b[k] !== undefined),
      passwordFrom: 'none',
    };
    let urlPassword = null;
    if (b.url !== undefined) {
      const parsed = parseWebdavUrl(b.url);
      t.url = parsed.url;
      // Same rule as putConfig: credentials pasted into the URL only count when
      // the request did not spell them out separately.
      if (parsed.username && b.username === undefined) t.username = parsed.username;
      if (parsed.password && b.password === undefined) urlPassword = parsed.password;
    }
    if (b.username !== undefined) t.username = v.optStr(b.username, 'username', { max: 200 }) || '';
    if (b.remoteDir !== undefined) t.remoteDir = normalizeDir(b.remoteDir);

    const typed = b.password === undefined || b.password === null
      ? ''
      : v.str(b.password, 'password', { min: 0, max: 512, trim: false });
    if (typed !== '') {
      t.password = typed;
      t.passwordFrom = 'typed';
    } else if (urlPassword) {
      t.password = urlPassword;
      t.passwordFrom = 'url';
    } else if (b.password !== null && cur.passwordEnc) {
      const origin = originOf(t.url);
      if (origin && origin === originOf(cur.url)) {
        t.password = reveal(cur.passwordEnc) || '';
        t.passwordFrom = 'saved';
      } else {
        t.passwordFrom = 'withheld';
      }
    }
    return t;
  }

  /**
   * POST /backup/test — probe, create remoteDir, count the snapshots already
   * there. Always 200 `{ok, message}` once the body validates; an empty body
   * tests exactly what is saved.
   */
  async function testConnection(req, res, reqCtx) {
    const t = testTarget(v.body(reqCtx.body));
    const reply = (out) => {
      // Where the password came from, never the password itself.
      log.info(
        'backup',
        `test: ${t.overridden ? 'unsaved form values' : 'saved config'} origin=${originOf(t.url) || 'none'} ` +
          `password=${t.passwordFrom} → ${out.ok ? 'ok' : `failed: ${out.message}`}`,
      );
      sendJson(res, 200, { ok: out.ok, message: out.message });
    };

    if (!t.url) return reply({ ok: false, message: '还没有配置 WebDAV 地址' });
    let client;
    try {
      client = new WebDavClient({ url: t.url, username: t.username, password: t.password, timeoutMs: WEBDAV_TIMEOUT_MS });
    } catch (e) {
      return reply({ ok: false, message: e.message });
    }
    const probe = await client.test();
    if (!probe.ok) {
      // A 401 right after the stored password was held back is the one case
      // where "wrong username or password" would send the household hunting
      // for the wrong fault.
      const withheld = t.passwordFrom === 'withheld' && (probe.status === 401 || probe.status === 403);
      return reply({
        ok: false,
        message: withheld ? `${probe.message}。地址换到了别的服务器，已保存的口令不会带过去，请把口令重新填一遍` : probe.message,
      });
    }
    try {
      await client.mkcolp(t.remoteDir);
      const n = (await client.propfind(t.remoteDir, 1)).filter((i) => !i.isDir && SNAPSHOT_RE.test(i.name)).length;
      return reply({ ok: true, message: `连接成功：${t.remoteDir} 下已有 ${n} 个备份` });
    } catch (e) {
      return reply({ ok: false, message: e.message || String(e) });
    }
  }

  async function list(req, res) {
    const c = config();
    if (!c.webdav.url) return sendJson(res, 200, { items: [] });
    let entries;
    try {
      entries = await makeClient(c).propfind(c.webdav.remoteDir, 1);
    } catch (e) {
      // A directory that was never created is simply an empty backup list.
      if (e instanceof WebDavError && e.status === 404) return sendJson(res, 200, { items: [] });
      throw toHttp(e);
    }
    const items = entries
      .filter((i) => !i.isDir && SNAPSHOT_RE.test(i.name))
      .map((i) => ({ name: i.name, bytes: i.size, modifiedAt: i.modifiedAt, encrypted: i.name.endsWith('.enc') }))
      .sort((a, b) => (a.name < b.name ? 1 : a.name > b.name ? -1 : 0));
    sendJson(res, 200, { items });
  }

  // ------------------------------------------------------------------ snapshot

  /**
   * Monotonic within the process: two runs inside the same second must not
   * produce the same name, or the second would silently overwrite the first.
   */
  function nextStamp() {
    let d = new Date();
    let s = stampOf(d);
    while (s <= lastStamp) {
      d = new Date(d.getTime() + 1000);
      s = stampOf(d);
    }
    lastStamp = s;
    return s;
  }

  function schemaVersion() {
    const row = db.get('SELECT MAX(version) AS v FROM schema_migrations');
    return row && row.v != null ? Number(row.v) : 0;
  }

  /** A consistent gzipped copy of the live database. */
  function snapshotBytes() {
    const tmp = path.join(db.dataDir, `.snapshot-${process.pid}-${crypto.randomBytes(4).toString('hex')}.db`);
    try {
      fs.rmSync(tmp, { force: true });
      // VACUUM INTO takes no parameters — quote the path the SQL way.
      db.exec(`VACUUM INTO '${tmp.replace(/'/g, "''")}'`);
      return zlib.gzipSync(fs.readFileSync(tmp), { level: 9 });
    } finally {
      fs.rmSync(tmp, { force: true });
      fs.rmSync(`${tmp}-wal`, { force: true });
      fs.rmSync(`${tmp}-shm`, { force: true });
    }
  }

  /** `FLBK1 | salt16 | nonce12 | ciphertext | tag16` */
  function seal(plain, passphrase) {
    const salt = crypto.randomBytes(16);
    const nonce = crypto.randomBytes(12);
    const key = crypto.scryptSync(passphrase, salt, 32, SCRYPT);
    const c = crypto.createCipheriv('aes-256-gcm', key, nonce);
    const ct = Buffer.concat([c.update(plain), c.final()]);
    return Buffer.concat([MAGIC, salt, nonce, ct, c.getAuthTag()]);
  }

  const isSealed = (buf) => buf.length > HEADER_LEN + TAG_LEN && buf.subarray(0, MAGIC.length).equals(MAGIC);

  function unseal(buf, passphrase) {
    const salt = buf.subarray(MAGIC.length, MAGIC.length + 16);
    const nonce = buf.subarray(MAGIC.length + 16, HEADER_LEN);
    const ct = buf.subarray(HEADER_LEN, buf.length - TAG_LEN);
    const key = crypto.scryptSync(passphrase, salt, 32, SCRYPT);
    const d = crypto.createDecipheriv('aes-256-gcm', key, nonce);
    d.setAuthTag(buf.subarray(buf.length - TAG_LEN));
    try {
      return Buffer.concat([d.update(ct), d.final()]);
    } catch {
      throw new HttpError(400, 'decrypt_failed', '密语不对，或备份文件已损坏');
    }
  }

  // ------------------------------------------------------------------ run

  /** Drop everything past the newest `keep` snapshots, manifests included. */
  async function prune(client, dir, keep) {
    const entries = await client.propfind(dir, 1);
    const snaps = entries
      .filter((i) => !i.isDir && SNAPSHOT_RE.test(i.name))
      .map((i) => i.name)
      .sort(); // fixed-width stamps → lexicographic is chronological
    const drop = snaps.slice(0, Math.max(0, snaps.length - keep));
    for (const name of drop) {
      await client.delete(`${dir}/${name}`);
      await client.delete(`${dir}/${name}.json`); // 404 is fine: nothing to clean
    }
    return drop.length;
  }

  /**
   * A row still marked in-progress that cannot possibly be in progress — the
   * process died mid-backup, or the snapshot we just restored was taken while
   * a backup was running and therefore contains its own unfinished row. Left
   * alone it would show as "备份进行中" forever.
   */
  function reapStaleRuns(why) {
    const r = db.run('UPDATE backup_runs SET ok = 0, finished_at = ?, message = ? WHERE ok IS NULL', db.now(), why);
    if (r.changes) log.info('backup', `${r.changes} 条未完成的备份记录被标记为中断：${why}`);
  }

  function trimHistory() {
    db.run(
      'DELETE FROM backup_runs WHERE id NOT IN (SELECT id FROM backup_runs ORDER BY started_at DESC, rowid DESC LIMIT ?)',
      HISTORY_KEEP,
    );
  }

  /**
   * One backup, start to finish. Always leaves a `backup_runs` row behind.
   * @param {'manual'|'schedule'} trigger
   * @returns {Promise<{name:string, bytes:number, tookMs:number}>}
   */
  async function runBackup(trigger = 'manual') {
    // Taken synchronously, before the first await: two overlapping requests can
    // never both get past this line.
    acquire('backup');

    const t0 = Date.now();
    const label = trigger === 'schedule' ? '定时备份' : '手动备份';
    const id = crypto.randomUUID();
    let name = null;

    try {
      // Inside the try: if even this INSERT fails (disk full is the realistic
      // case) the `finally` below must still release `busy`, or every later
      // backup and restore would answer 409 until the process restarts.
      db.run('INSERT INTO backup_runs(id, started_at, ok) VALUES(?, ?, NULL)', id, db.now());
      const c = config();
      if (!c.webdav.url) throw new HttpError(400, 'webdav_not_configured', '还没有配置 WebDAV 地址');
      let passphrase = null;
      if (c.encryption.enabled) {
        passphrase = reveal(c.encryption.passphraseEnc);
        if (!passphrase) throw new HttpError(400, 'passphrase_required', '已开启备份加密，但密语不可用，请重新设置');
      }

      const client = makeClient(c);
      const gz = snapshotBytes();
      const payload = passphrase ? seal(gz, passphrase) : gz;
      name = `famledger-${nextStamp()}.db.gz${passphrase ? '.enc' : ''}`;
      const manifest = {
        app: 'famledger',
        formatVersion: 1,
        createdAt: new Date().toISOString(),
        bytes: payload.length,
        sha256: sha256hex(payload),
        encrypted: !!passphrase,
        schemaVersion: schemaVersion(),
        household: db.meta('household_name', '') || '',
      };

      const dir = c.webdav.remoteDir;
      await client.mkcolp(dir);
      await client.put(`${dir}/${name}`, payload, 'application/gzip');
      await client.put(`${dir}/${name}.json`, Buffer.from(JSON.stringify(manifest, null, 2), 'utf8'), 'application/json');

      // Retention must never turn a good backup into a failed run: the copy is
      // already safely uploaded by here.
      let note = '';
      try {
        const dropped = await prune(client, dir, c.schedule.keep);
        if (dropped) note = `，清理 ${dropped} 个旧备份`;
      } catch (e) {
        note = `，清理旧备份失败：${e.message}`;
        log.warn('backup', `retention failed: ${e.message}`);
      }

      db.run(
        'UPDATE backup_runs SET finished_at = ?, ok = 1, name = ?, bytes = ?, message = ? WHERE id = ?',
        db.now(), name, payload.length, `${label}成功${note}`, id,
      );
      db.setMeta(LAST_DAY_KEY, dayOf(new Date()));
      trimHistory();
      log.info('backup', `${label} ok name=${name} bytes=${payload.length} took=${Date.now() - t0}ms`);
      return { name, bytes: payload.length, tookMs: Date.now() - t0 };
    } catch (e) {
      const http = toHttp(e);
      try {
        db.run(
          'UPDATE backup_runs SET finished_at = ?, ok = 0, name = ?, message = ? WHERE id = ?',
          db.now(), name, `${label}失败：${http.message}`, id,
        );
        trimHistory();
      } catch (inner) {
        log.error('backup', `could not record the failed run: ${inner.message}`);
      }
      log.warn('backup', `${label} failed: ${http.message}`);
      throw http;
    } finally {
      busy = null;
    }
  }

  async function run(req, res) {
    sendJson(res, 200, await runBackup('manual'));
  }

  function status(req, res) {
    const rows = db.all('SELECT * FROM backup_runs ORDER BY started_at DESC, rowid DESC LIMIT ?', HISTORY_PAGE);
    sendJson(res, 200, {
      lastRun: runJson(rows[0] || null),
      nextRun: nextRunAt(),
      running: busy === 'backup',
      busy,
      history: rows.map(runJson),
    });
  }

  // ------------------------------------------------------------------ restore

  /** Refuses anything that is not one of our own snapshot names. */
  function snapshotName(value) {
    const s = typeof value === 'string' ? value.trim() : '';
    if (!SNAPSHOT_RE.test(s)) v.bad('name', '备份文件名不合法');
    return s;
  }

  /**
   * Verify → decrypt → gunzip → integrity-check → swap the live file.
   * @returns {{preRestoreCopy:string, bytes:number}}
   */
  function applySnapshot(payload, { manifest = null, passphrase = null } = {}) {
    if (manifest && typeof manifest.sha256 === 'string' && manifest.sha256 !== sha256hex(payload)) {
      throw new HttpError(400, 'checksum_mismatch', '备份文件和 manifest 的 sha256 对不上，文件可能损坏');
    }

    let gz = payload;
    if (isSealed(payload)) {
      if (!passphrase) throw new HttpError(400, 'passphrase_required', '这是加密备份，请先在备份设置里填写密语');
      gz = unseal(payload, passphrase);
    }

    let raw;
    try {
      raw = zlib.gunzipSync(gz);
    } catch {
      throw new HttpError(400, 'bad_snapshot', '备份文件不是 gzip 格式');
    }

    const stamp = nextStamp();
    const candidate = path.join(db.dataDir, `.restore-${stamp}.db`);
    fs.writeFileSync(candidate, raw, { mode: 0o600 });

    let out;
    try {
      // Every way this can go wrong — and what it must and must not overwrite
      // on the way out — lives in lib/db_swap.js.
      out = swapDatabase({ db, dataDir: db.dataDir, candidatePath: candidate, stamp, log });
    } catch (e) {
      fs.rmSync(candidate, { force: true });
      if (e instanceof DbSwapError) {
        if (e.code === 'bad_snapshot') throw new HttpError(400, 'bad_snapshot', e.message);
        throw new HttpError(500, 'restore_failed', e.message);
      }
      throw e;
    }
    reapStaleRuns('中断：数据库已被恢复覆盖');
    return { preRestoreCopy: out.preRestoreCopy, bytes: raw.length };
  }

  async function restore(req, res, reqCtx) {
    const b = v.body(reqCtx.body);
    const name = snapshotName(b.name);
    const c = config();
    if (!c.webdav.url) throw new HttpError(400, 'webdav_not_configured', '还没有配置 WebDAV 地址');
    // Held across the download too: a backup that starts while we are fetching
    // would still be running when we close the database underneath it.
    acquire('restore');
    try {
      const client = makeClient(c);
      const dir = c.webdav.remoteDir;

      let payload;
      try {
        payload = await client.get(`${dir}/${name}`);
      } catch (e) {
        if (e instanceof WebDavError && e.status === 404) throw new HttpError(404, 'not_found', '远端没有这个备份文件');
        throw toHttp(e);
      }

      let manifest = null;
      try {
        const parsed = JSON.parse((await client.get(`${dir}/${name}.json`)).toString('utf8'));
        if (v.isObject(parsed)) manifest = parsed;
      } catch {
        // Snapshots uploaded by hand may have no manifest; the integrity check
        // downstream is what actually protects the database.
        log.warn('backup', `${name} 没有可用的 manifest，跳过 sha256 校验`);
      }

      const out = applySnapshot(payload, { manifest, passphrase: reveal(c.encryption.passphraseEnc) });
      log.info('backup', `restored from ${name} (${out.bytes} bytes), previous database kept as ${out.preRestoreCopy}`);
      sendJson(res, 200, { ok: true, restoredFrom: name, preRestoreCopy: out.preRestoreCopy });
    } finally {
      busy = null;
    }
  }

  /** Raw `.db.gz` / `.db.gz.enc` upload — the same pipeline, different source. */
  async function importSnapshot(req, res) {
    acquire('import');
    try {
      const payload = await readBody(req, MAX_IMPORT);
      if (!payload || payload.length === 0) throw new HttpError(400, 'empty_body', '没有收到备份内容');
      const c = config();
      const out = applySnapshot(payload, { passphrase: reveal(c.encryption.passphraseEnc) });
      log.info('backup', `restored from an uploaded snapshot (${out.bytes} bytes), previous database kept as ${out.preRestoreCopy}`);
      sendJson(res, 200, { ok: true, restoredFrom: 'upload', bytes: payload.length, preRestoreCopy: out.preRestoreCopy });
    } finally {
      busy = null;
    }
  }

  function exportSnapshot(req, res) {
    const gz = snapshotBytes();
    const name = `famledger-${nextStamp()}.db.gz`;
    res.writeHead(200, {
      'content-type': 'application/gzip',
      'content-length': gz.length,
      'content-disposition': `attachment; filename="${name}"`,
      'cache-control': 'no-store',
    });
    res.end(gz);
  }

  // ------------------------------------------------------------------ schedule

  /** Once a minute: ask shouldRunNow, and record the attempt if it says yes. */
  function tick() {
    try {
      if (busy) return;
      const c = config();
      const now = new Date();
      const m = scheduleMeta();
      const decision = shouldRunNow(now, c, m);
      if (!decision.run) return;

      const day = dayOf(now);
      const attempt = (m.attemptDay === day ? m.attempts : 0) + 1;
      // Record the attempt before making it, so a crash mid-backup still counts
      // against the retry budget instead of looping every minute.
      db.setMeta(LAST_ATTEMPT_KEY, now.toISOString());
      db.setMeta(ATTEMPTS_KEY, `${day}:${attempt}`);
      // The last shot settles the day up front: whatever happens, no more today.
      if (attempt >= MAX_ATTEMPTS) db.setMeta(LAST_DAY_KEY, day);
      log.info('backup', `定时备份触发（${decision.reason}，第 ${attempt}/${MAX_ATTEMPTS} 次）`);
      runBackup('schedule').catch(() => {
        /* runBackup already logged it and wrote the failed run row; the next
           tick will retry after the back-off, or give up for today */
      });
    } catch (e) {
      // The scheduler outlives every individual failure.
      log.error('backup', `scheduler tick failed: ${e.stack || e}`);
    }
  }

  return {
    name: 'backup',
    routes: [
      { method: 'GET', pattern: '/backup/config', handler: getConfig, auth: 'admin', maxBody: 0 },
      { method: 'PUT', pattern: '/backup/config', handler: putConfig, auth: 'admin' },
      { method: 'POST', pattern: '/backup/test', handler: testConnection, auth: 'admin' },
      { method: 'POST', pattern: '/backup/run', handler: run, auth: 'admin' },
      { method: 'GET', pattern: '/backup/list', handler: list, auth: 'admin', maxBody: 0 },
      { method: 'GET', pattern: '/backup/status', handler: status, auth: 'admin', maxBody: 0 },
      { method: 'POST', pattern: '/backup/restore', handler: restore, auth: 'admin' },
      { method: 'GET', pattern: '/backup/export', handler: exportSnapshot, auth: 'admin', maxBody: 0 },
      { method: 'POST', pattern: '/backup/import', handler: importSnapshot, auth: 'admin', maxBody: 0 },
    ],
    start() {
      reapStaleRuns('中断：服务重启');
      const ms = Number(process.env.BACKUP_TICK_MS) > 0 ? Number(process.env.BACKUP_TICK_MS) : DEFAULT_TICK_MS;
      timer = setInterval(tick, ms);
      timer.unref();
    },
    stop() {
      if (timer) clearInterval(timer);
      timer = null;
    },
    // Exposed for tests and for any future module that wants a snapshot.
    runBackup,
    shouldRunNow,
    nextRunFrom,
  };
};

// Pure, dependency-free, and unit-tested directly (see test/backup.test.js).
module.exports.shouldRunNow = shouldRunNow;
module.exports.nextRunFrom = nextRunFrom;
module.exports.MAX_ATTEMPTS = MAX_ATTEMPTS;
module.exports.RETRY_BACKOFF_MS = RETRY_BACKOFF_MS;
