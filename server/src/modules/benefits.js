'use strict';

// 权益 = 一张卡能兑现的一样东西（优酷年卡、每月 4 张红包券、机场贵宾厅 6 次）。
// 可以指定「在哪个平台领」（claim_platform_id，空 = 会员本平台）和领取路径；额度是可叠加的上限列表
// （lib/perks_schema.js quotaOf）；N 选 1 = 一条 kind='choice' 的父权益 + 若干选项（只许一层，选项不设额度、
// flow 跟随父权益）。父权益换了卡或改了 flow，选项跟着一起改；换卡不能挪进由它（或选项）带出来的卡（成环）。
// 新建收 clientId 做幂等（回应丢了再点保存也只建一条）。本期、剩余这些派生数只在 App 算（P3）。
// 删除：还有选项或打卡事件时 409 has_children；?cascade=1 连选项和事件一起软删；指向被删权益的派生会员解开。
// 新建「N 选 1」可以顺带 options:[{…选项字段}]（最多 30 个），和父权益同一个事务：哪个选项不对整条都不建，
// 回应多一个 options（建好的选项）。建卡时顺带的权益（memberships.js）也走这里的 insertBenefit。

const { HttpError } = require('../lib/router');
const { makeCrud } = require('../lib/crud');
const v = require('../lib/validate');
const perks = require('../lib/perks_schema');

/** 新建时顺带子项的请求体上限（建卡最多 50 项权益、每个「N 选 1」最多 30 个选项）。 */
const CHILDREN_BODY_MAX = 512 * 1024;

module.exports = (ctx) => {
  const { db } = ctx;

  const aliveRow = (table, id) => db.get(`SELECT * FROM ${table} WHERE id = ? AND deleted_at IS NULL`, id);
  const optionIds = (id) => db.all('SELECT id FROM benefits WHERE parent_id = ? AND deleted_at IS NULL', id).map((r) => r.id);
  const eventCount = (ids) => ids.reduce(
    (n, id) => n + db.get('SELECT COUNT(*) AS n FROM benefit_events WHERE benefit_id = ? AND deleted_at IS NULL', id).n,
    0,
  );

  /**
   * 软删 [ids] 这些权益（已经删了的跳过）、它们的打卡事件，并把指向它们的派生会员解开
   * （source_benefit_id 置空）。每行都拿新的 seq：两行共用一个会让分页的 /changes 停在半路。
   * memberships.js 的级联删除也走这里。
   */
  function removeBenefits(ids, now) {
    for (const id of ids) {
      if (aliveRow('benefits', id)) {
        db.run('UPDATE benefits SET deleted_at = ?, updated_at = ?, seq = ? WHERE id = ?', now, now, db.nextSeq(), id);
      }
      for (const e of db.all('SELECT id FROM benefit_events WHERE benefit_id = ? AND deleted_at IS NULL', id)) {
        db.run('UPDATE benefit_events SET deleted_at = ?, updated_at = ?, seq = ? WHERE id = ?', now, now, db.nextSeq(), e.id);
      }
      for (const m of db.all('SELECT id FROM memberships WHERE source_benefit_id = ? AND deleted_at IS NULL', id)) {
        db.run('UPDATE memberships SET source_benefit_id = NULL, updated_at = ?, seq = ? WHERE id = ?', now, db.nextSeq(), m.id);
      }
    }
  }
  ctx.perks = { ...(ctx.perks || {}), removeBenefits };

  const crud = makeCrud({
    db,
    table: 'benefits',
    resource: 'benefits',
    singular: 'benefit',
    label: '权益',
    idempotency: 'benefit.create',
    // 字段表和 AI 导入共用（lib/perks_schema.js）；quota / limits / origin 的真正校验在下面 fromBody。
    fields: perks.BENEFIT_FIELDS,

    /** 引用、父子规则、日期先后，比的是「旧行 + 本次改动」合并后的样子。 */
    fromBody(body, isPatch, row) {
      const given = (k) => body[k] !== undefined;
      const blank = (k) => v.isMissing(body[k]) || body[k] === '';
      const out = {};

      let membershipId = row ? row.membership_id : null;
      if (given('membershipId')) {
        membershipId = blank('membershipId') ? '' : String(body.membershipId).trim();
        if (!membershipId || !aliveRow('memberships', membershipId)) v.bad('membershipId', '会员不存在');
        // 换卡（选项跟着走）不能挪进由它自己带出来的卡，不然派生链成环（spec §2）。
        if (row && membershipId !== row.membership_id) {
          perks.checkBenefitMove({
            benefitIds: [row.id, ...optionIds(row.id)],
            targetMembershipId: membershipId,
            benefitOf: (id) => aliveRow('benefits', id),
            membershipOf: (id) => aliveRow('memberships', id),
          });
        }
      }
      if (!blank('claimPlatformId') && !aliveRow('platforms', String(body.claimPlatformId).trim())) {
        v.bad('claimPlatformId', '领取平台不存在');
      }
      if (given('claimUrl')) out.claim_url = perks.httpUrl(body.claimUrl, 'claimUrl');

      if (given('quota')) out.quota = JSON.stringify(perks.quotaOf(body.quota ?? []));
      if (given('limits')) out.limits = JSON.stringify(perks.limitsOf(body.limits ?? []));
      if (given('origin')) out.origin = JSON.stringify(v.isMissing(body.origin) ? {} : perks.originOf(body.origin));
      else if (isPatch) {
        // 改过的字段算确认过，「AI 推断」小点跟着消失。
        const pruned = perks.pruneUnverified(body, row);
        if (pruned) out.origin = pruned;
      }

      // 权益自身的有效窗口，允许未来日期；止不早于起。
      const validFrom = given('validFrom') ? v.optDay(body.validFrom, 'validFrom', { future: true }) : (row ? row.valid_from : null);
      const validUntil = given('validUntil') ? v.optDay(body.validUntil, 'validUntil', { future: true }) : (row ? row.valid_until : null);
      perks.dateOrder(validFrom, validUntil, given('validUntil') ? 'validUntil' : 'validFrom', '有效期的结束不能早于开始');
      out.valid_from = validFrom;
      out.valid_until = validUntil;

      const parentId = given('parentId') ? (blank('parentId') ? null : String(body.parentId).trim()) : (row ? row.parent_id : null);
      const parent = parentId ? aliveRow('benefits', parentId) : null;
      if (parentId && !parent) v.bad('parentId', '父权益不存在');
      const merged = {
        id: row ? row.id : null,
        membership_id: membershipId,
        kind: given('kind') ? (body.kind ?? 'other') : (row ? row.kind : 'other'),
        quota: out.quota ?? (row ? row.quota : '[]'),
      };
      // 顺带的选项只在新建「N 选 1」时收；已有的「N 选 1」加选项走 POST /benefits（parentId）。null 当没给。
      if (!v.isMissing(body.options)) {
        if (isPatch) v.bad('options', '已有的「N 选 1」在会员详情里加选项');
        if (merged.kind !== 'choice') v.bad('options', '只有「N 选 1」能带选项');
        perks.childList(body.options, 'options');
      }
      // 父权益换卡时它的选项跟着搬（onWrite），所以这里只拿「搬之前」的选项数判断结构。
      Object.assign(out, perks.benefitParentRules(merged, parent, row ? optionIds(row.id).length : 0));
      return out;
    },

    /** 新建「N 选 1」顺带的选项一个个建（同一个事务）；父权益换了卡或改了 flow：选项跟着改（每行新的 seq）。 */
    onWrite(row, { isPatch, body, reqCtx }) {
      if (!isPatch) {
        if (row.kind === 'choice' && Array.isArray(body.options)) {
          body.options.forEach((o, i) => perks.asChild('options', i, o, () =>
            insertBenefit({ ...o, membershipId: row.membership_id, parentId: row.id }, reqCtx)));
        }
        return;
      }
      if (row.kind !== 'choice') return;
      const now = db.now();
      const kids = db.all(
        'SELECT id FROM benefits WHERE parent_id = ? AND deleted_at IS NULL AND (membership_id != ? OR flow != ?)',
        row.id, row.membership_id, row.flow,
      );
      for (const k of kids) {
        db.run(
          'UPDATE benefits SET membership_id = ?, flow = ?, updated_at = ?, seq = ? WHERE id = ?',
          row.membership_id, row.flow, now, db.nextSeq(), k.id,
        );
      }
    },

    /** 顺带建了选项的，回应里一并带上（App 落本地，不用等下一次同步）。 */
    createExtra(row, body) {
      if (!Array.isArray(body.options) || body.options.length === 0) return {};
      return { options: childrenOf('parent_id', row.id).map(toJson) };
    },

    canDelete(row, reqCtx) {
      if (reqCtx.query.cascade === '1') return;
      const options = optionIds(row.id);
      const events = eventCount([row.id, ...options]);
      if (options.length > 0 || events > 0) {
        const parts = [];
        if (options.length > 0) parts.push(`${options.length} 个选项`);
        if (events > 0) parts.push(`${events} 条打卡记录`);
        throw new HttpError(409, 'has_children', `这条下面还有 ${parts.join('、')}，要一起删掉吗？`, { options: options.length, events });
      }
    },

    /** ?cascade=1 时连选项和各自的打卡事件一起删（不带 cascade 时 canDelete 已保证它们都没有）；带出过的派生会员解开。 */
    onDelete(row) {
      const now = db.now();
      removeBenefits([row.id, ...optionIds(row.id)], now);
    },
  });

  const toJson = (row) => crud.toJson(row);
  /** 只建一条（不管幂等）：建卡、建「N 选 1」时顺带的子项用，调用方已经在事务里。 */
  function insertBenefit(body, reqCtx) {
    return crud.insert(body, reqCtx);
  }
  /** 某张卡（membership_id）或某个「N 选 1」（parent_id）下存活的权益，按用户的排序。 */
  function childrenOf(column, id) {
    return db.all(
      `SELECT * FROM benefits WHERE ${column} = ? AND deleted_at IS NULL ORDER BY sort_order ASC, created_at ASC`,
      id,
    );
  }
  ctx.perks = { ...ctx.perks, insertBenefit, benefitsOf: (membershipId) => childrenOf('membership_id', membershipId).map(toJson) };

  // 「N 选 1」带 30 个选项（各自有领取路径、限制、备注）可能超过默认的 64KB。
  const routes = crud.routes.map((r) => (r.method === 'POST' && r.pattern === '/benefits' ? { ...r, maxBody: CHILDREN_BODY_MAX } : r));
  return { name: 'benefits', routes };
};
