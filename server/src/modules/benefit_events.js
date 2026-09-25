'use strict';

// 打卡事件 = 某项权益「领了 / 用了 / 本期跳过」的一条记录（spec §2 benefit_events）。
// 这里只记事实：权益要存活、不能是 N 选 1 的父权益（点它下面的选项）、日期不晚于今天、份数 1–999。
// 不校验额度 —— 超额只在 App 里显示「超额 N」，不拦（spec §3）；也不存 period_key，属于哪一期按当前规则现算。
// 删除 = 撤销打卡（软删，墓碑经 /changes 同步）。新建收 clientId 做幂等：一键打卡回应丢了再点，只记一条。

const { makeCrud } = require('../lib/crud');
const v = require('../lib/validate');
const perks = require('../lib/perks_schema');

const MAX_AMOUNT = 1e14;

module.exports = (ctx) => {
  const { db } = ctx;

  const aliveRow = (table, id) => db.get(`SELECT * FROM ${table} WHERE id = ? AND deleted_at IS NULL`, id);

  const crud = makeCrud({
    db,
    table: 'benefit_events',
    resource: 'benefit-events',
    singular: 'event',
    label: '打卡记录',
    idempotency: 'benefit_event.create',
    archived: false,
    sortColumn: null,
    listOrder: 'occurred_on DESC, created_at DESC',
    fields: {
      benefitId: { type: 'id', required: true },
      kind: { type: 'enum', values: perks.EVENT_KINDS, default: 'claim' },
      count: { type: 'int', min: 1, max: 999, default: 1 },
      valueCents: { type: 'int', min: 0, max: MAX_AMOUNT },
      memberId: { type: 'id' },
      note: { type: 'string', max: 200 },
    },

    fromBody(body, isPatch) {
      const given = (k) => body[k] !== undefined;
      const blank = (k) => v.isMissing(body[k]) || body[k] === '';
      const out = {};

      // 空串过了字段校验会变成 null，撞上 NOT NULL 就是 500：这里一并当「权益不存在」。
      if (given('benefitId')) {
        const benefit = blank('benefitId') ? null : aliveRow('benefits', String(body.benefitId).trim());
        if (!benefit) v.bad('benefitId', '权益不存在');
        if (benefit.kind === 'choice') v.bad('benefitId', '「N 选 1」本身不能打卡，点它下面选中的那一项');
      }
      if (!blank('memberId') && !aliveRow('members', String(body.memberId).trim())) v.bad('memberId', '成员不存在');

      // 发生在哪天：不晚于今天（还没发生的事不记）；新建不给就是今天。
      if (!isPatch) out.occurred_on = blank('occurredOn') ? v.localDay() : v.day(body.occurredOn, 'occurredOn');
      else if (given('occurredOn')) out.occurred_on = v.day(body.occurredOn, 'occurredOn');
      return out;
    },
  });

  return { name: 'benefit_events', routes: crud.routes };
};
