'use strict';

// The one SQLite handle the process owns. `openDb` creates the data dir,
// opens the file in WAL mode, applies `src/sql/NNN_*.sql` migrations that have
// not run yet, and hands back a small facade:
//
//   db.db          the live DatabaseSync (a getter — survives reopen())
//   db.get/all/run/exec   prepared-statement passthroughs, statements cached
//   db.tx(fn)      BEGIN IMMEDIATE … COMMIT, re-entrant
//   db.nextSeq()   the next global change sequence number
//   db.now()       ISO-8601 timestamp
//   db.meta/setMeta   the key/value table
//   db.close()/db.reopen()   used by backup restore, which swaps the file
//
// Everything is synchronous: node:sqlite has no async API, and for a
// single-household ledger the whole database fits in page cache anyway.

const fs = require('node:fs');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');

const DB_FILE = 'famledger.db';

function openDb(dataDir, opts = {}) {
  const dir = path.resolve(dataDir);
  const file = path.join(dir, opts.file || DB_FILE);
  const sqlDir = opts.sqlDir || path.join(__dirname, '..', 'sql');
  fs.mkdirSync(dir, { recursive: true });

  /** @type {DatabaseSync|null} */
  let conn = null;
  /** @type {Map<string, object>} */
  let cache = new Map();
  let depth = 0;

  function connect() {
    conn = new DatabaseSync(file);
    conn.exec('PRAGMA journal_mode = WAL');
    conn.exec('PRAGMA foreign_keys = ON');
    conn.exec('PRAGMA busy_timeout = 5000');
    conn.exec('PRAGMA synchronous = NORMAL');
    cache = new Map();
    migrate();
  }

  function migrate() {
    const bootstrapped = conn
      .prepare("SELECT 1 AS ok FROM sqlite_master WHERE type='table' AND name='schema_migrations'")
      .get();
    const applied = new Set(
      bootstrapped ? conn.prepare('SELECT version FROM schema_migrations').all().map((r) => Number(r.version)) : [],
    );
    const files = fs
      .readdirSync(sqlDir)
      .filter((f) => /^\d+_.+\.sql$/.test(f))
      .sort();
    for (const f of files) {
      const version = Number(f.split('_')[0]);
      if (applied.has(version)) continue;
      const sql = fs.readFileSync(path.join(sqlDir, f), 'utf8');
      conn.exec('BEGIN IMMEDIATE');
      try {
        conn.exec(sql);
        conn.prepare('INSERT INTO schema_migrations(version, applied_at) VALUES(?, ?)').run(version, new Date().toISOString());
        conn.exec('COMMIT');
      } catch (e) {
        try {
          conn.exec('ROLLBACK');
        } catch {
          /* the failing statement may already have aborted the tx */
        }
        throw new Error(`migration ${f} failed: ${e.message}`);
      }
    }
  }

  const handle = {
    get db() {
      return conn;
    },
    get file() {
      return file;
    },
    get dataDir() {
      return dir;
    },

    prepare(sql) {
      let s = cache.get(sql);
      if (!s) {
        s = conn.prepare(sql);
        cache.set(sql, s);
      }
      return s;
    },
    run(sql, ...args) {
      return handle.prepare(sql).run(...args);
    },
    get(sql, ...args) {
      return handle.prepare(sql).get(...args) ?? null;
    },
    all(sql, ...args) {
      return handle.prepare(sql).all(...args);
    },
    exec(sql) {
      return conn.exec(sql);
    },

    /**
     * Run `fn` inside a write transaction. Nested calls join the outer one, so
     * a helper like seedDefaults() can be safe on its own and still compose.
     */
    tx(fn) {
      if (depth > 0) {
        depth++;
        try {
          return fn();
        } finally {
          depth--;
        }
      }
      conn.exec('BEGIN IMMEDIATE');
      depth = 1;
      try {
        const out = fn();
        conn.exec('COMMIT');
        return out;
      } catch (e) {
        try {
          conn.exec('ROLLBACK');
        } catch {
          /* already rolled back */
        }
        throw e;
      } finally {
        depth = 0;
      }
    },

    /** Monotonic change counter stamped onto every syncable row. */
    nextSeq() {
      const row = handle
        .prepare("UPDATE meta SET value = CAST(value AS INTEGER) + 1 WHERE key = 'change_seq' RETURNING value")
        .get();
      if (!row) throw new Error('meta.change_seq is missing — database not initialised');
      return Number(row.value);
    },

    now() {
      return new Date().toISOString();
    },

    meta(key, fallback = null) {
      const row = handle.get('SELECT value FROM meta WHERE key = ?', key);
      return row ? row.value : fallback;
    },
    setMeta(key, value) {
      handle.run(
        'INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        key,
        String(value),
      );
      return value;
    },

    close() {
      if (!conn) return;
      cache = new Map();
      conn.close();
      conn = null;
    },
    /** Close and re-open the same path — backup restore swaps the file underneath. */
    reopen() {
      handle.close();
      connect();
      return handle;
    },
  };

  connect();
  return handle;
}

const camel = (s) => s.replace(/_([a-z0-9])/g, (_, c) => c.toUpperCase());

/**
 * snake_case DB row → camelCase API object.
 * @param {object|null} row
 * @param {{omit?:string[], bools?:string[], json?:string[]}} [opts]
 *   omit  columns to drop entirely (e.g. password_hash)
 *   bools INTEGER 0/1 columns to surface as true/false
 *   json  TEXT columns holding JSON to parse (tags, match_hints, extra)
 */
function rowToJson(row, { omit = [], bools = [], json = [] } = {}) {
  if (!row) return null;
  const out = {};
  for (const [k, v] of Object.entries(row)) {
    if (omit.includes(k)) continue;
    if (bools.includes(k)) out[camel(k)] = !!v;
    else if (json.includes(k)) {
      try {
        out[camel(k)] = JSON.parse(v ?? 'null');
      } catch {
        out[camel(k)] = null;
      }
    } else out[camel(k)] = v === undefined ? null : v;
  }
  return out;
}

module.exports = { openDb, rowToJson, camel, DB_FILE };
