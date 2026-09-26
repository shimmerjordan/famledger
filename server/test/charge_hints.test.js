'use strict';

// 扣费线索（spec §4 GET /memberships/charge-hints，P6）与它连带的规则：会员的扣费特征 payPattern 可写（校验、规整、清空）；
// 线索只看设了扣费特征、到期日在 [今天 − 15, 今天 + 7] 的卡，在到期日前 7 天到后 15 天里找没被关联过的对得上的
// 确认支出；一张卡一条、一笔流水只给一张卡；同一笔流水不能挂到两张卡上（续费关联、PATCH lastChargeTxId 都 409）。

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const { household } = require('./fixtures');
const { openDb } = require('../src/lib/db');
const perks = require('../src/lib/perks_schema');
const { CHARGE_TX_SQL, matchChargeHints, matchesPayPattern, readPayPattern } = require('../src/lib/charge_hints');

const pad = (n) => String(n).padStart(2, '0');
/** 本地日期，偏移 `days` 天；helpers.js 已把本进程钉在 Asia/Shanghai，和子进程一致。 */
function localDay(days = 0) {
  const d = new Date();
  d.setDate(d.getDate() + days);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}
/** 那天上午九点（北京时间），流水的 occurredAt。 */
const at = (days) => `${localDay(days)}T09:00:00+08:00`;

const TV = { keywords: ['腾讯视频'], minCents: 2000, maxCents: 3000 };

/** 一户人家 + 腾讯视频平台；`card(body)` 建卡，`spend(days, body)` 记一笔确认支出，`hints()` 取线索。 */
async function withTv(t) {
  const h = await household(t);
  const tx = (await h.a.post('/platforms', { name: '腾讯视频' }, h.auth)).json.platform;
  const card = async (body) => {
    const r = await h.a.post('/memberships', { platformId: tx.id, name: '腾讯视频', feeCents: 2500, feePeriod: 'month', ...body }, h.auth);
    assert.equal(r.status, 201, r.text);
    return r.json.membership;
  };
  const spend = async (days, body = {}) => {
    const r = await h.tx({
      type: 'expense', amountCents: 2500, accountId: h.account.id, fundId: h.fund.id, categoryId: h.category.id,
      occurredAt: at(days), merchant: '腾讯视频', ...body,
    });
    assert.equal(r.status, 201, r.text);
    return r.json.transaction;
  };
  const hints = async () => {
    const r = await h.a.get('/memberships/charge-hints', h.auth);
    assert.equal(r.status, 200, r.text);
    return r.json.items;
  };
  return { ...h, platform: tx, card, spend, hints };
}

test('payPattern 可写：关键词去空白、按规范化名去重；金额范围可缺一头；null 清掉；/changes 带出去', async (t) => {
  const { a, auth, card } = await withTv(t);
  const m = await card({ payPattern: { keywords: [' 腾讯视频 ', '腾讯 视频', 'QQ会员', '!!'], minCents: 2000, junk: 1 } });
  assert.deepEqual(m.payPattern, { keywords: ['腾讯视频', 'QQ会员'], minCents: 2000 });
  // 关键词中间的空格原样留着（「Apple Music」是一个词）；App 表单只按逗号、顿号、换行拆，两边一个口径。
  const apple = await card({ name: 'Apple Music', payPattern: { keywords: ['Apple Music'] } });
  assert.deepEqual(apple.payPattern, { keywords: ['Apple Music'] });

  const patched = await a.patch(`/memberships/${m.id}`, { payPattern: { keywords: ['腾讯视频'], minCents: 2000, maxCents: 3000 } }, auth);
  assert.equal(patched.status, 200, patched.text);
  assert.deepEqual(patched.json.membership.payPattern, TV);
  const synced = (await a.get('/changes?since=0', auth)).json.memberships.find((x) => x.id === m.id);
  assert.deepEqual(synced.payPattern, TV);

  const untouched = await a.patch(`/memberships/${m.id}`, { note: '改个备注' }, auth);
  assert.deepEqual(untouched.json.membership.payPattern, TV, '没传就不动');
  const cleared = await a.patch(`/memberships/${m.id}`, { payPattern: null }, auth);
  assert.equal(cleared.json.membership.payPattern, null);
});

test('payPattern 校验：不是对象、没有关键词、关键词太长 / 太多、金额下限高于上限、金额是负数 —— 400 invalid_payPattern', async (t) => {
  const { a, auth, card } = await withTv(t);
  const m = await card({});
  const bad = [
    '腾讯视频',
    { keywords: [] },
    { keywords: ['!!', '  '] },
    { keywords: ['x'.repeat(31)] },
    { keywords: ['a', 'b', 'c', 'd', 'e', 'f'] },
    { keywords: [1] },
    { keywords: ['腾讯视频'], minCents: 3000, maxCents: 2000 },
    { keywords: ['腾讯视频'], minCents: -1 },
  ];
  for (const payPattern of bad) {
    const r = await a.patch(`/memberships/${m.id}`, { payPattern }, auth);
    assert.equal(r.status, 400, `${JSON.stringify(payPattern)} → ${r.text}`);
    assert.equal(r.json.error.code, 'invalid_payPattern');
  }
});

test('线索：到期日前后对得上的确认支出（关键词在商户或备注里、金额在范围内）；一张卡给离到期日最近的那一笔', async (t) => {
  const { a, auth, account, fund, card, spend, hints } = await withTv(t);
  const m = await card({ expiresOn: localDay(-2), autoRenew: 'yes', payPattern: TV });
  const near = await spend(-1, { merchant: '财付通', note: '腾讯视频VIP 连续包月' });
  await spend(-5);
  // 对不上的：金额超出、关键词不对、待确认、收入、删掉的、比到期日早 8 天。
  await spend(0, { amountCents: 3500 });
  await spend(0, { merchant: '爱奇艺' });
  await spend(0, { status: 'pending' });
  const income = await a.post('/transactions', {
    type: 'income', amountCents: 2500, accountId: account.id, fundId: fund.id, occurredAt: at(0), merchant: '腾讯视频',
  }, auth);
  assert.equal(income.status, 201, income.text);
  const gone = await spend(0);
  await a.del(`/transactions/${gone.id}`, auth);
  await spend(-10);

  assert.deepEqual(await hints(), [{
    membershipId: m.id,
    transactionId: near.id,
    occurredOn: localDay(-1),
    amountCents: 2500,
    merchant: '财付通',
    expiresOn: localDay(-2),
    renewTo: perks.addPeriod(localDay(-2), 'month'),
  }]);
});

test('线索只看到期日在 [今天 − 15, 今天 + 7]、没归档、设了扣费特征、能续费的卡', async (t) => {
  const { card, spend, hints } = await withTv(t);
  // 卡的到期日在这里按「今天」算好写死，服务端取线索时才算窗口：中间跨过 0 点，两头的卡就差一天。
  const day0 = localDay();
  const edgeOld = await card({ name: '过期 15 天', expiresOn: localDay(-15), payPattern: TV });
  await spend(-14, { merchant: '腾讯视频 过期15' });
  await card({ name: '过期 16 天', expiresOn: localDay(-16), payPattern: { keywords: ['过期16'] } });
  await spend(-15, { merchant: '过期16' });
  const edgeNew = await card({ name: '7 天后到期', expiresOn: localDay(7), payPattern: { keywords: ['七天'] } });
  await spend(0, { merchant: '七天' });
  await card({ name: '8 天后到期', expiresOn: localDay(8), payPattern: { keywords: ['八天'] } });
  await spend(1, { merchant: '八天' });
  await card({ name: '归档的', expiresOn: localDay(0), archived: true, payPattern: { keywords: ['归档'] } });
  await spend(0, { merchant: '归档' });
  await card({ name: '没设特征', expiresOn: localDay(0) });
  await spend(0, { merchant: '没设特征' });
  await card({ name: '一次性', feePeriod: 'once', expiresOn: localDay(0), payPattern: { keywords: ['一次性'] } });
  await spend(0, { merchant: '一次性' });
  await card({ name: '长期有效', payPattern: { keywords: ['长期'] } });
  await spend(0, { merchant: '长期' });

  const got = (await hints()).map((h) => h.membershipId);
  if (localDay() !== day0) return t.skip('跑的途中跨过了午夜，窗口两头差一天');
  assert.deepEqual(got, [edgeOld.id, edgeNew.id]);
});

test('被关联过的流水不再给：续费关联过的、建卡时记的那笔、物品记的那笔；续上之后这条线索就没了', async (t) => {
  const { a, auth, account, card, spend, hints } = await withTv(t);
  const m = await card({ expiresOn: localDay(-1), payPattern: TV });
  const charge = await spend(0);
  assert.deepEqual((await hints()).map((h) => h.transactionId), [charge.id]);
  const r = await a.post(`/memberships/${m.id}/renew`, { chargeTransactionId: charge.id, paidCents: 2500, clientId: 'hint-1' }, auth);
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(await hints(), [], '续上以后到期日往后挪、这笔也挂上了');

  // 建卡时「同时记一笔」记下的那笔已经挂在卡上。
  const fresh = await card({ name: '新卡', feeCents: 2500, termStartOn: localDay(0), expiresOn: localDay(3), payPattern: { keywords: ['新卡'] }, recordTransaction: { accountId: account.id } });
  assert.ok(fresh.lastChargeTxId);
  // 物品「同时记一笔」记下的那笔（名字碰巧也叫「新卡」）挂在物品上。
  const item = await a.post('/assets', { name: '新卡读卡器', category: 'digital', priceCents: 2500, purchasedOn: localDay(0), recordTransaction: { accountId: account.id } }, auth);
  assert.equal(item.status, 201, item.text);
  assert.deepEqual(await hints(), []);
});

test('一笔流水只给一张卡：两张卡都对得上时持有人对得上的那张拿走；两笔就各给一张', async (t) => {
  const { a, auth, member, card, spend, hints } = await withTv(t);
  const other = (await a.post('/members', { username: 'baba', password: 'hunter22', displayName: '爸爸' }, auth)).json.member;
  assert.ok(other && other.id, '建第二个成员');
  // 爸爸的卡今天到期，离今天这笔更近；但这笔是我记的（member_id = 我），归我的卡。
  const papa = await card({ name: '爸爸的', memberId: other.id, expiresOn: localDay(0), payPattern: TV });
  const mine = await card({ name: '我的', memberId: member.id, expiresOn: localDay(-1), payPattern: TV });
  const first = await spend(0);
  assert.deepEqual((await hints()).map((h) => [h.membershipId, h.transactionId]), [[mine.id, first.id]]);

  const second = await spend(-1);
  const both = await hints();
  assert.equal(both.length, 2);
  assert.deepEqual(new Set(both.map((h) => h.transactionId)), new Set([first.id, second.id]), '一笔一张卡');
  assert.deepEqual(new Set(both.map((h) => h.membershipId)), new Set([papa.id, mine.id]));
});

test('对不对得上（纯函数）：关键词在商户或备注里都算，但不能跨过两者的边界拼出来；金额两头都是闭区间', () => {
  const p = readPayPattern({ keywords: ['移动视频', 'Apple Music'], minCents: 1000, maxCents: 2000 });
  const tx = (merchant, note = '', cents = 1500) => ({ merchant, note, amount_cents: cents });
  assert.equal(matchesPayPattern(p, tx('中国移动', '视频彩铃')), false, '「中国移动」+「视频彩铃」拼不出「移动视频」');
  assert.equal(matchesPayPattern(p, tx('财付通', '移动视频会员')), true, '备注里有');
  assert.equal(matchesPayPattern(p, tx('APPLE MUSIC')), true, '商户里有（大小写、空格都规范化了再比）');
  assert.equal(matchesPayPattern(p, tx('Apple', 'Music')), false);
  assert.equal(matchesPayPattern(p, tx('移动视频', '', 1000)), true);
  assert.equal(matchesPayPattern(p, tx('移动视频', '', 2000)), true);
  assert.equal(matchesPayPattern(p, tx('移动视频', '', 2001)), false);
  assert.equal(matchesPayPattern(p, tx(null, null)), false);
});

test('charge-hints 的流水查询走 idx_tx_occurred（服务端不跑 ANALYZE，没有统计信息也要走它），不另起临时排序', (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'famledger-qp-'));
  const db = openDb(dir);
  t.after(() => {
    db.close();
    fs.rmSync(dir, { recursive: true, force: true });
  });
  const plan = db.all(`EXPLAIN QUERY PLAN ${CHARGE_TX_SQL}`, '2026-09-01', '2026-10-01').map((r) => r.detail);
  const main = plan.find((d) => /\btransactions\b/.test(d) && !/memberships|assets/.test(d));
  assert.ok(main, plan.join(' | '));
  assert.match(main, /USING (COVERING )?INDEX idx_tx_occurred \(occurred_at>\? AND occurred_at<\?\)/, plan.join(' | '));
  assert.ok(!plan.some((d) => /idx_tx_dedupe/.test(d)), plan.join(' | '));
  assert.ok(!plan.some((d) => /TEMP B-TREE FOR ORDER BY/.test(d)), plan.join(' | '));
});

test('matchChargeHints（纯函数）：坏的扣费特征跳过；窗口两头都算；分配结果和输入顺序无关', () => {
  const card = (id, expiresOn, pattern, memberId = null) => ({ id, member_id: memberId, fee_period: 'month', expires_on: expiresOn, pay_pattern: JSON.stringify(pattern) });
  const tx = (id, day, cents = 2500, merchant = '腾讯视频', memberId = 'u1') => ({ id, occurred_at: `${day}T09:00:00+08:00`, amount_cents: cents, merchant, note: '', member_id: memberId });
  assert.equal(readPayPattern('{bad json'), null);
  assert.equal(readPayPattern(JSON.stringify({ keywords: ['!!'] })), null);
  assert.deepEqual(readPayPattern({ keywords: ['腾讯 视频'], minCents: -5, maxCents: 3000 }), { keys: ['腾讯视频'], min: null, max: 3000 });

  const cards = [card('a', '2026-09-10', TV), card('b', '2026-09-10', TV), { ...card('bad', '2026-09-10', TV), pay_pattern: 'oops' }];
  const txs = [tx('t-early', '2026-09-03'), tx('t-late', '2026-09-25'), tx('t-out', '2026-09-26'), tx('t-before', '2026-09-02')];
  const forward = matchChargeHints(cards, txs);
  const backward = matchChargeHints([...cards].reverse(), [...txs].reverse());
  assert.deepEqual(forward, backward);
  assert.deepEqual(forward.map((h) => [h.membershipId, h.transactionId]), [['a', 't-early'], ['b', 't-late']], '到期前 7 天、后 15 天都算；再往外不算');
  assert.equal(forward[0].renewTo, '2026-10-10');
});

test('同一笔流水不能挂到两张卡上：续费关联别的卡挂着的 409 charge_linked；挂在自己身上再续也 409；PATCH lastChargeTxId 同样查', async (t) => {
  const { a, auth, card, spend } = await withTv(t);
  const one = await card({ name: '一号', expiresOn: localDay(-1) });
  const two = await card({ name: '二号', expiresOn: localDay(-1) });
  const charge = await spend(0);
  assert.equal((await a.post(`/memberships/${one.id}/renew`, { chargeTransactionId: charge.id }, auth)).status, 200);

  const taken = await a.post(`/memberships/${two.id}/renew`, { chargeTransactionId: charge.id }, auth);
  assert.equal(taken.status, 409, taken.text);
  assert.equal(taken.json.error.code, 'charge_linked');
  assert.equal(taken.json.error.details.membershipId, one.id);
  const again = await a.post(`/memberships/${one.id}/renew`, { chargeTransactionId: charge.id }, auth);
  assert.equal(again.status, 409, again.text);
  assert.equal(again.json.error.code, 'charge_linked', '一笔钱不能续两期');

  const patchTaken = await a.patch(`/memberships/${two.id}`, { lastChargeTxId: charge.id }, auth);
  assert.equal(patchTaken.status, 409, patchTaken.text);
  assert.equal(patchTaken.json.error.code, 'charge_linked');
  // 撤销「续上」：把自己的改回原来的（null），再挂回去也行（没别人挂着）。
  const undone = await a.patch(`/memberships/${one.id}`, { lastChargeTxId: null }, auth);
  assert.equal(undone.json.membership.lastChargeTxId, null);
  const relinked = await a.patch(`/memberships/${two.id}`, { lastChargeTxId: charge.id }, auth);
  assert.equal(relinked.status, 200, relinked.text);
  assert.equal(relinked.json.membership.lastChargeTxId, charge.id);
  // 不存在的、待确认的：按 null 存（只为撤销时改回原值用，悬空的指针没有意义），不 400。
  const missing = await a.patch(`/memberships/${one.id}`, { lastChargeTxId: 'nope' }, auth);
  assert.equal(missing.status, 200, missing.text);
  assert.equal(missing.json.membership.lastChargeTxId, null);
  const pending = await spend(0, { status: 'pending' });
  const notYet = await a.patch(`/memberships/${one.id}`, { lastChargeTxId: pending.id }, auth);
  assert.equal(notYet.status, 200, notYet.text);
  assert.equal(notYet.json.membership.lastChargeTxId, null);
});

test('撤销「续上」：原来的「上次扣费」那笔后来删了，撤销照样成功 —— 到期日、本期都改回去，上次扣费清空，线索回来', async (t) => {
  const { a, auth, account, card, spend, hints } = await withTv(t);
  // 建卡时勾了「同时记一笔」：lastChargeTxId = 那笔。后来自动记账记下了真实扣款，用户把手记的那笔删了。
  const m = await card({ termStartOn: localDay(-30), expiresOn: localDay(-1), payPattern: TV, recordTransaction: { accountId: account.id } });
  const original = m.lastChargeTxId;
  assert.ok(original);
  assert.equal((await a.del(`/transactions/${original}`, auth)).status, 200);
  const charge = await spend(0);
  const [hint] = await hints();
  assert.equal(hint.transactionId, charge.id);
  const renewed = await a.post(`/memberships/${m.id}/renew`, { clientId: 'undo-1', expiresOn: hint.renewTo, paidCents: 2500, chargeTransactionId: charge.id }, auth);
  assert.equal(renewed.status, 200, renewed.text);

  // App 的撤销：把续费前的样子整包 PATCH 回去（perk_actions.dart renewNow）。
  const undo = await a.patch(`/memberships/${m.id}`, {
    expiresOn: m.expiresOn, termStartOn: m.termStartOn, termPaidCents: m.termPaidCents, isTrial: m.isTrial, lastChargeTxId: original,
  }, auth);
  assert.equal(undo.status, 200, undo.text);
  assert.equal(undo.json.membership.expiresOn, localDay(-1));
  assert.equal(undo.json.membership.termStartOn, localDay(-30));
  assert.equal(undo.json.membership.lastChargeTxId, null, '删掉的那笔不再挂回来');
  assert.deepEqual((await hints()).map((h) => h.transactionId), [charge.id], '这笔又没挂在哪张卡上了，线索回来');
});
