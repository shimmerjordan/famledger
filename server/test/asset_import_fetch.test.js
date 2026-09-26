'use strict';

// 网址导入的两个接口（spec §4 POST /asset-import/fetch、POST /asset-import/extract kind=url、§6「网址」）：真服务 + 真 HTTP，
// 不访问任何外部网站（抓取本身的成功路径在 page_fetch.test.js 用本地服务器测；这里只打会被拦下的地址）。
// 钉死：写法不对 400 且不占限流；本机、localhost、fake-ip 段被拦（fake-ip 的说明里提到 URL_FETCH_ALLOW_FAKEIP、要重启、代价），
// 回应里不带解析出的地址；每人每分钟 URL_FETCH_PER_MIN 次；放开 fake-ip 时只有管理员能抓（成员 403），IP 直写、单段主机名
// 照样拦，启动日志 warn 一句；kind=url 当粘贴文字识别、依据照样核对，服务端不再去抓，ai_imports 记下 source_kind / source_url，
// 落库的 origin.src 是 ai_url，「最近的 AI 导入」里是 url；info 日志里没有网址本身。

const test = require('node:test');
const assert = require('node:assert/strict');

const { household } = require('./fixtures');
const { openDb } = require('../src/lib/db');
const { startFakeAnthropic } = require('./fake_upstream');
const { ANT_KEY, fixture, sse, addProvider, applyBodyOf } = require('./import_fixtures');

const PAGE_URL = 'https://vip.example/88vip/rights?from=app';

test('POST /asset-import/fetch：写法不对 400 invalid_url（不占限流）；本机、localhost、fake-ip 段 400 url_blocked；超过每分钟次数 429', async (t) => {
  const h = await household(t, { URL_FETCH_PER_MIN: '2', LOG_LEVEL: 'info' });
  const fetchUrl = (url) => h.a.post('/asset-import/fetch', url === undefined ? {} : { url }, h.auth);
  for (const url of [undefined, '', 'ftp://vip.example/', 'javascript:alert(1)', 'http://user:pw@vip.example/']) {
    const r = await fetchUrl(url);
    assert.deepEqual([r.status, r.json.error.code], [400, 'invalid_url'], String(url));
  }
  const loop = await fetchUrl(`http://127.0.0.1:${h.srv.port}/healthz`);
  assert.deepEqual([loop.status, loop.json.error.code, loop.json.error.details], [400, 'url_blocked', { fakeIp: false }]);
  const fake = await fetchUrl('http://198.18.0.1/');
  assert.deepEqual([fake.status, fake.json.error.code, fake.json.error.details], [400, 'url_blocked', { fakeIp: true }]);
  assert.match(fake.json.error.message, /URL_FETCH_ALLOW_FAKEIP=1.*重启.*只有管理员能用网址导入/);
  assert.ok(!fake.text.includes('198.18.0.1'), '回应里不带解析出的地址');
  const limited = await fetchUrl(`http://localhost:${h.srv.port}/`);
  assert.deepEqual([limited.status, limited.json.error.code], [429, 'rate_limited']);
  assert.equal((await h.a.post('/asset-import/fetch', { url: 'http://127.0.0.1/' })).status, 401);
  assert.ok(!h.srv.stdout().includes('/healthz'), 'info 日志里没有网址');
  assert.match(h.srv.stdout(), /\[import\] 抓网页失败 url_blocked/);
});

test('POST /asset-import/fetch：localhost（DNS 解析成回环）同样拦下，回应里没有解析出的地址（只进 debug 日志）', async (t) => {
  const h = await household(t, { LOG_LEVEL: 'debug' });
  const r = await h.a.post('/asset-import/fetch', { url: `http://localhost:${h.srv.port}/` }, h.auth);
  assert.deepEqual([r.status, r.json.error.code, r.json.error.details], [400, 'url_blocked', { fakeIp: false }]);
  assert.ok(!/127\.0\.0\.1|::1/.test(r.text), r.text);
  assert.match(h.srv.stdout(), /抓网页被拦 http:\/\/localhost:\d+\/ → (127\.0\.0\.1|::1)/);
});

test('URL_FETCH_ALLOW_FAKEIP=1：只有管理员能抓（成员 403，不占限流）；IP 直写、单段主机名、内网后缀照样拦；启动时 warn 代价', async (t) => {
  const h = await household(t, { URL_FETCH_ALLOW_FAKEIP: '1', URL_FETCH_PER_MIN: '5', LOG_LEVEL: 'info' });
  assert.match(h.srv.stderr(), /已放开 fake-ip 抓取.*没法核实网址的真实目标地址.*只有管理员能用网址导入/);
  await h.a.post('/members', { username: 'xiaohong', password: 'hunter22', displayName: '小红', role: 'member' }, h.auth);
  const her = (await h.a.post('/auth/login', { username: 'xiaohong', password: 'hunter22' })).json.token;
  for (let i = 0; i < 6; i++) {
    const r = await h.a.post('/asset-import/fetch', { url: 'https://vip.example/88' }, { token: her });
    assert.deepEqual([r.status, r.json.error.code], [403, 'url_fetch_admin_only']);
  }
  assert.match((await h.a.post('/asset-import/fetch', { url: 'https://vip.example/88' }, { token: her })).json.error.message, /只有管理员能用/);
  for (const url of [`http://127.0.0.1:${h.srv.port}/`, 'http://93.184.216.34/', `http://localhost:${h.srv.port}/`, 'http://db/', 'http://router.lan/']) {
    const r = await h.a.post('/asset-import/fetch', { url }, h.auth);
    assert.deepEqual([r.status, r.json.error.code], [400, 'url_blocked'], url);
  }
});

test('kind=url：要带正文和 http(s) 的 sourceUrl；当粘贴文字识别、依据照样核对，服务端不去抓那个网址；记下来源，落库 src=ai_url', async (t) => {
  const up = await startFakeAnthropic({ key: ANT_KEY });
  t.after(() => up.stop());
  const h = await household(t, { LOG_LEVEL: 'info' });
  await addProvider(h, up);
  const post = (body) => sse(h.srv.base, '/asset-import/extract', { token: h.token, body: { kind: 'url', ...body } });
  const cases = [
    [{ text: fixture('vip88.source.txt') }, 'invalid_sourceUrl'],
    [{ text: fixture('vip88.source.txt'), sourceUrl: 'javascript:alert(1)' }, 'invalid_sourceUrl'],
    [{ text: '  ', sourceUrl: PAGE_URL }, 'invalid_text'],
  ];
  for (const [body, code] of cases) {
    const r = await post(body);
    assert.deepEqual([r.status, r.json.error.code], [400, code], JSON.stringify(body).slice(0, 80));
  }
  assert.equal((await post({ text: ' ', sourceUrl: PAGE_URL })).json.error.message, '先抓取网页，或者把正文粘进来');
  assert.equal(up.requests.length, 0);

  up.state.completions.push(fixture('vip88.output.txt'));
  const r = await post({ text: fixture('vip88.source.txt'), sourceUrl: PAGE_URL, want: 'virtual' });
  assert.equal(r.status, 200, r.text);
  const done = r.of('done')[0].data;
  assert.deepEqual(done.draft.source, { kind: 'url', text: fixture('vip88.source.txt'), url: PAGE_URL });
  assert.ok(done.draft.memberships[0].span, '网页正文和粘贴一样核对依据');
  assert.ok(!done.draft.benefits.some((b) => b.badges.includes('ev_unverified')));
  assert.equal(up.requests.length, 1, '只问了模型，没去抓网址');
  assert.ok(up.lastBody().messages[0].content.includes('优酷视频年卡，开通后去优酷 App'));

  const applied = await h.a.post('/asset-import/apply', applyBodyOf(done, { clientId: 'url-apply-1' }), h.auth);
  assert.equal(applied.status, 200, applied.text);
  const card = (await h.a.get('/changes?since=0', h.auth)).json.memberships.find((m) => m.name === '88VIP');
  assert.equal(card.origin.src, 'ai_url');
  const recent = (await h.a.get('/asset-import/recent', h.auth)).json.items;
  assert.deepEqual(recent.map((x) => x.sourceKind), ['url']);
  assert.match(h.srv.stdout(), /\[import\] 识别 anthropic\/claude-sonnet-5 网页正文 \d+ 字/);
  assert.ok(!h.srv.stdout().includes('vip.example'), 'info 日志里没有网址');

  await h.srv.stop();
  const db = openDb(h.srv.dataDir);
  try {
    const row = db.get('SELECT source_kind, source_url, status FROM ai_imports WHERE id = ?', done.importId);
    assert.deepEqual({ ...row }, { source_kind: 'url', source_url: PAGE_URL, status: 'applied' });
  } finally {
    db.close();
  }
});
