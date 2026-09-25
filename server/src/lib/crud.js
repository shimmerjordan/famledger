'use strict';

// The CRUD shape accounts / funds / categories / rules all share: list, create,
// patch, soft-delete, reorder. Each of those modules only declares its columns
// and the one or two things that make it special (a uniqueness rule, a
// "still in use" check), so the five routes exist exactly once in the codebase.
//
//   makeCrud({ db, table, resource, fields, ... }) → { routes, toJson, byId, … }
//
// `fields` is a map of camelCase API name → spec:
//
//   {type:'string'|'enum'|'int'|'bool'|'color'|'emoji'|'id'|'json',
//    required?, min?, max?, values?, default?, column?}
//
// `default` may be a function (evaluated per request — funds pick a palette
// colour that way). The standard columns (id / created_at / updated_at /
// deleted_at / seq, plus `archived` and `sort_order` when the table has them)
// are handled here and must NOT be declared in `fields`.
//
// Hooks, all optional:
//   fromBody(body, isPatch, row) → extra column values, merged last
//   canDelete(row, reqCtx)       → throw HttpError(409, …) to refuse a delete
//   onWrite(row, {isPatch, body, reqCtx}) → runs inside the same transaction
//   onDelete(row, reqCtx)        → runs inside the delete's transaction, right after the
//                                  row got its tombstone (cascades, unlinking references);
//                                  a throw rolls the delete back too
//
// `idempotency: '<scope>'` makes POST honour a `clientId` in the body (lib/idempotency.js):
// a create whose onWrite also books money must not run twice when the client retries
// after losing the response. A replay answers 200 with the row as it is now.

const crypto = require('node:crypto');

const { HttpError, sendJson } = require('./router');
const { rowToJson } = require('./db');
const idem = require('./idempotency');
const v = require('./validate');

const snake = (s) => s.replace(/[A-Z]/g, (c) => `_${c.toLowerCase()}`);

/** A spec's default, evaluated and cast the same way user input would be. */
function defaultFor(spec) {
  const d = typeof spec.default === 'function' ? spec.default() : spec.default;
  if (d === undefined || d === null) return null;
  if (spec.type === 'bool') return d ? 1 : 0;
  if (spec.type === 'json') return typeof d === 'string' ? d : JSON.stringify(d);
  return d;
}

/** One field's raw JSON value → the value its column stores. */
function coerce(spec, raw, name) {
  switch (spec.type) {
    case 'string':
      return spec.required
        ? v.str(raw, name, { min: spec.min, max: spec.max })
        : v.optStr(raw, name, { max: spec.max });
    case 'enum':
      return v.enumOf(raw, name, spec.values);
    case 'int':
      return spec.required
        ? v.int(raw, name, { min: spec.min, max: spec.max })
        : v.optInt(raw, name, { min: spec.min, max: spec.max });
    case 'bool':
      return v.bool(raw, name) ? 1 : 0;
    case 'color':
      return v.color(raw, name);
    case 'emoji':
      return v.emoji(raw, name, { max: spec.max });
    case 'id':
      return v.optStr(raw, name, { max: spec.max || 64 });
    case 'json': {
      if (!v.isObject(raw) && !Array.isArray(raw)) v.bad(name, `${name} 必须是 JSON 对象或数组`);
      const s = JSON.stringify(raw);
      if (s.length > (spec.max || 4000)) v.bad(name, `${name} 太大了`);
      return s;
    }
    default:
      throw new Error(`crud: 未知的字段类型 ${spec.type}`);
  }
}

function makeCrud(opts) {
  const {
    db,
    table,
    resource,
    singular = resource.replace(/s$/, ''),
    label = resource,
    fields = {},
    listOrder = 'sort_order ASC, created_at ASC',
    archived = true,
    sortColumn = 'sort_order',
    fromBody = null,
    canDelete = null,
    onWrite = null,
    onDelete = null,
    idempotency = null,
    auth = 'member',
  } = opts;

  const boolCols = [
    ...(archived ? ['archived'] : []),
    ...Object.entries(fields).filter(([, s]) => s.type === 'bool').map(([n, s]) => s.column || snake(n)),
  ];
  const jsonCols = Object.entries(fields).filter(([, s]) => s.type === 'json').map(([n, s]) => s.column || snake(n));
  const toJson = opts.toJson || ((row) => rowToJson(row, { bools: boolCols, json: jsonCols }));

  const byId = (id) => db.get(`SELECT * FROM ${table} WHERE id = ? AND deleted_at IS NULL`, id);
  const reread = (id) => db.get(`SELECT * FROM ${table} WHERE id = ?`, id);

  function mustExist(id) {
    const row = byId(id);
    if (!row) throw new HttpError(404, 'not_found', `${label}不存在`);
    return row;
  }

  /** Validate a body into `{column: value}`. Absent fields are skipped on PATCH. */
  function columnsFrom(body, isPatch, row) {
    const out = {};
    for (const [name, spec] of Object.entries(fields)) {
      const col = spec.column || snake(name);
      const raw = body[name];
      if (raw === undefined || raw === null) {
        if (isPatch && raw === undefined) continue;
        if (spec.required) v.bad(name, `${name} 不能为空`);
        // An explicit null clears a nullable column, but a column with a
        // default (and NOT NULL behind it) falls back to that default.
        out[col] = defaultFor(spec);
        continue;
      }
      const value = coerce(spec, raw, name);
      out[col] = value === null && spec.default !== undefined ? defaultFor(spec) : value;
    }
    if (archived) {
      if (body.archived !== undefined) out.archived = v.bool(body.archived, 'archived') ? 1 : 0;
      else if (!isPatch) out.archived = 0;
    }
    if (sortColumn && body.sortOrder !== undefined) {
      out[sortColumn] = v.int(body.sortOrder, 'sortOrder', { min: 0, max: 1000000 });
    }
    if (fromBody) Object.assign(out, fromBody(body, isPatch, row) || {});
    return out;
  }

  /** Append: new rows land at the end of the user's own ordering. */
  function nextSort() {
    const r = db.get(`SELECT MAX(${sortColumn}) AS m FROM ${table} WHERE deleted_at IS NULL`);
    return (r && typeof r.m === 'number' ? r.m : -1) + 1;
  }

  function list(req, res, reqCtx) {
    const withArchived = archived && (reqCtx.query.archived === '1' || reqCtx.query.archived === 'true');
    const rows = db.all(
      `SELECT * FROM ${table} WHERE deleted_at IS NULL${archived && !withArchived ? ' AND archived = 0' : ''}` +
        ` ORDER BY ${listOrder}`,
    );
    sendJson(res, 200, { items: rows.map(toJson) });
  }

  function create(req, res, reqCtx) {
    const body = v.body(reqCtx.body);
    const clientId = idempotency ? idem.clientIdOf(body) : null;
    // Checked before validation: the retry must still succeed if, say, the account it
    // named has been deleted since the first attempt went through.
    const hit = idem.lookup(db, idempotency, clientId);
    const prev = hit && reread(hit.refId);
    if (prev) return sendJson(res, 200, { [singular]: toJson(prev), replayed: true });
    const cols = columnsFrom(body, false, null);
    const row = db.tx(() => {
      if (sortColumn && cols[sortColumn] === undefined) cols[sortColumn] = nextSort();
      const now = db.now();
      const all = { id: crypto.randomUUID(), ...cols, created_at: now, updated_at: now, seq: db.nextSeq() };
      const keys = Object.keys(all);
      db.run(
        `INSERT INTO ${table}(${keys.join(', ')}) VALUES(${keys.map(() => '?').join(', ')})`,
        ...keys.map((k) => all[k]),
      );
      onWrite?.(reread(all.id), { isPatch: false, body, reqCtx });
      idem.remember(db, idempotency, clientId, all.id);
      return reread(all.id);
    });
    sendJson(res, 201, { [singular]: toJson(row) });
  }

  function patch(req, res, reqCtx) {
    const body = v.body(reqCtx.body);
    const row = mustExist(reqCtx.params.id);
    const cols = columnsFrom(body, true, row);
    const next = db.tx(() => {
      const keys = Object.keys(cols);
      db.run(
        `UPDATE ${table} SET ${[...keys.map((k) => `${k} = ?`), 'updated_at = ?', 'seq = ?'].join(', ')} WHERE id = ?`,
        ...keys.map((k) => cols[k]), db.now(), db.nextSeq(), row.id,
      );
      onWrite?.(reread(row.id), { isPatch: true, body, reqCtx });
      return reread(row.id);
    });
    sendJson(res, 200, { [singular]: toJson(next) });
  }

  /** Soft delete: the tombstone is what `GET /changes` ships to other devices. */
  function remove(req, res, reqCtx) {
    const row = mustExist(reqCtx.params.id);
    const next = db.tx(() => {
      canDelete?.(row, reqCtx);
      const now = db.now();
      db.run(`UPDATE ${table} SET deleted_at = ?, updated_at = ?, seq = ? WHERE id = ?`, now, now, db.nextSeq(), row.id);
      const gone = reread(row.id);
      onDelete?.(gone, reqCtx);
      return gone;
    });
    sendJson(res, 200, { [singular]: toJson(next) });
  }

  function reorder(req, res, reqCtx) {
    const body = v.body(reqCtx.body);
    const ids = v.list(body.ids, 'ids', { max: 1000, required: true }).map((id) => v.str(id, 'ids', { max: 64 }));
    const rows = db.tx(() => {
      const now = db.now();
      ids.forEach((id, i) => {
        if (!byId(id)) throw new HttpError(404, 'not_found', `${label} ${id} 不存在`);
        // Every row gets its own seq: two rows sharing one would let a paged
        // GET /changes stop halfway through and never come back for the rest.
        db.run(`UPDATE ${table} SET ${sortColumn} = ?, updated_at = ?, seq = ? WHERE id = ?`, i, now, db.nextSeq(), id);
      });
      return db.all(`SELECT * FROM ${table} WHERE deleted_at IS NULL ORDER BY ${listOrder}`);
    });
    sendJson(res, 200, { items: rows.map(toJson) });
  }

  const routes = [
    { method: 'GET', pattern: `/${resource}`, handler: list, auth, maxBody: 0 },
    { method: 'POST', pattern: `/${resource}`, handler: create, auth },
    { method: 'PATCH', pattern: `/${resource}/:id`, handler: patch, auth },
    { method: 'DELETE', pattern: `/${resource}/:id`, handler: remove, auth, maxBody: 0 },
  ];
  if (sortColumn) routes.push({ method: 'PUT', pattern: `/${resource}/reorder`, handler: reorder, auth });

  // Modules that add their own routes (funds/templates) reuse these.
  return { routes, toJson, byId, mustExist };
}

module.exports = { makeCrud };
