'use strict';

// 多币种的数据规则（transactions.js / accounts.js / debts.js / holdings.js / assets.js / memberships.js）：
// 流水的币种跟账户走；跨币种转账必须说到账多少；账户有流水就锁定币种；债务的币种只在新建时定；
// 钱经过的真账户必须和债务 / 持仓 / 物品同币种，会员费按基准币；板块余额按币种分开。

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
  return r.json.error;
}

async function setup(t) {
  const h = await household(t);
  const { a, auth } = h;
  const acct = async (body) => ok(await a.post('/accounts', body, auth), `POST ${body.name}`).account;
  return {
    ...h,
    cny: await acct({ name: '招行卡', kind: 'bank', initialBalanceCents: 1000000 }),
    usd: await acct({ name: '美元户', kind: 'bank', currency: 'USD', initialBalanceCents: 100000 }),
    usdInvest: await acct({ name: '美股户', kind: 'invest', currency: 'USD' }),
    tx: (body) => a.post('/transactions', body, auth),
    overview: async () => ok(await a.get('/stats/overview', auth), 'GET /stats/overview'),
  };
}

const balance = (o, id) => o.accounts.find((x) => x.accountId === id)?.balanceCents;

test('流水的币种跟账户走：美元户里记的就是美元，客户端传错了也以账户为准；没账户用传来的', async (t) => {
  const h = await setup(t);
  const spent = ok(await h.tx({ type: 'expense', amountCents: 1500, currency: 'CNY', accountId: h.usd.id }), '美元户支出').transaction;
  assert.equal(spent.currency, 'USD');
  const plain = ok(await h.tx({ type: 'expense', amountCents: 800, currency: 'EUR' }), '没挂账户的支出').transaction;
  assert.equal(plain.currency, 'EUR');
  const moved = ok(await h.a.patch(`/transactions/${plain.id}`, { accountId: h.cny.id }, h.auth), '挂到人民币账户').transaction;
  assert.equal(moved.currency, 'CNY', '换了账户，币种跟着新账户');
});

test('跨币种转账：要说到账多少；转出按原币扣、转入按到账金额加；同币种不存到账金额', async (t) => {
  const h = await setup(t);
  const base = { type: 'transfer', amountCents: 10000, accountId: h.usd.id, toAccountId: h.cny.id };
  const err = fail(await h.tx(base), 400, 'invalid_toAmountCents', '没填到账金额');
  assert.match(err.message, /USD → CNY/);

  const x = ok(await h.tx({ ...base, toAmountCents: 66940 }), '换汇 $100 → ¥669.40').transaction;
  assert.equal(x.currency, 'USD');
  assert.equal(x.toAmountCents, 66940);
  assert.equal(x.toCurrency, 'CNY');
  const o = await h.overview();
  assert.equal(balance(o, h.usd.id), 100000 - 10000, '美元户扣 $100');
  assert.equal(balance(o, h.cny.id), 1000000 + 66940, '人民币户加 ¥669.40，不是 ¥100');

  const same = ok(await h.tx({ type: 'transfer', amountCents: 500, accountId: h.usd.id, toAccountId: h.usdInvest.id, toAmountCents: 1 }), '同币种').transaction;
  assert.equal(same.toAmountCents, null, '同币种忽略到账金额');
  assert.equal(same.toCurrency, null);
});

test('板块余额按币种分开：美元支出挂在家庭公共上，就是家庭公共的美元少了', async (t) => {
  const h = await setup(t);
  ok(await h.tx({ type: 'expense', amountCents: 2000, accountId: h.usd.id, fundId: h.fund.id }), '美元支出');
  ok(await h.tx({ type: 'income', amountCents: 50000, accountId: h.cny.id, fundId: h.fund.id }), '人民币收入');
  const o = await h.overview();
  const f = o.funds.find((x) => x.fundId === h.fund.id);
  assert.deepEqual(f.balances, { CNY: 50000, USD: -2000 });
  const detail = ok(await h.a.get(`/stats/fund/${h.fund.id}`, h.auth), '板块详情');
  assert.deepEqual(detail.balances, { CNY: 50000, USD: -2000 });
});

test('币种锁：账户有流水就不能改币种；没流水可以；债务的币种只在新建时定', async (t) => {
  const h = await setup(t);
  ok(await h.tx({ type: 'expense', amountCents: 100, accountId: h.cny.id }), '记一笔');
  fail(await h.a.patch(`/accounts/${h.cny.id}`, { currency: 'USD' }, h.auth), 409, 'currency_locked', '有流水');
  const empty = ok(await h.a.post('/accounts', { name: '新卡', kind: 'bank' }, h.auth), 'POST 新卡').account;
  assert.equal(ok(await h.a.patch(`/accounts/${empty.id}`, { currency: 'HKD' }, h.auth), '没流水').account.currency, 'HKD');

  const debt = ok(await h.a.post('/debts', { direction: 'lend', counterparty: '张三', amountCents: 5000, currency: 'USD' }, h.auth), '美元债务').debt;
  assert.equal(debt.currency, 'USD');
  const inner = (await h.overview()).accounts.find((x) => x.accountId === debt.accountId);
  assert.equal(inner.currency, 'USD', '内部账户跟着债务的币种');
  fail(await h.a.patch(`/debts/${debt.id}`, { currency: 'CNY' }, h.auth), 400, 'invalid_currency', '改债务币种');
});

test('钱经过的真账户要同币种：美元债务不能从人民币卡走；持仓跟挂的账户；物品、会员费同理', async (t) => {
  const h = await setup(t);
  const { a, auth } = h;
  fail(
    await a.post('/debts', { direction: 'lend', counterparty: '张三', amountCents: 5000, currency: 'USD', recordTransaction: { accountId: h.cny.id } }, auth),
    400, 'currency_mismatch', '美元债务从人民币卡借出',
  );
  ok(await a.post('/debts', { direction: 'lend', counterparty: '张三', amountCents: 5000, currency: 'USD', recordTransaction: { accountId: h.usd.id } }, auth), '从美元户借出');

  const h1 = ok(await a.post('/holdings', {
    kind: 'stock', name: 'AAPL', quantityE4: 100000, costCents: 20000, accountId: h.usdInvest.id,
    recordTransaction: { fromAccountId: h.usd.id },
  }, auth), '挂美股户的持仓').holding;
  assert.equal(h1.currency, 'USD', '没说币种就跟挂的账户');
  fail(
    await a.post('/holdings', { kind: 'stock', name: 'X', quantityE4: 1, costCents: 100, currency: 'CNY', accountId: h.usdInvest.id, recordTransaction: { fromAccountId: h.usd.id } }, auth),
    400, 'currency_mismatch', '人民币持仓挂美元账户',
  );
  fail(
    await a.post('/holdings', { kind: 'stock', name: 'Y', quantityE4: 1, costCents: 100, accountId: h.usdInvest.id, recordTransaction: { fromAccountId: h.cny.id } }, auth),
    400, 'currency_mismatch', '成本从人民币卡转进美元户',
  );

  fail(
    await a.post('/assets', { name: '相机', category: 'digital', priceCents: 50000, purchasedOn: '2026-01-01', currency: 'USD', recordTransaction: { accountId: h.cny.id } }, auth),
    400, 'currency_mismatch', '美元买的东西从人民币卡出',
  );

  const tb = ok(await a.post('/platforms', { name: '淘宝' }, auth), 'POST 平台').platform;
  fail(
    await a.post('/memberships', { platformId: tb.id, name: '88VIP', feeCents: 8800, recordTransaction: { accountId: h.usd.id } }, auth),
    400, 'currency_mismatch', '会员费从美元户扣',
  );
});

test('总览 byCurrency：每个币种一份原生分项；全是 0 的币种不给', async (t) => {
  const h = await setup(t);
  ok(await h.tx({ type: 'expense', amountCents: 3000, accountId: h.usd.id }), '美元支出');
  const o = await h.overview();
  assert.equal(o.byCurrency.CNY.netWorthCents, 1000000);
  assert.equal(o.byCurrency.CNY.cashCents, 1000000);
  assert.equal(o.byCurrency.USD.netWorthCents, 100000 - 3000);
  assert.equal(o.byCurrency.USD.monthExpenseCents, 3000);
  assert.equal(o.byCurrency.CNY.monthExpenseCents, 0);
});
