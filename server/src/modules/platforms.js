'use strict';

// 平台 = 会员挂在哪、权益去哪领（淘宝、优酷、招行信用卡……）。存活平台之间「规范化名」唯一
// （lib/perks_schema.js normalizeName），重名回 409 name_taken 并带上已有那行的 id，App 可以直接改用它。
// 删平台前查引用：还有会员挂着、或被某条权益当作领取平台时 409 platform_in_use（带引用数）；
// 要去掉一个重复的平台走「合并」：一个事务把引用全改到目标平台，被并的名字记成目标的别名。

const { HttpError, sendJson } = require('../lib/router');
const { makeCrud } = require('../lib/crud');
const idem = require('../lib/idempotency');
const v = require('../lib/validate');
const perks = require('../lib/perks_schema');

module.exports = (ctx) => {
  const { db } = ctx;

  const aliveRows = () => db.all('SELECT id, name FROM platforms WHERE deleted_at IS NULL');

  /** 挂在这个平台下的存活会员数、把它当领取平台的存活权益数（归档的也算：它们还指着它）。 */
  function usage(id) {
    const memberships = db.get('SELECT COUNT(*) AS n FROM memberships WHERE platform_id = ? AND deleted_at IS NULL', id).n;
    const benefits = db.get('SELECT COUNT(*) AS n FROM benefits WHERE claim_platform_id = ? AND deleted_at IS NULL', id).n;
    return { memberships, benefits };
  }

  const crud = makeCrud({
    db,
    table: 'platforms',
    resource: 'platforms',
    singular: 'platform',
    label: '平台',
    // 字段表和 AI 导入共用（lib/perks_schema.js）；aliases 的校验和去重在下面 fromBody。
    fields: perks.PLATFORM_FIELDS,

    /** 名字唯一、别名规整（和名字同名的别名丢掉）、链接只收 http/https。比的是合并后的样子。 */
    fromBody(body, isPatch, row) {
      const given = (k) => body[k] !== undefined;
      const out = {};
      const name = given('name') ? body.name.trim() : row.name;
      const key = perks.normalizeName(name);
      if (key === '') v.bad('name', '名称里至少要有一个字或字母');
      const clash = aliveRows().find((p) => p.id !== row?.id && perks.normalizeName(p.name) === key);
      if (clash) {
        throw new HttpError(409, 'name_taken', `已经有叫「${clash.name}」的平台了`, { id: clash.id, name: clash.name });
      }
      if (given('aliases') || given('name')) {
        const raw = given('aliases') ? (body.aliases ?? []) : perks.asList(row?.aliases);
        const aliases = perks.aliasesOf(raw).filter((a) => perks.normalizeName(a) !== key);
        out.aliases = JSON.stringify(aliases);
      }
      if (given('url')) out.url = perks.httpUrl(body.url, 'url');
      return out;
    },

    canDelete(row) {
      const used = usage(row.id);
      if (used.memberships > 0 || used.benefits > 0) {
        const parts = [];
        if (used.memberships > 0) parts.push(`${used.memberships} 张会员卡挂在它下面`);
        if (used.benefits > 0) parts.push(`${used.benefits} 项权益要去它那领`);
        throw new HttpError(409, 'platform_in_use', `还有 ${parts.join('、')}，不能删；可以归档，或并入别的平台`, used);
      }
    },
  });

  /**
   * 合并后目标平台的别名：目标原有的在前，再追加被并平台的名字和它的别名；按规范化名去重（和目标名字同名的
   * 丢掉），每个要守 PATCH 的规矩（≤30 字，不然目标以后连改名都存不下），最多 20 个。
   * 被并平台的名字一定要留下（spec §5：以后导入认得出旧名）：放不下时挤掉目标原有的最后一个别名。
   * 名字本身超过 30 字的（平台名最长 40）当不了别名，只好不记。
   */
  function mergedAliases(target, source) {
    const seen = new Set([perks.normalizeName(target.name)]);
    const take = (list) => {
      const out = [];
      for (const a of list) {
        if (typeof a !== 'string') continue;
        const s = a.trim();
        const key = perks.normalizeName(s);
        if (key === '' || s.length > 30 || seen.has(key)) continue;
        seen.add(key);
        out.push(s);
      }
      return out;
    };
    const kept = take(perks.asList(target.aliases));
    const [name] = take([source.name]);
    const extra = take(perks.asList(source.aliases));
    const max = perks.MAX_ALIASES;
    if (name && kept.length >= max) return [...kept.slice(0, max - 1), name];
    return [...kept, ...(name ? [name] : []), ...extra].slice(0, max);
  }

  /**
   * `POST /platforms/:id/merge {targetId, clientId?}`：把 :id 并入 targetId。一个事务里：
   * 会员的 platform_id、权益的 claim_platform_id 全改到目标（每行拿新的 seq），被并平台的名字和别名
   * 追加进目标的别名（规则见 mergedAliases），最后软删被并平台。
   * 回应 `{platform: 目标, moved: {memberships, benefits}}`；带 clientId 时重发只回第一次的结果。
   */
  function merge(req, res, reqCtx) {
    const body = v.body(reqCtx.body);
    const clientId = idem.clientIdOf(body);
    const hit = idem.lookup(db, 'platform.merge', clientId);
    if (hit && hit.response) return sendJson(res, 200, { ...hit.response, replayed: true });
    const source = crud.mustExist(reqCtx.params.id);
    const targetId = v.str(body.targetId, 'targetId', { max: 64 });
    if (targetId === source.id) v.bad('targetId', '不能并入自己');
    const target = crud.byId(targetId);
    if (!target) v.bad('targetId', '目标平台不存在');

    const out = db.tx(() => {
      const now = db.now();
      const moved = { memberships: 0, benefits: 0 };
      for (const m of db.all('SELECT id FROM memberships WHERE platform_id = ? AND deleted_at IS NULL', source.id)) {
        db.run('UPDATE memberships SET platform_id = ?, updated_at = ?, seq = ? WHERE id = ?', target.id, now, db.nextSeq(), m.id);
        moved.memberships++;
      }
      for (const b of db.all('SELECT id FROM benefits WHERE claim_platform_id = ? AND deleted_at IS NULL', source.id)) {
        db.run('UPDATE benefits SET claim_platform_id = ?, updated_at = ?, seq = ? WHERE id = ?', target.id, now, db.nextSeq(), b.id);
        moved.benefits++;
      }
      db.run(
        'UPDATE platforms SET aliases = ?, updated_at = ?, seq = ? WHERE id = ?',
        JSON.stringify(mergedAliases(target, source)), now, db.nextSeq(), target.id,
      );
      db.run('UPDATE platforms SET deleted_at = ?, updated_at = ?, seq = ? WHERE id = ?', now, now, db.nextSeq(), source.id);
      const response = { platform: crud.toJson(crud.byId(target.id)), moved };
      idem.remember(db, 'platform.merge', clientId, target.id, response);
      return response;
    });
    sendJson(res, 200, out);
  }

  return {
    name: 'platforms',
    routes: [...crud.routes, { method: 'POST', pattern: '/platforms/:id/merge', handler: merge }],
  };
};
