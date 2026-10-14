'use strict';

// 汇率刷新与查询。抓取的解析/折算口径全在 lib/fx.js（stats.js 也读那份，保证两边数字一致）；
// 这里只管：需要哪些货币对、什么时候重抓（TTL + 定时器）、以及两个 HTTP 出口。
//
//   GET  /fx/rates?base=CNY   → {base, asOf, rates:{USD: rateE6, …}}   （member；base 省略即家庭基准币）
//   POST /fx/refresh          → {base, asOf, updated, failed, cached}   （admin；立即重抓，忽略 TTL）
//
// 基准币来自家庭设置（meta.currency，默认 CNY）。要抓的币种 = 各实体上出现过的 currency
// ∪ 显示币种，去掉基准币；只对这些抓，别把腾讯没有的冷门对也问一遍。
// 定时器仿 backup.js：setInterval(...).unref()，醒来看一眼要不要重抓。启动后马上抓一次（不然刚部署的
// 一个小时里外币全按缺汇率算）；用到的币种在表里没有时不受 TTL 限制、立刻抓（新建了一个日元账户不用等 6 小时）。
// 总览发现缺汇率时也会 kick 一下（ctx.fx.kick，最多每 10 分钟一次，免得一个腾讯没有的冷门币每次都去问）。

const { sendJson } = require('../lib/router');
const fx = require('../lib/fx');
const settings = require('./settings');
const v = require('../lib/validate');

const LAST_KEY = 'fx_last_refresh';
const TTL_MS = 6 * 60 * 60 * 1000;        // 6h：过期才自动重抓，手动刷新不受限
const KICK_MIN_MS = 10 * 60 * 1000;      // 总览缺汇率时补抓的最短间隔
const DEFAULT_TICK_MS = 60 * 60 * 1000;   // 每小时醒一次
// 显示币种默认（settings 里没配 displayCurrencies 时的兜底，和客户端 4e 的默认一致）。
const DEFAULT_DISPLAY = ['CNY', 'USD'];
// 各实体表：需要汇率的币种从这些表的 currency 列里收集（板块没有币种，余额按流水的币种分开算）。
const CURRENCY_TABLES = ['accounts', 'holdings', 'assets', 'debts', 'transactions'];

module.exports = (ctx) => {
  const { db, log } = ctx;
  let timer = null;

  /** 家庭基准币（默认 CNY）。 */
  const baseCurrency = () => settings.currentSettings(db).currency || 'CNY';

  /** 显示币种：settings.ui.displayCurrencies（合法非空数组）否则默认 [CNY, USD]。 */
  function displayCurrencies() {
    const ui = settings.currentSettings(db).ui || {};
    const list = Array.isArray(ui.displayCurrencies)
      ? ui.displayCurrencies.filter((c) => typeof c === 'string' && /^[A-Za-z]{3}$/.test(c)).map((c) => c.toUpperCase())
      : [];
    return list.length ? list : DEFAULT_DISPLAY;
  }

  /** 需要汇率的币种：各实体出现过的 currency ∪ 显示币种，去掉基准币与非法值，去重。 */
  function neededCurrencies(base) {
    const set = new Set();
    const add = (c) => {
      const s = typeof c === 'string' ? c.trim().toUpperCase() : '';
      if (/^[A-Z]{3}$/.test(s) && s !== base) set.add(s);
    };
    for (const table of CURRENCY_TABLES) {
      for (const r of db.all(`SELECT DISTINCT currency FROM ${table} WHERE currency IS NOT NULL`)) add(r.currency);
    }
    for (const c of displayCurrencies()) add(c);
    return [...set].sort();
  }

  /**
   * 抓一批汇率写进 fx_rates。`force=false` 且未过 TTL 就跳过（cached=true）。
   * 永不抛：整批失败只记日志、保留旧汇率（宁可用旧价，也不让首页因为一次网络抖动就空掉）。
   * @returns {Promise<{base: string, asOf: string|null, updated: number, failed: {currency: string, message: string}[], cached: boolean}>}
   */
  async function refresh({ force = false } = {}) {
    const base = baseCurrency();
    const last = db.meta(LAST_KEY, null);
    const currencies = neededCurrencies(base);
    // 未过 TTL 且要用的币种都有汇率才跳过；缺哪个都立刻抓。
    const have = new Set(db.all('SELECT currency FROM fx_rates WHERE base = ?', base).map((r) => r.currency));
    const missing = currencies.some((c) => !have.has(c));
    if (!force && !missing && last && Date.now() - Date.parse(last) < TTL_MS) {
      return { base, asOf: last, updated: 0, failed: [], cached: true };
    }
    const now = db.now();
    if (currencies.length === 0) {
      db.setMeta(LAST_KEY, now);
      return { base, asOf: now, updated: 0, failed: [], cached: false };
    }
    const got = await fx.fetchRates(currencies.map((currency) => ({ base, currency })));
    const failed = [];
    let updated = 0;
    db.tx(() => {
      for (const currency of currencies) {
        const r = got.get(fx.pairKey(base, currency));
        if (!r || r.error) {
          failed.push({ currency, message: r?.error || '没拿到汇率' });
          continue;
        }
        db.run(
          'INSERT INTO fx_rates(base, currency, rate_e6, updated_at) VALUES(?, ?, ?, ?)' +
            ' ON CONFLICT(base, currency) DO UPDATE SET rate_e6 = excluded.rate_e6, updated_at = excluded.updated_at',
          base, currency, r.rateE6, now,
        );
        updated++;
      }
    });
    db.setMeta(LAST_KEY, now);
    if (failed.length) log.warn('fx', `部分汇率没抓到：${failed.map((f) => `${f.currency}(${f.message})`).join(', ')}`);
    return { base, asOf: now, updated, failed, cached: false };
  }

  function getRates(req, res, c) {
    const base = c.query.base === undefined || c.query.base === '' ? baseCurrency() : v.currency(c.query.base, 'base');
    const out = fx.ratesForBase(db, base);
    sendJson(res, 200, { base: out.base, asOf: out.asOf || db.meta(LAST_KEY, null), rates: out.rates });
  }

  async function postRefresh(req, res) {
    sendJson(res, 200, await refresh({ force: true }));
  }

  /** 定时器每次醒来：未过 TTL 且不缺汇率就在 refresh 里被跳过，不会白抓。 */
  let running = null;
  function tick() {
    if (running) return running;
    running = refresh({ force: false })
      .catch((e) => log.error('fx', `定时刷新失败：${e.stack || e}`))
      .finally(() => { running = null; });
    return running;
  }

  /** 总览发现缺汇率时调：后台补抓，最多每 10 分钟一次。 */
  let lastKick = 0;
  function kick() {
    const now = Date.now();
    if (now - lastKick < KICK_MIN_MS) return;
    lastKick = now;
    tick();
  }
  ctx.fx = { kick };

  return {
    name: 'fx',
    routes: [
      { method: 'GET', pattern: '/fx/rates', handler: getRates, maxBody: 0 },
      { method: 'POST', pattern: '/fx/refresh', handler: postRefresh, auth: 'admin', maxBody: 0 },
    ],
    start() {
      const ms = Number(process.env.FX_TICK_MS) > 0 ? Number(process.env.FX_TICK_MS) : DEFAULT_TICK_MS;
      timer = setInterval(tick, ms);
      timer.unref();
      // 启动后马上抓一次（不阻塞启动；抓不到只记日志，沿用库里的旧汇率）。
      setTimeout(tick, 0).unref();
    },
    stop() {
      if (timer) clearInterval(timer);
      timer = null;
    },
    // 供测试与将来别的模块直接调用。
    refresh,
    neededCurrencies,
    baseCurrency,
    displayCurrencies,
  };
};
