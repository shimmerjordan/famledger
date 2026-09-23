'use strict';

// setup / auth / members / settings — the contract every later module builds on.
// Each case gets its own server + data dir so state (and the login rate-limit
// bucket) never leaks between cases.

const test = require('node:test');
const assert = require('node:assert/strict');
const { DatabaseSync } = require('node:sqlite');
const path = require('node:path');

const { startServer, api } = require('./helpers');

const SETUP = {
  householdName: '小明家',
  username: 'admin',
  password: 'hunter22',
  displayName: '小明',
};

/** Fresh server, torn down when the test ends. */
async function fresh(t, env) {
  const srv = await startServer(env);
  t.after(() => srv.stop());
  return { srv, a: api(srv.base) };
}

/** Fresh server that has already run POST /setup. */
async function bootstrapped(t, env) {
  const { srv, a } = await fresh(t, env);
  const r = await a.post('/setup', SETUP);
  assert.equal(r.status, 200, `setup failed: ${r.text}`);
  return { srv, a, token: r.json.token, member: r.json.member };
}

// ① ---------------------------------------------------------------------
test('① 空库 GET /setup/status → needsSetup:true', async (t) => {
  const { a } = await fresh(t);
  const r = await a.get('/setup/status');
  assert.equal(r.status, 200);
  assert.equal(r.json.needsSetup, true);
  assert.equal(r.json.householdName, undefined);
});

// ② ---------------------------------------------------------------------
test('② POST /setup 建 admin 返回 token；再次 POST /setup → 409', async (t) => {
  const { srv, a } = await fresh(t);
  const r = await a.post('/setup', SETUP);
  assert.equal(r.status, 200, r.text);
  assert.match(r.json.token, /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/);
  assert.equal(r.json.member.username, 'admin');
  assert.equal(r.json.member.role, 'admin');
  assert.equal(r.json.member.displayName, '小明');
  assert.equal(r.json.member.archived, false);
  assert.ok(!('passwordHash' in r.json.member), 'password hash must not leak');
  assert.ok(!('password_hash' in r.json.member), 'snake_case must not leak');

  const st = await a.get('/setup/status');
  assert.equal(st.json.needsSetup, false);
  assert.equal(st.json.householdName, '小明家');

  const again = await a.post('/setup', SETUP);
  assert.equal(again.status, 409);
  assert.equal(again.json.error.code, 'already_setup');

  // setup seeds the household defaults.
  const db = new DatabaseSync(path.join(srv.dataDir, 'famledger.db'), { readOnly: true });
  t.after(() => db.close());
  const cats = db.prepare('SELECT kind, COUNT(*) n FROM categories GROUP BY kind').all();
  const byKind = Object.fromEntries(cats.map((c) => [c.kind, c.n]));
  assert.equal(byKind.expense, 15);
  assert.equal(byKind.income, 6);
  assert.ok(
    db.prepare('SELECT COUNT(*) n FROM categories WHERE icon IS NOT NULL AND color IS NOT NULL').get().n === 21,
    'every seeded category has an icon and a color',
  );
  const fund = db.prepare('SELECT * FROM funds').get();
  assert.equal(fund.name, '家庭公共基金');
  assert.equal(fund.kind, 'shared');
  assert.equal(fund.color, '#c36a4f');
  assert.equal(fund.is_default, 1);
  const acct = db.prepare('SELECT * FROM accounts').get();
  assert.equal(acct.name, '现金');
  assert.equal(acct.kind, 'cash');
  assert.ok(db.prepare("SELECT value FROM meta WHERE key='change_seq'").get().value > 0);
});

test('② SETUP_TOKEN 非空时 POST /setup 需要令牌（header 通道）', async (t) => {
  const { a } = await fresh(t, { SETUP_TOKEN: 's3cret' });
  const no = await a.post('/setup', SETUP);
  assert.equal(no.status, 403);
  assert.equal(no.json.error.code, 'forbidden');
  const bad = await a.post('/setup', SETUP, { setupToken: 'nope' });
  assert.equal(bad.status, 403);
  const ok = await a.post('/setup', SETUP, { setupToken: 's3cret' });
  assert.equal(ok.status, 200, ok.text);
});

test('② SETUP_TOKEN 也接受 body 里的 setupToken（Flutter 首启向导走这条）', async (t) => {
  const { a } = await fresh(t, { SETUP_TOKEN: 's3cret' });

  // The app puts the token in the JSON body, not in a header.
  const bad = await a.post('/setup', { ...SETUP, setupToken: 'nope' });
  assert.equal(bad.status, 403);
  assert.equal(bad.json.error.code, 'forbidden');

  const ok = await a.post('/setup', { ...SETUP, setupToken: 's3cret' });
  assert.equal(ok.status, 200, ok.text);
  assert.equal(ok.json.member.username, 'admin');
  // The extra body field must not leak into the member record.
  assert.ok(!('setupToken' in ok.json.member));
});

test('② setup 令牌不会出现在任何响应体或日志里', async (t) => {
  const TOKEN = 'sup3r-s3cret-setup-token';
  // LOG_LEVEL=warn so the rejection actually reaches the captured stderr —
  // otherwise the "not in the log" assertion would be vacuously true.
  const { srv, a } = await fresh(t, { SETUP_TOKEN: TOKEN, LOG_LEVEL: 'warn' });

  const bad = await a.post('/setup', { ...SETUP, setupToken: 'wrong-guess' });
  assert.equal(bad.status, 403);
  assert.doesNotMatch(bad.text, /sup3r|wrong-guess/, '403 must not echo either token');

  const ok = await a.post('/setup', { ...SETUP, setupToken: TOKEN });
  assert.equal(ok.status, 200, ok.text);
  assert.doesNotMatch(ok.text, /sup3r/, '200 must not echo the token');

  // …nor through anything the freshly-made session can read back.
  for (const p of ['/auth/me', '/settings', '/members']) {
    const r = await a.get(p, { token: ok.json.token });
    assert.equal(r.status, 200, `${p}: ${r.text}`);
    assert.doesNotMatch(r.text, /sup3r/, `${p} must not echo the token`);
  }

  await new Promise((r) => setTimeout(r, 50)); // let the child's stderr flush
  const logged = srv.stderr();
  assert.match(logged, /rejected setup attempt/, 'the failed attempt is logged at all');
  assert.doesNotMatch(logged, /sup3r|wrong-guess/, 'but never with the token in it');
});

test('② POST /setup 限流：SETUP_TOKEN 爆破在第 N+1 次被挡下', async (t) => {
  const { a } = await fresh(t, { SETUP_TOKEN: 's3cret', SETUP_PER_MIN: '3' });

  const statuses = [];
  for (let i = 0; i < 4; i++) {
    const r = await a.post('/setup', SETUP, { setupToken: `guess-${i}` });
    statuses.push(r.status);
    if (i === 3) assert.equal(r.json.error.code, 'rate_limited');
  }
  // The limiter runs *before* the token comparison, so a wrong token is not a
  // free attempt — otherwise the token could be brute-forced at line speed.
  assert.deepEqual(statuses, [403, 403, 403, 429]);

  // Even the correct token is refused while the bucket is empty.
  assert.equal((await a.post('/setup', SETUP, { setupToken: 's3cret' })).status, 429);

  // …and the bucket is setup's own: login still answers on its own budget.
  const login = await a.post('/auth/login', { username: 'admin', password: 'hunter22' });
  assert.equal(login.status, 401, 'login must not share the setup bucket');
  assert.equal(login.json.error.code, 'invalid_credentials');
});

// ③ ---------------------------------------------------------------------
test('③ POST /auth/login 错口令 401、对口令 200', async (t) => {
  const { a } = await bootstrapped(t);
  const bad = await a.post('/auth/login', { username: 'admin', password: 'wrong' });
  assert.equal(bad.status, 401);
  assert.equal(bad.json.error.code, 'invalid_credentials');

  const nouser = await a.post('/auth/login', { username: 'ghost', password: 'hunter22' });
  assert.equal(nouser.status, 401);
  assert.equal(nouser.json.error.code, 'invalid_credentials');

  const ok = await a.post('/auth/login', {
    username: 'admin',
    password: 'hunter22',
    deviceName: 'Pixel 8',
    platform: 'android',
  });
  assert.equal(ok.status, 200, ok.text);
  assert.ok(ok.json.token);
  assert.ok(ok.json.deviceId);
  assert.equal(ok.json.member.username, 'admin');

  const me = await a.get('/auth/me', { token: ok.json.token });
  assert.equal(me.status, 200);
  assert.equal(me.json.deviceId, ok.json.deviceId);
});

// ④ ---------------------------------------------------------------------
test('④ GET /auth/me 无 token 401、有 token 返回 member', async (t) => {
  const { a, token } = await bootstrapped(t);
  const anon = await a.get('/auth/me');
  assert.equal(anon.status, 401);
  assert.equal(anon.json.error.code, 'unauthorized');

  const garbage = await a.get('/auth/me', { token: 'not.a.token' });
  assert.equal(garbage.status, 401);

  const me = await a.get('/auth/me', { token });
  assert.equal(me.status, 200, me.text);
  assert.equal(me.json.member.username, 'admin');
  assert.equal(me.json.member.avatarEmoji, '🙂');
  assert.equal(me.json.household.name, '小明家');
  assert.equal(me.json.household.currency, 'CNY');
  assert.ok(me.json.deviceId);
});

// ⑤ ---------------------------------------------------------------------
test('⑤ POST /auth/logout 后同 token 401', async (t) => {
  const { a, token } = await bootstrapped(t);
  assert.equal((await a.get('/auth/me', { token })).status, 200);
  const out = await a.post('/auth/logout', undefined, { token });
  assert.equal(out.status, 200, out.text);
  const after = await a.get('/auth/me', { token });
  assert.equal(after.status, 401);
  assert.equal(after.json.error.code, 'unauthorized');
});

// ⑥ ---------------------------------------------------------------------
test('⑥ 登录连打 3 次，第 3 次 429（LOGIN_PER_MIN=2）', async (t) => {
  // N 故意取小（与 test/ai.test.js 的 AI_PER_MIN=2 同一约定）：每次登录尝试都会
  // 真的跑一遍 scrypt 校验密码，N=10 时窗口边界只有 6 秒裕量，CI 较慢的机器上
  // 曾经真的因此偶发 429 判定提前触发；N=2 把裕量放大到 30 秒，覆盖的生产代码
  // 路径（RateLimiter + 登录路由 + 429 rate_limited）完全一样。
  const { a } = await bootstrapped(t, { LOGIN_PER_MIN: '2' });
  const statuses = [];
  for (let i = 0; i < 3; i++) {
    const r = await a.post('/auth/login', { username: 'admin', password: 'wrong' });
    statuses.push(r.status);
    if (i === 2) assert.equal(r.json.error.code, 'rate_limited');
  }
  assert.deepEqual(statuses, [401, 401, 429]);
});

// ⑦ ---------------------------------------------------------------------
test('⑦ admin 可建 member；member 角色 POST /members → 403', async (t) => {
  const { a, token } = await bootstrapped(t);

  const created = await a.post(
    '/members',
    { username: 'xiaohong', password: 'hunter22', displayName: '小红', color: '#bb6690', avatarEmoji: '🌸', role: 'member' },
    { token },
  );
  assert.equal(created.status, 201, created.text);
  assert.equal(created.json.member.displayName, '小红');
  assert.equal(created.json.member.role, 'member');
  assert.equal(created.json.member.color, '#bb6690');

  const dup = await a.post('/members', { username: 'xiaohong', password: 'hunter22', displayName: '重复' }, { token });
  assert.equal(dup.status, 409);
  assert.equal(dup.json.error.code, 'username_taken');

  const list = await a.get('/members', { token });
  assert.equal(list.status, 200);
  assert.equal(list.json.items.length, 2);
  assert.ok(list.json.items.every((m) => !('passwordHash' in m)));

  const hong = await a.post('/auth/login', { username: 'xiaohong', password: 'hunter22' });
  assert.equal(hong.status, 200, hong.text);
  const memberToken = hong.json.token;

  // A plain member may read the roster …
  assert.equal((await a.get('/members', { token: memberToken })).status, 200);
  // … but not write it.
  const forbidden = await a.post(
    '/members',
    { username: 'nope', password: 'hunter22', displayName: '不行' },
    { token: memberToken },
  );
  assert.equal(forbidden.status, 403);
  assert.equal(forbidden.json.error.code, 'forbidden');

  // admin can rename, reset a password, and archive.
  const patched = await a.patch(`/members/${created.json.member.id}`, { displayName: '小红红' }, { token });
  assert.equal(patched.status, 200, patched.text);
  assert.equal(patched.json.member.displayName, '小红红');

  const reset = await a.post(`/members/${created.json.member.id}/reset-password`, { password: 'newpass1' }, { token });
  assert.equal(reset.status, 200, reset.text);
  assert.equal((await a.post('/auth/login', { username: 'xiaohong', password: 'newpass1' })).status, 200);
  // resetting revokes the old device tokens
  assert.equal((await a.get('/auth/me', { token: memberToken })).status, 401);

  const archived = await a.del(`/members/${created.json.member.id}`, { token });
  assert.equal(archived.status, 200, archived.text);
  assert.equal(archived.json.member.archived, true);
  assert.equal((await a.post('/auth/login', { username: 'xiaohong', password: 'newpass1' })).status, 401);

  // the last admin cannot be archived
  const lastAdmin = await a.del(`/members/${(await a.get('/auth/me', { token })).json.member.id}`, { token });
  assert.equal(lastAdmin.status, 409);
  assert.equal(lastAdmin.json.error.code, 'last_admin');
});

// ⑧ ---------------------------------------------------------------------
test('⑧ GET /settings 默认 currency:CNY；PATCH 深合并生效', async (t) => {
  const { a, token } = await bootstrapped(t);

  const got = await a.get('/settings', { token });
  assert.equal(got.status, 200, got.text);
  assert.deepEqual(got.json, {
    name: '小明家',
    currency: 'CNY',
    capture: {
      defaultFundId: null,
      defaultAccountId: null,
      autoConfirmThreshold: 0.75,
      aiTrigger: 'off',
      aiAutoConfirm: false,
      aiProviderId: null,
    },
    ui: { firstDayOfMonth: 1 },
  });

  const p = await a.patch('/settings', { capture: { autoConfirmThreshold: 0.8 } }, { token });
  assert.equal(p.status, 200, p.text);
  assert.equal(p.json.capture.autoConfirmThreshold, 0.8);
  // one-level deep merge: siblings inside `capture` survive
  assert.equal(p.json.capture.aiTrigger, 'off');
  assert.equal(p.json.ui.firstDayOfMonth, 1);
  assert.equal(p.json.currency, 'CNY');

  const again = await a.get('/settings', { token });
  assert.equal(again.json.capture.autoConfirmThreshold, 0.8);

  // name mirrors meta.household_name, visible through /auth/me
  const renamed = await a.patch('/settings', { name: '小明和小红家', ui: { firstDayOfMonth: 5 } }, { token });
  assert.equal(renamed.json.name, '小明和小红家');
  assert.equal(renamed.json.ui.firstDayOfMonth, 5);
  assert.equal(renamed.json.capture.autoConfirmThreshold, 0.8);
  assert.equal((await a.get('/auth/me', { token })).json.household.name, '小明和小红家');

  const bad = await a.patch('/settings', { capture: { autoConfirmThreshold: 9 } }, { token });
  assert.equal(bad.status, 400);
  assert.equal(bad.json.error.code, 'invalid_autoConfirmThreshold');

  const aiPatch = await a.patch(
    '/settings',
    { capture: { aiTrigger: 'auto', aiAutoConfirm: true, aiProviderId: 'prov-1' } },
    { token },
  );
  assert.equal(aiPatch.status, 200, aiPatch.text);
  assert.equal(aiPatch.json.capture.aiTrigger, 'auto');
  assert.equal(aiPatch.json.capture.aiAutoConfirm, true);
  assert.equal(aiPatch.json.capture.aiProviderId, 'prov-1');

  // aiProviderId 传 null = 清回默认渠道
  const cleared = await a.patch('/settings', { capture: { aiProviderId: null } }, { token });
  assert.equal(cleared.json.capture.aiProviderId, null);

  const badTrigger = await a.patch('/settings', { capture: { aiTrigger: 'sometimes' } }, { token });
  assert.equal(badTrigger.status, 400);
  assert.equal(badTrigger.json.error.code, 'invalid_aiTrigger');
});

// misc contract ---------------------------------------------------------
test('坏 JSON → 400 bad_json；缺字段 → 400 invalid_*', async (t) => {
  const { a } = await fresh(t);
  const broken = await a.raw('POST', '/api/v1/setup', { body: '{oops' });
  assert.equal(broken.status, 400);
  assert.equal(broken.json.error.code, 'bad_json');

  const missing = await a.post('/setup', { householdName: '家', username: 'admin' });
  assert.equal(missing.status, 400);
  assert.match(missing.json.error.code, /^invalid_/);
});

test('POST /auth/password 改口令后旧口令失效', async (t) => {
  const { a, token } = await bootstrapped(t);
  const wrong = await a.post('/auth/password', { oldPassword: 'nope', newPassword: 'brandnew1' }, { token });
  assert.equal(wrong.status, 401);

  const ok = await a.post('/auth/password', { oldPassword: 'hunter22', newPassword: 'brandnew1' }, { token });
  assert.equal(ok.status, 200, ok.text);
  assert.equal((await a.post('/auth/login', { username: 'admin', password: 'hunter22' })).status, 401);
  assert.equal((await a.post('/auth/login', { username: 'admin', password: 'brandnew1' })).status, 200);
});
