'use strict';

// Multinomial naive Bayes over character n-grams — the shared half of the
// auto-capture classifier (spec §6). The phone runs the same algorithm in Dart
// (`app/lib/capture/naive_bayes.dart`); this file and that one MUST agree
// character for character, because the model travels between them as JSON.
//
// ── Serialised form (the contract) ───────────────────────────────────────
//   {
//     version:   int,                    // bumped by the /model endpoints
//     classes: { [label]: { docs: int, tokens: int, counts: { [token]: int } } },
//     vocab:     int,                    // |⋃ keys(counts)| over every class
//     totalDocs: int                     // Σ docs
//   }
// `label` is an opaque id (a category id or a fund id server-side). JSON object
// key ORDER is not part of the contract — JS reorders integer-like keys such as
// "35" ahead of the rest, Dart does not. Compare parsed values, never bytes.
//
// ── Tokenizer (the other contract) ───────────────────────────────────────
// normalize(text):
//   1. NFKC — full-width forms fold to half-width (ＡＢ→AB, ￥→¥, ．→.)
//   2. toLowerCase
//   3. drop every character that is not a Unicode letter or number:
//      /[^\p{L}\p{N}]/gu — this removes whitespace, punctuation (\p{P}) and
//      symbols (\p{S}) as the spec asks, and also the invisible residue those
//      leave behind (combining marks, variation selectors, ZWJ,控制字符),
//      which would otherwise become tokens of their own.
// extrasFor(fields) emits a feature ONLY when the field is present and
//   non-empty: `m:`/`dir:`/`ch:`/`mem:` are skipped for null/undefined/'' (an
//   empty string is not a category of its own), while `amt:`/`h:`/`wd:` are
//   emitted whenever the field is not null/undefined — 0 is a real bucket, a
//   real hour and a real weekday.
// tokenize(text, extras):
//   every code point of the normalised string as a 1-gram, in order, then every
//   adjacent code-point pair as a 2-gram, in order, then `extras` verbatim
//   (NOT normalised). Duplicates are kept — the model is multinomial.
//   Code points, not UTF-16 units: the Dart side must iterate `runes`.
//
// ── Scoring ──────────────────────────────────────────────────────────────
//   Only tokens the model has actually seen are scored. Everything else is
//   dropped before scoring: a notification is mostly characters that appear in
//   no training sample, and counting them turns the posterior into "whichever
//   class has the fewest tokens wins" (a pure length bias) — it classified
//   「商户：麦当劳」as 转账收入. `vocabulary` = ⋃ keys(counts) over every class,
//   and its size is what feeds the denominator (the stored `vocab` field is
//   never read for scoring, so a stale one cannot skew a prediction).
//
//   score(c) = log(docs_c / totalDocs) + Σ_t∈vocab log((counts_c[t] + 1) / (tokens_c + vocab))
//   p = softmax(score) — subtract the max, exp, normalise. Sorted by p
//   descending, ties broken by label ascending (UTF-16 order, which is what
//   both JS `<` and Dart `String.compareTo` use) so both languages emit the
//   same list. Laplace α = 1; an empty model yields [].
//   Two degenerate guards the Dart port must copy or the two will disagree on
//   malformed input: the prior numerator is `max(docs, 1)` and the smoothing
//   denominator is `max(1, tokens + vocab)` — neither can be reached by a model
//   that was only ever built with learn(), but both are reachable via merge().

const MODEL_VERSION = 1;

/**
 * Prototype-free bag. BOTH `classes` and `counts` are bags, and that is load
 * bearing, not tidiness: labels and tokens are attacker-reachable strings. On a
 * plain `{}`, `classes['__proto__']` reads back `Object.prototype` — so `learn`
 * would write `docs`/`tokens` onto `Object.prototype` itself (process-wide, and
 * a database rollback does not undo it), `classes['constructor']` would hand
 * back a function, and `JSON.parse`'d `__proto__` classes would vanish on the
 * way back out. Every object that is keyed by a label or a token is a bag.
 */
const bag = (src) => Object.assign(Object.create(null), src || undefined);

// ── tokenizer ───────────────────────────────────────────────────────────

/** NFKC → lower-case → letters and digits only. */
function normalize(text) {
  if (typeof text !== 'string' || text === '') return '';
  return text.normalize('NFKC').toLowerCase().replace(/[^\p{L}\p{N}]/gu, '');
}

/**
 * @param {string} text raw notification / merchant text
 * @param {string[]} [extras] pre-built feature tokens, appended verbatim
 * @returns {string[]} 1-grams, then 2-grams, then extras
 */
function tokenize(text, extras = []) {
  const chars = [...normalize(text)]; // code points, not UTF-16 units
  const out = [];
  for (let i = 0; i < chars.length; i++) out.push(chars[i]);
  for (let i = 0; i + 1 < chars.length; i++) out.push(chars[i] + chars[i + 1]);
  for (const e of extras) if (typeof e === 'string' && e !== '') out.push(e);
  return out;
}

/** Amount buckets, in cents: <10元 <50元 <200元 <1000元 else. */
function amountBucket(cents) {
  const n = Math.abs(Number(cents) || 0);
  if (n < 1000) return 0;
  if (n < 5000) return 1;
  if (n < 20000) return 2;
  if (n < 100000) return 3;
  return 4;
}

/**
 * The non-text features of one sample, in the fixed order the Dart pipeline
 * also emits. Absent fields contribute nothing.
 * @param {{merchant?:string, direction?:string, channel?:string,
 *          amountCents?:number, hour?:number, weekday?:number, memberId?:string}} f
 * @returns {string[]}
 */
function extrasFor(f = {}) {
  const out = [];
  if (f.merchant) out.push(`m:${f.merchant}`);
  if (f.direction) out.push(`dir:${f.direction}`);
  if (f.channel) out.push(`ch:${f.channel}`);
  if (f.amountCents !== undefined && f.amountCents !== null) out.push(`amt:b${amountBucket(f.amountCents)}`);
  if (f.hour !== undefined && f.hour !== null) out.push(`h:${f.hour}`);
  if (f.weekday !== undefined && f.weekday !== null) out.push(`wd:${f.weekday}`);
  if (f.memberId) out.push(`mem:${f.memberId}`);
  return out;
}

// ── model ───────────────────────────────────────────────────────────────

function emptyModel(version = MODEL_VERSION) {
  return { version, classes: bag(), vocab: 0, totalDocs: 0 };
}

function emptyClass() {
  return { docs: 0, tokens: 0, counts: bag() };
}

/**
 * Every token the model has ever seen, across all classes. `Object.keys`, never
 * `for…in`: the latter walks the prototype chain, so one polluted
 * `Object.prototype` would inflate the vocabulary of every model in the process.
 */
function vocabulary(model) {
  const seen = new Set();
  for (const label of Object.keys(model.classes)) {
    for (const t of Object.keys(model.classes[label].counts)) seen.add(t);
  }
  return seen;
}

/** The exact union size — what `model.vocab` must always equal. */
function vocabOf(model) {
  return vocabulary(model).size;
}

/**
 * Fold one document into the model, in place. `vocab` stays exact without a
 * recount.
 *
 * @param {Set<string>} [union] the model's vocabulary, when the caller already
 *   has it. Pass it when learning a batch: without it every call rebuilds the
 *   union (O(vocab)), which is what made a 500×500-char batch block the event
 *   loop for ~18 s. `learn` keeps the set up to date, so one `vocabulary(model)`
 *   before the loop is enough. Omit it and the result is identical, just slower.
 * @returns {object} the same model
 */
function learn(model, tokens, label, union = null) {
  // An empty document carries no evidence, so it must not move the priors
  // either. The Dart reference returns early here; if the server counted the
  // doc and the phone did not, `totalDocs` would drift apart forever.
  if (tokens.length === 0) return model;
  const seen = union || vocabulary(model);
  let c = model.classes[label];
  if (!c) {
    c = emptyClass();
    model.classes[label] = c;
  }
  c.docs += 1;
  c.tokens += tokens.length;
  for (const t of tokens) {
    c.counts[t] = (c.counts[t] || 0) + 1;
    seen.add(t); // idempotent — the set IS the union, so its size IS the vocab
  }
  model.vocab = seen.size;
  model.totalDocs += 1;
  return model;
}

/**
 * Add every count in `delta` into `target`, in place. `delta` is not modified
 * and neither model's `version` is touched — the caller owns versioning.
 * @returns {object} target
 */
function merge(target, delta) {
  // A hand-built target may carry Object.prototype; re-seat it before writing
  // any client-supplied label into it.
  target.classes = bag(target.classes);
  for (const [label, d] of Object.entries(delta.classes || {})) {
    let c = target.classes[label];
    if (!c) {
      c = emptyClass();
      target.classes[label] = c;
    }
    c.docs += d.docs || 0;
    c.tokens += d.tokens || 0;
    c.counts = bag(c.counts);
    for (const [t, n] of Object.entries(d.counts || {})) c.counts[t] = (c.counts[t] || 0) + n;
  }
  target.totalDocs += delta.totalDocs || 0;
  target.vocab = vocabOf(target);
  return target;
}

/**
 * @returns {{label:string, p:number}[]} every class, p descending
 *   (ties by label ascending). `[]` when the model has never been trained.
 */
function predict(model, tokens) {
  const labels = Object.keys(model.classes);
  if (labels.length === 0 || model.totalDocs <= 0) return [];

  // Score only what the model has seen — see the header note on length bias.
  const vocab = vocabulary(model);
  const seen = tokens.filter((t) => vocab.has(t));

  const scores = labels.map((label) => {
    const c = model.classes[label];
    // A class with no tokens in a vocab-less model would divide by zero.
    const denom = Math.max(1, c.tokens + vocab.size);
    let s = Math.log(Math.max(c.docs, 1) / model.totalDocs);
    for (const t of seen) s += Math.log(((c.counts[t] || 0) + 1) / denom);
    return s;
  });

  // reduce, not Math.max(...scores): a buggy client can mint arbitrarily many
  // labels, and spreading that many arguments would overflow the stack.
  const max = scores.reduce((a, b) => (b > a ? b : a), -Infinity);
  const exps = scores.map((s) => Math.exp(s - max));
  const sum = exps.reduce((a, b) => a + b, 0) || 1;
  return labels
    .map((label, i) => ({ label, p: exps[i] / sum }))
    .sort((a, b) => b.p - a.p || (a.label < b.label ? -1 : a.label > b.label ? 1 : 0));
}

// ── (de)serialisation ───────────────────────────────────────────────────

const posInt = (v) => (typeof v === 'number' && Number.isFinite(v) && v >= 0 ? Math.trunc(v) : null);

/**
 * Parse a stored model. Anything malformed — bad JSON, wrong types, a negative
 * count — collapses to an empty model rather than throwing: a corrupt row must
 * degrade the classifier, not take the API down. `vocab` is taken from the
 * payload as written (not recomputed), so a producer that miscounts shows up
 * instead of being papered over.
 * @param {string|object|null} input
 */
function parse(input) {
  let raw = input;
  if (typeof input === 'string') {
    try {
      raw = JSON.parse(input);
    } catch {
      return emptyModel();
    }
  }
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return emptyModel();
  if (!raw.classes || typeof raw.classes !== 'object' || Array.isArray(raw.classes)) return emptyModel();

  const version = posInt(raw.version) ?? MODEL_VERSION;
  const out = emptyModel(version || MODEL_VERSION);
  for (const [label, c] of Object.entries(raw.classes)) {
    if (!c || typeof c !== 'object') return emptyModel();
    const docs = posInt(c.docs);
    const tokens = posInt(c.tokens);
    if (docs === null || tokens === null || !c.counts || typeof c.counts !== 'object') return emptyModel();
    const counts = bag();
    for (const [t, n] of Object.entries(c.counts)) {
      const v = posInt(n);
      if (v === null) return emptyModel();
      counts[t] = v;
    }
    out.classes[label] = { docs, tokens, counts };
  }
  out.vocab = posInt(raw.vocab) ?? vocabOf(out);
  out.totalDocs = posInt(raw.totalDocs) ?? 0;
  return out;
}

module.exports = {
  MODEL_VERSION,
  normalize, tokenize, amountBucket, extrasFor,
  emptyModel, learn, merge, predict, vocabulary, vocabOf, parse,
};
