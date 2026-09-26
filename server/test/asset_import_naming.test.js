'use strict';

// 从流水识别 · AI 整理名称（spec §6「从流水」：只发规范化商户、金额、周期、次数，不发 raw_text；年费用观测到的中位数覆盖模型给的值；
// 不让模型凭常识补权益）：纯函数 + 真服务 + 假上游（test/fake_upstream.js），不调真模型。
// 钉死：发给模型的只有编号、商户、金额、周期、次数；只认已有分组的 membership 记录；名字用模型的、费用用观测的；模型补的权益丢掉；
// 没填商户名（名字来自备注）的组只发「扣费 ¥30/月 · 第 1 组」这种占位名，备注一个字都不发，模型给它起的名字也不收；
// 模型没按格式写 → 按商户名生成并说明、用量照记；上游出错 → SSE error、不出草稿、名额照还；没有渠道 400、不占限流；
// AI 整理名称占每小时次数。

const test = require('node:test');
const assert = require('node:assert/strict');

const { openDb } = require('../src/lib/db');
const { addProvider } = require('./import_fixtures');
const { detectSubscriptions } = require('../src/lib/subscription_detect');
const { buildNamingPrompt, namesFromOutput } = require('../src/lib/subscription_import');
const { TODAY, tx, acceptanceTxs, setupSubscriptions, seedAcceptance } = require('./subscription_fixtures');

test('AI 整理名称：发给模型的只有编号、商户、金额、周期、次数（备注和原文不发）；只认已有分组的 membership 记录', () => {
  const txs = acceptanceTxs();
  txs[0].note = '订单备注：请勿外传 13912345678';
  const groups = detectSubscriptions(txs, { today: TODAY });
  const prompt = buildNamingPrompt(groups);
  assert.equal(prompt.user, '分组：\ng1｜商户「腾讯视频」｜¥30.00｜每月｜7 次\ng2｜商户「88VIP」｜¥88.00｜每年｜1 次');
  assert.match(prompt.system, /不要补权益/);
  assert.ok(!prompt.user.includes('请勿外传') && !prompt.user.includes('139'));

  const names = namesFromOutput([
    { t: 'membership', group: 'g1', name: '腾讯视频VIP', platform: '腾讯视频', platformKind: 'video', kind: 'subscription', fee: 1 },
    { t: 'membership', group: 'g1', name: '第二条不要' },
    { t: 'membership', group: 'g2', name: '88VIP', platform: '淘宝', platformKind: 'nope', kind: 'credit_card' },
    { t: 'membership', group: 'g9', name: '没有这一组' },
    { t: 'benefit', group: 'g2', name: '优酷年卡' },
    { t: 'membership', group: 'g2 ', name: '重复' },
  ], groups);
  assert.deepEqual([...names.entries()], [
    [groups[0].key, { name: '腾讯视频VIP', platform: '腾讯视频', platformKind: 'video', kind: 'subscription' }],
    [groups[1].key, { name: '88VIP', platform: '淘宝' }],
  ]);
});

test('AI 整理名称：没填商户名的组（名字是备注）只发占位名，备注原文一个字都不发；模型给这组起的名字不收', () => {
  const note = '给老婆开的腾讯视频会员 私人备注 13912345678';
  const txs = [0, 1, 2].map((i) => tx(`n${i}`, -5 - 30 * i, 3000, '', note));
  txs.push(tx('q', -40, 8850, '88VIP'));
  const groups = detectSubscriptions(txs, { today: TODAY });
  assert.deepEqual(groups.map((g) => [g.merchant.slice(0, 5), g.fromNote]), [['给老婆开的', true], ['88VIP', false]]);
  const prompt = buildNamingPrompt(groups);
  assert.equal(prompt.user, '分组：\ng1｜商户「（没有商户名）扣费 ¥30/月 · 第 1 组」｜¥30.00｜每月｜3 次\ng2｜商户「88VIP」｜¥88.50｜每年｜1 次');
  for (const piece of ['老婆', '腾讯视频', '私人备注', '139']) assert.ok(!prompt.user.includes(piece), piece);
  const names = namesFromOutput([
    { t: 'membership', group: 'g1', name: '扣费 ¥30/月 · 第 1 组', platform: '扣费' },
    { t: 'membership', group: 'g2', name: '88VIP', platform: '淘宝' },
  ], groups);
  assert.deepEqual([...names.keys()], [groups[1].key], '备注来的组按本机的名字，不收模型照抄的占位名');
});

test('AI 整理名称：上游出错 → SSE error ai_upstream，不出草稿；名额照还，马上能直接生成', async (t) => {
  const ctx = await setupSubscriptions(t);
  const { up, h, spend, candidates, extract } = ctx;
  for (let i = 0; i < 3; i++) await spend(-5 - 30 * i, 3000, '腾讯视频');
  const [g] = (await candidates()).items;
  up.state.completions.push({ status: 500 });
  const r = await extract({ groups: [g.key], useAi: true });
  assert.equal(r.status, 200, r.text);
  assert.deepEqual([r.of('done').length, r.of('error')[0].data.code], [0, 'ai_upstream']);
  assert.equal((await extract({ groups: [g.key] })).of('done').length, 1, '出错那次的名额已经还了');
  await h.srv.stop();
  const db = openDb(h.srv.dataDir);
  try {
    // 和粘贴、截图一样：上游第一次就出错时没有用量可记，只记成功出草稿的那次（直接生成）。
    assert.deepEqual(db.all("SELECT provider_id FROM ai_imports WHERE source_kind = 'transactions'").map((x) => x.provider_id), [null]);
  } finally {
    db.close();
  }
});

test('AI 整理名称（真服务）：备注当商户名的组，发给模型的是占位名；草稿里这组仍按备注开头起名，并说明为什么', async (t) => {
  const ctx = await setupSubscriptions(t);
  const { up, spend, candidates, extract } = ctx;
  for (let i = 0; i < 3; i++) await spend(-5 - 30 * i, 3000, '', { note: '给老婆开的腾讯视频会员' });
  await spend(-40, 8800, '88VIP');
  const keys = (await candidates()).items.map((g) => g.key);
  up.state.completions.push('{"records":[{"t":"membership","group":"g1","name":"腾讯视频VIP","platform":"腾讯视频"},{"t":"membership","group":"g2","name":"88VIP","platform":"淘宝"}],"done":true}');
  const { draft } = (await extract({ groups: keys, useAi: true })).of('done')[0].data;
  const sent = JSON.stringify(up.lastBody());
  assert.ok(sent.includes('扣费 ¥30/月 · 第 1 组'));
  assert.ok(!sent.includes('老婆') && !sent.includes('腾讯视频会员'), '备注不发给模型');
  assert.deepEqual(draft.memberships.map((m) => m.fields.name), ['给老婆开的腾讯视频会员', '88VIP']);
  assert.deepEqual(draft.notices, ['有 1 组没填商户名（名字是从备注来的），备注不发给 AI，这几组按备注开头生成，导入前可以改']);
});

test('AI 整理名称：没有渠道 400 no_provider（不占限流）；占每小时的导入次数，打满了 429，直接生成照样能用', async (t) => {
  const ctx = await setupSubscriptions(t, { provider: false, env: { AI_IMPORT_PER_HOUR: '1' } });
  const { up, h, spend, candidates, extract } = ctx;
  for (let i = 0; i < 3; i++) await spend(-5 - 30 * i, 3000, '腾讯视频');
  const [g] = (await candidates()).items;
  for (let i = 0; i < 3; i++) assert.equal((await extract({ groups: [g.key] })).of('done').length, 1, `第 ${i + 1} 次直接生成`);
  const noProvider = await extract({ groups: [g.key], useAi: true });
  assert.deepEqual([noProvider.status, noProvider.json.error.code], [400, 'no_provider']);
  await addProvider(h, up);
  up.state.completions.push('{"records":[],"done":true}');
  assert.equal((await extract({ groups: [g.key], useAi: true })).of('done').length, 1);
  const limited = await extract({ groups: [g.key], useAi: true });
  assert.deepEqual([limited.status, limited.json.error.code], [429, 'rate_limited']);
  assert.equal((await extract({ groups: [g.key] })).of('done').length, 1, '限流打满了照样能直接生成');
});

test('AI 整理名称：只发规范化商户、金额、周期、次数；名字用模型的，费用用观测到的中位数，模型补的权益丢掉', async (t) => {
  const ctx = await setupSubscriptions(t);
  const { up, h, candidates, extract } = ctx;
  await seedAcceptance(ctx);
  const keys = (await candidates()).items.map((g) => g.key);
  up.state.completions.push(JSON.stringify({
    records: [
      { t: 'membership', group: 'g1', name: '腾讯视频VIP', platform: '腾讯视频', platformKind: 'video', kind: 'subscription', fee: 1 },
      { t: 'membership', group: 'g2', name: '88VIP', platform: '淘宝', platformKind: 'shopping', kind: 'membership' },
      { t: 'benefit', name: '优酷年卡', membership: '88VIP', claimPlatform: '优酷' },
    ],
    done: true,
  }));
  const r = await extract({ groups: keys, useAi: true });
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.events.map((e) => e.event).filter((e) => e !== 'record'), ['stage', 'stage', 'done']);
  const body = up.lastBody();
  assert.equal(body.max_tokens, 4000);
  assert.equal(body.messages[0].content, '分组：\ng1｜商户「腾讯视频」｜¥30.00｜每月｜7 次\ng2｜商户「88VIP」｜¥88.00｜每年｜1 次');
  assert.ok(!JSON.stringify(body).includes('请勿外传'), '备注不发给模型');
  const { draft } = r.of('done')[0].data;
  assert.deepEqual(draft.platforms.map((p) => [p.fields.name, p.fields.kind]), [['腾讯视频', 'video'], ['淘宝', 'shopping']]);
  assert.deepEqual(draft.memberships.map((m) => [m.fields.name, m.fields.kind, m.fields.feeCents]), [['腾讯视频VIP', 'subscription', 3000], ['88VIP', 'membership', 8800]]);
  assert.equal(draft.benefits.length, 0, '不让模型凭常识补权益');
  assert.deepEqual([draft.notices, draft.usage], [[], { input: 123, output: 45 }]);
});

test('AI 整理名称：模型没按格式写 → 按商户名直接生成并说明，用量照记；只写了一部分 → 其余按商户名', async (t) => {
  const ctx = await setupSubscriptions(t);
  const { up, h, candidates, extract } = ctx;
  await seedAcceptance(ctx);
  const keys = (await candidates()).items.map((g) => g.key);
  up.state.completions.push('抱歉，我不太明白。');
  const bad = (await extract({ groups: keys, useAi: true })).of('done')[0].data;
  assert.deepEqual(bad.draft.memberships.map((m) => m.fields.name), ['腾讯视频', '88VIP']);
  assert.deepEqual(bad.draft.notices, ['模型没有按要求整理名称，已按商户名直接生成']);
  up.state.completions.push('{"records":[{"t":"membership","group":"g2","name":"88VIP","platform":"淘宝"}],"done":true}');
  const half = (await extract({ groups: keys, useAi: true })).of('done')[0].data;
  assert.deepEqual(half.draft.memberships.map((m) => m.fields.name), ['腾讯视频', '88VIP']);
  assert.deepEqual(half.draft.platforms.map((p) => p.fields.name), ['腾讯视频', '淘宝']);
  assert.deepEqual(half.draft.notices, ['模型只整理了 1 组的名称，其余按商户名']);

  await h.srv.stop();
  const db = openDb(h.srv.dataDir);
  try {
    const rows = db.all("SELECT status, usage_in, summary FROM ai_imports WHERE source_kind = 'transactions' ORDER BY created_at");
    assert.deepEqual(rows.map((x) => [x.status, x.usage_in, JSON.parse(x.summary).aiError]), [['extracted', 123, 'ai_bad_output'], ['extracted', 123, null]]);
  } finally {
    db.close();
  }
});
