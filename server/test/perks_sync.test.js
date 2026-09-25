'use strict';

// 会员权益四张表的迁移与同步登记（006）：旧库重开补表、/changes 带上四个桶。
// 各表的 CRUD、墓碑、备份在 platforms / memberships / benefits 各自的测试里。

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const { household } = require('./fixtures');
const { tmpDir } = require('./helpers');
const { SYNCED } = require('../src/modules/changes');

const PERK_TABLES = ['platforms', 'memberships', 'benefits', 'benefit_events'];

test('旧库（001–005）重开：补上四张表和它们的索引 —— 恢复旧备份走的就是这条路', () => {
  const { openDb } = require('../src/lib/db');
  const dir = tmpDir('perks-migrate');
  const oldSql = tmpDir('perks-sql');
  const sqlDir = path.join(__dirname, '..', 'src', 'sql');
  for (const f of fs.readdirSync(sqlDir).filter((x) => /^00[1-5]_.+\.sql$/.test(x))) {
    fs.copyFileSync(path.join(sqlDir, f), path.join(oldSql, f));
  }
  const old = openDb(dir, { sqlDir: oldSql });
  for (const t of PERK_TABLES) {
    assert.equal(old.get("SELECT 1 AS ok FROM sqlite_master WHERE type='table' AND name=?", t), null);
  }
  old.close();

  const db = openDb(dir);
  try {
    assert.ok(db.get('SELECT 1 AS ok FROM schema_migrations WHERE version = 6'));
    for (const t of PERK_TABLES) {
      assert.ok(db.get("SELECT 1 AS ok FROM sqlite_master WHERE type='table' AND name=?", t), `${t} 表`);
      assert.ok(db.get("SELECT 1 AS ok FROM sqlite_master WHERE type='index' AND name=?", `idx_${t}_seq`), `idx_${t}_seq`);
    }
    for (const idx of ['idx_memberships_platform', 'idx_benefits_membership', 'idx_benefits_claim_platform', 'idx_benefit_events_benefit']) {
      assert.ok(db.get("SELECT 1 AS ok FROM sqlite_master WHERE type='index' AND name=?", idx), idx);
    }
    // 列默认值：P3 起 App 靠这些缺省值画「本期」，这里钉住。
    const now = new Date().toISOString();
    db.run("INSERT INTO platforms(id, name, created_at, updated_at, seq) VALUES('p', '淘宝', ?, ?, 1)", now, now);
    db.run("INSERT INTO memberships(id, platform_id, name, created_at, updated_at, seq) VALUES('m', 'p', '88VIP', ?, ?, 2)", now, now);
    db.run("INSERT INTO benefits(id, membership_id, name, created_at, updated_at, seq) VALUES('b', 'm', '券', ?, ?, 3)", now, now);
    db.run("INSERT INTO benefit_events(id, benefit_id, kind, occurred_on, created_at, updated_at, seq) VALUES('e', 'b', 'claim', '2026-09-01', ?, ?, 4)", now, now);
    const p = db.get("SELECT * FROM platforms WHERE id = 'p'");
    assert.deepEqual([p.aliases, p.kind, p.archived, p.sort_order], ['[]', 'other', 0, 0]);
    const m = db.get("SELECT * FROM memberships WHERE id = 'm'");
    assert.deepEqual(
      [m.kind, m.fee_period, m.auto_renew, m.is_trial, m.origin, m.pay_pattern, m.last_charge_tx_id],
      ['membership', 'year', 'unknown', 0, '{}', null, null],
    );
    const b = db.get("SELECT * FROM benefits WHERE id = 'b'");
    assert.deepEqual([b.kind, b.flow, b.quota, b.anchor, b.limits, b.remind, b.origin], ['other', 'claim', '[]', 'calendar', '[]', 1, '{}']);
    assert.equal(db.get("SELECT count FROM benefit_events WHERE id = 'e'").count, 1);
  } finally {
    db.close();
    fs.rmSync(dir, { recursive: true, force: true });
    fs.rmSync(oldSql, { recursive: true, force: true });
  }
});

test('同步登记：四张表照 spec 登记布尔 / JSON 列', () => {
  const byTable = Object.fromEntries(SYNCED);
  assert.deepEqual(byTable.platforms, { bools: ['archived'], json: ['aliases'] });
  assert.deepEqual(byTable.memberships, { bools: ['archived', 'is_trial'], json: ['pay_pattern', 'origin'] });
  assert.deepEqual(byTable.benefits, { bools: ['archived', 'remind'], json: ['quota', 'limits', 'origin'] });
  assert.deepEqual(byTable.benefit_events, {});
});

test('/changes?since=0 带上四个桶（空库是空数组）', async (t) => {
  const { a, auth } = await household(t);
  const r = await a.get('/changes?since=0', auth);
  assert.equal(r.status, 200, r.text);
  for (const key of PERK_TABLES) assert.deepEqual(r.json[key], [], key);
});
