'use strict';

// 会员/卡：CRUD 与校验（平台存活、未来日期、到期不早于开始、账户只给信用卡）、「同时记一笔支出」与幂等、
// 同步墓碑。派生会员（来源权益）和级联删除在 perks_links.test.js。

const test = require('node:test');
const assert = require('node:assert/strict');

const { household } = require('./fixtures');
const { restartWith } = require('./perks_fixtures');

const pad = (n) => String(n).padStart(2, '0');
/** 本地日期，偏移 `days` 天；helpers.js 已把本进程钉在 Asia/Shanghai，和子进程一致。 */
function localDay(days = 0) {
  const d = new Date();
  d.setDate(d.getDate() + days);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

/** 一户人家 + 淘宝、优酷两个平台。 */
async function withPlatforms(t) {
  const h = await household(t);
  const tb = (await h.a.post('/platforms', { name: '淘宝' }, h.auth)).json.platform;
  const yk = (await h.a.post('/platforms', { name: '优酷' }, h.auth)).json.platform;
  return { ...h, tb, yk };
}

test('会员 CRUD：只必填平台和名称；默认值；未来的到期日可以；PATCH 不动没传的字段', async (t) => {
  const { a, auth, tb, yk, member } = await withPlatforms(t);

  const bare = await a.post('/memberships', { platformId: tb.id, name: '88VIP' }, auth);
  assert.equal(bare.status, 201, bare.text);
  const vip = bare.json.membership;
  assert.equal(vip.platformId, tb.id);
  assert.equal(vip.name, '88VIP');
  assert.equal(vip.kind, 'membership');
  assert.equal(vip.feePeriod, 'year');
  assert.equal(vip.autoRenew, 'unknown');
  assert.equal(vip.isTrial, false);
  assert.equal(vip.archived, false);
  assert.equal(vip.expiresOn, null, '到期日留空 = 长期有效');
  assert.equal(vip.termPaidCents, null, '本期实付留空 = 按续费价算');
  assert.deepEqual(vip.origin, {});
  assert.equal(vip.payPattern, null);
  assert.equal(vip.lastChargeTxId, null);
  assert.equal(vip.sourceBenefitId, null);

  const full = await a.post('/memberships', {
    platformId: yk.id, name: '优酷VIP', tier: '酷喵', kind: 'subscription', memberId: member.id,
    feeCents: 24800, feePeriod: 'year', termPaidCents: 0, termStartOn: localDay(-10), expiresOn: localDay(355),
    autoRenew: 'yes', isTrial: true, remindDays: 0, note: '88VIP 送的',
    origin: { src: 'manual', junk: 1 },
  }, auth);
  assert.equal(full.status, 201, full.text);
  const m = full.json.membership;
  assert.equal(m.tier, '酷喵');
  assert.equal(m.kind, 'subscription');
  assert.equal(m.memberId, member.id);
  assert.equal(m.feeCents, 24800);
  assert.equal(m.termPaidCents, 0, '刷卡免年费/试用填 0');
  assert.equal(m.expiresOn, localDay(355), '到期日可以在将来');
  assert.equal(m.autoRenew, 'yes');
  assert.equal(m.isTrial, true);
  assert.equal(m.remindDays, 0, '0 = 关掉提醒，不是空');
  assert.deepEqual(m.origin, { src: 'manual' }, 'origin 只留认得的键');

  const patched = await a.patch(`/memberships/${m.id}`, { name: '优酷VIP会员' }, auth);
  assert.equal(patched.status, 200, patched.text);
  assert.equal(patched.json.membership.expiresOn, localDay(355));
  assert.equal(patched.json.membership.memberId, member.id);
  assert.equal(patched.json.membership.isTrial, true);

  const cleared = await a.patch(`/memberships/${m.id}`, { expiresOn: null, memberId: null, tier: '' }, auth);
  assert.equal(cleared.json.membership.expiresOn, null);
  assert.equal(cleared.json.membership.memberId, null, 'null = 全家共用');
  assert.equal(cleared.json.membership.tier, null);

  const archived = await a.patch(`/memberships/${vip.id}`, { archived: true }, auth);
  assert.equal(archived.json.membership.archived, true);
  assert.deepEqual((await a.get('/memberships', auth)).json.items.map((x) => x.id), [m.id]);
  assert.deepEqual((await a.get('/memberships?archived=1', auth)).json.items.map((x) => x.id), [vip.id, m.id]);

  const gone = await a.del(`/memberships/${m.id}`, auth);
  assert.equal(gone.status, 200, gone.text);
  assert.equal((await a.patch(`/memberships/${m.id}`, { name: 'x' }, auth)).status, 404);
});

test('会员校验：非法输入一律 400', async (t) => {
  const { a, auth, tb, account } = await withPlatforms(t);
  const ok = { platformId: tb.id, name: '88VIP' };
  const cases = [
    [{ name: '88VIP' }, 'invalid_platformId'],
    [{ ...ok, platformId: '' }, 'invalid_platformId'],
    [{ ...ok, platformId: 'nope' }, 'invalid_platformId'],
    [{ ...ok, name: '' }, 'invalid_name'],
    [{ ...ok, name: 'x'.repeat(61) }, 'invalid_name'],
    [{ ...ok, tier: 'x'.repeat(31) }, 'invalid_tier'],
    [{ ...ok, kind: 'vip' }, 'invalid_kind'],
    [{ ...ok, memberId: 'nobody' }, 'invalid_memberId'],
    [{ ...ok, feeCents: -1 }, 'invalid_feeCents'],
    [{ ...ok, feeCents: 1.5 }, 'invalid_feeCents'],
    [{ ...ok, feePeriod: 'week' }, 'invalid_feePeriod'],
    [{ ...ok, termPaidCents: -1 }, 'invalid_termPaidCents'],
    [{ ...ok, termStartOn: '2026-02-30' }, 'invalid_termStartOn'],
    [{ ...ok, expiresOn: '2026/12/31' }, 'invalid_expiresOn'],
    [{ ...ok, termStartOn: '2026-09-01', expiresOn: '2026-08-31' }, 'invalid_expiresOn'],
    [{ ...ok, autoRenew: true }, 'invalid_autoRenew'],
    [{ ...ok, remindDays: 366 }, 'invalid_remindDays'],
    [{ ...ok, accountId: account.id }, 'invalid_accountId'],
    [{ ...ok, kind: 'credit_card', accountId: 'nope' }, 'invalid_accountId'],
    [{ ...ok, origin: [] }, 'invalid_origin'],
    [{ ...ok, origin: { ev: 'x'.repeat(201) } }, 'invalid_origin'],
    [{ ...ok, note: 'x'.repeat(1001) }, 'invalid_note'],
    [{ ...ok, recordTransaction: 'yes', feeCents: 8800 }, 'invalid_recordTransaction'],
  ];
  for (const [body, code] of cases) {
    const r = await a.post('/memberships', body, auth);
    assert.equal(r.status, 400, `${JSON.stringify(body)} → ${r.status} ${r.text}`);
    assert.equal(r.json.error.code, code, JSON.stringify(body));
  }
  assert.deepEqual((await a.get('/memberships?archived=1', auth)).json.items, [], '校验失败一条都不落库');

  // PATCH 比的是合并后的样子：只挪开始日到到期日之后也不行。
  const m = (await a.post('/memberships', { ...ok, termStartOn: '2026-01-01', expiresOn: '2026-12-31' }, auth)).json.membership;
  const moved = await a.patch(`/memberships/${m.id}`, { termStartOn: '2027-01-01' }, auth);
  assert.equal(moved.status, 400, moved.text);
  assert.equal(moved.json.error.code, 'invalid_termStartOn');
});

test('账户只给信用卡：信用卡可以挂账户；改成别的类型时账户自动清掉', async (t) => {
  const { a, auth, tb, account } = await withPlatforms(t);
  const card = await a.post('/memberships', { platformId: tb.id, name: '招行经典白', kind: 'credit_card', accountId: account.id }, auth);
  assert.equal(card.status, 201, card.text);
  assert.equal(card.json.membership.accountId, account.id);
  const renamed = await a.patch(`/memberships/${card.json.membership.id}`, { name: '经典白' }, auth);
  assert.equal(renamed.json.membership.accountId, account.id, '无关的 PATCH 不动账户');
  const other = await a.patch(`/memberships/${card.json.membership.id}`, { kind: 'membership' }, auth);
  assert.equal(other.status, 200, other.text);
  assert.equal(other.json.membership.accountId, null);
});

test('同时记一笔支出：默认不记；勾了按本期实付（没填按续费价）记在开始那天，0 元不记；同一个 clientId 只记一次', async (t) => {
  const { a, auth, tb, account, categories } = await withPlatforms(t);
  const cat = categories.find((c) => c.kind === 'expense');

  const quiet = await a.post('/memberships', { platformId: tb.id, name: '88VIP', feeCents: 8800 }, auth);
  assert.equal(quiet.json.membership.lastChargeTxId, null, '没勾就不记账');
  assert.equal((await a.get('/transactions', auth)).json.items.length, 0);

  const body = {
    platformId: tb.id, name: '88VIP', tier: '年卡', feeCents: 8800, termStartOn: '2026-03-01', expiresOn: '2027-02-28',
    recordTransaction: { accountId: account.id, categoryId: cat.id }, clientId: 'm-1',
  };
  const first = await a.post('/memberships', body, auth);
  assert.equal(first.status, 201, first.text);
  const txId = first.json.membership.lastChargeTxId;
  assert.ok(txId, '记下的流水挂在 lastChargeTxId');
  const tx = (await a.get(`/transactions/${txId}`, auth)).json.transaction;
  assert.equal(tx.type, 'expense');
  assert.equal(tx.amountCents, 8800);
  assert.equal(tx.accountId, account.id);
  assert.equal(tx.categoryId, cat.id);
  assert.equal(tx.merchant, '88VIP 年卡');
  assert.ok(tx.occurredAt.startsWith('2026-03-01'), tx.occurredAt);

  const again = await a.post('/memberships', body, auth);
  assert.equal(again.status, 200, again.text);
  assert.equal(again.json.replayed, true);
  assert.equal(again.json.membership.id, first.json.membership.id);
  assert.equal((await a.get('/transactions', auth)).json.items.length, 1, '重发不多记一笔');

  const paid = await a.post('/memberships', {
    platformId: tb.id, name: '京东PLUS', feeCents: 19800, termPaidCents: 9900, recordTransaction: { accountId: account.id },
  }, auth);
  const paidTx = (await a.get(`/transactions/${paid.json.membership.lastChargeTxId}`, auth)).json.transaction;
  assert.equal(paidTx.amountCents, 9900, '本期实付优先于续费价');
  assert.ok(paidTx.occurredAt.startsWith(localDay(0)), '没填开始日记今天');

  const future = await a.post('/memberships', {
    platformId: tb.id, name: '预约卡', feeCents: 100, termStartOn: localDay(30), recordTransaction: { accountId: account.id },
  }, auth);
  const futureTx = (await a.get(`/transactions/${future.json.membership.lastChargeTxId}`, auth)).json.transaction;
  assert.ok(futureTx.occurredAt.startsWith(localDay(0)), '开始日在将来也只记到今天');

  const free = await a.post('/memberships', { platformId: tb.id, name: '试用卡', feeCents: 1500, termPaidCents: 0, recordTransaction: { accountId: account.id } }, auth);
  assert.equal(free.json.membership.lastChargeTxId, null, '本期实付 0 不记账');

  const broken = await a.post('/memberships', { platformId: tb.id, name: '坏卡', feeCents: 100, recordTransaction: { accountId: 'gone' } }, auth);
  assert.equal(broken.status, 400, broken.text);
  assert.equal((await a.get('/memberships', auth)).json.items.filter((x) => x.name === '坏卡').length, 0, '记账失败时会员也不落库');
});

test('/changes 同步 memberships：isTrial 布尔、origin 对象，软删带墓碑', async (t) => {
  const { a, auth, tb } = await withPlatforms(t);
  const before = (await a.get('/changes?since=0', auth)).json.next;
  const m = (await a.post('/memberships', { platformId: tb.id, name: '88VIP', isTrial: true }, auth)).json.membership;
  const delta = (await a.get(`/changes?since=${before}`, auth)).json;
  assert.deepEqual(delta.memberships.map((x) => [x.id, x.isTrial, x.archived, x.origin]), [[m.id, true, false, {}]]);
  await a.del(`/memberships/${m.id}`, auth);
  assert.ok((await a.get(`/changes?since=${delta.next}`, auth)).json.memberships[0].deletedAt);
});

test('增删改的回应和 /changes 一个形状：pay_pattern（P6/P7 写）也还原成对象', async (t) => {
  const h = await withPlatforms(t);
  const { srv, auth, tb } = h;
  const pattern = { merchant: '淘宝', amountCents: 8800, everyDays: 365 };
  const made = (await h.a.post('/memberships', { platformId: tb.id, name: '88VIP' }, auth)).json.membership;
  const a = await restartWith(t, srv, (db) => {
    db.run('UPDATE memberships SET pay_pattern = ?, seq = ? WHERE id = ?', JSON.stringify(pattern), db.nextSeq(), made.id);
  });

  const listed = (await a.get('/memberships', auth)).json.items[0];
  const patched = (await a.patch(`/memberships/${made.id}`, { note: '改个备注' }, auth)).json.membership;
  const synced = (await a.get('/changes?since=0', auth)).json.memberships.find((m) => m.id === made.id);
  for (const row of [listed, patched, synced]) {
    assert.deepEqual(row.payPattern, pattern);
    assert.deepEqual(row.origin, {});
    assert.equal(row.isTrial, false);
    assert.equal(row.archived, false);
  }
  const gone = (await a.del(`/memberships/${made.id}`, auth)).json.membership;
  assert.deepEqual(gone.payPattern, pattern, '删除回的墓碑也一样');
});
