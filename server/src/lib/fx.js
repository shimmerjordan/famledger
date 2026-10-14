'use strict';

// 汇率。和行情同一家上游（腾讯 qt.gtimg.cn，GBK 文本、`~` 分隔、无 SLA），只是取的是外汇（`wh` 前缀）：
//
//   GET {FX_BASE}/q=whUSDCNY,whEURCNY,…  → `v_whUSDCNY="310~美元人民币~USDCNY~6.6940~0~…~2026-10-13"`
//   字段：[1] 名称、[2] 代码、[3] 现价（外汇的 [4] 恒为 0，不是昨收，别拿它当价）
//
// 腾讯的外汇代码**区分大小写**：`whUSDCNY` 有、`whusdcny` 回 `v_pv_none_match`。请求一律用大写，
// 解析出来的 Map 键才统一成小写。
//
// 汇率存进 fx_rates：一行 (base, currency, rate_e6) 表示「1 单位 base = rate_e6/1e6 单位 currency」，
// 整数存避免浮点误差。腾讯的 `wh{A}{B}` 报的是「1 A = X B」，方向不一定和 (base→currency) 一致，
// 所以每一对都问两个方向：直接 `wh{base}{currency}` 拿到就用，否则拿倒数 `wh{currency}{base}` 反算。
//
// 缺汇率绝不臆造：fetchRates 永不抛，逐对给 `{rateE6}` 或 `{error}`；rateTo 缺行返回 null，
// 调用方（stats.js 聚合、客户端显示）据此只显示原生币并标「汇率缺失」，而不是编一个数字出来。

const { fetchText, QuoteError } = require('./quotes');

const DEFAULT_BASE = 'https://qt.gtimg.cn';
const DEFAULT_TIMEOUT_MS = 8000;
// 一个 URL 塞太多符号会被截断，60 个远在安全线内（和 quotes.js 同一个上限）。
const BATCH = 60;
const E6 = 1000000;

/** 与 server.js 的 envInt 同义：缺失或非法一律回默认值。 */
function envInt(name, dflt) {
  const n = Number(process.env[name]);
  return Number.isInteger(n) && n > 0 ? n : dflt;
}

function config() {
  return {
    // 和行情共用一家上游：FX_BASE 优先，没配就跟着 QUOTE_STOCK_BASE 走（测试里一个假源喂两边）。
    base: (process.env.FX_BASE || process.env.QUOTE_STOCK_BASE || DEFAULT_BASE).replace(/\/+$/, ''),
    timeoutMs: envInt('FX_TIMEOUT_MS', envInt('QUOTE_TIMEOUT_MS', DEFAULT_TIMEOUT_MS)),
  };
}

/** `6.6940` → 6694000（×1e6，第 7 位小数四舍五入）；不是非负十进制数就是 null。 */
function toE6(raw) {
  const m = /^(\d{1,9})(?:\.(\d+))?$/.exec(String(raw ?? '').trim());
  if (!m) return null;
  const frac = (m[2] || '').padEnd(7, '0');
  return Number(m[1]) * E6 + Number(frac.slice(0, 6)) + (Number(frac[6]) >= 5 ? 1 : 0);
}

/** 腾讯外汇符号：`wh{from}{to}`（币种码大写）。 */
const forexSymbol = (from, to) => `wh${String(from).toUpperCase()}${String(to).toUpperCase()}`;

/** fetchRates 结果 Map 的键：`{base}/{currency}`。 */
const pairKey = (base, currency) => `${base}/${currency}`;

const messageOf = (e) => (e instanceof QuoteError ? e.message : '汇率解析出错');

/**
 * 腾讯外汇文本 → 小写符号（如 `whusdcny`）→ `{name, priceE6}` 或 `{error}`。
 * 只认 `wh` 前缀、6 位币种码；现价为 0（还没开盘/接口没这个对）记成这对的错误。
 * @returns {Map<string, {name: string, priceE6: number}|{error: string}>}
 */
function parseForex(text) {
  const out = new Map();
  for (const m of text.matchAll(/v_(wh[A-Za-z]{6})="([^"]*)"/g)) {
    const sym = m[1].toLowerCase();
    const f = m[2].split('~');
    const price = toE6(f[3]);
    if (!(price > 0)) {
      out.set(sym, { error: '没有这个汇率' });
      continue;
    }
    out.set(sym, { name: String(f[1] ?? '').trim(), priceE6: price });
  }
  return out;
}

/**
 * 一次拉齐一批货币对的汇率。永不抛：每一对要么 `{rateE6, via}`，要么 `{error}`。
 * @param {{base: string, currency: string}[]} pairs
 * @returns {Promise<Map<string, {rateE6: number, via?: string}|{error: string}>>}
 */
async function fetchRates(pairs, opts = {}) {
  const cfg = { ...config(), ...opts };
  const out = new Map();
  /** @type {Map<string, {base: string, currency: string}>} 去重后的待抓对 */
  const unique = new Map();
  for (const p of pairs) {
    const base = String(p.base || '').toUpperCase();
    const currency = String(p.currency || '').toUpperCase();
    if (!/^[A-Z]{3}$/.test(base) || !/^[A-Z]{3}$/.test(currency)) continue;
    if (base === currency) {
      out.set(pairKey(base, currency), { rateE6: E6, via: 'same' });
      continue;
    }
    unique.set(pairKey(base, currency), { base, currency });
  }

  // 每一对问两个方向；同一符号被多对需要也只抓一次。符号保持大写（腾讯只认大写）。
  const syms = new Set();
  for (const { base, currency } of unique.values()) {
    syms.add(forexSymbol(base, currency));
    syms.add(forexSymbol(currency, base));
  }

  /** @type {Map<string, {name: string, priceE6: number}|{error: string}>} */
  const got = new Map();
  const list = [...syms];
  for (let i = 0; i < list.length; i += BATCH) {
    const batch = list.slice(i, i + BATCH);
    let parsed = null;
    let error = null;
    try {
      const url = `${cfg.base}/q=${batch.map(encodeURIComponent).join(',')}`;
      parsed = parseForex(await fetchText(url, { timeoutMs: cfg.timeoutMs }));
    } catch (e) {
      error = messageOf(e);
    }
    // 一批整体失败只算这一批的符号失败，别的批照常；批内没返回的也算那一个符号失败。
    for (const sym of batch) {
      const key = sym.toLowerCase();
      got.set(key, parsed?.get(key) || { error: error || '行情里没有这个汇率' });
    }
  }

  for (const { base, currency } of unique.values()) {
    const key = pairKey(base, currency);
    const direct = got.get(forexSymbol(base, currency).toLowerCase());
    const inverse = got.get(forexSymbol(currency, base).toLowerCase());
    if (direct && !direct.error && direct.priceE6 > 0) {
      // `wh{base}{currency}` 报的就是「1 base = X currency」，正是要的 rate_e6。
      out.set(key, { rateE6: direct.priceE6, via: `${base}${currency}` });
    } else if (inverse && !inverse.error && inverse.priceE6 > 0) {
      // `wh{currency}{base}` 报「1 currency = P base」→ 1 base = 1e6/P currency。
      // P 已是 ×1e6 的整数，1e12/P 正好是 ×1e6 的倒数，四舍五入到整数。
      out.set(key, { rateE6: Math.round(1e12 / inverse.priceE6), via: `1/${currency}${base}` });
    } else {
      out.set(key, { error: direct?.error || inverse?.error || '没有这一对汇率' });
    }
  }
  return out;
}

// ------------------------------------------------------------------ db 读取（stats.js 与 modules/fx.js 共用一份口径）

/**
 * (base, currency) 的 rate_e6：同币恒 `1e6`，表里没有这一对返回 null（绝不臆造）。
 * @param {object} db lib/db.js 的句柄
 */
function rateTo(db, base, currency) {
  const b = String(base || '').toUpperCase();
  const c = String(currency || '').toUpperCase();
  if (!/^[A-Z]{3}$/.test(b) || !/^[A-Z]{3}$/.test(c)) return null;
  if (b === c) return E6;
  const row = db.get('SELECT rate_e6 FROM fx_rates WHERE base = ? AND currency = ?', b, c);
  return row ? Number(row.rate_e6) : null;
}

/**
 * 某个 base 的全部汇率 → `{base, asOf, rates:{USD: rateE6, …}}`。asOf 取这批里最新的 updated_at。
 */
function ratesForBase(db, base) {
  const b = String(base || '').toUpperCase();
  const rows = db.all('SELECT currency, rate_e6, updated_at FROM fx_rates WHERE base = ?', b);
  const rates = {};
  let asOf = null;
  for (const r of rows) {
    rates[r.currency] = Number(r.rate_e6);
    if (!asOf || r.updated_at > asOf) asOf = r.updated_at;
  }
  return { base: b, asOf, rates };
}

/**
 * 把 `amount`（native 币的整数分）折到 base 币，四舍五入到整数分。
 * `rateE6 = rateTo(base, native)`（1 base = rateE6/1e6 native），所以
 * `amount_base = amount_native / (rateE6/1e6) = amount_native × 1e6 / rateE6`。
 * 走 BigInt 是因为大额 ×1e6 会越过 2^53；rateE6 为 null（缺汇率）时返回 null，由调用方决定怎么显示。
 */
function toBase(amount, rateE6) {
  if (rateE6 === null || rateE6 === undefined) return null;
  const r = BigInt(rateE6);
  if (r <= 0n) return null;
  if (r === BigInt(E6)) return amount;
  const num = BigInt(amount) * BigInt(E6);
  const sign = num < 0n ? -1n : 1n;
  const abs = num < 0n ? -num : num;
  return Number(sign * ((abs * 2n + r) / (2n * r))); // 按绝对值四舍五入，负数对称
}

module.exports = {
  fetchRates, parseForex, toE6, toBase, forexSymbol, pairKey, rateTo, ratesForBase, config, E6,
};
