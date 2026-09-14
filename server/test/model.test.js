'use strict';

// GET/POST/DELETE /model — the family-shared naive-bayes counts.
// Every case gets its own server + data dir, so the seeded model and the
// version counter never leak between cases.

const test = require('node:test');
const assert = require('node:assert/strict');
const { DatabaseSync } = require('node:sqlite');
const path = require('node:path');

const { startServer, api } = require('./helpers');
const nb = require('../src/lib/nb');
const { NB_SEED } = require('../src/modules/seed');

const SETUP = {
  householdName: '小明家',
  username: 'admin',
  password: 'hunter22',
  displayName: '小明',
};

async function bootstrapped(t, env) {
  const srv = await startServer(env);
  t.after(() => srv.stop());
  const a = api(srv.base);
  const r = await a.post('/setup', SETUP);
  assert.equal(r.status, 200, `setup failed: ${r.text}`);
  return { srv, a, token: r.json.token, member: r.json.member };
}

/** Read the household's categories straight from SQLite (no /categories yet). */
function categories(srv, t) {
  const db = new DatabaseSync(path.join(srv.dataDir, 'famledger.db'), { readOnly: true });
  t.after(() => db.close());
  return db.prepare('SELECT id, name, kind FROM categories WHERE deleted_at IS NULL').all();
}

const idOf = (rows, name, kind = 'expense') => rows.find((c) => c.name === name && c.kind === kind).id;

/** The household's funds (setup seeds exactly one: 家庭公共基金). */
function funds(srv, t) {
  const db = new DatabaseSync(path.join(srv.dataDir, 'famledger.db'), { readOnly: true });
  t.after(() => db.close());
  return db.prepare('SELECT id, name FROM funds WHERE deleted_at IS NULL').all();
}

/** Real ids — labels must now be rows this household actually owns. */
function realIds(srv, t) {
  const cats = categories(srv, t);
  return { cats, catA: idOf(cats, '宠物'), catB: idOf(cats, '餐饮'), fundA: funds(srv, t)[0].id };
}

// ① ---------------------------------------------------------------------
test('① 首次 GET /model 返回由种子训练出的模型：≥15 个类别、version 1、fund 为空', async (t) => {
  const { srv, a, token } = await bootstrapped(t);
  const r = await a.get('/model', { token });
  assert.equal(r.status, 200, r.text);

  assert.equal(r.json.version, 1);
  const cat = r.json.category;
  const fund = r.json.fund;

  assert.deepEqual(Object.keys(cat).sort(), ['classes', 'totalDocs', 'version', 'vocab']);
  assert.equal(cat.version, 1);
  const labels = Object.keys(cat.classes);
  assert.ok(labels.length >= 15, `种子模型应至少 15 个类别，实得 ${labels.length}`);
  assert.equal(cat.totalDocs, NB_SEED.length, '每条种子样本训练一次');
  assert.ok(cat.vocab > 100);
  assert.equal(cat.vocab, nb.vocabOf(cat));

  // label 必须是真实存在的 category id，不是类别名
  const rows = categories(srv, t);
  const ids = new Set(rows.map((c) => c.id));
  for (const l of labels) assert.ok(ids.has(l), `label ${l} 不是真实的 category id`);

  // 每个类的计数自洽
  for (const c of Object.values(cat.classes)) {
    assert.ok(c.docs > 0);
    assert.equal(c.tokens, Object.values(c.counts).reduce((s, n) => s + n, 0));
  }

  assert.deepEqual(fund, { version: 1, classes: {}, vocab: 0, totalDocs: 0 });
});

test('① 种子模型能把典型通知文本分到正确类别', async (t) => {
  const { srv, a, token } = await bootstrapped(t);
  const { json } = await a.get('/model', { token });
  const rows = categories(srv, t);
  const expect = [
    ['美团外卖 订单支付', '餐饮'],
    ['滴滴出行 行程费用', '交通'],
    ['国家电网 电费', '水电'],
    ['中国移动 话费充值', '通讯'],
    ['工资 代发', '工资', 'income'],
  ];
  for (const [text, name, kind] of expect) {
    const top = nb.predict(json.category, nb.tokenize(text))[0];
    assert.equal(top.label, idOf(rows, name, kind || 'expense'), `「${text}」应判成 ${name}，实得别的`);
  }
});

test('① GET /model 幂等：第二次返回同一份，且不重复训练', async (t) => {
  const { a, token } = await bootstrapped(t);
  const one = await a.get('/model', { token });
  const two = await a.get('/model', { token });
  assert.deepEqual(two.json, one.json);
});

test('① DELETE /model 要管理员：普通成员 403，管理员 200', async (t) => {
  const { srv, a, token } = await bootstrapped(t);
  const { catA } = realIds(srv, t);
  const created = await a.post('/members', { username: 'xiaohong', password: 'hunter22', displayName: '小红' }, { token });
  assert.equal(created.status, 201, created.text);
  const login = await a.post('/auth/login', { username: 'xiaohong', password: 'hunter22' });
  assert.equal(login.status, 200, login.text);
  const memberToken = login.json.token;

  // 成员能读、能学，就是不能清
  assert.equal((await a.get('/model', { token: memberToken })).status, 200);
  assert.equal((await a.post('/model/learn', { samples: [{ text: '猫粮', categoryId: catA }] }, { token: memberToken })).status, 200);

  const denied = await a.del('/model', { token: memberToken });
  assert.equal(denied.status, 403, denied.text);
  assert.equal(denied.json.error.code, 'forbidden');
  // 403 之后模型必须原封不动
  assert.equal((await a.get('/model', { token })).json.category.version, 2);

  const ok = await a.del('/model', { token });
  assert.equal(ok.status, 200, ok.text);
  assert.deepEqual(ok.json, { ok: true });
  // 重置后版本【严格变大】，绝不回退：缓存了 2 的设备必须还会再拉一次
  assert.equal((await a.get('/model', { token })).json.category.version, 3);
});

test('① 所有 /model 接口都要登录', async (t) => {
  const { a } = await bootstrapped(t);
  assert.equal((await a.get('/model')).status, 401);
  assert.equal((await a.post('/model/learn', { samples: [] })).status, 401);
  assert.equal((await a.del('/model')).status, 401);
});

// ② ---------------------------------------------------------------------
test('② POST /model/learn：version 单调递增，且预测被样本改写', async (t) => {
  const { srv, a, token } = await bootstrapped(t);
  const rows = categories(srv, t);
  const pet = idOf(rows, '宠物');
  const text = '美团外卖 订单支付';

  const before = await a.get('/model', { token });
  assert.equal(before.json.version, 1);
  assert.notEqual(nb.predict(before.json.category, nb.tokenize(text))[0].label, pet);

  const samples = [];
  for (let i = 0; i < 30; i++) samples.push({ text, categoryId: pet, direction: 'expense' });
  const learn = await a.post('/model/learn', { samples }, { token });
  assert.equal(learn.status, 200, learn.text);
  assert.equal(learn.json.version, 2);
  assert.deepEqual(learn.json.learned, { category: 30, fund: 0 });

  const after = await a.get('/model', { token });
  assert.equal(after.json.version, 2);
  assert.equal(after.json.category.version, 2);
  assert.equal(after.json.fund.version, 1, 'fund 没被学过，版本不动');
  assert.equal(after.json.category.totalDocs, before.json.category.totalDocs + 30);
  assert.equal(after.json.category.vocab, nb.vocabOf(after.json.category));

  // 预测被改写：extras 要一起带上才是同一组特征
  const q = nb.tokenize(text, nb.extrasFor({ direction: 'expense' }));
  assert.equal(nb.predict(after.json.category, q)[0].label, pet);

  // 再学一次，版本继续单调
  const again = await a.post('/model/learn', { samples: [{ text: '猫粮', categoryId: pet }] }, { token });
  assert.equal(again.json.version, 3);
  assert.equal((await a.get('/model', { token })).json.category.version, 3);
});

test('② learn 同时喂 category 与 fund，两个模型各自 +1', async (t) => {
  const { srv, a, token } = await bootstrapped(t);
  const { catA, catB, fundA } = realIds(srv, t);
  const r = await a.post('/model/learn', {
    samples: [
      { text: '小区物业费', merchant: '物业', direction: 'expense', channel: 'alipay',
        amountCents: 120000, hour: 9, weekday: 3, categoryId: catB, fundId: fundA, memberId: 'mem-1' },
      { text: '猫砂', categoryId: catA },
      { text: '没有标签的样本' },
    ],
  }, { token });
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.version, 2);
  assert.deepEqual(r.json.learned, { category: 2, fund: 1 });

  const { json } = await a.get('/model', { token });
  assert.equal(json.category.version, 2);
  assert.equal(json.fund.version, 2);
  assert.equal(json.fund.totalDocs, 1);
  assert.deepEqual(Object.keys(json.fund.classes), [fundA]);

  // extras 按约定顺序进了 counts
  const counts = json.fund.classes[fundA].counts;
  for (const e of ['m:物业', 'dir:expense', 'ch:alipay', 'amt:b4', 'h:9', 'wd:3', 'mem:mem-1']) {
    assert.equal(counts[e], 1, `缺少特征 ${e}`);
  }
  assert.ok(counts['物业'] >= 1);
});

test('② 零 token 的样本（无文本、无特征）不落账，version 不动', async (t) => {
  const { srv, a, token } = await bootstrapped(t);
  const { catA, fundA } = realIds(srv, t);
  const seed = await a.get('/model', { token });
  const r = await a.post('/model/learn', { samples: [{ categoryId: catA }, { text: '  ¥ . ', fundId: fundA }] }, { token });
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.json.learned, { category: 0, fund: 0 });
  assert.equal(r.json.version, 1);
  assert.deepEqual((await a.get('/model', { token })).json, seed.json);
});

test('② learn 空 samples / 全是无标签样本 → 版本不动', async (t) => {
  const { a, token } = await bootstrapped(t);
  await a.get('/model', { token });
  const r = await a.post('/model/learn', { samples: [] }, { token });
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.version, 1);
  assert.deepEqual(r.json.learned, { category: 0, fund: 0 });

  const r2 = await a.post('/model/learn', { samples: [{ text: '随便写点什么' }] }, { token });
  assert.equal(r2.json.version, 1);
  assert.equal((await a.get('/model', { token })).json.version, 1);
});

test('② learn 在未初始化模型的库上也能工作（先建种子再累加）', async (t) => {
  const { srv, a, token } = await bootstrapped(t);
  const { catA } = realIds(srv, t);
  // 注意：这里没有先 GET /model
  const r = await a.post('/model/learn', { samples: [{ text: '猫粮', categoryId: catA }] }, { token });
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.version, 2);
  const { json } = await a.get('/model', { token });
  assert.equal(json.category.totalDocs, NB_SEED.length + 1, '种子没有被绕过');
});

// ③ 校验 -----------------------------------------------------------------
test('③ 原型键当 label：400，而且服务端模型分毫未动', async (t) => {
  const { srv, a, token } = await bootstrapped(t);
  const { catA } = realIds(srv, t);
  const before = await a.get('/model', { token });

  for (const evil of ['__proto__', 'constructor', 'prototype', 'toString', 'valueOf']) {
    const c = await a.post('/model/learn', { samples: [{ text: 'abc', categoryId: evil }] }, { token });
    assert.equal(c.status, 400, `categoryId=${evil} 必须 400（不能 500，更不能 200），实得 ${c.status} ${c.text}`);
    assert.equal(c.json.error.code, 'invalid_categoryId', c.text);

    const f = await a.post('/model/learn', { samples: [{ text: 'abc', fundId: evil }] }, { token });
    assert.equal(f.status, 400, `fundId=${evil} 必须 400，实得 ${f.status} ${f.text}`);
    assert.equal(f.json.error.code, 'invalid_fundId', f.text);
  }

  // 混在一批合法样本里也要整批拒绝，不能学一半
  const mixed = await a.post('/model/learn', {
    samples: [{ text: '正常样本', categoryId: catA }, { text: 'abc', categoryId: '__proto__' }],
  }, { token });
  assert.equal(mixed.status, 400);
  assert.equal(mixed.json.error.code, 'invalid_categoryId');

  // 模型必须与攻击前逐字段相同（版本也没动）
  assert.deepEqual((await a.get('/model', { token })).json, before.json);

  // 而且进程还是好的：紧接着一条合法样本照常学得进去
  const ok = await a.post('/model/learn', { samples: [{ text: '猫粮', categoryId: catA }] }, { token });
  assert.equal(ok.status, 200, ok.text);
  assert.equal(ok.json.version, 2);
});

test('③ 超出词表上限的批次被拒，且不落库', async (t) => {
  const { srv, a, token } = await bootstrapped(t);
  const { catA } = realIds(srv, t);
  const before = await a.get('/model', { token });

  // 每条 500 个随机汉字 ≈ 499 个几乎必然唯一的 2-gram，450 条越过 20 万词表上限
  // （1-gram 只有 2 万种，很快就撞满，真正堆词表的是 2-gram）
  const rand = () => {
    let out = '';
    for (let i = 0; i < 500; i++) out += String.fromCodePoint(0x4e00 + ((Math.random() * 20000) | 0));
    return out;
  };
  const r = await a.post('/model/learn', {
    samples: Array.from({ length: 450 }, () => ({ text: rand(), categoryId: catA })),
  }, { token });
  assert.equal(r.status, 400, `应当 400 model_too_large，实得 ${r.status} ${r.text.slice(0, 120)}`);
  assert.equal(r.json.error.code, 'model_too_large', r.text);

  // 被拒之后库里的模型必须原封不动（含 version）
  assert.deepEqual((await a.get('/model', { token })).json, before.json);
});

test('③ learn 参数校验', async (t) => {
  const { srv, a, token } = await bootstrapped(t);
  const { catA } = realIds(srv, t);
  const bad = async (body, code) => {
    const r = await a.post('/model/learn', body, { token });
    assert.equal(r.status, 400, `${JSON.stringify(body).slice(0, 60)} 应该 400，实得 ${r.status} ${r.text}`);
    if (code) assert.equal(r.json.error.code, code, r.text);
  };
  await bad({ samples: 'x' }, 'invalid_samples');
  await bad({ samples: Array.from({ length: 501 }, () => ({ text: 'a', categoryId: 'c' })) }, 'invalid_samples');
  await bad({ samples: [{ text: 'x'.repeat(501), categoryId: 'c' }] }, 'invalid_text');
  await bad({ samples: ['nope'] }, 'invalid_sample');
  await bad({ samples: [{ text: 'a', direction: 'sideways' }] }, 'invalid_direction');
  await bad({ samples: [{ text: 'a', hour: 24 }] }, 'invalid_hour');
  await bad({ samples: [{ text: 'a', weekday: 9 }] }, 'invalid_weekday');
  await bad({ samples: [{ text: 'a', amountCents: -1 }] }, 'invalid_amountCents');
  await bad({ samples: [{ text: 'a', amountCents: 1.5 }] }, 'invalid_amountCents');
  await bad({ samples: [{ text: 123, categoryId: 'c' }] }, 'invalid_text');
  await bad({ samples: [{ text: 'a', categoryId: 'x'.repeat(65) }] }, 'invalid_categoryId');
  // label 必须是本家庭真实存在的行
  await bad({ samples: [{ text: 'a', categoryId: '11111111-2222-3333-4444-555555555555' }] }, 'invalid_categoryId');
  await bad({ samples: [{ text: 'a', fundId: '11111111-2222-3333-4444-555555555555' }] }, 'invalid_fundId');
  await bad({ samples: [{ text: 'a', categoryId: 'nope' }] }, 'invalid_categoryId');
  // memberId 只是特征位，但也不允许原型键与怪字符
  await bad({ samples: [{ text: 'a', memberId: '__proto__' }] }, 'invalid_memberId');
  await bad({ samples: [{ text: 'a', memberId: 'constructor' }] }, 'invalid_memberId');
  await bad({ samples: [{ text: 'a', memberId: 'prototype' }] }, 'invalid_memberId');
  await bad({ samples: [{ text: 'a', memberId: 'a b' }] }, 'invalid_memberId');
  await bad({ samples: [{ text: 'a', memberId: 'x:y' }] }, 'invalid_memberId');

  // 500 条正好放得下（默认 64KB body 上限不够用，路由必须放宽）
  const ok = await a.post('/model/learn', {
    samples: Array.from({ length: 500 }, () => ({ text: '美团外卖订单支付成功'.repeat(20), categoryId: catA })),
  }, { token });
  assert.equal(ok.status, 200, `500 条 × 200 字应当被接受，实得 ${ok.status} ${ok.text.slice(0, 120)}`);
  assert.equal(ok.json.learned.category, 500);
});

// ④ ---------------------------------------------------------------------
test('④ DELETE /model 重置：再 GET 与最初的种子同内容，但版本严格变大', async (t) => {
  const { srv, a, token } = await bootstrapped(t);
  const { catB, fundA } = realIds(srv, t);
  const seed = await a.get('/model', { token });

  await a.post('/model/learn', {
    samples: [
      { text: '把餐饮带偏', categoryId: catB },
      { text: '顺便污染基金', fundId: fundA },
    ],
  }, { token });
  const dirty = await a.get('/model', { token });
  assert.notDeepEqual(dirty.json.category, seed.json.category);
  assert.equal(dirty.json.version, 2);

  const del = await a.del('/model', { token });
  assert.equal(del.status, 200, del.text);
  assert.deepEqual(del.json, { ok: true });

  const reset = await a.get('/model', { token });
  const sameContent = (got, want) => {
    assert.deepEqual(got.category.classes, want.category.classes);
    assert.equal(got.category.vocab, want.category.vocab);
    assert.equal(got.category.totalDocs, want.category.totalDocs);
    assert.deepEqual(got.fund.classes, want.fund.classes);
    assert.equal(got.fund.totalDocs, want.fund.totalDocs);
  };
  sameContent(reset.json, seed.json, '重置后内容必须与种子一致');
  // …但版本号【绝不回退】：重建出来的种子拿的是新的全局计数
  assert.ok(reset.json.version > dirty.json.version,
    `重置后 version 必须严格大于 ${dirty.json.version}，实得 ${reset.json.version}`);
  assert.equal(reset.json.category.version, reset.json.version);
  assert.equal(reset.json.fund.version, reset.json.version);

  // 重复 DELETE 幂等（内容不变，版本继续往上走）
  const v2 = reset.json.version;
  assert.deepEqual((await a.del('/model', { token })).json, { ok: true });
  const again = await a.get('/model', { token });
  sameContent(again.json, seed.json);
  assert.ok(again.json.version > v2, '再删一次，版本还要更大');
});
