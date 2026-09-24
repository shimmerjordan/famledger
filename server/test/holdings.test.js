'use strict';

// 投资持仓。钉死的是钱的口径：移动平均成本、卖出盈亏、「同时记账」记成哪几笔、
// 净资产怎么把持仓算进去；以及行情刷新的三条底线 —— 基金和股票两个批次互不连累、
// 拉不到不清旧价、全局节流。所有数字都是手算好的常量。

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');

const { household } = require('./fixtures');
const quotes = require('../src/lib/quotes');

// 腾讯行情是 GBK 文本，Node 没有 GBK 编码器，这几个名字的字节是用 python3 的 str.encode('gbk') 生成的。
const GBK = {
  贵州茅台: Buffer.from('b9f3d6ddc3a9cca8', 'hex'),
  平安银行: Buffer.from('c6bdb0b2d2f8d0d0', 'hex'),
  招商中证白酒指数A: Buffer.from('d5d0c9ccd6d0d6a4b0d7bec6d6b8cafd41', 'hex'),
  易方达蓝筹精选混合: Buffer.from('d2d7b7bdb4efc0b6b3efbeabd1a1bbecbacf', 'hex'),
  长: Buffer.from('b3a4', 'hex'),
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function ok(r, what) {
  assert.ok(r.status >= 200 && r.status < 300, `${what} → ${r.status} ${r.text}`);
  return r.json;
}

function fail(r, status, code, what) {
  assert.equal(r.status, status, `${what} → ${r.status} ${r.text}`);
  assert.equal(r.json.error.code, code, `${what} 的错误码`);
}

/**
 * 假腾讯行情（GBK），只认 `/q=符号,符号…`，基金（jj）和股票都从这里来。
 * `funds[code]` 是 `{ name: GBK Buffer 或 ASCII 串, nav, pct }`，或 'zero'（净值 0.0000）；
 * `stocks[symbol]` 是 `[名称 Buffer, 现价, 昨收]`；没有的代码按腾讯的样子回 `v_pv_none_match`。
 * `batchFault[前缀]` 为 'fail'（回 500）/ 'hang'（不回），按请求里第一个符号的前缀让整批出错。
 */
async function startFakeQuotes() {
  const state = { funds: {}, stocks: {}, batchFault: {}, requests: [] };
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://x');
    state.requests.push(url.pathname);
    if (!url.pathname.startsWith('/q=')) {
      res.writeHead(404);
      return res.end();
    }
    const symbols = url.pathname.slice(3).split(',');
    const fault = state.batchFault[symbols[0].slice(0, 2)];
    if (fault === 'hang') return;
    if (fault === 'fail') {
      res.writeHead(500);
      return res.end('nope');
    }
    const parts = [];
    for (const sym of symbols) {
      const code = sym.slice(2);
      const f = sym.startsWith('jj') ? state.funds[code] : undefined;
      const s = state.stocks[sym];
      if (f === 'zero') {
        parts.push(Buffer.from(`v_${sym}="${code}~ZERO~0.0000~0.0000~~0.0000~0.0000~0.0000~2026-09-22~";\n`));
      } else if (f) {
        const name = Buffer.isBuffer(f.name) ? f.name : Buffer.from(f.name);
        parts.push(
          Buffer.from(`v_${sym}="${code}~`), name,
          Buffer.from(`~0.0000~0.0000~~${f.nav}~${f.nav}~${f.pct ?? ''}~2026-09-22~";\n`),
        );
      } else if (s) {
        parts.push(Buffer.from(`v_${sym}="1~`), s[0], Buffer.from(`~${code}~${s[1]}~${s[2]}~123456~";\n`));
      } else {
        parts.push(Buffer.from('v_pv_none_match="1";\n'));
      }
    }
    res.writeHead(200, { 'content-type': 'text/html; charset=GBK' });
    res.end(Buffer.concat(parts));
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return {
    base: `http://127.0.0.1:${server.address().port}`,
    state,
    stop: () =>
      new Promise((resolve) => {
        server.closeAllConnections?.();
        server.close(() => resolve());
      }),
  };
}

/** 带假行情源的家庭；`env` 追加到服务端环境变量。 */
async function investHousehold(t, env = {}) {
  const up = await startFakeQuotes();
  t.after(() => up.stop());
  const h = await household(t, { QUOTE_STOCK_BASE: up.base, ...env });
  const { a, auth } = h;
  const bank = ok(await a.post('/accounts', { name: '招行卡', kind: 'bank', initialBalanceCents: 10000000 }, auth), 'POST 招行卡').account;
  const invest = ok(await a.post('/accounts', { name: '证券账户', kind: 'invest' }, auth), 'POST 证券账户').account;
  return {
    ...h, up, bank, invest,
    hold: (body) => a.post('/holdings', body, auth),
    trade: (id, body) => a.post(`/holdings/${id}/trade`, body, auth),
    refresh: () => a.post('/holdings/refresh', {}, auth),
    list: async () => ok(await a.get('/holdings?archived=1', auth), 'GET /holdings').items,
    overview: async () => ok(await a.get('/stats/overview', auth), 'GET /stats/overview'),
    txs: async () => ok(await a.get('/transactions?limit=200', auth), 'GET /transactions').items,
  };
}

const balanceOf = (o, id) => o.accounts.find((x) => x.accountId === id).balanceCents;

test('quotes：价格串按字符串转 ×10000 整数；腾讯文本按前缀各取各的字段', () => {
  assert.equal(quotes.toE4('1.0301'), 10301);
  assert.equal(quotes.toE4('1500.00'), 15000000);
  assert.equal(quotes.toE4(' 12 '), 120000);
  assert.equal(quotes.toE4('0.12345'), 1235, '第 5 位小数四舍五入');
  assert.equal(quotes.toE4('0.12344'), 1234);
  for (const bad of ['', '-', 'abc', '1.2.3', '-1.00', null, undefined]) assert.equal(quotes.toE4(bad), null, String(bad));

  const text = new TextDecoder('gbk').decode(Buffer.concat([
    // 头两行是腾讯 2026-09-22 的原样返回
    Buffer.from('v_jj005827="005827~'), GBK.易方达蓝筹精选混合, Buffer.from('~0.0000~0.0000~~1.4985~1.4985~-0.0734~2026-09-22~";\n'),
    Buffer.from('v_jj161725="161725~'), GBK.招商中证白酒指数A, Buffer.from('~0.0000~0.0000~~0.5320~2.2481~-0.0564~2026-09-22~";\n'),
    Buffer.from('v_jj000001="000001~A~0.0000~0.0000~~1.2345~1.2345~~2026-09-22~";\n'),
    Buffer.from('v_jj000002="000002~B~0.0000~0.0000~~1.2345~1.2345~--~2026-09-22~";\n'),
    Buffer.from('v_jj000003="000003~C~0.0000~0.0000~~0.0000~0.0000~0.0000~2026-09-22~";\n'),
    Buffer.from('v_jj000004="000004~D~1.1111~2.22~~1.0000~3.0000~0.00~2026-09-22~";\n'),
    Buffer.from('v_sh600519="1~'), GBK.贵州茅台, Buffer.from('~600519~1500.00~1490.00~9~";\nv_pv_none_match="1";\n'),
    Buffer.from('v_sz000001="51~'), GBK.平安银行, Buffer.from('~000001~0.00~11.20~0~";\n'),
  ]));
  const m = quotes.parseTencent(text);
  // 上一净值由日涨跌幅反推：14985 / (1 − 0.000734) = 14996.007 → 14996
  assert.deepEqual(m.get('jj005827'), { name: '易方达蓝筹精选混合', priceE4: 14985, prevCloseE4: 14996 });
  // 5320 / (1 − 0.000564) = 5323.002 → 5323；[6] 是累计净值，不是价格
  assert.deepEqual(m.get('jj161725'), { name: '招商中证白酒指数A', priceE4: 5320, prevCloseE4: 5323 });
  assert.deepEqual(m.get('jj000001'), { name: 'A', priceE4: 12345, prevCloseE4: null }, '没有涨跌幅就不猜昨收');
  assert.deepEqual(m.get('jj000002'), { name: 'B', priceE4: 12345, prevCloseE4: null }, '涨跌幅不是数字也不猜');
  assert.deepEqual(m.get('jj000003'), { error: '没有这只基金的净值' });
  assert.deepEqual(m.get('jj000004'), { name: 'D', priceE4: 10000, prevCloseE4: 10000 }, '[2][3] 的废弃估值不当价格；平盘昨收就是净值');
  assert.deepEqual(m.get('sh600519'), { name: '贵州茅台', priceE4: 15000000, prevCloseE4: 14900000 });
  assert.deepEqual(m.get('sz000001'), { name: '平安银行', priceE4: 112000, prevCloseE4: 112000 }, '现价 0（停牌/未开盘）退回昨收');
  assert.equal(m.size, 8);
});

test('quotes：基金与股票分两批问，每批最多 60 个符号', async (t) => {
  const up = await startFakeQuotes();
  t.after(() => up.stop());
  const items = [];
  for (let i = 0; i < 61; i++) {
    const code = String(100000 + i);
    up.state.funds[code] = { name: `F${code}`, nav: '1.0000', pct: '0' };
    items.push({ market: 'fund', code });
  }
  up.state.stocks = { sh600519: [GBK.贵州茅台, '1500.00', '1490.00'] };
  items.push({ market: 'sh', code: '600519' }, { market: 'fund', code: '100000' }, { market: 'sz', code: '000001' });

  const got = await quotes.fetchQuotes(items, { base: up.base, timeoutMs: 2000 });
  const batches = up.state.requests.map((p) => p.slice(3).split(','));
  assert.deepEqual(batches.map((b) => b.length).sort((x, y) => x - y), [1, 2, 60], '61 只基金拆成 60 + 1，重复的只问一次');
  for (const b of batches) assert.equal(new Set(b.map((s) => s.startsWith('jj'))).size, 1, `一批里不混基金和股票：${b}`);
  assert.equal(got.size, 63);
  assert.deepEqual(got.get('fund:100060'), { name: 'F100060', priceE4: 10000, prevCloseE4: 10000 });
  assert.deepEqual(got.get('sh:600519'), { name: '贵州茅台', priceE4: 15000000, prevCloseE4: 14900000 });
  assert.deepEqual(got.get('sz:000001'), { error: '行情里没有这个代码' });
});

test('CRUD：校验、份额成本只能经交易改、同步与软删', async (t) => {
  const h = await investHousehold(t);
  const { a, auth, bank, invest } = h;

  fail(await h.hold({ name: '白酒', quantityE4: 0, costCents: 100 }), 400, 'invalid_quantityE4', '份额为 0');
  fail(await h.hold({ name: '白酒', quantityE4: 100, costCents: -1 }), 400, 'invalid_costCents', '成本为负');
  fail(await h.hold({ quantityE4: 100, costCents: 100 }), 400, 'invalid_name', '名称代码都没填');
  fail(await h.hold({ name: '白酒', quantityE4: 100, costCents: 100, accountId: bank.id }), 400, 'invalid_accountId', '挂到非投资账户');
  fail(await h.hold({ name: '白酒', quantityE4: 100, costCents: 100, openedOn: '2026-02-30' }), 400, 'invalid_openedOn', '不存在的日期');
  fail(await h.hold({ name: '白酒', quantityE4: 100, costCents: 100, priceSource: 'auto' }), 400, 'invalid_priceSource', '自动行情却没代码');
  fail(await h.hold({ name: '金条', code: 'AU', market: 'other', priceSource: 'auto', quantityE4: 100, costCents: 100 }), 400, 'invalid_priceSource', 'other 市场不能自动行情');
  fail(await h.hold({ name: 'x', code: '16/../1', market: 'fund', quantityE4: 100, costCents: 100 }), 400, 'invalid_code', '代码带路径字符');
  fail(
    await h.hold({ name: '白酒', quantityE4: 100, costCents: 100, recordTransaction: { fromAccountId: bank.id } }),
    400, 'holding_needs_account', '要记账却没挂投资账户',
  );
  fail(
    await h.hold({ name: '白酒', quantityE4: 100, costCents: 100, accountId: invest.id, recordTransaction: { fromAccountId: 'nope' } }),
    400, 'invalid_fromAccountId', '转出账户不存在',
  );
  fail(
    await h.hold({ name: '白酒', quantityE4: 100, costCents: 100, accountId: invest.id }),
    400, 'holding_needs_transfer', '挂了投资账户、有成本，却不记转账',
  );
  assert.deepEqual(await h.list(), [], '失败的新建一条都不该留下');

  const created = await h.hold({ name: '白酒基金', code: '161725', market: 'fund', priceSource: 'auto', quantityE4: 30000000, costCents: 1000000, openedOn: '2026-09-01' });
  assert.equal(created.status, 201, created.text);
  const hd = created.json.holding;
  assert.equal(hd.quantityE4, 30000000);
  assert.equal(hd.costCents, 1000000);
  assert.equal(hd.realizedCents, 0);
  assert.equal(hd.priceE4, null);
  assert.equal(hd.archived, false);
  assert.equal(hd.openedOn, '2026-09-01');
  assert.deepEqual(await h.txs(), [], '没要求记账就不记');

  fail(await a.patch(`/holdings/${hd.id}`, { quantityE4: 1 }, auth), 400, 'invalid_quantityE4', 'PATCH 份额');
  fail(await a.patch(`/holdings/${hd.id}`, { costCents: 1 }, auth), 400, 'invalid_costCents', 'PATCH 成本');
  fail(await a.patch(`/holdings/${hd.id}`, { market: 'other' }, auth), 400, 'invalid_priceSource', '自动行情改成 other 市场');

  const priced = ok(await a.patch(`/holdings/${hd.id}`, { priceE4: 10500, note: '定投' }, auth), 'PATCH 手动价').holding;
  assert.equal(priced.priceE4, 10500);
  assert.ok(priced.priceAt, '改价要记下时间，App 靠它判断过期');
  assert.equal(priced.prevCloseE4, null);
  assert.equal(priced.note, '定投');
  assert.equal(priced.quantityE4, 30000000);

  const delta = ok(await a.get('/changes?since=0', auth), 'GET /changes');
  assert.equal(delta.holdings.length, 1);
  assert.equal(delta.holdings[0].archived, false, 'archived 是布尔');
  assert.equal(delta.holdings[0].priceE4, 10500);

  ok(await a.del(`/holdings/${hd.id}`, auth), 'DELETE');
  const after = ok(await a.get(`/changes?since=${delta.next}`, auth), 'GET /changes 增量');
  assert.equal(after.holdings.length, 1);
  assert.ok(after.holdings[0].deletedAt, '墓碑同步出去');
  assert.deepEqual(await h.list(), []);
});

test('同时记账：开仓与加仓记转账，减仓按移动平均成本记盈亏，超卖 400', async (t) => {
  const h = await investHousehold(t);
  const { bank, invest } = h;

  const hd = ok(await h.hold({
    name: '白酒基金', code: '161725', market: 'fund', quantityE4: 30000000, costCents: 1000000,
    accountId: invest.id, openedOn: '2026-09-01', recordTransaction: { fromAccountId: bank.id },
  }), 'POST 开仓').holding;

  let txs = await h.txs();
  assert.equal(txs.length, 1);
  assert.equal(txs[0].type, 'transfer', '买基金是换个地方存钱，不是花钱');
  assert.equal(txs[0].amountCents, 1000000);
  assert.equal(txs[0].accountId, bank.id);
  assert.equal(txs[0].toAccountId, invest.id);
  assert.equal(txs[0].occurredAt, '2026-09-01T12:00:00+08:00');
  assert.equal(txs[0].categoryId, null);

  // 加仓 1000 份花 3500.00
  const buy = ok(await h.trade(hd.id, { side: 'buy', quantityE4: 10000000, amountCents: 350000, occurredOn: '2026-09-10', recordTransaction: { accountId: bank.id } }), '加仓');
  assert.equal(buy.holding.quantityE4, 40000000);
  assert.equal(buy.holding.costCents, 1350000);
  assert.equal(buy.transactions.length, 1);
  assert.equal(buy.transactions[0].type, 'transfer');
  assert.equal(buy.transactions[0].amountCents, 350000);
  assert.equal(buy.transactions[0].accountId, bank.id);
  assert.equal(buy.transactions[0].toAccountId, invest.id);
  assert.equal(buy.transactions[0].occurredAt, '2026-09-10T12:00:00+08:00');

  // 卖 1234.5678 份得 5000.00：摊出的成本 = round(1350000 × 12345678 / 40000000) = round(416666.63) = 416667
  const sell = ok(await h.trade(hd.id, { side: 'sell', quantityE4: 12345678, amountCents: 500000, occurredOn: '2026-09-15', recordTransaction: { accountId: bank.id } }), '盈利减仓');
  assert.equal(sell.holding.quantityE4, 27654322);
  assert.equal(sell.holding.costCents, 933333);
  assert.equal(sell.holding.realizedCents, 83333);
  assert.equal(sell.transactions.length, 2);
  const [out, gain] = sell.transactions;
  assert.equal(out.type, 'transfer');
  assert.equal(out.amountCents, 500000, '转回的是卖出所得');
  assert.equal(out.accountId, invest.id);
  assert.equal(out.toAccountId, bank.id);
  assert.equal(gain.type, 'income');
  assert.equal(gain.amountCents, 83333);
  assert.equal(gain.accountId, invest.id);
  assert.equal(gain.occurredAt, '2026-09-15T12:00:00+08:00');
  let cats = ok(await h.a.get('/categories', h.auth), 'GET /categories').items;
  const gainCat = cats.find((c) => c.id === gain.categoryId);
  assert.deepEqual([gainCat.name, gainCat.kind], ['投资收益', 'income'], '没有这个类别就当场建一个');

  // 卖 765.4322 份得 2000.00：摊出成本 round(933333 × 7654322 / 27654322) = 258333 → 亏 583.33
  const loss = ok(await h.trade(hd.id, { side: 'sell', quantityE4: 7654322, amountCents: 200000, occurredOn: '2026-09-16', recordTransaction: { accountId: bank.id } }), '亏损减仓');
  assert.equal(loss.holding.quantityE4, 20000000);
  assert.equal(loss.holding.costCents, 675000);
  assert.equal(loss.holding.realizedCents, 83333 - 58333);
  const lossTx = loss.transactions[1];
  assert.equal(lossTx.type, 'expense');
  assert.equal(lossTx.amountCents, 58333);
  assert.equal(lossTx.accountId, invest.id);
  cats = ok(await h.a.get('/categories', h.auth), 'GET /categories').items;
  const lossCat = cats.find((c) => c.id === lossTx.categoryId);
  assert.deepEqual([lossCat.name, lossCat.kind], ['投资亏损', 'expense']);

  // 再亏一次复用同一个类别，不会建出两个「投资亏损」
  const loss2 = ok(await h.trade(hd.id, { side: 'sell', quantityE4: 10000, amountCents: 0, occurredOn: '2026-09-16', recordTransaction: { accountId: bank.id } }), '清零卖出');
  assert.equal(loss2.transactions.length, 1, '卖出所得 0 就不记转账，只记亏损');
  assert.equal(loss2.transactions[0].categoryId, lossCat.id);
  cats = ok(await h.a.get('/categories', h.auth), 'GET /categories').items;
  assert.equal(cats.filter((c) => c.name === '投资亏损').length, 1);
  assert.equal(loss2.holding.quantityE4, 19990000);
  // round(675000 × 10000 / 20000000) = round(337.5) = 338
  assert.equal(loss2.holding.costCents, 674662);

  const before = (await h.list())[0];
  fail(await h.trade(hd.id, { side: 'sell', quantityE4: 19990001, amountCents: 1, occurredOn: '2026-09-17' }), 400, 'insufficient_quantity', '超卖');
  assert.deepEqual((await h.list())[0], before, '超卖一个字都不改');
  fail(await h.trade(hd.id, { side: 'hold', quantityE4: 1, amountCents: 1, occurredOn: '2026-09-17' }), 400, 'invalid_side', '未知方向');
  fail(await h.trade(hd.id, { side: 'buy', quantityE4: 0, amountCents: 1, occurredOn: '2026-09-17' }), 400, 'invalid_quantityE4', '份额 0');
  fail(await h.trade(hd.id, { side: 'buy', quantityE4: 1, amountCents: 1, occurredOn: '2026-09-17', recordTransaction: { accountId: invest.id } }), 400, 'invalid_accountId', '转给自己');
  fail(await h.trade('nope', { side: 'buy', quantityE4: 1, amountCents: 1, occurredOn: '2026-09-17' }), 404, 'not_found', '不存在的持仓');

  // 全部卖掉不删行：已实现盈亏还要看
  const all = ok(await h.trade(hd.id, { side: 'sell', quantityE4: 19990000, amountCents: 700000, occurredOn: '2026-09-18' }), '清仓');
  assert.equal(all.transactions.length, 0, '没要求记账就不记');
  assert.equal(all.holding.quantityE4, 0);
  assert.equal(all.holding.costCents, 0);
  assert.equal(all.holding.realizedCents, 25000 - 674662 + 700000 - 338);
  assert.equal((await h.list()).length, 1);

  // 余额：银行 1e7 − 1000000 − 350000 + 500000 + 200000；投资账户 = 记过账部分剩下的成本
  const o = await h.overview();
  assert.equal(balanceOf(o, bank.id), 9350000);
  assert.equal(balanceOf(o, invest.id), 1000000 + 350000 - 500000 + 83333 - 200000 - 58333 - 338);
  txs = await h.txs();
  assert.equal(txs.filter((x) => x.type === 'transfer').length, 4);
  assert.ok(!txs.some((x) => x.type === 'expense' && x.amountCents === 350000), '加仓从来不是支出');

  // 不挂账户的持仓要求记账 → 400，且份额不动
  const loose = ok(await h.hold({ name: '纸黄金', quantityE4: 10000, costCents: 50000 }), 'POST 不挂账户').holding;
  fail(await h.trade(loose.id, { side: 'buy', quantityE4: 10000, amountCents: 1, occurredOn: '2026-09-18', recordTransaction: { accountId: bank.id } }), 400, 'holding_needs_account', '没挂账户却要记账');
  assert.equal((await h.list()).find((x) => x.id === loose.id).quantityE4, 10000);
});

test('刷新行情：名称回填、GBK、同代码不同市场各查各的、没这只或净值为 0 只算那只失败、节流', async (t) => {
  const h = await investHousehold(t, { QUOTE_THROTTLE_MS: '1500' });
  const { up } = h;
  up.state.funds = {
    161725: { name: GBK.招商中证白酒指数A, nav: '0.5320', pct: '-0.0564' },
    '000001': { name: 'HuaXia', nav: '1.2345', pct: '1.23' },
    666666: 'zero',
  };
  up.state.stocks = {
    sh600519: [GBK.贵州茅台, '1500.00', '1490.00'],
    sz000001: [GBK.平安银行, '11.23', '11.20'],
    sz300750: [GBK.平安银行, '1.00', '1.00'],
    sh600000: [GBK.平安银行, '1.00', '1.00'],
  };

  const mk = async (body) => ok(await h.hold({ quantityE4: 10000, costCents: 100, ...body }), `POST ${body.code}`).holding;
  const baijiu = await mk({ name: '', code: '161725', market: 'fund', priceSource: 'auto' });
  const huaxia = await mk({ name: '我的华夏', code: '000001', market: 'fund', priceSource: 'auto' });
  const zero = await mk({ name: '零净值', code: '666666', market: 'fund', priceSource: 'auto', priceE4: 20000 });
  const gone = await mk({ name: '没这只', code: '777777', market: 'fund', priceSource: 'auto' });
  const moutai = await mk({ code: '600519', market: 'sh', priceSource: 'auto' });
  const pingan = await mk({ name: '平安', code: '000001', market: 'sz', priceSource: 'auto' });
  const missing = await mk({ name: '查无此股', code: '000002', market: 'sz', priceSource: 'auto' });
  const manual = await mk({ name: '浦发手动', code: '600000', market: 'sh', priceSource: 'manual', priceE4: 88000 });
  const archived = await mk({ name: '宁德', code: '300750', market: 'sz', priceSource: 'auto', archived: true });
  const zeroBefore = (await h.list()).find((x) => x.id === zero.id);

  const r = ok(await h.refresh(), '刷新');
  assert.equal(r.throttled, false);
  assert.equal(r.updated, 4);
  assert.ok(r.refreshedAt);
  const failed = new Map(r.failed.map((f) => [f.id, f]));
  assert.deepEqual([...failed.keys()].sort(), [zero.id, gone.id, missing.id].sort());
  assert.equal(failed.get(zero.id).code, '666666');
  assert.equal(failed.get(zero.id).message, '没有这只基金的净值');
  assert.match(failed.get(gone.id).message, /没有这只基金/);
  assert.equal(failed.get(missing.id).code, '000002');

  const byId = new Map((await h.list()).map((x) => [x.id, x]));
  const b = byId.get(baijiu.id);
  // 上一净值 = 5320 / (1 − 0.000564) = 5323.002 → 5323
  assert.deepEqual([b.name, b.priceE4, b.prevCloseE4], ['招商中证白酒指数A', 5320, 5323], '名称为空时用行情里的名称回填（GBK 解码）');
  assert.ok(b.priceAt);
  const hx = byId.get(huaxia.id);
  // 12345 / 1.0123 = 12195.001 → 12195
  assert.deepEqual([hx.name, hx.priceE4, hx.prevCloseE4], ['我的华夏', 12345, 12195], '自己起的名字不覆盖');
  const mt = byId.get(moutai.id);
  assert.deepEqual([mt.name, mt.priceE4, mt.prevCloseE4], ['贵州茅台', 15000000, 14900000], 'GBK 名称解码正确');
  const pa = byId.get(pingan.id);
  assert.deepEqual([pa.name, pa.priceE4, pa.prevCloseE4], ['平安', 112300, 112000], '同代码不同市场各查各的');
  assert.deepEqual(byId.get(zero.id), zeroBefore, '净值为 0 就原样保留旧价格');
  assert.equal(byId.get(manual.id).priceE4, 88000);
  assert.equal(byId.get(archived.id).priceE4, null);

  const calls = up.state.requests.map((p) => p.slice(3).split(',').sort()).sort((x, y) => x[0].localeCompare(y[0]));
  assert.deepEqual(calls, [
    ['jj000001', 'jj161725', 'jj666666', 'jj777777'],
    ['sh600519', 'sz000001', 'sz000002'],
  ], '基金一批、股票一批，各自一次请求');
  assert.ok(!up.state.requests.some((p) => p.includes('600000') || p.includes('300750')), '手动价与归档的不查');

  // 节流期内：原样返回上次结果，不碰上游
  const n = up.state.requests.length;
  const again = ok(await h.refresh(), '节流中再刷');
  assert.equal(again.throttled, true);
  assert.deepEqual({ ...again, throttled: false }, r);
  assert.equal(up.state.requests.length, n);

  // 过了节流间隔（测试里调成 1.5 秒）就真的再拉一次；5555 / (1 − 0.000564) = 5558.134 → 5558
  up.state.funds[161725] = { ...up.state.funds[161725], nav: '0.5555' };
  await sleep(1600);
  const third = ok(await h.refresh(), '节流过后再刷');
  assert.equal(third.throttled, false);
  assert.ok(up.state.requests.length > n);
  const again3 = (await h.list()).find((x) => x.id === baijiu.id);
  assert.deepEqual([again3.priceE4, again3.prevCloseE4], [5555, 5558]);
});

test('刷新行情：一个批次整体坏了只连累同类，失败不清旧价', async (t) => {
  const h = await investHousehold(t, { QUOTE_THROTTLE_MS: '200', QUOTE_TIMEOUT_MS: '400' });
  const { up } = h;
  up.state.funds = { 161725: { name: 'Baijiu', nav: '0.5320', pct: '-0.0564' } };
  up.state.stocks = { sh600519: [GBK.贵州茅台, '1500.00', '1490.00'] };

  const mk = async (body) => ok(await h.hold({ quantityE4: 10000, costCents: 100, ...body }), `POST ${body.code}`).holding;
  const fund = await mk({ name: '白酒', code: '161725', market: 'fund', priceSource: 'auto', priceE4: 20000 });
  const stock = await mk({ name: '茅台', code: '600519', market: 'sh', priceSource: 'auto', priceE4: 16000000 });
  const get = async (id) => (await h.list()).find((x) => x.id === id);
  const prices = (x) => [x.priceE4, x.prevCloseE4];
  const fundBefore = await get(fund.id);

  // 基金批次回 500：基金失败、旧价原样，股票照常
  up.state.batchFault = { jj: 'fail' };
  let r = ok(await h.refresh(), '基金批次 500');
  assert.equal(r.updated, 1);
  assert.deepEqual(r.failed.map((f) => [f.id, f.code]), [[fund.id, '161725']]);
  assert.match(r.failed[0].message, /500/);
  assert.deepEqual(await get(fund.id), fundBefore, '拉不到就原样保留旧价格');
  assert.deepEqual(prices(await get(stock.id)), [15000000, 14900000], '基金批次坏了股票照常');

  // 基金批次不回：超时也只算基金失败
  up.state.batchFault = { jj: 'hang' };
  await sleep(250);
  r = ok(await h.refresh(), '基金批次超时');
  assert.equal(r.throttled, false);
  assert.equal(r.updated, 1);
  assert.deepEqual(r.failed.map((f) => f.id), [fund.id]);
  assert.match(r.failed[0].message, /超时/);
  assert.deepEqual(await get(fund.id), fundBefore);

  // 反过来：股票批次坏了，基金照常、股票旧价保留
  up.state.batchFault = { sh: 'fail' };
  const stockBefore = await get(stock.id);
  await sleep(250);
  r = ok(await h.refresh(), '股票批次 500');
  assert.equal(r.throttled, false);
  assert.equal(r.updated, 1);
  assert.deepEqual(r.failed.map((f) => [f.id, f.code]), [[stock.id, '600519']]);
  assert.match(r.failed[0].message, /500/);
  assert.deepEqual(prices(await get(fund.id)), [5320, 5323], '股票批次坏了基金照常');
  assert.deepEqual(await get(stock.id), stockBefore);
});

test('节流默认 10 分钟，并发的两次刷新只打一次上游', async (t) => {
  const h = await investHousehold(t);
  h.up.state.funds = { 161725: { name: 'Baijiu', nav: '1.0100', pct: '1.00' } };
  await h.hold({ name: '白酒', code: '161725', market: 'fund', priceSource: 'auto', quantityE4: 10000, costCents: 100 });

  const [x, y] = await Promise.all([h.refresh(), h.refresh()]);
  assert.equal(x.status, 200);
  assert.equal(y.status, 200);
  assert.deepEqual([x.json.throttled, y.json.throttled].sort(), [false, true]);
  assert.equal(h.up.state.requests.length, 1);
  await sleep(300);
  const z = ok(await h.refresh(), '稍后再刷');
  assert.equal(z.throttled, true);
  assert.equal(z.updated, 1);
  assert.equal(h.up.state.requests.length, 1);
});

test('overview：投资市值/成本/收益，净资产挂账户只补浮盈、不挂账户整份计入', async (t) => {
  const h = await investHousehold(t);
  const { a, auth, bank, invest } = h;
  ok(await a.patch(`/accounts/${bank.id}`, { initialBalanceCents: 1000000 }, auth), 'PATCH 招行卡');

  const empty = await h.overview();
  assert.deepEqual([empty.investMarketCents, empty.investCostCents, empty.investGainCents], [0, 0, 0]);
  assert.equal(empty.netWorthCents, 1000000);

  // H1 挂账户、记了转账：市值 round(1234567 × 123456 / 1e6) = round(152414.70) = 152415，浮盈 2415
  const h1 = ok(await h.hold({ name: 'H1', quantityE4: 1234567, costCents: 150000, priceE4: 123456, accountId: invest.id, recordTransaction: { fromAccountId: bank.id } }), 'H1').holding;
  // H2 不挂账户：市值 2000000 × 2500 / 1e6 = 5000，整份计入
  await h.hold({ name: 'H2', quantityE4: 2000000, costCents: 50000, priceE4: 2500 });
  // 下面这些都不计：归档的、没价格的、清了仓的、删掉的
  await h.hold({ name: 'H3', quantityE4: 1000000, costCents: 10000, priceE4: 100000, archived: true });
  await h.hold({ name: 'H4', quantityE4: 1000000, costCents: 30000 });
  const h5 = ok(await h.hold({ name: 'H5', quantityE4: 10000, costCents: 10000, priceE4: 990000 }), 'H5').holding;
  ok(await h.trade(h5.id, { side: 'sell', quantityE4: 10000, amountCents: 9900, occurredOn: '2026-09-20' }), '清仓 H5');
  const h6 = ok(await h.hold({ name: 'H6', quantityE4: 10000, costCents: 10000, priceE4: 990000 }), 'H6').holding;
  ok(await a.del(`/holdings/${h6.id}`, auth), 'DELETE H6');

  const o = await h.overview();
  assert.equal(o.investMarketCents, 152415 + 5000);
  assert.equal(o.investCostCents, 150000 + 50000);
  assert.equal(o.investGainCents, 157415 - 200000);
  assert.equal(balanceOf(o, bank.id), 850000);
  assert.equal(balanceOf(o, invest.id), 150000);
  // 账户合计 1000000（成本已在投资账户里）+ H1 浮盈 2415 + H2 整份 5000
  assert.equal(o.netWorthCents, 1007415);
  assert.equal(o.assetsCents - o.liabilitiesCents, o.netWorthCents, '净资产 = 资产 − 负债 的恒等式不破');

  // 亏了也照算：H1 价格跌到 10.0000 → 市值 123456.7 → 123457，浮亏 26543
  ok(await a.patch(`/holdings/${h1.id}`, { priceE4: 100000 }, auth), '改价');
  const o2 = await h.overview();
  assert.equal(o2.investMarketCents, 123457 + 5000);
  assert.equal(o2.netWorthCents, 1000000 + (123457 - 150000) + 5000);
});

test('换了代码或市场就清掉旧价，同一次给了新价以新价为准；上游超长名称截到 60 字', async (t) => {
  const h = await investHousehold(t);
  const { a, auth, bank, invest } = h;
  h.up.state.funds = {
    '000003': { name: 'Jia', nav: '2.0000', pct: '5.2632' },
    '000001': { name: Buffer.concat(Array(200).fill(GBK.长)), nav: '1.0000', pct: '0.00' },
  };
  const fund = ok(await h.hold({ name: '甲', code: '000003', market: 'fund', priceSource: 'auto', quantityE4: 10000, costCents: 100 }), 'POST 甲').holding;
  const long = ok(await h.hold({ name: '', code: '000001', market: 'fund', priceSource: 'auto', quantityE4: 10000, costCents: 100, accountId: invest.id, recordTransaction: { fromAccountId: bank.id } }), 'POST 无名').holding;
  const gold = ok(await h.hold({ name: '金条', code: 'AU', market: 'other', priceE4: 5000000, quantityE4: 10000, costCents: 100 }), 'POST 金条').holding;
  ok(await h.refresh(), '刷新');
  // 市值：甲 1 份 × 2.0000 = 200；无名 1 份 × 1.0000 = 100；金条 1 份 × 500.0000 = 50000
  assert.equal((await h.overview()).investMarketCents, 200 + 100 + 50000);

  const refreshed = (await h.list()).find((x) => x.id === fund.id);
  const same = ok(await a.patch(`/holdings/${fund.id}`, { code: ' 000003 ', market: 'fund', note: '定投' }, auth), 'PATCH 同一只').holding;
  // 甲的上一净值 = 20000 / 1.052632 = 18999.99 → 19000
  assert.deepEqual([same.priceE4, same.prevCloseE4, same.priceAt], [20000, 19000, refreshed.priceAt], '代码没真变就不动价格');

  const swapped = ok(await a.patch(`/holdings/${fund.id}`, { code: '999999' }, auth), 'PATCH 换代码').holding;
  assert.deepEqual([swapped.priceE4, swapped.prevCloseE4, swapped.priceAt], [null, null, null], '旧价属于另一只证券');
  assert.equal((await h.overview()).investMarketCents, 100 + 50000, '没价格就退出市值统计');

  const repriced = ok(await a.patch(`/holdings/${gold.id}`, { code: 'AU9999', priceE4: 4000000 }, auth), 'PATCH 换代码带新价').holding;
  assert.equal(repriced.priceE4, 4000000);
  assert.ok(repriced.priceAt);
  const moved = ok(await a.patch(`/holdings/${gold.id}`, { market: 'sh' }, auth), 'PATCH 换市场').holding;
  assert.deepEqual([moved.priceE4, moved.priceAt], [null, null], '同一个代码换了市场也是另一只东西');

  const named = (await h.list()).find((x) => x.id === long.id);
  assert.equal(named.name, '长'.repeat(60), '回填名称和手填一样最多 60 字');
  const buy = ok(await h.trade(long.id, { side: 'buy', quantityE4: 10000, amountCents: 100, occurredOn: '2026-09-20', recordTransaction: { accountId: bank.id } }), '回填过长名称后加仓记账');
  assert.equal(buy.transactions[0].merchant, `买入 ${'长'.repeat(60)}`);
});

test('交易：挂的投资账户删了报 holding_needs_account；累计已实现盈亏越界是 400 而不是 500', async (t) => {
  const h = await investHousehold(t);
  const { a, auth, bank, invest } = h;

  const hd = ok(await h.hold({ name: '白酒', quantityE4: 20000, costCents: 200, accountId: invest.id, recordTransaction: { fromAccountId: bank.id } }), 'POST 白酒').holding;
  // 账户下有流水删不掉：先删开仓那笔转账，才走得到「挂的账户没了」
  ok(await a.del(`/transactions/${(await h.txs())[0].id}`, auth), 'DELETE 开仓转账');
  ok(await a.del(`/accounts/${invest.id}`, auth), 'DELETE 投资账户');
  for (const side of ['buy', 'sell']) {
    const r = await h.trade(hd.id, { side, quantityE4: 10000, amountCents: 100, occurredOn: '2026-09-20', recordTransaction: { accountId: bank.id } });
    fail(r, 400, 'holding_needs_account', `${side}：不能报成请求里的账户不存在`);
    assert.match(r.json.error.message, /删/);
  }
  assert.equal((await h.list())[0].quantityE4, 20000, '报错的交易一个字都不改');
  assert.deepEqual(await h.txs(), []);
  ok(await h.trade(hd.id, { side: 'buy', quantityE4: 10000, amountCents: 100, occurredOn: '2026-09-20' }), '不记账照样能加仓');

  // 成本 0 卖 1 个单位得 1e14：已实现盈亏正好顶到上限；再赚 1 分就越界
  const big = ok(await h.hold({ name: '大', quantityE4: 1e14, costCents: 0 }), 'POST 大').holding;
  ok(await h.trade(big.id, { side: 'sell', quantityE4: 1, amountCents: 1e14, occurredOn: '2026-09-20' }), '盈利到上限');
  const atMax = (await h.list()).find((x) => x.id === big.id);
  assert.equal(atMax.realizedCents, 1e14);
  fail(await h.trade(big.id, { side: 'sell', quantityE4: 1, amountCents: 1, occurredOn: '2026-09-20' }), 400, 'invalid_amountCents', '累计盈利越界');
  assert.deepEqual((await h.list()).find((x) => x.id === big.id), atMax);

  const lossy = ok(await h.hold({ name: '亏', quantityE4: 10000, costCents: 1e14 }), 'POST 亏').holding;
  ok(await h.trade(lossy.id, { side: 'sell', quantityE4: 10000, amountCents: 0, occurredOn: '2026-09-20' }), '亏到下限');
  ok(await h.trade(lossy.id, { side: 'buy', quantityE4: 10000, amountCents: 1, occurredOn: '2026-09-20' }), '再买一点');
  fail(await h.trade(lossy.id, { side: 'sell', quantityE4: 10000, amountCents: 0, occurredOn: '2026-09-20' }), 400, 'invalid_amountCents', '累计亏损越界');
  assert.equal((await h.list()).find((x) => x.id === lossy.id).realizedCents, -1e14);
});

test('净资产的前提「成本已在账户余额里」：开仓挂账户必须记转账、事后挂上要给转出账户、换账户补移仓、不许解绑', async (t) => {
  const h = await investHousehold(t);
  const { a, auth, bank, invest } = h;
  const invest2 = ok(await a.post('/accounts', { name: '基金户', kind: 'invest' }, auth), 'POST 基金户').account;
  const base = (await h.overview()).netWorthCents;
  const noonToday = (() => {
    const d = new Date();
    const p = (n) => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T12:00:00+08:00`;
  })();
  // App 的 HoldingsRepo.edit 每次都整份发这些字段
  const editBody = (x, accountId, extra = {}) => ({
    name: x.name, code: null, market: x.market, priceSource: 'manual', openedOn: x.openedOn, accountId, note: null, ...extra,
  });
  const netWorth = async (what) => {
    const o = await h.overview();
    assert.equal(o.assetsCents - o.liabilitiesCents, o.netWorthCents, `${what}：资产 − 负债 = 净资产`);
    return o;
  };

  // 送的股票没有成本，挂账户不用记账
  ok(await h.hold({ name: '赠股', quantityE4: 10000, costCents: 0, accountId: invest.id }), '成本 0 挂账户');

  // X：1 份、成本 100.00、现价 100.00，先不挂账户 → 市值整份计入
  const x = ok(await h.hold({ name: 'X', quantityE4: 10000, costCents: 10000, priceE4: 1000000 }), 'POST X').holding;
  assert.equal((await netWorth('不挂账户')).netWorthCents, base + 10000);

  // 只补 accountId、不说成本从哪来：以前净资产会凭空少一整份成本，现在直接拒掉
  fail(await a.patch(`/holdings/${x.id}`, editBody(x, invest.id), auth), 400, 'holding_needs_transfer', '事后挂账户不记转账');
  fail(
    await a.patch(`/holdings/${x.id}`, editBody(x, invest.id, { recordTransaction: { fromAccountId: invest.id } }), auth),
    400, 'invalid_fromAccountId', '成本从挂的那个账户自己转进来',
  );
  assert.equal((await h.list()).find((r) => r.id === x.id).accountId, null, '拒掉的 PATCH 一个字都不改');
  assert.deepEqual(await h.txs(), []);
  assert.equal((await netWorth('拒掉之后')).netWorthCents, base + 10000);

  // 说清楚成本是从招行卡出的：补一笔转账。招行卡真少了这笔钱，净资产跟着少一份成本 ——
  // 这是用户明说的一笔钱的去向，流水里看得见，不是凭空跳
  ok(await a.patch(`/holdings/${x.id}`, editBody(x, invest.id, { recordTransaction: { fromAccountId: bank.id } }), auth), '挂上并补转账');
  let txs = await h.txs();
  assert.equal(txs.length, 1);
  assert.deepEqual(
    [txs[0].type, txs[0].amountCents, txs[0].accountId, txs[0].toAccountId, txs[0].merchant, txs[0].occurredAt],
    ['transfer', 10000, bank.id, invest.id, '转入 X', noonToday],
  );
  let o = await netWorth('挂上之后');
  assert.equal(o.netWorthCents, base, '账户合计没变（转账），持仓只补浮盈 0');
  assert.equal(balanceOf(o, invest.id), 10000);
  assert.equal(balanceOf(o, bank.id), 10000000 - 10000);

  // 同一个 PATCH 再发一次（回应丢了 App 重发）：账户没变，不再补
  ok(await a.patch(`/holdings/${x.id}`, editBody(x, invest.id, { recordTransaction: { fromAccountId: bank.id } }), auth), '重发');
  assert.equal((await h.txs()).length, 1);

  // 换到另一个投资账户：成本跟着挪过去
  ok(await a.patch(`/holdings/${x.id}`, editBody(x, invest2.id), auth), '换账户');
  txs = await h.txs();
  assert.equal(txs.length, 2);
  const moved = txs.find((r) => r.merchant === '移仓 X');
  assert.deepEqual([moved.type, moved.amountCents, moved.accountId, moved.toAccountId], ['transfer', 10000, invest.id, invest2.id]);
  o = await netWorth('换账户之后');
  assert.equal(o.netWorthCents, base);
  assert.deepEqual([balanceOf(o, invest.id), balanceOf(o, invest2.id)], [0, 10000]);

  // 直接解绑：成本还在账户余额里，净资产会多算一份 → 拒掉
  fail(await a.patch(`/holdings/${x.id}`, editBody(x, null), auth), 400, 'holding_account_locked', '有成本时解绑');
  assert.equal((await netWorth('拒绝解绑')).netWorthCents, base);

  // 带转账全部卖出：投资账户回到 0，不会变成负数进负债
  ok(await h.trade(x.id, { side: 'sell', quantityE4: 10000, amountCents: 10000, occurredOn: '2026-09-20', recordTransaction: { accountId: bank.id } }), '清仓');
  o = await netWorth('清仓之后');
  assert.equal(balanceOf(o, invest2.id), 0);
  assert.equal(o.liabilitiesCents, 0);
  assert.equal(o.netWorthCents, base);
  // 清了仓成本是 0，想解绑就解绑
  ok(await a.patch(`/holdings/${x.id}`, editBody(x, null), auth), '清仓后解绑');

  // 挂的账户删了（先删掉那笔转账才删得动）：成本跟着从余额里消失，按没挂算；编辑时原样带回旧 id 照样能存
  const dead = ok(await a.post('/accounts', { name: '销户', kind: 'invest' }, auth), 'POST 销户').account;
  const y = ok(await h.hold({ name: 'Y', quantityE4: 10000, costCents: 5000, priceE4: 600000, accountId: dead.id, recordTransaction: { fromAccountId: bank.id } }), 'POST Y').holding;
  ok(await a.del(`/transactions/${(await h.txs()).find((r) => r.toAccountId === dead.id).id}`, auth), '删开仓转账');
  ok(await a.del(`/accounts/${dead.id}`, auth), '删账户');
  const before = (await netWorth('账户删了')).netWorthCents;
  ok(await a.patch(`/holdings/${y.id}`, editBody(y, dead.id, { note: '改个备注' }), auth), '带着删掉的账户 id 保存');
  fail(await a.patch(`/holdings/${y.id}`, editBody(y, invest.id), auth), 400, 'holding_needs_transfer', '重新挂账户也要说清成本从哪来');
  ok(await a.patch(`/holdings/${y.id}`, editBody(y, invest.id, { recordTransaction: { fromAccountId: bank.id } }), auth), '重新挂上');
  assert.equal((await netWorth('重新挂上')).netWorthCents, before - 5000, '成本从招行卡出：招行卡少 5000，持仓只补浮盈');
});

test('幂等：同一个 clientId 的开仓、加减仓重发只算一次，回放第一次的结果', async (t) => {
  const h = await investHousehold(t);
  const { bank, invest } = h;

  const open = { name: '白酒', quantityE4: 1000000, costCents: 100000, priceE4: 10000, accountId: invest.id, recordTransaction: { fromAccountId: bank.id }, clientId: 'open-1' };
  const first = await h.hold(open);
  assert.equal(first.status, 201, first.text);
  const again = await h.hold(open);
  assert.equal(again.status, 200, again.text);
  assert.equal(again.json.replayed, true);
  assert.equal(again.json.holding.id, first.json.holding.id);
  assert.equal((await h.list()).length, 1, '重发的开仓不多出一只');
  assert.equal((await h.txs()).length, 1, '也不多记一笔转账');
  const id = first.json.holding.id;

  // 同一个卖出请求连发两次：只卖一次（份额 70 万、成本 7 万、已实现 1 万），流水只有转账 + 收益两笔
  const sell = { side: 'sell', quantityE4: 300000, amountCents: 40000, occurredOn: '2026-09-20', recordTransaction: { accountId: bank.id }, clientId: 'sell-1' };
  const s1 = ok(await h.trade(id, sell), '卖出');
  const s2 = await h.trade(id, sell);
  assert.equal(s2.status, 200, s2.text);
  assert.equal(s2.json.replayed, true);
  assert.deepEqual(s2.json.holding, s1.holding, '回放的是第一次的结果');
  assert.deepEqual(s2.json.transactions, s1.transactions);
  const now = (await h.list())[0];
  assert.deepEqual([now.quantityE4, now.costCents, now.realizedCents], [700000, 70000, 10000]);
  assert.equal((await h.txs()).length, 3);

  // 换一个 clientId 就是另一笔；不带 clientId 和以前一样每次都执行
  ok(await h.trade(id, { ...sell, clientId: 'sell-2' }), '另一笔卖出');
  ok(await h.trade(id, { side: 'buy', quantityE4: 10000, amountCents: 100, occurredOn: '2026-09-20' }), '不带 clientId');
  ok(await h.trade(id, { side: 'buy', quantityE4: 10000, amountCents: 100, occurredOn: '2026-09-20' }), '不带 clientId 再来');
  assert.equal((await h.list())[0].quantityE4, 400000 + 20000);

  // 失败的请求不占用 clientId：改对了用同一个再发照常执行
  fail(await h.trade(id, { side: 'sell', quantityE4: 99999999, amountCents: 1, occurredOn: '2026-09-20', clientId: 'fix-1' }), 400, 'insufficient_quantity', '超卖');
  ok(await h.trade(id, { side: 'sell', quantityE4: 20000, amountCents: 1, occurredOn: '2026-09-20', clientId: 'fix-1' }), '改对再发');
  assert.equal((await h.list())[0].quantityE4, 400000);

  // 同一个 clientId 拿去交易另一只：说清楚，不把别的持仓的结果回给它
  const other = ok(await h.hold({ name: '另一只', quantityE4: 10000, costCents: 100 }), 'POST 另一只').holding;
  fail(await h.trade(other.id, { ...sell, clientId: 'sell-1' }), 409, 'client_id_reused', 'clientId 串用');
  fail(await h.trade(id, { ...sell, clientId: 'x'.repeat(65) }), 400, 'invalid_clientId', 'clientId 太长');
});
