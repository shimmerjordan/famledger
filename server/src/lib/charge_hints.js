'use strict';

// 扣费线索（spec §4 GET /memberships/charge-hints、§5「要处理」）：设了扣费特征（pay_pattern）的会员，到期日前后
// 有一笔对得上的确认支出，就在「要处理」里说「已看到 9/3 扣 ¥30 → 续到 10/3」，一点就续上（只关联、不记账）。
// 这里只做纯计算：读扣费特征、判一笔流水对不对得上、把流水分给卡。查库在 modules/memberships.js（流水那条 SQL 放在
// 这里的 CHARGE_TX_SQL，测试要对它跑 EXPLAIN QUERY PLAN，钉住「走 idx_tx_occurred」）。
//
// 分配规则：一张卡最多一条线索，一笔流水最多给一张卡（「同一笔流水不能挂到两张卡上」）。候选按
// 「持有人对得上的优先 → 离到期日近的优先 → 新的优先 → id」排好，贪心地一对一分掉 —— 同样的输入永远同样的结果。

const { normalizeName, addDays, addPeriod } = require('./perks_schema');
const { CONFIRMED } = require('./stats_sql');

/** 流水的日子落在 [到期日 − 7, 到期日 + 15] 才算这张卡这一期的扣费：提前几天扣、宽限期内补扣都认。 */
const CHARGE_DAYS_BEFORE = 7;
const CHARGE_DAYS_AFTER = 15;

/**
 * 候选流水（参数：occurred_at 的下界、上界，左闭右开）：确认过的支出、没被关联过（不是哪张卡的 last_charge_tx_id、
 * 也不是哪件物品的 transaction_id）。按 occurred_at 的字符串区间走 idx_tx_occurred（spec §4）：`+type` 的一元加号
 * 让这一项不参与选索引 —— 不然没有统计信息（服务端从不跑 ANALYZE）时 SQLite 会挑 idx_tx_dedupe(type, …)，
 * 把所有支出扫一遍再临时排序。
 */
const CHARGE_TX_SQL =
  `SELECT id, occurred_at, amount_cents, merchant, note, member_id FROM transactions WHERE ${CONFIRMED} AND +type = 'expense'` +
  ' AND occurred_at >= ? AND occurred_at < ?' +
  ' AND id NOT IN (SELECT last_charge_tx_id FROM memberships WHERE deleted_at IS NULL AND last_charge_tx_id IS NOT NULL)' +
  ' AND id NOT IN (SELECT transaction_id FROM assets WHERE deleted_at IS NULL AND transaction_id IS NOT NULL)' +
  ' ORDER BY occurred_at DESC, id DESC LIMIT 5000';

/**
 * 库里存的扣费特征（JSON 文本或对象）→ 比对用的样子 `{keys, min, max}`；坏的、没有关键词的回 null（这张卡不给线索）。
 * 写入时已经过 perks_schema.payPatternOf，这里仍然宽松地读：老数据、手改的行不能让整个接口 500。
 */
function readPayPattern(raw) {
  let p = raw;
  if (typeof raw === 'string') {
    try {
      p = JSON.parse(raw);
    } catch {
      return null;
    }
  }
  if (!p || typeof p !== 'object' || !Array.isArray(p.keywords)) return null;
  const keys = p.keywords.filter((k) => typeof k === 'string').map(normalizeName).filter((k) => k !== '');
  if (keys.length === 0) return null;
  const cents = (x) => (Number.isInteger(x) && x >= 0 ? x : null);
  return { keys, min: cents(p.minCents), max: cents(p.maxCents) };
}

/**
 * 一笔流水（snake_case 行：merchant、note、amount_cents）对不对得上扣费特征：金额在范围内，商户或备注含任一关键词。
 * 商户和备注分开比：拼在一起比的话，「移动视频」会命中商户「中国移动」+ 备注「视频彩铃」。
 */
function matchesPayPattern(pattern, tx) {
  if (pattern.min !== null && tx.amount_cents < pattern.min) return false;
  if (pattern.max !== null && tx.amount_cents > pattern.max) return false;
  const texts = [tx.merchant, tx.note].map((s) => normalizeName(s || '')).filter((s) => s !== '');
  return pattern.keys.some((k) => texts.some((text) => text.includes(k)));
}

const dayMs = (day) => Date.parse(`${day}T00:00:00Z`);
const cmp = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

/**
 * 把流水分给卡。
 *
 *   cards  会员行（id, member_id, fee_period, expires_on, pay_pattern）—— 调用方已按到期日窗口、存活、未归档、能续费筛过
 *   txs    候选流水（id, occurred_at, amount_cents, merchant, note, member_id）—— 调用方已按口径和「没被关联过」筛过
 *
 * 返回 `[{membershipId, transactionId, occurredOn, amountCents, merchant, expiresOn, renewTo}]`，按到期日、卡 id 排。
 */
function matchChargeHints(cards, txs) {
  const pairs = [];
  for (const card of cards) {
    const pattern = readPayPattern(card.pay_pattern);
    const renewTo = card.expires_on ? addPeriod(card.expires_on, card.fee_period) : null;
    if (!pattern || !renewTo) continue;
    const from = addDays(card.expires_on, -CHARGE_DAYS_BEFORE);
    const until = addDays(card.expires_on, CHARGE_DAYS_AFTER);
    for (const tx of txs) {
      const day = String(tx.occurred_at).slice(0, 10);
      if (day < from || day > until || !matchesPayPattern(pattern, tx)) continue;
      pairs.push({
        card,
        tx,
        day,
        renewTo,
        foreign: card.member_id && card.member_id !== tx.member_id ? 1 : 0,
        gap: Math.abs(dayMs(day) - dayMs(card.expires_on)),
      });
    }
  }
  pairs.sort((a, b) => a.foreign - b.foreign || a.gap - b.gap || cmp(b.tx.occurred_at, a.tx.occurred_at) ||
    cmp(a.card.id, b.card.id) || cmp(a.tx.id, b.tx.id));
  const cardsTaken = new Set();
  const txTaken = new Set();
  const out = [];
  for (const p of pairs) {
    if (cardsTaken.has(p.card.id) || txTaken.has(p.tx.id)) continue;
    cardsTaken.add(p.card.id);
    txTaken.add(p.tx.id);
    out.push(p);
  }
  return out
    .sort((a, b) => cmp(a.card.expires_on, b.card.expires_on) || cmp(a.card.id, b.card.id))
    .map((p) => ({
      membershipId: p.card.id,
      transactionId: p.tx.id,
      occurredOn: p.day,
      amountCents: p.tx.amount_cents,
      merchant: p.tx.merchant || '',
      expiresOn: p.card.expires_on,
      renewTo: p.renewTo,
    }));
}

module.exports = { CHARGE_DAYS_BEFORE, CHARGE_DAYS_AFTER, CHARGE_TX_SQL, readPayPattern, matchesPayPattern, matchChargeHints };
