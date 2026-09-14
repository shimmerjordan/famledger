'use strict';

// Replacing the database file the process is serving from, without restarting.
//
//   swapDatabase({db, dataDir, candidatePath})
//     → integrity-check the candidate
//     → db.close()  (WAL is checkpointed away, so the file is self-contained)
//     → copy the live file to `pre-restore-<stamp>.db` and verify its size
//     → rename the candidate over the live file
//     → db.reopen()   (migrations re-run against whatever just landed)
//
// The whole point of this file is the failure paths, so they are spelled out:
//
//   * The live file is only ever overwritten from the pre-restore copy when the
//     swap **actually happened**. Before the rename the live file is still the
//     healthy original, and the copy is the suspect one — a copy that failed
//     half-way (ENOSPC is the realistic one: a restore writes both the
//     candidate and the pre-restore copy into the same directory) is truncated
//     but present, and copying it back would be the only thing in this file
//     capable of destroying a working ledger.
//   * The copy is size-checked against the live file before anything relies on
//     it. A short copy aborts the restore instead of becoming the rollback.
//   * `db.reopen()` runs on every path out, success or failure, so the process
//     is never left holding a closed handle.
//
// `fs` and `now` are injectable so the failure paths can be tested with real
// files and a fault-injecting fs (see test/db_swap.test.js).

const nodeFs = require('node:fs');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');

class DbSwapError extends Error {
  /**
   * @param {'bad_snapshot'|'pre_restore_incomplete'|'restore_failed'} code
   * @param {boolean} [rolledBack] the live database was put back from the copy
   */
  constructor(code, message, { rolledBack = false } = {}) {
    super(message);
    this.name = 'DbSwapError';
    this.code = code;
    this.rolledBack = rolledBack;
  }
}

const pad = (n, w = 2) => String(n).padStart(w, '0');
const stampOf = (d) =>
  `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;

/**
 * A candidate file only gets to replace a live database if SQLite itself
 * vouches for it and it looks like one of ours.
 * @param {string} file
 */
function assertUsableDatabase(file) {
  let probe = null;
  try {
    probe = new DatabaseSync(file, { readOnly: true });
    const row = probe.prepare('PRAGMA integrity_check').get();
    const verdict = row ? String(Object.values(row)[0] ?? '').toLowerCase() : '';
    if (verdict !== 'ok') throw new DbSwapError('bad_snapshot', `备份文件校验不通过：${verdict || '未知'}`);
    if (!probe.prepare("SELECT 1 AS ok FROM sqlite_master WHERE type='table' AND name='schema_migrations'").get()) {
      throw new DbSwapError('bad_snapshot', '这不是 famledger 的备份文件');
    }
  } catch (e) {
    if (e instanceof DbSwapError) throw e;
    throw new DbSwapError('bad_snapshot', `备份文件不是可用的 SQLite 数据库：${e.message}`);
  } finally {
    try {
      probe?.close();
    } catch {
      /* closing a handle we are throwing away cannot make things worse */
    }
  }
}

/**
 * @param {{db: {file:string, close:Function, reopen:Function},
 *          dataDir: string,
 *          candidatePath: string,
 *          fs?: typeof import('node:fs'),
 *          now?: () => Date,
 *          stamp?: string|null,
 *          log?: {info?:Function, warn?:Function, error?:Function}|null}} opts
 * @returns {{preRestoreCopy: string, bytes: number}} the copy's *basename*
 * @throws {DbSwapError}
 */
function swapDatabase({ db, dataDir, candidatePath, fs = nodeFs, now = () => new Date(), stamp = null, log = null }) {
  const note = (level, msg) => {
    try {
      log?.[level]?.('db_swap', msg);
    } catch {
      /* logging must never be the reason a restore fails */
    }
  };

  const target = db.file;
  const bytes = fs.statSync(candidatePath).size;
  assertUsableDatabase(candidatePath);

  const copyName = `pre-restore-${stamp || stampOf(now())}.db`;
  const copy = path.join(dataDir, copyName);

  // Flipped only once the live file has really been replaced. Everything the
  // catch block does hangs off this flag.
  let swapped = false;
  try {
    db.close();
    fs.copyFileSync(target, copy);
    const copied = fs.statSync(copy).size;
    const live = fs.statSync(target).size;
    if (copied !== live) {
      throw new DbSwapError(
        'pre_restore_incomplete',
        `留底副本只写了 ${copied}/${live} 字节（磁盘空间不够？），已放弃恢复，当前数据库没有被改动`,
      );
    }
    // Stale WAL/SHM belong to the database being replaced; left behind they
    // would be applied on top of the restored file.
    fs.rmSync(`${target}-wal`, { force: true });
    fs.rmSync(`${target}-shm`, { force: true });
    fs.renameSync(candidatePath, target);
    swapped = true;
    db.reopen();
    return { preRestoreCopy: copyName, bytes };
  } catch (e) {
    let rolledBack = false;
    if (swapped) {
      // The live file really is the restored one now, so the copy is the only
      // way back to what the household had.
      try {
        fs.copyFileSync(copy, target);
        fs.rmSync(`${target}-wal`, { force: true });
        fs.rmSync(`${target}-shm`, { force: true });
        rolledBack = true;
      } catch (inner) {
        note('error', `回滚失败，数据库仍是恢复进来的文件：${inner.message}`);
      }
    } else {
      // Nothing was replaced: the live file is untouched and healthy, and the
      // copy may be truncated. Writing it back is exactly the bug we refuse to
      // have; drop the useless copy instead.
      try {
        fs.rmSync(copy, { force: true });
      } catch (inner) {
        note('warn', `清理未完成的留底副本失败：${inner.message}`);
      }
    }
    try {
      db.reopen();
    } catch (inner) {
      note('error', `重开数据库失败：${inner.message}`);
    }
    try {
      fs.rmSync(candidatePath, { force: true });
    } catch {
      /* a leftover .restore-* file is cosmetic */
    }
    if (e instanceof DbSwapError) {
      e.rolledBack = rolledBack;
      throw e;
    }
    throw new DbSwapError('restore_failed', `恢复失败：${e.message}`, { rolledBack });
  }
}

module.exports = { swapDatabase, assertUsableDatabase, DbSwapError, stampOf };
