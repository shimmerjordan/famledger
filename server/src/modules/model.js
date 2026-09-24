'use strict';

// The family-shared naive-bayes counts (spec §4.1 `model`, §6 自动记账管线).
//
// Two models live in the `model` table, one row each:
//   key='category' → label = a `categories.id`
//   key='fund'     → label = a `funds.id`
// Every device pulls the whole thing with `GET /model`, classifies offline, and
// pushes back only the corrections a human made (`POST /model/learn`). The
// server folds those into the shared counts and bumps `version`, which is how a
// device knows its copy is stale. Counts are additive, so no device ever has to
// win a merge — this is the one piece of state where last-writer-wins is wrong.
//
// The table has no `seq`/`deleted_at`: the model is derived data, not a
// syncable row, and `DELETE /model` rebuilds it from the seed on the next read.

const { HttpError, sendJson } = require('../lib/router');
const v = require('../lib/validate');
const nb = require('../lib/nb');
const { NB_SEED } = require('./seed');

const KEYS = ['category', 'fund'];
const MAX_SAMPLES = 500;
const MAX_TEXT = 500;
const DIRECTIONS = ['expense', 'income', 'transfer', 'unknown'];

// `meta` key holding the household-wide, monotonically increasing model
// version. Per-model `version` is the value this counter had when that model
// last changed; the top-level `version` of GET /model is the counter itself.
// It must never go backwards — a device that cached 7 would otherwise stop
// refreshing after a reset handed out 1 again.
const VERSION_KEY = 'model_version';

// Hard ceilings. Labels are validated against real rows so the class count is
// bounded by the household anyway; these stop a pathological batch from
// persisting a model nobody can download.
const MAX_CLASSES = 200;
const MAX_VOCAB = 200000;

// A label is a row id; `memberId` never becomes one, but it does become a token.
const SAFE_ID_RE = /^[A-Za-z0-9_-]+$/;
const RESERVED_IDS = new Set(['__proto__', 'constructor', 'prototype']);

// 500 samples × 500 chars of Chinese is ~0.8 MB — the router's 64 KB default
// would reject a perfectly legal batch.
const MAX_BODY = 2 * 1024 * 1024;

module.exports = (ctx) => {
  const { db, log } = ctx;

  /**
   * Category ids by name, expense winning a tie — '其他' exists as both an
   * expense and an income category, and the seed samples are all expenses.
   */
  function categoryIdsByName() {
    const rows = db.all(
      'SELECT id, name FROM categories WHERE deleted_at IS NULL' +
        " ORDER BY CASE kind WHEN 'expense' THEN 0 ELSE 1 END, sort_order, id",
    );
    const byName = new Map();
    for (const r of rows) if (!byName.has(r.name)) byName.set(r.name, r.id);
    return byName;
  }

  /**
   * Train the built-in samples against this household's own category ids.
   * Seed documents carry text tokens only: a seed sample has no direction,
   * channel or hour, so those features start at zero weight and gain it purely
   * from real corrections. The Dart client seeds itself the same way.
   */
  function buildSeedModel(version) {
    const byName = categoryIdsByName();
    const model = nb.emptyModel(version);
    const union = new Set(); // one shared vocabulary for the whole 214-doc build
    for (const s of NB_SEED) {
      const id = byName.get(s.category);
      if (id) nb.learn(model, nb.tokenize(s.text), id, union); // a renamed/deleted category is simply skipped
    }
    return model;
  }

  /** The household-wide counter. Absent on a fresh database → 1. */
  function globalVersion() {
    const n = Number.parseInt(db.meta(VERSION_KEY, '1'), 10);
    return Number.isSafeInteger(n) && n >= 1 ? n : 1;
  }

  /** Advance the counter and return the new value. Call inside a transaction. */
  function bumpVersion() {
    const next = globalVersion() + 1;
    db.setMeta(VERSION_KEY, next);
    return next;
  }

  function save(key, model) {
    db.run(
      'INSERT INTO model(key, json, version, updated_at) VALUES(?, ?, ?, ?)' +
        ' ON CONFLICT(key) DO UPDATE SET json = excluded.json, version = excluded.version, updated_at = excluded.updated_at',
      key, JSON.stringify(model), model.version, db.now(),
    );
  }

  /**
   * Both models, creating and persisting them on first use. Runs in one
   * transaction so two concurrent readers cannot each train their own seed.
   * @returns {{category: object, fund: object}}
   */
  function ensure() {
    return db.tx(() => {
      const out = {};
      const now = globalVersion();
      for (const key of KEYS) {
        const row = db.get('SELECT json, version FROM model WHERE key = ?', key);
        if (row) {
          const model = nb.parse(row.json);
          model.version = Number(row.version) || model.version; // the column is authoritative
          out[key] = model;
        } else {
          // A rebuild after a reset takes the *current* counter, so the version
          // a device sees only ever goes up.
          out[key] = key === 'category' ? buildSeedModel(now) : nb.emptyModel(now);
          save(key, out[key]);
        }
      }
      return out;
    });
  }

  /**
   * Labels are written straight into the model as object keys and are handed to
   * every device, so they must be ids this household actually owns — not an
   * arbitrary string, and certainly not `__proto__`. Memoised: a 500-sample
   * batch usually references a handful of distinct ids.
   */
  function refChecker() {
    const memo = new Map();
    const SQL = {
      category: 'SELECT 1 AS ok FROM categories WHERE id = ? AND deleted_at IS NULL',
      fund: 'SELECT 1 AS ok FROM funds WHERE id = ? AND deleted_at IS NULL',
    };
    return (kind, id) => {
      const k = `${kind}\u0000${id}`;
      if (!memo.has(k)) memo.set(k, !!db.get(SQL[kind], id));
      return memo.get(k);
    };
  }

  function takeRef(value, field, kind, exists) {
    const id = v.optStr(value, field, { max: 64 });
    if (id === null) return null;
    if (!exists(kind, id)) v.bad(field, `${field} 指向的${kind === 'category' ? '类别' : '基金'}不存在`);
    return id;
  }

  /** Only ever a token (`mem:<id>`), but still never a prototype key. */
  function takeMemberId(value) {
    const id = v.optStr(value, 'memberId', { max: 64 });
    if (id === null) return null;
    if (RESERVED_IDS.has(id) || !SAFE_ID_RE.test(id)) v.bad('memberId', 'memberId 只能是字母、数字、下划线与连字符');
    return id;
  }

  /** Validate one sample and turn it into the token list it trains on. */
  function prepare(raw, exists) {
    if (!v.isObject(raw)) throw new HttpError(400, 'invalid_sample', '每条样本必须是对象');
    const text = v.optStr(raw.text, 'text', { max: MAX_TEXT }) || '';
    const fields = {
      merchant: v.optStr(raw.merchant, 'merchant', { max: 100 }),
      direction: v.isMissing(raw.direction) ? null : v.enumOf(raw.direction, 'direction', DIRECTIONS),
      channel: v.optStr(raw.channel, 'channel', { max: 32 }),
      amountCents: v.isMissing(raw.amountCents) ? null : v.int(raw.amountCents, 'amountCents', { min: 0 }),
      hour: v.optInt(raw.hour, 'hour', { min: 0, max: 23 }),
      // famledger's Dart client sends DateTime.weekday (1=Mon … 7=Sun); 0 is
      // accepted for a client that uses the JS convention. Never reinterpreted.
      weekday: v.optInt(raw.weekday, 'weekday', { min: 0, max: 7 }),
      memberId: takeMemberId(raw.memberId),
    };
    return {
      tokens: nb.tokenize(text, nb.extrasFor(fields)),
      categoryId: takeRef(raw.categoryId, 'categoryId', 'category', exists),
      fundId: takeRef(raw.fundId, 'fundId', 'fund', exists),
    };
  }

  /** Refuse to persist a model no device could reasonably download. */
  function assertWithinCaps(key, model) {
    const classes = Object.keys(model.classes).length;
    if (classes > MAX_CLASSES || model.vocab > MAX_VOCAB) {
      throw new HttpError(
        400,
        'model_too_large',
        `${key} 模型超出上限（类别 ${classes}/${MAX_CLASSES}，词表 ${model.vocab}/${MAX_VOCAB}）`,
      );
    }
  }

  // ── routes ────────────────────────────────────────────────────────────

  function read(req, res) {
    const m = ensure();
    sendJson(res, 200, { version: globalVersion(), category: m.category, fund: m.fund });
  }

  function learn(req, res, reqCtx) {
    const b = v.body(reqCtx.body);
    // Validate the whole batch before writing anything: a bad sample at index
    // 400 must not leave the first 399 folded in.
    const exists = refChecker();
    const samples = v.list(b.samples, 'samples', { max: MAX_SAMPLES }).map((raw, i) => {
      try {
        return prepare(raw, exists);
      } catch (e) {
        // Keep the code (the client switches on it) but say which row is bad.
        if (e instanceof HttpError) e.message = `samples[${i}]: ${e.message}`;
        throw e;
      }
    });

    const out = db.tx(() => {
      const m = ensure();
      const learned = { category: 0, fund: 0 };
      // One vocabulary set per model for the whole batch: membership is then
      // O(1) instead of an O(vocab) rebuild on every single sample.
      const union = { category: nb.vocabulary(m.category), fund: nb.vocabulary(m.fund) };
      for (const s of samples) {
        // No text and no features → no evidence. nb.learn() would ignore it
        // anyway; skipping here keeps `learned` and `version` honest.
        if (s.tokens.length === 0) continue;
        if (s.categoryId) {
          nb.learn(m.category, s.tokens, s.categoryId, union.category);
          learned.category++;
        }
        if (s.fundId) {
          nb.learn(m.fund, s.tokens, s.fundId, union.fund);
          learned.fund++;
        }
      }
      if (!learned.category && !learned.fund) {
        return { version: globalVersion(), learned };
      }
      // Check before writing anything: an over-cap batch must leave the stored
      // model exactly as it was.
      if (learned.category) assertWithinCaps('category', m.category);
      if (learned.fund) assertWithinCaps('fund', m.fund);

      // One bump per request, not per model and not per sample, so `version`
      // counts syncs — and it moves even when only the smaller model changed.
      const next = bumpVersion();
      if (learned.category) {
        m.category.version = next;
        save('category', m.category);
      }
      if (learned.fund) {
        m.fund.version = next;
        save('fund', m.fund);
      }
      return { version: next, learned };
    });
    sendJson(res, 200, out);
  }

  /** Reset to the seed. The next GET rebuilds it — nothing is stored here. */
  function reset(req, res, reqCtx) {
    // Bump first: the rebuilt seed takes the new value, so a device that cached
    // the pre-reset version still sees a strictly larger one afterwards.
    db.tx(() => {
      bumpVersion();
      db.run('DELETE FROM model WHERE key IN (?, ?)', ...KEYS);
    });
    log.info('model', `${reqCtx.member.username} reset the shared model`);
    sendJson(res, 200, { ok: true });
  }

  // 导入预览要和 GET /model 走同一条懒初始化，从没同步过模型的家庭才有种子可用；
  // imports 按字母序先加载，只能在请求时再取。
  ctx.ensureModel = ensure;
  return {
    name: 'model',
    routes: [
      { method: 'GET', pattern: '/model', handler: read, maxBody: 0 },
      { method: 'POST', pattern: '/model/learn', handler: learn, maxBody: MAX_BODY },
      // admin only: this throws away learning the whole family accumulated,
      // and the seed rebuild cannot bring the corrections back.
      { method: 'DELETE', pattern: '/model', handler: reset, auth: 'admin', maxBody: 0 },
    ],
  };
};
