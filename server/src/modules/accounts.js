'use strict';

// 账户 = 钱实际待着的地方（现金、储蓄卡、支付宝…）。余额不存在这张表里：
// 它永远是 initialBalanceCents + Σ流水，由 stats 现算。「校准余额」= PATCH currentBalanceCents
// （现在实际有多少），差额进 initialBalanceCents，不多记流水。
//
// 股票账户（kind = 'stock'）不挂持仓，整户记一个「当前市值」：余额（期初 + 流水）= 投入的本金，
// value_cents = 照券商 App 填的市值（空 = 还没填过，按投入算），value_on = 哪天的数，value_log = 历次市值
// （老的在前、同一天覆盖、最多 VALUE_LOG_MAX 条）。浮盈 = 市值 − 余额，由 stats.js 算。
// 逐只记的老持仓用 POST /accounts/:id/absorb 并进来：成本挂在活的账户里的记一笔「移仓」转账，
// 没挂账户的直接加进期初，然后把持仓归档。

const { HttpError, sendJson } = require('../lib/router');
const { makeCrud, currencyColumns, requireSameCurrency } = require('../lib/crud');
const { rowToJson } = require('../lib/db');
const { logActivity } = require('../lib/activity');
const idem = require('../lib/idempotency');
const sql = require('../lib/stats_sql');
const v = require('../lib/validate');

const KINDS = ['cash', 'bank', 'alipay', 'wechat', 'credit', 'invest', 'stock', 'other'];
const MAX_AMOUNT = 1e14;
const VALUE_LOG_MAX = 200;
const ABSORB_MAX = 200;

// 契约规定流水时间一律带 +08:00；取中午是为了日期在任何一侧偏移下都不会滑到前后一天。
const noonOf = (date) => `${date}T12:00:00+08:00`;

const txJson = (row) => rowToJson(row, { json: ['tags'], bools: ['off_balance'] });
// 和 holdings.js 的 crud.toJson 同一个形状。
const holdingJson = (row) => rowToJson(row, { bools: ['archived'] });

/** 历次市值里追加一条：同一天覆盖，按日期排（老的在前），只留最近 VALUE_LOG_MAX 条。 */
function appendValueLog(raw, entry) {
  let log = [];
  try {
    log = JSON.parse(raw || '[]');
  } catch (_) {
    log = [];
  }
  if (!Array.isArray(log)) log = [];
  log = log.filter((e) => e && typeof e === 'object' && e.on !== entry.on);
  log.push(entry);
  log.sort((a, b) => (a.on < b.on ? -1 : a.on > b.on ? 1 : 0));
  return JSON.stringify(log.slice(-VALUE_LOG_MAX));
}

/** 记录里最新那天的市值（appendValueLog 已按日期排好、至少一条）：补记以前的日子不能把「当前市值」改成旧数。 */
function latestValue(raw) {
  const log = JSON.parse(raw);
  return log[log.length - 1];
}

module.exports = (ctx) => {
  const { db } = ctx;

  const toJson = (row) => rowToJson(row, { bools: ['archived'], json: ['match_hints', 'value_log'] });

  /** 市值是哪天的：默认今天，补记以前的也行（不能是将来）。 */
  const valueDay = (raw) => (v.isMissing(raw) ? v.localDay() : v.day(raw, 'valueOn'));

  /** 走 transactions.js 的同一套校验与写入；它按字母序后加载，所以只能在请求时取。 */
  function record(body, reqCtx) {
    return ctx.createTransaction({ source: 'manual', ...body }, reqCtx).row;
  }

  const labelOf = (h) => h.name || h.code || '持仓';

  const crud = makeCrud({
    db,
    table: 'accounts',
    resource: 'accounts',
    singular: 'account',
    label: '账户',
    fields: {
      name: { type: 'string', required: true, max: 40 },
      kind: { type: 'enum', values: KINDS, default: 'other' },
      ownerMemberId: { type: 'id' },
      initialBalanceCents: { type: 'int', min: -1e14, max: 1e14, default: 0 },
      icon: { type: 'string', max: 40 },
      color: { type: 'color' },
      matchHints: { type: 'json', max: 2000, default: '{}' },
    },
    // value_log 不在 fields 里（它不是客户端直接写的列），所以 JSON 列要在这里点名。
    toJson,

    // `currency` is not a plain field: a new account inherits the household's
    // currency rather than the column default, and it is always upper-cased.
    // 币种建好后有了流水就锁定：旧流水记的是旧币种，改了余额就是两种钱混着加。
    fromBody(body, isPatch, row) {
      const out = currencyColumns(db, body, isPatch);
      // 债务的内部账户：余额就是「还剩多少」，到债务里改（会留一行备忘）；类型改了它就成了普通账户。
      if (isPatch && row.kind === 'debt') {
        for (const f of ['initialBalanceCents', 'currentBalanceCents', 'valueCents', 'valueOn']) {
          if (body[f] !== undefined) v.bad(f, '这是债务的账户：还剩多少到「资产 › 债务」里改');
        }
        if (body.kind !== undefined) v.bad('kind', '这是债务的账户，不能改类型');
      }
      if (!v.isMissing(body.currentBalanceCents)) {
        const target = v.int(body.currentBalanceCents, 'currentBalanceCents', { min: -1e14, max: 1e14 });
        const flows = row ? sql.deltaMap(db, 'account', row.id).get(row.id) || 0 : 0;
        if (Math.abs(target - flows) > 1e14) v.bad('currentBalanceCents', '差得太多了');
        out.initial_balance_cents = target - flows;
      }
      if (isPatch && out.currency && out.currency !== row.currency) {
        if (row.kind === 'debt') v.bad('currency', '债务的内部账户跟着债务走，不能单独改币种');
        const used = db.get(
          'SELECT 1 AS ok FROM transactions WHERE deleted_at IS NULL AND (account_id = ? OR to_account_id = ?) LIMIT 1',
          row.id, row.id,
        );
        if (used) {
          throw new HttpError(409, 'currency_locked', '这个账户已经有流水了，不能改币种；换币种请新建一个账户');
        }
      }

      // 市值只有股票账户记，看的是「旧行 + 本次」合并后的类型（kind 已经过 fields 的枚举校验，
      // 传 null 和没传一样落到默认的 other）。
      const kind = body.kind === undefined ? (isPatch ? row.kind : 'other') : (body.kind ?? 'other');
      // 投资账户下还挂着（没归档的）持仓时不能改成别的类型：持仓按「挂了账户」补浮盈，改成股票账户后整户市值
      // 又补一次，同一只股票就算两遍；先「合并到股票账户」或把持仓换到别的账户。
      if (isPatch && row.kind === 'invest' && kind !== 'invest') {
        const held = db.get(
          'SELECT 1 AS ok FROM holdings WHERE account_id = ? AND archived = 0 AND deleted_at IS NULL LIMIT 1', row.id,
        );
        if (held) throw new HttpError(409, 'holdings_attached', '这个账户下还挂着持仓：先把它们合并到股票账户、或换到别的账户，再改类型');
      }
      if (kind === 'stock') {
        if (!v.isMissing(body.valueCents)) {
          out.value_cents = v.int(body.valueCents, 'valueCents', { min: 0, max: MAX_AMOUNT });
          out.value_on = valueDay(body.valueOn);
          out.value_log = appendValueLog(row ? row.value_log : '[]', { on: out.value_on, valueCents: out.value_cents });
          ({ on: out.value_on, valueCents: out.value_cents } = latestValue(out.value_log));
        } else if (body.valueCents === null) {
          // 清掉市值：回到按投入算；历次记录留着。
          out.value_cents = null;
          out.value_on = null;
        } else if (!v.isMissing(body.valueOn)) {
          v.bad('valueOn', '市值日期要和市值一起给');
        }
      } else {
        if (!v.isMissing(body.valueCents) || !v.isMissing(body.valueOn)) v.bad('valueCents', '只有股票账户记市值');
        // 从股票账户改成别的类型：市值没意义了，清掉（历次记录留着，改回来还能看）。
        if (isPatch && row.kind === 'stock') {
          out.value_cents = null;
          out.value_on = null;
        }
      }
      return out;
    },

    canDelete(row) {
      // 债务的内部账户（modules/debts.js）跟着债务删，从这里删掉债务就没了余额。
      if (row.kind === 'debt') {
        throw new HttpError(409, 'account_is_debt', '这是一笔债务的账户，到「资产 › 债务」里删');
      }
      const used = db.get(
        "SELECT 1 AS ok FROM transactions WHERE deleted_at IS NULL AND status = 'confirmed'" +
          ' AND (account_id = ? OR to_account_id = ?) LIMIT 1',
        row.id, row.id,
      );
      if (used) {
        throw new HttpError(409, 'account_in_use', '该账户下已有流水，不能删除；可以改成「归档」');
      }
    },
  });

  /**
   * 把逐只记的持仓并进一个股票账户，一个事务：成本挂在活的账户里的（holdings.js 守着「成本已在那个账户的余额里」）
   * 记一笔「移仓」转账到股票账户；没挂账户或挂的账户已删的，成本以前不在任何余额里，直接加进股票账户期初。
   * 然后持仓归档，份额、成本、已实现盈亏原样留着。给了 valueCents 就按 PATCH 同样的规则顺手把市值写上。
   * clientId 幂等（scope account.absorb）：回应丢了 App 重发，转账不能记两遍。
   */
  function absorb(req, res, reqCtx) {
    const b = v.body(reqCtx.body);
    const ids = [...new Set(
      v.list(b.holdingIds, 'holdingIds', { max: ABSORB_MAX, required: true }).map((id) => v.str(id, 'holdingIds', { max: 64 })),
    )];
    if (ids.length === 0) v.bad('holdingIds', '至少选一只持仓');
    const value = v.isMissing(b.valueCents) ? null : v.int(b.valueCents, 'valueCents', { min: 0, max: MAX_AMOUNT });
    if (value === null && !v.isMissing(b.valueOn)) v.bad('valueOn', '市值日期要和市值一起给');
    const valueOn = value === null ? null : valueDay(b.valueOn);
    const clientId = idem.clientIdOf(b);

    const hit = idem.lookup(db, 'account.absorb', clientId);
    if (hit) {
      if (hit.refId !== reqCtx.params.id) {
        throw new HttpError(409, 'client_id_reused', '这个 clientId 已经用在另一个账户上了');
      }
      return sendJson(res, 200, { ...hit.response, replayed: true });
    }

    const out = db.tx(() => {
      const account = crud.byId(reqCtx.params.id);
      if (!account) throw new HttpError(400, 'invalid_accountId', '账户不存在');
      if (account.kind !== 'stock') throw new HttpError(400, 'invalid_accountId', '只能并进股票账户');

      const holdings = ids.map((id) => {
        const h = db.get('SELECT * FROM holdings WHERE id = ? AND deleted_at IS NULL', id);
        if (!h) v.bad('holdingIds', `持仓 ${id} 不存在`);
        if (h.archived) v.bad('holdingIds', `「${labelOf(h)}」已经归档了`);
        requireSameCurrency(db, account.id, h.currency, 'holdingIds', `「${labelOf(h)}」`);
        return h;
      });

      const today = v.localDay();
      const txs = [];
      let intoInitial = 0;
      for (const h of holdings) {
        const cost = Number(h.cost_cents) || 0;
        const linked = h.account_id && db.get('SELECT id FROM accounts WHERE id = ? AND deleted_at IS NULL', h.account_id);
        if (cost > 0 && linked && linked.id !== account.id) {
          txs.push(record({
            type: 'transfer', amountCents: cost, occurredAt: noonOf(today),
            accountId: linked.id, toAccountId: account.id, merchant: `移仓 ${labelOf(h)}`,
          }, reqCtx));
        } else if (cost > 0 && !linked) {
          intoInitial += cost;
        }
        db.run('UPDATE holdings SET archived = 1, updated_at = ?, seq = ? WHERE id = ?', db.now(), db.nextSeq(), h.id);
      }
      const initial = (Number(account.initial_balance_cents) || 0) + intoInitial;
      if (initial > MAX_AMOUNT) v.bad('holdingIds', '并进去的成本太大了');

      const sets = ['initial_balance_cents = ?', 'updated_at = ?', 'seq = ?'];
      const args = [initial, db.now(), db.nextSeq()];
      if (value !== null) {
        const log = appendValueLog(account.value_log, { on: valueOn, valueCents: value });
        const latest = latestValue(log);
        sets.push('value_cents = ?', 'value_on = ?', 'value_log = ?');
        args.push(latest.valueCents, latest.on, log);
      }
      db.run(`UPDATE accounts SET ${sets.join(', ')} WHERE id = ?`, ...args, account.id);
      logActivity(db, { memberId: reqCtx.member.id, action: 'absorb', entity: 'account', entityId: account.id });

      const response = {
        account: toJson(db.get('SELECT * FROM accounts WHERE id = ?', account.id)),
        holdings: ids.map((id) => holdingJson(db.get('SELECT * FROM holdings WHERE id = ?', id))),
        transactions: txs.map(txJson),
      };
      idem.remember(db, 'account.absorb', clientId, account.id, response);
      return response;
    });
    sendJson(res, 200, out);
  }

  return {
    name: 'accounts',
    routes: [
      ...crud.routes,
      { method: 'POST', pattern: '/accounts/:id/absorb', handler: absorb },
    ],
  };
};
