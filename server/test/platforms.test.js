'use strict';

// 平台：CRUD 与校验、规范化名唯一（409 带已有行 id）、删除前查引用（409 带引用数）、合并、同步墓碑。

const test = require('node:test');
const assert = require('node:assert/strict');

const { household } = require('./fixtures');

test('平台 CRUD：默认值、别名规整、PATCH、重排、软删', async (t) => {
  const { a, auth, put } = await household(t);

  const made = await a.post('/platforms', { name: '淘宝', kind: 'shopping', aliases: [' 天猫 ', 'Tmall', 'TMALL', '', '淘 宝'], url: 'https://www.taobao.com' }, auth);
  assert.equal(made.status, 201, made.text);
  const tb = made.json.platform;
  assert.equal(tb.name, '淘宝');
  assert.equal(tb.kind, 'shopping');
  assert.deepEqual(tb.aliases, ['天猫', 'Tmall'], '去空白、去重，和名字同名的别名丢掉');
  assert.equal(tb.url, 'https://www.taobao.com');
  assert.equal(tb.archived, false);
  assert.ok(tb.seq > 0);

  const bare = (await a.post('/platforms', { name: '优酷' }, auth)).json.platform;
  assert.equal(bare.kind, 'other');
  assert.deepEqual(bare.aliases, []);

  const renamed = await a.patch(`/platforms/${bare.id}`, { name: '优酷视频', aliases: ['优酷', 'YOUKU'] }, auth);
  assert.equal(renamed.status, 200, renamed.text);
  assert.deepEqual(renamed.json.platform.aliases, ['优酷', 'YOUKU']);
  const note = await a.patch(`/platforms/${bare.id}`, { note: '家里的号' }, auth);
  assert.deepEqual(note.json.platform.aliases, ['优酷', 'YOUKU'], '无关的 PATCH 不动别名');
  const cleared = await a.patch(`/platforms/${bare.id}`, { aliases: null, url: '' }, auth);
  assert.deepEqual(cleared.json.platform.aliases, []);
  assert.equal(cleared.json.platform.url, null);

  const order = await put('/platforms/reorder', { ids: [bare.id, tb.id] });
  assert.equal(order.status, 200, order.text);
  assert.deepEqual(order.json.items.map((p) => p.id), [bare.id, tb.id]);

  const gone = await a.del(`/platforms/${bare.id}`, auth);
  assert.equal(gone.status, 200, gone.text);
  assert.ok(gone.json.platform.deletedAt);
  assert.deepEqual((await a.get('/platforms', auth)).json.items.map((p) => p.id), [tb.id]);
  assert.equal((await a.get('/platforms')).status, 401);
});

test('平台校验：非法输入一律 400', async (t) => {
  const { a, auth } = await household(t);
  const cases = [
    [{}, 'invalid_name'],
    [{ name: '' }, 'invalid_name'],
    [{ name: 'x'.repeat(41) }, 'invalid_name'],
    [{ name: '！！' }, 'invalid_name'],
    [{ name: '淘宝', kind: 'mall' }, 'invalid_kind'],
    [{ name: '淘宝', aliases: '天猫' }, 'invalid_aliases'],
    [{ name: '淘宝', aliases: ['x'.repeat(31)] }, 'invalid_aliases'],
    [{ name: '淘宝', aliases: Array.from({ length: 21 }, (_, i) => `别名${i}`) }, 'invalid_aliases'],
    [{ name: '淘宝', url: 'taobao://home' }, 'invalid_url'],
    [{ name: '淘宝', color: 'red' }, 'invalid_color'],
    [{ name: '淘宝', note: 'x'.repeat(501) }, 'invalid_note'],
  ];
  for (const [body, code] of cases) {
    const r = await a.post('/platforms', body, auth);
    assert.equal(r.status, 400, `${JSON.stringify(body)} → ${r.status} ${r.text}`);
    assert.equal(r.json.error.code, code, JSON.stringify(body));
  }
  assert.deepEqual((await a.get('/platforms', auth)).json.items, [], '校验失败一条都不落库');
});

test('规范化名唯一：全角、大小写、空格、标点都算同名，409 带已有那行；删掉之后可以再用', async (t) => {
  const { a, auth } = await household(t);
  const youku = (await a.post('/platforms', { name: 'Youku 优酷' }, auth)).json.platform;

  for (const name of ['youku优酷', 'ＹＯＵＫＵ 优酷', 'Youku·优酷', ' YOUKU  优酷 ']) {
    const r = await a.post('/platforms', { name }, auth);
    assert.equal(r.status, 409, `${name} → ${r.text}`);
    assert.equal(r.json.error.code, 'name_taken');
    assert.deepEqual(r.json.error.details, { id: youku.id, name: 'Youku 优酷' }, 'App 靠这个 id 直接改用已有的平台');
  }

  const other = (await a.post('/platforms', { name: '爱奇艺' }, auth)).json.platform;
  const clash = await a.patch(`/platforms/${other.id}`, { name: 'youku 优酷' }, auth);
  assert.equal(clash.status, 409, '改名撞上别人也不行');
  assert.equal(clash.json.error.details.id, youku.id);
  const self = await a.patch(`/platforms/${youku.id}`, { name: 'YOUKU优酷' }, auth);
  assert.equal(self.status, 200, `改自己的写法不算撞名：${self.text}`);

  // 归档的也还「存活」，照样占着名字。
  await a.patch(`/platforms/${other.id}`, { archived: true }, auth);
  assert.equal((await a.post('/platforms', { name: '爱奇艺' }, auth)).status, 409);

  await a.del(`/platforms/${youku.id}`, auth);
  const again = await a.post('/platforms', { name: 'Youku 优酷' }, auth);
  assert.equal(again.status, 201, `软删的不占名字：${again.text}`);
});

test('/changes 同步 platforms：aliases 还原成数组，软删带墓碑', async (t) => {
  const { a, auth } = await household(t);
  const before = (await a.get('/changes?since=0', auth)).json.next;
  const p = (await a.post('/platforms', { name: '京东', aliases: ['JD'] }, auth)).json.platform;
  const delta = (await a.get(`/changes?since=${before}`, auth)).json;
  assert.deepEqual(delta.platforms.map((x) => [x.id, x.aliases, x.archived]), [[p.id, ['JD'], false]]);
  await a.del(`/platforms/${p.id}`, auth);
  const tomb = (await a.get(`/changes?since=${delta.next}`, auth)).json;
  assert.ok(tomb.platforms[0].deletedAt);
});

test('删除前查引用：有会员挂着或被当作领取平台时 409 platform_in_use，带引用数；归档照常', async (t) => {
  const { a, auth } = await household(t);
  const tb = (await a.post('/platforms', { name: '淘宝' }, auth)).json.platform;
  const yk = (await a.post('/platforms', { name: '优酷' }, auth)).json.platform;
  const vip = (await a.post('/memberships', { platformId: tb.id, name: '88VIP' }, auth)).json.membership;
  const perk = (await a.post('/benefits', { membershipId: vip.id, name: '优酷年卡', claimPlatformId: yk.id }, auth)).json.benefit;

  const r1 = await a.del(`/platforms/${tb.id}`, auth);
  assert.equal(r1.status, 409, r1.text);
  assert.equal(r1.json.error.code, 'platform_in_use');
  assert.deepEqual(r1.json.error.details, { memberships: 1, benefits: 0 });
  const r2 = await a.del(`/platforms/${yk.id}`, auth);
  assert.equal(r2.status, 409, r2.text);
  assert.deepEqual(r2.json.error.details, { memberships: 0, benefits: 1 });

  // 归档的会员也还指着它。
  await a.patch(`/memberships/${vip.id}`, { archived: true }, auth);
  assert.equal((await a.del(`/platforms/${tb.id}`, auth)).status, 409);
  assert.equal((await a.patch(`/platforms/${tb.id}`, { archived: true }, auth)).status, 200, '归档随时可以');

  await a.del(`/benefits/${perk.id}`, auth);
  assert.equal((await a.del(`/platforms/${yk.id}`, auth)).status, 200, '引用没了就能删');
});

test('合并：会员和领取平台都改到目标，被并的名字和别名进目标的别名，被并平台软删；重发只算一次', async (t) => {
  const { a, auth } = await household(t);
  const tb = (await a.post('/platforms', { name: '淘宝', aliases: ['淘宝网'] }, auth)).json.platform;
  const tm = (await a.post('/platforms', { name: '天猫', aliases: ['Tmall', '淘宝网'] }, auth)).json.platform;
  const yk = (await a.post('/platforms', { name: '优酷' }, auth)).json.platform;
  const vip = (await a.post('/memberships', { platformId: tm.id, name: '88VIP' }, auth)).json.membership;
  const other = (await a.post('/memberships', { platformId: yk.id, name: '优酷VIP' }, auth)).json.membership;
  const perk = (await a.post('/benefits', { membershipId: other.id, name: '天猫券', claimPlatformId: tm.id }, auth)).json.benefit;
  const before = (await a.get('/changes?since=0', auth)).json.next;

  const body = { targetId: tb.id, clientId: 'merge-1' };
  const r = await a.post(`/platforms/${tm.id}/merge`, body, auth);
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.platform.id, tb.id);
  assert.deepEqual(r.json.platform.aliases, ['淘宝网', '天猫', 'Tmall'], '按规范化名去重，原有的在前');
  assert.deepEqual(r.json.moved, { memberships: 1, benefits: 1 });

  const delta = (await a.get(`/changes?since=${before}`, auth)).json;
  assert.equal(delta.memberships.find((m) => m.id === vip.id).platformId, tb.id);
  assert.equal(delta.benefits.find((b) => b.id === perk.id).claimPlatformId, tb.id);
  assert.ok(delta.platforms.find((p) => p.id === tm.id).deletedAt, '被并平台带墓碑');
  const seqs = [...delta.platforms, ...delta.memberships, ...delta.benefits].map((x) => x.seq);
  assert.equal(new Set(seqs).size, seqs.length, '每行各拿一个 seq');

  const again = await a.post(`/platforms/${tm.id}/merge`, body, auth);
  assert.equal(again.status, 200, `回应丢了重发，照成功回：${again.text}`);
  assert.equal(again.json.replayed, true);
  assert.deepEqual(again.json.moved, { memberships: 1, benefits: 1 });

  assert.equal((await a.post(`/platforms/${tb.id}/merge`, { targetId: tb.id }, auth)).json.error.code, 'invalid_targetId');
  assert.equal((await a.post(`/platforms/${tb.id}/merge`, { targetId: 'nope' }, auth)).json.error.code, 'invalid_targetId');
  assert.equal((await a.post(`/platforms/${tb.id}/merge`, {}, auth)).json.error.code, 'invalid_targetId');
  assert.equal((await a.post(`/platforms/${tm.id}/merge`, { targetId: yk.id }, auth)).status, 404, '被并掉的平台不存在了');
});

test('合并：别名放不下 20 个时只留前 20 个', async (t) => {
  const { a, auth } = await household(t);
  const target = (await a.post('/platforms', { name: '甲', aliases: Array.from({ length: 19 }, (_, i) => `甲${i}`) }, auth)).json.platform;
  const source = (await a.post('/platforms', { name: '乙', aliases: ['乙一', '乙二'] }, auth)).json.platform;
  const r = await a.post(`/platforms/${source.id}/merge`, { targetId: target.id }, auth);
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.platform.aliases.length, 20);
  assert.equal(r.json.platform.aliases[19], '乙', '被并平台的名字排在它的别名前面');
});

test('合并：目标别名已满 20 个时，被并平台的名字挤掉目标最后一个别名，不被静默丢掉', async (t) => {
  const { a, auth } = await household(t);
  const full = Array.from({ length: 20 }, (_, i) => `甲${i}`);
  const target = (await a.post('/platforms', { name: '甲', aliases: full }, auth)).json.platform;
  const source = (await a.post('/platforms', { name: '乙', aliases: ['乙一'] }, auth)).json.platform;
  const r = await a.post(`/platforms/${source.id}/merge`, { targetId: target.id }, auth);
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.json.platform.aliases, [...full.slice(0, 19), '乙'], '以后导入「乙」还认得出是它');
});

test('合并：被并平台的名字超过 30 字当不了别名；目标之后照样能改名、能带着别名存', async (t) => {
  const { a, auth } = await household(t);
  const target = (await a.post('/platforms', { name: '目标', aliases: ['旧名'] }, auth)).json.platform;
  const longName = '一个名字足足有三十五个字的平台'.padEnd(35, '长');
  assert.equal(longName.length, 35);
  const src = (await a.post('/platforms', { name: longName, aliases: ['短别名'] }, auth)).json.platform;

  const r = await a.post(`/platforms/${src.id}/merge`, { targetId: target.id }, auth);
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.json.platform.aliases, ['旧名', '短别名']);
  assert.ok(r.json.platform.aliases.every((x) => x.length <= 30));

  const renamed = await a.patch(`/platforms/${target.id}`, { name: '目标2' }, auth);
  assert.equal(renamed.status, 200, `只改名：${renamed.text}`);
  const asApp = await a.patch(`/platforms/${target.id}`, { name: '目标3', aliases: renamed.json.platform.aliases }, auth);
  assert.equal(asApp.status, 200, `App 的编辑页总带着全部别名：${asApp.text}`);
});
