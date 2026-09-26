'use strict';

// 从流水识别的第二步（spec §6「从流水」）：用户勾好的候选分组（lib/subscription_detect.js）→ 导入管线认得的 records，
// 之后照常 normalizeImport（sourceKind 'transactions'）→ matchImport → 预览 → apply。
//
//   recordsFromGroups(groups, names) → records          「直接生成」names 是空的；「AI 整理名称」是模型给的名字
//   payPatternFor(groups) → {keywords, minCents, maxCents}   落库写进会员的 pay_pattern（P6 的形状，apply 再过一遍 payPatternOf）
//   buildNamingPrompt(groups) → {system, user}         只发规范化商户、金额、周期、次数，不发流水原文（raw_text、备注）；
//                                                      商户名全是从备注来的组（fromNote）发占位名「扣费 ¥30/月 · 第 3 组」
//   namesFromOutput(records, groups) → Map(分组 key → {name?, platform?, platformKind?, kind?})   fromNote 的组不收模型给的名字
//
// 口径：
//   · 每组一个平台 + 一张卡：名字默认是商户名，模型给了就用模型的；平台名、卡名一样的几组（同一个会员涨过价、勾了两档）
//     合成一张卡，价格、日期取最近扣费的那组，扣费特征的金额范围盖住所有组；
//   · 费用 = 观测到的中位数（模型给的价格一律不用）；本期开始 = 最近一次扣费；到期日 = 最近一次扣费 + 周期；
//     扣过两次以上算自动续费，只扣过一次写「不确定」；
//   · 模型只能给已有分组起名：不认识的分组、权益、物品、别的字段一律丢掉（不让模型凭常识补权益，spec §1）；
//   · 置信度按分数给（0.3 + 分数 × 0.1，封顶 0.95）：用户自己勾上的低分组在预览里标「低置信」。

const { normalizeName, PLATFORM_KINDS } = require('./perks_schema');
const { redactPii } = require('./redact');

/** 模型只写名字，40 组也就两三千 token；渠道设了导入输出上限（extra.importMaxTokens）就用渠道的。 */
const NAMING_MAX_TOKENS = 4000;
const MAX_KEYWORDS = 5;
const MAX_KEYWORD = 30;
/** 扣费特征的金额范围：观测到的最低价 × 0.8 到最高价 × 1.2（小幅涨价还认得出）。 */
const PAY_MIN_RATIO = 0.8;
const PAY_MAX_RATIO = 1.2;
const CARD_KINDS = ['membership', 'subscription'];
const PERIOD_LABEL = { month: '每月', quarter: '每季', year: '每年' };
const PERIOD_UNIT = { month: '月', quarter: '季', year: '年' };

const isObject = (x) => x !== null && typeof x === 'object' && !Array.isArray(x);
const yuan = (cents) => `¥${(cents / 100).toFixed(2)}`;
const clip = (raw, max) => (typeof raw === 'string' && raw.trim() ? raw.trim().slice(0, max) : null);

/** 「腾讯视频 ¥30.00 × 7 次（2026-03-22 至 2026-09-18）」—— 预览里的依据块照这句说。 */
function evidenceOf(g) {
  const price = g.minCents === g.maxCents ? yuan(g.amountCents) : `${yuan(g.minCents)}–${yuan(g.maxCents)}`;
  const when = g.firstOn === g.lastOn ? g.lastOn : `${g.firstOn} 至 ${g.lastOn}`;
  return `${g.merchant} ${price} × ${g.count} 次（${when}）`;
}

const confOf = (score) => Math.round(Math.min(0.95, Math.max(0.3, 0.3 + score * 0.1)) * 100) / 100;

/** 几组合成一张卡时的扣费特征：商户名都当关键词（去重、最多 5 个），金额范围盖住所有组。 */
function payPatternFor(groups) {
  const keywords = [];
  const seen = new Set();
  for (const g of groups) {
    const k = g.merchant.slice(0, MAX_KEYWORD);
    if (!normalizeName(k) || seen.has(normalizeName(k))) continue;
    seen.add(normalizeName(k));
    keywords.push(k);
  }
  return {
    keywords: keywords.slice(0, MAX_KEYWORDS),
    minCents: Math.floor(Math.min(...groups.map((g) => g.minCents)) * PAY_MIN_RATIO),
    maxCents: Math.ceil(Math.max(...groups.map((g) => g.maxCents)) * PAY_MAX_RATIO),
  };
}

/**
 * @param {object[]} groups  勾选的候选分组（detectSubscriptions 的项）
 * @param {Map<string, object>} [names]  分组 key → 模型给的 {name, platform, platformKind, kind}
 */
function recordsFromGroups(groups, names = new Map()) {
  const cards = new Map(); // 规范化的「平台|卡名」→ {platform, name, naming, groups}
  for (const g of groups) {
    const naming = names.get(g.key) || {};
    const platform = naming.platform || g.merchant;
    const name = naming.name || g.merchant;
    const k = `${normalizeName(platform)}|${normalizeName(name)}`;
    if (!cards.has(k)) cards.set(k, { platform, name, naming, groups: [] });
    cards.get(k).groups.push(g);
  }
  const records = [];
  for (const card of cards.values()) {
    const latest = [...card.groups].sort((a, b) => (a.lastOn < b.lastOn ? 1 : a.lastOn > b.lastOn ? -1 : 0))[0];
    const conf = confOf(Math.max(...card.groups.map((g) => g.score)));
    const ev = card.groups.map(evidenceOf).join('；').slice(0, 200);
    records.push({ t: 'platform', name: card.platform, kind: card.naming.platformKind || 'other', ev, conf });
    records.push({
      t: 'membership',
      name: card.name,
      platform: card.platform,
      tier: null,
      kind: card.naming.kind || 'subscription',
      fee: latest.amountCents / 100,
      feePeriod: latest.period,
      termStartOn: latest.lastOn,
      expiresOn: latest.nextOn,
      autoRenew: card.groups.some((g) => g.count >= 2) ? 'yes' : 'unknown',
      isTrial: false,
      ev,
      conf,
      payPattern: payPatternFor(card.groups),
      lastChargeTxId: latest.lastTransactionId,
    });
  }
  return records;
}

const NAMING_SYSTEM = [
  '你是家庭账本的「订阅整理」助手。用户给你从流水里归好的扣费分组，每组一行：编号、商户、金额、周期、扣了几次。',
  '给每组起一个会员卡名和它所属的平台名。只输出一个 JSON 对象，不要解释，不要代码块：',
  '{"records":[{"t":"membership","group":"g1","name":"腾讯视频VIP","platform":"腾讯视频","platformKind":"video","kind":"subscription"}],"done":true}',
  '规则：',
  '1. 只整理名称。不要补权益，不要估价格和日期，不要新增分组；认不出的商户，name 和 platform 都照抄商户名。',
  '2. platform 写品牌或 App 的通用叫法（「腾讯视频VIP会员」→ 腾讯视频）；name 写会员名（腾讯视频VIP、88VIP、京东PLUS），不要带金额。',
  `3. platformKind 取 ${PLATFORM_KINDS.join('/')}；kind 取 membership（会员、PLUS 这类）或 subscription（按月、按年订阅的服务），拿不准写 subscription。`,
  '4. 商户写成「（没有商户名）…」的组不用管，跳过就行。',
  '5. 每组最多一条；全部写完后一定写 "done":true。',
].join('\n');

/** ¥30 / ¥30.50：占位名里的价格（整元不带小数）。 */
const shortYuan = (cents) => (cents % 100 === 0 ? `¥${cents / 100}` : yuan(cents));

/**
 * 商户名全是从备注来的组（没填商户、只写了备注）发给模型时用的占位名：「扣费 ¥30/月 · 第 3 组」—— 只由金额、周期和
 * 编号拼成，备注一个字都不发（界面上说了「不发流水原文和备注」）。
 */
function placeholderOf(g, i) {
  return `扣费 ${shortYuan(g.amountCents)}/${PERIOD_UNIT[g.period] || g.period} · 第 ${i + 1} 组`;
}

/** 发给模型的只有这几样：编号、规范化商户（来自备注的换成占位名）、金额、周期、次数（再过一遍脱敏）。 */
function buildNamingPrompt(groups) {
  const lines = groups.map((g, i) => {
    const price = g.minCents === g.maxCents ? yuan(g.amountCents) : `${yuan(g.minCents)}–${yuan(g.maxCents)}`;
    const merchant = g.fromNote ? `（没有商户名）${placeholderOf(g, i)}` : g.merchant;
    return `g${i + 1}｜商户「${merchant}」｜${price}｜${PERIOD_LABEL[g.period] || g.period}｜${g.count} 次`;
  });
  return { system: NAMING_SYSTEM, user: redactPii(['分组：', ...lines].join('\n')).text };
}

/**
 * 模型的 records → 分组 key → 名字。只认 t=membership、group 是 g1…gN 的；每组取第一条。商户名来自备注的组模型只看到了
 * 占位名，它给的名字不收（这几组按本机的商户名，也就是备注开头生成）。
 */
function namesFromOutput(records, groups) {
  const out = new Map();
  for (const r of records) {
    if (!isObject(r) || (r.t !== undefined && r.t !== 'membership')) continue;
    const m = /^g(\d+)$/.exec(typeof r.group === 'string' ? r.group.trim() : '');
    const g = m ? groups[Number(m[1]) - 1] : null;
    if (!g || g.fromNote || out.has(g.key)) continue;
    const naming = {};
    const name = clip(r.name, 60);
    const platform = clip(r.platform, 40);
    if (name && normalizeName(name)) naming.name = name;
    if (platform && normalizeName(platform)) naming.platform = platform;
    if (PLATFORM_KINDS.includes(r.platformKind)) naming.platformKind = r.platformKind;
    if (CARD_KINDS.includes(r.kind)) naming.kind = r.kind;
    if (Object.keys(naming).length) out.set(g.key, naming);
  }
  return out;
}

module.exports = { NAMING_MAX_TOKENS, evidenceOf, payPatternFor, recordsFromGroups, buildNamingPrompt, namesFromOutput };
