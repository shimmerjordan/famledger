'use strict';

// 会员权益（平台 → 会员/卡 → 权益）的共享校验（spec §2、§4）。modules/platforms.js、
// memberships.js、benefits.js 的 CRUD 用它，P4 的 AI 导入 apply 也要用同一套 —— 规则只写一处，
// 手工建和导入建出来的数据才不会各守各的口径。
//
// 这里只做「看得见的值」的校验和规整，不查库：父权益、来源权益这些引用由调用方查好了再传进来。
// 失败一律抛 HttpError（400 invalid_<字段>，结构冲突是 409），和 lib/validate.js 一个样子。
// 枚举不写 CHECK（SQLite 改约束要重建表），取值表就是这里的常量。

const { HttpError } = require('./router');
const v = require('./validate');

const PLATFORM_KINDS = ['shopping', 'video', 'music', 'reading', 'cloud', 'food', 'travel', 'bank', 'telecom', 'game', 'tool', 'other'];
const MEMBERSHIP_KINDS = ['membership', 'subscription', 'credit_card', 'bundle', 'other'];
const FEE_PERIODS = ['month', 'quarter', 'year', 'once', 'none'];
const AUTO_RENEW = ['yes', 'no', 'unknown'];
const BENEFIT_KINDS = ['subscription', 'coupon', 'discount', 'cashback', 'points', 'service', 'lounge', 'shipping', 'insurance', 'choice', 'other'];
// claim：领到手就算；use：用一次算；claim_use：先领再用（额度计 use，本期没领时显示「待领」）。
const FLOWS = ['claim', 'use', 'claim_use'];
// 以后做账单日起算再加 'date'（spec §2「扩展位」），不用重建表。
const ANCHORS = ['calendar', 'term'];
const QUOTA_PERIODS = ['day', 'week', 'month', 'quarter', 'year', 'term', 'total'];
const LIMIT_TYPES = ['min_spend', 'scope', 'channel', 'holder', 'device', 'time', 'region', 'stacking', 'other'];
// 打卡事件：领了 / 用了 / 本期跳过。以后做发放批次再加 'grant'（spec §2「扩展位」）。
const EVENT_KINDS = ['claim', 'use', 'skip'];
/** 能续费的周期各是几个月；once / none 不在表里 = 不能续（renew 回 409 not_renewable）。 */
const PERIOD_MONTHS = { month: 1, quarter: 3, year: 12 };

const MAX_AMOUNT = 1e14;

// 三个 makeCrud 模块的字段表（lib/crud.js 的 fields 形状）。CRUD（modules/platforms.js、memberships.js、benefits.js）
// 和 AI 导入的 apply（lib/perk_import_apply.js）用同一份，字段的类型、长度、取值范围只写在这里。
// 类型写成 json 的（aliases / quota / limits / origin）真正的校验在各自的 fromBody / apply 里（aliasesOf、quotaOf…），
// 这里声明成 json 只为 toJson 还原成数组或对象。

const PLATFORM_FIELDS = Object.freeze({
  name: { type: 'string', required: true, max: 40 },
  aliases: { type: 'json', default: '[]' },
  kind: { type: 'enum', values: PLATFORM_KINDS, default: 'other' },
  icon: { type: 'string', max: 40 },
  color: { type: 'color' },
  url: { type: 'string', max: 500 },
  note: { type: 'string', max: 500 },
});

const MEMBERSHIP_FIELDS = Object.freeze({
  platformId: { type: 'id', required: true },
  sourceBenefitId: { type: 'id' },
  name: { type: 'string', required: true, max: 60 },
  tier: { type: 'string', max: 30 },
  kind: { type: 'enum', values: MEMBERSHIP_KINDS, default: 'membership' },
  memberId: { type: 'id' },
  accountId: { type: 'id' },
  feeCents: { type: 'int', min: 0, max: MAX_AMOUNT },
  feePeriod: { type: 'enum', values: FEE_PERIODS, default: 'year' },
  termPaidCents: { type: 'int', min: 0, max: MAX_AMOUNT },
  autoRenew: { type: 'enum', values: AUTO_RENEW, default: 'unknown' },
  isTrial: { type: 'bool', default: false },
  remindDays: { type: 'int', min: 0, max: 365 },
  origin: { type: 'json', default: '{}' },
  note: { type: 'string', max: 1000 },
});

const BENEFIT_FIELDS = Object.freeze({
  membershipId: { type: 'id', required: true },
  parentId: { type: 'id' },
  name: { type: 'string', required: true, max: 60 },
  kind: { type: 'enum', values: BENEFIT_KINDS, default: 'other' },
  claimPlatformId: { type: 'id' },
  claimHow: { type: 'string', max: 200 },
  claimUrl: { type: 'string', max: 500 },
  flow: { type: 'enum', values: FLOWS, default: 'claim' },
  quota: { type: 'json', default: '[]' },
  anchor: { type: 'enum', values: ANCHORS, default: 'calendar' },
  faceValueCents: { type: 'int', min: 0, max: MAX_AMOUNT },
  myValueCents: { type: 'int', min: 0, max: MAX_AMOUNT },
  limits: { type: 'json', default: '[]' },
  remind: { type: 'bool', default: true },
  origin: { type: 'json', default: '{}' },
  note: { type: 'string', max: 500 },
});

const MAX_ALIASES = 20;
const MAX_PAY_KEYWORDS = 5;
const MAX_QUOTA = 3;
const MAX_LIMITS = 12;
/** 派生会员沿「来源权益 → 它的会员 → 那张卡的来源权益 …」最多查几层。 */
const MAX_SOURCE_DEPTH = 5;

/**
 * 平台的「规范化名」：NFKC → 小写 → 去掉空白和标点。存活平台之间它必须唯一（「优酷」「优 酷」
 * 「ＹＯＵＫＵ」和「youku」各算一个名字）。不落列：表只有几十行，每次现算。
 */
function normalizeName(s) {
  return String(s ?? '').normalize('NFKC').toLowerCase().replace(/[\s\p{P}]+/gu, '');
}

/** 别名：去空白、丢空串、按规范化名去重（顺序保留第一次出现的），最多 20 个、每个 ≤30 字。 */
function aliasesOf(raw, field = 'aliases') {
  const list = v.list(raw, field, { max: 200 });
  const out = [];
  const seen = new Set();
  for (const item of list) {
    if (typeof item !== 'string') v.bad(field, '别名必须是字符串');
    const s = item.trim();
    if (s === '') continue;
    if (s.length > 30) v.bad(field, '每个别名最多 30 个字');
    const key = normalizeName(s);
    if (key === '' || seen.has(key)) continue;
    seen.add(key);
    out.push(s);
  }
  if (out.length > MAX_ALIASES) v.bad(field, `别名最多 ${MAX_ALIASES} 个`);
  return out;
}

/**
 * 扣费特征 `{keywords:[…], minCents?, maxCents?}`（P6 会员表单手填，P7 流水识别写）：商户或备注里含任一关键词、
 * 金额落在 [minCents, maxCents]（缺哪头哪头不设限）的确认支出，算这张卡的一次扣费（lib/charge_hints.js）。
 * 关键词 1–5 个、每个 ≤30 字：去空白，按规范化名去重，规范化后是空串的（全是标点）丢掉；金额下限不能高于上限。
 * 只留这三个键。
 */
function payPatternOf(raw, field = 'payPattern') {
  if (!v.isObject(raw)) v.bad(field, '扣费特征要写成 {keywords, minCents, maxCents}');
  const keywords = [];
  const seen = new Set();
  for (const item of v.list(raw.keywords, field, { max: 50 })) {
    if (typeof item !== 'string') v.bad(field, '商户关键词必须是字符串');
    const s = item.trim();
    if (s.length > 30) v.bad(field, '每个商户关键词最多 30 个字');
    const key = normalizeName(s);
    if (key === '' || seen.has(key)) continue;
    seen.add(key);
    keywords.push(s);
  }
  if (keywords.length === 0) v.bad(field, '扣费特征至少要一个商户关键词');
  if (keywords.length > MAX_PAY_KEYWORDS) v.bad(field, `商户关键词最多 ${MAX_PAY_KEYWORDS} 个`);
  const minCents = v.optInt(raw.minCents, field, { min: 0, max: MAX_AMOUNT });
  const maxCents = v.optInt(raw.maxCents, field, { min: 0, max: MAX_AMOUNT });
  if (minCents !== null && maxCents !== null && minCents > maxCents) v.bad(field, '金额下限不能高于上限');
  const out = { keywords };
  if (minCents !== null) out.minCents = minCents;
  if (maxCents !== null) out.maxCents = maxCents;
  return out;
}

/**
 * 额度上限列表 `[{p, n}]`：p 是周期，n 是 1–9999 次；最多 3 条、p 不能重复；`[]` = 不限次。
 * 多条是叠加：「每年 6 次且每月最多 2 次」= `[{p:'year',n:6},{p:'month',n:2}]`。
 */
function quotaOf(raw, field = 'quota') {
  const list = v.list(raw, field, { max: MAX_QUOTA });
  const seen = new Set();
  return list.map((item) => {
    if (!v.isObject(item)) v.bad(field, '额度的每一条要写成 {p, n}');
    const p = item.p;
    if (!QUOTA_PERIODS.includes(p)) v.bad(field, `额度周期必须是 ${QUOTA_PERIODS.join('/')} 之一`);
    if (seen.has(p)) v.bad(field, '同一个周期只能写一条额度');
    seen.add(p);
    const n = v.int(item.n, field, { min: 1, max: 9999 });
    return { p, n };
  });
}

/** 限制条件 `[{type, text}]`：最多 12 条，text 1–200 字。 */
function limitsOf(raw, field = 'limits') {
  const list = v.list(raw, field, { max: MAX_LIMITS });
  return list.map((item) => {
    if (!v.isObject(item)) v.bad(field, '限制条件的每一条要写成 {type, text}');
    if (!LIMIT_TYPES.includes(item.type)) v.bad(field, `限制条件的类型必须是 ${LIMIT_TYPES.join('/')} 之一`);
    const text = v.str(item.text, field, { max: 200 });
    return { type: item.type, text };
  });
}

/**
 * 来源标记 `{src, importId, ev, unverified:[字段名]}`（P4 的 AI 导入写，App 确认后清掉 unverified）。
 * 只留这四个键；ev 是抽取依据，≤200 字。
 */
function originOf(raw, field = 'origin') {
  if (!v.isObject(raw)) v.bad(field, `${field} 必须是对象`);
  const out = {};
  const src = v.optStr(raw.src, field, { max: 20 });
  if (src) out.src = src;
  const importId = v.optStr(raw.importId, field, { max: 64 });
  if (importId) out.importId = importId;
  const ev = v.optStr(raw.ev, field, { max: 200 });
  if (ev) out.ev = ev;
  if (raw.unverified !== undefined && raw.unverified !== null) {
    out.unverified = v.list(raw.unverified, field, { max: 30 }).map((f) => v.str(f, field, { max: 40 }));
  }
  return out;
}

const snakeOf = (s) => s.replace(/[A-Z]/g, (c) => `_${c.toLowerCase()}`);

/**
 * 「AI 推断」小点（spec §5）：PATCH 里改了值的字段算人工确认过，从 origin.unverified 里拿掉。
 * 比的是「这次给的值」和「行里原来的值」—— 表单编辑时整张表单都会带上，没改的字段不算确认。
 * 会员、权益、物品三个模块在 PATCH 没带 origin 时调它。
 *
 *   body  这次 PATCH 的请求体（camelCase；空串当 null）
 *   row   改之前的行（snake_case；JSON 列是字符串）
 *
 * 返回新的 origin JSON 字符串；没有要拿掉的回 null（调用方就不写这一列）。
 */
function pruneUnverified(body, row) {
  let origin;
  try {
    origin = JSON.parse((row && row.origin) || '{}');
  } catch {
    return null;
  }
  if (!v.isObject(origin) || !Array.isArray(origin.unverified) || origin.unverified.length === 0) return null;
  const same = (a, b) => JSON.stringify(a ?? null) === JSON.stringify(b ?? null);
  const kept = origin.unverified.filter((field) => {
    if (typeof field !== 'string' || body[field] === undefined) return true;
    let old = row[snakeOf(field)];
    if (typeof old === 'string' && /^[[{]/.test(old)) {
      try {
        old = JSON.parse(old);
      } catch {
        /* 不是 JSON 就按字符串比 */
      }
    }
    return same(body[field] === '' ? null : body[field], old);
  });
  if (kept.length === origin.unverified.length) return null;
  return JSON.stringify({ ...origin, unverified: kept });
}

/** 可选链接：只收 http/https，≤500 字；空串 = 清掉。 */
function httpUrl(raw, field, { max = 500 } = {}) {
  const s = v.optStr(raw, field, { max });
  if (s === null) return null;
  let u;
  try {
    u = new URL(s);
  } catch {
    v.bad(field, `${field} 不是有效的网址`);
  }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') v.bad(field, `${field} 只能是 http 或 https 网址`);
  return s;
}

/** 起止日期先后：两头都有时止 ≥ 起。`field` 是报错时点名的那个字段（一般是止）。 */
function dateOrder(from, until, field, message) {
  if (from && until && until < from) v.bad(field, message);
}

const pad2 = (n) => String(n).padStart(2, '0');
const dayOf = (d) => `${d.getUTCFullYear()}-${pad2(d.getUTCMonth() + 1)}-${pad2(d.getUTCDate())}`;

/** `YYYY-MM-DD` 加 [n] 天（按 UTC 日历数，不碰时区；n 可以是负数）。 */
function addDays(day, n) {
  const d = new Date(`${day}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return dayOf(d);
}

/**
 * `YYYY-MM-DD` 往后 [k] 个续费周期（month / quarter / year；k 可以是负数）。日号从起点重新夹取：
 * 1/31 + 1 月 = 2/28，+ 2 月 = 3/31，不做链式累加。App 的 perk_math.dart addMonthsClamped 是同一个口径。
 * 不能续的周期（once / none）返回 null。
 */
function addPeriod(day, feePeriod, k = 1) {
  const months = PERIOD_MONTHS[feePeriod];
  if (!months) return null;
  const [y, m, d] = day.split('-').map(Number);
  const first = new Date(Date.UTC(y, m - 1 + months * k, 1));
  const last = new Date(Date.UTC(first.getUTCFullYear(), first.getUTCMonth() + 1, 0)).getUTCDate();
  first.setUTCDate(Math.min(d, last));
  return dayOf(first);
}

/** JSON 列（字符串）或已经解析好的值 → 数组；坏值按空数组。 */
function asList(raw) {
  if (Array.isArray(raw)) return raw;
  if (typeof raw !== 'string') return [];
  try {
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

/**
 * 权益的父子规则（N 选 1 = 一条 kind='choice' 的父权益 + 若干选项；只允许一层）。
 *
 *   b            合并后的权益（snake_case：id?, membership_id, parent_id, kind, quota）
 *   parent       parent_id 指向的存活权益行；没有 parent_id 传 null（指向的行不存在时调用方先 400）
 *   optionCount  b 自己名下的存活选项数（新建传 0）
 *
 * 返回要强制写入的列：选项的 flow 跟随父权益。
 */
function benefitParentRules(b, parent, optionCount) {
  if (optionCount > 0 && b.kind !== 'choice') {
    throw new HttpError(409, 'has_options', '这条下面还有选项，先把选项删掉或挪走，再改成别的类型', { options: optionCount });
  }
  if (!parent) return {};
  if (b.id && parent.id === b.id) v.bad('parentId', '不能挂在自己下面');
  if (parent.kind !== 'choice') v.bad('parentId', '只有「N 选 1」的权益下面能挂选项');
  if (parent.parent_id) v.bad('parentId', '选项下面不能再挂选项');
  if (parent.membership_id !== b.membership_id) v.bad('parentId', '选项要和它的「N 选 1」在同一张卡下');
  if (optionCount > 0) v.bad('parentId', '这条自己下面有选项，不能再挂到别的权益下');
  if (b.kind === 'choice') v.bad('kind', '选项不能再是「N 选 1」');
  if (asList(b.quota).length > 0) v.bad('quota', '选项不单独设额度，额度看它的「N 选 1」');
  return { flow: parent.flow };
}

/**
 * 派生会员（88VIP 的「优酷年卡」带出来的优酷会员）不能成环：从来源权益出发，沿
 * 「权益 → 所属会员 → 那张卡的来源权益 → …」往上查，碰到自己就是环；查了 5 层还没到头也拒绝。
 *
 *   membershipId     正在写的会员 id（新建传 null：没人能指向一张还不存在的卡）
 *   sourceBenefitId  要设的来源权益 id
 *   benefitOf(id)    → 存活权益行或 null
 *   membershipOf(id) → 存活会员行或 null
 */
function checkSourceChain({ membershipId, sourceBenefitId, benefitOf, membershipOf }) {
  let benefitId = sourceBenefitId;
  for (let depth = 0; depth < MAX_SOURCE_DEPTH; depth++) {
    const benefit = benefitOf(benefitId);
    if (!benefit) {
      if (depth === 0) v.bad('sourceBenefitId', '来源权益不存在');
      return;
    }
    if (membershipId && benefit.membership_id === membershipId) {
      v.bad('sourceBenefitId', '来源权益不能是这张卡自己的（或由它派生出去的）权益');
    }
    const owner = membershipOf(benefit.membership_id);
    if (!owner || !owner.source_benefit_id) return;
    benefitId = owner.source_benefit_id;
  }
  v.bad('sourceBenefitId', `派生关系最多 ${MAX_SOURCE_DEPTH} 层`);
}

/**
 * 把权益挪到另一张卡下（改 membership_id；choice 父权益的选项跟着走）也不能成环：88VIP 的「优酷年卡」
 * 带出了优酷VIP，再把「优酷年卡」挪进优酷VIP，就成了「优酷VIP 是它自己名下的权益带出来的」。
 * 从目标卡出发，沿「会员的来源权益 → 那条权益的会员 → …」往上查，碰到要挪的任何一条就是环；
 * 查了 5 层还没到头也拒绝（和 checkSourceChain 同一个上限）。
 *
 *   benefitIds          要挪的权益 id（本条 + 跟着走的选项）
 *   targetMembershipId  挪去的会员 id
 *   benefitOf(id)       → 存活权益行或 null
 *   membershipOf(id)    → 存活会员行或 null
 */
function checkBenefitMove({ benefitIds, targetMembershipId, benefitOf, membershipOf }) {
  const moving = new Set(benefitIds);
  let card = membershipOf(targetMembershipId);
  for (let depth = 0; depth < MAX_SOURCE_DEPTH; depth++) {
    if (!card || !card.source_benefit_id) return;
    if (moving.has(card.source_benefit_id)) {
      v.bad('membershipId', '这张卡是由这项权益（或它的选项）带出来的，不能把权益挪进去');
    }
    const source = benefitOf(card.source_benefit_id);
    if (!source) return;
    card = membershipOf(source.membership_id);
  }
  if (card && card.source_benefit_id) v.bad('membershipId', `派生关系最多 ${MAX_SOURCE_DEPTH} 层`);
}

module.exports = {
  PLATFORM_KINDS,
  MEMBERSHIP_KINDS,
  FEE_PERIODS,
  AUTO_RENEW,
  BENEFIT_KINDS,
  FLOWS,
  ANCHORS,
  QUOTA_PERIODS,
  LIMIT_TYPES,
  EVENT_KINDS,
  PERIOD_MONTHS,
  PLATFORM_FIELDS,
  MEMBERSHIP_FIELDS,
  BENEFIT_FIELDS,
  MAX_ALIASES,
  MAX_PAY_KEYWORDS,
  MAX_SOURCE_DEPTH,
  normalizeName,
  aliasesOf,
  payPatternOf,
  quotaOf,
  limitsOf,
  originOf,
  pruneUnverified,
  httpUrl,
  dateOrder,
  addDays,
  addPeriod,
  asList,
  benefitParentRules,
  checkSourceChain,
  checkBenefitMove,
};
