'use strict';

// Household settings. Stored as one JSON blob in `meta.settings`, with `name`
// and `currency` mirrored into their own meta keys because setup, /auth/me and
// the backup manifest all read them without parsing the blob.
//
// PATCH merges one level deep: a nested object is merged key-by-key, anything
// else replaces. That is what the client needs (`{capture:{llmFallback:true}}`
// must not wipe `defaultFundId`) and nothing here is deeper than two levels.

const { sendJson } = require('../lib/router');
const v = require('../lib/validate');

const DEFAULTS = {
  name: '',
  currency: 'CNY',
  capture: {
    defaultFundId: null,
    defaultAccountId: null,
    autoConfirmThreshold: 0.75,
    llmFallback: false,
  },
  ui: {
    firstDayOfMonth: 1,
  },
};

module.exports = (ctx) => {
  const { db } = ctx;

  function stored() {
    try {
      const raw = JSON.parse(db.meta('settings', '{}'));
      return v.isObject(raw) ? raw : {};
    } catch {
      return {};
    }
  }

  /** Defaults ← stored blob ← the authoritative meta keys. */
  function current() {
    const s = stored();
    return {
      name: db.meta('household_name', DEFAULTS.name),
      currency: db.meta('currency', DEFAULTS.currency),
      capture: { ...DEFAULTS.capture, ...(v.isObject(s.capture) ? s.capture : {}) },
      ui: { ...DEFAULTS.ui, ...(v.isObject(s.ui) ? s.ui : {}) },
    };
  }

  function read(req, res) {
    sendJson(res, 200, current());
  }

  function patch(req, res, reqCtx) {
    const b = v.body(reqCtx.body);
    const next = current();

    if (b.name !== undefined) next.name = v.str(b.name, 'name', { max: 60 });
    if (b.currency !== undefined) {
      next.currency = v.str(b.currency, 'currency', { min: 3, max: 3 }).toUpperCase();
      if (!/^[A-Z]{3}$/.test(next.currency)) v.bad('currency', '币种必须是 3 个字母的代码');
    }
    if (b.capture !== undefined) {
      const c = v.isObject(b.capture) ? b.capture : v.bad('capture', 'capture 必须是对象');
      if (c.defaultFundId !== undefined) next.capture.defaultFundId = v.optStr(c.defaultFundId, 'defaultFundId', { max: 64 });
      if (c.defaultAccountId !== undefined) next.capture.defaultAccountId = v.optStr(c.defaultAccountId, 'defaultAccountId', { max: 64 });
      if (c.autoConfirmThreshold !== undefined) {
        next.capture.autoConfirmThreshold = v.num(c.autoConfirmThreshold, 'autoConfirmThreshold', { min: 0, max: 1 });
      }
      if (c.llmFallback !== undefined) next.capture.llmFallback = v.bool(c.llmFallback, 'llmFallback');
    }
    if (b.ui !== undefined) {
      const u = v.isObject(b.ui) ? b.ui : v.bad('ui', 'ui 必须是对象');
      if (u.firstDayOfMonth !== undefined) {
        next.ui.firstDayOfMonth = v.int(u.firstDayOfMonth, 'firstDayOfMonth', { min: 1, max: 28 });
      }
    }

    db.tx(() => {
      db.setMeta('household_name', next.name);
      db.setMeta('currency', next.currency);
      db.setMeta('settings', JSON.stringify({ capture: next.capture, ui: next.ui }));
    });
    sendJson(res, 200, current());
  }

  return {
    name: 'settings',
    routes: [
      { method: 'GET', pattern: '/settings', handler: read, maxBody: 0 },
      { method: 'PATCH', pattern: '/settings', handler: patch, auth: 'admin' },
    ],
  };
};
