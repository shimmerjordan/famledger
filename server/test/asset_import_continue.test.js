'use strict';

// 续写一次（spec §6「截断判定」、§8「续写请求带『已收到』名单」）：截断（stopReason=max_tokens 或没有 done 哨兵）且已经收到
// ≥5 条 → 带着「已收到」名单再问一次，两次的记录合起来去重；续写后仍截断 → truncated 照旧（continued 为真）；续写那次出错 →
// continueFailed 为真（App 照这三个标记说是哪种情况，截断那句不放进 notices）；收到的少于 5 条、剩下的总时长不够、续写的输出坏了 →
// 不续或保留第一次的；用量两次相加记进 ai_imports；续写期间客户端断开，第一次的用量照样记一行。

const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');
const { DatabaseSync } = require('node:sqlite');

const { household } = require('./fixtures');
const { openDb } = require('../src/lib/db');
const { startFakeAnthropic } = require('./fake_upstream');
const { ANT_KEY, fixture, sse, addProvider, extractDraft, pngImage } = require('./import_fixtures');
const { continueNote } = require('../src/lib/perk_import_prompt');

async function setup(t, env) {
  const up = await startFakeAnthropic({ key: ANT_KEY });
  t.after(() => up.stop());
  const h = await household(t, env);
  await addProvider(h, up);
  return { up, h };
}

test('「已收到」名单：类型、名字、所属逐行列出，最多 200 条，要求接着写并写哨兵', () => {
  const note = continueNote([
    { t: 'platform', name: '淘宝' },
    { t: 'membership', name: '88VIP', platform: '淘宝' },
    { t: 'benefit', name: '优酷视频年卡', membership: '88VIP' },
    { t: 'benefit' },
  ]);
  assert.match(note, /下面这些记录已经收到，不要再写/);
  assert.ok(note.includes('- platform：淘宝\n- membership：88VIP（淘宝）\n- benefit：优酷视频年卡（88VIP）\n- benefit：（没写名字）'));
  assert.match(note, /"done":true/);
  const many = continueNote(Array.from({ length: 250 }, (_, i) => ({ t: 'benefit', name: `权益${i}` })));
  assert.ok(many.includes('权益199') && !many.includes('权益200'));
});

test('截断且收到 6 条 → 续写一次：第二次请求带「已收到」名单，两次合起来 = 完整的 88VIP；不再标截断；用量相加', async (t) => {
  const { up, h } = await setup(t);
  up.state.completions.push(fixture('vip88_part1.output.txt'), fixture('vip88_part2.output.txt'));
  const r = await sse(h.srv.base, '/asset-import/extract', { token: h.token, body: { kind: 'text', text: fixture('vip88.source.txt') } });
  assert.equal(r.status, 200, r.text);
  assert.ok(r.of('stage').some((e) => e.data.stage === 'continuing'), '告诉用户在续写');
  const ns = r.of('record').map((e) => e.data.n);
  assert.equal(ns[ns.length - 1], 8, `进度接着往上数：${ns}`);
  const { draft, importId } = r.of('done')[0].data;
  assert.deepEqual([draft.truncated, draft.continued, draft.continueFailed], [false, true, false]);
  assert.equal(draft.benefits.length, 7, '三选一的三个选项分在两次里也合成一个父权益');
  assert.deepEqual(draft.benefits.filter((b) => b.fields.parent).map((b) => b.fields.name), ['网易云音乐黑胶年卡', 'QQ 音乐豪华绿钻年卡', '芒果 TV 年卡']);
  assert.ok(!draft.notices.some((n) => n.includes('分段')));
  assert.deepEqual(draft.usage, { input: 246, output: 90 });

  assert.equal(up.requests.length, 2);
  const second = up.requests[1].body.messages[0].content;
  assert.ok(second.startsWith(up.requests[0].body.messages[0].content), '续写发的是同一份材料');
  assert.match(second, /已经收到，不要再写/);
  assert.ok(second.includes('- benefit：网易云音乐黑胶年卡（88VIP）'));
  assert.ok(!second.includes('QQ 音乐豪华绿钻年卡（88VIP）'), '没收到的不在名单里');

  await h.srv.stop();
  const db = openDb(h.srv.dataDir);
  try {
    const row = db.get('SELECT usage_in, usage_out, summary FROM ai_imports WHERE id = ?', importId);
    assert.deepEqual([row.usage_in, row.usage_out], [246, 90]);
    assert.equal(JSON.parse(row.summary).continued, true);
  } finally {
    db.close();
  }
});

test('续写后仍截断：只续一次，truncated 照旧、continued 为真（App 说「续写了一次还是没写完」）；续写的输出坏了就留着第一次的', async (t) => {
  const { up, h } = await setup(t);
  const cut = fixture('vip88_part2.output.txt').replace('],"done":true}', ']}');
  up.state.completions.push(fixture('vip88_part1.output.txt'), cut);
  const r = await sse(h.srv.base, '/asset-import/extract', { token: h.token, body: { kind: 'text', text: fixture('vip88.source.txt') } });
  const { draft } = r.of('done')[0].data;
  assert.deepEqual([draft.truncated, draft.continued, draft.continueFailed], [true, true, false]);
  assert.ok(!draft.notices.some((n) => n.includes('分段')));
  assert.equal(up.requests.length, 2, '只续一次');

  up.state.completions.push(fixture('vip88_part1.output.txt'), '抱歉，我没法继续。');
  const bad = await sse(h.srv.base, '/asset-import/extract', { token: h.token, body: { kind: 'text', text: fixture('vip88.source.txt') } });
  const kept = bad.of('done')[0].data.draft;
  assert.deepEqual([kept.truncated, kept.continued], [true, true]);
  assert.equal(kept.memberships.length, 1, '第一次收到的 6 条都在');
  assert.equal(kept.benefits.filter((b) => !b.fields.parent).length, 4);
});

test('不续写：收到的不到 5 条（第 5 条中间断掉）；剩下的总时长不够 15 秒 —— 各只打一次上游', async (t) => {
  const { up, h } = await setup(t);
  const few = await extractDraft(h, up, 'vip88_truncated.output.txt', 'vip88.source.txt');
  assert.deepEqual([few.draft.truncated, few.draft.continued, few.draft.continueFailed], [true, false, false]);
  assert.equal(up.requests.length, 1);

  const { up: up2, h: h2 } = await setup(t, { AI_IMPORT_TOTAL_MS: '10000' });
  const short = await extractDraft(h2, up2, 'vip88_part1.output.txt', 'vip88.source.txt');
  assert.deepEqual([short.draft.truncated, short.draft.continued], [true, false]);
  assert.equal(up2.requests.length, 1);
});

test('续写那次上游出错：第一次收到的留着（截断照旧、continueFailed 为真 —— App 说「接着写时出错了」而不是「续写了还没写完」），不报错；用量记第一次的', async (t) => {
  const { up, h } = await setup(t);
  up.state.completions.push(fixture('vip88_part1.output.txt'), { status: 500 });
  const r = await sse(h.srv.base, '/asset-import/extract', { token: h.token, body: { kind: 'text', text: fixture('vip88.source.txt') } });
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.of('error'), [], '第一次的 token 已经花了，不能因为续写失败整个丢掉');
  const { draft } = r.of('done')[0].data;
  assert.deepEqual([draft.truncated, draft.continued, draft.continueFailed], [true, true, true]);
  assert.equal(draft.memberships.length, 1, '第一次收到的 6 条都在');
  assert.equal(draft.benefits.filter((b) => !b.fields.parent).length, 4);
  assert.deepEqual(draft.usage, { input: 123, output: 45 });
  assert.equal(up.requests.length, 2);

  await h.srv.stop();
  const db = openDb(h.srv.dataDir);
  try {
    const summary = JSON.parse(db.get('SELECT summary FROM ai_imports WHERE id = ?', r.of('done')[0].data.importId).summary);
    assert.deepEqual([summary.continued, summary.continueFailed], [true, true], '用量记录里也分得清是续写失败');
  } finally {
    db.close();
  }
});

test('续写期间客户端断开：上游那条立刻中止；第一次已经花掉的用量照样记一行 ai_imports（failed / client_aborted）', async (t) => {
  const { up, h } = await setup(t);
  up.state.completions.push(fixture('vip88_part1.output.txt'), { text: fixture('vip88_part2.output.txt'), hang: true });
  const ctl = new AbortController();
  const r = await fetch(`${h.srv.base}/api/v1/asset-import/extract`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${h.token}` },
    body: JSON.stringify({ kind: 'text', text: fixture('vip88.source.txt') }),
    signal: ctl.signal,
  });
  assert.equal(r.status, 200);
  const reader = r.body.getReader();
  let seen = '';
  while (!seen.includes('"continuing"')) {
    const { value, done } = await reader.read();
    assert.ok(!done, `没等到续写就结束了：${seen}`);
    seen += Buffer.from(value).toString('utf8');
  }
  for (let i = 0; i < 200 && up.requests.length < 2; i++) await new Promise((res) => setTimeout(res, 10));
  ctl.abort();
  for (let i = 0; i < 200 && up.state.aborted < 1; i++) await new Promise((res) => setTimeout(res, 10));
  assert.equal(up.state.aborted, 1, '续写那条上游请求中止了');
  await new Promise((res) => setTimeout(res, 100));

  // 断过线的测试服务停不干净（要等宽限期），这里不停服务，只读打开库看一眼（WAL 下读不挡写）。
  const db = new DatabaseSync(path.join(h.srv.dataDir, 'famledger.db'), { readOnly: true });
  try {
    const rows = db.prepare('SELECT status, usage_in, usage_out, summary FROM ai_imports').all();
    assert.equal(rows.length, 1, '断开也记了一行');
    const summary = JSON.parse(rows[0].summary);
    assert.deepEqual([rows[0].status, rows[0].usage_in, rows[0].usage_out], ['failed', 123, 45]);
    assert.deepEqual([summary.error, summary.continued], ['client_aborted', true]);
  } finally {
    db.close();
  }
});

test('截图也续写：第二次照样带上全部图片块，名单附在文字块末尾', async (t) => {
  const { up, h } = await setup(t);
  up.state.completions.push(fixture('vip88_part1.output.txt'), fixture('vip88_part2.output.txt'));
  const shots = [pngImage(784, 1568), pngImage(784, 1568)];
  const r = await sse(h.srv.base, '/asset-import/extract', { token: h.token, body: { kind: 'image', images: shots } });
  const { draft } = r.of('done')[0].data;
  assert.deepEqual([draft.continued, draft.truncated, draft.source.kind], [true, false, 'image']);
  assert.equal(up.requests.length, 2);
  const content = up.requests[1].body.messages[0].content;
  assert.deepEqual(content.map((b) => b.type), ['image', 'image', 'text']);
  assert.match(content[2].text, /按顺序附的 2 张截图[\s\S]*已经收到，不要再写/);
});
