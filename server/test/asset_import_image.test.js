'use strict';

// 截图导入（spec §6「截图」、§7 P5 验收「订单截图能导成物品」、§8「假上游断言」「日志里搜不到 base64」）：
// kind=image → 图片块发给上游（anthropic 图在文字前、openai data URL + detail:'high'），草稿每条带 img、关键字段进 unverified，
// 订单截图照样关联唯一那笔流水、导进去 origin.src = 'ai_image'、origin.unverified 带买价和买入日期（详情页出「AI 推断」小点）；
// 看不了图的渠道、坏图都在花钱之前挡下。

const test = require('node:test');
const assert = require('node:assert/strict');

const { household } = require('./fixtures');
const { openDb } = require('../src/lib/db');
const { startFakeAnthropic, startFakeOpenai } = require('./fake_upstream');
const { ANT_KEY, sse, addProvider, extractImages, applyBodyOf, pngImage } = require('./import_fixtures');

async function setup(t, env) {
  const up = await startFakeAnthropic({ key: ANT_KEY });
  t.after(() => up.stop());
  const h = await household(t, env);
  const provider = await addProvider(h, up);
  return { up, h, provider };
}

const items = async (h, p) => (await h.a.get(p, h.auth)).json.items;

test('验收（服务端）：订单截图 → 物品关联唯一那笔流水、带 img、买价和日期算推断 → 导入后 origin.src = ai_image、unverified 照写，流水条数不变', async (t) => {
  const { up, h } = await setup(t);
  const tx = (await h.tx({ type: 'expense', amountCents: 899900, occurredAt: '2026-09-21T09:00:00+08:00', fundId: h.fund.id, merchant: 'Apple Store' })).json.transaction;
  const before = (await h.a.get('/transactions?limit=200', h.auth)).json.items.length;
  const shots = [pngImage(784, 1568), pngImage(784, 1568)];
  const done = await extractImages(h, up, 'order_image.output.txt', shots, { want: 'items' });
  const item = done.draft.items[0];
  assert.deepEqual(item.fields, { name: 'iPhone 16 Pro 256GB', category: 'digital', preset: 'apple', priceCents: 899900, purchasedOn: '2026-09-20' });
  assert.equal(item.img, 2);
  assert.ok(!item.badges.includes('ev_unverified'), '截图来源不逐条标，预览顶上整批说');
  assert.deepEqual(item.unverified, ['priceCents', 'purchasedOn']);
  assert.deepEqual(item.link, { mode: 'link', transactionId: tx.id });
  assert.deepEqual(done.draft.source, { kind: 'image', count: 2 }, '草稿不回传图片本身');

  const body = up.lastBody();
  const content = body.messages[0].content;
  assert.deepEqual(content.map((b) => b.type), ['image', 'image', 'text'], 'anthropic：图在文字前面');
  assert.deepEqual(content[0].source, { type: 'base64', media_type: 'image/png', data: shots[0].data });
  assert.match(content[2].text, /按顺序附的 2 张截图/);
  assert.match(content[2].text, /这次只抽 item/);

  const r = await h.a.post('/asset-import/apply', applyBodyOf(done), h.auth);
  assert.equal(r.status, 200, r.text);
  const asset = (await items(h, '/assets'))[0];
  assert.deepEqual([asset.transactionId, asset.origin.src, asset.origin.importId], [tx.id, 'ai_image', done.importId]);
  assert.deepEqual(asset.origin.unverified, ['priceCents', 'purchasedOn'], '详情页的「AI 推断」小点靠它');
  assert.equal((await h.a.get('/transactions?limit=200', h.auth)).json.items.length, before, '关联已有流水，不另记账');

  await h.srv.stop();
  const db = openDb(h.srv.dataDir);
  try {
    const row = db.get('SELECT source_kind, summary FROM ai_imports WHERE id = ?', done.importId);
    assert.equal(row.source_kind, 'image');
    const summary = JSON.parse(row.summary);
    assert.deepEqual([summary.sourceKind, summary.images], ['image', 2]);
    assert.ok(summary.bytes > 0);
  } finally {
    db.close();
  }
});

test('openai 协议：截图是 data URL 且显式 detail:high，排在说明文字后面', async (t) => {
  const up = await startFakeOpenai({ key: 'sk-oai-img' });
  t.after(() => up.stop());
  const h = await household(t);
  const r = await h.a.post('/ai/providers', { name: '兼容端', kind: 'openai', baseUrl: `${up.base}/v1`, apiKey: 'sk-oai-img', model: 'qwen-vl', isDefault: true }, h.auth);
  assert.equal(r.status, 201, r.text);
  const shot = pngImage(784, 1568);
  await extractImages(h, up, '{"records":[],"done":true}', [shot]);
  const content = up.lastBody().messages[1].content;
  assert.deepEqual(content.map((b) => b.type), ['text', 'image_url']);
  assert.deepEqual(content[1].image_url, { url: `data:image/png;base64,${shot.data}`, detail: 'high' });
});

test('日志里搜不到 base64（LOG_LEVEL=debug 也没有）：info 只记块数和大小', async (t) => {
  const { up, h } = await setup(t, { LOG_LEVEL: 'debug' });
  const shot = pngImage(784, 1568);
  await extractImages(h, up, 'order_image.output.txt', [shot, pngImage(784, 1568)], { want: 'items' });
  const out = h.srv.stdout() + h.srv.stderr();
  assert.match(out, /\[import\] 识别 anthropic\/claude-sonnet-5 截图 2 块 共 \d+KB want=items/);
  assert.ok(!out.includes(shot.data.slice(0, 40)), '日志里不该有图片的 base64');
  assert.ok(!out.includes('iVBORw0KGgo'), '连 PNG 头的 base64 都不该有');
});

test('看不了图的渠道：指定它 400 provider_no_vision；默认渠道看不了图时自动挑下一个能看图的；都看不了 400 —— 都在花钱之前', async (t) => {
  const { up, h, provider } = await setup(t);
  await h.a.patch(`/ai/providers/${provider.id}`, { extra: { vision: false } }, h.auth);
  const shot = pngImage(100, 100);
  const post = (body) => sse(h.srv.base, '/asset-import/extract', { token: h.token, body: { kind: 'image', images: [shot], ...body } });
  const named = await post({ providerId: provider.id });
  assert.deepEqual([named.status, named.json.error.code], [400, 'provider_no_vision']);
  const none = await post({});
  assert.deepEqual([none.status, none.json.error.code], [400, 'provider_no_vision']);
  assert.match(none.json.error.message, /都看不了图片/);
  assert.equal(up.requests.length, 0);

  const second = await addProvider(h, up, { name: '能看图', isDefault: false, extra: { vision: true } });
  up.state.completions.push('{"records":[],"done":true}');
  const ok = await post({});
  assert.equal(ok.status, 200, ok.text);
  assert.equal(ok.of('done')[0].data.draft.providerId, second.id, '默认那个看不了图，挑了能看图的');
  assert.equal(up.requests.length, 1);
});

test('坏图在花钱之前挡下：不是图片、单张太大、PNG 边长超 2000、超过 8 片 → 400 invalid_images；请求体超过 8MB → 413', async (t) => {
  const { up, h } = await setup(t);
  const post = (images) => sse(h.srv.base, '/asset-import/extract', { token: h.token, body: { kind: 'image', images } });
  const gif = { data: Buffer.from('GIF89a' + '\0'.repeat(30), 'latin1').toString('base64') };
  for (const images of [[gif], [pngImage(2001, 100)], Array.from({ length: 9 }, () => pngImage(10, 10)), []]) {
    const r = await post(images);
    assert.deepEqual([r.status, r.json.error.code], [400, 'invalid_images'], r.text.slice(0, 200));
  }
  const tooBig = await post([{ data: 'A'.repeat(9 * 1024 * 1024) }]);
  assert.equal(tooBig.status, 413);
  assert.equal(up.requests.length, 0, '一个都不该打到上游');
});
