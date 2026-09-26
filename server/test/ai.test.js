'use strict';

// AI 渠道。这个套件钉死三件事：
//
//   · 密钥永远不出服务端（列表/详情只给 hasKey + 尾 4 位，响应正文里搜不到明文）
//   · 上游协议按 kind 走对（anthropic: /v1/messages + x-api-key；openai:
//     /chat/completions + Bearer），SSE 被切碎成 40 字节一片也要拼得回来
//   · 自家流格式恒为 delta* → done | error，报告落库，分类只吃候选集里的 id
//
// 上游是 test/fake_upstream.js 里两个**真的** HTTP 服务器，没有 stub、没有打桩。

const test = require('node:test');
const assert = require('node:assert/strict');

const { household } = require('./fixtures');
const { startFakeAnthropic, startFakeOpenai } = require('./fake_upstream');

const ANT_KEY = 'sk-ant-secret-1234';
const OAI_KEY = 'sk-oai-secret-5678';

// ------------------------------------------------------------------ helpers

function ok(r, what) {
  assert.ok(r.status >= 200 && r.status < 300, `${what} → ${r.status} ${r.text}`);
  return r.json;
}

/** SSE 响应体 → [{event, data}]，注释行（心跳）忽略。 */
function parseSse(text) {
  const out = [];
  for (const block of text.split('\n\n')) {
    let event = null;
    let data = '';
    for (const line of block.split('\n')) {
      if (!line || line.startsWith(':')) continue;
      if (line.startsWith('event:')) event = line.slice(6).trim();
      else if (line.startsWith('data:')) data += line.slice(5).trim();
    }
    if (event) out.push({ event, data: data ? JSON.parse(data) : null });
  }
  return out;
}

/** POST 一个 SSE 接口，读到流结束。非 200 时 events 为空，看 .json。 */
async function sse(base, path, { token, body } = {}) {
  const r = await fetch(`${base}/api/v1${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body ?? {}),
  });
  const text = await r.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    /* SSE 正文不是 JSON */
  }
  return {
    status: r.status,
    contentType: r.headers.get('content-type') || '',
    text,
    json,
    events: r.status === 200 ? parseSse(text) : [],
    of: (name) => parseSse(text).filter((e) => e.event === name),
  };
}

/** 建一个指向假上游的渠道，返回它的行 JSON。 */
async function addProvider(h, body) {
  return ok(await h.a.post('/ai/providers', body, h.auth), 'POST /ai/providers').provider;
}

const antProvider = (up, extra = {}) => ({
  name: 'cc-trans 测试',
  kind: 'anthropic',
  baseUrl: up.base,
  apiKey: ANT_KEY,
  model: 'claude-sonnet-5',
  isDefault: true,
  ...extra,
});

const oaiProvider = (up, extra = {}) => ({
  name: '硅基流动 测试',
  kind: 'openai',
  baseUrl: `${up.base}/v1`,
  apiKey: OAI_KEY,
  model: 'Qwen/Qwen3-32B',
  isDefault: true,
  ...extra,
});

/** 往账本里塞几笔，好让财务上下文有东西可写。 */
async function seedLedger(h) {
  const food = h.categories.find((c) => c.name === '餐饮' && c.kind === 'expense');
  const salary = h.categories.find((c) => c.name === '工资' && c.kind === 'income');
  assert.ok(food && salary, '种子类别里应该有 餐饮/工资');
  const month = new Date();
  const ym = `${month.getFullYear()}-${String(month.getMonth() + 1).padStart(2, '0')}`;
  const at = (d, hh) => `${ym}-${String(d).padStart(2, '0')}T${hh}:00:00+08:00`;

  ok(await h.tx({ type: 'expense', amountCents: 12345, occurredAt: at(3, '12'), fundId: h.fund.id, accountId: h.account.id, categoryId: food.id, merchant: '楼下面馆', note: '午饭' }), 'T1');
  ok(await h.tx({ type: 'expense', amountCents: 6600, occurredAt: at(4, '19'), fundId: h.fund.id, accountId: h.account.id, categoryId: food.id, merchant: '便利店' }), 'T2');
  ok(await h.tx({ type: 'income', amountCents: 900000, occurredAt: at(5, '09'), fundId: h.fund.id, accountId: h.account.id, categoryId: salary.id, merchant: '公司' }), 'T3');
  return { ym, food, salary };
}

// -------------------------------------------------------------------- 预设

test('GET /ai/presets 至少 8 个预设，cc-trans 在列且带填写提示', async (t) => {
  const h = await household(t);
  const items = ok(await h.a.get('/ai/presets', h.auth), 'GET /ai/presets').items;

  assert.ok(items.length >= 8, `预设只有 ${items.length} 个`);
  const keys = items.map((p) => p.key);
  for (const k of ['cc-trans', 'siliconflow', 'deepseek', 'moonshot', 'zhipu', 'openai', 'anthropic', 'ollama']) {
    assert.ok(keys.includes(k), `缺预设 ${k}`);
  }
  const cc = items.find((p) => p.key === 'cc-trans');
  assert.equal(cc.kind, 'anthropic');
  assert.equal(cc.model, 'claude-sonnet-5');
  assert.match(cc.baseUrl, /^http:\/\//);
  assert.ok(cc.hint && cc.hint.includes('cct-'), 'cc-trans 应该提示客户端令牌是 cct- 开头');

  for (const p of items) {
    assert.ok(['anthropic', 'openai'].includes(p.kind), `${p.key} kind 非法`);
    assert.ok(p.name && p.baseUrl && p.model, `${p.key} 预设字段不全`);
    if (p.kind === 'openai') assert.ok(/\/v\d|\/paas\//.test(p.baseUrl), `${p.key} 的 baseUrl 应该已经含 /v1`);
  }
  // 预设是静态清单，不该泄漏任何密钥字段
  assert.ok(!JSON.stringify(items).includes('apiKey'));
});

// ------------------------------------------------------------- providers CRUD

test('providers CRUD：密钥只进不出、默认渠道互斥、成员改不了', async (t) => {
  const h = await household(t);

  const created = ok(
    await h.a.post('/ai/providers', { name: 'cc-trans', kind: 'anthropic', baseUrl: 'http://nas:8787/', apiKey: ANT_KEY, model: 'claude-sonnet-5', isDefault: true }, h.auth),
    'POST /ai/providers',
  );
  const p1 = created.provider;
  assert.equal(p1.name, 'cc-trans');
  assert.equal(p1.baseUrl, 'http://nas:8787', '末尾斜杠要去掉');
  assert.equal(p1.hasKey, true);
  assert.equal(p1.keyTail, '1234');
  assert.equal(p1.isDefault, true);
  assert.equal(p1.enabled, true);
  assert.equal(p1.apiKey, undefined);

  const list = await h.a.get('/ai/providers', h.auth);
  assert.ok(!list.text.includes('sk-ant-secret'), '列表正文里出现了明文密钥');
  assert.ok(!list.text.includes('enc:v1:'), '列表正文里出现了密文');
  assert.equal(ok(list, 'GET /ai/providers').items[0].keyTail, '1234');

  // PATCH 不带 apiKey / 带空串都不改密钥
  const renamed = ok(await h.a.patch(`/ai/providers/${p1.id}`, { name: 'cc-trans（NAS）' }, h.auth), 'PATCH name').provider;
  assert.equal(renamed.name, 'cc-trans（NAS）');
  assert.equal(renamed.keyTail, '1234');
  assert.equal(ok(await h.a.patch(`/ai/providers/${p1.id}`, { apiKey: '' }, h.auth), 'PATCH apiKey:""').provider.keyTail, '1234');
  // 换密钥才换尾号
  assert.equal(ok(await h.a.patch(`/ai/providers/${p1.id}`, { apiKey: 'cct-brand-new-9999' }, h.auth), 'PATCH apiKey').provider.keyTail, '9999');

  // 默认渠道互斥
  const p2 = await addProvider(h, { name: '硅基流动', kind: 'openai', baseUrl: 'https://api.siliconflow.cn/v1', apiKey: 'sk-sf-0000', model: 'Qwen/Qwen3-32B', isDefault: true });
  assert.equal(p2.isDefault, true);
  const after = ok(await h.a.get('/ai/providers', h.auth), 'GET after default switch').items;
  assert.equal(after.filter((p) => p.isDefault).length, 1, '同时只能有一个默认渠道');
  assert.equal(after.find((p) => p.id === p1.id).isDefault, false);

  // 校验
  assert.equal((await h.a.post('/ai/providers', { name: 'x', kind: 'gemini', baseUrl: 'https://x/v1', apiKey: 'k', model: 'm' }, h.auth)).json.error.code, 'invalid_kind');
  assert.equal((await h.a.post('/ai/providers', { name: 'x', kind: 'openai', baseUrl: 'ftp://x/v1', apiKey: 'k', model: 'm' }, h.auth)).json.error.code, 'invalid_baseUrl');
  assert.equal((await h.a.post('/ai/providers', { name: 'x', kind: 'openai', baseUrl: 'https://api.deepseek.com/v1', model: 'deepseek-chat' }, h.auth)).json.error.code, 'invalid_apiKey');
  // 本机 Ollama 可以没有密钥
  const ollama = await addProvider(h, { name: 'Ollama', kind: 'openai', baseUrl: 'http://host.docker.internal:11434/v1', model: 'qwen3:8b' });
  assert.equal(ollama.hasKey, false);
  assert.equal(ollama.keyTail, null);

  // 成员只能看，不能改
  ok(await h.a.post('/members', { username: 'xiaohong', password: 'hunter22', displayName: '小红', role: 'member' }, h.auth), 'POST /members');
  const memberToken = ok(await h.a.post('/auth/login', { username: 'xiaohong', password: 'hunter22' }), 'login').token;
  const mAuth = { token: memberToken };
  assert.equal((await h.a.get('/ai/providers', mAuth)).status, 200);
  assert.equal((await h.a.post('/ai/providers', { name: 'x', kind: 'openai', baseUrl: 'https://x/v1', apiKey: 'k', model: 'm' }, mAuth)).status, 403);
  assert.equal((await h.a.patch(`/ai/providers/${p1.id}`, { name: 'y' }, mAuth)).status, 403);
  assert.equal((await h.a.del(`/ai/providers/${p1.id}`, mAuth)).status, 403);

  // 删除
  assert.equal((await h.a.del(`/ai/providers/${ollama.id}`, h.auth)).status, 200);
  assert.ok(!ok(await h.a.get('/ai/providers', h.auth), 'GET after delete').items.some((p) => p.id === ollama.id));
  assert.equal((await h.a.del(`/ai/providers/${ollama.id}`, h.auth)).status, 404);
});

// -------------------------------------------------------------------- /test

test('POST /ai/providers/:id/test：通了给 ok:true + 样例，上游 500 给 ok:false', async (t) => {
  const up = await startFakeAnthropic({ key: ANT_KEY, completion: 'OK' });
  t.after(() => up.stop());
  const h = await household(t);
  const p = await addProvider(h, antProvider(up));

  const good = ok(await h.a.post(`/ai/providers/${p.id}/test`, {}, h.auth), 'POST /test');
  assert.equal(good.ok, true);
  assert.equal(good.model, 'claude-sonnet-5');
  assert.equal(typeof good.latencyMs, 'number');
  assert.ok(good.sample.includes('OK'), `sample=${good.sample}`);
  assert.equal(up.lastBody().stream, undefined, '测试用非流式');
  assert.equal(up.lastHeaders()['x-api-key'], ANT_KEY);

  up.state.status = 500;
  const bad = await h.a.post(`/ai/providers/${p.id}/test`, {}, h.auth);
  assert.equal(bad.status, 200, '上游坏掉不是我们的 5xx');
  assert.equal(bad.json.ok, false);
  assert.match(bad.json.message, /500/);
  assert.ok(!bad.text.includes(ANT_KEY));
});

// -------------------------------------------------------------------- /chat

test('POST /ai/chat（anthropic）：delta 拼接 = 上游原文，system 里带着本月账本', async (t) => {
  const up = await startFakeAnthropic({ key: ANT_KEY });
  t.after(() => up.stop());
  const h = await household(t);
  await seedLedger(h);
  await addProvider(h, antProvider(up));

  const r = await sse(h.srv.base, '/ai/chat', { token: h.token, body: { messages: [{ role: 'user', content: '我这个月花超了吗？' }] } });
  assert.equal(r.status, 200);
  assert.match(r.contentType, /text\/event-stream/);

  const deltas = r.of('delta');
  assert.ok(deltas.length >= 3, `只收到 ${deltas.length} 个 delta`);
  assert.equal(deltas.map((d) => d.data.text).join(''), up.text());

  const done = r.of('done');
  assert.equal(done.length, 1);
  assert.equal(done[0].data.model, 'claude-sonnet-5');
  assert.equal(done[0].data.usage.input, 123);
  assert.equal(done[0].data.usage.output, 45);
  assert.ok(done[0].data.providerId);
  assert.equal(r.of('error').length, 0);

  // 上游收到的东西
  const body = up.lastBody();
  assert.equal(body.stream, true);
  assert.equal(body.model, 'claude-sonnet-5');
  assert.equal(body.messages.length, 1);
  assert.equal(body.messages[0].role, 'user');
  assert.ok(typeof body.max_tokens === 'number' && body.max_tokens > 0);
  assert.equal(up.lastHeaders()['anthropic-version'], '2023-06-01');
  assert.equal(up.lastHeaders()['x-api-key'], ANT_KEY);

  // 财务上下文真的注进去了
  assert.ok(body.system.includes('餐饮'), 'system 里没有类别名：\n' + body.system);
  assert.ok(body.system.includes(h.fund.name), 'system 里没有基金名');
  assert.ok(body.system.includes('¥189.45'), 'system 里没有本月支出合计 ¥189.45');
  assert.ok(body.system.length <= 8000, `system 太长了：${body.system.length}`);
});

test('POST /ai/chat（openai）：Bearer 头 + system 作为第一条 message', async (t) => {
  const up = await startFakeOpenai({ key: OAI_KEY, parts: ['支出', '还行', '，继续保持。'] });
  t.after(() => up.stop());
  const h = await household(t);
  await addProvider(h, oaiProvider(up));

  const r = await sse(h.srv.base, '/ai/chat', {
    token: h.token,
    body: { messages: [{ role: 'user', content: '帮我看看' }, { role: 'assistant', content: '好的' }, { role: 'user', content: '继续' }] },
  });
  assert.equal(r.status, 200);
  assert.equal(r.of('delta').map((d) => d.data.text).join(''), up.text());
  assert.equal(r.of('done')[0].data.usage.input, 123);
  assert.equal(r.of('done')[0].data.usage.output, 45);

  assert.equal(up.lastHeaders().authorization, `Bearer ${OAI_KEY}`);
  assert.equal(up.lastHeaders()['x-api-key'], undefined);
  const body = up.lastBody();
  assert.equal(body.stream, true);
  assert.equal(body.messages[0].role, 'system');
  assert.ok(body.messages[0].content.includes('理财'), 'system 人设丢了');
  assert.deepEqual(body.messages.slice(1).map((m) => m.role), ['user', 'assistant', 'user']);
  assert.equal(up.requests[0].url, '/v1/chat/completions');
});

// ------------------------------------------------------------------ /report

test('POST /ai/report 落 ai_reports，GET /ai/reports?month= 读得回来', async (t) => {
  const up = await startFakeAnthropic({ key: ANT_KEY, parts: ['## 本月概览\n', '花得比上月少。\n', '## 下月建议\n少点外卖。'] });
  t.after(() => up.stop());
  const h = await household(t);
  await seedLedger(h);
  await addProvider(h, antProvider(up));

  const r = await sse(h.srv.base, '/ai/report?month=2026-09', { token: h.token });
  assert.equal(r.status, 200);
  const text = r.of('delta').map((d) => d.data.text).join('');
  assert.equal(text, up.text());
  const done = r.of('done')[0].data;
  assert.ok(done.reportId, 'done 里没有 reportId');
  assert.ok(done.usage);

  const items = ok(await h.a.get('/ai/reports?month=2026-09', h.auth), 'GET /ai/reports').items;
  assert.equal(items.length, 1);
  assert.equal(items[0].id, done.reportId);
  assert.equal(items[0].month, '2026-09');
  assert.equal(items[0].content, up.text());
  assert.ok(items[0].createdAt);

  // 别的月份没有
  assert.equal(ok(await h.a.get('/ai/reports?month=2026-08', h.auth), 'GET other month').items.length, 0);
  // 不带 month 给全部
  assert.equal(ok(await h.a.get('/ai/reports', h.auth), 'GET all').items.length, 1);
  // 报告的提示词按月份写死，且不是聊天的那套
  assert.ok(up.lastBody().messages[0].content.includes('2026-09'));
  assert.ok(up.lastBody().system.includes('2026-09'));
});

// ---------------------------------------------------------------- /classify

test('POST /ai/classify：只认候选集里的 id，输出不是 JSON → 502', async (t) => {
  const up = await startFakeOpenai({ key: OAI_KEY });
  t.after(() => up.stop());
  const h = await household(t);
  await addProvider(h, oaiProvider(up));

  const candidates = { categories: [{ id: 'c1', name: '餐饮' }, { id: 'c2', name: '交通' }], funds: [{ id: 'f1', name: '家庭公共基金' }] };
  const ask = (body) => h.a.post('/ai/classify', { text: '支付宝支付 35.00 元', merchant: '楼下面馆', amountCents: 3500, candidates, ...body }, h.auth);

  up.state.completion = '{"categoryId":"c1","fundId":"f1","confidence":0.9,"reason":"面馆是餐饮"}';
  const good = ok(await ask({}), 'POST /ai/classify');
  assert.equal(good.categoryId, 'c1');
  assert.equal(good.fundId, 'f1');
  assert.equal(good.confidence, 0.9);
  assert.equal(good.reason, '面馆是餐饮');
  assert.equal(up.lastBody().stream, undefined, '分类不走流式');
  // 候选名单进了提示词
  assert.ok(JSON.stringify(up.lastBody().messages).includes('餐饮'));
  assert.ok(JSON.stringify(up.lastBody().messages).includes('楼下面馆'));

  // 代码块包着的 JSON 也要能吃下
  up.state.completion = '```json\n{"categoryId":"c2","fundId":"f1","confidence":0.42,"reason":"打车"}\n```';
  assert.equal(ok(await ask({}), 'fenced json').categoryId, 'c2');

  // 不在候选集里的 id → null（不是 500，也不是照抄）
  up.state.completion = '{"categoryId":"c-not-exist","fundId":"f1","confidence":0.8,"reason":"瞎猜"}';
  const bogus = ok(await ask({}), 'bogus id');
  assert.equal(bogus.categoryId, null);
  assert.equal(bogus.fundId, 'f1');

  // 模型开始说人话 → 502 ai_bad_output
  up.state.completion = '我觉得这大概是餐饮吧，你说呢？';
  const bad = await ask({});
  assert.equal(bad.status, 502);
  assert.equal(bad.json.error.code, 'ai_bad_output');

  // 上游不认 response_format（很多 OpenAI 兼容端都不认）→ 自动退一步重试一次
  up.state.completion = '{"categoryId":"c1","fundId":"f1","confidence":0.7,"reason":"退一步也能用"}';
  up.state.rejectJsonMode = true;
  const before = up.requests.length;
  assert.equal(ok(await ask({}), 'json 模式被拒后重试').categoryId, 'c1');
  const tries = up.requests.slice(before);
  assert.equal(tries.length, 2, 'JSON 模式被 400 之后应该正好重试一次');
  assert.deepEqual(tries[0].body.response_format, { type: 'json_object' });
  assert.equal(tries[1].body.response_format, undefined, '重试那次不该再带 response_format');
  up.state.rejectJsonMode = false;

  // 上游挂了 → 502 ai_upstream
  up.state.status = 503;
  const down = await ask({});
  assert.equal(down.status, 502);
  assert.equal(down.json.error.code, 'ai_upstream');
  assert.ok(!down.text.includes(OAI_KEY));
});

// ------------------------------------------------------------------ 失败面

test('上游 500 → SSE error 事件；一个渠道都没有 → 400 no_provider', async (t) => {
  const up = await startFakeAnthropic({ key: ANT_KEY });
  t.after(() => up.stop());
  const h = await household(t);

  // 还没配渠道
  const none = await sse(h.srv.base, '/ai/chat', { token: h.token, body: { messages: [{ role: 'user', content: '在吗' }] } });
  assert.equal(none.status, 400);
  assert.equal(none.json.error.code, 'no_provider');

  const p = await addProvider(h, antProvider(up));
  up.state.status = 500;
  const r = await sse(h.srv.base, '/ai/chat', { token: h.token, body: { messages: [{ role: 'user', content: '在吗' }] } });
  assert.equal(r.status, 200, 'SSE 已经开了，错误只能从流里出去');
  const errs = r.of('error');
  assert.equal(errs.length, 1, `error 事件 ${errs.length} 个：${r.text}`);
  assert.match(errs[0].data.message, /500/);
  assert.equal(r.of('done').length, 0);
  assert.ok(!r.text.includes(ANT_KEY));

  // 指名一个不存在的渠道 → 404；停用的渠道不会被自动选中
  const missing = await sse(h.srv.base, '/ai/chat', { token: h.token, body: { providerId: 'nope', messages: [{ role: 'user', content: 'hi' }] } });
  assert.equal(missing.status, 404);
  ok(await h.a.patch(`/ai/providers/${p.id}`, { enabled: false }, h.auth), 'disable');
  const disabled = await sse(h.srv.base, '/ai/chat', { token: h.token, body: { messages: [{ role: 'user', content: 'hi' }] } });
  assert.equal(disabled.status, 400);
  assert.equal(disabled.json.error.code, 'no_provider');

  // 消息校验
  const tooMany = await sse(h.srv.base, '/ai/chat', { token: h.token, body: { messages: Array.from({ length: 41 }, () => ({ role: 'user', content: 'x' })) } });
  assert.equal(tooMany.status, 400);
  assert.equal((await sse(h.srv.base, '/ai/chat', { token: h.token, body: { messages: [] } })).status, 400);
  assert.equal((await sse(h.srv.base, '/ai/chat', { token: h.token, body: { messages: [{ role: 'system', content: 'x' }] } })).status, 400);
});

test('上游把错误塞在已经 200 的流里 → 照样转成 error 事件', async (t) => {
  const up = await startFakeAnthropic({ key: ANT_KEY });
  t.after(() => up.stop());
  up.state.streamError = true;
  const h = await household(t);
  await addProvider(h, antProvider(up));

  const r = await sse(h.srv.base, '/ai/chat', { token: h.token, body: { messages: [{ role: 'user', content: '在吗' }] } });
  assert.equal(r.status, 200);
  assert.ok(r.of('delta').length >= 1, '错误之前那几个 delta 不该被吞掉');
  assert.equal(r.of('done').length, 0, '半路崩了就不能再发 done');
  assert.equal(r.of('error').length, 1);
  assert.match(r.of('error')[0].data.message, /服务繁忙/);
});

test('客户端半路断开 → 上游请求也被中止', async (t) => {
  const up = await startFakeAnthropic({ key: ANT_KEY });
  t.after(() => up.stop());
  up.state.hang = true;
  const h = await household(t);
  await addProvider(h, antProvider(up));

  const ctl = new AbortController();
  const r = await fetch(`${h.srv.base}/api/v1/ai/chat`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${h.token}` },
    body: JSON.stringify({ messages: [{ role: 'user', content: '慢慢说' }] }),
    signal: ctl.signal,
  });
  assert.equal(r.status, 200);
  const reader = r.body.getReader();
  // 读到第一个 delta 就走人
  let seen = '';
  for (let i = 0; i < 20 && !seen.includes('event: delta'); i++) {
    const { value, done } = await reader.read();
    if (done) break;
    seen += Buffer.from(value).toString('utf8');
  }
  assert.ok(seen.includes('event: delta'), `没等到 delta：${seen}`);
  ctl.abort();

  for (let i = 0; i < 200 && up.state.aborted === 0; i++) await new Promise((res) => setTimeout(res, 10));
  assert.ok(up.state.aborted > 0, '客户端走了，上游连接却还挂着');
});

// ------------------------------------------------------------------ 两道闸门

test('限流：AI_PER_MIN=2 时第三次 → 429，而且是按人算的', async (t) => {
  const up = await startFakeOpenai({ key: OAI_KEY });
  t.after(() => up.stop());
  up.state.completion = '{"categoryId":"c1","fundId":"f1","confidence":0.9,"reason":"ok"}';
  const h = await household(t, { AI_PER_MIN: '2' });
  await addProvider(h, oaiProvider(up));

  const candidates = { categories: [{ id: 'c1', name: '餐饮' }], funds: [{ id: 'f1', name: '公共' }] };
  const ask = (auth) => h.a.post('/ai/classify', { text: '支付宝支付 35.00 元', candidates }, auth);

  assert.equal((await ask(h.auth)).status, 200);
  assert.equal((await ask(h.auth)).status, 200);
  const third = await ask(h.auth);
  assert.equal(third.status, 429);
  assert.equal(third.json.error.code, 'rate_limited');

  // 同一个桶：换个 AI 接口照样挡，并且是干净的 JSON 错误 —— 不是 SSE 里的 error
  const chat = await sse(h.srv.base, '/ai/chat', { token: h.token, body: { messages: [{ role: 'user', content: '在吗' }] } });
  assert.equal(chat.status, 429);
  assert.equal(chat.json.error.code, 'rate_limited');
  assert.equal(chat.events.length, 0);
  // 桶空了也不许多打一次上游
  assert.equal(up.requests.length, 2, `上游被打了 ${up.requests.length} 次，限流没挡在花钱之前`);

  // 不花上游钱的接口不受影响
  assert.equal((await h.a.get('/ai/providers', h.auth)).status, 200);
  assert.equal((await h.a.get('/ai/presets', h.auth)).status, 200);

  // 按人算：小红有自己的额度（家里人都在同一个公网 IP 后面，按 IP 会互相挤掉）
  ok(await h.a.post('/members', { username: 'xiaohong', password: 'hunter22', displayName: '小红', role: 'member' }, h.auth), 'POST /members');
  const her = { token: ok(await h.a.post('/auth/login', { username: 'xiaohong', password: 'hunter22' }), 'login').token };
  assert.equal((await ask(her)).status, 200, '限流桶不该是全家共用的');
});

test('并发：AI_MAX_STREAMS=1 时第二条流 → 503 ai_busy，前一条断了名额就还回来', async (t) => {
  const up = await startFakeAnthropic({ key: ANT_KEY });
  t.after(() => up.stop());
  up.state.hang = true; // 第一条流发完第一片就赖着不走
  const h = await household(t, { AI_MAX_STREAMS: '1', AI_PER_MIN: '500' });
  await addProvider(h, antProvider(up));

  const ctl = new AbortController();
  const first = await fetch(`${h.srv.base}/api/v1/ai/chat`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${h.token}` },
    body: JSON.stringify({ messages: [{ role: 'user', content: '慢慢说' }] }),
    signal: ctl.signal,
  });
  assert.equal(first.status, 200);
  const reader = first.body.getReader();
  let seen = '';
  for (let i = 0; i < 20 && !seen.includes('event: delta'); i++) {
    const { value, done } = await reader.read();
    if (done) break;
    seen += Buffer.from(value).toString('utf8');
  }
  assert.ok(seen.includes('event: delta'), '第一条流没真正跑起来，后面的断言不算数');

  const second = await sse(h.srv.base, '/ai/chat', { token: h.token, body: { messages: [{ role: 'user', content: '我也要' }] } });
  assert.equal(second.status, 503);
  assert.equal(second.json.error.code, 'ai_busy');
  assert.ok(second.json.error.message.includes('1'), '错误里应该写明上限');
  assert.equal(up.requests.length, 1, '被挡下的那条不该打到上游');

  // 名额在 finally 里还：客户端半路跑了也一样
  ctl.abort();
  up.state.hang = false;
  let third = null;
  for (let i = 0; i < 30; i++) {
    third = await sse(h.srv.base, '/ai/chat', { token: h.token, body: { messages: [{ role: 'user', content: '再来' }] } });
    if (third.status === 200) break;
    await new Promise((r) => setTimeout(r, 25));
  }
  assert.equal(third.status, 200, '第一条断了之后名额没还回来');
  assert.equal(third.of('done').length, 1);
});

// -------------------------------------------------- review 修复轮 1 的三条

test('上游只认 max_completion_tokens（gpt-5/o 系列）→ 换字段重试一次，流式与非流式都要', async (t) => {
  const up = await startFakeOpenai({ key: OAI_KEY });
  t.after(() => up.stop());
  up.state.rejectMaxTokens = true;
  const h = await household(t);
  await addProvider(h, oaiProvider(up, { model: 'gpt-5-mini' }));

  // ① 流式：delta 一个不少，且没有因为重试而重复
  const r = await sse(h.srv.base, '/ai/chat', { token: h.token, body: { messages: [{ role: 'user', content: '在吗' }] } });
  assert.equal(r.status, 200);
  assert.equal(r.of('delta').map((d) => d.data.text).join(''), up.text(), '重试之后文本应该完整且不重复');
  assert.equal(r.of('done').length, 1);
  assert.equal(r.of('error').length, 0);

  assert.equal(up.requests.length, 2, `应该正好两次往返，实际 ${up.requests.length}`);
  assert.equal(up.requests[0].body.max_tokens, 2048);
  assert.equal(up.requests[0].body.max_completion_tokens, undefined, '第一次该发老字段');
  assert.equal(up.requests[1].body.max_tokens, undefined, '重试那次不该再带 max_tokens');
  assert.equal(up.requests[1].body.max_completion_tokens, 2048);
  assert.equal(up.requests[1].body.stream, true, '重试那次仍然是流式');

  // ② 非流式（classify）：同样只多花一次往返，JSON 模式不受牵连
  const before = up.requests.length;
  up.state.completion = '{"categoryId":"c1","fundId":"f1","confidence":0.8,"reason":"ok"}';
  const candidates = { categories: [{ id: 'c1', name: '餐饮' }], funds: [{ id: 'f1', name: '公共' }] };
  const out = ok(await h.a.post('/ai/classify', { text: '支付 35 元', candidates }, h.auth), 'POST /ai/classify');
  assert.equal(out.categoryId, 'c1');
  const tries = up.requests.slice(before);
  assert.equal(tries.length, 2, `classify 应该只多花一次往返，实际 ${tries.length}`);
  assert.equal(tries[0].body.max_completion_tokens, undefined);
  assert.equal(tries[1].body.max_completion_tokens, 300);
  assert.deepEqual(tries[1].body.response_format, { type: 'json_object' }, 'JSON 模式不该被这次退让顺手丢掉');

  // ③ 上游正常时不该有任何多余往返
  up.state.rejectMaxTokens = false;
  const n = up.requests.length;
  ok(await h.a.post('/ai/classify', { text: '再来一笔', candidates }, h.auth), '正常 classify');
  assert.equal(up.requests.length - n, 1, '上游没报错就不该重试');
});

test('messages 规整：开头的 assistant 丢掉、相邻同角色合并、全是 assistant → 400', async (t) => {
  const up = await startFakeAnthropic({ key: ANT_KEY });
  t.after(() => up.stop());
  const h = await household(t);
  await addProvider(h, antProvider(up));

  const r = await sse(h.srv.base, '/ai/chat', {
    token: h.token,
    body: { messages: [{ role: 'assistant', content: '上一轮的回复' }, { role: 'user', content: '第一句' }, { role: 'user', content: '第二句' }] },
  });
  assert.equal(r.status, 200);
  const sent = up.lastBody().messages;
  assert.equal(sent.length, 1, `应该只剩一条合并后的 user，实际 ${JSON.stringify(sent)}`);
  assert.equal(sent[0].role, 'user');
  assert.equal(sent[0].content, '第一句\n\n第二句');
  assert.ok(!JSON.stringify(sent).includes('上一轮的回复'), '开头的 assistant 应该被丢掉');

  // 中间的 assistant 是正常轮次，不能动
  const r2 = await sse(h.srv.base, '/ai/chat', {
    token: h.token,
    body: { messages: [{ role: 'user', content: 'A' }, { role: 'assistant', content: 'B' }, { role: 'user', content: 'C' }] },
  });
  assert.equal(r2.status, 200);
  assert.deepEqual(up.lastBody().messages.map((m) => m.role), ['user', 'assistant', 'user']);

  // 一条 user 都没有 → 400，而不是把最后那条 assistant 发出去
  const n = up.requests.length;
  const bad = await sse(h.srv.base, '/ai/chat', { token: h.token, body: { messages: [{ role: 'assistant', content: 'X' }, { role: 'assistant', content: 'Y' }] } });
  assert.equal(bad.status, 400);
  assert.equal(bad.json.error.code, 'invalid_messages');
  assert.equal(up.requests.length, n, '这种请求根本不该打到上游');
});

test('短密钥不回显尾号：hasKey 仍为 true，keyTail 是空串', async (t) => {
  const h = await household(t);
  const short = await addProvider(h, { name: '短密钥', kind: 'openai', baseUrl: 'https://api.deepseek.com/v1', apiKey: 'abc123', model: 'deepseek-chat' });
  assert.equal(short.hasKey, true);
  assert.equal(short.keyTail, '', '6 位的密钥不该露出「尾 4 位」');

  const long = await addProvider(h, { name: '长密钥', kind: 'openai', baseUrl: 'https://api.deepseek.com/v1', apiKey: 'sk-12345678', model: 'deepseek-chat' });
  assert.equal(long.keyTail, '5678');

  const list = await h.a.get('/ai/providers', h.auth);
  assert.ok(!list.text.includes('abc123'), '短密钥居然出现在列表里');
  assert.ok(!list.text.includes('sk-12345678'));
});

test('POST /ai/chat：财务上下文带一行实物估值，计入额跟着全局开关走；没有物品不写', async (t) => {
  const up = await startFakeAnthropic({ key: ANT_KEY });
  t.after(() => up.stop());
  const h = await household(t);
  await addProvider(h, antProvider(up));
  const d = new Date();
  const today = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  const system = async () => {
    const r = await sse(h.srv.base, '/ai/chat', { token: h.token, body: { messages: [{ role: 'user', content: '家里的东西值多少？' }] } });
    assert.equal(r.status, 200, r.text);
    return up.lastBody().system;
  };

  assert.ok(!(await system()).includes('【实物估值】'), '一件物品都没有就不写');

  // 今天买的：估值 = 原价。数码按类别计入，家电不计入。
  ok(await h.a.post('/assets', { name: '手机', category: 'digital', priceCents: 599900, purchasedOn: today }, h.auth), '手机');
  ok(await h.a.post('/assets', { name: '冰箱', category: 'appliance', priceCents: 320000, purchasedOn: today }, h.auth), '冰箱');
  const on = await system();
  assert.ok(on.includes('【实物估值】¥9,199.00（计入 ¥5,999.00）'), on);
  assert.ok(on.includes('【净资产】¥5,999.00'), '净资产里含计入的那部分');

  ok(await h.a.patch('/settings', { assets: { netWorthIncludesPhysical: false } }, h.auth), '关掉全局开关');
  const off = await system();
  assert.ok(off.includes('【实物估值】¥9,199.00（计入 ¥0.00）'), off);
  assert.ok(off.includes('【净资产】¥0.00'), off);
});

test('extra.requestExtras：只收白名单参数，存下后对话请求体里带上；importMaxTokens 有范围', async (t) => {
  const up = await startFakeOpenai({ key: OAI_KEY });
  t.after(() => up.stop());
  const h = await household(t);
  const p = await addProvider(h, oaiProvider(up));

  const bad = await h.a.patch(`/ai/providers/${p.id}`, { extra: { requestExtras: { temperature: 0.2, model: 'hack' } } }, h.auth);
  assert.equal(bad.status, 400, bad.text);
  assert.equal(bad.json.error.code, 'invalid_extra');
  assert.match(bad.json.error.message, /model/);
  const tooBig = await h.a.patch(`/ai/providers/${p.id}`, { extra: { importMaxTokens: 100 } }, h.auth);
  assert.equal(tooBig.json.error.code, 'invalid_extra');

  const saved = ok(
    await h.a.patch(`/ai/providers/${p.id}`, { extra: { requestExtras: { temperature: 0.2, enable_thinking: false }, importMaxTokens: 8000, vision: true } }, h.auth),
    'PATCH extra',
  ).provider;
  assert.deepEqual(saved.extra, { requestExtras: { temperature: 0.2, enable_thinking: false }, importMaxTokens: 8000, vision: true });

  const r = await sse(h.srv.base, '/ai/chat', { token: h.token, body: { messages: [{ role: 'user', content: '在吗' }] } });
  assert.equal(r.status, 200, r.text);
  const body = up.lastBody();
  assert.equal(body.temperature, 0.2);
  assert.equal(body.enable_thinking, false);
  assert.equal(body.max_tokens, 2048, '对话的输出上限不受导入覆盖影响');
  assert.equal(body.importMaxTokens, undefined, 'extra 里别的键不进请求体');
});
