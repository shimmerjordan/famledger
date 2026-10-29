'use strict';

// 股票账户（modules/accounts.js kind = 'stock'）：整户记一个市值，余额是投入，浮盈 = 市值 − 余额；
// 历次市值同一天覆盖、老的在前、最多 200 条；逐只记的持仓经 POST /accounts/:id/absorb 并进来。
// 所有数字手算。

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

/** 服务端和这里都钉在 Asia/Shanghai（helpers.js），今天 ± n 天的本地日期。 */
function dayShift(n) {
  const d = new Date();
  d.setDate(d.getDate() + n);
  const p = (x) => String(x).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

async function setup(t) {
  const h = await household(t);
  const { a, auth } = h;
  return {
    ...h,
    account: (body) => a.post('/accounts', body, auth),
    patchAccount: (id, body) => a.patch(`/accounts/${id}`, body, auth),
    accounts: async () => ok(await a.get('/accounts?archived=1', auth), 'GET /accounts').items,
    absorb: (id, body) => a.post(`/accounts/${id}/absorb`, body, auth),
    hold: (body) => a.post('/holdings', body, auth),
    patchHolding: (id, body) => a.patch(`/holdings/${id}`, body, auth),
    holdings: async (archived = false) => ok(await a.get(`/holdings${archived ? '?archived=1' : ''}`, auth), 'GET /holdings').items,
    overview: async () => ok(await a.get('/stats/overview', auth), 'GET /stats/overview'),
    txs: async () => ok(await a.get('/transactions?limit=200', auth), 'GET /transactions').items,
  };
}

const balanceOf = (o, id) => o.accounts.find((x) => x.accountId === id)?.balanceCents;

test('股票账户：市值进理财分项、转入是投入、改市值留记录、改类型清市值、同步带 valueLog', async (t) => {
  const h = await setup(t);
  const today = dayShift(0);
  const yesterday = dayShift(-1);

  const bank = ok(await h.account({ name: '招行卡', kind: 'bank', initialBalanceCents: 1000000 }), 'POST 招行卡').account;
  const created = await h.account({ name: '华泰证券', kind: 'stock', initialBalanceCents: 100000, valueCents: 120000 });
  assert.equal(created.status, 201, created.text);
  const stock = created.json.account;
  assert.equal(stock.kind, 'stock');
  assert.equal(stock.initialBalanceCents, 100000);
  assert.equal(stock.valueCents, 120000);
  assert.equal(stock.valueOn, today, '没给日期就是今天');
  assert.deepEqual(stock.valueLog, [{ on: today, valueCents: 120000 }]);

  // 投入 1000.00、市值 1200.00：浮盈 200.00 补进资产；现金流不含它。
  let o = await h.overview();
  assert.deepEqual(o.accounts.find((x) => x.accountId === stock.id), { accountId: stock.id, currency: 'CNY', balanceCents: 100000 });
  assert.equal(o.investAccountsCents, 100000);
  assert.equal(o.investNetCents, 20000);
  assert.equal(o.investMarketCents, 120000);
  assert.equal(o.investCostCents, 100000);
  assert.equal(o.investGainCents, 20000);
  assert.equal(o.cashCents, 1000000, '证券户里的钱不算现金流');
  assert.equal(o.assetsCents, 1120000, '招行 10000 + 投入 1000 + 浮盈 200');
  assert.equal(o.liabilitiesCents, 0);
  assert.equal(o.netWorthCents, 1120000);
  assert.equal(o.netWorthExPhysicalCents, 1120000);
  assert.deepEqual(o.investByKind, [{ kind: 'stock', valueCents: 120000, costCents: 100000, count: 1 }]);
  const cny = o.byCurrency.CNY;
  assert.equal(cny.investAccountsCents, 100000);
  assert.equal(cny.investNetCents, 20000);
  assert.equal(cny.investMarketCents, 120000);
  assert.equal(cny.investCostCents, 100000);
  assert.equal(cny.cashCents, 1000000);
  assert.equal(cny.assetsCents, 1120000);
  assert.equal(cny.netWorthCents, 1120000);

  // 转 500.00 进去 = 投入变 1500.00；市值没改，浮盈变成 −300.00。
  ok(await h.tx({ type: 'transfer', amountCents: 50000, accountId: bank.id, toAccountId: stock.id, occurredAt: '2026-10-20T12:00:00+08:00' }), '转入股票账户');
  o = await h.overview();
  assert.equal(balanceOf(o, stock.id), 150000);
  assert.equal(o.investAccountsCents, 150000);
  assert.equal(o.investNetCents, -30000);
  assert.equal(o.investMarketCents, 120000);
  assert.equal(o.investCostCents, 150000);
  assert.equal(o.cashCents, 950000);
  assert.equal(o.assetsCents, 1070000, '950000 + 150000 − 30000');
  assert.equal(o.netWorthCents, 1070000);
  assert.equal(o.byCurrency.CNY.investNetCents, -30000);
  assert.deepEqual(o.investByKind, [{ kind: 'stock', valueCents: 120000, costCents: 150000, count: 1 }]);

  // 补昨天的市值：多一条，老的在前；「当前市值」还是最新那天（今天）的；今天再改一次是覆盖，不加条。
  let acct = ok(await h.patchAccount(stock.id, { valueCents: 200000, valueOn: yesterday }), 'PATCH 昨天的市值').account;
  assert.equal(acct.valueCents, 120000, '补以前的日子不改当前市值');
  assert.equal(acct.valueOn, today);
  assert.deepEqual(acct.valueLog, [{ on: yesterday, valueCents: 200000 }, { on: today, valueCents: 120000 }]);
  acct = ok(await h.patchAccount(stock.id, { valueCents: 210000 }), 'PATCH 今天的市值').account;
  assert.equal(acct.valueOn, today);
  assert.deepEqual(acct.valueLog, [{ on: yesterday, valueCents: 200000 }, { on: today, valueCents: 210000 }], '同一天覆盖');
  o = await h.overview();
  assert.equal(o.investMarketCents, 210000);
  assert.equal(o.investNetCents, 60000);
  assert.equal(o.netWorthCents, 1160000, '950000 + 150000 + 60000');

  // 市值只有股票账户记；日期不能单独给、不能是将来；债务的内部账户照旧不收。
  fail(await h.account({ name: '工资卡', kind: 'bank', valueCents: 1 }), 400, 'invalid_valueCents', '新建银行卡带市值');
  fail(await h.account({ name: '理财户', kind: 'invest', valueCents: 1 }), 400, 'invalid_valueCents', '投资账户带市值');
  fail(await h.patchAccount(bank.id, { valueCents: 1 }), 400, 'invalid_valueCents', '银行卡改市值');
  fail(await h.patchAccount(bank.id, { valueOn: today }), 400, 'invalid_valueCents', '银行卡给市值日期');
  fail(await h.patchAccount(stock.id, { valueOn: today }), 400, 'invalid_valueOn', '只给日期不给市值');
  fail(await h.patchAccount(stock.id, { valueCents: 1, valueOn: dayShift(1) }), 400, 'invalid_valueOn', '将来的日期');
  fail(await h.patchAccount(stock.id, { valueCents: 1, valueOn: '2026-02-30' }), 400, 'invalid_valueOn', '不存在的日期');
  fail(await h.patchAccount(stock.id, { valueCents: -1 }), 400, 'invalid_valueCents', '负的市值');
  fail(await h.patchAccount(stock.id, { valueCents: 1.5 }), 400, 'invalid_valueCents', '不是整数');
  const debt = ok(await h.a.post('/debts', { direction: 'lend', counterparty: '张三', amountCents: 100 }, h.auth), 'POST 债务').debt;
  fail(await h.patchAccount(debt.accountId, { valueCents: 1 }), 400, 'invalid_valueCents', '债务的内部账户');
  acct = (await h.accounts()).find((x) => x.id === stock.id);
  assert.equal(acct.valueCents, 210000, '失败的请求什么都不改');
  assert.equal(acct.valueLog.length, 2);

  // 改成别的类型：市值、日期清掉，历次记录留着；钱变成现金流。
  acct = ok(await h.patchAccount(stock.id, { kind: 'bank' }), 'PATCH 改成银行卡').account;
  assert.equal(acct.valueCents, null);
  assert.equal(acct.valueOn, null);
  assert.deepEqual(acct.valueLog, [{ on: yesterday, valueCents: 200000 }, { on: today, valueCents: 210000 }]);
  o = await h.overview();
  assert.equal(o.cashCents, 1100000);
  assert.equal(o.investAccountsCents, 0);
  assert.equal(o.investNetCents, 0);
  assert.equal(o.investMarketCents, 0);
  assert.deepEqual(o.investByKind, []);
  assert.equal(o.netWorthCents, 1100100, '1100000 + 上面借出去的 1.00（计入的应收）');
  assert.equal(o.byCurrency.CNY.cashCents, 1100000);

  // 改回股票账户：没市值就按投入算，不多算也不少算。
  acct = ok(await h.patchAccount(stock.id, { kind: 'stock' }), 'PATCH 改回股票账户').account;
  assert.equal(acct.valueCents, null);
  o = await h.overview();
  assert.equal(o.investAccountsCents, 150000);
  assert.equal(o.investNetCents, 0);
  assert.equal(o.investMarketCents, 0);
  assert.equal(o.investCostCents, 0);
  assert.equal(o.cashCents, 950000);
  assert.equal(o.netWorthCents, 1100100);
  assert.deepEqual(o.investByKind, [{ kind: 'stock', valueCents: 150000, costCents: 150000, count: 1 }], '没市值的按投入当估值');

  // 再填一次今天的市值是覆盖；传 null 清掉市值，记录还在；改类型时顺手传 null 也不报错。
  acct = ok(await h.patchAccount(stock.id, { valueCents: 160000 }), 'PATCH 市值').account;
  assert.deepEqual(acct.valueLog, [{ on: yesterday, valueCents: 200000 }, { on: today, valueCents: 160000 }]);
  acct = ok(await h.patchAccount(stock.id, { valueCents: null }), 'PATCH 清掉市值').account;
  assert.equal(acct.valueCents, null);
  assert.equal(acct.valueOn, null);
  assert.equal(acct.valueLog.length, 2);
  o = await h.overview();
  assert.equal(o.investNetCents, 0);
  assert.equal(o.investMarketCents, 0);
  ok(await h.patchAccount(stock.id, { kind: 'bank', valueCents: null }), 'PATCH 改类型顺手传 null');
  ok(await h.patchAccount(stock.id, { kind: 'stock' }), '改回来');

  // 列表和同步都带 valueLog 数组。
  const listed = (await h.accounts()).find((x) => x.id === stock.id);
  assert.ok(Array.isArray(listed.valueLog));
  assert.equal(listed.valueLog.length, 2);
  const changes = ok(await h.a.get('/changes?since=0', h.auth), 'GET /changes');
  const synced = changes.accounts.find((x) => x.id === stock.id);
  assert.equal(synced.kind, 'stock');
  assert.equal(synced.valueCents, null);
  assert.deepEqual(synced.valueLog, listed.valueLog);
  assert.equal(synced.archived, false);
});

test('股票账户：历次市值按日期排、最多留 200 条', async (t) => {
  const h = await setup(t);
  const stock = ok(await h.account({ name: '东财证券', kind: 'stock' }), 'POST 股票账户').account;
  assert.equal(stock.valueCents, null);
  assert.deepEqual(stock.valueLog, []);

  // 从 200 天前记到今天，201 条；只留最近 200 条，最老的那天掉了。
  let acct = null;
  for (let i = 200; i >= 0; i--) {
    acct = ok(await h.patchAccount(stock.id, { valueCents: 1000 + i, valueOn: dayShift(-i) }), `PATCH 第 ${i} 天`).account;
  }
  assert.equal(acct.valueCents, 1000);
  assert.equal(acct.valueOn, dayShift(0));
  assert.equal(acct.valueLog.length, 200);
  assert.deepEqual(acct.valueLog[0], { on: dayShift(-199), valueCents: 1199 }, '老的在前，第 201 条把最老的挤掉');
  assert.deepEqual(acct.valueLog[199], { on: dayShift(0), valueCents: 1000 });
  for (let i = 1; i < acct.valueLog.length; i++) {
    assert.ok(acct.valueLog[i - 1].on < acct.valueLog[i].on, '按日期升序');
  }
});

test('absorb：挂账户的记移仓转账、没挂的改期初、归档；校验与幂等', async (t) => {
  const h = await setup(t);
  const today = dayShift(0);

  const bank = ok(await h.account({ name: '招行卡', kind: 'bank', initialBalanceCents: 10000000 }), 'POST 招行卡').account;
  const invest = ok(await h.account({ name: '证券账户', kind: 'invest' }), 'POST 证券账户').account;
  const invest2 = ok(await h.account({ name: '老券商', kind: 'invest' }), 'POST 老券商').account;
  const stock = ok(await h.account({ name: '股票账户', kind: 'stock' }), 'POST 股票账户').account;
  const stock2 = ok(await h.account({ name: '另一个股票账户', kind: 'stock' }), 'POST 另一个股票账户').account;

  // 挂着活的投资账户的基金：成本 10000.00 已经以转账形式在证券账户里。
  const fund = ok(await h.hold({
    name: '白酒基金', code: '161725', market: 'fund', quantityE4: 30000000, costCents: 1000000,
    accountId: invest.id, openedOn: '2026-09-01', recordTransaction: { fromAccountId: bank.id },
  }), 'POST 开仓').holding;
  ok(await h.patchHolding(fund.id, { priceE4: 3500 }), 'PATCH 手动价');
  // 没挂账户的股票：成本 150000.00 以前不在任何账户的余额里。
  const stk = ok(await h.hold({ name: '贵州茅台', code: '600519', market: 'sh', quantityE4: 1000000, costCents: 15000000 }), 'POST 股票').holding;
  // 挂的账户后来删了（没流水才删得掉，成本是校准上去的）：和没挂一样，成本不在任何余额里。
  const old = ok(await h.hold({ name: '老券商的票', quantityE4: 10000, costCents: 0, accountId: invest2.id }), 'POST 老持仓').holding;
  ok(await h.patchHolding(old.id, { costCents: 200000 }), 'PATCH 校准成本');
  ok(await h.a.del(`/accounts/${invest2.id}`, h.auth), 'DELETE 老券商');
  const archived = ok(await h.hold({ name: '早就归档的', quantityE4: 100, costCents: 100 }), 'POST 归档持仓').holding;
  ok(await h.patchHolding(archived.id, { archived: true }), 'PATCH 归档');
  const usd = ok(await h.hold({ name: '美股', code: 'AAPL', market: 'other', quantityE4: 10000, costCents: 100000, currency: 'USD' }), 'POST 美股').holding;

  let o = await h.overview();
  assert.equal(balanceOf(o, bank.id), 9000000);
  assert.equal(balanceOf(o, invest.id), 1000000);
  assert.equal(balanceOf(o, stock.id), 0);
  // 3000 份 × 0.3500 = 1050.00，挂账户的只补浮盈：1050 − 10000 = −8950.00
  // 两个空的股票账户也各占一条（没钱、没市值就是 0）。
  assert.deepEqual(o.investByKind, [
    { kind: 'fund', valueCents: 105000, costCents: 1000000, count: 1 },
    { kind: 'stock', valueCents: 0, costCents: 0, count: 2 },
  ]);
  assert.equal(o.netWorthCents, 9105000, '9000000 + 1000000 − 895000');
  const txCount = (await h.txs()).length;
  assert.equal(txCount, 1);

  // 校验：只能并进股票账户；持仓要在、未归档、同币种；日期不能单独给。失败什么都不动。
  fail(await h.absorb(bank.id, { holdingIds: [fund.id] }), 400, 'invalid_accountId', '并进银行卡');
  fail(await h.absorb(invest.id, { holdingIds: [fund.id] }), 400, 'invalid_accountId', '并进投资账户');
  fail(await h.absorb('nope', { holdingIds: [fund.id] }), 400, 'invalid_accountId', '账户不存在');
  fail(await h.absorb(stock.id, {}), 400, 'invalid_holdingIds', '没给持仓');
  fail(await h.absorb(stock.id, { holdingIds: [] }), 400, 'invalid_holdingIds', '空列表');
  fail(await h.absorb(stock.id, { holdingIds: 'x' }), 400, 'invalid_holdingIds', '不是数组');
  fail(await h.absorb(stock.id, { holdingIds: ['nope'] }), 400, 'invalid_holdingIds', '持仓不存在');
  fail(await h.absorb(stock.id, { holdingIds: [archived.id] }), 400, 'invalid_holdingIds', '已归档');
  fail(await h.absorb(stock.id, { holdingIds: [usd.id] }), 400, 'currency_mismatch', '币种不同');
  fail(await h.absorb(stock.id, { holdingIds: [fund.id], valueOn: today }), 400, 'invalid_valueOn', '只给日期');
  fail(await h.absorb(stock.id, { holdingIds: [fund.id], valueCents: -1 }), 400, 'invalid_valueCents', '负的市值');
  fail(await h.absorb(stock.id, { holdingIds: [fund.id, usd.id], valueCents: 100 }), 400, 'currency_mismatch', '一只不同币种整批失败');
  assert.equal((await h.holdings()).find((x) => x.id === fund.id).archived, false, '失败的那批一只都没归档');
  assert.equal((await h.txs()).length, txCount, '失败的那批没记转账');
  assert.equal(balanceOf(await h.overview(), stock.id), 0);

  const res = await h.absorb(stock.id, { holdingIds: [fund.id, stk.id, old.id], valueCents: 17000000, clientId: 'ab1' });
  assert.equal(res.status, 200, res.text);
  const out = res.json;
  assert.equal(out.replayed, undefined);
  assert.equal(out.account.id, stock.id);
  assert.equal(out.account.initialBalanceCents, 15200000, '没挂的 150000.00 + 挂的账户已删的 2000.00 进期初');
  assert.equal(out.account.valueCents, 17000000);
  assert.equal(out.account.valueOn, today);
  assert.deepEqual(out.account.valueLog, [{ on: today, valueCents: 17000000 }]);
  assert.equal(out.holdings.length, 3);
  const byId = Object.fromEntries(out.holdings.map((x) => [x.id, x]));
  for (const x of out.holdings) assert.equal(x.archived, true, `${x.name} 归档`);
  assert.equal(byId[fund.id].costCents, 1000000, '成本不动');
  assert.equal(byId[fund.id].quantityE4, 30000000, '份额不动');
  assert.equal(byId[fund.id].realizedCents, 0);
  assert.equal(byId[stk.id].costCents, 15000000);
  assert.equal(byId[old.id].costCents, 200000);
  assert.equal(out.transactions.length, 1, '只有挂着活账户的那只记转账');
  const moved = out.transactions[0];
  assert.equal(moved.type, 'transfer');
  assert.equal(moved.amountCents, 1000000);
  assert.equal(moved.accountId, invest.id);
  assert.equal(moved.toAccountId, stock.id);
  assert.equal(moved.merchant, '移仓 白酒基金');
  assert.equal(moved.occurredAt, `${today}T12:00:00+08:00`);
  assert.equal(moved.source, 'manual');
  assert.equal(moved.status, 'confirmed');

  o = await h.overview();
  assert.equal(balanceOf(o, invest.id), 0, '证券账户的成本转走了');
  assert.equal(balanceOf(o, stock.id), 16200000, '期初 152000.00 + 移仓 10000.00');
  assert.equal(balanceOf(o, bank.id), 9000000);
  assert.equal(o.investAccountsCents, 16200000);
  assert.equal(o.investMarketCents, 17000000, '市值就是传进来的');
  assert.equal(o.investCostCents, 16200000);
  assert.equal(o.investNetCents, 800000);
  assert.equal(o.cashCents, 9000000);
  assert.equal(o.assetsCents, 26000000, '9000000 + 16200000 + 800000');
  assert.equal(o.netWorthCents, 26000000);
  assert.deepEqual(o.investByKind, [{ kind: 'stock', valueCents: 17000000, costCents: 16200000, count: 2 }], '归档的持仓不再逐只算；另一个空户仍占一条');

  // 幂等：重发回放同一份响应，转账不记第二遍。
  const again = await h.absorb(stock.id, { holdingIds: [fund.id, stk.id, old.id], valueCents: 17000000, clientId: 'ab1' });
  assert.equal(again.status, 200, again.text);
  assert.equal(again.json.replayed, true);
  assert.deepEqual({ ...again.json, replayed: undefined }, { ...out, replayed: undefined });
  assert.equal((await h.txs()).filter((x) => x.merchant === '移仓 白酒基金').length, 1);
  assert.equal(balanceOf(await h.overview(), stock.id), 16200000);
  fail(await h.absorb(stock2.id, { holdingIds: [archived.id], clientId: 'ab1' }), 409, 'client_id_reused', 'clientId 用到别的账户上');
  fail(await h.absorb(stock.id, { holdingIds: [fund.id] }), 400, 'invalid_holdingIds', '并过的已经归档，不能再并');

  const live = await h.holdings();
  assert.ok(!live.some((x) => [fund.id, stk.id, old.id].includes(x.id)), '默认列表不含并进去的');
  const all = await h.holdings(true);
  assert.deepEqual(all.filter((x) => x.archived).map((x) => x.id).sort(), [archived.id, fund.id, old.id, stk.id].sort());
  const changes = ok(await h.a.get('/changes?since=0', h.auth), 'GET /changes');
  assert.equal(changes.holdings.find((x) => x.id === fund.id).archived, true, '归档同步出去');
  assert.equal(changes.accounts.find((x) => x.id === stock.id).initialBalanceCents, 15200000);

  // 不给市值：账户照样按投入算；没挂账户的成本只进期初，不记转账。
  const h2 = ok(await h.hold({ name: '另一只', quantityE4: 100, costCents: 5000 }), 'POST 另一只').holding;
  const out2 = ok(await h.absorb(stock2.id, { holdingIds: [h2.id] }), 'absorb 不给市值');
  assert.equal(out2.account.valueCents, null);
  assert.equal(out2.account.initialBalanceCents, 5000);
  assert.deepEqual(out2.account.valueLog, []);
  assert.deepEqual(out2.transactions, []);
  assert.equal(out2.holdings[0].archived, true);
  o = await h.overview();
  assert.equal(balanceOf(o, stock2.id), 5000);
  assert.equal(o.investAccountsCents, 16205000);
  assert.equal(o.investMarketCents, 17000000, '没市值的那户不进市值');
  assert.equal(o.investNetCents, 800000);
  assert.deepEqual(o.investByKind, [{ kind: 'stock', valueCents: 17005000, costCents: 16205000, count: 2 }]);
  assert.equal(o.netWorthCents, 26005000);
});

test('挂着持仓的投资账户不能改类型（409 holdings_attached），持仓并走后才行；补记以前的市值不改当前市值', async (t) => {
  const h = await setup(t);
  const today = dayShift(0);
  const bank = ok(await h.account({ name: '招行卡', kind: 'bank', initialBalanceCents: 10000000 }), 'POST 招行卡').account;
  const invest = ok(await h.account({ name: '证券户', kind: 'invest' }), 'POST 证券户').account;
  // 100 股、成本 1000.00、手动价 12.0000 → 市值 1200.00；挂着证券户，成本已经以转账形式在它的余额里。
  const stk = ok(await h.hold({
    name: '贵州茅台', code: '600519', market: 'sh', quantityE4: 1000000, costCents: 100000,
    accountId: invest.id, openedOn: '2026-09-01', recordTransaction: { fromAccountId: bank.id },
  }), 'POST 持仓').holding;
  ok(await h.patchHolding(stk.id, { priceE4: 120000 }), 'PATCH 手动价');
  let o = await h.overview();
  assert.equal(o.investNetCents, 20000, '挂了账户的持仓只补浮盈 1200 − 1000');

  fail(await h.patchAccount(invest.id, { kind: 'stock', valueCents: 120000 }), 409, 'holdings_attached', '挂着持仓改成股票账户');
  fail(await h.patchAccount(invest.id, { kind: 'bank' }), 409, 'holdings_attached', '改成银行卡也不行');
  ok(await h.patchAccount(invest.id, { name: '证券户（改名）' }), 'PATCH 不动类型照常');
  o = await h.overview();
  assert.equal(o.investNetCents, 20000, '没被算两遍');

  // 并进股票账户（持仓归档）之后就能改了；浮盈还是只算一次。
  const stock = ok(await h.account({ name: '华泰', kind: 'stock' }), 'POST 华泰').account;
  ok(await h.absorb(stock.id, { holdingIds: [stk.id], valueCents: 120000 }), 'absorb');
  ok(await h.patchAccount(invest.id, { kind: 'bank' }), '持仓归档后改类型');
  o = await h.overview();
  assert.equal(balanceOf(o, invest.id), 0, '成本移仓走了');
  assert.equal(balanceOf(o, stock.id), 100000);
  assert.equal(o.investNetCents, 20000, '市值 1200 − 投入 1000');

  // 补记以前的市值：记录多一条，当前市值还是最新那天的；absorb 带的旧日期也一样。
  const acct = ok(await h.patchAccount(stock.id, { valueCents: 90000, valueOn: dayShift(-3) }), 'PATCH 三天前').account;
  assert.equal(acct.valueCents, 120000);
  assert.equal(acct.valueOn, today);
  assert.deepEqual(acct.valueLog, [{ on: dayShift(-3), valueCents: 90000 }, { on: today, valueCents: 120000 }]);
  assert.equal((await h.overview()).investNetCents, 20000, '总览也不跟着旧数走');
  const stk2 = ok(await h.hold({ name: '没挂账户的', quantityE4: 10000, costCents: 5000 }), 'POST 持仓 2').holding;
  const out = ok(await h.absorb(stock.id, { holdingIds: [stk2.id], valueCents: 1, valueOn: dayShift(-2) }), 'absorb 带旧日期');
  assert.equal(out.account.valueCents, 120000, '当前市值不被旧日期的数盖掉');
  assert.equal(out.account.valueOn, today);
  assert.deepEqual(out.account.valueLog.map((e) => e.on), [dayShift(-3), dayShift(-2), today]);
});

test('归档的股票账户：投入还算钱，旧市值不再补浮盈、不进 investByKind；恢复了又算回来', async (t) => {
  const h = await setup(t);
  const stock = ok(await h.account({ name: '老券商', kind: 'stock', initialBalanceCents: 100000, valueCents: 150000 }), 'POST 老券商').account;
  let o = await h.overview();
  assert.equal(o.investNetCents, 50000);
  assert.equal(o.netWorthCents, 150000);
  assert.equal(o.investByKind.length, 1);

  ok(await h.patchAccount(stock.id, { archived: true }), 'PATCH 归档');
  o = await h.overview();
  assert.equal(o.investAccountsCents, 100000, '投入和别的归档账户一样还在');
  assert.equal(o.investMarketCents, 0);
  assert.equal(o.investNetCents, 0);
  assert.deepEqual(o.investByKind, []);
  assert.equal(o.netWorthCents, 100000);

  ok(await h.patchAccount(stock.id, { archived: false }), 'PATCH 恢复');
  assert.equal((await h.overview()).investNetCents, 50000);
});
