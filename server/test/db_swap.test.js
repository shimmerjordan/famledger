'use strict';

// Fault injection around the one operation in famledger that can destroy a
// ledger: replacing the live database file. Real SQLite files in a real temp
// directory, a fake db handle so close()/reopen() can be made to fail, and an
// `fs` proxy that breaks exactly one call.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');

const { swapDatabase, assertUsableDatabase, DbSwapError } = require('../src/lib/db_swap');

/** A minimal SQLite file that `assertUsableDatabase` accepts, tagged with `tag`. */
function makeDb(file, tag) {
  const d = new DatabaseSync(file);
  d.exec('CREATE TABLE schema_migrations(version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)');
  d.exec("INSERT INTO schema_migrations VALUES(1, '2026-01-01')");
  d.exec('CREATE TABLE marker(tag TEXT NOT NULL)');
  d.prepare('INSERT INTO marker(tag) VALUES(?)').run(tag);
  d.close();
  return file;
}

/** Which database is this file? */
function tagOf(file) {
  const d = new DatabaseSync(file, { readOnly: true });
  try {
    return d.prepare('SELECT tag FROM marker').get().tag;
  } finally {
    d.close();
  }
}

/** The bits of lib/db.js's facade that swapDatabase touches. */
function fakeHandle(file, hooks = {}) {
  return {
    file,
    closed: 0,
    reopened: 0,
    close() {
      this.closed++;
      hooks.onClose?.(this);
    },
    reopen() {
      this.reopened++;
      hooks.onReopen?.(this);
    },
  };
}

function fixture(t, tag = 'live') {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'swap-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const target = makeDb(path.join(dir, 'famledger.db'), tag);
  const candidate = makeDb(path.join(dir, '.restore-20260913-030000.db'), 'snapshot');
  return { dir, target, candidate, size: fs.statSync(target).size };
}

/** node:fs with some calls replaced. */
const brokenFs = (over) => ({ ...fs, ...over });

/** Run `fn` and hand back what it threw (assert.throws returns nothing). */
function grab(fn) {
  try {
    fn();
  } catch (e) {
    return e;
  }
  assert.fail('expected this to throw');
}

// ---------------------------------------------------------------- happy path

test('换库成功：目标变成候选文件，留底副本是原来的库', async (t) => {
  const { dir, target, candidate } = fixture(t);
  const db = fakeHandle(target);

  const out = swapDatabase({ db, dataDir: dir, candidatePath: candidate, stamp: '20260913-030000' });

  assert.equal(out.preRestoreCopy, 'pre-restore-20260913-030000.db');
  assert.equal(tagOf(target), 'snapshot', 'live 文件应该已经是候选库');
  assert.equal(tagOf(path.join(dir, out.preRestoreCopy)), 'live', '留底副本应该是换之前的库');
  assert.ok(!fs.existsSync(candidate), '候选文件已被 rename 走');
  assert.equal(db.closed, 1);
  assert.equal(db.reopened, 1);
});

test('候选文件不是数据库 / 不是 famledger 的库 → bad_snapshot，一个字节都不动', async (t) => {
  const { dir, target } = fixture(t);
  const junk = path.join(dir, 'junk.db');
  fs.writeFileSync(junk, 'definitely not sqlite');
  const foreign = path.join(dir, 'foreign.db');
  const d = new DatabaseSync(foreign);
  d.exec('CREATE TABLE whatever(a)');
  d.close();

  for (const bad of [junk, foreign]) {
    const db = fakeHandle(target);
    assert.throws(
      () => swapDatabase({ db, dataDir: dir, candidatePath: bad, stamp: '20260913-030000' }),
      (e) => e instanceof DbSwapError && e.code === 'bad_snapshot',
    );
    assert.equal(db.closed, 0, '连库都没关');
    assert.equal(tagOf(target), 'live');
  }
  assert.ok(!fs.existsSync(path.join(dir, 'pre-restore-20260913-030000.db')), '没换就不该留副本');
});

// ---------------------------------------------------------------- (a) copy 失败

test('(a) 留底副本写不下（copyFileSync 抛错）→ 现役库原封不动并重新打开', async (t) => {
  const { dir, target, candidate, size } = fixture(t);
  const db = fakeHandle(target);

  const e = grab(() =>
    swapDatabase({
      db,
      dataDir: dir,
      candidatePath: candidate,
      stamp: '20260913-030000',
      fs: brokenFs({
        copyFileSync: () => {
          const err = new Error('ENOSPC: no space left on device');
          err.code = 'ENOSPC';
          throw err;
        },
      }),
    }),
  );
  assert.ok(e instanceof DbSwapError);
  assert.equal(e.code, 'restore_failed');
  assert.equal(e.rolledBack, false, '没换过就谈不上回滚');
  assert.equal(tagOf(target), 'live', '现役库必须原封不动');
  assert.equal(fs.statSync(target).size, size);
  assert.equal(db.reopened, 1, '失败路径也必须把库重新打开');
});

test('(a2) 留底副本被截断（copy 成功但只写了一半）→ 放弃恢复，绝不用残副本覆盖现役库', async (t) => {
  const { dir, target, candidate, size } = fixture(t);
  const db = fakeHandle(target);

  const e = grab(() =>
    swapDatabase({
      db,
      dataDir: dir,
      candidatePath: candidate,
      stamp: '20260913-030000',
      // ENOSPC 的真实形态：文件建出来了，内容只写了一部分，调用本身不报错。
      fs: brokenFs({
        copyFileSync: (src, dest) => fs.writeFileSync(dest, fs.readFileSync(src).subarray(0, 512)),
      }),
    }),
  );
  assert.equal(e.code, 'pre_restore_incomplete');
  assert.equal(e.rolledBack, false);
  assert.match(e.message, /没有被改动/);
  assert.equal(tagOf(target), 'live', '现役库必须原封不动');
  assert.equal(fs.statSync(target).size, size);
  assert.ok(!fs.existsSync(path.join(dir, 'pre-restore-20260913-030000.db')), '残缺的留底副本要清掉，不能留着骗人');
  assert.equal(db.reopened, 1);
});

// ---------------------------------------------------------------- (b) rename 失败

test('(b) rename 失败 → 现役库原封不动并重新打开', async (t) => {
  const { dir, target, candidate, size } = fixture(t);
  const db = fakeHandle(target);

  const e = grab(() =>
    swapDatabase({
      db,
      dataDir: dir,
      candidatePath: candidate,
      stamp: '20260913-030000',
      fs: brokenFs({
        renameSync: () => {
          throw new Error('EXDEV: cross-device link not permitted');
        },
      }),
    }),
  );
  assert.equal(e.code, 'restore_failed');
  assert.equal(e.rolledBack, false);
  assert.equal(tagOf(target), 'live', '现役库必须原封不动');
  assert.equal(fs.statSync(target).size, size);
  assert.equal(db.reopened, 1);
});

// ---------------------------------------------------------------- (c) reopen 失败

test('(c) 换完之后 reopen 失败 → 用留底副本回滚，并再开一次', async (t) => {
  const { dir, target, candidate } = fixture(t);
  let firstReopen = true;
  const db = fakeHandle(target, {
    onReopen: () => {
      if (firstReopen) {
        firstReopen = false;
        throw new Error('migration 009 failed: unknown column');
      }
    },
  });

  const e = grab(() => swapDatabase({ db, dataDir: dir, candidatePath: candidate, stamp: '20260913-030000' }));
  assert.equal(e.code, 'restore_failed');
  assert.equal(e.rolledBack, true, '换过了，就必须回滚');
  assert.equal(tagOf(target), 'live', '现役库要被留底副本还原');
  assert.equal(db.reopened, 2, '失败一次 + 回滚后再开一次');
  assert.equal(tagOf(path.join(dir, 'pre-restore-20260913-030000.db')), 'live', '留底副本留着，别删');
});

test('(c2) 回滚也失败时不抛二次异常，只是如实标记 rolledBack=false', async (t) => {
  const { dir, target, candidate } = fixture(t);
  const db = fakeHandle(target, {
    onReopen: () => {
      throw new Error('boom');
    },
  });

  const e = grab(() =>
    swapDatabase({
      db,
      dataDir: dir,
      candidatePath: candidate,
      stamp: '20260913-030000',
      fs: brokenFs({
        copyFileSync: (src, dest) => {
          if (src === target) return fs.copyFileSync(src, dest); // 留底副本照常
          throw new Error('EIO'); // 回滚时的那次 copy 失败
        },
      }),
    }),
  );
  assert.equal(e.code, 'restore_failed');
  assert.equal(e.rolledBack, false);
  assert.equal(db.reopened, 2, 'reopen 失败也要再试一次，绝不留着关掉的句柄');
});

// ---------------------------------------------------------------- 校验器

test('assertUsableDatabase 认可正常库，拒绝空文件与外来库', async (t) => {
  const { dir, target } = fixture(t);
  assertUsableDatabase(target); // 不抛

  const empty = path.join(dir, 'empty.db');
  fs.writeFileSync(empty, '');
  assert.throws(() => assertUsableDatabase(empty), (e) => e.code === 'bad_snapshot');
  assert.throws(() => assertUsableDatabase(path.join(dir, 'nope.db')), (e) => e.code === 'bad_snapshot');
});
