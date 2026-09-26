'use strict';

// AI 导入里和「原文」打交道的两件事（spec §6）：
//
//   pickParagraphs(text, limit)  粘贴超过 12000 字时按关键词密度挑段落（最多 20000 字的那道闸在接口上）
//   locateEvidence(ev, source)   依据核对：模型给的原话在原文里的位置 [start, end)，找不到是 null
//
// 核对用「规范化子串」：NFKC → 小写 → 去掉空白、标点和符号（全角半角、换行、¥ 这些不计较），再按原文下标映射回来，
// App 拿这个区间在原文上高亮。

const PICK_LIMIT = 12000;

/** 挑段落时算密度用的关键词：会员权益和订单里最常见的字眼。 */
const KEYWORDS = [
  '会员', '权益', '领取', '每月', '每年', '每周', '次', '张', '券', '年卡', '月卡', '季卡', '有效期', '到期', '续费', '自动续费',
  '开通', '兑换', '贵宾厅', '免费', '折', '满', '减', '红包', '88VIP', 'PLUS', 'SVIP', 'VIP',
  '订单', '实付', '合计', '商品', '下单', '购买', '付款', '¥', '元', '件',
];

const SKIP_CHAR = /[\s\p{P}\p{S}]/u;

/** 原文 → 规范化串 + 每个规范化字符对应的原文下标。 */
function normalizeWithMap(s) {
  const text = String(s ?? '');
  let norm = '';
  const map = [];
  for (let i = 0; i < text.length; ) {
    const cp = text.codePointAt(i);
    const ch = String.fromCodePoint(cp);
    const width = ch.length;
    for (const c of ch.normalize('NFKC').toLowerCase()) {
      if (SKIP_CHAR.test(c)) continue;
      norm += c;
      for (let k = 0; k < c.length; k++) map.push(i);
    }
    i += width;
  }
  return { norm, map };
}

/** 规范化后的串（不带映射）：比对名字用。 */
function normalizeText(s) {
  return normalizeWithMap(s).norm;
}

/**
 * 依据 [ev] 在原文 [source] 里的位置 `[start, end)`（原文下标）；规范化后不到 2 个字、或找不到，回 null。
 */
function locateEvidence(ev, source) {
  const needle = normalizeText(ev);
  if (needle.length < 2) return null;
  const { norm, map } = normalizeWithMap(source);
  const at = norm.indexOf(needle);
  if (at < 0) return null;
  const start = map[at];
  const lastIdx = map[at + needle.length - 1];
  const lastChar = String.fromCodePoint(String(source).codePointAt(lastIdx));
  return [start, lastIdx + lastChar.length];
}

/** 原文里出现过这个名字吗（规范化后包含）。领取平台、年份的「是不是推断出来的」靠它判。 */
function mentions(source, name) {
  const needle = normalizeText(name);
  return needle.length > 0 && normalizeText(source).includes(needle);
}

/** 比 [limit] 还长的一段：先按行切开，单独一行还超的按 [limit] 切成几块（都保持原来的先后）。 */
function splitLong(p, limit) {
  if (p.length <= limit) return [p];
  const out = [];
  for (const line of p.split('\n').map((l) => l.trim()).filter(Boolean)) {
    for (let at = 0; at < line.length; at += limit) out.push(line.slice(at, at + limit));
  }
  return out;
}

/**
 * 超过 [limit] 字时挑段落：按空行切段（没有空行就按行切；某一段自己就比 [limit] 长的，再把它按行、按 [limit] 切开，
 * 不然它永远放不进来 —— 「短标题 + 一大段正文」只剩标题），每段算「关键词命中数 ÷ 段长」，从高到低挑进来，
 * 放不下的跳过接着看下一段，最后按原来的先后拼回去。整篇只有一行时直接截断。
 * @returns {{text:string, picked:boolean, kept:number, total:number}}
 */
function pickParagraphs(text, limit = PICK_LIMIT) {
  const s = String(text ?? '');
  if (s.length <= limit) return { text: s, picked: false, kept: 1, total: 1 };
  let parts = s.split(/\n\s*\n/).map((p) => p.trim()).filter(Boolean);
  if (parts.length < 2) parts = s.split('\n').map((p) => p.trim()).filter(Boolean);
  if (parts.length < 2) return { text: s.slice(0, limit), picked: true, kept: 1, total: 1 };
  parts = parts.flatMap((p) => splitLong(p, limit));
  const scored = parts.map((p, i) => {
    let hits = 0;
    for (const k of KEYWORDS) {
      for (let at = p.indexOf(k); at >= 0; at = p.indexOf(k, at + k.length)) hits++;
    }
    return { i, p, score: hits / p.length };
  });
  const order = [...scored].sort((a, b) => b.score - a.score || a.i - b.i);
  const chosen = [];
  let used = 0;
  for (const item of order) {
    const cost = item.p.length + (chosen.length ? 2 : 0);
    if (used + cost > limit) continue;
    chosen.push(item);
    used += cost;
  }
  chosen.sort((a, b) => a.i - b.i);
  return { text: chosen.map((c) => c.p).join('\n\n'), picked: true, kept: chosen.length, total: parts.length };
}

module.exports = { PICK_LIMIT, KEYWORDS, normalizeText, locateEvidence, mentions, pickParagraphs };
