'use strict';

// AI 导入的比对（spec §6「比对」、§8「比对」「实物」）：天猫 → alias；淘宝网 → maybe 且未预选；88VIP → update 且取更晚的
// 日期；同名两张卡 → ambiguous；物品同名同价 → 已存在；关联流水的三种情况（唯一 / 多笔 / 没有）。
// 直接开一个临时库往里塞行，不起服务（比对是纯读库的函数）。

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');

const { openDb } = require('../src/lib/db');
const { tmpDir } = require('./helpers');
const { normalizeImport } = require('../src/lib/perk_import_normalize');
const { matchImport, matchPlatform, editDistance, unionLimits } = require('../src/lib/perk_import_match');

const TODAY = '2026-09-23';

/** 临时库 + 往表里插行的小工具（seq 递增）。 */
function scratch(t) {
  const dir = tmpDir('match');
  const db = openDb(dir);
  t.after(() => {
    db.close();
    fs.rmSync(dir, { recursive: true, force: true });
  });
  const now = new Date().toISOString();
  let seq = 0;
  const put = (table, row) => {
    const all = { ...row, created_at: now, updated_at: now, seq: ++seq };
    const keys = Object.keys(all);
    db.run(`INSERT INTO ${table}(${keys.join(', ')}) VALUES(${keys.map(() => '?').join(', ')})`, ...keys.map((k) => all[k]));
  };
  const tx = (id, amount, occurredAt, extra = {}) =>
    put('transactions', { id, type: 'expense', amount_cents: amount, occurred_at: occurredAt, member_id: 'm1', created_by: 'm1', merchant: id, ...extra });
  return { db, put, tx };
}

const draftOf = (records, source) => normalizeImport(records, { source, today: TODAY });

test('平台：exact 与种子表 alias 默认并入；「淘宝网」只是 maybe，候选列出来但仍是新建（不预选）', (t) => {
  const { db, put } = scratch(t);
  put('platforms', { id: 'tb', name: '淘宝', aliases: '[]' });
  put('platforms', { id: 'yk', name: '优酷', aliases: '["优酷视频"]' });
  const source = '淘宝 天猫 淘宝网 优酷视频 京东';
  const draft = matchImport(db, draftOf([
    { t: 'platform', name: '淘宝', ev: '淘宝' },
    { t: 'platform', name: '天猫', ev: '天猫' },
    { t: 'platform', name: '淘宝网', ev: '淘宝网' },
    { t: 'platform', name: '优酷视频', ev: '优酷视频' },
    { t: 'platform', name: '京东', ev: '京东' },
  ], source));
  const by = Object.fromEntries(draft.platforms.map((p) => [p.fields.name, p]));
  assert.deepEqual([by['淘宝'].match.kind, by['淘宝'].action, by['淘宝'].targetId], ['exact', 'merge', 'tb']);
  assert.deepEqual([by['天猫'].match.kind, by['天猫'].action, by['天猫'].targetId], ['alias', 'merge', 'tb'], '种子表：淘宝 = 天猫');
  assert.deepEqual([by['优酷视频'].match.kind, by['优酷视频'].targetId], ['alias', 'yk'], '库里的别名');
  assert.equal(by['淘宝网'].match.kind, 'maybe');
  assert.deepEqual(by['淘宝网'].match.candidates, [{ id: 'tb', name: '淘宝' }]);
  assert.deepEqual([by['淘宝网'].action, by['淘宝网'].targetId], ['create', null], 'maybe 只提示、不预选');
  assert.ok(by['淘宝网'].badges.includes('maybe_dup'));
  assert.deepEqual([by['京东'].match.kind, by['京东'].action], ['none', 'create']);
});

test('会员：88VIP 唯一命中 → update，到期日取更晚的并勾上，原来空的勾上，费用不同不勾；没提到的权益列出来', (t) => {
  const { db, put } = scratch(t);
  put('platforms', { id: 'tb', name: '淘宝', aliases: '[]' });
  put('memberships', { id: 'vip', platform_id: 'tb', name: '88VIP', fee_cents: 8800, expires_on: '2026-06-30', auto_renew: 'unknown' });
  put('benefits', { id: 'b-yk', membership_id: 'vip', name: '优酷视频年卡', quota: '[{"p":"term","n":1}]', limits: '[{"type":"other","text":"限本人"}]' });
  put('benefits', { id: 'b-old', membership_id: 'vip', name: '淘票票观影券' });
  const source = '88VIP 年费 99 元 到期日 2026-12-31 自动续费；优酷视频年卡 限本人 不与其他优惠同享；去优酷领';
  const draft = matchImport(db, draftOf([
    { t: 'platform', name: '淘宝', ev: '88VIP' },
    { t: 'membership', name: '88VIP', platform: '淘宝', fee: 99, feePeriod: 'year', expiresOn: '2026-12-31', autoRenew: 'yes', ev: '88VIP 年费 99 元' },
    {
      t: 'benefit', name: '优酷视频年卡', membership: '88VIP', claimPlatform: '优酷', quota: [{ p: 'term', n: 1 }],
      limits: [{ type: 'other', text: '限本人' }, { type: 'stacking', text: '不与其他优惠同享' }], ev: '优酷视频年卡',
    },
  ], source));
  const vip = draft.memberships[0];
  assert.deepEqual([vip.action, vip.targetId, vip.match.kind], ['update', 'vip', 'update']);
  const diff = Object.fromEntries(vip.diff.map((d) => [d.field, d]));
  assert.deepEqual(diff.expiresOn, { field: 'expiresOn', old: '2026-06-30', new: '2026-12-31', take: true });
  assert.deepEqual(diff.feeCents, { field: 'feeCents', old: 8800, new: 9900, take: false });
  assert.deepEqual(diff.autoRenew, { field: 'autoRenew', old: 'unknown', new: 'yes', take: true });
  assert.equal(diff.feePeriod, undefined, '一样的不列');
  assert.deepEqual(vip.notMentioned, [{ id: 'b-old', name: '淘票票观影券' }]);

  const yk = draft.benefits[0];
  assert.deepEqual([yk.action, yk.targetId], ['update', 'b-yk']);
  const bd = Object.fromEntries(yk.diff.map((d) => [d.field, d]));
  assert.equal(bd.quota, undefined);
  assert.deepEqual(bd.limits.new, [{ type: 'other', text: '限本人' }, { type: 'stacking', text: '不与其他优惠同享' }], 'limits 取并集');
  assert.equal(bd.limits.take, true);
  assert.deepEqual(bd.claimPlatform, { field: 'claimPlatform', old: null, new: 'key:p2', take: true }, '原来没写领取平台');
});

test('会员：新的到期日更早 → 列出差异但不勾（留着更晚的旧值）；同名两张卡持有人不明 → ambiguous，必须选', (t) => {
  const { db, put } = scratch(t);
  put('platforms', { id: 'jd', name: '京东', aliases: '[]' });
  put('memberships', { id: 'plus-a', platform_id: 'jd', name: 'PLUS', member_id: 'dad', expires_on: '2027-03-01' });
  put('memberships', { id: 'plus-b', platform_id: 'jd', name: 'PLUS', member_id: 'mom', expires_on: '2026-11-01' });
  put('platforms', { id: 'sam', name: '山姆', aliases: '[]' });
  put('memberships', { id: 'sam-1', platform_id: 'sam', name: '山姆会员卡', expires_on: '2027-01-31' });
  const draft = matchImport(db, draftOf([
    { t: 'membership', name: 'PLUS', platform: '京东', expiresOn: '2026-12-31', ev: 'PLUS' },
    { t: 'membership', name: '山姆会员卡', platform: '山姆', expiresOn: '2026-12-31', ev: '山姆会员卡' },
  ], 'PLUS 京东 山姆会员卡 2026-12-31'));
  const plus = draft.memberships[0];
  assert.deepEqual([plus.action, plus.targetId, plus.match.kind], ['pick', null, 'ambiguous']);
  assert.deepEqual(plus.match.candidates.map((c) => [c.id, c.memberId]), [['plus-a', 'dad'], ['plus-b', 'mom']]);
  assert.ok(plus.badges.includes('ambiguous'));
  const sam = draft.memberships[1];
  assert.deepEqual(sam.diff, [{ field: 'expiresOn', old: '2027-01-31', new: '2026-12-31', take: false }]);
});

test('同名两张卡（Review ⑧）：每张候选各带一份差异和「未提及」，卡下的权益按候选各比一次（byCard），选定哪张换上哪份', (t) => {
  const { db, put } = scratch(t);
  put('platforms', { id: 'jd', name: '京东', aliases: '[]' });
  put('memberships', { id: 'plus-a', platform_id: 'jd', name: 'PLUS', expires_on: '2026-10-01' });
  put('memberships', { id: 'plus-b', platform_id: 'jd', name: 'PLUS', expires_on: '2026-11-01', fee_cents: 9900 });
  put('benefits', { id: 'b-ship', membership_id: 'plus-b', name: '免运费券', quota: '[{"p":"month","n":5}]' });
  put('benefits', { id: 'b-old', membership_id: 'plus-b', name: '联名视频卡' });
  const draft = matchImport(db, draftOf([
    { t: 'membership', name: 'PLUS', platform: '京东', expiresOn: '2027-11-01', fee: 99, ev: 'PLUS' },
    { t: 'benefit', name: '免运费券', membership: 'PLUS', quota: [{ p: 'month', n: 6 }], faceValue: 6, ev: '免运费券' },
    { t: 'benefit', name: '新权益', membership: 'PLUS', ev: '新权益' },
  ], 'PLUS 京东 2027-11-01 年费 99 免运费券 新权益'));
  const plus = draft.memberships[0];
  assert.equal(plus.action, 'pick');
  const [ca, cb] = plus.match.candidates;
  assert.deepEqual(ca.diff.map((d) => [d.field, d.take]), [['feeCents', true], ['expiresOn', true]]);
  assert.deepEqual(cb.diff.map((d) => [d.field, d.take]), [['expiresOn', true]], '费用一样不列');
  assert.deepEqual([ca.notMentioned, cb.notMentioned], [[], [{ id: 'b-old', name: '联名视频卡' }]]);
  const [ship, fresh] = draft.benefits;
  assert.deepEqual([ship.action, ship.targetId], ['create', null], '没选之前还是新建');
  assert.deepEqual(Object.keys(ship.byCard), ['plus-b'], '只有 b 下面有同名的');
  assert.equal(ship.byCard['plus-b'].targetId, 'b-ship');
  assert.deepEqual(ship.byCard['plus-b'].diff.map((d) => [d.field, d.take]), [['quota', false], ['faceValueCents', true]]);
  assert.deepEqual(fresh.byCard, {});
});

test('归档的卡、权益（Review ⑩）：没归档的优先；只有归档的才命中它，差异里多一项「恢复」且默认勾，候选带上好让 App 给「新建一张」', (t) => {
  const { db, put } = scratch(t);
  put('platforms', { id: 'tb', name: '淘宝', aliases: '[]' });
  put('memberships', { id: 'vip-old', platform_id: 'tb', name: '88VIP', expires_on: '2025-12-31', archived: 1 });
  put('benefits', { id: 'yk-old', membership_id: 'vip-old', name: '优酷视频年卡', archived: 1 });
  put('platforms', { id: 'jd', name: '京东', aliases: '[]' });
  put('memberships', { id: 'plus-old', platform_id: 'jd', name: 'PLUS', archived: 1 });
  put('memberships', { id: 'plus-now', platform_id: 'jd', name: 'PLUS' });
  const draft = matchImport(db, draftOf([
    { t: 'membership', name: '88VIP', platform: '淘宝', expiresOn: '2026-12-31', ev: '88VIP' },
    { t: 'benefit', name: '优酷视频年卡', membership: '88VIP', ev: '优酷视频年卡' },
    { t: 'membership', name: 'PLUS', platform: '京东', ev: 'PLUS' },
  ], '88VIP 淘宝 2026-12-31 优酷视频年卡 PLUS 京东'));
  const [vip, plus] = draft.memberships;
  assert.deepEqual([vip.action, vip.targetId, vip.match.archived], ['update', 'vip-old', true]);
  assert.deepEqual(vip.diff.map((d) => [d.field, d.old, d.new, d.take]), [['expiresOn', '2025-12-31', '2026-12-31', true], ['archived', true, false, true]]);
  assert.deepEqual(vip.match.candidates.map((c) => [c.id, c.archived]), [['vip-old', true]]);
  const yk = draft.benefits[0];
  assert.deepEqual([yk.action, yk.targetId, yk.match.archived], ['update', 'yk-old', true]);
  assert.deepEqual(yk.diff.at(-1), { field: 'archived', old: true, new: false, take: true });
  assert.ok(yk.byCard['vip-old'], '卡有候选（能改成新建）时权益也带 byCard');
  assert.deepEqual([plus.action, plus.targetId, plus.match.candidates], ['update', 'plus-now', undefined], '有没归档的就只看没归档的');
});

test('权益按（卡, 「N 选 1」, 名称）比：顶层只和顶层比、选项只和命中的那个「N 选 1」下面的比；update 带上库里现在的值（current）', (t) => {
  const { db, put } = scratch(t);
  put('platforms', { id: 'tb', name: '淘宝', aliases: '[]' });
  put('memberships', { id: 'vip', platform_id: 'tb', name: '88VIP', fee_cents: 8800, expires_on: '2026-06-30' });
  put('benefits', { id: 'mg-top', membership_id: 'vip', name: '芒果 TV 年卡', claim_platform_id: 'tb', quota: '[{"p":"term","n":1}]' });
  put('benefits', { id: 'grp', membership_id: 'vip', name: '视频二选一', kind: 'choice' });
  put('benefits', { id: 'yk-opt', membership_id: 'vip', parent_id: 'grp', name: '优酷年卡' });
  const draft = matchImport(db, draftOf([
    { t: 'membership', name: '88VIP', platform: '淘宝', expiresOn: '2026-12-31', ev: '88VIP' },
    { t: 'benefit', name: '芒果 TV 年卡', membership: '88VIP', choice: { group: '音乐三选一', pick: 1 }, ev: '芒果 TV 年卡' },
    { t: 'benefit', name: 'QQ 音乐年卡', membership: '88VIP', choice: { group: '音乐三选一', pick: 1 }, ev: 'QQ 音乐年卡' },
    { t: 'benefit', name: '优酷年卡', membership: '88VIP', choice: { group: '视频二选一', pick: 1 }, ev: '优酷年卡' },
    { t: 'benefit', name: '腾讯视频年卡', membership: '88VIP', choice: { group: '视频二选一', pick: 1 }, ev: '腾讯视频年卡' },
  ], '88VIP 芒果 TV 年卡 QQ 音乐年卡 音乐三选一 优酷年卡 腾讯视频年卡 视频二选一'));
  const vip = draft.memberships[0];
  assert.equal(vip.action, 'update');
  assert.deepEqual(vip.current, {
    name: '88VIP', tier: null, kind: 'membership', feeCents: 8800, feePeriod: 'year', termStartOn: null, expiresOn: '2026-06-30', autoRenew: 'unknown',
  });
  const by = Object.fromEntries(draft.benefits.map((b) => [b.fields.name, b]));
  assert.deepEqual([by['音乐三选一'].action, by['芒果 TV 年卡'].action], ['create', 'create'], '新建的「N 选 1」下的选项不和顶层同名的那项比');
  assert.deepEqual([by['视频二选一'].action, by['视频二选一'].targetId], ['update', 'grp']);
  assert.deepEqual([by['优酷年卡'].action, by['优酷年卡'].targetId], ['update', 'yk-opt'], '命中的「N 选 1」下面的选项照样比');
  assert.equal(by['腾讯视频年卡'].action, 'create');
  assert.equal(by['优酷年卡'].current.name, '优酷年卡');
  assert.deepEqual(by['视频二选一'].current.claimPlatform, null);
});

test('新建的平台下面的卡一律新建（没有可比的）；指定了卡（id:）的权益按那张卡比', (t) => {
  const { db, put } = scratch(t);
  put('platforms', { id: 'tb', name: '淘宝', aliases: '[]' });
  put('memberships', { id: 'vip', platform_id: 'tb', name: '88VIP' });
  put('benefits', { id: 'b1', membership_id: 'vip', name: '购物券', face_value_cents: null });
  const draft = normalizeImport(
    [{ t: 'benefit', name: '购物券', faceValue: 5, ev: '购物券' }, { t: 'benefit', name: '新权益', ev: '新权益' }],
    { source: '购物券 5 元 新权益', today: TODAY, target: { id: 'vip' } },
  );
  matchImport(db, draft);
  assert.deepEqual(draft.benefits.map((b) => [b.fields.membership, b.action, b.targetId]), [['id:vip', 'update', 'b1'], ['id:vip', 'create', null]]);
  assert.deepEqual(draft.benefits[0].diff, [{ field: 'faceValueCents', old: null, new: 500, take: true }]);

  const fresh = matchImport(db, draftOf([{ t: 'membership', name: '88VIP', platform: '新平台', ev: '88VIP' }], '88VIP 新平台'));
  assert.deepEqual([fresh.platforms[0].action, fresh.memberships[0].action], ['create', 'create']);
});

test('物品：同名同价 → 默认跳过、标「已存在」；名字相近只提示；关联流水：唯一一笔默认关联，多笔只列不选，没有就不记账', (t) => {
  const { db, put, tx } = scratch(t);
  put('assets', { id: 'a-old', name: 'iPhone 16 Pro 256GB', price_cents: 899900, purchased_on: '2026-09-01' });
  tx('t-hit', 599900, '2026-09-21T20:00:00+08:00');
  tx('t-far', 599900, '2026-09-25T20:00:00+08:00'); // 差 5 天
  tx('t-pending', 599900, '2026-09-20T20:00:00+08:00', { status: 'pending' });
  tx('t-income', 599900, '2026-09-20T20:00:00+08:00', { type: 'income' });
  tx('t-a', 12900, '2026-09-19T10:00:00+08:00');
  tx('t-b', 12900, '2026-09-22T10:00:00+08:00');
  tx('t-linked', 34900, '2026-09-20T10:00:00+08:00');
  put('assets', { id: 'a-linked', name: '别的东西', price_cents: 34900, purchased_on: '2026-09-20', transaction_id: 't-linked' });
  const source = 'iPhone 16 Pro 256GB 8999 iPad mini 5999 数据线 129 充电头 349 耳机 99';
  const draft = matchImport(db, draftOf([
    { t: 'item', name: 'iPhone 16 Pro 256GB', category: 'digital', price: 8999, purchasedOn: '2026-09-20', ev: 'iPhone 16 Pro 256GB' },
    { t: 'item', name: 'iPad mini', category: 'digital', price: 5999, purchasedOn: '2026-09-20', ev: 'iPad mini' },
    { t: 'item', name: '数据线', price: 129, purchasedOn: '2026-09-20', ev: '数据线' },
    { t: 'item', name: '充电头', price: 349, purchasedOn: '2026-09-20', ev: '充电头' },
    { t: 'item', name: 'iPhone 16 Pro', price: 99, purchasedOn: '2026-09-20', ev: '耳机 99' },
  ], source));
  const [phone, pad, cable, charger, near] = draft.items;
  assert.deepEqual([phone.action, phone.checked, phone.match.kind, phone.match.id], ['skip', false, 'exists', 'a-old']);
  assert.ok(phone.badges.includes('exists'));
  assert.deepEqual(pad.txCandidates.map((c) => c.id), ['t-hit'], '只有日期 ±3 天、确认过的支出');
  assert.deepEqual(pad.link, { mode: 'link', transactionId: 't-hit' });
  assert.deepEqual(cable.txCandidates.map((c) => c.id).sort(), ['t-a', 't-b']);
  assert.deepEqual(cable.link, { mode: 'none', transactionId: null }, '多笔只列不选');
  assert.deepEqual([charger.txCandidates, charger.link.mode], [[], 'none'], '已经关联给别的物品的那笔不再当候选');
  assert.equal(near.match.kind, 'near');
  assert.ok(near.badges.includes('maybe_dup'));
  assert.equal(near.action, 'create');
});

test('全角、大小写、空格不同的名字照样命中（Review Focus ④）：ＰＬＵＳ = PLUS，88vip = 88VIP，「京 东」= 京东', (t) => {
  const { db, put } = scratch(t);
  put('platforms', { id: 'jd', name: '京东', aliases: '[]' });
  put('memberships', { id: 'plus', platform_id: 'jd', name: 'PLUS', expires_on: '2026-10-01' });
  put('platforms', { id: 'tb', name: '淘宝', aliases: '[]' });
  put('memberships', { id: 'vip', platform_id: 'tb', name: '88VIP' });
  const draft = matchImport(db, draftOf([
    { t: 'membership', name: 'ＰＬＵＳ', platform: '京 东', expiresOn: '2027-10-01', ev: 'ＰＬＵＳ' },
    { t: 'membership', name: '88vip', platform: '淘宝', ev: '88vip' },
  ], 'ＰＬＵＳ 京东 88vip 2027-10-01'));
  assert.deepEqual(draft.platforms.map((p) => [p.action, p.targetId]), [['merge', 'jd'], ['merge', 'tb']]);
  assert.deepEqual(draft.memberships.map((m) => [m.action, m.targetId]), [['update', 'plus'], ['update', 'vip']]);
});

test('小工具：matchPlatform 不认空名；编辑距离带上限；limits 并集按规范化文字去重', () => {
  assert.deepEqual(matchPlatform([{ id: 'x', name: '淘宝', aliases: '[]' }], '  '), { kind: 'none' });
  assert.equal(editDistance('优酷', '优步'), 1);
  assert.equal(editDistance('abcdef', 'uvwxyz'), 3, '超过上限提前返回 cap + 1');
  assert.deepEqual(
    unionLimits([{ type: 'other', text: '限本人' }], [{ type: 'holder', text: '限 本人。' }, { type: 'time', text: '周末可用' }]),
    [{ type: 'other', text: '限本人' }, { type: 'time', text: '周末可用' }],
  );
});
