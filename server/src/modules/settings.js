'use strict';

// Household settings. Stored as one JSON blob in `meta.settings`, with `name`
// and `currency` mirrored into their own meta keys because setup, /auth/me and
// the backup manifest all read them without parsing the blob.
//
// PATCH merges one level deep: a nested object is merged key-by-key, anything
// else replaces. That is what the client needs (`{capture:{aiTrigger:'auto'}}`
// must not wipe `defaultFundId`) and nothing here is deeper than two levels.
//
// `currentSettings(db)` is exported so stats.js can read `assets` (whether the
// physical valuation counts towards net worth) without going through HTTP.

const { sendJson } = require('../lib/router');
const v = require('../lib/validate');

const DEFAULTS = {
  name: '',
  currency: 'CNY',
  capture: {
    defaultFundId: null,
    defaultAccountId: null,
    autoConfirmThreshold: 0.75,
    aiTrigger: 'off',
    aiAutoConfirm: false,
    aiProviderId: null,
  },
  ui: {
    firstDayOfMonth: 1,
  },
  // spec §2: physical items count towards net worth by default (per category,
  // overridable per item); this is the household-wide switch.
  assets: {
    netWorthIncludesPhysical: true,
  },
};

function storedSettings(db) {
  try {
    const raw = JSON.parse(db.meta('settings', '{}'));
    return v.isObject(raw) ? raw : {};
  } catch {
    return {};
  }
}

/** Defaults ← stored blob ← the authoritative meta keys. */
function currentSettings(db) {
  const s = storedSettings(db);
  return {
    name: db.meta('household_name', DEFAULTS.name),
    currency: db.meta('currency', DEFAULTS.currency),
    capture: { ...DEFAULTS.capture, ...(v.isObject(s.capture) ? s.capture : {}) },
    ui: { ...DEFAULTS.ui, ...(v.isObject(s.ui) ? s.ui : {}) },
    assets: { ...DEFAULTS.assets, ...(v.isObject(s.assets) ? s.assets : {}) },
  };
}

module.exports = (ctx) => {
  const { db } = ctx;

  function read(req, res) {
    sendJson(res, 200, currentSettings(db));
  }

  function patch(req, res, reqCtx) {
    const b = v.body(reqCtx.body);
    const next = currentSettings(db);

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
      if (c.aiTrigger !== undefined) next.capture.aiTrigger = v.enumOf(c.aiTrigger, 'aiTrigger', ['off', 'manual', 'auto']);
      if (c.aiAutoConfirm !== undefined) next.capture.aiAutoConfirm = v.bool(c.aiAutoConfirm, 'aiAutoConfirm');
      if (c.aiProviderId !== undefined) next.capture.aiProviderId = v.optStr(c.aiProviderId, 'aiProviderId', { max: 64 });
    }
    if (b.ui !== undefined) {
      const u = v.isObject(b.ui) ? b.ui : v.bad('ui', 'ui 必须是对象');
      if (u.firstDayOfMonth !== undefined) {
        next.ui.firstDayOfMonth = v.int(u.firstDayOfMonth, 'firstDayOfMonth', { min: 1, max: 28 });
      }
    }
    if (b.assets !== undefined) {
      const x = v.isObject(b.assets) ? b.assets : v.bad('assets', 'assets 必须是对象');
      if (x.netWorthIncludesPhysical !== undefined) {
        next.assets.netWorthIncludesPhysical = v.bool(x.netWorthIncludesPhysical, 'netWorthIncludesPhysical');
      }
    }

    db.tx(() => {
      db.setMeta('household_name', next.name);
      db.setMeta('currency', next.currency);
      db.setMeta('settings', JSON.stringify({ capture: next.capture, ui: next.ui, assets: next.assets }));
    });
    sendJson(res, 200, currentSettings(db));
  }

  return {
    name: 'settings',
    routes: [
      { method: 'GET', pattern: '/settings', handler: read, maxBody: 0 },
      { method: 'PATCH', pattern: '/settings', handler: patch, auth: 'admin' },
    ],
  };
};
// Attached to the factory: the module loader only checks that the export is a function.
module.exports.currentSettings = currentSettings;
