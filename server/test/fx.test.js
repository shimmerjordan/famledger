'use strict';

// 汇率。钉死三件事：腾讯外汇文本的字段位（[3] 是现价、[4] 恒 0）、缺一个方向时
// 用倒数反算、以及缺汇率绝不臆造（给 error / rateTo 返回 null，而不是编个数）。
// 所有数字都对着 2026-10-13 从 qt.gtimg.cn 抓到的真实返回手算过。

const test = require('node:test');
const assert = require('node:assert/strict');

const { household } = require('./fixtures');
const { startFakeFx } = require('./fx_upstream');
const fx = require('../src/lib/fx');

function ok(r, what) {
  assert.ok(r.status >= 200 && r.status < 300, `${what} → ${r.status} ${r.text}`);
  return r.json;
}

test('fx：toE6 转 ×1e6 整数、第 7 位小数四舍五入；parseForex 只取 [3] 现价', () => {
  assert.equal(fx.toE6('6.6940'), 6694000);
  assert.equal(fx.toE6('158.0900'), 158090000);
  assert.equal(fx.toE6(' 7.4841 '), 7484100);
  assert.equal(fx.toE6('0.1234567'), 123457, '第 7 位小数进位');
  assert.equal(fx.toE6('0.1234564'), 123456);
  for (const bad of ['', '-', 'abc', '6.6.9', '-1.00', null, undefined]) assert.equal(fx.toE6(bad), null, String(bad));

  // 真实样本（2026-10-13 qt.gtimg.cn，名称换成 ASCII，字段位一字不改）：
  //   [3] 才是现价，[4] 恒为 0 —— 拿 [4] 当昨收会把汇率算成 0。
  const text = [
    'v_whUSDCNY="310~USDCNY~USDCNY~6.6940~0~20261013180539~6.6936~6.6940~6.6974~6.6930~6.6940~6.6943~0.0004~0.01~7.1430~6.6911~2026-10-13";',
    'v_whUSDJPY="310~USDJPY~USDJPY~158.0900~0~20261013180547~158.5600~158.5700~163.9800~149.3700~2026-10-13";',
    'v_whZZZCNY="310~ZZZCNY~ZZZCNY~0~0~20261013180547~0~0~2026-10-13";',
    'v_pv_none_match="1";',
  ].join('\n');
  const m = fx.parseForex(text);
  assert.deepEqual(m.get('whusdcny'), { name: 'USDCNY', priceE6: 6694000 });
  assert.deepEqual(m.get('whusdjpy'), { name: 'USDJPY', priceE6: 158090000 });
  assert.deepEqual(m.get('whzzzcny'), { error: '没有这个汇率' }, '现价 0（没开盘/无此对）记成错误');
  assert.equal(m.has('pv_none_match'), false, '非 wh 前缀不收录');
});

test('fx：fetchRates 直接方向、倒数反算、同币 1e6、缺对给 error', async (t) => {
  const up = await startFakeFx();
  t.after(() => up.stop());
  up.state.rates = { whUSDCNY: '6.6940', whEURCNY: '7.4841' };

  const got = await fx.fetchRates(
    [
      { base: 'USD', currency: 'CNY' }, // 直接 whUSDCNY 有 → 1 USD = 6.694 CNY
      { base: 'CNY', currency: 'USD' }, // 直接 whCNYUSD 没有 → 用倒数 whUSDCNY 反算
      { base: 'CNY', currency: 'CNY' }, // 同币
      { base: 'CNY', currency: 'XXX' }, // 两个方向都没有
    ],
    { base: up.base, timeoutMs: 2000 },
  );

  assert.deepEqual(got.get('USD/CNY'), { rateE6: 6694000, via: 'USDCNY' });
  // 1 CNY = 1e6/6694000 USD → round(1e12/6694000) = 149388
  assert.deepEqual(got.get('CNY/USD'), { rateE6: 149388, via: '1/USDCNY' });
  assert.deepEqual(got.get('CNY/CNY'), { rateE6: 1000000, via: 'same' });
  assert.equal(got.get('CNY/XXX').error !== undefined, true, '缺对给 error，不臆造');
});

test('fx：toBase 折算按整数分四舍五入、缺汇率 null、负数对称', () => {
  // base=CNY、native=USD、rate=149388（1 CNY = 0.149388 USD）：$100.00 → ¥669.40
  assert.equal(fx.toBase(10000, 149388), 66940);
  assert.equal(fx.toBase(-10000, 149388), -66940, '负数按绝对值四舍五入');
  assert.equal(fx.toBase(12345, 1000000), 12345, '同币原样返回');
  assert.equal(fx.toBase(12345, null), null, '缺汇率返回 null，由调用方决定显示');
});

/** 等服务启动时那一次自动抓取落库（最多 3 秒）。 */
async function waitRates(a, auth, want) {
  for (let i = 0; i < 60; i++) {
    const r = ok(await a.get('/fx/rates', auth), 'GET /fx/rates');
    if (want.every((c) => r.rates[c] !== undefined)) return r;
    await new Promise((res) => setTimeout(res, 50));
  }
  assert.fail(`等不到汇率 ${want.join(',')}`);
}

test('fx：服务一起来就抓汇率（不等一小时）；请求用大写代码（腾讯只认大写）', async (t) => {
  const up = await startFakeFx();
  t.after(() => up.stop());
  up.state.rates = { whUSDCNY: '6.6940' };

  const h = await household(t, { FX_BASE: up.base });
  const { a, auth } = h;

  // 基准币默认 CNY，显示币种默认含 USD —— 即便还没有任何美元账户也该抓到 USD。
  const got = await waitRates(a, auth, ['USD']);
  assert.equal(got.base, 'CNY');
  assert.equal(got.rates.USD, 149388, 'USD 由倒数 whUSDCNY 反算入库');
  assert.ok(got.asOf, '带上最近更新时间');
  assert.ok(up.state.requests.some((p) => p.includes('whUSDCNY')), `请求里是大写：${up.state.requests.join(' ')}`);
  assert.ok(!up.state.requests.some((p) => /whusdcny/.test(p)), '不能发小写代码，腾讯回 none_match');

  const refreshed = ok(await a.post('/fx/refresh', {}, auth), 'POST /fx/refresh');
  assert.equal(refreshed.cached, false, '手动刷新不受缓存限制');
  assert.deepEqual(refreshed.failed, []);

  // base 参数非法（不是 3 位字母）照常 400。
  const bad = await a.get('/fx/rates?base=CN', auth);
  assert.equal(bad.status, 400);
  assert.equal(bad.json.error.code, 'invalid_base');
});

test('fx：新用到一个币种，不等 6 小时缓存过期就去抓；总览缺汇率也会补抓', async (t) => {
  const up = await startFakeFx();
  t.after(() => up.stop());
  up.state.rates = { whUSDCNY: '6.6940', whJPYCNY: '0.0472' };

  const h = await household(t, { FX_BASE: up.base });
  const { a, auth } = h;
  await waitRates(a, auth, ['USD']);

  // 刚抓过（在缓存期内），但日元是新用到的：总览发现缺汇率 → 后台补抓。
  ok(await a.post('/accounts', { name: '日元户', kind: 'bank', currency: 'JPY', initialBalanceCents: 100000 }, auth), 'POST 日元户');
  const first = ok(await a.get('/stats/overview', auth), 'GET /stats/overview');
  assert.deepEqual(first.fx.missing, ['JPY'], '刚建的这一刻还没有日元汇率');
  const after = await waitRates(a, auth, ['JPY']);
  assert.equal(after.rates.JPY, Math.round(1e12 / 47200), '1 CNY = 1/0.0472 JPY');
  const second = ok(await a.get('/stats/overview', auth), 'GET /stats/overview');
  assert.deepEqual(second.fx.missing, []);
  assert.equal(second.byCurrency.JPY.netWorthCents, 100000, '日元的原生合计');
});
