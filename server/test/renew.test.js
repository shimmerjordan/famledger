'use strict';

// 续费 POST /memberships/:id/renew：默认往后推一个周期（月末截断）、本期开始和实付跟着换、试用变正式；
// 给定到期日（断了一阵又重开）；同一个 clientId 重发不再续、不重复记账；带 chargeTransactionId 只关联不记账；
// once / none 409 not_renewable；到期日不往后 400。

const test = require('node:test');
const assert = require('node:assert/strict');

const { household } = require('./fixtures');
const perks = require('../src/lib/perks_schema');

const pad = (n) => String(n).padStart(2, '0');
/** 本地日期，偏移 `days` 天；helpers.js 已把本进程钉在 Asia/Shanghai，和子进程一致。 */
function localDay(days = 0) {
  const d = new Date();
  d.setDate(d.getDate() + days);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

/** 一户人家 + 淘宝；`card(body)` 建一张会员卡。 */
async function withShop(t) {
  const h = await household(t);
  const tb = (await h.a.post('/platforms', { name: '淘宝' }, h.auth)).json.platform;
  const card = async (body) => (await h.a.post('/memberships', { platformId: tb.id, name: '88VIP', ...body }, h.auth)).json.membership;
  const renew = (id, body = {}) => h.a.post(`/memberships/${id}/renew`, body, h.auth);
  return { ...h, tb, card, renew };
}

test('续一期：到期日 + 一个周期、本期开始 = 原到期日次日、实付清空（按续费价）、试用变正式；同一个 clientId 重发不再续', async (t) => {
  const { a, auth, card, renew } = await withShop(t);
  const vip = await card({
    feeCents: 8800, termPaidCents: 0, termStartOn: '2026-01-01', expiresOn: '2026-12-31', autoRenew: 'yes', isTrial: true,
  });
  const before = (await a.get('/changes?since=0', auth)).json.next;

  const r = await renew(vip.id, { clientId: 'renew-1' });
  assert.equal(r.status, 200, r.text);
  const m = r.json.membership;
  assert.equal(m.expiresOn, '2027-12-31');
  assert.equal(m.termStartOn, '2027-01-01');
  assert.equal(m.termPaidCents, null, '不给实付 = 按续费价算');
  assert.equal(m.isTrial, false, '续过费就不是试用了');
  assert.equal(m.autoRenew, 'yes', '续费方式不动');
  assert.equal(m.lastChargeTxId, null, '没勾记账就不记');
  assert.equal((await a.get('/transactions', auth)).json.items.length, 0);

  const again = await renew(vip.id, { clientId: 'renew-1' });
  assert.equal(again.status, 200, again.text);
  assert.equal(again.json.replayed, true);
  assert.equal(again.json.membership.expiresOn, '2027-12-31', '重发不会再往后推一期');

  const delta = (await a.get(`/changes?since=${before}`, auth)).json.memberships;
  assert.deepEqual(delta.map((x) => [x.id, x.expiresOn]), [[vip.id, '2027-12-31']], '/changes 带上续过的样子');

  const other = await card({ feeCents: 100 });
  const reused = await renew(other.id, { clientId: 'renew-1' });
  assert.equal(reused.status, 409, reused.text);
  assert.equal(reused.json.error.code, 'client_id_reused');
});

test('续了一期：到期日、本期开始、试用这几项从「AI 推断」里拿掉（用户刚确认过），别的推断字段留着', async (t) => {
  const { card, renew } = await withShop(t);
  const vip = await card({
    feeCents: 8800, expiresOn: '2026-12-31', isTrial: true,
    origin: { src: 'ai_text', importId: 'imp-1', ev: '到期日 12-31', unverified: ['expiresOn', 'termStartOn', 'feeCents'] },
  });
  const r = await renew(vip.id, { clientId: 'renew-origin' });
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.json.membership.origin, { src: 'ai_text', importId: 'imp-1', ev: '到期日 12-31', unverified: ['feeCents'] });

  const plain = await card({ feeCents: 100, expiresOn: '2026-12-31' });
  const r2 = await renew(plain.id, { clientId: 'renew-plain' });
  assert.deepEqual(r2.json.membership.origin, {}, '手记的卡 origin 原样');
});

test('月末截断；没有到期日的按昨天算（续出来的一期从今天开始）；给定到期日时本期开始取「往前一期」的次日', async (t) => {
  const { card, renew } = await withShop(t);
  const monthly = await card({ feeCents: 2500, feePeriod: 'month', expiresOn: '2026-01-31' });
  const r1 = (await renew(monthly.id)).json.membership;
  assert.equal(r1.expiresOn, '2026-02-28', '1/31 + 1 月 = 2/28');
  assert.equal(r1.termStartOn, '2026-02-01');

  const open = await card({ feeCents: 2500, feePeriod: 'month' });
  const r2 = (await renew(open.id)).json.membership;
  assert.equal(r2.expiresOn, perks.addPeriod(localDay(-1), 'month'));
  assert.equal(r2.termStartOn, localDay(0));

  // 5 月底停了，9 月又开：给新的到期日，本期开始按「新到期日往前一个月」的次日算，不是 6/1。
  const lapsed = await card({ feeCents: 2500, feePeriod: 'month', expiresOn: '2026-05-31' });
  const r3 = await renew(lapsed.id, { expiresOn: '2026-10-22', paidCents: 1990 });
  assert.equal(r3.status, 200, r3.text);
  assert.equal(r3.json.membership.expiresOn, '2026-10-22');
  assert.equal(r3.json.membership.termStartOn, '2026-09-23');
  assert.equal(r3.json.membership.termPaidCents, 1990);

  const quarterly = await card({ feeCents: 6800, feePeriod: 'quarter', expiresOn: '2026-11-30' });
  assert.equal((await renew(quarterly.id)).json.membership.expiresOn, '2027-02-28');
});

test('续费同时记一笔：金额 = 实付（没给按续费价），记在本期开始那天；0 元不记；同一个 clientId 只记一次', async (t) => {
  const { a, auth, account, card, renew } = await withShop(t);
  const vip = await card({ tier: '年卡', feeCents: 8800, feePeriod: 'month', expiresOn: '2026-03-31' });
  const r = await renew(vip.id, { recordTransaction: { accountId: account.id }, clientId: 'renew-rec' });
  assert.equal(r.status, 200, r.text);
  const txId = r.json.membership.lastChargeTxId;
  assert.ok(txId, '记下的流水挂在 lastChargeTxId');
  const tx = (await a.get(`/transactions/${txId}`, auth)).json.transaction;
  assert.equal(tx.type, 'expense');
  assert.equal(tx.amountCents, 8800);
  assert.equal(tx.merchant, '88VIP 年卡');
  assert.ok(tx.occurredAt.startsWith('2026-04-01'), tx.occurredAt);
  await renew(vip.id, { recordTransaction: { accountId: account.id }, clientId: 'renew-rec' });
  assert.equal((await a.get('/transactions', auth)).json.items.length, 1, '重发不多记一笔');

  const paid = await renew(vip.id, { paidCents: 6600, recordTransaction: { accountId: account.id } });
  const paidTx = (await a.get(`/transactions/${paid.json.membership.lastChargeTxId}`, auth)).json.transaction;
  assert.equal(paidTx.amountCents, 6600, '给了实付按实付记');

  const free = await renew(vip.id, { paidCents: 0, recordTransaction: { accountId: account.id } });
  assert.equal(free.json.membership.lastChargeTxId, paid.json.membership.lastChargeTxId, '0 元不记，上一笔关联留着');
  assert.equal((await a.get('/transactions', auth)).json.items.length, 2);

  const broken = await renew(vip.id, { recordTransaction: { accountId: 'gone' } });
  assert.equal(broken.status, 400, broken.text);
  assert.equal(
    (await a.get('/memberships', auth)).json.items.find((m) => m.id === vip.id).expiresOn,
    free.json.membership.expiresOn,
    '记账失败时续费也不落库',
  );
});

test('带 chargeTransactionId：只关联那笔已有流水、不另记账（勾了记账也不记）；流水不存在、不是确认过的支出 400', async (t) => {
  const { a, auth, account, fund, category, card, renew, tx } = await withShop(t);
  const vip = await card({ feeCents: 2500, feePeriod: 'month', expiresOn: '2026-08-31' });
  const charge = (await tx({
    type: 'expense', amountCents: 2500, accountId: account.id, fundId: fund.id, categoryId: category.id,
    occurredAt: '2026-09-01T09:00:00+08:00', merchant: '淘宝 88VIP',
  })).json.transaction;
  const r = await renew(vip.id, { chargeTransactionId: charge.id, recordTransaction: { accountId: account.id } });
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.membership.lastChargeTxId, charge.id);
  assert.equal(r.json.membership.expiresOn, '2026-09-30');
  assert.equal((await a.get('/transactions', auth)).json.items.length, 1, '只关联，不另记账');

  const missing = await renew(vip.id, { chargeTransactionId: 'nope' });
  assert.equal(missing.status, 400, missing.text);
  assert.equal(missing.json.error.code, 'invalid_chargeTransactionId');

  // 只能关联确认过的支出：收入、待确认的都不行，卡也不动。
  const income = (await tx({
    type: 'income', amountCents: 2500, accountId: account.id, fundId: fund.id, occurredAt: '2026-09-02T09:00:00+08:00',
  })).json.transaction;
  const pending = (await tx({
    type: 'expense', amountCents: 2500, accountId: account.id, fundId: fund.id, categoryId: category.id,
    occurredAt: '2026-09-03T09:00:00+08:00', status: 'pending',
  })).json.transaction;
  for (const wrong of [income, pending]) {
    assert.ok(wrong && wrong.id, JSON.stringify(wrong));
    const bad = await renew(vip.id, { chargeTransactionId: wrong.id });
    assert.equal(bad.status, 400, bad.text);
    assert.equal(bad.json.error.code, 'invalid_chargeTransactionId');
  }
  assert.equal(
    (await a.get('/memberships', auth)).json.items.find((m) => m.id === vip.id).expiresOn,
    '2026-09-30',
    '关联不对就不续',
  );
});

test('不能续：once / none 409 not_renewable；新到期日不晚于原到期日 400；卡不存在 404；实付是负数 400', async (t) => {
  const { card, renew } = await withShop(t);
  for (const feePeriod of ['once', 'none']) {
    const m = await card({ feePeriod, expiresOn: '2026-12-31' });
    const r = await renew(m.id);
    assert.equal(r.status, 409, `${feePeriod} → ${r.text}`);
    assert.equal(r.json.error.code, 'not_renewable');
  }
  const m = await card({ feeCents: 8800, expiresOn: '2026-12-31' });
  for (const expiresOn of ['2026-12-31', '2026-06-30']) {
    const r = await renew(m.id, { expiresOn });
    assert.equal(r.status, 400, r.text);
    assert.equal(r.json.error.code, 'invalid_expiresOn');
  }
  assert.equal((await renew(m.id, { expiresOn: '2027-02-30' })).json.error.code, 'invalid_expiresOn');
  assert.equal((await renew(m.id, { paidCents: -1 })).json.error.code, 'invalid_paidCents');
  assert.equal((await renew('nope')).status, 404);
});
