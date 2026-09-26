'use strict';

// 从流水识别订阅的纯规则（lib/subscription_detect.js，spec §4 candidates、§8「流水候选」）：不起服务、不查库（EXPLAIN 那条除外）。
// 钉死：候选名单和排序确定（输入顺序打乱也一样）、噪声被排除、归一化商户、金额档、周期、打分、默认勾选、已关联、金额与窗口边界；
// 关键词不误报（英文按词、不算域名、店名里的「会员店」不算、只扣过一次要强关键词才默认勾）；物品的购买流水也算已关联；
// 备注当商户名的组标 fromNote；很长的备注也是线性处理；候选流水的查询走 idx_tx_occurred。

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const { openDb } = require('../src/lib/db');
const perks = require('../src/lib/perks_schema');
const { CANDIDATE_TX_SQL, merchantOf, detectSubscriptions } = require('../src/lib/subscription_detect');
const { TODAY, tx, acceptanceTxs } = require('./subscription_fixtures');

test('验收：腾讯视频 30 × 7、88VIP 88 × 1 进名单，顺序确定；外卖、咖啡、买一次的、超额、不到 1 元、13 个月前的都不进', () => {
  const groups = detectSubscriptions(acceptanceTxs(), { today: TODAY });
  assert.deepEqual(groups.map((g) => g.merchant), ['腾讯视频', '88VIP']);
  const [tv, vip] = groups;
  assert.deepEqual(
    { ...tv, key: undefined },
    {
      key: undefined, merchant: '腾讯视频', amountCents: 3000, minCents: 3000, maxCents: 3000, count: 7,
      period: 'month', periodSource: 'observed', firstOn: '2026-03-22', lastOn: '2026-09-18', nextOn: '2026-10-18',
      score: 7, reasons: ['period', 'regular', 'count', 'same_amount', 'round', 'active'], checked: true, linked: null, lastTransactionId: 'tv0',
      fromNote: false,
    },
  );
  assert.match(tv.key, /^g_[0-9a-f]{12}$/);
  // 88VIP 只扣过一次，但「88VIP」本身就是年费会员（强关键词），照样默认勾。
  assert.deepEqual(
    [vip.count, vip.period, vip.periodSource, vip.lastOn, vip.nextOn, vip.score, vip.reasons, vip.checked],
    [1, 'year', 'keyword', '2026-08-14', '2027-08-14', 5, ['keyword', 'round', 'active'], true],
  );
  // 打乱输入顺序，名单、顺序、key 一个不变。
  const shuffled = acceptanceTxs().reverse();
  shuffled.push(shuffled.shift());
  assert.deepEqual(detectSubscriptions(shuffled, { today: TODAY }), groups);
});

test('归一化商户：去掉支付渠道前缀、长串数字和两头标点；商户名空就用备注；「微信读书」不被当成前缀', () => {
  assert.equal(merchantOf({ merchant: '财付通-腾讯视频' }).key, '腾讯视频');
  assert.equal(merchantOf({ merchant: '支付宝（腾讯视频）' }).label, '腾讯视频');
  assert.equal(merchantOf({ merchant: '微信支付 - 腾讯视频' }).key, merchantOf({ merchant: '腾讯视频' }).key);
  assert.equal(merchantOf({ merchant: '爱奇艺 202609051234567' }).label, '爱奇艺');
  assert.equal(merchantOf({ merchant: '微信读书' }).label, '微信读书');
  assert.deepEqual(merchantOf({ merchant: '', note: '网易云音乐 黑胶VIP' }), { key: '网易云音乐黑胶vip', label: '网易云音乐 黑胶VIP', fromNote: true });
  assert.equal(merchantOf({ merchant: '腾讯视频', note: '私人备注' }).fromNote, false);
  assert.equal(merchantOf({ merchant: '  ', note: '' }), null);
  assert.equal(merchantOf({ merchant: '！！' }), null);
  assert.equal(merchantOf({ merchant: '「（爱奇艺）」' }).label, '爱奇艺');
  // 渠道前缀写法不同也是同一组。
  const groups = detectSubscriptions(
    [tx('a', -5, 3000, '财付通-腾讯视频'), tx('b', -35, 3000, '腾讯视频'), tx('c', -65, 3000, '支付宝（腾讯视频）')],
    { today: TODAY },
  );
  assert.equal(groups.length, 1);
  assert.equal(groups[0].count, 3);
});

test('金额档：同一商户涨价（25 → 30，超过 15%）分成两组；29 和 30 算同一档，金额取中位数', () => {
  const up = [];
  for (let i = 0; i < 3; i++) up.push(tx(`old${i}`, -125 - 30 * i, 2500, '腾讯视频'));
  for (let i = 0; i < 3; i++) up.push(tx(`new${i}`, -5 - 30 * i, 3000, '腾讯视频'));
  const two = detectSubscriptions(up, { today: TODAY });
  assert.deepEqual(two.map((g) => g.amountCents).sort(), [2500, 3000]);
  assert.notEqual(two[0].key, two[1].key);

  const near = detectSubscriptions([tx('a', -5, 2900, '网易云音乐'), tx('b', -35, 3000, '网易云音乐'), tx('c', -65, 3000, '网易云音乐')], { today: TODAY });
  assert.equal(near.length, 1);
  assert.deepEqual([near[0].amountCents, near[0].minCents, near[0].maxCents], [3000, 2900, 3000]);
  assert.ok(!near[0].reasons.includes('same_amount'));
});

test('周期与打分：季付、年付看得出；停了的（最近一次 + 周期 + 15 天已过）照样列出但扣 3 分、不默认勾', () => {
  const q = detectSubscriptions([tx('a', -10, 6800, '百度网盘'), tx('b', -101, 6800, '百度网盘'), tx('c', -192, 6800, '百度网盘')], { today: TODAY });
  assert.deepEqual([q[0].period, q[0].periodSource], ['quarter', 'observed']);
  const y = detectSubscriptions([tx('a', -20, 19800, '爱奇艺'), tx('b', -385, 19800, '爱奇艺')], { today: TODAY, months: 14 });
  assert.deepEqual([y[0].period, y[0].nextOn], ['year', perks.addPeriod(perks.addDays(TODAY, -20), 'year')]);

  const stopped = detectSubscriptions([0, 1, 2, 3].map((i) => tx(`s${i}`, -160 - 30 * i, 1500, '喜马拉雅')), { today: TODAY });
  assert.equal(stopped.length, 1);
  assert.ok(stopped[0].reasons.includes('stale'));
  assert.equal(stopped[0].score, 3);
  assert.equal(stopped[0].checked, false);

  // 只扣过一次、字面说了「包月」按月猜；什么都没说按年。
  const once = detectSubscriptions([tx('m', -3, 1500, 'QQ音乐 豪华绿钻包月'), tx('y', -3, 9900, 'WPS会员')], { today: TODAY });
  const by = Object.fromEntries(once.map((g) => [g.merchant, g]));
  assert.deepEqual([by['QQ音乐 豪华绿钻包月'].period, by['QQ音乐 豪华绿钻包月'].periodSource], ['month', 'keyword']);
  assert.deepEqual([by['WPS会员'].period, by['WPS会员'].periodSource], ['year', 'guess']);
});

test('金额边界：¥1 和 ¥5000 算，¥0.99 和 ¥5000.01 不算；窗口按 months 往前数（边界那天算）', () => {
  const edge = detectSubscriptions(
    [tx('lo', -1, 100, '会员A'), tx('hi', -1, 500000, '会员B'), tx('lo2', -1, 99, '会员C'), tx('hi2', -1, 500001, '会员D')],
    { today: TODAY },
  );
  assert.deepEqual(edge.map((g) => g.merchant).sort(), ['会员A', '会员B']);
  const from = perks.addPeriod(TODAY, 'month', -13);
  const at = (day, id) => ({ id, occurred_at: `${day}T09:00:00+08:00`, amount_cents: 8800, merchant: '88VIP', note: '' });
  assert.equal(detectSubscriptions([at(from, 'in')], { today: TODAY }).length, 1);
  assert.equal(detectSubscriptions([at(perks.addDays(from, -1), 'out')], { today: TODAY }).length, 0);
  assert.equal(detectSubscriptions([at(perks.addDays(TODAY, 1), 'future')], { today: TODAY }).length, 0, '明天的不算');
  assert.equal(detectSubscriptions([at(perks.addDays(from, -1), 'out')], { today: TODAY, months: 14 }).length, 1);
});

test('已关联：某张卡的扣费特征对得上最近一笔、或者这组里有一笔是那张卡的上次扣费 → 标出那张卡、不默认勾', () => {
  const txs = acceptanceTxs();
  const byPattern = detectSubscriptions(txs, {
    today: TODAY,
    cards: [{ id: 'm-tv', name: '腾讯视频VIP', pay_pattern: JSON.stringify({ keywords: ['腾讯视频'], minCents: 2000, maxCents: 4000 }), last_charge_tx_id: null }],
  });
  assert.deepEqual([byPattern[0].linked, byPattern[0].checked], [{ membershipId: 'm-tv', name: '腾讯视频VIP' }, false]);
  assert.deepEqual([byPattern[1].linked, byPattern[1].checked], [null, true]);
  const byCharge = detectSubscriptions(txs, { today: TODAY, cards: [{ id: 'm-vip', name: '88VIP', pay_pattern: null, last_charge_tx_id: 'vip' }] });
  assert.deepEqual(byCharge.find((g) => g.merchant === '88VIP').linked, { membershipId: 'm-vip', name: '88VIP' });
  // 金额对不上扣费特征的不算关联。
  const off = detectSubscriptions(txs, { today: TODAY, cards: [{ id: 'x', name: 'x', pay_pattern: JSON.stringify({ keywords: ['腾讯视频'], maxCents: 1000 }) }] });
  assert.equal(off[0].linked, null);
});

test('关键词不误报：山姆会员商店的日常购物、唯品会（vip.com）、「iPhone 16 Plus」保护壳都不默认勾；英文按词比', () => {
  const noise = detectSubscriptions([
    tx('s1', -3, 35680, '山姆会员商店'), tx('s2', -52, 41250, '山姆会员商店'), tx('s3', -100, 28900, '山姆会员商店'), tx('s4', -145, 12800, '山姆会员商店'),
    tx('v1', -13, 19900, '唯品会', 'vip.com 订单'),
    tx('p1', -22, 59900, 'Apple Store', 'iPhone 16 Plus 保护壳'),
  ], { today: TODAY });
  assert.deepEqual(noise.filter((g) => g.checked), [], JSON.stringify(noise.map((g) => [g.merchant, g.score, g.reasons])));
  assert.ok(!noise.some((g) => g.merchant === '山姆会员商店'), '「会员商店」是店名，不算会员关键词');
  assert.ok(!noise.some((g) => g.merchant === '唯品会'), 'vip.com 是域名，不算 VIP');
  const plus = noise.find((g) => g.merchant === 'Apple Store');
  assert.ok(plus, 'Plus 按词算关键词，照样列出来');
  assert.deepEqual([plus.count, plus.checked, plus.reasons.includes('once')], [1, false, true], '只扣过一次、没有强关键词：列出来、不默认勾');

  // 按词：前后紧挨着英文字母的不算（vipshop），挨着数字、中文、空格的算（88VIP、腾讯视频VIP会员、Plus会员）。
  const words = detectSubscriptions([
    tx('a', -3, 1990, 'vipshop'), tx('b', -3, 2500, '腾讯视频VIP'), tx('c', -3, 1200, 'm.vip.com'), tx('d', -3, 900, 'Spotify Premium'),
  ], { today: TODAY });
  assert.deepEqual(words.map((g) => g.merchant).sort(), ['Spotify Premium', '腾讯视频VIP']);

  // 只扣过一次、名字里有强关键词（年费、包年、年卡、会员费、自动续费、连续包月）：默认勾。
  const strong = detectSubscriptions([
    tx('y1', -3, 26000, '山姆会员年费'), tx('y2', -3, 9900, 'WPS', '自动续费'), tx('y3', -3, 1500, 'QQ音乐 连续包月'), tx('y4', -3, 19800, '京东PLUS'),
  ], { today: TODAY });
  const by = Object.fromEntries(strong.map((g) => [g.merchant, g.checked]));
  assert.deepEqual(by, { 山姆会员年费: true, WPS: true, 'QQ音乐 连续包月': true, 京东PLUS: false });
});

test('已关联（物品）：这组里有一笔是某件物品的购买流水 → 标出那件物品、不默认勾；卡优先', () => {
  const txs = acceptanceTxs();
  const assets = [{ id: 'a-vip', name: '88VIP 年卡', transaction_id: 'vip' }, { id: 'a-x', name: '别的', transaction_id: 'nope' }];
  const byAsset = detectSubscriptions(txs, { today: TODAY, assets });
  const vip = byAsset.find((g) => g.merchant === '88VIP');
  assert.deepEqual([vip.linked, vip.checked], [{ assetId: 'a-vip', name: '88VIP 年卡' }, false]);
  assert.equal(byAsset.find((g) => g.merchant === '腾讯视频').linked, null);
  const both = detectSubscriptions(txs, { today: TODAY, assets, cards: [{ id: 'm-vip', name: '88VIP', pay_pattern: null, last_charge_tx_id: 'vip' }] });
  assert.deepEqual(both.find((g) => g.merchant === '88VIP').linked, { membershipId: 'm-vip', name: '88VIP' });
});

test('备注当商户名：整组都是备注来的标 fromNote；很长、满是标点的备注也是线性处理，不会卡住', () => {
  const noted = detectSubscriptions([0, 1, 2].map((i) => tx(`n${i}`, -5 - 30 * i, 3000, '', '给老婆开的腾讯视频会员 私人备注')), { today: TODAY });
  assert.deepEqual([noted[0].merchant, noted[0].fromNote], ['给老婆开的腾讯视频会员 私人备注', true]);
  const mixed = detectSubscriptions([tx('m1', -5, 3000, '腾讯视频'), tx('m2', -35, 3000, '', '腾讯视频'), tx('m3', -65, 3000, '腾讯视频')], { today: TODAY });
  assert.equal(mixed[0].fromNote, false, '有一笔写了商户名，这个名字就不是私人备注');

  const evil = `a${'！'.repeat(998)}a`;
  const txs = Array.from({ length: 2000 }, (_, i) => tx(`e${i}`, -1 - (i % 300), 1000 + i, '', evil));
  const started = Date.now();
  detectSubscriptions(txs, { today: TODAY });
  assert.ok(Date.now() - started < 1000, `2000 笔长备注用了 ${Date.now() - started}ms`);
});

test('候选流水的 SQL 走 idx_tx_occurred（字符串区间），不挑 idx_tx_dedupe、不另排序', (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'famledger-subs-'));
  const db = openDb(dir);
  t.after(() => {
    db.close();
    fs.rmSync(dir, { recursive: true, force: true });
  });
  const plan = db.all(`EXPLAIN QUERY PLAN ${CANDIDATE_TX_SQL}`, 100, 500000, '2025-08-23', '2026-09-24').map((r) => r.detail);
  assert.ok(plan.some((d) => /USING (COVERING )?INDEX idx_tx_occurred \(occurred_at>\? AND occurred_at<\?\)/.test(d)), plan.join(' | '));
  assert.ok(!plan.some((d) => /idx_tx_dedupe/.test(d)), plan.join(' | '));
  assert.ok(!plan.some((d) => /TEMP B-TREE FOR ORDER BY/.test(d)), plan.join(' | '));
});
