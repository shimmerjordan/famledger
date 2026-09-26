'use strict';

// POST /asset-import/extract（spec §4、§6）：粘贴文字 → SSE stage → record* → done{importId, draft} | error{code}。
// 钉死：草稿带比对结果（并入 / 可能重复 / 关联流水）、截断时标 truncated、坏输出 ai_bad_output 并记一行 failed 用量、
// 发给模型前脱敏且 info 日志里没有原文、每人同时 1 个导入（409）、每小时限流（429）、空闲超时、客户端断开就掐上游。
// 上游是假的（test/fake_upstream.js），喂 test/fixtures/perk_import/ 的「模型原样输出」。

const test = require('node:test');
const assert = require('node:assert/strict');

const { household } = require('./fixtures');
const { startServer, api } = require('./helpers');
const { openDb } = require('../src/lib/db');
const { startFakeAnthropic } = require('./fake_upstream');
const { ANT_KEY, fixture, sse, addProvider, extractDraft } = require('./import_fixtures');

async function setup(t, env) {
  const up = await startFakeAnthropic({ key: ANT_KEY });
  t.after(() => up.stop());
  const h = await household(t, env);
  await addProvider(h, up);
  return { up, h };
}

test('88VIP：stage → record（只增不减）→ done；草稿带比对结果，原文随草稿回来给依据高亮；请求带已有平台名和 12000 输出上限', async (t) => {
  const { up, h } = await setup(t);
  const tb = (await h.a.post('/platforms', { name: '淘宝' }, h.auth)).json.platform;
  const yk = (await h.a.post('/platforms', { name: '优酷' }, h.auth)).json.platform;
  up.state.completions.push(fixture('vip88.output.txt'));
  const r = await sse(h.srv.base, '/asset-import/extract', { token: h.token, body: { kind: 'text', text: fixture('vip88.source.txt'), want: 'virtual' } });
  assert.equal(r.status, 200, r.text);
  assert.equal(r.events[0].event, 'stage');
  const ns = r.of('record').map((e) => e.data.n);
  assert.ok(ns.length >= 1 && ns[ns.length - 1] === 8, `record：${ns}`);
  assert.deepEqual([...ns].sort((a, b) => a - b), ns);
  assert.equal(r.of('error').length, 0);
  const { importId, draft } = r.of('done')[0].data;
  assert.ok(importId);
  assert.equal(draft.importId, importId);
  assert.deepEqual([draft.truncated, draft.want, draft.source.kind], [false, 'virtual', 'text']);
  assert.equal(draft.source.text, fixture('vip88.source.txt'));
  const p = Object.fromEntries(draft.platforms.map((x) => [x.fields.name, x]));
  assert.deepEqual([p['淘宝'].action, p['淘宝'].targetId], ['merge', tb.id]);
  assert.deepEqual([p['优酷视频'].action, p['优酷视频'].match.kind, p['优酷视频'].match.candidates], ['create', 'maybe', [{ id: yk.id, name: '优酷' }]]);
  assert.equal(draft.memberships[0].action, 'create');
  assert.equal(draft.benefits.length, 7);

  const body = up.lastBody();
  assert.equal(body.stream, true);
  assert.equal(body.max_tokens, 12000);
  assert.match(body.system, /只抽材料里写明的内容/);
  assert.match(body.messages[0].content, /已有的平台.*淘宝、优酷/);
  assert.match(body.messages[0].content, /只抽平台、会员卡和权益/);
  assert.ok(body.messages[0].content.includes('优酷视频年卡，开通后去优酷 App'));
});

test('订单文字：发给模型前手机号打码、info 日志只有长度；物品默认关联唯一匹配的流水', async (t) => {
  const { up, h } = await setup(t, { LOG_LEVEL: 'info' });
  const tx = (await h.tx({ type: 'expense', amountCents: 899900, occurredAt: '2026-09-21T09:00:00+08:00', fundId: h.fund.id, merchant: 'Apple Store' })).json.transaction;
  const done = await extractDraft(h, up, 'order.output.txt', 'order.source.txt', { want: 'items' });
  const item = done.draft.items[0];
  assert.deepEqual(item.fields, { name: 'iPhone 16 Pro 256GB', category: 'digital', preset: 'apple', priceCents: 899900, purchasedOn: '2026-09-20' });
  assert.deepEqual(item.txCandidates.map((c) => c.id), [tx.id]);
  assert.deepEqual(item.link, { mode: 'link', transactionId: tx.id });
  const sent = up.lastBody().messages[0].content;
  assert.ok(!sent.includes('13912345678'), '手机号不该原样发给模型');
  assert.ok(sent.includes('139****5678'));
  assert.ok(!sent.includes('2026092021140512345'), '19 位订单号按卡号打码');
  assert.ok(!done.draft.source.text.includes('13912345678'), '回给 App 的原文也是打过码的');
  const out = h.srv.stdout();
  assert.match(out, /\[import\] 识别 anthropic\/claude-sonnet-5 原文 \d+ 字/);
  assert.ok(!out.includes('王小明') && !out.includes('13912345678') && !out.includes('iPhone 16 Pro'), 'info 日志里不该有原文');
});

test('截断：第 5 条中间断掉 → 救回 4 条、truncated（App 照着在顶部提示分段，截断那句不放进 notices）；stopReason=max_tokens 也算截断', async (t) => {
  const { up, h } = await setup(t);
  const cut = await extractDraft(h, up, 'vip88_truncated.output.txt', 'vip88.source.txt');
  assert.equal(cut.draft.truncated, true);
  assert.equal(cut.draft.salvaged, true);
  assert.deepEqual(cut.draft.benefits.map((b) => b.fields.name), ['优酷视频年卡', '饿了么超级会员年卡']);
  assert.deepEqual([cut.draft.continued, cut.draft.continueFailed], [false, false]);
  assert.ok(!cut.draft.notices.some((n) => n.includes('分段')), '截断的说法由 App 按标记给，不在 notices 里重复');

  up.state.completions.push({ text: fixture('vip88.output.txt'), stopReason: 'max_tokens' });
  const r = await sse(h.srv.base, '/asset-import/extract', { token: h.token, body: { kind: 'text', text: fixture('vip88.source.txt') } });
  assert.equal(r.of('done')[0].data.draft.truncated, true);
});

test('坏输出：一条都救不回来 → error ai_bad_output，用量照样记一行 failed；空结果不是错误', async (t) => {
  const { up, h } = await setup(t);
  up.state.completions.push('抱歉，我看不懂这段材料。');
  const bad = await sse(h.srv.base, '/asset-import/extract', { token: h.token, body: { kind: 'text', text: '随便一段字' } });
  assert.equal(bad.status, 200);
  assert.deepEqual(bad.of('error').map((e) => e.data.code), ['ai_bad_output']);
  assert.equal(bad.of('done').length, 0);

  const empty = await extractDraft(h, up, '{"records":[],"done":true}', '今天天气不错');
  assert.equal(empty.draft.platforms.length + empty.draft.benefits.length + empty.draft.items.length, 0);
  assert.ok(empty.draft.notices.some((n) => n.includes('没找到')));

  await h.srv.stop();
  const db = openDb(h.srv.dataDir);
  try {
    const rows = db.all('SELECT status, usage_in, usage_out, source_kind, member_id FROM ai_imports ORDER BY created_at');
    assert.deepEqual(rows.map((r) => r.status), ['failed', 'extracted']);
    assert.deepEqual([rows[0].usage_in, rows[0].usage_out, rows[0].source_kind, rows[0].member_id], [123, 45, 'text', h.member.id]);
  } finally {
    db.close();
  }
});

test('校验：只接 kind=text / image（url、transactions 还没有）；原文最多 20000 字、不能是空白；要补充的卡得存在；没有渠道 400 —— 都在花钱之前', async (t) => {
  const up = await startFakeAnthropic({ key: ANT_KEY });
  t.after(() => up.stop());
  const h = await household(t);
  const post = (body) => sse(h.srv.base, '/asset-import/extract', { token: h.token, body: { kind: 'text', text: '88VIP', ...body } });
  assert.equal((await post({})).json.error.code, 'no_provider');
  await addProvider(h, up);
  const cases = [
    [{ kind: 'url' }, 'kind_unsupported'],
    [{ kind: 'transactions' }, 'kind_unsupported'],
    [{ kind: 'image' }, 'invalid_images'],
    [{ kind: 'fax' }, 'invalid_kind'],
    [{ want: 'all' }, 'invalid_want'],
    [{ text: '字'.repeat(20001) }, 'invalid_text'],
    [{ text: '   \n ' }, 'invalid_text'],
    [{ targetMembershipId: 'nope' }, 'invalid_targetMembershipId'],
  ];
  for (const [body, code] of cases) {
    const r = await post(body);
    assert.equal(r.status, 400, `${JSON.stringify(body).slice(0, 60)} → ${r.text.slice(0, 200)}`);
    assert.equal(r.json.error.code, code);
  }
  assert.equal(up.requests.length, 0, '一个都不该打到上游');
});

test('超过 12000 字按关键词挑段落，并在 stage 和草稿里告诉用户', async (t) => {
  const { up, h } = await setup(t);
  const noise = '今天天气不错，出门散步。'.repeat(300); // 3600 字一段
  const text = [noise, noise, fixture('vip88.source.txt'), noise, noise].join('\n\n');
  up.state.completions.push(fixture('vip88.output.txt'));
  const r = await sse(h.srv.base, '/asset-import/extract', { token: h.token, body: { kind: 'text', text } });
  assert.match(r.events[0].data.message, /只挑了最相关的 \d+ 段/);
  const draft = r.of('done')[0].data.draft;
  assert.ok(draft.notices[0].includes(`材料有 ${text.length} 字`));
  assert.ok(draft.source.text.length <= 12000);
  assert.ok(draft.source.text.includes('优酷视频年卡'));
});

test('指定卡（会员详情的「AI 补充权益」）：提示词写明归到这张卡，权益一律 id: 引用它', async (t) => {
  const { up, h } = await setup(t);
  const tb = (await h.a.post('/platforms', { name: '淘宝' }, h.auth)).json.platform;
  const vip = (await h.a.post('/memberships', { platformId: tb.id, name: '88VIP' }, h.auth)).json.membership;
  const done = await extractDraft(
    h, up,
    '{"records":[{"t":"benefit","name":"饿了么超级会员年卡","membership":"88VIP","claimPlatform":"饿了么","quota":[{"p":"year","n":1}],"ev":"饿了么超级会员年卡"}],"done":true}',
    'vip88.source.txt',
    { targetMembershipId: vip.id, want: 'virtual' },
  );
  assert.equal(done.draft.targetMembershipId, vip.id);
  assert.deepEqual(done.draft.benefits.map((b) => b.fields.membership), [`id:${vip.id}`]);
  assert.match(up.lastBody().messages[0].content, /归到已有的会员卡「88VIP」（淘宝）/);
});

test('每人同时只能 1 个导入：第二个 409 import_in_progress 且不打上游；客户端断开就掐上游、名额还回来', async (t) => {
  const { up, h } = await setup(t, { AI_MAX_STREAMS: '4' });
  up.state.hang = true;
  const ctl = new AbortController();
  const first = await fetch(`${h.srv.base}/api/v1/asset-import/extract`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${h.token}` },
    body: JSON.stringify({ kind: 'text', text: '88VIP 年费 88 元' }),
    signal: ctl.signal,
  });
  assert.equal(first.status, 200);
  const reader = first.body.getReader();
  await reader.read();
  for (let i = 0; i < 50 && up.requests.length === 0; i++) await new Promise((r) => setTimeout(r, 10));

  const second = await sse(h.srv.base, '/asset-import/extract', { token: h.token, body: { kind: 'text', text: '再来' } });
  assert.equal(second.status, 409);
  assert.equal(second.json.error.code, 'import_in_progress');
  assert.equal(up.requests.length, 1, '被挡下的那次不打上游');

  ctl.abort();
  for (let i = 0; i < 200 && up.state.aborted === 0; i++) await new Promise((r) => setTimeout(r, 10));
  assert.ok(up.state.aborted > 0, '客户端断开就掐掉上游');
  up.state.hang = false;
  let again = null;
  for (let i = 0; i < 30; i++) {
    again = await sse(h.srv.base, '/asset-import/extract', { token: h.token, body: { kind: 'text', text: fixture('vip88.source.txt') } });
    if (again.status === 200) break;
    await new Promise((r) => setTimeout(r, 25));
  }
  assert.equal(again.status, 200, '前一个断了之后名额没还回来');
});

test('每人每小时 AI_IMPORT_PER_HOUR 次：打满后 429，且不打上游；按人算', async (t) => {
  const { up, h } = await setup(t, { AI_IMPORT_PER_HOUR: '2' });
  for (let i = 0; i < 2; i++) await extractDraft(h, up, '{"records":[],"done":true}', '88VIP');
  const third = await sse(h.srv.base, '/asset-import/extract', { token: h.token, body: { kind: 'text', text: '88VIP' } });
  assert.equal(third.status, 429);
  assert.equal(third.json.error.code, 'rate_limited');
  assert.match(third.json.error.message, /每小时最多 2 次/);
  assert.equal(up.requests.length, 2);

  await h.a.post('/members', { username: 'xiaohong', password: 'hunter22', displayName: '小红', role: 'member' }, h.auth);
  const her = (await h.a.post('/auth/login', { username: 'xiaohong', password: 'hunter22' })).json.token;
  up.state.completions.push('{"records":[],"done":true}');
  const r = await sse(h.srv.base, '/asset-import/extract', { token: her, body: { kind: 'text', text: '88VIP' } });
  assert.equal(r.status, 200, '限流桶不是全家共用的');
});

test('空闲超时：上游一段时间没新数据 → error ai_timeout，掐断上游', async (t) => {
  const { up, h } = await setup(t, { AI_IMPORT_IDLE_MS: '300' });
  up.state.stallMs = 2000;
  const r = await sse(h.srv.base, '/asset-import/extract', { token: h.token, body: { kind: 'text', text: '88VIP 年费 88 元' } });
  const errs = r.of('error');
  assert.equal(errs.length, 1, r.text);
  assert.equal(errs[0].data.code, 'ai_timeout');
  assert.match(errs[0].data.message, /秒没有新数据/);
  for (let i = 0; i < 100 && up.state.aborted === 0; i++) await new Promise((res) => setTimeout(res, 10));
  assert.ok(up.state.aborted > 0);
});

test('ai_imports 只在服务端：不进 /changes；备份导出导入带着它', async (t) => {
  const { up, h } = await setup(t);
  await extractDraft(h, up, '{"records":[],"done":true}', '88VIP');
  const changes = (await h.a.get('/changes?since=0', h.auth)).json;
  assert.equal(changes.ai_imports, undefined);
  const dump = await fetch(`${h.srv.base}/api/v1/backup/export`, { headers: { authorization: `Bearer ${h.token}` } });
  const gz = Buffer.from(await dump.arrayBuffer());
  await extractDraft(h, up, '{"records":[],"done":true}', '88VIP');
  const r = await fetch(`${h.srv.base}/api/v1/backup/import`, {
    method: 'POST',
    headers: { authorization: `Bearer ${h.token}`, 'content-type': 'application/gzip' },
    body: gz,
  });
  assert.equal(r.status, 200, await r.text());
  await h.srv.stop();
  const db = openDb(h.srv.dataDir);
  try {
    assert.equal(db.get('SELECT COUNT(*) AS n FROM ai_imports').n, 1, '恢复成导出时的样子');
  } finally {
    db.close();
  }
  // 同一个数据目录再起一次也照常（迁移不会重跑出错）
  const again = await startServer({ DATA_DIR: h.srv.dataDir, WEB_ROOT: h.srv.webRoot });
  t.after(() => again.stop());
  assert.equal((await api(again.base).get('/changes?since=0', h.auth)).status, 200);
});
