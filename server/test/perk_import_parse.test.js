'use strict';

// AI 导入的解析与规范化（spec §6「抽取管线」、§8「AI 导入 golden 用例」）。纯函数，吃 test/fixtures/perk_import/ 里的
// 原文和「模型原样输出」：干净 JSON、代码块加废话、第 N 条中间截断、缺哨兵、字符串里有花括号、类型不对、未知枚举、超长、
// N 选 1 合成父权益、未归属、补建领取平台、依据查不到压低置信度、照抄示例、物品白名单。

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const { parseImportOutput, createRecordCounter } = require('../src/lib/perk_import_parse');
const { normalizeImport, yuanToCents, dayOf } = require('../src/lib/perk_import_normalize');

const FIX = path.join(__dirname, 'fixtures', 'perk_import');
const read = (name) => fs.readFileSync(path.join(FIX, name), 'utf8');
const TODAY = '2026-09-23';

/** 解析 + 规范化一份 fixture。 */
function draftOf(output, source, opts = {}) {
  const parsed = parseImportOutput(read(output));
  return { parsed, draft: normalizeImport(parsed.records, { source: read(source), sourceKind: 'text', today: TODAY, ...opts }) };
}
const byName = (list, name) => list.find((n) => n.fields.name === name);

test('解析：干净 JSON / 代码块加前后废话 → 同样的 8 条，见到哨兵', () => {
  for (const f of ['vip88.output.txt', 'vip88_fenced.output.txt']) {
    const p = parseImportOutput(read(f));
    assert.equal(p.ok, true, f);
    assert.equal(p.records.length, 8, f);
    assert.equal(p.done, true, f);
    assert.equal(p.salvaged, false, f);
  }
});

test('解析：第 5 条中间截断 → 状态机救回前 4 条，没有哨兵；缺哨兵的完整数组也算截断', () => {
  const cut = parseImportOutput(read('vip88_truncated.output.txt'));
  assert.equal(cut.ok, true);
  assert.equal(cut.salvaged, true);
  assert.equal(cut.done, false);
  assert.deepEqual(cut.records.map((r) => r.name), ['淘宝', '88VIP', '优酷视频年卡', '饿了么超级会员年卡']);

  const noDone = parseImportOutput(read('vip88_no_done.output.txt'));
  assert.equal(noDone.ok, true);
  assert.equal(noDone.records.length, 8);
  assert.equal(noDone.done, false, '没有 done 哨兵就当截断（结束原因未必透传）');
});

test('解析：字符串里的花括号和引号不打乱逐条抢救；哨兵写进 records 末尾也认；一条都没有 → ok:false', () => {
  const tricky = '{"records":[{"t":"benefit","name":"券 {每月} \\"2 张\\"","ev":"}{"},{"t":"platform","name":"淘';
  const p = parseImportOutput(tricky);
  assert.equal(p.ok, true);
  assert.deepEqual(p.records.map((r) => r.name), ['券 {每月} "2 张"']);

  const inner = parseImportOutput('{"records":[{"t":"platform","name":"淘宝"},{"done":true}]}');
  assert.deepEqual([inner.records.length, inner.done], [1, true]);

  const bare = parseImportOutput('[{"t":"platform","name":"淘宝"}]');
  assert.deepEqual([bare.ok, bare.records.length, bare.done], [true, 1, false], '顶层直接是数组也收，但没有哨兵');

  const empty = parseImportOutput('{"records":[],"done":true}');
  assert.deepEqual([empty.ok, empty.records.length, empty.done], [true, 0, true], '空结果不是坏输出');

  for (const junk of ['我看不懂这段材料。', '{"records":[{"t":', '']) {
    assert.equal(parseImportOutput(junk).ok, false, JSON.stringify(junk));
  }
});

test('流式进度：跨分片数完整收到了几条（字符串里的括号不算）', () => {
  const text = read('vip88_fenced.output.txt');
  const c = createRecordCounter();
  let n = 0;
  const seen = [];
  for (let i = 0; i < text.length; i += 7) {
    n = c.push(text.slice(i, i + 7));
    seen.push(n);
  }
  assert.equal(n, 8);
  assert.deepEqual([...seen].sort((a, b) => a - b), seen, '只增不减');
  const tricky = createRecordCounter();
  assert.equal(tricky.push('{"records":[{"name":"a}{"},{"name":"'), 1);
});

test('规范化 88VIP：补建领取平台（implied）、N 选 1 合成父权益且排在选项前、依据命中给 span', () => {
  const { draft } = draftOf('vip88.output.txt', 'vip88.source.txt');
  assert.deepEqual(draft.platforms.map((p) => [p.key, p.fields.name, p.implied]), [
    ['p1', '淘宝', false], ['p2', '优酷视频', true], ['p3', '饿了么', true], ['p4', '网易云音乐', true], ['p5', 'QQ音乐', true], ['p6', '芒果TV', true],
  ]);
  const vip = draft.memberships[0];
  assert.deepEqual(vip.fields, {
    platform: 'key:p1', name: '88VIP', tier: null, kind: 'membership', feeCents: 8800, feePeriod: 'year',
    termStartOn: null, expiresOn: '2026-12-31', autoRenew: 'yes', isTrial: false,
  });
  assert.deepEqual(draft.benefits.map((b) => b.fields.name), [
    '优酷视频年卡', '饿了么超级会员年卡', '88 折购物券', '三选一', '网易云音乐黑胶年卡', 'QQ 音乐豪华绿钻年卡', '芒果 TV 年卡',
  ]);
  const group = byName(draft.benefits, '三选一');
  assert.equal(group.fields.kind, 'choice');
  assert.deepEqual(group.fields.quota, [{ p: 'term', n: 1 }]);
  for (const o of ['网易云音乐黑胶年卡', 'QQ 音乐豪华绿钻年卡', '芒果 TV 年卡']) {
    const b = byName(draft.benefits, o);
    assert.equal(b.fields.parent, `key:${group.key}`);
    assert.deepEqual(b.fields.quota, [], '选项不单独设额度');
    assert.equal(b.fields.flow, group.fields.flow);
  }
  const yk = byName(draft.benefits, '优酷视频年卡');
  assert.deepEqual([yk.fields.membership, yk.fields.claimPlatform, yk.fields.anchor], ['key:m1', 'key:p2', 'term']);
  const src = read('vip88.source.txt');
  assert.equal(src.slice(yk.span[0], yk.span[1]), '优酷视频年卡，开通后去优酷 App「我的-会员中心」领取');
  const coupon = byName(draft.benefits, '88 折购物券');
  assert.deepEqual(coupon.fields.limits, [{ type: 'min_spend', text: '单笔满 200 元可用' }, { type: 'stacking', text: '不与其他优惠同享' }]);
  assert.equal(coupon.fields.claimPlatform, null, '在会员本平台领');
  assert.ok(draft.benefits.every((b) => b.checked));
  // 「淘宝」原文没写：平台的依据「88VIP 会员说明」在原文里，节点不压置信度；年份 2026 在原文里，到期日不算推断
  assert.deepEqual(vip.unverified, []);
  // 优酷视频原文有；「饿了么」原文有
  assert.ok(!yk.badges.includes('claim_unsure'));
});

test('规范化：类型不对的（「99元」「2027年3月31日」「5次」）照样认；未知枚举按默认；超长裁掉；相对有效期进限制条件；未知 t 丢掉', () => {
  const { draft } = draftOf('types.output.txt', 'types.source.txt');
  assert.equal(draft.dropped, 1, '「coupon」不是认得的 t');
  assert.equal(draft.platforms[0].fields.kind, 'shopping', '「电商」是 shopping 的同义词');
  assert.equal(draft.platforms[0].conf, 0.9, '字符串的 conf 也认');
  const plus = draft.memberships[0];
  assert.deepEqual(
    [plus.fields.name, plus.fields.kind, plus.fields.feeCents, plus.fields.feePeriod, plus.fields.expiresOn, plus.fields.autoRenew],
    ['PLUS {年卡}', 'membership', 9900, 'year', '2027-03-31', 'unknown'],
  );
  const perk = draft.benefits[0];
  assert.equal(perk.fields.name.length, 60, '权益名裁到 60 字');
  assert.equal(perk.fields.membership, 'key:m1');
  assert.deepEqual([perk.fields.kind, perk.fields.flow, perk.fields.anchor], ['shipping', 'claim', 'calendar']);
  assert.deepEqual(perk.fields.quota, [{ p: 'month', n: 5 }], '同一周期只留第一条，不认识的周期丢掉');
  assert.equal(perk.fields.validUntil, null, '相对期限不是日期');
  assert.deepEqual(perk.fields.limits, [
    { type: 'other', text: '仅限自营商品' },
    { type: 'other', text: '其他' },
    { type: 'time', text: '领取后 30 天' },
  ]);
  const band = draft.items[0];
  assert.deepEqual(band.fields, { name: '小米手环 9 "NFC 版"', category: 'digital', preset: null, priceCents: 24900, purchasedOn: '2026-09-01' });
  const lego = draft.items[1];
  assert.deepEqual([lego.fields.category, lego.fields.preset], ['other', null], '类别不在白名单 → 其他；预设和类别对不上 → 不要');
  assert.deepEqual(lego.missing, ['purchasedOn']);
  assert.ok(lego.badges.includes('missing'));
});

test('规范化：依据查不到压到 0.4 并标「依据未核实」；年份和领取平台是推断的进 unverified（字段置信度 ≤0.6）；照抄示例标出来且默认不勾；找不到卡的进未归属', () => {
  const { draft } = draftOf('evidence.output.txt', 'evidence.source.txt');
  const card = byName(draft.memberships, '山姆会员卡');
  assert.deepEqual(card.unverified, ['expiresOn'], '原文只写了 12 月 31 日，年份是推断的');
  assert.ok(card.fieldConf.expiresOn <= 0.6);
  const wash = byName(draft.benefits, '免费洗车');
  assert.deepEqual(wash.unverified, ['claimPlatformId']);
  assert.ok(wash.badges.includes('claim_unsure'), '途虎养车原文没提');
  const voucher = byName(draft.benefits, '50 元代金券');
  assert.equal(voucher.span, null);
  assert.ok(voucher.conf <= 0.4);
  assert.ok(voucher.badges.includes('ev_unverified'));
  assert.ok(voucher.badges.includes('low_conf'));
  assert.equal(voucher.fields.faceValueCents, 5000);
  const parking = byName(draft.benefits, '免费停车');
  assert.equal(parking.fields.membership, null);
  assert.deepEqual(parking.missing, ['membership']);
  assert.equal(parking.checked, false, '未归属的默认不勾');
  const copied = byName(draft.memberships, 'SVIP');
  assert.ok(copied.badges.includes('copied_example'));
  assert.equal(copied.checked, false);
  assert.ok(byName(draft.platforms, '星河视频').badges.includes('copied_example'));
});

test('规范化：识别范围 virtual 丢掉物品、items 只留物品；指定了卡的权益一律归到它', () => {
  const src = read('types.source.txt');
  const records = parseImportOutput(read('types.output.txt')).records;
  const v = normalizeImport(records, { want: 'virtual', source: src, today: TODAY });
  assert.deepEqual([v.items.length, v.dropped], [0, 3]);
  const i = normalizeImport(records, { want: 'items', source: src, today: TODAY });
  assert.deepEqual([i.platforms.length, i.memberships.length, i.benefits.length, i.items.length], [0, 0, 0, 2]);
  const t = normalizeImport(records, { want: 'virtual', source: src, today: TODAY, target: { id: 'm-old' } });
  assert.equal(t.benefits[0].fields.membership, 'id:m-old');
});

test('金额与日期的小工具：元 → 分限制在 0–10 万元；日期必须真实存在', () => {
  assert.equal(yuanToCents('¥1,234.50'), 123450);
  assert.equal(yuanToCents('1.2万'), 1200000);
  assert.equal(yuanToCents(100000), 10000000);
  assert.equal(yuanToCents(100000.01), null, '超过 10 万元当没写（车价在预览里补，apply 收到 1e14 分）');
  assert.equal(yuanToCents(-5), null);
  assert.equal(yuanToCents('免费'), null);
  assert.equal(dayOf('2026/2/28'), '2026-02-28');
  assert.equal(dayOf('2026年2月30日'), null);
  assert.equal(dayOf('12月31日'), null);
});
