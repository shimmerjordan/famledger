'use strict';

// 模型的 records → 预览草稿（spec §6「规范化」「依据核对」）。纯函数，不查库；比对已有数据在 perk_import_match.js。
//
//   normalizeImport(records, {want, source, sourceKind, imageCount, today, target}) → draft
//
// 草稿是四张扁平的节点表 {platforms, memberships, benefits, items}，另带 dropped（丢掉了几条认不出的）。
// 每个节点：
//   key          p1 / m1 / b1 / i1（导入内部的名字，apply 时 `key:p1` 这样引用）
//   t            platform | membership | benefit | item
//   fields       API 形状的字段（camelCase，金额是分）；引用写成 'key:m1' / 'id:<已有 id>' / null：
//                  membership.platform、benefit.membership / parent / claimPlatform
//   ev / span    模型给的依据原话、它在原文里的位置 [start, end)（找不到是 null）
//   img          （截图来源）出自第几块，1..imageCount；模型没写或写错是 null。文字来源一律 null
//   conf         0–1；依据查不到时压到 ≤0.4
//   unverified   推断出来的字段名 —— 落库写进 origin.unverified，详情页字段旁显示「AI 推断」小点：
//                  文字来源：年份不在原文里的日期、原文没提的领取平台；
//                  截图来源：截图里的字没法逐字核对，关键字段（IMAGE_KEY_FIELDS，有值的）一律算推断
//   badges       low_conf / claim_unsure / missing / ev_unverified / copied_example（比对后还会加 maybe_dup / ambiguous / exists）
//                截图来源不逐条标 ev_unverified（每条都会标上，「需确认」就失去了分诊作用）：App 在预览顶部整批提示一次
//   missing      缺的必填字段名
//   checked      默认勾不勾：疑似照抄示例、找不到归属的权益默认不勾
//   implied      （平台）材料里没单独列、从会员或权益里补建出来的
//
// 规整的口径：枚举同义词归一、不认识的值按默认；字符串裁到列的上限；金额（元）限制在 0–10 万元，超了当没写；
// 日期必须真实存在；相对有效期只存成限制条件（type:'time'）；N 选 1 合成一条 choice 父权益；导入内部同名的合并。

const { normalizeName } = require('./perks_schema');
const { CATEGORY_DEFAULTS } = require('./valuation');
const { ITEM_PRESETS, EXAMPLE_NAMES } = require('./perk_import_prompt');
const { locateEvidence, mentions } = require('./perk_import_text');

const MAX_CENTS = 10000000; // 10 万元
const CONF_NO_EVIDENCE = 0.4;
const CONF_INFERRED = 0.6;
const LOW_CONF = 0.6;
const CATEGORIES = Object.keys(CATEGORY_DEFAULTS);
/** 截图来源落库时标成「AI 推断」的字段（origin.unverified 里的 API 字段名 → 草稿 fields 里的名字）。 */
const IMAGE_KEY_FIELDS = {
  membership: { expiresOn: 'expiresOn', termStartOn: 'termStartOn', feeCents: 'feeCents', autoRenew: 'autoRenew' },
  benefit: { claimPlatformId: 'claimPlatform', quota: 'quota', validUntil: 'validUntil', faceValueCents: 'faceValueCents' },
  item: { priceCents: 'priceCents', purchasedOn: 'purchasedOn' },
};
const EXAMPLE_KEYS = new Set(EXAMPLE_NAMES.map(normalizeName));

const T_OF = {
  platform: 'platform', 平台: 'platform',
  membership: 'membership', card: 'membership', 会员: 'membership', 会员卡: 'membership',
  benefit: 'benefit', perk: 'benefit', 权益: 'benefit',
  item: 'item', goods: 'item', 物品: 'item', 商品: 'item',
};
const PLATFORM_KIND = {
  shopping: 'shopping', 购物: 'shopping', 电商: 'shopping', video: 'video', 视频: 'video', music: 'music', 音乐: 'music',
  reading: 'reading', 阅读: 'reading', cloud: 'cloud', 网盘: 'cloud', 云盘: 'cloud', food: 'food', 外卖: 'food', 餐饮: 'food',
  travel: 'travel', 出行: 'travel', 旅行: 'travel', bank: 'bank', 银行: 'bank', telecom: 'telecom', 通信: 'telecom', 运营商: 'telecom',
  game: 'game', 游戏: 'game', tool: 'tool', 工具: 'tool', other: 'other',
};
const MEMBERSHIP_KIND = {
  membership: 'membership', 会员: 'membership', subscription: 'subscription', 订阅: 'subscription',
  credit_card: 'credit_card', creditcard: 'credit_card', 信用卡: 'credit_card', bundle: 'bundle', 联名: 'bundle', 套餐: 'bundle', other: 'other',
};
const FEE_PERIOD = {
  month: 'month', monthly: 'month', 月: 'month', 月付: 'month', 包月: 'month', quarter: 'quarter', quarterly: 'quarter', 季: 'quarter', 季付: 'quarter',
  year: 'year', yearly: 'year', annual: 'year', annually: 'year', 年: 'year', 年付: 'year', 包年: 'year',
  once: 'once', 一次性: 'once', 买断: 'once', none: 'none', free: 'none', 免费: 'none', 不收费: 'none',
};
const BENEFIT_KIND = {
  subscription: 'subscription', 会员: 'subscription', 年卡: 'subscription', 月卡: 'subscription', coupon: 'coupon', 券: 'coupon', 优惠券: 'coupon',
  discount: 'discount', 折扣: 'discount', cashback: 'cashback', 返现: 'cashback', points: 'points', 积分: 'points',
  service: 'service', 服务: 'service', lounge: 'lounge', 贵宾厅: 'lounge', shipping: 'shipping', 运费: 'shipping', 包邮: 'shipping',
  insurance: 'insurance', 保险: 'insurance', other: 'other',
};
const FLOW = { claim: 'claim', 领取: 'claim', 领: 'claim', use: 'use', 使用: 'use', 用: 'use', claim_use: 'claim_use', claimuse: 'claim_use', 先领后用: 'claim_use', 先领再用: 'claim_use' };
const ANCHOR = { calendar: 'calendar', 自然: 'calendar', 自然月: 'calendar', term: 'term', 会员期: 'term', 开卡日: 'term' };
const QUOTA_P = {
  day: 'day', daily: 'day', 日: 'day', 天: 'day', 每天: 'day', week: 'week', weekly: 'week', 周: 'week', 每周: 'week',
  month: 'month', monthly: 'month', 月: 'month', 每月: 'month', quarter: 'quarter', 季: 'quarter', 每季: 'quarter',
  year: 'year', yearly: 'year', 年: 'year', 每年: 'year', term: 'term', 会籍期: 'term', 本期: 'term', 会员期: 'term',
  total: 'total', 总共: 'total', 一共: 'total', 一次性: 'total',
};
const LIMIT_TYPE = {
  min_spend: 'min_spend', 门槛: 'min_spend', 满减: 'min_spend', scope: 'scope', 范围: 'scope', channel: 'channel', 渠道: 'channel',
  holder: 'holder', 持卡人: 'holder', 本人: 'holder', device: 'device', 设备: 'device', time: 'time', 时间: 'time', 时段: 'time',
  region: 'region', 地区: 'region', stacking: 'stacking', 叠加: 'stacking', 同享: 'stacking', other: 'other',
};
const CATEGORY = {
  digital: 'digital', 数码: 'digital', 手机: 'digital', 电脑: 'digital', 平板: 'digital', 相机: 'digital', 耳机: 'digital',
  appliance: 'appliance', 家电: 'appliance', furniture: 'furniture', 家具: 'furniture', clothing: 'clothing', 衣物: 'clothing', 服装: 'clothing', 鞋服: 'clothing',
  vehicle: 'vehicle', 出行: 'vehicle', 汽车: 'vehicle', 车: 'vehicle', 电动车: 'vehicle', luxury: 'luxury', 箱包: 'luxury', 奢侈品: 'luxury', 包: 'luxury',
  jewelry: 'jewelry', 首饰: 'jewelry', 贵金属: 'jewelry', 黄金: 'jewelry', sports: 'sports', 运动: 'sports', other: 'other',
};

const isObject = (x) => x !== null && typeof x === 'object' && !Array.isArray(x);

/** 同义词表里查（大小写、首尾空白不计较）；查不到回 [dflt]。 */
function pick(map, raw, dflt) {
  if (typeof raw !== 'string') return dflt;
  const k = raw.trim().toLowerCase();
  return map[k] ?? map[raw.trim()] ?? dflt;
}

/** 字符串裁到 [max] 字；空的、不是字符串的回 null。 */
function clip(raw, max) {
  if (typeof raw !== 'string' && typeof raw !== 'number') return null;
  const s = String(raw).trim();
  return s === '' ? null : s.slice(0, max);
}

function confOf(raw) {
  const n = Number(raw);
  return Number.isFinite(n) ? Math.min(1, Math.max(0, n)) : 0.5;
}

/** 元 → 分：88、"88元"、"¥88.00"、"1.2万" 都认；负数、认不出、超过 10 万元回 null。 */
function yuanToCents(raw) {
  let n;
  if (typeof raw === 'number') n = raw;
  else if (typeof raw === 'string') {
    const m = raw.replace(/[,，\s]/g, '').match(/\d+(?:\.\d+)?/);
    if (!m) return null;
    n = Number(m[0]);
    if (/万/.test(raw)) n *= 10000;
  } else return null;
  if (!Number.isFinite(n) || n < 0) return null;
  const cents = Math.round(n * 100);
  return cents > MAX_CENTS ? null : cents;
}

const pad2 = (n) => String(n).padStart(2, '0');

/** 日期：2026-12-31、2026/12/31、2026.12.31、2026年12月31日 都认，必须真实存在；否则 null。 */
function dayOf(raw) {
  if (typeof raw !== 'string') return null;
  const m = raw.trim().match(/^(\d{4})\s*[-/.年]\s*(\d{1,2})\s*[-/.月]\s*(\d{1,2})\s*日?$/);
  if (!m) return null;
  const day = `${m[1]}-${pad2(m[2])}-${pad2(m[3])}`;
  const d = new Date(`${day}T00:00:00Z`);
  return Number.isNaN(d.getTime()) || d.toISOString().slice(0, 10) !== day ? null : day;
}

/** 像「领取后 30 天」「开通 1 个月内」这种相对期限（不是日期）。 */
const looksRelative = (raw) => typeof raw === 'string' && !dayOf(raw) && /[天日周月年]/.test(raw);

function quotaOf(raw) {
  const list = Array.isArray(raw) ? raw : isObject(raw) ? [raw] : [];
  const out = [];
  const seen = new Set();
  for (const q of list) {
    if (!isObject(q)) continue;
    const p = pick(QUOTA_P, q.p, null);
    const n = Number(typeof q.n === 'string' ? q.n.replace(/\D/g, '') : q.n);
    if (!p || seen.has(p) || !Number.isInteger(n) || n < 1 || n > 9999) continue;
    seen.add(p);
    out.push({ p, n });
    if (out.length === 3) break;
  }
  return out;
}

function limitsOf(raw) {
  const list = Array.isArray(raw) ? raw : [];
  const out = [];
  for (const l of list) {
    const text = clip(isObject(l) ? l.text : l, 200);
    if (!text) continue;
    out.push({ type: pick(LIMIT_TYPE, isObject(l) ? l.type : null, 'other'), text });
    if (out.length === 12) break;
  }
  return out;
}

function httpUrlOf(raw) {
  const s = clip(raw, 500);
  if (!s) return null;
  try {
    const u = new URL(s);
    return u.protocol === 'http:' || u.protocol === 'https:' ? s : null;
  } catch {
    return null;
  }
}

function boolOf(raw) {
  if (raw === true || raw === 1) return true;
  if (typeof raw === 'string') return ['true', 'yes', '是', '试用'].includes(raw.trim().toLowerCase());
  return false;
}

function autoRenewOf(raw) {
  if (raw === true) return 'yes';
  if (raw === false) return 'no';
  if (typeof raw !== 'string') return 'unknown';
  const k = raw.trim().toLowerCase();
  if (['yes', 'true', '是', '自动续费', '自动'].includes(k)) return 'yes';
  if (['no', 'false', '否', '不自动续费', '手动'].includes(k)) return 'no';
  return 'unknown';
}

/**
 * @param {object[]} records  parseImportOutput 的 records
 * @param {{want?:string, source?:string, sourceKind?:'text'|'image', imageCount?:number, today:string, target?:{id:string}|null}} opts
 */
function normalizeImport(records, { want = 'auto', source = '', sourceKind = 'text', imageCount = 0, today, target = null } = {}) {
  const draft = { platforms: [], memberships: [], benefits: [], items: [], dropped: 0 };
  const seq = { p: 0, m: 0, b: 0, i: 0 };
  const nextKey = (k) => `${k}${++seq[k]}`;
  /** 截图来源的「出自第几块」：1..imageCount 的整数（"2" 也认），别的都是 null。 */
  const imgOf = (raw) => {
    if (sourceKind !== 'image') return null;
    const n = Number(raw);
    return Number.isInteger(n) && n >= 1 && n <= imageCount ? n : null;
  };
  const node = (t, key, fields, r) => ({
    key, t, fields, ev: clip(r && r.ev, 200), span: null, conf: confOf(r && r.conf), img: imgOf(r && r.img),
    unverified: [], badges: [], missing: [], checked: true, implied: false,
  });

  const platformByName = new Map(); // 规范化名 → 节点
  const addPlatform = (name, r, implied) => {
    const k = normalizeName(name);
    const hit = platformByName.get(k);
    if (hit) {
      if (!implied) hit.implied = false;
      if (r && hit.fields.kind === 'other') hit.fields.kind = pick(PLATFORM_KIND, r.kind, 'other');
      return hit;
    }
    const n = node('platform', nextKey('p'), { name: clip(name, 40), kind: pick(PLATFORM_KIND, r && r.kind, 'other') }, implied ? null : r);
    n.implied = implied;
    if (implied && r) {
      n.conf = confOf(r.conf);
      n.img = imgOf(r.img);
    }
    platformByName.set(k, n);
    draft.platforms.push(n);
    return n;
  };

  const wanted = (t) => (want === 'virtual' ? t !== 'item' : want === 'items' ? t === 'item' : true);
  const typed = [];
  for (const r of records) {
    const t = isObject(r) ? pick(T_OF, r.t, null) : null;
    if (!t || !wanted(t)) draft.dropped++;
    else typed.push([t, r]);
  }

  // 1. 平台（先收明写的，会员和权益里提到的再补建）
  for (const [t, r] of typed) if (t === 'platform' && clip(r.name, 40)) addPlatform(r.name, r, false);

  // 2. 会员
  const cardByKey = new Map(); // 平台|名字|档位 → 节点（导入内部去重）
  const cardByName = new Map(); // 规范化名 → 第一张同名卡（权益按名字找卡）
  for (const [t, r] of typed) {
    if (t !== 'membership') continue;
    const name = clip(r.name, 60);
    let platform = null;
    if (clip(r.platform, 40)) platform = addPlatform(r.platform, r, true);
    else {
      const explicit = draft.platforms.filter((p) => !p.implied);
      if (explicit.length === 1) platform = explicit[0];
    }
    const tier = clip(r.tier, 30);
    const dedupe = `${platform ? platform.key : ''}|${normalizeName(name)}|${normalizeName(tier || '')}`;
    let termStartOn = dayOf(r.termStartOn);
    const expiresOn = dayOf(r.expiresOn);
    if (termStartOn && expiresOn && expiresOn < termStartOn) termStartOn = null;
    const fields = {
      platform: platform ? `key:${platform.key}` : null,
      name,
      tier,
      kind: pick(MEMBERSHIP_KIND, r.kind, 'membership'),
      feeCents: yuanToCents(r.fee ?? r.feeCents),
      feePeriod: pick(FEE_PERIOD, r.feePeriod, 'year'),
      termStartOn,
      expiresOn,
      autoRenew: autoRenewOf(r.autoRenew),
      isTrial: boolOf(r.isTrial),
    };
    const hit = cardByKey.get(dedupe);
    if (hit) {
      for (const [k, val] of Object.entries(fields)) if (hit.fields[k] === null || hit.fields[k] === undefined) hit.fields[k] = val;
      continue;
    }
    const n = node('membership', nextKey('m'), fields, r);
    cardByKey.set(dedupe, n);
    if (name && !cardByName.has(normalizeName(name))) cardByName.set(normalizeName(name), n);
    draft.memberships.push(n);
  }
  const cardFor = (name) => {
    if (target) return `id:${target.id}`;
    if (clip(name, 60)) {
      const hit = cardByName.get(normalizeName(name));
      if (hit) return `key:${hit.key}`;
    }
    return draft.memberships.length === 1 ? `key:${draft.memberships[0].key}` : null;
  };

  // 3. 权益（N 选 1 的选项先按组收着，最后合成父权益）
  const groups = new Map(); // `${membership}|${组名}` → {pick, options:[节点]}
  const benefitByName = new Map();
  for (const [t, r] of typed) {
    if (t !== 'benefit') continue;
    const name = clip(r.name, 60);
    const membership = cardFor(r.membership);
    const card = membership && membership.startsWith('key:') ? draft.memberships.find((m) => `key:${m.key}` === membership) : null;
    let claimPlatform = null;
    if (clip(r.claimPlatform, 40)) {
      const own = card && card.fields.platform ? draft.platforms.find((p) => `key:${p.key}` === card.fields.platform) : null;
      if (!own || normalizeName(own.fields.name) !== normalizeName(r.claimPlatform)) {
        claimPlatform = `key:${addPlatform(r.claimPlatform, r, true).key}`;
      }
    }
    const limits = limitsOf(r.limits);
    const rel = [r.validRule, looksRelative(r.validUntil) ? r.validUntil : null].map((x) => clip(x, 200)).filter(Boolean);
    for (const text of rel) if (limits.length < 12 && !limits.some((l) => l.text === text)) limits.push({ type: 'time', text });
    let validFrom = dayOf(r.validFrom);
    const validUntil = dayOf(r.validUntil);
    if (validFrom && validUntil && validUntil < validFrom) validFrom = null;
    const fields = {
      membership,
      parent: null,
      name,
      kind: pick(BENEFIT_KIND, r.kind, 'other'),
      claimPlatform,
      claimHow: clip(r.claimHow, 200),
      claimUrl: httpUrlOf(r.claimUrl),
      flow: pick(FLOW, r.flow, 'claim'),
      quota: quotaOf(r.quota),
      anchor: pick(ANCHOR, r.anchor, 'calendar'),
      validFrom,
      validUntil,
      faceValueCents: yuanToCents(r.faceValue ?? r.faceValueCents),
      limits,
    };
    const dedupe = `${membership || ''}|${normalizeName(name)}`;
    const hit = benefitByName.get(dedupe);
    if (hit) {
      for (const [k, val] of Object.entries(fields)) {
        if (hit.fields[k] === null || (Array.isArray(hit.fields[k]) && hit.fields[k].length === 0)) hit.fields[k] = val;
      }
      continue;
    }
    const n = node('benefit', nextKey('b'), fields, r);
    benefitByName.set(dedupe, n);
    draft.benefits.push(n);
    if (isObject(r.choice)) {
      const label = clip(r.choice.group, 60) || '';
      const g = `${membership || ''}|${normalizeName(label)}`;
      if (!groups.has(g)) groups.set(g, { label, pick: Number.isInteger(Number(r.choice.pick)) && Number(r.choice.pick) > 0 ? Number(r.choice.pick) : 1, options: [] });
      groups.get(g).options.push(n);
    }
  }
  for (const g of groups.values()) {
    const first = g.options[0];
    const quota = g.options.map((o) => o.fields.quota).find((q) => q.length) || [{ p: 'term', n: g.pick }];
    const parent = node('benefit', nextKey('b'), {
      membership: first.fields.membership,
      parent: null,
      name: g.label || `${g.options.length} 选 ${g.pick}`,
      kind: 'choice',
      claimPlatform: null,
      claimHow: null,
      claimUrl: null,
      flow: first.fields.flow,
      quota,
      anchor: first.fields.anchor,
      validFrom: null,
      validUntil: null,
      faceValueCents: null,
      limits: [],
    }, null);
    parent.ev = first.ev;
    parent.img = first.img;
    parent.conf = Math.min(...g.options.map((o) => o.conf));
    // 父权益排在它第一个选项前面，树形列表里才是「父 → 选项」的顺序。
    draft.benefits.splice(draft.benefits.indexOf(first), 0, parent);
    for (const o of g.options) {
      o.fields.parent = `key:${parent.key}`;
      o.fields.quota = [];
      o.fields.flow = parent.fields.flow;
    }
  }

  // 4. 物品
  const itemByName = new Map();
  for (const [t, r] of typed) {
    if (t !== 'item') continue;
    const name = clip(r.name, 60);
    const category = pick(CATEGORY, r.category, 'other');
    const preset = typeof r.preset === 'string' && ITEM_PRESETS[r.preset] && ITEM_PRESETS[r.preset].includes(category) ? r.preset : null;
    const purchasedOn = dayOf(r.purchasedOn);
    const fields = {
      name,
      category: CATEGORIES.includes(category) ? category : 'other',
      preset,
      priceCents: yuanToCents(r.price ?? r.priceCents),
      purchasedOn: purchasedOn && purchasedOn <= today ? purchasedOn : null,
    };
    const dedupe = `${normalizeName(name)}|${fields.priceCents}`;
    if (itemByName.has(dedupe)) continue;
    const n = node('item', nextKey('i'), fields, r);
    itemByName.set(dedupe, n);
    draft.items.push(n);
  }

  // 5. 依据核对、推断字段、缺字段、默认勾选
  const DATE_FIELDS = ['termStartOn', 'expiresOn', 'validFrom', 'validUntil', 'purchasedOn'];
  const nameOf = (ref) => {
    const p = ref && ref.startsWith('key:') ? draft.platforms.find((x) => `key:${x.key}` === ref) : null;
    return p ? p.fields.name : null;
  };
  for (const n of [...draft.platforms, ...draft.memberships, ...draft.benefits, ...draft.items]) {
    if (n.ev && sourceKind === 'text') {
      n.span = locateEvidence(n.ev, source);
      if (!n.span) {
        n.conf = Math.min(n.conf, CONF_NO_EVIDENCE);
        n.badges.push('ev_unverified');
      }
    }
    // 和示例同名：文字来源要原文里也找不到才算照抄；截图核对不了原文，示例里的名字又是编的，同名就标出来。
    const example = EXAMPLE_KEYS.has(normalizeName(n.fields.name));
    if (sourceKind === 'text' ? example && !n.span && !mentions(source, n.fields.name) : example) {
      n.badges.push('copied_example');
      n.checked = false;
    }
    if (sourceKind === 'text') {
      for (const f of DATE_FIELDS) {
        const day = n.fields[f];
        if (day && !mentions(source, day.slice(0, 4))) n.unverified.push(f);
      }
      if (n.t === 'benefit' && n.fields.claimPlatform) {
        const claim = nameOf(n.fields.claimPlatform);
        if (claim && !mentions(source, claim)) {
          n.unverified.push('claimPlatformId');
          n.badges.push('claim_unsure');
        }
      }
    } else {
      // 截图：有值的关键字段都算推断（autoRenew 没写是 unknown，额度没写是空列表，都不算）。
      for (const [api, f] of Object.entries(IMAGE_KEY_FIELDS[n.t] || {})) {
        const val = n.fields[f];
        const empty = val === null || val === undefined || (Array.isArray(val) && !val.length) || (f === 'autoRenew' && val === 'unknown');
        if (!empty) n.unverified.push(api);
      }
    }
    if (n.unverified.length) n.fieldConf = Object.fromEntries(n.unverified.map((f) => [f, Math.min(n.conf, CONF_INFERRED)]));
    else n.fieldConf = {};
    if (n.conf < LOW_CONF) n.badges.push('low_conf');
    const need = {
      platform: ['name'],
      membership: ['name', 'platform'],
      benefit: ['name', 'membership'],
      item: ['name', 'priceCents', 'purchasedOn'],
    }[n.t];
    n.missing = need.filter((f) => n.fields[f] === null || n.fields[f] === undefined || n.fields[f] === '');
    if (n.missing.length) n.badges.push('missing');
    // 找不到归属的权益放进「未归属」，默认不勾（勾着就会因为缺卡挡住导入）；移到某张卡下再勾。
    if (n.t === 'benefit' && !n.fields.membership) n.checked = false;
  }
  return draft;
}

module.exports = { normalizeImport, yuanToCents, dayOf, MAX_CENTS, IMAGE_KEY_FIELDS };
