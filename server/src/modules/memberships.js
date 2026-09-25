'use strict';

// 会员/卡 = 挂在某个平台下、带着一串权益的东西（88VIP、京东 PLUS、招行经典白）。
// 这里守住：平台必须存活；派生会员（source_benefit_id）不成环；到期日不早于本期开始（都允许未来日期）；
// 账户只有信用卡能挂。新建可选「同时记一笔支出」（默认不记，收 clientId 做幂等，和物品一样）。
// 删除：名下还有权益时 409 has_children；带 ?cascade=1 在同一事务里连权益、选项、打卡事件一起软删，
// 指向这些权益的派生会员把 source_benefit_id 置空（lib/crud.js 的 onDelete + benefits.js 的 removeBenefits）。

const { HttpError } = require('../lib/router');
const { makeCrud } = require('../lib/crud');
const { rowToJson } = require('../lib/db');
const v = require('../lib/validate');
const perks = require('../lib/perks_schema');

const MAX_AMOUNT = 1e14;
const RECORD_KEYS = ['accountId', 'fundId', 'categoryId', 'memberId'];

// 会员只记到「哪一天」：钉在当天中午，和物品同一个口径（modules/assets.js）。
const noonOf = (day) => `${day}T12:00:00+08:00`;

module.exports = (ctx) => {
  const { db } = ctx;

  const alive = (table, id) => !!db.get(`SELECT 1 AS ok FROM ${table} WHERE id = ? AND deleted_at IS NULL`, id);
  const aliveRow = (table, id) => db.get(`SELECT * FROM ${table} WHERE id = ? AND deleted_at IS NULL`, id);

  /** 「同时记账」请求体 → createTransaction 的一部分；类型、金额、日期由会员本身决定。 */
  function recordFrom(raw, row) {
    if (raw === undefined || raw === null || raw === false) return null;
    if (!v.isObject(raw)) v.bad('recordTransaction', 'recordTransaction 必须是对象');
    const out = {};
    for (const k of RECORD_KEYS) if (raw[k] !== undefined) out[k] = raw[k];
    if (out.memberId === undefined && row.member_id && alive('members', row.member_id)) out.memberId = row.member_id;
    return out;
  }

  const crud = makeCrud({
    db,
    table: 'memberships',
    resource: 'memberships',
    singular: 'membership',
    label: '会员',
    idempotency: 'membership.create',
    // pay_pattern（扣费特征，P6/P7 写）不是可写字段，但回应要和 /changes 一个形状（modules/changes.js 的 SYNCED）：
    // 否则 App 落本地时把字符串当成「没有」，缓存里的 payPattern 要等下一次同步才回来。
    toJson: (row) => rowToJson(row, { bools: ['archived', 'is_trial'], json: ['pay_pattern', 'origin'] }),
    fields: {
      platformId: { type: 'id', required: true },
      sourceBenefitId: { type: 'id' },
      name: { type: 'string', required: true, max: 60 },
      tier: { type: 'string', max: 30 },
      kind: { type: 'enum', values: perks.MEMBERSHIP_KINDS, default: 'membership' },
      memberId: { type: 'id' },
      accountId: { type: 'id' },
      feeCents: { type: 'int', min: 0, max: MAX_AMOUNT },
      feePeriod: { type: 'enum', values: perks.FEE_PERIODS, default: 'year' },
      termPaidCents: { type: 'int', min: 0, max: MAX_AMOUNT },
      autoRenew: { type: 'enum', values: perks.AUTO_RENEW, default: 'unknown' },
      isTrial: { type: 'bool', default: false },
      remindDays: { type: 'int', min: 0, max: 365 },
      origin: { type: 'json', default: '{}' },
      note: { type: 'string', max: 1000 },
    },

    /** 跨字段、跨表的规则，比的是「旧行 + 本次改动」合并后的样子。 */
    fromBody(body, isPatch, row) {
      const given = (k) => body[k] !== undefined;
      const blank = (k) => v.isMissing(body[k]) || body[k] === '';
      const pick = (k, col) => (given(k) ? body[k] : row ? row[col] : null);
      const out = {};

      // 空串过了字段校验会变成 null，撞上 NOT NULL 就是 500：这里一并当「平台不存在」。
      if (given('platformId') && (blank('platformId') || !alive('platforms', String(body.platformId).trim()))) {
        v.bad('platformId', '平台不存在');
      }

      if (!blank('sourceBenefitId')) {
        perks.checkSourceChain({
          membershipId: row ? row.id : null,
          sourceBenefitId: String(body.sourceBenefitId).trim(),
          benefitOf: (id) => aliveRow('benefits', id),
          membershipOf: (id) => aliveRow('memberships', id),
        });
      }

      if (!blank('memberId') && !alive('members', String(body.memberId).trim())) v.bad('memberId', '成员不存在');

      // 账户只给信用卡用：改成别的类型时顺手清掉，不然会留下一张「挂着信用卡账户的视频会员」。
      const kind = pick('kind', 'kind') ?? 'membership';
      if (kind !== 'credit_card') {
        if (!blank('accountId')) v.bad('accountId', '只有信用卡能关联账户');
        out.account_id = null;
      } else if (!blank('accountId') && !alive('accounts', String(body.accountId).trim())) {
        v.bad('accountId', '账户不存在');
      }

      // 会员的日期允许在将来（到期日、预约的开通日）；到期日不早于本期开始。
      const termStartOn = given('termStartOn') ? v.optDay(body.termStartOn, 'termStartOn', { future: true }) : (row ? row.term_start_on : null);
      const expiresOn = given('expiresOn') ? v.optDay(body.expiresOn, 'expiresOn', { future: true }) : (row ? row.expires_on : null);
      perks.dateOrder(termStartOn, expiresOn, given('expiresOn') ? 'expiresOn' : 'termStartOn', '到期日不能早于本期开始');
      out.term_start_on = termStartOn;
      out.expires_on = expiresOn;

      if (given('origin')) out.origin = JSON.stringify(v.isMissing(body.origin) ? {} : perks.originOf(body.origin));
      return out;
    },

    /** 新建时「同时记一笔支出」：金额 = 本期实付（没填按续费价）；0 或没有就不记。 */
    onWrite(row, { isPatch, body, reqCtx }) {
      if (isPatch) return;
      const rec = recordFrom(body.recordTransaction, row);
      const amount = row.term_paid_cents ?? row.fee_cents;
      if (!rec || !amount) return;
      // 本期从将来才开始（预约开通）也只能记到今天：还没发生的事不该有账。
      const today = v.localDay();
      const day = row.term_start_on && row.term_start_on < today ? row.term_start_on : today;
      const { row: tx } = ctx.createTransaction({
        ...rec,
        type: 'expense',
        amountCents: amount,
        occurredAt: noonOf(day),
        merchant: row.tier ? `${row.name} ${row.tier}` : row.name,
        source: 'manual',
      }, reqCtx);
      db.run('UPDATE memberships SET last_charge_tx_id = ? WHERE id = ?', tx.id, row.id);
    },

    canDelete(row, reqCtx) {
      if (reqCtx.query.cascade === '1') return;
      const n = db.get('SELECT COUNT(*) AS n FROM benefits WHERE membership_id = ? AND deleted_at IS NULL', row.id).n;
      if (n > 0) throw new HttpError(409, 'has_children', `这张卡下还有 ${n} 项权益，要一起删掉吗？`, { benefits: n });
    },

    /** ?cascade=1：名下的权益（含选项）连同打卡事件一起软删，派生会员解开（modules/benefits.js）。 */
    onDelete(row, reqCtx) {
      if (reqCtx.query.cascade !== '1') return;
      const ids = db.all('SELECT id FROM benefits WHERE membership_id = ? AND deleted_at IS NULL', row.id).map((b) => b.id);
      ctx.perks.removeBenefits(ids, db.now());
    },
  });

  return { name: 'memberships', routes: crud.routes };
};
