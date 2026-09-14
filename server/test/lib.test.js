'use strict';

// Unit tests for the base libs. The HTTP suites cover these indirectly, but
// every later module (transactions, changes, backup, ai) builds directly on
// them, so the edges — a tampered token, a rolled-back transaction, an
// encrypted API key — are pinned here rather than discovered downstream.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');

const { openDb, rowToJson } = require('../src/lib/db');
const { hashPassword, verifyPassword, signToken, verifyToken } = require('../src/lib/auth');
const { loadOrCreateSecret, encrypt, decrypt, isEncrypted } = require('../src/lib/secret');
const { RateLimiter } = require('../src/lib/ratelimit');
const { clientIp } = require('../src/lib/clientip');
const { openSse } = require('../src/lib/sse');

function tmp(tag) {
  return fs.mkdtempSync(path.join(os.tmpdir(), `famledger-${tag}-`));
}

test('db: migrations run once, seq is monotonic, tx rolls back', (t) => {
  const dir = tmp('db');
  const db = openDb(dir);
  t.after(() => db.close());

  const applied = db.all('SELECT version FROM schema_migrations');
  assert.deepEqual(applied.map((r) => Number(r.version)), [1]);
  assert.equal(db.meta('change_seq'), '0');

  const seqs = db.tx(() => [db.nextSeq(), db.nextSeq(), db.nextSeq()]);
  assert.deepEqual(seqs, [1, 2, 3]);

  // A throw inside tx() leaves nothing behind — including the seq bump.
  assert.throws(() => {
    db.tx(() => {
      db.setMeta('household_name', '半路夭折');
      db.nextSeq();
      throw new Error('boom');
    });
  }, /boom/);
  assert.equal(db.meta('household_name', null), null);
  assert.equal(db.meta('change_seq'), '3');

  // Nested tx() joins the outer one rather than failing on a nested BEGIN.
  db.tx(() => {
    db.setMeta('currency', 'CNY');
    db.tx(() => db.setMeta('household_name', '家'));
  });
  assert.equal(db.meta('household_name'), '家');

  // reopen() (used by backup restore) keeps everything and still works.
  db.reopen();
  assert.equal(db.meta('household_name'), '家');
  assert.equal(db.tx(() => db.nextSeq()), 4);
  assert.deepEqual(db.all('SELECT version FROM schema_migrations').map((r) => Number(r.version)), [1]);
});

test('db: rowToJson converts snake_case, hides and casts columns', () => {
  const row = {
    id: 'a', display_name: '小明', archived: 1, is_default: 0,
    match_hints: '{"tail":"1234"}', tags: 'not json', note: null, password_hash: 'secret',
  };
  assert.deepEqual(
    rowToJson(row, { omit: ['password_hash'], bools: ['archived', 'is_default'], json: ['match_hints', 'tags'] }),
    { id: 'a', displayName: '小明', archived: true, isDefault: false, matchHints: { tail: '1234' }, tags: null, note: null },
  );
  assert.equal(rowToJson(null), null);
});

test('auth: scrypt hashes verify and never collide', () => {
  const h = hashPassword('hunter22');
  assert.match(h, /^scrypt\$16384\$8\$1\$[A-Za-z0-9+/=]+\$[A-Za-z0-9+/=]+$/);
  assert.notEqual(hashPassword('hunter22'), h, 'salt must be random');
  assert.equal(verifyPassword('hunter22', h), true);
  assert.equal(verifyPassword('hunter23', h), false);
  for (const junk of ['', 'plain', 'scrypt$x', null, undefined, 'scrypt$16384$8$1$@@@$@@@']) {
    assert.equal(verifyPassword('hunter22', junk), false, `${junk} must not verify`);
  }
});

test('auth: tokens are signed, scoped and expiring', () => {
  const secret = Buffer.alloc(32, 7);
  const other = Buffer.alloc(32, 8);
  const token = signToken(secret, { sub: 'm1', tid: 't1' });

  const payload = verifyToken(secret, token);
  assert.equal(payload.sub, 'm1');
  assert.equal(payload.tid, 't1');
  assert.ok(payload.exp - payload.iat === 30 * 24 * 3600, '30-day expiry');

  assert.equal(verifyToken(other, token), null, 'another secret must not verify');
  assert.equal(verifyToken(secret, token.slice(0, -2) + 'AA'), null, 'tampered signature');
  const [head, sig] = token.split('.');
  const forged = Buffer.from(JSON.stringify({ sub: 'admin', tid: 't1', exp: 2 ** 40 }), 'utf8').toString('base64url');
  assert.equal(verifyToken(secret, `${forged}.${sig}`), null, 'swapped payload');
  assert.equal(verifyToken(secret, head), null, 'no signature');
  assert.equal(verifyToken(secret, `${head}.${sig}.extra`), null, 'three parts');
  assert.equal(verifyToken(secret, signToken(secret, { sub: 'm', tid: 't', exp: 1 })), null, 'expired');
  for (const junk of ['', '.', 'abc', null, 42]) assert.equal(verifyToken(secret, junk), null);
});

test('secret: the key file is created once and API keys round-trip', () => {
  const dir = tmp('secret');
  const key = loadOrCreateSecret(dir);
  assert.equal(key.length, 32);
  assert.ok(key.equals(loadOrCreateSecret(dir)), 'a second call reuses the file');
  assert.equal(fs.statSync(path.join(dir, 'secret.key')).mode & 0o777, 0o600);

  const enc = encrypt(key, 'sk-ant-secret-value');
  assert.ok(enc.startsWith('enc:v1:'));
  assert.ok(isEncrypted(enc) && !isEncrypted('sk-plain'));
  assert.equal(decrypt(key, enc), 'sk-ant-secret-value');
  assert.notEqual(encrypt(key, 'same'), encrypt(key, 'same'), 'nonce must be random');
  assert.equal(decrypt(key, null), null);
  assert.equal(decrypt(key, ''), null);
  assert.throws(() => decrypt(Buffer.alloc(32, 1), enc), /unable to authenticate|bad decrypt/i);
  assert.throws(() => decrypt(key, 'enc:v1:' + Buffer.from('too short').toString('base64')), /truncated/);
  assert.throws(() => decrypt(key, 'plaintext'), /enc:v1/);
});

test('ratelimit: N per minute, then refusal', () => {
  const rl = new RateLimiter(10);
  const results = Array.from({ length: 11 }, () => rl.allow('1.2.3.4'));
  assert.deepEqual(results.slice(0, 10), Array(10).fill(true));
  assert.equal(results[10], false);
  assert.equal(rl.allow('5.6.7.8'), true, 'buckets are per key');
});

test('clientip: proxy headers only count when TRUST_PROXY is on', () => {
  const req = {
    headers: { 'cf-connecting-ip': '9.9.9.9', 'x-forwarded-for': '1.1.1.1, 2.2.2.2' },
    socket: { remoteAddress: '127.0.0.1' },
  };
  assert.equal(clientIp(req, false), '127.0.0.1');
  assert.equal(clientIp(req, true), '9.9.9.9');
  delete req.headers['cf-connecting-ip'];
  assert.equal(clientIp(req, true), '1.1.1.1', 'first hop of x-forwarded-for');
  delete req.headers['x-forwarded-for'];
  assert.equal(clientIp(req, true), '127.0.0.1');
});

test('log: all five levels are callable and LOG_LEVEL gates them', () => {
  const log = require('../src/lib/log');
  for (const level of ['trace', 'debug', 'info', 'warn', 'error']) {
    assert.equal(typeof log[level], 'function', `ctx.log.${level} must exist`);
  }

  // Emission is threshold-driven, so check it in a child with a real LOG_LEVEL.
  const probe =
    "const l=require(process.argv[1]);for(const x of ['trace','debug','info','warn','error'])l[x]('t',x);";
  const run = (LOG_LEVEL) => {
    const r = require('node:child_process').spawnSync(
      process.execPath,
      ['-e', probe, path.join(__dirname, '..', 'src', 'lib', 'log.js')],
      { env: { ...process.env, LOG_LEVEL }, encoding: 'utf8' },
    );
    return (r.stdout + r.stderr).trim().split('\n').filter(Boolean).map((l) => l.match(/\[(\w+)\] \[t\]/)[1]);
  };
  assert.deepEqual(run('trace'), ['trace', 'debug', 'info', 'warn', 'error']);
  assert.deepEqual(run('debug'), ['debug', 'info', 'warn', 'error'], 'debug is its own level, below info');
  assert.deepEqual(run('info'), ['info', 'warn', 'error']);
  assert.deepEqual(run('error'), ['error']);
  assert.deepEqual(run('nonsense'), ['info', 'warn', 'error'], 'unknown level falls back to info');
});

test('sse: events are framed as text/event-stream', async (t) => {
  const server = http.createServer((req, res) => {
    const sse = openSse(res);
    sse.send('delta', { text: '你好' });
    sse.send('done', { usage: { in: 1, out: 2 } });
    sse.close();
    assert.equal(sse.send('delta', { text: 'after close' }), false);
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  t.after(() => new Promise((r) => server.close(r)));

  const res = await fetch(`http://127.0.0.1:${server.address().port}/`);
  assert.match(res.headers.get('content-type'), /^text\/event-stream/);
  assert.match(res.headers.get('cache-control'), /no-cache/);
  const body = await res.text();
  assert.equal(body, ': open\n\nevent: delta\ndata: {"text":"你好"}\n\nevent: done\ndata: {"usage":{"in":1,"out":2}}\n\n');
});
