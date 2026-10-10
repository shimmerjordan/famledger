'use strict';

// 债务（modules/debts.js）：每笔债务背后一个内部账户，余额就是还剩多少；钱经真账户走是普通转账，
// 不记流水改期初并留备忘；人情的钱记成支出/收入、默认不进净资产。所有数字手算。

const test = require('node:test');
const assert = require('node:assert/strict');

const { household } = require('./fixtures');

function ok(r, what) {
  assert.ok(r.status >= 200 && r.status < 300, `${what} → ${r.status} ${r.text}`);
  return r.json;
}

function fail(r, status, code, what) {
  assert.equal(r.status, status, `${what} → ${r.status} ${r.text}`);
  assert.equal(r.json.error.code, code, `${what} 的错误码`);
}

async function setup(t) {
  const h = await household(t);
  const { a, auth } = h;
  const bank = ok(await a.post('/accounts', { name: '招行卡', kind: 'bank', initialBalanceCents: 1000000 }, auth), 'POST 招行卡').account;
  return {
    ...h, bank,
    debt: (body) => a.post('/debts', body, auth),
    settle: (id, body) => a.post(`/debts/${id}/settle`, body, auth),
    overview: async () => ok(await a.get('/stats/overview', auth), 'GET /stats/overview'),
    txs: async () => ok(await a.get('/transactions?limit=200', auth), 'GET /transactions').items,
    accounts: async () => ok(await a.get('/accounts?archived=1', auth), 'GET /accounts').items,
  };
}

const balanceOf = (o, id) => o.accounts.find((x) => x.accountId === id)?.balanceCents;

test('借出：内部账户 + 转账；收回一部分；收多了 400；净资产不变', async (t) => {
  const h = await setup(t);
  const before = await h.overview();

  fail(await h.debt({ direction: 'lend', counterparty: '张三', amountCents: 0 }), 400, 'invalid_amountCents', '0 元');
  fail(await h.debt({ direction: 'both', counterparty: '张三', amountCents: 1 }), 400, 'invalid_direction', '方向不对');
  fail(await h.debt({ direction: 'lend', amountCents: 1 }), 400, 'invalid_counterparty', '没对方');
  fail(
    await h.debt({ direction: 'lend', counterparty: '张三', amountCents: 1, recordTransaction: { accountId: 'nope' } }),
    400, 'invalid_accountId', '账户不存在',
  );

  const d = ok(await h.debt({
    direction: 'lend', counterparty: '张三', amountCents: 500000, startedOn: '2026-09-01', dueOn: '2026-12-31',
    recordTransaction: { accountId: h.bank.id },
  }), 'POST 借出').debt;
  assert.equal(d.counted, true, '借款默认计入');
  assert.equal(d.kind, 'loan');
  assert.deepEqual(d.memoLog, [], '经账户走的不留备忘');
  const acct = (await h.accounts()).find((x) => x.id === d.accountId);
  assert.equal(acct.kind, 'debt');
  assert.equal(acct.name, '借给 张三');
  const lent = (await h.txs()).find((x) => x.merchant === '借给 张三');
  assert.equal(lent.type, 'transfer');
  assert.equal(lent.accountId, h.bank.id);
  assert.equal(lent.toAccountId, d.accountId);

  let o = await h.overview();
  assert.equal(balanceOf(o, d.accountId), 500000);
  assert.equal(o.debts.receivableCents, 500000);
  assert.equal(o.debts.countedReceivableCents, 500000);
  assert.equal(o.cashCents, before.cashCents - 500000, '借出去的不算现金流');
  assert.equal(o.netWorthCents, before.netWorthCents, '钱换了个地方，净资产不变');

  ok(await h.settle(d.id, { amountCents: 200000, accountId: h.bank.id, clientId: 'c1' }), '收回 2000');
  const again = ok(await h.settle(d.id, { amountCents: 200000, accountId: h.bank.id, clientId: 'c1' }), '重发');
  assert.equal(again.replayed, true);
  o = await h.overview();
  assert.equal(balanceOf(o, d.accountId), 300000, '重发只收回一次');
  fail(await h.settle(d.id, { amountCents: 300001, accountId: h.bank.id }), 400, 'over_settle', '收多了');
  const back = (await h.txs()).filter((x) => x.merchant === '收回 张三');
  assert.equal(back.length, 1);
  assert.equal(back[0].accountId, d.accountId);
  assert.equal(back[0].toAccountId, h.bank.id);

  // 再借 1000，不记流水：改期初、留备忘、原始金额累加
  const added = ok(await h.settle(d.id, { action: 'add', amountCents: 100000, occurredOn: '2026-10-01', note: '又借了' }), '追加').debt;
  assert.equal(added.amountCents, 600000);
  assert.equal(added.memoLog.length, 1);
  assert.deepEqual(added.memoLog[0], { on: '2026-10-01', amountCents: 100000, note: '又借了', recorded: false, action: 'add' });
  o = await h.overview();
  assert.equal(balanceOf(o, d.accountId), 400000);

  fail(await h.a.del(`/debts/${d.id}`, h.auth), 409, 'debt_in_use', '有往来流水不能删');
  fail(await h.a.del(`/accounts/${d.accountId}`, h.auth), 409, 'account_is_debt', '内部账户不能从账户页删');

  ok(await h.a.patch(`/debts/${d.id}`, { counterparty: '张三丰' }, h.auth), '改名');
  assert.equal((await h.accounts()).find((x) => x.id === d.accountId).name, '借给 张三丰', '内部账户跟着改名');
  fail(await h.a.patch(`/debts/${d.id}`, { direction: 'borrow' }, h.auth), 400, 'invalid_direction', '方向不能改');
});

test('借入不记流水：负余额进负债；还清后删得掉、内部账户一起删；同步带 debts', async (t) => {
  const h = await setup(t);
  const before = await h.overview();
  const d = ok(await h.debt({ direction: 'borrow', kind: 'credit', counterparty: '李四', amountCents: 100000 }), 'POST 借入').debt;
  assert.equal(d.memoLog.length, 1, '起始那一行');
  assert.equal(d.memoLog[0].note, '起始');
  assert.equal(d.memoLog[0].amountCents, -100000);

  let o = await h.overview();
  assert.equal(balanceOf(o, d.accountId), -100000);
  assert.equal(o.debts.payableCents, 100000);
  assert.equal(o.netWorthCents, before.netWorthCents - 100000, '欠的钱进负债');
  assert.equal(o.liabilitiesCents, before.liabilitiesCents + 100000);

  ok(await h.settle(d.id, { amountCents: 100000 }), '还清（不记流水）');
  o = await h.overview();
  assert.equal(balanceOf(o, d.accountId), 0);
  assert.equal(o.netWorthCents, before.netWorthCents);

  const changes = ok(await h.a.get('/changes?since=0', h.auth), 'GET /changes');
  const synced = changes.debts.find((x) => x.id === d.id);
  assert.equal(synced.counted, true);
  assert.equal(synced.memoLog.length, 2);

  ok(await h.a.del(`/debts/${d.id}`, h.auth), '删');
  assert.equal((await h.accounts()).some((x) => x.id === d.accountId), false, '内部账户一起删了');
});

test('人情：钱记成支出/收入（类别人情）、默认不进净资产；收回人情记收入', async (t) => {
  const h = await setup(t);
  const before = await h.overview();
  const d = ok(await h.debt({
    direction: 'lend', kind: 'favor', counterparty: '王五', amountCents: 80000, startedOn: '2026-05-01',
    recordTransaction: { accountId: h.bank.id },
  }), 'POST 随礼').debt;
  assert.equal(d.counted, false, '人情默认不计入');
  const gift = (await h.txs()).find((x) => x.merchant === '人情 王五');
  assert.equal(gift.type, 'expense', '随礼是真花出去的钱');
  const cat = h.categories.find((c) => c.id === gift.categoryId);
  assert.equal(cat.name, '人情');

  let o = await h.overview();
  assert.equal(balanceOf(o, d.accountId), 80000, '内部账户记个数');
  assert.equal(o.debts.receivableCents, 80000);
  assert.equal(o.debts.countedReceivableCents, 0);
  assert.equal(o.netWorthCents, before.netWorthCents - 80000, '只少了随出去的钱，人情本身不算');

  ok(await h.settle(d.id, { amountCents: 80000, accountId: h.bank.id }), '对方回礼');
  const back = (await h.txs()).find((x) => x.merchant === '收回人情 王五');
  assert.equal(back.type, 'income');
  o = await h.overview();
  assert.equal(balanceOf(o, d.accountId), 0);
  assert.equal(o.netWorthCents, before.netWorthCents);
});
