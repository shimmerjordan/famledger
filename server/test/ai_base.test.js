'use strict';

// AI 底座（spec §4「AI 底座」）：适配器直连假上游，不起服务。钉死五件事：
//
//   · 两家的结束原因统一成 stopReason（end / max_tokens / refusal / other），流式、非流式都有
//   · 中性图片块按渠道转：anthropic 图在文字前面；openai 用 data URL 并带 detail:'high'
//   · extra.requestExtras 只注入白名单里的键，盖不掉 model / max_tokens
//   · 上游 400 并给出 max_tokens 合法上限时按上限重试一次
//   · 空闲超时（两片之间太久）抛 IdleTimeoutError 并掐断上游；总时长上限照样在
//
// 对话、分类的行为由 test/ai.test.js 钉着，这里改完它必须还是绿的。

const test = require('node:test');
const assert = require('node:assert/strict');

const providers = require('../src/modules/ai_providers');
const { startFakeAnthropic, startFakeOpenai } = require('./fake_upstream');

const ANT_KEY = 'sk-ant-base';
const OAI_KEY = 'sk-oai-base';

const ant = (up, extra = {}) => ({ kind: 'anthropic', baseUrl: up.base, model: 'claude-sonnet-5', apiKey: ANT_KEY, extra });
const oai = (up, extra = {}) => ({ kind: 'openai', baseUrl: `${up.base}/v1`, model: 'Qwen/Qwen3-32B', apiKey: OAI_KEY, extra });
const ask = (content = '在吗', maxTokens = 100) => ({ messages: [{ role: 'user', content }], maxTokens });

test('stopReason：anthropic 的 end_turn / max_tokens / refusal / 不发，流式与非流式一个口径', async (t) => {
  const up = await startFakeAnthropic({ key: ANT_KEY });
  t.after(() => up.stop());
  const cases = [['end_turn', 'end'], ['stop_sequence', 'end'], ['max_tokens', 'max_tokens'], ['refusal', 'refusal'], ['pause_turn', 'other'], ['', 'other']];
  for (const [raw, want] of cases) {
    up.state.stopReason = raw;
    const s = await providers.streamChat(ant(up), ask());
    assert.equal(s.stopReason, want, `流式 ${raw || '（不发）'}`);
    assert.equal(s.text, up.text());
    const c = await providers.complete(ant(up), ask());
    assert.equal(c.stopReason, want, `非流式 ${raw || '（不发）'}`);
  }
});

test('stopReason：openai 的 stop / length / content_filter / 不发', async (t) => {
  const up = await startFakeOpenai({ key: OAI_KEY });
  t.after(() => up.stop());
  const cases = [['stop', 'end'], ['length', 'max_tokens'], ['content_filter', 'refusal'], ['tool_calls', 'other'], ['', 'other']];
  for (const [raw, want] of cases) {
    up.state.stopReason = raw;
    assert.equal((await providers.streamChat(oai(up), ask())).stopReason, want, `流式 ${raw || '（不发）'}`);
    assert.equal((await providers.complete(oai(up), ask())).stopReason, want, `非流式 ${raw || '（不发）'}`);
  }
});

test('completions 队列：每次请求取一条，取空了回到 parts', async (t) => {
  const up = await startFakeOpenai({ key: OAI_KEY });
  t.after(() => up.stop());
  up.state.completions = ['第一条回答', { text: '第二条', stopReason: 'length' }];
  const a = await providers.streamChat(oai(up), ask());
  assert.equal(a.text, '第一条回答');
  const b = await providers.streamChat(oai(up), ask());
  assert.deepEqual([b.text, b.stopReason], ['第二条', 'max_tokens']);
  const c = await providers.streamChat(oai(up), ask());
  assert.equal(c.text, up.text());
  assert.equal(up.requests.length, 3);
});

test('中性图片块：anthropic 图在文字前面（base64 source）；openai 用 data URL 并带 detail:high；字符串 content 原样', async (t) => {
  const a = await startFakeAnthropic({ key: ANT_KEY });
  const o = await startFakeOpenai({ key: OAI_KEY });
  t.after(() => Promise.all([a.stop(), o.stop()]));
  const blocks = [
    { type: 'text', text: '这是订单截图' },
    { type: 'image', mediaType: 'image/png', data: 'iVBORw0KGgo=' },
    { type: 'bogus', text: '不认识的块丢掉' },
  ];

  await providers.streamChat(ant(a), ask(blocks));
  const antContent = a.lastBody().messages[0].content;
  assert.deepEqual(antContent, [
    { type: 'image', source: { type: 'base64', media_type: 'image/png', data: 'iVBORw0KGgo=' } },
    { type: 'text', text: '这是订单截图' },
  ]);

  await providers.complete(oai(o), ask(blocks));
  const oaiContent = o.lastBody().messages[0].content;
  assert.deepEqual(oaiContent, [
    { type: 'text', text: '这是订单截图' },
    { type: 'image_url', image_url: { url: 'data:image/png;base64,iVBORw0KGgo=', detail: 'high' } },
  ]);

  await providers.streamChat(ant(a), ask('只有字'));
  assert.equal(a.lastBody().messages[0].content, '只有字', '对话、分类的字符串 content 不动');
});

test('extra.requestExtras：只注入白名单里的键，model / max_tokens / messages 盖不掉', async (t) => {
  const up = await startFakeOpenai({ key: OAI_KEY });
  t.after(() => up.stop());
  const extra = { requestExtras: { temperature: 0.1, enable_thinking: false, model: 'hack', max_tokens: 1, messages: [], stream: false, foo: 1 } };
  await providers.streamChat(oai(up, extra), ask('在吗', 300));
  const body = up.lastBody();
  assert.equal(body.temperature, 0.1);
  assert.equal(body.enable_thinking, false);
  assert.equal(body.model, 'Qwen/Qwen3-32B');
  assert.equal(body.max_tokens, 300);
  assert.equal(body.stream, true);
  assert.equal(body.messages[0].content, '在吗');
  assert.equal(body.foo, undefined, '白名单外的键不注入');

  const a = await startFakeAnthropic({ key: ANT_KEY });
  t.after(() => a.stop());
  await providers.complete(ant(a, { requestExtras: { thinking: { type: 'disabled' }, top_k: 5 } }), ask());
  assert.deepEqual(a.lastBody().thinking, { type: 'disabled' });
  assert.equal(a.lastBody().top_k, 5);
  // 没配 extra 的渠道请求体和以前一模一样（对话、分类不变）
  await providers.complete(ant(a), ask());
  assert.deepEqual(Object.keys(a.lastBody()).sort(), ['max_tokens', 'messages', 'model']);
});

test('max_tokens 超出合法范围：按上游给的上限重试一次（两家原话都认），流式与非流式都要', async (t) => {
  const a = await startFakeAnthropic({ key: ANT_KEY });
  const o = await startFakeOpenai({ key: OAI_KEY });
  t.after(() => Promise.all([a.stop(), o.stop()]));
  a.state.maxTokensCap = 8192;
  o.state.maxTokensCap = 4096;

  const s = await providers.streamChat(ant(a), ask('长一点', 12000));
  assert.equal(s.text, a.text());
  assert.deepEqual(a.requests.map((r) => r.body.max_tokens), [12000, 8192]);

  const c = await providers.complete(oai(o), ask('长一点', 12000));
  assert.equal(c.text, o.text());
  assert.deepEqual(o.requests.map((r) => r.body.max_tokens), [12000, 4096]);

  const n = o.requests.length;
  await providers.streamChat(oai(o), ask('再来', 12000));
  assert.deepEqual(o.requests.slice(n).map((r) => r.body.max_tokens), [12000, 4096], '流式也是只多一次往返');

  // 上限比这次要的还大（上游胡说）或者 400 里没写上限：不重试，原样抛出
  assert.equal(providers.maxTokensCap(new providers.UpstreamError(400, 'max_tokens: 100 > 50000, which is the maximum')), 50000);
  assert.equal(providers.maxTokensCap(new providers.UpstreamError(400, 'Invalid max_tokens value, the valid range of max_tokens is [1, 8192]')), 8192);
  assert.equal(providers.maxTokensCap(new providers.UpstreamError(400, 'max_tokens must be less than or equal to 32768')), 32768);
  assert.equal(providers.maxTokensCap(new providers.UpstreamError(400, 'messages: roles must alternate')), null);
  assert.equal(providers.maxTokensCap(new providers.UpstreamError(500, 'range of max_tokens is [1, 8192]')), null);
  o.state.maxTokensCap = 0;
  o.state.status = 400;
  const before = o.requests.length;
  await assert.rejects(providers.complete(oai(o), ask('x', 12000)), (e) => e instanceof providers.UpstreamError && e.status === 400);
  assert.equal(o.requests.length - before, 1, '没写上限的 400 不重试');
});

test('空闲超时：两片之间太久 → IdleTimeoutError 并掐断上游；不给 idleMs（对话）就一直等', async (t) => {
  const up = await startFakeAnthropic({ key: ANT_KEY });
  t.after(() => up.stop());
  up.state.stallMs = 900;

  const seen = [];
  await assert.rejects(
    providers.streamChat(ant(up), { ...ask(), idleMs: 200 }, (d) => seen.push(d)),
    (e) => e instanceof providers.IdleTimeoutError && e.name === 'IdleTimeoutError' && /秒没有新数据/.test(e.message),
  );
  assert.equal(seen.length, 1, '超时前收到的那一片照常喂出去了');
  for (let i = 0; i < 100 && up.state.aborted === 0; i++) await new Promise((r) => setTimeout(r, 10));
  assert.ok(up.state.aborted > 0, '空闲超时要把上游连接掐掉');

  up.state.stallMs = 300;
  const ok = await providers.streamChat(ant(up), ask());
  assert.equal(ok.text, up.text(), '不给 idleMs 时停 300ms 也照样收完');
});

test('总时长上限：timeoutMs 到了就停（TimeoutError），不管还在不在吐字', async (t) => {
  const up = await startFakeOpenai({ key: OAI_KEY });
  t.after(() => up.stop());
  up.state.hang = true;
  await assert.rejects(providers.streamChat(oai(up), { ...ask(), timeoutMs: 300 }), (e) => e.name === 'TimeoutError' || e.name === 'AbortError');
});

test('visionOk：只有明确测出 vision:false 的渠道算不能看图', () => {
  assert.equal(providers.visionOk({}), true);
  assert.equal(providers.visionOk(null), true);
  assert.equal(providers.visionOk({ vision: true }), true);
  assert.equal(providers.visionOk({ vision: false }), false);
  assert.deepEqual(providers.STOP_REASONS, ['end', 'max_tokens', 'refusal', 'other']);
});
