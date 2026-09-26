'use strict';

// AI 导入的整批撤销（spec §4 `POST /asset-import/:id/undo`）。读 apply 记在 ai_imports.undo 里的东西：
//
//   {created:[{table, id}], updated:[{table, id, seq, before:{列:旧值}}], aliases:[{platformId, alias}], transactions:[id]}
//
// 在一个 db.tx 里按下面几步走，每改一行都拿新的 seq（别的设备靠 /changes 拿到墓碑和恢复后的值）：
//   1. 更新过的行（会员、权益）：同一行可能被写过几次（「N 选 1」的父权益改 flow 时选项跟着改），按行合并 ——
//      每列取最早那次记下的旧值，比的是最后那次写完的 seq。seq 没变 → 恢复这些列；变了（导入后有人改过或删过）→
//      不动，记进 skippedChanged（deleted 标出是被删了还是被改了）。恢复的领取平台已经不在了就写 null。
//      平台只会因为追加别名被改，走第 3 步。两条结构规则（lib/perks_schema.js benefitParentRules）不能被撤坏：
//        · 导入把已有权益改成了「N 选 1」、下面又有导入之外的存活选项（导入后手动加的）→ 这一行整行不恢复
//          （改回去那些选项就挂在了非「N 选 1」下面，之后改都改不了），记进 skippedInUse，reason choice_in_use；
//        · 选项的 flow 跟着父权益走：选项行不单独恢复 flow，最后一步按父权益现在的 flow 统一（父权益被跳过、
//          选项被恢复，或者反过来，都不会对不上）。
//   2. 新建的行：按 物品 → 权益（选项在前）→ 会员 → 平台 软删。导入之后被改过的照样删（这一行本来就是这次导入的），
//      但还被导入之外的存活数据用着的留下，记进 skippedInUse（reason）：
//        sold          物品卖出时记过一笔还算数的收入（物品连同随它新建的那笔支出都留着）
//        has_options   权益下面还有存活的选项（导入后手动加的）
//        has_benefits  会员下面还有存活的权益（导入后手动加的）
//        in_use        平台下面还挂着存活的会员，或者被存活的权益当作领取平台
//      权益的打卡事件跟着软删、指向它的派生会员解开（benefits.js 的 removeBenefits，和级联删除同一套）；早就删掉的行跳过。
//   3. 追加的别名：平台还在、别名还在就拿掉这一个（不看 seq：导入后别人改了平台的别的字段，也只拿掉这个别名）。
//   4. 随物品新建的流水：物品删掉了（或者早被删了）就一并软删；物品因为卖出留着的，那笔也留着。
//      物品关联的旧流水（linkTransactionId）不在 transactions 里，永远不动。
//   5. 这批涉及的「N 选 1」：存活选项的 flow 统一成父权益现在的 flow（和 CRUD 改父权益时的 onWrite 一样）。
//
//   undoImport({db, ctx, importRow, reqCtx}) → {importId, undone:{platforms, memberships, benefits, items, transactions, events},
//     restored:{memberships, benefits}, aliasesRemoved, skippedChanged:[{table, id, name, deleted}],
//     skippedInUse:[{table, id, name, reason}]}
//   ai_imports 那行改成 undone、写 undone_at，summary.undone 存这份结果（重放时原样回）。

const perks = require('./perks_schema');
const { logActivity } = require('./activity');

const RESTORABLE = ['memberships', 'benefits'];
const COLUMN = /^[a-z_]+$/;

function parseJson(raw, dflt) {
  try {
    const v = JSON.parse(raw || '');
    return v && typeof v === 'object' ? v : dflt;
  } catch {
    return dflt;
  }
}

function undoImport({ db, ctx, importRow, reqCtx }) {
  const plan = parseJson(importRow.undo, {});
  const created = Array.isArray(plan.created) ? plan.created.filter((c) => c && typeof c.id === 'string') : [];
  const updated = Array.isArray(plan.updated) ? plan.updated.filter((u) => u && typeof u.id === 'string') : [];
  const aliases = Array.isArray(plan.aliases) ? plan.aliases.filter((a) => a && typeof a.platformId === 'string') : [];
  const txIds = Array.isArray(plan.transactions) ? plan.transactions.filter((id) => typeof id === 'string') : [];
  const out = {
    importId: importRow.id,
    undone: { platforms: 0, memberships: 0, benefits: 0, items: 0, transactions: 0, events: 0 },
    restored: { memberships: 0, benefits: 0 },
    aliasesRemoved: 0,
    skippedChanged: [],
    skippedInUse: [],
  };

  return db.tx(() => {
    const now = db.now();
    const alive = (table, id) => db.get(`SELECT * FROM ${table} WHERE id = ? AND deleted_at IS NULL`, id);
    const count = (sql, ...args) => db.get(sql, ...args).n;
    const bury = (table, id) => db.run(`UPDATE ${table} SET deleted_at = ?, updated_at = ?, seq = ? WHERE id = ?`, now, now, db.nextSeq(), id);
    const createdOf = (table) => created.filter((c) => c.table === table).map((c) => c.id);

    // 1. 更新过的行：按行合并，seq 没变才恢复。
    const createdIds = new Set(created.map((c) => c.id));
    const merged = new Map();
    for (const u of updated) {
      if (!RESTORABLE.includes(u.table)) continue;
      const key = `${u.table}:${u.id}`;
      const m = merged.get(key) || { table: u.table, id: u.id, seq: null, before: {} };
      for (const [k, val] of Object.entries(u.before || {})) if (COLUMN.test(k) && !(k in m.before)) m.before[k] = val;
      m.seq = u.seq; // undo.updated 按 apply 写的先后排：最后一次的 seq 就是导入完那一刻的
      merged.set(key, m);
    }
    const choiceParents = new Set(); // 第 5 步要统一选项 flow 的「N 选 1」
    for (const m of merged.values()) {
      const cur = db.get(`SELECT * FROM ${m.table} WHERE id = ?`, m.id);
      if (cur && m.table === 'benefits') {
        if (cur.kind === 'choice') choiceParents.add(cur.id);
        if (cur.parent_id) choiceParents.add(cur.parent_id);
      }
      if (!cur || cur.deleted_at || cur.seq !== m.seq) {
        out.skippedChanged.push({ table: m.table, id: m.id, name: cur ? cur.name : null, deleted: !cur || !!cur.deleted_at });
        continue;
      }
      const cols = { ...m.before };
      if (m.table === 'benefits') {
        if ('kind' in cols && cols.kind !== 'choice' && cur.kind === 'choice') {
          const foreign = db
            .all('SELECT id FROM benefits WHERE parent_id = ? AND deleted_at IS NULL', cur.id)
            .filter((o) => !createdIds.has(o.id));
          if (foreign.length) {
            out.skippedInUse.push({ table: 'benefits', id: cur.id, name: cur.name, reason: 'choice_in_use' });
            continue;
          }
        }
        if (cur.parent_id) delete cols.flow; // 选项的 flow 第 5 步跟着父权益统一
      }
      if (cols.claim_platform_id && !alive('platforms', cols.claim_platform_id)) cols.claim_platform_id = null;
      const names = Object.keys(cols);
      if (!names.length) continue;
      db.run(
        `UPDATE ${m.table} SET ${[...names.map((k) => `${k} = ?`), 'updated_at = ?', 'seq = ?'].join(', ')} WHERE id = ?`,
        ...names.map((k) => cols[k]), now, db.nextSeq(), m.id,
      );
      out.restored[m.table]++;
    }

    // 2. 新建的行：物品 → 权益（选项在前）→ 会员 → 平台。
    const keptTx = new Set();
    for (const id of createdOf('assets')) {
      const a = alive('assets', id);
      if (!a) continue;
      const sold = a.sale_transaction_id && db.get(
        "SELECT 1 AS ok FROM transactions WHERE id = ? AND deleted_at IS NULL AND status NOT IN ('duplicate', 'void')",
        a.sale_transaction_id,
      );
      if (sold) {
        out.skippedInUse.push({ table: 'assets', id, name: a.name, reason: 'sold' });
        if (a.transaction_id) keptTx.add(a.transaction_id);
        continue;
      }
      bury('assets', id);
      out.undone.items++;
    }
    const benefits = createdOf('benefits').map((id) => alive('benefits', id)).filter(Boolean);
    benefits.sort((a, b) => (b.parent_id ? 1 : 0) - (a.parent_id ? 1 : 0));
    for (const b of benefits) {
      if (count('SELECT COUNT(*) AS n FROM benefits WHERE parent_id = ? AND deleted_at IS NULL', b.id) > 0) {
        out.skippedInUse.push({ table: 'benefits', id: b.id, name: b.name, reason: 'has_options' });
        continue;
      }
      out.undone.events += count('SELECT COUNT(*) AS n FROM benefit_events WHERE benefit_id = ? AND deleted_at IS NULL', b.id);
      ctx.perks.removeBenefits([b.id], now);
      out.undone.benefits++;
    }
    for (const id of createdOf('memberships')) {
      const m = alive('memberships', id);
      if (!m) continue;
      if (count('SELECT COUNT(*) AS n FROM benefits WHERE membership_id = ? AND deleted_at IS NULL', id) > 0) {
        out.skippedInUse.push({ table: 'memberships', id, name: m.name, reason: 'has_benefits' });
        continue;
      }
      bury('memberships', id);
      out.undone.memberships++;
    }
    for (const id of createdOf('platforms')) {
      const p = alive('platforms', id);
      if (!p) continue;
      const used = count('SELECT COUNT(*) AS n FROM memberships WHERE platform_id = ? AND deleted_at IS NULL', id) +
        count('SELECT COUNT(*) AS n FROM benefits WHERE claim_platform_id = ? AND deleted_at IS NULL', id);
      if (used > 0) {
        out.skippedInUse.push({ table: 'platforms', id, name: p.name, reason: 'in_use' });
        continue;
      }
      bury('platforms', id);
      out.undone.platforms++;
    }

    // 3. 追加的别名：只拿掉这一个。
    for (const a of aliases) {
      const p = alive('platforms', a.platformId);
      if (!p) continue;
      const list = perks.asList(p.aliases);
      const next = list.filter((x) => x !== a.alias);
      if (next.length === list.length) continue;
      db.run('UPDATE platforms SET aliases = ?, updated_at = ?, seq = ? WHERE id = ?', JSON.stringify(next), now, db.nextSeq(), p.id);
      out.aliasesRemoved++;
    }

    // 4. 随物品新建的流水。
    for (const id of txIds) {
      if (keptTx.has(id) || !alive('transactions', id)) continue;
      bury('transactions', id);
      out.undone.transactions++;
    }

    // 5. 选项的 flow 跟着父权益（父权益恢复了、被跳过了都一样按它现在的值）。
    for (const pid of choiceParents) {
      const parent = alive('benefits', pid);
      if (!parent || parent.kind !== 'choice') continue;
      for (const o of db.all('SELECT id FROM benefits WHERE parent_id = ? AND deleted_at IS NULL AND flow != ?', pid, parent.flow)) {
        db.run('UPDATE benefits SET flow = ?, updated_at = ?, seq = ? WHERE id = ?', parent.flow, now, db.nextSeq(), o.id);
      }
    }

    const summary = { ...parseJson(importRow.summary, {}), undone: out };
    db.run("UPDATE ai_imports SET status = 'undone', undone_at = ?, summary = ? WHERE id = ?", now, JSON.stringify(summary), importRow.id);
    logActivity(db, { memberId: reqCtx.member.id, action: 'undo', entity: 'asset_import', entityId: importRow.id, at: now });
    return out;
  });
}

module.exports = { undoImport };
