'use strict';

// AI 导入的比对（spec §6「比对」「实物导入」）：拿规范化后的草稿对照库里已有的平台、会员、权益、物品，给每个节点定默认动作。
//
//   matchImport(db, draft) → draft（就地补上 action / targetId / match / diff / current / notMentioned / byCard / txCandidates / link）
//   matchPlatform(rows, name) → {kind:'exact'|'alias'|'maybe'|'none', id?, name?, candidates?}   apply 重新比对时也用
//   sameCard / sameBenefit / membershipDiff / benefitDiff   apply 重新比对会员、权益时也用（同一套口径）
//   ALIAS_SEED   内置别名种子表：淘宝 = 天猫、京东 = JD、哔哩哔哩 = B 站……
//
// 口径：
//   平台  exact（规范化名相同）或 alias（库里的别名、或种子表同组）→ 默认并入（merge）；maybe（编辑距离 ≤1 或名字互相包含）
//         只提示候选、不预选（仍是新建）。
//   会员  按（平台, 名称, 档位, 持有人）找：没归档的唯一命中 → update，列出逐字段差异；没归档的有好几张 → ambiguous（pick），
//         必须由用户选。没归档的一张都没有、只有归档的（停了又重开）→ 命中归档的那张（多张同样要选），差异里多一项「恢复」，
//         默认勾（材料说明它还在用；不恢复的话导进去本期看不到）。要选的和归档的卡在 match.candidates 里每张各带一份
//         diff / current / notMentioned，卡下的权益在 byCard[卡 id] 里各带一份比对结果 —— App 选定哪张就换上哪份（不用再问服务端）。
//   权益  按（会员, 「N 选 1」, 名称）命中 → update，列出逐字段差异（同名的没归档的优先；只有归档的也命中，同样多一项「恢复」）。
//         顶层的只和顶层的比；选项只和它那个「N 选 1」（命中了库里的那项才有）下面的比 —— 新建的「N 选 1」下面的选项一律新建。
//         库里有、这次没提到的只列进会员的 notMentioned（「本次材料未提及」），永不删。
//   current  update 的节点（和每张候选卡、byCard 的每份结果）带上库里那一行现在的值（API 字段名）：App 在预览里改了「更新」的项，
//         拿它当差异的旧值，改的字段照样写进去。
//   物品  名称相同且价格相同 → 默认跳过、标「已存在」（勾上就照样新建一件）；名称相近 → 只提示。关联流水候选：同金额、日期 ±3 天、
//         确认过的支出、还没被别的物品关联过；唯一一笔就默认关联，多笔只列不选。
//   差异的默认勾选：原来为空、新值有 → 勾；到期日（会员 expiresOn、权益 validUntil）不同 → 新的更晚才勾（结果就是取更晚的）；
//         limits 取并集（并集比原来多才勾）；费用、额度、名称等不同 → 不勾，只展示。新值为空的字段永不拿来清空旧值。
//         扣费特征（payPattern，只有从流水识别的草稿带）同样：原来没设 → 勾；设过、不一样 → 只展示。

const { normalizeName, addDays, asList } = require('./perks_schema');

/** 同一组里的名字算同一个平台（规范化名比较）。只收常见的、不会误伤的写法。 */
const ALIAS_SEED = [
  ['淘宝', '天猫', 'Taobao', 'Tmall'],
  ['京东', 'JD', 'JD.com'],
  ['哔哩哔哩', 'B站', 'bilibili'],
  ['腾讯视频', 'Tencent Video'],
  ['爱奇艺', 'iQIYI'],
  ['优酷', 'Youku'],
  ['芒果TV', '芒果 TV'],
  ['网易云音乐', '网易云'],
  ['饿了么', 'Ele.me'],
  ['美团', 'Meituan'],
  ['支付宝', 'Alipay'],
  ['微信', 'WeChat'],
  ['拼多多', 'PDD'],
  ['百度网盘', '百度云'],
  ['中国移动', '移动'],
  ['中国联通', '联通'],
  ['中国电信', '电信'],
];
const SEED_GROUPS = ALIAS_SEED.map((g) => new Set(g.map(normalizeName)));

/** 两个串的编辑距离（按码点）；超过 [cap] 提前返回 cap + 1。 */
function editDistance(a, b, cap = 2) {
  const x = [...a];
  const y = [...b];
  if (Math.abs(x.length - y.length) > cap) return cap + 1;
  let prev = Array.from({ length: y.length + 1 }, (_, j) => j);
  for (let i = 1; i <= x.length; i++) {
    const cur = [i];
    let best = i;
    for (let j = 1; j <= y.length; j++) {
      cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] === y[j - 1] ? 0 : 1));
      best = Math.min(best, cur[j]);
    }
    if (best > cap) return cap + 1;
    prev = cur;
  }
  return prev[y.length];
}

/** 名字相近：编辑距离 ≤ [cap]，或一个包含另一个（两边都至少 2 个字）。 */
function similar(a, b, cap = 1) {
  if (!a || !b || a === b) return false;
  if ([...a].length < 2 || [...b].length < 2) return false;
  return a.includes(b) || b.includes(a) || editDistance(a, b, cap) <= cap;
}

/**
 * 一个平台名对照库里的存活平台（`{id, name, aliases}` 行，aliases 是 JSON 串或数组）。
 */
function matchPlatform(rows, name) {
  const key = normalizeName(name);
  if (!key) return { kind: 'none' };
  const exact = rows.find((p) => normalizeName(p.name) === key);
  if (exact) return { kind: 'exact', id: exact.id, name: exact.name };
  const group = SEED_GROUPS.find((g) => g.has(key));
  const alias = rows.find((p) => {
    const names = [p.name, ...asList(p.aliases)].map(normalizeName);
    return names.includes(key) || (group && names.some((n) => group.has(n)));
  });
  if (alias) return { kind: 'alias', id: alias.id, name: alias.name };
  const maybe = rows.filter((p) => [p.name, ...asList(p.aliases)].some((n) => similar(normalizeName(n), key)));
  if (maybe.length) return { kind: 'maybe', candidates: maybe.map((p) => ({ id: p.id, name: p.name })) };
  return { kind: 'none' };
}

const same = (a, b) => JSON.stringify(a ?? null) === JSON.stringify(b ?? null);
const blank = (x) => x === null || x === undefined || x === '' || (Array.isArray(x) && x.length === 0);

/** limits 并集：原来的在前，新的里规范化文字没出现过的追加在后。 */
function unionLimits(oldList, newList) {
  const out = [...oldList];
  const seen = new Set(oldList.map((l) => normalizeName(l.text)));
  for (const l of newList) {
    const k = normalizeName(l.text);
    if (!seen.has(k)) {
      seen.add(k);
      out.push(l);
    }
  }
  return out.slice(0, 12);
}

/**
 * 逐字段差异。[pairs] 是 [字段名, 旧值, 新值]；新值为空的跳过（永不清空）。
 * 返回 [{field, old, new, take}]。
 */
function diffOf(pairs, { expiry = [] } = {}) {
  const out = [];
  for (const [field, oldValue, newValue] of pairs) {
    if (blank(newValue)) continue;
    if (field === 'limits') {
      const merged = unionLimits(oldValue || [], newValue);
      if (merged.length > (oldValue || []).length) out.push({ field, old: oldValue || [], new: merged, take: true });
      continue;
    }
    if (same(oldValue, newValue)) continue;
    let take = false;
    if (blank(oldValue) || (field === 'autoRenew' && oldValue === 'unknown')) take = true;
    else if (expiry.includes(field)) take = newValue > oldValue;
    out.push({ field, old: oldValue ?? null, new: newValue, take });
  }
  return out;
}

/**
 * 物品的关联流水候选：同金额、日期 ±3 天、没删、确认过的支出，而且还没被别的存活物品关联（同一笔不关联两次）。
 * 按离购买日近的在前，最多 5 笔。`occurred_at` 是带偏移的本地时间，按前 10 位（本地日期）比。
 */
function itemTxCandidates(db, { priceCents, purchasedOn }) {
  if (!priceCents || !purchasedOn) return [];
  const rows = db.all(
    "SELECT id, occurred_at, merchant, amount_cents, account_id FROM transactions WHERE deleted_at IS NULL AND type = 'expense'" +
      " AND status = 'confirmed' AND amount_cents = ? AND occurred_at >= ? AND occurred_at < ?" +
      ' AND id NOT IN (SELECT transaction_id FROM assets WHERE deleted_at IS NULL AND transaction_id IS NOT NULL)' +
      ' ORDER BY occurred_at DESC, id',
    priceCents, addDays(purchasedOn, -3), addDays(purchasedOn, 4),
  );
  const dist = (r) => Math.abs(Date.parse(`${r.occurred_at.slice(0, 10)}T00:00:00Z`) - Date.parse(`${purchasedOn}T00:00:00Z`));
  return rows
    .sort((a, b) => dist(a) - dist(b))
    .slice(0, 5)
    .map((r) => ({ id: r.id, occurredAt: r.occurred_at, merchant: r.merchant, amountCents: r.amount_cents, accountId: r.account_id }));
}

const MEMBERSHIP_DIFF = ['tier', 'kind', 'feeCents', 'feePeriod', 'termStartOn', 'expiresOn', 'autoRenew'];
const BENEFIT_DIFF = ['kind', 'claimHow', 'claimUrl', 'flow', 'quota', 'anchor', 'validFrom', 'validUntil', 'faceValueCents', 'limits'];
const col = (f) => f.replace(/[A-Z]/g, (c) => `_${c.toLowerCase()}`);
/** 归档的行被命中时多出来的一项：恢复（默认勾）。 */
const RESTORE = () => ({ field: 'archived', old: true, new: false, take: true });

/** 库里的会员行 [r] 和草稿里的会员字段 [fields] 是不是同一张：规范化名相同，给了档位、持有人时也要相同。 */
function sameCard(r, fields) {
  return (
    normalizeName(r.name) === normalizeName(fields.name) &&
    (fields.tier == null || normalizeName(r.tier || '') === normalizeName(fields.tier)) &&
    (fields.memberId == null || r.member_id === fields.memberId)
  );
}

/**
 * 卡下的权益行里和 [name] 同名、挂在同一个「N 选 1」下（[parentId]，顶层是 null）的那项：没归档的优先，
 * 只有归档的就是归档的那项；没有回 null。顶层的「芒果 TV 年卡」和某个「N 选 1」里的同名选项不是一回事。
 */
function sameBenefit(rows, name, parentId = null) {
  const key = normalizeName(name);
  const hits = rows.filter((x) => (x.parent_id || null) === parentId && normalizeName(x.name) === key);
  return hits.find((x) => !x.archived) || hits[0] || null;
}

/** 库里的扣费特征（JSON 文本）→ 对象；没设、坏的回 null。 */
function payPatternOfRow(raw) {
  if (!raw) return null;
  try {
    const p = JSON.parse(raw);
    return p && typeof p === 'object' && !Array.isArray(p) ? p : null;
  } catch {
    return null;
  }
}

/** 库里那张卡现在的值（API 字段名，和差异同一套字段 + 名称）。 */
function membershipCurrent(r) {
  return { name: r.name, ...Object.fromEntries(MEMBERSHIP_DIFF.map((f) => [f, r[col(f)] ?? null])) };
}

/** 库里那项权益现在的值（API 字段名；额度、限制条件是数组，领取平台写成 'id:…'）。 */
function benefitCurrent(r) {
  const out = { name: r.name };
  for (const f of BENEFIT_DIFF) out[f] = f === 'quota' || f === 'limits' ? asList(r[col(f)]) : (r[col(f)] ?? null);
  out.claimPlatform = r.claim_platform_id ? `id:${r.claim_platform_id}` : null;
  return out;
}

/** 会员和库里那张的逐字段差异；那张归档了就多一项「恢复」。 */
function membershipDiff(r, fields) {
  const pairs = MEMBERSHIP_DIFF.map((f) => [f, r[col(f)], fields[f]]);
  pairs.push(['payPattern', payPatternOfRow(r.pay_pattern), fields.payPattern]);
  const diff = diffOf(pairs, { expiry: ['expiresOn'] });
  if (r.archived) diff.push(RESTORE());
  return diff;
}

/**
 * 权益和库里那项的逐字段差异。[claimNew] 是这次的领取平台，写成能和库里比的样子：能对上已有平台的写 'id:…'，
 * 新建的领取平台（还没有 id）照样写 'key:…'（算「不同」），没写是 null。那项归档了就多一项「恢复」。
 */
function benefitDiff(r, fields, claimNew) {
  const pairs = BENEFIT_DIFF.map((f) => {
    const old = f === 'quota' || f === 'limits' ? asList(r[col(f)]) : r[col(f)];
    return [f, old, fields[f]];
  });
  pairs.push(['claimPlatform', r.claim_platform_id ? `id:${r.claim_platform_id}` : null, claimNew]);
  const diff = diffOf(pairs, { expiry: ['validUntil'] });
  if (r.archived) diff.push(RESTORE());
  return diff;
}

function matchImport(db, draft) {
  const platformRows = db.all('SELECT id, name, aliases FROM platforms WHERE deleted_at IS NULL');
  const platformByKey = new Map(draft.platforms.map((p) => [`key:${p.key}`, p]));

  // 1. 平台
  for (const p of draft.platforms) {
    p.match = matchPlatform(platformRows, p.fields.name);
    if (p.match.kind === 'exact' || p.match.kind === 'alias') {
      p.action = 'merge';
      p.targetId = p.match.id;
    } else {
      p.action = 'create';
      p.targetId = null;
      if (p.match.kind === 'maybe') p.badges.push('maybe_dup');
    }
  }
  /** 引用 → 库里已有的 id（新建的平台还没有 id，回 null）。 */
  const existingPlatformId = (ref) => {
    if (!ref) return null;
    if (ref.startsWith('id:')) return ref.slice(3);
    const p = platformByKey.get(ref);
    return p && p.action === 'merge' ? p.targetId : null;
  };

  // 2. 会员
  const cardByKey = new Map(draft.memberships.map((m) => [`key:${m.key}`, m]));
  for (const m of draft.memberships) {
    m.action = 'create';
    m.targetId = null;
    m.match = { kind: 'none' };
    const pid = existingPlatformId(m.fields.platform);
    if (!pid) continue;
    const same = db.all('SELECT * FROM memberships WHERE deleted_at IS NULL AND platform_id = ?', pid).filter((r) => sameCard(r, m.fields));
    const active = same.filter((r) => !r.archived);
    const pool = active.length ? active : same; // 没有在用的才看归档的
    if (!pool.length) continue;
    const candidates = pool.map((r) => ({
      id: r.id, name: r.name, tier: r.tier, memberId: r.member_id, expiresOn: r.expires_on, archived: !!r.archived,
      diff: membershipDiff(r, m.fields), current: membershipCurrent(r),
    }));
    if (pool.length === 1) {
      const r = pool[0];
      m.action = 'update';
      m.targetId = r.id;
      m.match = { kind: 'update', id: r.id, name: r.name };
      m.diff = candidates[0].diff;
      m.current = candidates[0].current;
      // 归档的那张：App 给「恢复并更新它 / 新建一张」两个选项，所以候选也带上。
      if (r.archived) Object.assign(m.match, { archived: true, candidates });
    } else {
      m.action = 'pick';
      m.match = { kind: 'ambiguous', candidates };
      m.badges.push('ambiguous');
    }
  }
  /** 权益的会员引用 → 现在选定的库里那张卡的 id（新建的、还没选的卡回 null）。 */
  const existingCardId = (ref) => {
    if (!ref) return null;
    if (ref.startsWith('id:')) return ref.slice(3);
    const m = cardByKey.get(ref);
    return m && m.action === 'update' ? m.targetId : null;
  };
  /** 会员引用可能是库里哪几张：'id:' 指定的那张、唯一命中的那张、要选的（或归档的）那几张候选。 */
  const cardChoices = (ref) => {
    if (!ref) return [];
    if (ref.startsWith('id:')) return [ref.slice(3)];
    const m = cardByKey.get(ref);
    if (!m) return [];
    if (m.match.candidates) return m.match.candidates.map((c) => c.id);
    return m.action === 'update' ? [m.targetId] : [];
  };
  const benefitRows = new Map(); // 卡 id → 它的存活权益行
  const rowsOf = (cardId) => {
    if (!benefitRows.has(cardId)) benefitRows.set(cardId, db.all('SELECT * FROM benefits WHERE deleted_at IS NULL AND membership_id = ?', cardId));
    return benefitRows.get(cardId);
  };

  // 3. 权益（顶层的先比：选项要看它的「N 选 1」命中了库里哪项）
  const mentioned = new Map(); // 卡 id → 这次提到的规范化名
  const hitsOf = new Map(); // 权益 key → {卡 id → 命中}
  /** 选项的「N 选 1」在卡 [cardId] 下是库里哪项：顶层回 null；父权益是新建的（没命中）回 undefined —— 下面的选项也是新的。 */
  const parentRowId = (b, cardId) => {
    const ref = b.fields.parent;
    if (!ref) return null;
    if (ref.startsWith('id:')) return ref.slice(3);
    const hit = (hitsOf.get(ref.slice(4)) || {})[cardId];
    return hit ? hit.targetId : undefined;
  };
  const isOption = (b) => typeof b.fields.parent === 'string' && b.fields.parent.startsWith('key:');
  for (const b of [...draft.benefits.filter((x) => !isOption(x)), ...draft.benefits.filter(isOption)]) {
    b.action = 'create';
    b.targetId = null;
    b.match = { kind: 'none' };
    const choices = cardChoices(b.fields.membership);
    if (!choices.length) continue;
    // 领取平台：新的能对上库里的 id 才比；新建的领取平台（还没有 id）照样算「不同」
    const claimId = existingPlatformId(b.fields.claimPlatform);
    const claimNew = b.fields.claimPlatform ? (claimId ? `id:${claimId}` : b.fields.claimPlatform) : null;
    const byCard = {};
    for (const cardId of choices) {
      if (!mentioned.has(cardId)) mentioned.set(cardId, new Set());
      mentioned.get(cardId).add(normalizeName(b.fields.name));
      const parentId = parentRowId(b, cardId);
      if (parentId === undefined) continue;
      const r = sameBenefit(rowsOf(cardId), b.fields.name, parentId);
      if (!r) continue;
      const match = { kind: 'update', id: r.id, name: r.name };
      if (r.archived) match.archived = true;
      byCard[cardId] = { targetId: r.id, match, diff: benefitDiff(r, b.fields, claimNew), current: benefitCurrent(r) };
    }
    hitsOf.set(b.key, byCard);
    const card = cardByKey.get(b.fields.membership);
    if (card && card.match.candidates) b.byCard = byCard;
    const hit = byCard[existingCardId(b.fields.membership)];
    if (!hit) continue;
    b.action = 'update';
    b.targetId = hit.targetId;
    b.match = hit.match;
    b.diff = hit.diff;
    b.current = hit.current;
  }
  /** 库里这张卡有、这次没提到的顶层权益（没归档的）。 */
  const notMentionedOf = (cardId) => {
    const said = mentioned.get(cardId) || new Set();
    return rowsOf(cardId)
      .filter((r) => !r.archived && !r.parent_id && !said.has(normalizeName(r.name)))
      .map((r) => ({ id: r.id, name: r.name }));
  };
  for (const m of draft.memberships) {
    if (m.action === 'update') m.notMentioned = notMentionedOf(m.targetId);
    for (const c of m.match.candidates || []) c.notMentioned = notMentionedOf(c.id);
  }

  // 4. 物品
  const assets = db.all("SELECT id, name, price_cents, purchased_on FROM assets WHERE deleted_at IS NULL");
  for (const it of draft.items) {
    const key = normalizeName(it.fields.name);
    const exists = assets.find((a) => normalizeName(a.name) === key && a.price_cents === it.fields.priceCents);
    if (exists) {
      it.action = 'skip';
      it.match = { kind: 'exists', id: exists.id, name: exists.name };
      it.checked = false;
      it.badges.push('exists');
    } else {
      it.action = 'create';
      const near = assets.filter((a) => similar(normalizeName(a.name), key, 2));
      it.match = near.length
        ? { kind: 'near', candidates: near.map((a) => ({ id: a.id, name: a.name, priceCents: a.price_cents, purchasedOn: a.purchased_on })) }
        : { kind: 'none' };
      if (near.length) it.badges.push('maybe_dup');
    }
    it.txCandidates = itemTxCandidates(db, it.fields);
    it.link = it.txCandidates.length === 1 ? { mode: 'link', transactionId: it.txCandidates[0].id } : { mode: 'none', transactionId: null };
  }
  return draft;
}

module.exports = {
  ALIAS_SEED, editDistance, similar, matchPlatform, matchImport, itemTxCandidates, unionLimits,
  sameCard, sameBenefit, membershipDiff, benefitDiff, membershipCurrent, benefitCurrent, diffOf,
};
