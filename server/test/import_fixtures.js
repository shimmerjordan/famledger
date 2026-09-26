'use strict';

// AI 导入测试共用：SSE 读法、指向假上游的渠道、跑一次 extract 拿草稿、把草稿拼成 apply 的请求体。
// 上游一律是 test/fake_upstream.js 的假服务（completions 队列喂 test/fixtures/perk_import/ 里的「模型原样输出」），不调真模型。

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');

const ANT_KEY = 'sk-ant-import';
const FIX = path.join(__dirname, 'fixtures', 'perk_import');
const fixture = (name) => fs.readFileSync(path.join(FIX, name), 'utf8');

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
async function sse(base, p, { token, body } = {}) {
  const r = await fetch(`${base}/api/v1${p}`, {
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
  const events = r.status === 200 ? parseSse(text) : [];
  return { status: r.status, text, json, events, of: (name) => events.filter((e) => e.event === name) };
}

/** CRC-32（PNG 块校验用）。 */
function crc32(buf) {
  let crc = 0xffffffff;
  for (const byte of buf) {
    crc ^= byte;
    for (let k = 0; k < 8; k++) crc = crc & 1 ? 0xedb88320 ^ (crc >>> 1) : crc >>> 1;
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function pngChunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, 'latin1'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
}

/** 一张真的灰度 PNG（w×h，全白），给截图导入当材料。服务端只读文件头，但假上游和日志断言要的是真字节。 */
function pngBuffer(w, h) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; // 位深
  ihdr[9] = 0; // 灰度
  const row = Buffer.alloc(1 + w, 0xff);
  row[0] = 0; // 过滤方式：无
  const raw = Buffer.concat(Array.from({ length: h }, () => row));
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    pngChunk('IHDR', ihdr),
    pngChunk('IDAT', zlib.deflateSync(raw)),
    pngChunk('IEND', Buffer.alloc(0)),
  ]);
}

/** 请求体里的一片截图：{mediaType, data(base64)}。 */
const pngImage = (w = 784, h = 1568) => ({ mediaType: 'image/png', data: pngBuffer(w, h).toString('base64') });

/** 建一个指向假 Anthropic 的默认渠道。 */
async function addProvider(h, up, extra = {}) {
  const r = await h.a.post('/ai/providers', {
    name: '导入测试', kind: 'anthropic', baseUrl: up.base, apiKey: ANT_KEY, model: 'claude-sonnet-5', isDefault: true, ...extra,
  }, h.auth);
  assert.equal(r.status, 201, r.text);
  return r.json.provider;
}

/**
 * 喂一份「模型原样输出」跑一次 extract，返回 done 的 data（{importId, draft}）。
 * [source] 是粘贴的原文（fixture 名或原文本身）。
 */
async function extractDraft(h, up, output, source, body = {}) {
  up.state.completions.push(output.endsWith('.txt') ? fixture(output) : output);
  const text = source.endsWith('.txt') ? fixture(source) : source;
  const r = await sse(h.srv.base, '/asset-import/extract', { token: h.token, body: { kind: 'text', text, ...body } });
  assert.equal(r.status, 200, r.text);
  const done = r.of('done');
  assert.equal(done.length, 1, `没有 done：${r.text}`);
  return done[0].data;
}

/** 喂一份「模型原样输出」跑一次截图识别（kind=image），返回 done 的 data。 */
async function extractImages(h, up, output, images, body = {}) {
  up.state.completions.push(output.endsWith('.txt') ? fixture(output) : output);
  const r = await sse(h.srv.base, '/asset-import/extract', { token: h.token, body: { kind: 'image', images, ...body } });
  assert.equal(r.status, 200, r.text);
  const done = r.of('done');
  assert.equal(done.length, 1, `没有 done：${r.text}`);
  return done[0].data;
}

/**
 * 草稿 → apply 请求体：勾着的节点照草稿的动作走（ambiguous 的 pick 按 [picks] 里给的决定），没勾的 skip；
 * update 默认只写草稿里默认勾选的差异字段。[edit(node, item)] 可以就地改每一项。
 */
function applyBodyOf(done, { clientId = 'apply-1', edit = () => {}, picks = {} } = {}) {
  const item = (n) => {
    const out = { key: n.key, action: n.checked === false ? 'skip' : n.action, fields: { ...n.fields }, ev: n.ev, unverified: n.unverified };
    if (out.action === 'pick') Object.assign(out, picks[n.key] || { action: 'create' });
    if (out.action === 'merge' || out.action === 'update') out.targetId = out.targetId || n.targetId;
    if (out.action === 'update') out.take = (n.diff || []).filter((d) => d.take).map((d) => d.field);
    if (n.t === 'item') {
      delete out.fields.preset;
      if (n.link && n.link.mode === 'link') out.linkTransactionId = n.link.transactionId;
    }
    edit(n, out);
    return out;
  };
  const d = done.draft;
  return {
    clientId,
    importId: done.importId,
    platforms: d.platforms.map(item),
    memberships: d.memberships.map(item),
    benefits: d.benefits.map(item),
    items: d.items.map(item),
  };
}

module.exports = { ANT_KEY, fixture, parseSse, sse, addProvider, extractDraft, extractImages, applyBodyOf, pngBuffer, pngImage };
