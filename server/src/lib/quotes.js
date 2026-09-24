'use strict';

// 行情。只有一家上游：腾讯行情，网页用的非官方接口，没有 SLA。
//
//   GET {QUOTE_STOCK_BASE}/q=jj161725,sh600519,… → GBK 文本，一行一只
//   场外基金  jj{代码}        只有上一交易日的单位净值：盘中估值 2025 年起被叫停，
//                             原来用的天天基金估值接口也已下线
//   沪深北    sh/sz/bj{代码}  现价与昨收
//
// 基金和股票分成两个批次各自请求：一批整体失败（超时、5xx、连不上）只算那一批失败，
// 另一类照常；批内拉不到的也只算那一只失败。调用方据此保留旧价，绝不能一处坏了拖垮整次刷新。
//
// 价格一律按字符串转成 ×10000 的整数，不经过浮点：1.0301 走一趟 parseFloat 再乘回来，
// 偶尔就是 10300.999…，一取整就差一分。

const DEFAULT_BASE = 'https://qt.gtimg.cn';
const DEFAULT_TIMEOUT_MS = 8000;
// 一个 URL 塞太多代码会被截断，60 个远在安全线内。
const BATCH = 60;

class QuoteError extends Error {}

/** 与 server.js 的 envInt 同义：缺失或非法一律回默认值。 */
function envInt(name, dflt) {
  const n = Number(process.env[name]);
  return Number.isInteger(n) && n > 0 ? n : dflt;
}

function config() {
  return {
    // 基金也走这个变量：同一家上游，分开配只会让两类指到不同的服务上去。
    base: (process.env.QUOTE_STOCK_BASE || DEFAULT_BASE).replace(/\/+$/, ''),
    timeoutMs: envInt('QUOTE_TIMEOUT_MS', DEFAULT_TIMEOUT_MS),
  };
}

/** `1.0301` → 10301；第 5 位小数四舍五入；不是非负十进制数就是 null。 */
function toE4(raw) {
  const m = /^(\d{1,11})(?:\.(\d+))?$/.exec(String(raw ?? '').trim());
  if (!m) return null;
  const frac = (m[2] || '').padEnd(5, '0');
  return Number(m[1]) * 10000 + Number(frac.slice(0, 4)) + (Number(frac[4]) >= 5 ? 1 : 0);
}

/**
 * 基金行情不给上一净值，只给日涨跌幅（百分比），反推 nav / (1 + pct/100) 再四舍五入。
 * 走 BigInt 是因为净值 ×10000 再乘上小数位的放大倍数会越过 2^53。拿不准就给 null ——
 * 瞎猜一个昨收，App 上的今日涨跌就是凭空编的。
 */
function prevFromPct(navE4, raw) {
  const m = /^([+-]?)(\d{1,4})(?:\.(\d{1,10}))?$/.exec(String(raw ?? '').trim());
  if (!m) return null;
  const frac = m[3] || '';
  const scale = 10n ** BigInt(frac.length);
  const pct = BigInt(m[2] + frac) * (m[1] === '-' ? -1n : 1n);
  const den = 100n * scale + pct;
  if (den <= 0n) return null;
  const num = BigInt(navE4) * 100n * scale;
  const prev = Number((num * 2n + den) / (2n * den));
  return prev > 0 ? prev : null;
}

/** 持仓在 fetchQuotes 结果里的键：同一个代码在基金和深市是两只东西。 */
const quoteKey = (market, code) => `${market}:${String(code).toLowerCase()}`;

/**
 * 腾讯行情文本 → 符号（如 `jj161725`、`sh600519`）→ 行情。字段以 `~` 分隔，两类各取各的：
 *   jj        [1] 名称、[5] 单位净值、[7] 日涨跌幅(%)；[2][3] 是废弃的估值，恒为 0，不能用
 *   sh/sz/bj  [1] 名称、[3] 现价、[4] 昨收；停牌或开盘前现价是 0，退回昨收，否则市值会凭空归零
 * 基金净值为 0 记成这只的错误；股票没有可用价格就不收录，调用方按「没有这个代码」处理。
 * @returns {Map<string, {name: string, priceE4: number, prevCloseE4: number|null}|{error: string}>}
 */
function parseTencent(text) {
  const out = new Map();
  for (const m of text.matchAll(/v_([a-z]{2}[0-9A-Za-z]+)="([^"]*)"/g)) {
    const sym = m[1].toLowerCase();
    const f = m[2].split('~');
    if (sym.startsWith('jj')) {
      const nav = toE4(f[5]);
      if (!(nav > 0)) {
        out.set(sym, { error: '没有这只基金的净值' });
        continue;
      }
      out.set(sym, { name: String(f[1] ?? '').trim(), priceE4: nav, prevCloseE4: prevFromPct(nav, f[7]) });
      continue;
    }
    if (f.length < 5) continue;
    const price = toE4(f[3]);
    const prev = toE4(f[4]);
    const p = price > 0 ? price : prev;
    if (!(p > 0)) continue;
    out.set(sym, { name: f[1].trim(), priceE4: p, prevCloseE4: prev > 0 ? prev : null });
  }
  return out;
}

async function fetchText(url, { timeoutMs }) {
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(timeoutMs), headers: { accept: '*/*' } });
    if (!res.ok) {
      await res.body?.cancel().catch(() => {});
      throw new QuoteError(`行情服务返回 ${res.status}`);
    }
    return new TextDecoder('gbk').decode(await res.arrayBuffer());
  } catch (e) {
    if (e instanceof QuoteError) throw e;
    if (e && (e.name === 'TimeoutError' || e.name === 'AbortError')) throw new QuoteError('行情服务超时');
    throw new QuoteError('连不上行情服务');
  }
}

const messageOf = (e) => (e instanceof QuoteError ? e.message : '行情解析出错');

/**
 * 一次拉齐一批持仓的行情。永不抛：每个键要么是行情，要么是 `{error}`。
 * @param {{market: 'fund'|'sh'|'sz'|'bj', code: string}[]} items
 * @returns {Promise<Map<string, {name: string, priceE4: number, prevCloseE4: number|null}|{error: string}>>}
 */
async function fetchQuotes(items, opts = {}) {
  const cfg = { ...config(), ...opts };
  const out = new Map();
  // 符号 → 结果键；Map 顺带去重，同一只持有两份也只问一次。
  const funds = new Map();
  const stocks = new Map();
  for (const i of items) {
    const code = String(i.code).toLowerCase();
    if (i.market === 'fund') funds.set(`jj${code}`, quoteKey('fund', code));
    else stocks.set(`${i.market}${code}`, quoteKey(i.market, code));
  }

  async function job(symbols, missing) {
    const syms = [...symbols.keys()];
    for (let i = 0; i < syms.length; i += BATCH) {
      const batch = syms.slice(i, i + BATCH);
      let found = null;
      let error = null;
      try {
        const url = `${cfg.base}/q=${batch.map(encodeURIComponent).join(',')}`;
        found = parseTencent(await fetchText(url, { timeoutMs: cfg.timeoutMs }));
      } catch (e) {
        error = messageOf(e);
      }
      for (const sym of batch) out.set(symbols.get(sym), found?.get(sym) || { error: error || missing });
    }
  }

  await Promise.all([job(funds, '行情里没有这只基金'), job(stocks, '行情里没有这个代码')]);
  return out;
}

module.exports = { fetchQuotes, parseTencent, toE4, quoteKey, QuoteError };
