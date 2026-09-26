'use strict';

// 迁移 007（spec §2「007」）：只在服务端的 ai_imports 表、物品的 origin 列；以及「AI 推断」小点的服务端一半 ——
// origin 能写能读，PATCH 改过的字段从 origin.unverified 里拿掉。

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const { household } = require('./fixtures');
const { tmpDir } = require('./helpers');
const { SYNCED } = require('../src/modules/changes');

test('旧库（001–006）重开：补上 ai_imports 表和索引、物品的 origin 列（老行是 {}，seq 不动）', () => {
  const { openDb } = require('../src/lib/db');
  const dir = tmpDir('ai-imports-migrate');
  const oldSql = tmpDir('ai-imports-sql');
  const sqlDir = path.join(__dirname, '..', 'src', 'sql');
  for (const f of fs.readdirSync(sqlDir).filter((x) => /^00[1-6]_.+\.sql$/.test(x))) {
    fs.copyFileSync(path.join(sqlDir, f), path.join(oldSql, f));
  }
  const old = openDb(dir, { sqlDir: oldSql });
  const now = new Date().toISOString();
  old.run(
    "INSERT INTO assets(id, name, price_cents, purchased_on, created_at, updated_at, seq) VALUES('a', '手机', 100, '2026-09-01', ?, ?, 7)",
    now, now,
  );
  assert.equal(old.get("SELECT 1 AS ok FROM sqlite_master WHERE type='table' AND name='ai_imports'"), null);
  old.close();

  const db = openDb(dir);
  try {
    assert.ok(db.get('SELECT 1 AS ok FROM schema_migrations WHERE version = 7'));
    assert.ok(db.get("SELECT 1 AS ok FROM sqlite_master WHERE type='table' AND name='ai_imports'"));
    for (const idx of ['idx_ai_imports_created', 'idx_ai_imports_member']) {
      assert.ok(db.get("SELECT 1 AS ok FROM sqlite_master WHERE type='index' AND name=?", idx), idx);
    }
    const a = db.get("SELECT origin, seq FROM assets WHERE id = 'a'");
    assert.deepEqual([a.origin, a.seq], ['{}', 7], '老行按 {}，seq 不动（App 缺字段兜底，不用全量重拉）');
    db.run("INSERT INTO ai_imports(id, member_id, created_at, source_kind) VALUES('i', 'm', ?, 'text')", now);
    const i = db.get("SELECT * FROM ai_imports WHERE id = 'i'");
    assert.deepEqual([i.status, i.usage_in, i.usage_out, i.summary, i.undo], ['extracted', 0, 0, '{}', null]);
  } finally {
    db.close();
    fs.rmSync(dir, { recursive: true, force: true });
    fs.rmSync(oldSql, { recursive: true, force: true });
  }
});

test('同步登记：物品的 origin 按 JSON 还原；ai_imports 不同步', () => {
  const byTable = Object.fromEntries(SYNCED);
  assert.deepEqual(byTable.assets, { bools: ['archived'], json: ['origin'] });
  assert.equal(byTable.ai_imports, undefined);
});

test('物品的 origin：能写能读（/assets 与 /changes 都是对象），坏形状 400', async (t) => {
  const { a, auth } = await household(t);
  const made = (await a.post('/assets', { name: '手机', priceCents: 599900, purchasedOn: '2026-09-01' }, auth)).json.asset;
  assert.deepEqual(made.origin, {});
  const origin = { src: 'ai_text', importId: 'imp-1', ev: '订单：手机 ¥5999', unverified: ['purchasedOn'], junk: 1 };
  const r = await a.patch(`/assets/${made.id}`, { origin }, auth);
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.json.asset.origin, { src: 'ai_text', importId: 'imp-1', ev: '订单：手机 ¥5999', unverified: ['purchasedOn'] }, '只留四个键');
  const synced = (await a.get('/changes?since=0', auth)).json.assets.find((x) => x.id === made.id);
  assert.deepEqual(synced.origin.unverified, ['purchasedOn']);
  const bad = await a.patch(`/assets/${made.id}`, { origin: ['x'] }, auth);
  assert.equal(bad.status, 400);
  assert.equal(bad.json.error.code, 'invalid_origin');
});

test('「AI 推断」小点：PATCH 改了值的字段从 unverified 拿掉，没改的（表单整张带上）留着；会员、权益、物品都一样', async (t) => {
  const { a, auth } = await household(t);
  const tb = (await a.post('/platforms', { name: '淘宝' }, auth)).json.platform;
  const yk = (await a.post('/platforms', { name: '优酷' }, auth)).json.platform;
  const vip = (await a.post('/memberships', {
    platformId: tb.id, name: '88VIP', feeCents: 8800, expiresOn: '2026-12-31',
    origin: { src: 'ai_text', importId: 'imp-1', unverified: ['expiresOn', 'feeCents'] },
  }, auth)).json.membership;
  // 表单整张带上：feeCents 没变，expiresOn 改了
  const m = await a.patch(`/memberships/${vip.id}`, { name: '88VIP', feeCents: 8800, expiresOn: '2027-01-31' }, auth);
  assert.equal(m.status, 200, m.text);
  assert.deepEqual(m.json.membership.origin, { src: 'ai_text', importId: 'imp-1', unverified: ['feeCents'] });
  // 什么都没改：origin 不动
  const same = await a.patch(`/memberships/${vip.id}`, { feeCents: 8800 }, auth);
  assert.deepEqual(same.json.membership.origin.unverified, ['feeCents']);
  // 显式带 origin（App 的「没错」）说了算
  const confirmed = await a.patch(`/memberships/${vip.id}`, { origin: { src: 'ai_text', importId: 'imp-1', unverified: [] } }, auth);
  assert.deepEqual(confirmed.json.membership.origin.unverified, []);

  const perk = (await a.post('/benefits', {
    membershipId: vip.id, name: '优酷年卡', claimPlatformId: tb.id, quota: [{ p: 'year', n: 1 }],
    origin: { src: 'ai_text', unverified: ['claimPlatformId', 'quota'] },
  }, auth)).json.benefit;
  const b = await a.patch(`/benefits/${perk.id}`, { claimPlatformId: yk.id, quota: [{ p: 'year', n: 1 }] }, auth);
  assert.equal(b.status, 200, b.text);
  assert.deepEqual(b.json.benefit.origin.unverified, ['quota'], 'JSON 列按值比：额度没变');

  const item = (await a.post('/assets', {
    name: '手机', priceCents: 599900, purchasedOn: '2026-09-01', origin: { src: 'ai_text', unverified: ['purchasedOn', 'priceCents'] },
  }, auth)).json.asset;
  const i = await a.patch(`/assets/${item.id}`, { name: '手机', priceCents: 599900, purchasedOn: '2026-09-02' }, auth);
  assert.equal(i.status, 200, i.text);
  assert.deepEqual(i.json.asset.origin.unverified, ['priceCents']);
});
