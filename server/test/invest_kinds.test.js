'use strict';

// 理财分品类（lib/invest.js）：定期按天计息、活期按金额、份额类照旧；交易按品类走；
// 净资产分项（现金流 / 投资账户 / 投资补差）加起来等于不含实物的净资产。所有数字手算。

const test = require('node:test');
const assert = require('node:assert/strict');

const { household } = require('./fixtures');
const invest = require('../src/lib/invest');

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
  const bank = ok(await a.post('/accounts', { name: '招行卡', kind: 'bank', initialBalanceCents: 20000000 }, auth), 'POST 招行卡').account;
  const invAcct = ok(await a.post('/accounts', { name: '招行理财', kind: 'invest' }, auth), 'POST 招行理财').account;
  return {
    ...h, bank, invAcct,
    hold: (body) => a.post('/holdings', body, auth),
    patchHolding: (id, body) => a.patch(`/holdings/${id}`, body, auth),
    trade: (id, body) => a.post(`/holdings/${id}/trade`, body, auth),
    overview: async () => ok(await a.get('/stats/overview', auth), 'GET /stats/overview'),
    txs: async () => ok(await a.get('/transactions?limit=200', auth), 'GET /transactions').items,
  };
}

test('invest：按天单利、到期停止计息、估值按品类', () => {
  // 10 万 × 2.15% × 181 天 / 365 = 1066.164… → 106616 分
  assert.equal(invest.accruedCents(10000000, 21500, '2025-01-01', '2025-07-01'), 106616);
  assert.equal(invest.accruedCents(10000000, 21500, '2025-01-01', '2025-01-01'), 0, '起息当天不算');
  assert.equal(invest.accruedCents(10000000, 0, '2025-01-01', '2025-07-01'), 0);
  assert.equal(invest.accruedCents(10000000, 21500, '2025-07-01', '2025-01-01'), 0, '倒着的区间不算');

  const fixed = { kind: 'fixed', quantity_e4: 10000, cost_cents: 10000000, rate_e6: 21500, opened_on: '2025-01-01', matures_on: '2025-07-01', realized_cents: 0 };
  assert.equal(invest.valueOf(fixed, '2026-10-09'), 10106616, '到期后停在到期日');
  assert.equal(invest.valueOf({ ...fixed, realized_cents: 50000 }, '2026-10-09'), 10056616, '付出来的利息从估值里扣掉');
  assert.equal(invest.valueOf({ ...fixed, realized_cents: 200000 }, '2026-10-09'), 10000000, '扣到本金为止');
  assert.equal(invest.valueOf({ ...fixed, quantity_e4: 0 }, '2026-10-09'), 0, '结清了');
  assert.equal(invest.valueOf({ kind: 'demand', quantity_e4: 10000, cost_cents: 500, value_cents: null }, '2026-10-09'), 500, '没更新过按本金');
  assert.equal(invest.valueOf({ kind: 'demand', quantity_e4: 10000, cost_cents: 500, value_cents: 520 }, '2026-10-09'), 520);
  assert.equal(invest.valueOf({ kind: 'fund', quantity_e4: 30000000, cost_cents: 1, price_e4: null }, '2026-10-09'), null, '份额类没价格不知道值多少');
  assert.equal(invest.valueOf({ kind: 'fund', quantity_e4: 30000000, cost_cents: 1, price_e4: 5320 }, '2026-10-09'), 159600, '3000 份 × 0.5320');
  assert.equal(invest.kindOf({ market: 'fund' }), 'fund', '老行按市场推');
  assert.equal(invest.kindOf({ market: 'sh' }), 'stock');
});

test('定期：校验、没有单价和行情、到期停止计息、付息扣估值、到期一次结清', async (t) => {
  const h = await setup(t);
  const base = { kind: 'fixed', name: '招行半年定期', costCents: 10000000, rateE6: 21500, openedOn: '2025-01-01' };

  fail(await h.hold(base), 400, 'invalid_maturesOn', '没到期日');
  fail(await h.hold({ ...base, maturesOn: '2024-12-31' }), 400, 'invalid_maturesOn', '到期早于起息');
  fail(await h.hold({ ...base, maturesOn: '2025-07-01', rateE6: 1000001 }), 400, 'invalid_rateE6', '年化超过 100%');
  fail(await h.hold({ ...base, maturesOn: '2025-07-01', costCents: 0 }), 400, 'invalid_costCents', '定期没有本金');
  fail(await h.hold({ ...base, maturesOn: '2025-07-01', priceSource: 'auto', code: '161725' }), 400, 'invalid_priceSource', '定期没有行情');

  const created = ok(await h.hold({ ...base, maturesOn: '2025-07-01', institution: '招商银行' }), 'POST 定期').holding;
  assert.equal(created.kind, 'fixed');
  assert.equal(created.quantityE4, 10000, '非份额类记一份');
  assert.equal(created.market, 'other');
  assert.equal(created.priceE4, null);
  assert.equal(created.institution, '招商银行');
  assert.equal(created.maturesOn, '2025-07-01');

  fail(await h.patchHolding(created.id, { priceE4: 10000 }), 400, 'invalid_priceE4', '定期没有单价');
  fail(await h.patchHolding(created.id, { kind: 'stock' }), 400, 'invalid_kind', '换记法');
  const asBond = ok(await h.patchHolding(created.id, { kind: 'bond' }), 'PATCH 换成国债').holding;
  assert.equal(asBond.kind, 'bond', '同一种记法里可以换');

  let o = await h.overview();
  assert.deepEqual(o.investByKind, [{ kind: 'bond', valueCents: 10106616, costCents: 10000000, count: 1 }]);
  assert.equal(o.investNetCents, 10106616, '没挂账户：整份估值算进净资产');

  fail(await h.trade(created.id, { side: 'buy', amountCents: 100 }), 400, 'deposit_no_topup', '定期不能追加');
  ok(await h.trade(created.id, { side: 'income', amountCents: 50000, recordTransaction: { accountId: h.bank.id } }), '付息');
  o = await h.overview();
  assert.equal(o.investByKind[0].valueCents, 10056616, '付出来的 500 从估值里扣掉');
  const interest = (await h.txs()).find((x) => x.merchant === '利息 招行半年定期');
  assert.ok(interest, '付息记了一笔收入');
  assert.equal(interest.type, 'income');
  assert.equal(interest.amountCents, 50000);
  assert.equal(interest.accountId, h.bank.id);

  const done = ok(await h.trade(created.id, { side: 'sell', amountCents: 10056616 }), '到期结清').holding;
  assert.equal(done.quantityE4, 0);
  assert.equal(done.costCents, 0);
  assert.equal(done.realizedCents, 106616, '利息合计 = 付息 + 到期多拿的');
  fail(await h.trade(created.id, { side: 'sell', amountCents: 1 }), 400, 'insufficient_value', '结清了再取');
  o = await h.overview();
  assert.deepEqual(o.investByKind, [], '结清了不算');
});

test('活期：更新金额、存入、按比例取出、取完清仓；结构性存款按保底计息', async (t) => {
  const h = await setup(t);
  const yeb = ok(await h.hold({ kind: 'demand', name: '余额宝', costCents: 1000000, rateE6: 18000 }), 'POST 余额宝').holding;
  assert.equal(yeb.valueCents, null, '没更新过 = 按本金');
  fail(await h.patchHolding(yeb.id, { valueCents: -1 }), 400, 'invalid_valueCents', '负金额');
  const updated = ok(await h.patchHolding(yeb.id, { valueCents: 1010000 }), 'PATCH 更新金额').holding;
  assert.equal(updated.valueCents, 1010000);
  assert.match(updated.valueOn, /^\d{4}-\d{2}-\d{2}$/);

  let r = ok(await h.trade(yeb.id, { side: 'buy', amountCents: 100000 }), '存入').holding;
  assert.equal(r.costCents, 1100000);
  assert.equal(r.valueCents, 1110000);
  // 取 5550：摊本金 round(1100000 × 555000 / 1110000) = 550000，收益 5000
  r = ok(await h.trade(yeb.id, { side: 'sell', amountCents: 555000 }), '取出一半').holding;
  assert.equal(r.costCents, 550000);
  assert.equal(r.valueCents, 555000);
  assert.equal(r.realizedCents, 5000);
  fail(await h.trade(yeb.id, { side: 'sell', amountCents: 555001 }), 400, 'insufficient_value', '取超了');
  r = ok(await h.trade(yeb.id, { side: 'sell', amountCents: 555000 }), '取完').holding;
  assert.equal(r.quantityE4, 0);
  assert.equal(r.costCents, 0);
  assert.equal(r.valueCents, 0);
  assert.equal(r.realizedCents, 10000);

  fail(
    await h.hold({ kind: 'structured', name: '结构性', costCents: 10000000, rateE6: 30000, rateMaxE6: 15000, openedOn: '2025-01-01', maturesOn: '2025-07-01' }),
    400, 'invalid_rateMaxE6', '最高低于保底',
  );
  const sd = ok(await h.hold({ kind: 'structured', name: '结构性', costCents: 10000000, rateE6: 21500, rateMaxE6: 35000, openedOn: '2025-01-01', maturesOn: '2025-07-01' }), 'POST 结构性').holding;
  assert.equal(sd.rateMaxE6, 35000);
  const o = await h.overview();
  assert.deepEqual(o.investByKind, [{ kind: 'structured', valueCents: 10106616, costCents: 10000000, count: 1 }], '按保底年化计息');
});

test('分红：份额类记已实现收益和一笔收入，份额成本不动；老 App 只发 market 也能建', async (t) => {
  const h = await setup(t);
  const fund = ok(await h.hold({ name: '白酒', code: '161725', market: 'fund', quantityE4: 30000000, costCents: 1000000 }), '老客户端').holding;
  assert.equal(fund.kind, 'fund', '没给 kind 按市场推');
  fail(await h.trade(fund.id, { side: 'income', amountCents: 0 }), 400, 'invalid_amountCents', '分红 0 元');
  const r = ok(await h.trade(fund.id, { side: 'income', amountCents: 12000, recordTransaction: { accountId: h.bank.id } }), '分红');
  assert.equal(r.holding.quantityE4, 30000000);
  assert.equal(r.holding.costCents, 1000000);
  assert.equal(r.holding.realizedCents, 12000);
  assert.equal(r.transactions.length, 1);
  assert.equal(r.transactions[0].merchant, '分红 白酒');
  assert.equal(r.transactions[0].type, 'income');
});

test('净资产分项：现金流 + 投资账户 + 投资补差 = 不含实物的净资产；挂账户的定期只补利息', async (t) => {
  const h = await setup(t);
  ok(await h.hold({
    kind: 'fixed', name: '定期', costCents: 10000000, rateE6: 21500, openedOn: '2025-01-01', maturesOn: '2025-07-01',
    accountId: h.invAcct.id, recordTransaction: { fromAccountId: h.bank.id },
  }), 'POST 挂账户的定期');
  const o = await h.overview();
  // 招行卡 20 万 − 转出 10 万 = 10 万（再加上 fixtures 默认账户的 0）
  assert.equal(o.investAccountsCents, 10000000, '成本转进了投资账户');
  assert.equal(o.investNetCents, 106616, '挂账户：只补利息');
  assert.equal(o.cashCents + o.investAccountsCents + o.investNetCents, o.netWorthExPhysicalCents);
  assert.equal(o.cashCents, 10000000);
});
