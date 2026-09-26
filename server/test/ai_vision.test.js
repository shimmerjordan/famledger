'use strict';

// 看图探测（spec §4 `POST /ai/providers/:id/test?vision=1`）：发一张 2×2 的红色 PNG 问颜色 → 明确答出红色 vision:true、
// 答错、否定、子串撞上 red 或上游 400 说不收图片 vision:false，都写进渠道 extra.vision（别的键留着）；连不上、5xx、没回答 → 判断不了，extra 不动。
// 换了模型 / 地址 / 协议，上次测的结果作废；探测等上游的时候渠道被改了 → 这次不算数，被删了 → 404。只有管理员能测（和普通测试一样）。

const test = require('node:test');
const assert = require('node:assert/strict');

const { household } = require('./fixtures');
const { startFakeAnthropic, startFakeOpenai } = require('./fake_upstream');
const { ANT_KEY, addProvider } = require('./import_fixtures');

const RED_PNG = 'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEUlEQVR4nGP4z8DwnwGMgRQAH+4D/dJQfRoAAAAASUVORK5CYII=';

async function setup(t) {
  const up = await startFakeAnthropic({ key: ANT_KEY });
  t.after(() => up.stop());
  const h = await household(t);
  const provider = await addProvider(h, up, { extra: { importMaxTokens: 8000 } });
  return { up, h, provider };
}

const probe = (h, id) => h.a.post(`/ai/providers/${id}/test?vision=1`, {}, h.auth);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
/** 等假上游收到第 n 个请求（探测已经发出去、正在等回答）。 */
async function untilAsked(up, n = 1) {
  for (let i = 0; i < 200 && up.requests.length < n; i++) await sleep(10);
  assert.equal(up.requests.length, n, '探测没打到上游');
}
const extraOf = async (h, id) => (await h.a.get('/ai/providers', h.auth)).json.items.find((p) => p.id === id).extra;

test('答出红色 → vision:true 写进 extra（别的键留着）；请求里是那张 2×2 的红图、图在文字前', async (t) => {
  const { up, h, provider } = await setup(t);
  up.state.completions.push('红色');
  const r = await probe(h, provider.id);
  assert.equal(r.status, 200, r.text);
  assert.deepEqual([r.json.ok, r.json.vision, r.json.sample], [true, true, '红色']);
  assert.deepEqual(r.json.provider.extra, { importMaxTokens: 8000, vision: true });
  assert.deepEqual(await extraOf(h, provider.id), { importMaxTokens: 8000, vision: true });
  const body = up.lastBody();
  assert.equal(body.stream, undefined, '非流式');
  assert.deepEqual(body.messages[0].content[0], { type: 'image', source: { type: 'base64', media_type: 'image/png', data: RED_PNG } });
  assert.equal(body.messages[0].content[1].type, 'text');
  assert.equal(body.max_tokens, 64);
});

test('答了别的颜色（看不见图在瞎猜）→ vision:false；上游 400 说不收图片 → vision:false', async (t) => {
  const { up, h, provider } = await setup(t);
  up.state.completions.push('蓝色');
  const guess = await probe(h, provider.id);
  assert.deepEqual([guess.json.ok, guess.json.vision], [true, false]);
  assert.match(guess.json.message, /它说「蓝色」，看起来没看到图/);
  assert.equal((await extraOf(h, provider.id)).vision, false);

  // 看不了图的模型常见的英文回答：delivered / rendered 里的 red 不算，「不是红色」也不算
  for (const answer of ['I cannot see any image; nothing was delivered.', 'The image was not rendered.', '不是红色']) {
    up.state.completions.push(answer);
    const r = await probe(h, provider.id);
    assert.deepEqual([r.json.ok, r.json.vision], [true, false], answer);
  }
  assert.equal((await extraOf(h, provider.id)).vision, false);

  up.state.status = 400;
  up.state.errorMessage = 'unknown variant `image_url`, expected `text`';
  const refused = await probe(h, provider.id);
  assert.deepEqual([refused.json.ok, refused.json.vision], [true, false]);
  assert.match(refused.json.message, /不收图片/);
});

test('判断不了（5xx、没回答）：vision:null，extra 不动（上次的结果留着）', async (t) => {
  const { up, h, provider } = await setup(t);
  up.state.completions.push('red');
  assert.equal((await probe(h, provider.id)).json.vision, true);
  up.state.status = 500;
  const down = await probe(h, provider.id);
  assert.deepEqual([down.status, down.json.ok, down.json.vision], [200, false, null]);
  assert.match(down.json.message, /上游返回 500/);
  up.state.status = 200;
  up.state.completions.push('   ');
  const silent = await probe(h, provider.id);
  assert.deepEqual([silent.json.ok, silent.json.vision], [false, null]);
  assert.match(silent.json.message, /没有回答/);
  assert.equal((await extraOf(h, provider.id)).vision, true, '判断不了的不覆盖上次的结果');
});

test('openai 协议：探测图是 data URL + detail:high', async (t) => {
  const up = await startFakeOpenai({ key: 'sk-oai-v' });
  t.after(() => up.stop());
  const h = await household(t);
  const p = (await h.a.post('/ai/providers', { name: 'VL', kind: 'openai', baseUrl: `${up.base}/v1`, apiKey: 'sk-oai-v', model: 'qwen-vl' }, h.auth)).json.provider;
  up.state.completions.push('Red.');
  assert.equal((await probe(h, p.id)).json.vision, true);
  const content = up.lastBody().messages[1].content;
  assert.deepEqual(content[1], { type: 'image_url', image_url: { url: `data:image/png;base64,${RED_PNG}`, detail: 'high' } });
});

test('换了模型、地址或协议：extra.vision 清掉（表单带着旧 extra 发回来也一样）；只改名字不动；普通成员不能测', async (t) => {
  const { up, h, provider } = await setup(t);
  up.state.completions.push('红色');
  await probe(h, provider.id);
  await h.a.patch(`/ai/providers/${provider.id}`, { name: '改个名' }, h.auth);
  assert.equal((await extraOf(h, provider.id)).vision, true);
  await h.a.patch(`/ai/providers/${provider.id}`, { model: 'claude-haiku-5', extra: { importMaxTokens: 8000, vision: true } }, h.auth);
  assert.deepEqual(await extraOf(h, provider.id), { importMaxTokens: 8000 });

  await h.a.post('/members', { username: 'xiaohong', password: 'hunter22', displayName: '小红', role: 'member' }, h.auth);
  const her = { token: (await h.a.post('/auth/login', { username: 'xiaohong', password: 'hunter22' })).json.token };
  assert.equal((await h.a.post(`/ai/providers/${provider.id}/test?vision=1`, {}, her)).status, 403);
});

test('探测等上游的时候渠道被改了：换了模型 → 这次不算数（vision:null、不写）；只改了别的 extra 键 → 结论合进改过的 extra，不回滚', async (t) => {
  const { up, h, provider } = await setup(t);
  up.state.delayMs = 300;
  up.state.completions.push('红色');
  const pending = probe(h, provider.id);
  await untilAsked(up);
  const patched = await h.a.patch(`/ai/providers/${provider.id}`, { model: 'claude-haiku-5' }, h.auth);
  assert.equal(patched.status, 200, patched.text);
  const r = await pending;
  assert.equal(r.status, 200, r.text);
  assert.deepEqual([r.json.ok, r.json.vision], [false, null]);
  assert.match(r.json.message, /渠道被改过.*再测一次/);
  assert.deepEqual(await extraOf(h, provider.id), { importMaxTokens: 8000 }, '旧模型的结论没有写到新模型头上');
  assert.equal(r.json.provider.model, 'claude-haiku-5');

  up.state.completions.push('红色');
  const second = probe(h, provider.id);
  await untilAsked(up, 2);
  await h.a.patch(`/ai/providers/${provider.id}`, { extra: { importMaxTokens: 6000 } }, h.auth);
  const ok = await second;
  assert.equal(ok.json.vision, true);
  assert.deepEqual(await extraOf(h, provider.id), { importMaxTokens: 6000, vision: true }, '期间改的 importMaxTokens 留着');
});

test('探测等上游的时候渠道被删了 → 404（不是 500）', async (t) => {
  const { up, h, provider } = await setup(t);
  up.state.delayMs = 300;
  up.state.completions.push('红色');
  const pending = probe(h, provider.id);
  await untilAsked(up);
  assert.equal((await h.a.del(`/ai/providers/${provider.id}`, h.auth)).status, 200);
  const r = await pending;
  assert.deepEqual([r.status, r.json.error.code], [404, 'not_found']);
});
