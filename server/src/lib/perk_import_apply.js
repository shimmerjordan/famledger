'use strict';

// AI 导入的落库（spec §4 `POST /asset-import/apply`、§6「实物导入」）。一个 db.tx 里按 平台 → 会员 → 权益（父在前）→ 物品
// 的顺序写，**只增改、不删**。请求体：
//
//   {clientId, importId, platforms[], memberships[], benefits[], items[]}
//   每项 {key, action, targetId?, fields, take?, edited?, match?, ev?, unverified?}
//     platforms    action create | merge | skip；merge 时 targetId 是已有平台，名字和它不同就记成它的别名；
//                  match 是预览时的比对结果（exact / alias / maybe / none，没给按 none）
//     memberships  action create | update | skip；fields.platform 是 'key:p1' 或 'id:<已有平台>'
//     benefits     action create | update | skip；fields.membership / parent / claimPlatform 同样用 key: / id: 引用
//     items        action create | skip；另带 linkTransactionId（只关联已有流水，不另记账；金额要和价格一样）或
//                  recordTransaction（同时记一笔支出）
//     update 只写 take[] 里列的字段（'archived' = 把归档的那行恢复）；limits 取「库里现在的 ∪ 这次的」。
//     edited 是预览里人工改过的字段：create 被重新比对转成 update 时，这些字段和默认勾选的差异一起写。
//
// 服务端重新校验（字段表和规则都用 lib/perks_schema.js，和 CRUD 同一套）、重新比对（lib/perk_import_match.js 同一套口径），
// 回应里的 autoMerged = [{key, id, name, table}] 列出这些「本来要新建、库里已经有了」的：
//   · 平台：名字撞上已有平台（规范化名唯一，只能并入）；或者预览时还不是别名、现在是了（别人刚建、刚加了别名）。
//     预览里就是 alias、用户仍选了新建的，照用户的建。
//   · 会员：新建的卡挂在已有平台下（预览之后别人刚建了同一张，或预览里把平台并入了已有的），那个平台下恰好有一张
//     没归档的同名卡 → 转成更新它。好几张分不清的照样新建（预览里选了「新建一张」的就是这种）。
//   · 权益：新建的权益挂在已有的卡下，卡里同一个「N 选 1」下（顶层就是顶层）已经有同名的 → 转成更新那项
//     （同名多张卡选定之后、移到已有的卡下都会走到）。新建的卡、新建的「N 选 1」下面不比。
//   转成更新时写「默认勾选的差异 ∪ edited」。
// 任意一条出错就整体回滚，400 import_invalid，details.errors = [{key, field, message}] —— 一次把所有错都报回去，
// App 标到对应节点上。上限（只数不是 skip 的）：平台 50、会员 50、权益 200、物品 50。
//
// 新建和更新的行都写 origin {src, importId, ev, unverified}（src = 'ai_' + 这批识别的来源：ai_text / ai_image）；ai_imports 那行改成 applied，undo 里记下
// P5 撤销要用的东西：{created:[{table,id}], updated:[{table,id,seq,before}], aliases:[{platformId,alias}], transactions:[id]}。

const crypto = require('node:crypto');

const { HttpError } = require('./router');
const { coerceFields } = require('./crud');
const idem = require('./idempotency');
const v = require('./validate');
const perks = require('./perks_schema');
const valuation = require('./valuation');
const { matchPlatform, unionLimits, sameCard, sameBenefit, membershipDiff, benefitDiff } = require('./perk_import_match');

const LIMITS = { platforms: 50, memberships: 50, benefits: 200, items: 50 };
const ACTIONS = {
  platforms: ['create', 'merge', 'skip'],
  memberships: ['create', 'update', 'skip'],
  benefits: ['create', 'update', 'skip'],
  items: ['create', 'skip'],
};
const RECORD_KEYS = ['accountId', 'fundId', 'categoryId', 'memberId'];
const MAX_AMOUNT = 1e14;
/** 错误码里的 API 字段名 → 草稿里的字段名（App 按它标到表单的那一栏）。 */
const FIELD_BACK = { platformId: 'platform', membershipId: 'membership', parentId: 'parent', claimPlatformId: 'claimPlatform' };
const MEMBERSHIP_TAKE = ['name', 'tier', 'kind', 'feeCents', 'feePeriod', 'termStartOn', 'expiresOn', 'autoRenew', 'isTrial', 'archived'];
const BENEFIT_TAKE = ['name', 'kind', 'claimPlatform', 'claimHow', 'claimUrl', 'flow', 'quota', 'anchor', 'validFrom', 'validUntil', 'faceValueCents', 'limits', 'archived'];
const PLATFORM_MATCH = ['exact', 'alias', 'maybe', 'none'];

const noonOf = (day) => `${day}T12:00:00+08:00`;

/** 整体回滚用：带着收集到的全部错误。 */
class ImportInvalid extends Error {
  constructor(errors) {
    super('import_invalid');
    this.errors = errors;
  }
}

function applyImport({ db, ctx, body, reqCtx, importRow, clientId }) {
  const lists = {};
  for (const name of Object.keys(LIMITS)) {
    lists[name] = v.list(body[name], name, { max: 1000 });
    // 没勾的（skip）也要发过来（别的项可能引用它的 key），不算进上限。
    if (lists[name].filter((x) => !(v.isObject(x) && x.action === 'skip')).length > LIMITS[name]) {
      throw new HttpError(400, 'too_many', `一次最多导入平台 ${LIMITS.platforms} 个、会员 ${LIMITS.memberships} 张、权益 ${LIMITS.benefits} 项、物品 ${LIMITS.items} 件`);
    }
  }
  const importId = importRow.id;
  const src = `ai_${importRow.source_kind || 'text'}`;
  const errors = [];
  const ids = new Map(); // key → 落库后的 id
  const keys = new Set();
  const created = { platforms: 0, memberships: 0, benefits: 0, items: 0, transactions: 0 };
  const updated = { platforms: 0, memberships: 0, benefits: 0 };
  const autoMerged = [];
  const undo = { created: [], updated: [], aliases: [], transactions: [] };
  const createdIds = new Set(); // 这次新建的行：挂在它们下面的不用重新比对（新的，下面还什么都没有）

  const alive = (table, id) => db.get(`SELECT * FROM ${table} WHERE id = ? AND deleted_at IS NULL`, id);
  const nextSort = (table) => {
    const r = db.get(`SELECT MAX(sort_order) AS m FROM ${table} WHERE deleted_at IS NULL`);
    return (r && typeof r.m === 'number' ? r.m : -1) + 1;
  };
  function insert(table, cols) {
    const now = db.now();
    const id = crypto.randomUUID();
    const all = { id, ...cols, created_at: now, updated_at: now, seq: db.nextSeq() };
    const names = Object.keys(all);
    db.run(`INSERT INTO ${table}(${names.join(', ')}) VALUES(${names.map(() => '?').join(', ')})`, ...names.map((k) => all[k]));
    undo.created.push({ table, id });
    createdIds.add(id);
    return id;
  }
  /** 只改给了的列；undo 里记下改之前的值和改完的 seq（P5 撤销时 seq 没变才恢复）。 */
  function update(table, row, cols) {
    const names = Object.keys(cols).filter((k) => JSON.stringify(cols[k]) !== JSON.stringify(row[k]));
    if (!names.length) return false;
    const seq = db.nextSeq();
    db.run(
      `UPDATE ${table} SET ${[...names.map((k) => `${k} = ?`), 'updated_at = ?', 'seq = ?'].join(', ')} WHERE id = ?`,
      ...names.map((k) => cols[k]), db.now(), seq, row.id,
    );
    undo.updated.push({ table, id: row.id, seq, before: Object.fromEntries(names.map((k) => [k, row[k]])) });
    return true;
  }

  /** 'key:p1' / 'id:<uuid>' / null → 落库的 id（或 null）；引用不上就 400（字段名是草稿里的）。 */
  function ref(raw, field, table, label, { required = false } = {}) {
    if (raw === null || raw === undefined || raw === '') {
      if (required) v.bad(field, `还没选${label}`);
      return null;
    }
    const s = v.str(raw, field, { max: 80 });
    if (s.startsWith('key:')) {
      const id = ids.get(s.slice(4));
      if (!id) v.bad(field, `${label}没有导入（没勾选或它自己出错了）`);
      return id;
    }
    if (s.startsWith('id:')) {
      if (!alive(table, s.slice(3))) v.bad(field, `${label}已经不在了`);
      return s.slice(3);
    }
    v.bad(field, `${field} 要写成 key:… 或 id:…`);
  }

  /** 这一项的 origin：{src, importId, ev, unverified}（unverified 限在给定的字段里）。 */
  function originFor(item, onlyFields = null) {
    const unverified = Array.isArray(item.unverified) ? item.unverified.filter((f) => typeof f === 'string') : [];
    return perks.originOf({
      src,
      importId,
      ev: typeof item.ev === 'string' ? item.ev.slice(0, 200) : null,
      unverified: onlyFields ? unverified.filter((f) => onlyFields.includes(f)) : unverified,
    });
  }

  /** create 被重新比对转成 update 时写的字段：默认勾选的差异 ∪ 预览里人工改过的（限在 [allowed] 里）。 */
  function autoTake(diff, edited, allowed) {
    const hand = Array.isArray(edited) ? edited.filter((k) => typeof k === 'string' && allowed.includes(k)) : [];
    return [...new Set([...diff.filter((d) => d.take).map((d) => d.field), ...hand])];
  }

  /** 一项的公共前置：key 唯一、action 合法。skip 回 false。 */
  function head(list, item) {
    if (!v.isObject(item)) v.bad('item', '每一项都必须是对象');
    const key = v.str(item.key, 'key', { max: 20 });
    if (keys.has(key)) v.bad('key', `key「${key}」重复了`);
    keys.add(key);
    const action = v.enumOf(item.action, 'action', ACTIONS[list]);
    if (action !== 'skip' && !v.isObject(item.fields)) v.bad('fields', 'fields 必须是对象');
    return action !== 'skip';
  }

  /** 跑一项；HttpError 收进 errors（接着跑下一项，一次报全），别的异常照常抛（500）。 */
  function each(list, fn) {
    for (const item of list) {
      try {
        fn(item);
      } catch (e) {
        if (!(e instanceof HttpError)) throw e;
        const field = e.code.startsWith('invalid_') ? e.code.slice(8) : null;
        errors.push({ key: v.isObject(item) && typeof item.key === 'string' ? item.key : null, field: FIELD_BACK[field] || field, message: e.message });
      }
    }
  }

  function platformStep(item) {
    if (!head('platforms', item)) return;
    const f = item.fields;
    if (item.action === 'merge') {
      const target = alive('platforms', v.str(item.targetId, 'targetId', { max: 64 }));
      if (!target) v.bad('targetId', '要并入的平台已经不在了');
      mergeInto(target, f.name);
      ids.set(item.key, target.id);
      return;
    }
    const name = v.str(f.name, 'name', { max: 40 });
    if (perks.normalizeName(name) === '') v.bad('name', '名称里至少要有一个字或字母');
    const seen = v.isMissing(item.match) ? 'none' : v.enumOf(item.match, 'match', PLATFORM_MATCH);
    // 名字撞上已有平台：规范化名唯一，只能并入。别名命中：预览时就是别名、用户仍选了「新建」的照建；
    // 预览时还不是（别人刚建了这个平台、刚加了这个别名）→ 自动转成并入。
    const now = matchPlatform(db.all('SELECT id, name, aliases FROM platforms WHERE deleted_at IS NULL'), name);
    if (now.kind === 'exact' || (now.kind === 'alias' && seen !== 'alias')) {
      mergeInto(alive('platforms', now.id), name);
      ids.set(item.key, now.id);
      autoMerged.push({ key: item.key, id: now.id, name: now.name, table: 'platforms' });
      return;
    }
    const cols = coerceFields(perks.PLATFORM_FIELDS, { name, kind: f.kind ?? 'other', aliases: [] });
    cols.sort_order = nextSort('platforms');
    ids.set(item.key, insert('platforms', cols));
    created.platforms++;
  }

  /** 并入已有平台：名字和它（名字或别名）都不同就追加成别名（≤30 字、最多 20 个，放不下就不记）。 */
  function mergeInto(target, rawName) {
    const name = typeof rawName === 'string' ? rawName.trim() : '';
    const key = perks.normalizeName(name);
    const aliases = perks.asList(target.aliases);
    const known = [target.name, ...aliases].map(perks.normalizeName);
    if (!key || known.includes(key) || name.length > 30 || aliases.length >= perks.MAX_ALIASES) return;
    if (update('platforms', target, { aliases: JSON.stringify([...aliases, name]) })) {
      undo.aliases.push({ platformId: target.id, alias: name });
      updated.platforms++;
    }
  }

  function membershipStep(item) {
    if (!head('memberships', item)) return;
    const f = item.fields;
    const cols = {};
    let row = null;
    let take = null;
    let platformId = null;
    if (item.action === 'update') {
      row = alive('memberships', v.str(item.targetId, 'targetId', { max: 64 }));
      if (!row) v.bad('targetId', '要更新的那张卡已经不在了');
      take = v.list(item.take, 'take', { max: 30 }).filter((k) => MEMBERSHIP_TAKE.includes(k));
    } else {
      platformId = ref(f.platform, 'platform', 'platforms', '平台', { required: true });
      // 挂在已有平台下：那个平台下恰好有一张没归档的同名卡 → 转成更新它（预览之后别人刚建的、预览里把平台并入了已有的）。
      if (!createdIds.has(platformId)) {
        const hits = db.all('SELECT * FROM memberships WHERE deleted_at IS NULL AND archived = 0 AND platform_id = ?', platformId).filter((r) => sameCard(r, f));
        if (hits.length === 1) {
          row = hits[0];
          take = autoTake(membershipDiff(row, f), item.edited, MEMBERSHIP_TAKE);
          autoMerged.push({ key: item.key, id: row.id, name: row.name, table: 'memberships' });
        }
      }
    }
    const given = (k) => (take ? take.includes(k) : true);
    const bodyOf = {};
    for (const k of ['name', 'tier', 'kind', 'feeCents', 'feePeriod', 'autoRenew', 'isTrial']) if (given(k) && f[k] !== undefined) bodyOf[k] = f[k];
    if (!take) {
      bodyOf.platformId = platformId;
      if (!v.isMissing(f.memberId) && f.memberId !== '') {
        const memberId = v.str(f.memberId, 'memberId', { max: 64 });
        if (!alive('members', memberId)) v.bad('memberId', '成员不存在');
        bodyOf.memberId = memberId;
      }
    }
    Object.assign(cols, coerceFields(perks.MEMBERSHIP_FIELDS, bodyOf, !!take));
    const termStartOn = given('termStartOn') && f.termStartOn !== undefined ? v.optDay(f.termStartOn, 'termStartOn', { future: true }) : (row ? row.term_start_on : null);
    const expiresOn = given('expiresOn') && f.expiresOn !== undefined ? v.optDay(f.expiresOn, 'expiresOn', { future: true }) : (row ? row.expires_on : null);
    perks.dateOrder(termStartOn, expiresOn, 'expiresOn', '到期日不能早于本期开始');
    if (!take || take.includes('termStartOn')) cols.term_start_on = termStartOn;
    if (!take || take.includes('expiresOn')) cols.expires_on = expiresOn;
    if (take && take.includes('archived')) cols.archived = 0; // 恢复：材料说明它还在用，不恢复的话本期看不到
    if (!take) {
      cols.origin = JSON.stringify(originFor(item));
      cols.sort_order = nextSort('memberships');
      ids.set(item.key, insert('memberships', cols));
      created.memberships++;
      return;
    }
    if (take.length) cols.origin = JSON.stringify(mergedOrigin(row.origin, item, take));
    // 真改了才算「更新了」：同一段材料再导一次时全是没有差异的 update，结果页不该写「更新：会员卡 1 张」。
    if (update('memberships', row, cols)) updated.memberships++;
    ids.set(item.key, row.id);
  }

  /** 更新的行：原来的 origin 保留，src / importId / ev 换成这次的，unverified 并上这次勾的字段里推断的那些。 */
  function mergedOrigin(raw, item, take) {
    let old = {};
    try {
      old = JSON.parse(raw || '{}');
    } catch {
      old = {};
    }
    const next = originFor(item, take);
    const unverified = [...new Set([...(Array.isArray(old.unverified) ? old.unverified : []), ...(next.unverified || [])])];
    return perks.originOf({ ...old, ...next, unverified });
  }

  function benefitStep(item) {
    if (!head('benefits', item)) return;
    const f = item.fields;
    let row = null;
    let take = null;
    let membershipId = null;
    if (item.action === 'update') {
      row = alive('benefits', v.str(item.targetId, 'targetId', { max: 64 }));
      if (!row) v.bad('targetId', '要更新的那项权益已经不在了');
      take = v.list(item.take, 'take', { max: 30 }).filter((k) => BENEFIT_TAKE.includes(k));
    } else {
      membershipId = ref(f.membership, 'membership', 'memberships', '会员卡', { required: true });
      // 挂在已有的卡下、卡里已经有同名的：转成更新那项，不建第二份（同名多张卡选定之后、移到已有的卡下、别人刚加的）。
      // 只和同一个「N 选 1」下的比（顶层和顶层比）；新建的卡、新建的「N 选 1」下面都是新的，不比。
      const parentId = createdIds.has(membershipId) ? null : ref(f.parent, 'parent', 'benefits', '「N 选 1」');
      const same = createdIds.has(membershipId) || createdIds.has(parentId)
        ? null
        : sameBenefit(db.all('SELECT * FROM benefits WHERE deleted_at IS NULL AND membership_id = ?', membershipId), f.name, parentId);
      if (same) {
        const claimId = f.claimPlatform === undefined ? null : ref(f.claimPlatform, 'claimPlatform', 'platforms', '领取平台');
        row = same;
        take = autoTake(benefitDiff(row, f, claimId ? `id:${claimId}` : null), item.edited, BENEFIT_TAKE);
        autoMerged.push({ key: item.key, id: row.id, name: row.name, table: 'benefits' });
      }
    }
    const given = (k) => (take ? take.includes(k) : true);
    const bodyOf = {};
    for (const k of ['name', 'kind', 'claimHow', 'flow', 'anchor', 'faceValueCents']) if (given(k) && f[k] !== undefined) bodyOf[k] = f[k];
    if (!take) bodyOf.membershipId = membershipId;
    const cols = coerceFields(perks.BENEFIT_FIELDS, bodyOf, !!take);
    if (given('claimPlatform') && f.claimPlatform !== undefined) cols.claim_platform_id = ref(f.claimPlatform, 'claimPlatform', 'platforms', '领取平台');
    if (given('claimUrl') && f.claimUrl !== undefined) cols.claim_url = perks.httpUrl(f.claimUrl, 'claimUrl');
    if (given('quota') && f.quota !== undefined) cols.quota = JSON.stringify(perks.quotaOf(f.quota ?? []));
    if (given('limits') && f.limits !== undefined) {
      const limits = perks.limitsOf(f.limits ?? []);
      cols.limits = JSON.stringify(row ? unionLimits(perks.asList(row.limits), limits) : limits);
    }
    const validFrom = given('validFrom') && f.validFrom !== undefined ? v.optDay(f.validFrom, 'validFrom', { future: true }) : (row ? row.valid_from : null);
    const validUntil = given('validUntil') && f.validUntil !== undefined ? v.optDay(f.validUntil, 'validUntil', { future: true }) : (row ? row.valid_until : null);
    perks.dateOrder(validFrom, validUntil, 'validUntil', '有效期的结束不能早于开始');
    if (!take || take.includes('validFrom')) cols.valid_from = validFrom;
    if (!take || take.includes('validUntil')) cols.valid_until = validUntil;
    if (take && take.includes('archived')) cols.archived = 0;

    if (!take) {
      const parentId = ref(f.parent, 'parent', 'benefits', '「N 选 1」');
      const parent = parentId ? alive('benefits', parentId) : null;
      cols.parent_id = parentId;
      Object.assign(cols, perks.benefitParentRules(
        { id: null, membership_id: cols.membership_id, kind: cols.kind, quota: cols.quota ?? '[]' },
        parent,
        0,
      ));
      cols.origin = JSON.stringify(originFor(item));
      cols.sort_order = nextSort('benefits');
      ids.set(item.key, insert('benefits', cols));
      created.benefits++;
      return;
    }
    const merged = { id: row.id, membership_id: row.membership_id, kind: cols.kind ?? row.kind, quota: cols.quota ?? row.quota };
    const parent = row.parent_id ? alive('benefits', row.parent_id) : null;
    const options = db.get('SELECT COUNT(*) AS n FROM benefits WHERE parent_id = ? AND deleted_at IS NULL', row.id).n;
    Object.assign(cols, perks.benefitParentRules(merged, parent, options));
    if (take.length) cols.origin = JSON.stringify(mergedOrigin(row.origin, item, take.map((k) => (k === 'claimPlatform' ? 'claimPlatformId' : k))));
    if (update('benefits', row, cols)) updated.benefits++;
    // 「N 选 1」的父权益改了 flow：选项跟着改（和 CRUD 的 onWrite 一样，每行新的 seq、撤销时能恢复）。
    const flow = cols.flow ?? row.flow;
    if ((cols.kind ?? row.kind) === 'choice') {
      for (const o of db.all('SELECT * FROM benefits WHERE parent_id = ? AND deleted_at IS NULL AND flow != ?', row.id, flow)) update('benefits', o, { flow });
    }
    ids.set(item.key, row.id);
  }

  function itemStep(item) {
    if (!head('items', item)) return;
    const f = item.fields;
    const name = v.str(f.name, 'name', { max: 60 });
    const category = f.category === undefined || f.category === null ? 'other' : v.enumOf(f.category, 'category', Object.keys(valuation.CATEGORY_DEFAULTS));
    const priceCents = v.int(f.priceCents, 'priceCents', { min: 0, max: MAX_AMOUNT });
    const purchasedOn = v.day(f.purchasedOn, 'purchasedOn');
    const cols = {
      name,
      category,
      price_cents: priceCents,
      purchased_on: purchasedOn,
      status: 'in_use',
      valuation_method: f.valuationMethod === undefined || f.valuationMethod === null ? 'auto' : v.enumOf(f.valuationMethod, 'valuationMethod', valuation.METHODS),
      rate_bp: v.optInt(f.rateBp, 'rateBp', { min: 0, max: 9000 }),
      residual_bp: v.optInt(f.residualBp, 'residualBp', { min: 0, max: 10000 }),
      net_worth: f.netWorth === undefined || f.netWorth === null ? 'auto' : v.enumOf(f.netWorth, 'netWorth', valuation.NET_WORTH),
      note: v.optStr(f.note, 'note', { max: 500 }),
      origin: JSON.stringify(originFor(item)),
      sort_order: nextSort('assets'),
    };
    const linkId = v.optStr(item.linkTransactionId, 'linkTransactionId', { max: 64 });
    const record = item.recordTransaction;
    // 和物品接口的 recordFrom 一样：不记账写 null / false / 不给，给了别的形状就 400，不悄悄不记。
    if (!v.isMissing(record) && record !== false && !v.isObject(record)) v.bad('recordTransaction', 'recordTransaction 必须是对象');
    if (linkId && !v.isMissing(record) && record !== false) v.bad('linkTransactionId', '关联已有流水和同时记一笔只能选一个');
    if (linkId) {
      const tx = db.get('SELECT type, status, amount_cents FROM transactions WHERE id = ? AND deleted_at IS NULL', linkId);
      if (!tx) v.bad('linkTransactionId', '要关联的那笔流水不在了');
      if (tx.type !== 'expense' || tx.status !== 'confirmed') v.bad('linkTransactionId', '只能关联一笔已确认的支出');
      // 候选本来就只列同金额的；预览里改了价格还挂着原来那笔，就是挂错了（这笔钱不是买它花的）。
      if (tx.amount_cents !== priceCents) v.bad('linkTransactionId', '要关联的那笔流水金额和价格对不上');
      if (db.get('SELECT 1 AS ok FROM assets WHERE transaction_id = ? AND deleted_at IS NULL', linkId)) {
        v.bad('linkTransactionId', '这笔流水已经关联了别的物品');
      }
      cols.transaction_id = linkId;
    }
    const id = insert('assets', cols);
    if (!linkId && v.isObject(record) && priceCents > 0) {
      // 沿用物品接口「同时记账」的口径（modules/assets.js）：类型、金额、日期由物品决定；clientId 按导入 + key 定死，重放也只记一笔。
      const rec = {};
      for (const k of RECORD_KEYS) if (record[k] !== undefined) rec[k] = record[k];
      const { row: tx } = ctx.createTransaction({
        ...rec,
        type: 'expense',
        amountCents: priceCents,
        occurredAt: noonOf(purchasedOn),
        merchant: name,
        source: 'manual',
        clientId: `${importId}:${item.key}`,
      }, reqCtx);
      db.run('UPDATE assets SET transaction_id = ? WHERE id = ?', tx.id, id);
      undo.transactions.push(tx.id);
      created.transactions++;
    }
    ids.set(item.key, id);
    created.items++;
  }

  try {
    return db.tx(() => {
      each(lists.platforms, platformStep);
      each(lists.memberships, membershipStep);
      // 父权益（没有 key: 父引用的）先写，选项才引用得上。
      const isOption = (b) => v.isObject(b) && v.isObject(b.fields) && typeof b.fields.parent === 'string' && b.fields.parent.startsWith('key:');
      each(lists.benefits.filter((b) => !isOption(b)), benefitStep);
      each(lists.benefits.filter(isOption), benefitStep);
      each(lists.items, itemStep);
      if (errors.length) throw new ImportInvalid(errors);
      const response = { importId, created, updated, autoMerged, ids: Object.fromEntries(ids) };
      const summary = { ...JSON.parse(importRow.summary || '{}'), applied: { created, updated, autoMerged: autoMerged.length } };
      db.run(
        "UPDATE ai_imports SET status = 'applied', applied_at = ?, undo = ?, summary = ? WHERE id = ?",
        db.now(), JSON.stringify(undo), JSON.stringify(summary), importId,
      );
      idem.remember(db, 'asset_import.apply', clientId, importId, response);
      return response;
    });
  } catch (e) {
    if (e instanceof ImportInvalid) {
      throw new HttpError(400, 'import_invalid', `有 ${e.errors.length} 处要改，一条都没导入`, { errors: e.errors });
    }
    throw e;
  }
}

module.exports = { applyImport, LIMITS };
