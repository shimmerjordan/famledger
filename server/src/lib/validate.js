'use strict';

// Field validators. Every failure throws HttpError(400, `invalid_<field>`, …)
// so a module never has to build an error body by hand. `field` is the
// camelCase name the client sent, which is what ends up in the error code.

const { HttpError } = require('./router');

function bad(field, message) {
  throw new HttpError(400, `invalid_${field}`, message);
}

const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const isMissing = (v) => v === undefined || v === null;

/** Required non-empty string. */
function str(v, field, { min = 1, max = 200, trim = true } = {}) {
  if (typeof v !== 'string') bad(field, `${field} 必须是字符串`);
  const s = trim ? v.trim() : v;
  if (s.length < min) bad(field, `${field} 至少 ${min} 个字符`);
  if (s.length > max) bad(field, `${field} 最多 ${max} 个字符`);
  return s;
}

/** Optional string; `undefined`/`null`/'' collapse to null. */
function optStr(v, field, { max = 200, trim = true } = {}) {
  if (isMissing(v)) return null;
  if (typeof v !== 'string') bad(field, `${field} 必须是字符串`);
  const s = trim ? v.trim() : v;
  if (s === '') return null;
  if (s.length > max) bad(field, `${field} 最多 ${max} 个字符`);
  return s;
}

function int(v, field, { min = -Infinity, max = Infinity } = {}) {
  const n = typeof v === 'string' && v.trim() !== '' ? Number(v) : v;
  if (typeof n !== 'number' || !Number.isInteger(n)) bad(field, `${field} 必须是整数`);
  if (n < min || n > max) bad(field, `${field} 必须在 ${min}~${max} 之间`);
  return n;
}

function optInt(v, field, opts) {
  return isMissing(v) || v === '' ? null : int(v, field, opts);
}

function num(v, field, { min = -Infinity, max = Infinity } = {}) {
  const n = typeof v === 'string' && v.trim() !== '' ? Number(v) : v;
  if (typeof n !== 'number' || !Number.isFinite(n)) bad(field, `${field} 必须是数字`);
  if (n < min || n > max) bad(field, `${field} 必须在 ${min}~${max} 之间`);
  return n;
}

function bool(v, field) {
  if (typeof v === 'boolean') return v;
  if (v === 1 || v === 0) return v === 1;
  if (v === 'true' || v === 'false') return v === 'true';
  bad(field, `${field} 必须是布尔值`);
}

function enumOf(v, field, values) {
  if (!values.includes(v)) bad(field, `${field} 必须是 ${values.join('/')} 之一`);
  return v;
}

/** `#rrggbb`, lower-cased. */
function color(v, field, { required = false } = {}) {
  if (isMissing(v) || v === '') {
    if (required) bad(field, `${field} 不能为空`);
    return null;
  }
  if (typeof v !== 'string' || !/^#[0-9a-fA-F]{6}$/.test(v)) bad(field, `${field} 必须是 #rrggbb 形式的颜色`);
  return v.toLowerCase();
}

/** A short grapheme blob — one emoji, a couple of code points at most. */
function emoji(v, field, { max = 8 } = {}) {
  const s = optStr(v, field, { max });
  if (s && [...s].length > 4) bad(field, `${field} 太长了`);
  return s;
}

/** `YYYY-MM`, or `*` when the caller allows the every-month default. */
function month(v, field, { allowStar = false } = {}) {
  if (allowStar && v === '*') return '*';
  if (typeof v !== 'string' || !/^\d{4}-(0[1-9]|1[0-2])$/.test(v)) bad(field, `${field} 必须是 YYYY-MM`);
  return v;
}

const pad2 = (n) => String(n).padStart(2, '0');

/** The server's local calendar day (the deploy image is pinned to Asia/Shanghai). */
function localDay(d = new Date()) {
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}

/**
 * `YYYY-MM-DD` that exists on the calendar. By default it may not be later than
 * today (nothing that has not happened yet gets booked); `{future: true}` lifts
 * that for dates that are naturally ahead — a membership's expiry, a perk's window.
 */
function day(v, field, { future = false } = {}) {
  if (typeof v !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(v)) bad(field, `${field} 必须是 YYYY-MM-DD 日期`);
  const d = new Date(`${v}T00:00:00Z`);
  if (Number.isNaN(d.getTime()) || d.toISOString().slice(0, 10) !== v) bad(field, `${field} 不是有效日期`);
  if (!future && v > localDay()) bad(field, `${field} 不能晚于今天`);
  return v;
}

/** Optional `day`: `undefined` / `null` / '' collapse to null. */
function optDay(v, field, opts) {
  return isMissing(v) || v === '' ? null : day(v, field, opts);
}

/** An ISO-8601 instant, normalised to UTC with milliseconds. */
function isoTime(v, field) {
  if (typeof v !== 'string') bad(field, `${field} 必须是 ISO-8601 时间字符串`);
  const t = Date.parse(v);
  if (Number.isNaN(t)) bad(field, `${field} 必须是 ISO-8601 时间字符串`);
  return new Date(t).toISOString();
}

function list(v, field, { max = 500, required = false } = {}) {
  if (isMissing(v)) {
    if (required) bad(field, `${field} 不能为空`);
    return [];
  }
  if (!Array.isArray(v)) bad(field, `${field} 必须是数组`);
  if (v.length > max) bad(field, `${field} 最多 ${max} 项`);
  return v;
}

/** The request body itself must be an object before any field is read. */
function body(v) {
  if (!isObject(v)) throw new HttpError(400, 'bad_json', '请求体必须是 JSON 对象');
  return v;
}

module.exports = {
  bad, isObject, isMissing, str, optStr, int, optInt, num, bool, enumOf, color, emoji, month, day, optDay, localDay, isoTime, list, body,
};
