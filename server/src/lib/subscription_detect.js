'use strict';

// 从流水识别订阅（spec §4 `GET /asset-import/candidates?months=13`、§6「从流水」）：纯规则、不花 token、不查库。
//
//   detectSubscriptions(txs, {today, months, cards, assets}) → 候选分组（排好序的全部；接口只回前 MAX_GROUPS 组）
//   merchantOf(tx) → {key, label, fromNote} | null   归一化商户：商户名（空就用备注，fromNote 为真）去掉支付渠道前缀和长串数字
//   CANDIDATE_TX_SQL                             候选流水的查询（测试对它跑 EXPLAIN QUERY PLAN，钉住走 idx_tx_occurred）
//
//   txs     确认过的支出（id, occurred_at, amount_cents, merchant, note）—— 调用方的 SQL 已按口径筛过
//   cards   没归档的存活会员（id, name, pay_pattern, last_charge_tx_id）—— 标「已关联」用
//   assets  关联了流水的存活物品（id, name, transaction_id）—— 同样标「已关联」（和 P6 charge_hints 一个口径：
//           是哪张卡的上次扣费、或者是哪件物品的购买流水，都算这笔流水已经有主了）
//
// 口径：
//   · 只看 ¥1–¥5000、落在 [today − months 个月, today] 的（SQL 已筛，这里再筛一遍，纯函数自己说了算）；
//   · 同一个归一化商户下按「金额档」分组：金额从小到大，不超过这一档最低价 15% 的算同一档（涨价、首月优惠会分成两组）；
//   · 周期：扣费日（同一天算一次）间隔的中位数落在 25–35 天算月付、80–100 天季付、330–400 天年付；
//   · 进名单的：看出了周期，或者商户名、备注里有「会员 / VIP / 年卡 / 包月 / 自动续费 / 订阅 …」（88VIP 一年只扣一次）；
//     偶尔买一次的、隔三差五去一次的店不进名单。中文关键词按规范化后的子串比；英文的（vip、plus、premium…）按词比：
//     前后不能紧挨着英文字母，也不算域名里的（唯品会的 vip.com、plus.example.com）；店名里的「会员店 / 会员商店」
//     （山姆会员商店这类仓储超市）不算「会员」；
//   · 打分（整数）：关键词 +3、看出周期 +2、间隔规整 +1、扣过 ≥3 次 +1、每次金额一样 +1、整元 +1、
//     还在扣（最近一次 + 一个周期 + 15 天宽限期还没过）+1，不在扣了 −3；
//   · 默认勾选：分数 ≥4、没关联，而且不是「只扣过一次、名字里又没有年费 / 包年 / 年卡 / 会员费 / 自动续费 / 连续包月
//     这类强关键词」的（原因里记 once）—— 只买过一次的东西（iPhone 16 Plus 保护壳）带个泛泛的关键词，分数也能凑到 4；
//   · 已关联：某张卡的扣费特征对得上这组最近一笔、这组里有一笔是那张卡的「上次扣费」→ 标出是哪张卡；这组里有一笔是
//     某件物品的购买流水 → 标出是哪件物品（linked.assetId）；
//   · 排序：分数 → 次数 → 最近一次（新的在前）→ key。同样的流水永远同样的名单、同样的顺序。
//   · key = 'g_' + sha1(归一化商户 | 这一档最低价) 的前 12 位：candidates 和 extract 各算一遍，对得上就是同一组。

const crypto = require('node:crypto');

const { normalizeName, addDays, addPeriod } = require('./perks_schema');
const { readPayPattern, matchesPayPattern } = require('./charge_hints');
const { CONFIRMED } = require('./stats_sql');

const MIN_CENTS = 100;
const MAX_CENTS = 500000;
const DEFAULT_MONTHS = 13;
const MAX_MONTHS = 24;
const MAX_GROUPS = 40;
const CHECK_SCORE = 4;
/** 同一档：不超过这一档最低价的 1.15 倍。 */
const BAND_RATIO = 1.15;
/** 过了「最近一次 + 一个周期」再宽限这么多天还没扣，算不在扣了（和 P3 的宽限期一样）。 */
const GRACE_DAYS = 15;
const MAX_LABEL = 40;

/**
 * 候选流水（参数：金额下限、上限，occurred_at 的下界、上界，左闭右开）：确认过的支出。和 charge_hints 一样按 occurred_at 的
 * 字符串区间走 idx_tx_occurred —— `+type` 让这一项不参与选索引，不然 SQLite 会挑 idx_tx_dedupe(type, …) 把所有支出扫一遍。
 * 一户人家 13 个月的流水到不了 2 万笔；真到了，只看最近的 2 万笔。
 */
const CANDIDATE_TX_SQL =
  `SELECT id, occurred_at, amount_cents, merchant, note FROM transactions WHERE ${CONFIRMED} AND +type = 'expense'` +
  ' AND amount_cents >= ? AND amount_cents <= ? AND occurred_at >= ? AND occurred_at < ?' +
  ' ORDER BY occurred_at DESC, id DESC LIMIT 20000';

const PERIODS = [
  { period: 'month', min: 25, max: 35 },
  { period: 'quarter', min: 80, max: 100 },
  { period: 'year', min: 330, max: 400 },
];
/** 商户名、备注里有这些字（规范化后按子串比）就像订阅。applecombill 是 Apple 扣费的抬头「APPLE.COM/BILL」。 */
const KEYWORDS = ['会员', '会籍', '年卡', '季卡', '月卡', '年费', '包月', '包季', '包年', '连续包', '自动续费', '订阅', 'icloud', 'applecombill'];
/** 英文的泛词按词比（见 englishKeyword）：前后不能紧挨着英文字母，也不能是域名的一段。「88VIP」「腾讯视频VIP」照样算。 */
const WORD_KEYWORDS = ['vip', 'plus', 'premium', 'subscription', 'membership'];
/** 店名里的「会员」：仓储超市的日常购物，不是会员费（规范化后先从文字里去掉再找关键词）。 */
const NOT_MEMBERSHIP = ['会员商店', '会员店', '会员超市', '会员价'];
/** 只扣过一次的组，名字里有这些才默认勾（年费一年只扣一次；泛泛的「会员 / VIP / Plus」不够）。 */
const STRONG_KEYWORDS = ['年费', '包年', '年卡', '会员费', '自动续费', '连续包', '88vip'];
/** 看不出周期时按字面猜：年卡、包月…… */
const PERIOD_HINTS = [
  ['year', /年卡|年费|包年|年度|88vip/],
  ['quarter', /季卡|包季|季度/],
  ['month', /月卡|包月|月度/],
];
/** 支付渠道前缀：「财付通-腾讯视频」「支付宝 - 淘宝」「微信支付（爱奇艺）」只留后面的真商户。后面必须跟分隔符，「微信读书」不动。 */
const PAY_PREFIX = /^(?:财付通|支付宝|微信支付|京东支付|云闪付|银联|美团支付|抖音支付|快捷支付|网上支付)\s*[-_—–:：·|/（(]\s*/;

const dayOf = (tx) => String(tx.occurred_at).slice(0, 10);
const dayMs = (day) => Date.parse(`${day}T00:00:00Z`);
const daysBetween = (a, b) => Math.round((dayMs(b) - dayMs(a)) / 86400000);
const cmp = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

function median(sorted) {
  const n = sorted.length;
  if (!n) return null;
  const mid = Math.floor(n / 2);
  return n % 2 ? sorted[mid] : Math.round((sorted[mid - 1] + sorted[mid]) / 2);
}

/** 空白或标点（去两头用）。 */
const EDGE = /[\s\p{P}]/u;

/** 去掉两头的空白和标点：逐个字符往里收，线性（不用 /[\s\p{P}]+$/ —— 中间一长串标点时它每个起点都要扫到头再退回来）。 */
function trimEdges(s) {
  const chars = [...s];
  let a = 0;
  let b = chars.length;
  while (a < b && EDGE.test(chars[a])) a++;
  while (b > a && EDGE.test(chars[b - 1])) b--;
  return chars.slice(a, b).join('');
}

/**
 * 归一化商户：{key（规范化、≤40）、label（给人看的写法、≤40）、fromNote（商户名是空的、用的是备注）}；商户名和备注都是空的回 null。
 * 备注最长 1000 字，只看开头 200 字（label 本来就只留 40 字）。
 */
function merchantOf(tx) {
  const merchant = String(tx.merchant || '').trim();
  let s = (merchant || String(tx.note || '').trim()).slice(0, 200);
  if (!s) return null;
  s = s.normalize('NFKC');
  for (let i = 0; i < 2 && PAY_PREFIX.test(s); i++) s = s.replace(PAY_PREFIX, '');
  // 订单号、流水号这类长串数字每次都不一样，去掉；两头的标点（「腾讯视频）」）也去掉。
  const label = trimEdges(s.replace(/\d{5,}/g, '')).replace(/\s+/g, ' ').slice(0, MAX_LABEL);
  const key = normalizeName(label).slice(0, MAX_LABEL);
  return key ? { key, label, fromNote: !merchant } : null;
}

const isLetter = (c) => c !== undefined && c >= 'a' && c <= 'z';

/**
 * 商户名或备注（小写、NFKC 之后）里有没有英文关键词，按词比：先按「不是字母、数字、点、短横」切成一段一段（中文字、空格、
 * 标点都是分隔），像域名的一段（vip.com、m.vip.com：点前是字母数字、点后是字母）整段不看；其余的段里关键词前后都不能
 * 紧挨着英文字母 ——「88vip」「腾讯视频vip会员」算，「vipshop」不算。只用 split + indexOf，不写回溯的正则。
 */
function englishKeyword(raw) {
  for (const token of raw.split(/[^a-z0-9.-]+/)) {
    if (!token || /[a-z0-9-]\.[a-z]/.test(token)) continue;
    for (const k of WORD_KEYWORDS) {
      for (let i = token.indexOf(k); i >= 0; i = token.indexOf(k, i + 1)) {
        if (!isLetter(token[i - 1]) && !isLetter(token[i + k.length])) return true;
      }
    }
  }
  return false;
}

/** 这一组最常见的写法（一样多取最近出现的）。 */
function labelOf(items) {
  const count = new Map();
  for (const it of items) count.set(it.label, (count.get(it.label) || 0) + 1);
  let best = null;
  for (const it of [...items].reverse()) {
    if (best === null || count.get(it.label) > count.get(best)) best = it.label;
  }
  return best;
}

/** 扣费日间隔的中位数 → 周期；看不出来是 null。 */
function periodOfGaps(gaps) {
  const m = median([...gaps].sort((a, b) => a - b));
  if (m === null) return null;
  return PERIODS.find((p) => m >= p.min && m <= p.max) || null;
}

/** 看不出周期时猜一个：字面上说了就按字面，只扣过一次按年，扣过几次按间隔大致归一档。 */
function guessPeriod(text, gaps) {
  const hint = PERIOD_HINTS.find(([, re]) => re.test(text));
  if (hint) return { period: hint[0], source: 'keyword' };
  if (!gaps.length) return { period: 'year', source: 'guess' };
  const m = median([...gaps].sort((a, b) => a - b));
  return { period: m < 60 ? 'month' : m < 200 ? 'quarter' : 'year', source: 'guess' };
}

/** 一组（同商户同一档）→ 候选；进不了名单回 null。items 已按日期、id 排好。 */
function scoreGroup(key, items, { today, cards, assetOf }) {
  const days = [...new Set(items.map((it) => it.day))].sort();
  const gaps = days.slice(1).map((d, i) => daysBetween(days[i], d));
  // 商户名和备注分开处理再拼（拼在一起会造出原本没有的词），每笔都只看开头 200 字。
  const raw = items.flatMap((it) => [it.tx.merchant, it.tx.note]).map((x) => String(x || '').slice(0, 200).normalize('NFKC').toLowerCase());
  let text = raw.map(normalizeName).join('|');
  for (const w of NOT_MEMBERSHIP) text = text.split(w).join('|');
  const keyword = KEYWORDS.some((k) => text.includes(k)) || raw.some(englishKeyword);
  const strong = STRONG_KEYWORDS.some((k) => text.includes(k));
  const observed = periodOfGaps(gaps);
  if (!keyword && !observed) return null;

  const amounts = items.map((it) => it.tx.amount_cents).sort((a, b) => a - b);
  const amountCents = median(amounts);
  const minCents = amounts[0];
  const maxCents = amounts[amounts.length - 1];
  const { period, source } = observed ? { period: observed.period, source: 'observed' } : guessPeriod(text, gaps);
  const last = items[items.length - 1];
  const lastOn = last.day;
  const nextOn = addPeriod(lastOn, period);
  const active = today <= addDays(nextOn, GRACE_DAYS);
  const regular = observed !== null && gaps.length >= 2 && gaps.filter((g) => g >= observed.min && g <= observed.max).length / gaps.length >= 0.75;

  const reasons = [];
  let score = 0;
  const add = (ok, points, why) => {
    if (!ok) return;
    score += points;
    reasons.push(why);
  };
  add(keyword, 3, 'keyword');
  add(observed !== null, 2, 'period');
  add(regular, 1, 'regular');
  add(items.length >= 3, 1, 'count');
  add(items.length >= 2 && minCents === maxCents, 1, 'same_amount');
  add(amountCents % 100 === 0, 1, 'round');
  add(active, 1, 'active');
  add(!active, -3, 'stale');
  // 只扣过一次、又没有强关键词：照样列出来，但不默认勾（原因里记一笔，App 照着说「把握不大」）。
  const once = items.length === 1 && !strong;
  if (once) reasons.push('once');

  const txIds = new Set(items.map((it) => it.tx.id));
  const card = cards.find((c) => {
    if (c.last_charge_tx_id && txIds.has(c.last_charge_tx_id)) return true;
    const pattern = readPayPattern(c.pay_pattern);
    return pattern !== null && matchesPayPattern(pattern, last.tx);
  });
  const asset = card ? null : items.map((it) => assetOf.get(it.tx.id)).find(Boolean) || null;
  const label = labelOf(items);
  return {
    key: `g_${crypto.createHash('sha1').update(`${key}|${minCents}`).digest('hex').slice(0, 12)}`,
    merchant: label,
    amountCents,
    minCents,
    maxCents,
    count: items.length,
    period,
    periodSource: source,
    firstOn: items[0].day,
    lastOn,
    nextOn,
    score,
    reasons,
    checked: score >= CHECK_SCORE && !card && !asset && !once,
    linked: card ? { membershipId: card.id, name: card.name } : asset ? { assetId: asset.id, name: asset.name } : null,
    lastTransactionId: last.tx.id,
    // 商户名全是从备注来的：「AI 整理名称」不把它发给模型（备注是私事），用金额和周期拼的占位名代替。
    fromNote: items.every((it) => it.fromNote),
  };
}

/**
 * @param {object[]} txs
 * @param {{today:string, months?:number, cards?:object[], assets?:object[]}} opts
 * @returns {object[]} 候选分组（全部，已排序）
 */
function detectSubscriptions(txs, { today, months = DEFAULT_MONTHS, cards = [], assets = [] }) {
  const from = addPeriod(today, 'month', -months);
  const assetOf = new Map();
  for (const a of assets) if (a.transaction_id && !assetOf.has(a.transaction_id)) assetOf.set(a.transaction_id, a);
  const byMerchant = new Map(); // 归一化商户 → [{tx, day, label}]
  for (const tx of txs) {
    const day = dayOf(tx);
    if (day < from || day > today) continue;
    if (!Number.isInteger(tx.amount_cents) || tx.amount_cents < MIN_CENTS || tx.amount_cents > MAX_CENTS) continue;
    const m = merchantOf(tx);
    if (!m) continue;
    if (!byMerchant.has(m.key)) byMerchant.set(m.key, []);
    byMerchant.get(m.key).push({ tx, day, label: m.label, fromNote: m.fromNote });
  }
  const out = [];
  for (const [key, list] of byMerchant) {
    // 金额档：从便宜到贵，超过这一档最低价 15% 就另起一档。
    const byAmount = [...list].sort((a, b) => a.tx.amount_cents - b.tx.amount_cents || cmp(a.day, b.day) || cmp(a.tx.id, b.tx.id));
    const bands = [];
    for (const it of byAmount) {
      const band = bands[bands.length - 1];
      if (band && it.tx.amount_cents <= band[0].tx.amount_cents * BAND_RATIO) band.push(it);
      else bands.push([it]);
    }
    for (const band of bands) {
      const items = band.sort((a, b) => cmp(a.day, b.day) || cmp(a.tx.occurred_at, b.tx.occurred_at) || cmp(a.tx.id, b.tx.id));
      const g = scoreGroup(key, items, { today, cards, assetOf });
      if (g) out.push(g);
    }
  }
  return out.sort((a, b) => b.score - a.score || b.count - a.count || cmp(b.lastOn, a.lastOn) || cmp(a.key, b.key));
}

module.exports = {
  MIN_CENTS, MAX_CENTS, DEFAULT_MONTHS, MAX_MONTHS, MAX_GROUPS, CHECK_SCORE, GRACE_DAYS, CANDIDATE_TX_SQL,
  merchantOf, detectSubscriptions,
};
