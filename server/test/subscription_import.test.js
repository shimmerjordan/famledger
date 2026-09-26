'use strict';

// 从流水识别的第二步（lib/subscription_import.js，spec §6「从流水」）：勾选的候选分组 → 导入管线认得的 records。纯函数。
// 钉死：费用 = 观测到的中位数、本期开始 = 最近一次扣费、到期日 = 最近一次 + 周期、扣过两次算自动续费；扣费特征过得了
// perks.payPatternOf，以后换了支付渠道前缀的扣费照样对得上；模型给的名字按分组用上，同名的几组合成一张卡。

const test = require('node:test');
const assert = require('node:assert/strict');

const perks = require('../src/lib/perks_schema');
const { readPayPattern, matchesPayPattern } = require('../src/lib/charge_hints');
const { detectSubscriptions } = require('../src/lib/subscription_detect');
const { recordsFromGroups, payPatternFor, evidenceOf } = require('../src/lib/subscription_import');
const { TODAY, tx, acceptanceTxs } = require('./subscription_fixtures');

test('拼 records：费用 = 中位数、本期开始 = 最近一次、到期日 = 最近一次 + 周期、扣过两次算自动续费；扣费特征过得了 payPatternOf', () => {
  const [tv, vip] = detectSubscriptions(acceptanceTxs(), { today: TODAY });
  const records = recordsFromGroups([tv, vip]);
  assert.deepEqual(records.map((r) => [r.t, r.name]), [['platform', '腾讯视频'], ['membership', '腾讯视频'], ['platform', '88VIP'], ['membership', '88VIP']]);
  const card = records[1];
  assert.deepEqual(
    [card.platform, card.kind, card.fee, card.feePeriod, card.termStartOn, card.expiresOn, card.autoRenew, card.lastChargeTxId, card.conf],
    ['腾讯视频', 'subscription', 30, 'month', '2026-09-18', '2026-10-18', 'yes', 'tv0', 0.95],
  );
  assert.equal(card.ev, '腾讯视频 ¥30.00 × 7 次（2026-03-22 至 2026-09-18）');
  assert.deepEqual(card.payPattern, { keywords: ['腾讯视频'], minCents: 2400, maxCents: 3600 });
  assert.deepEqual(perks.payPatternOf(card.payPattern), card.payPattern);
  // 以后的扣费换了支付渠道前缀、备注里才写商户，照样对得上（扣费线索靠它）；金额差太多的不算。
  const pattern = readPayPattern(card.payPattern);
  assert.ok(matchesPayPattern(pattern, { merchant: '财付通-腾讯视频VIP会员', note: '', amount_cents: 3000 }));
  assert.ok(matchesPayPattern(pattern, { merchant: '财付通', note: '腾讯视频 连续包月', amount_cents: 3300 }));
  assert.ok(!matchesPayPattern(pattern, { merchant: '腾讯视频', note: '', amount_cents: 9900 }));
  assert.deepEqual([records[3].autoRenew, records[3].conf, records[3].expiresOn], ['unknown', 0.8, '2027-08-14']);
  assert.equal(evidenceOf(vip), '88VIP ¥88.00 × 1 次（2026-08-14）');
});

test('拼 records：模型给的名字按分组用上；平台、卡名一样的两组合成一张卡（价格日期取最近的那组，金额范围盖住两组）', () => {
  const up = [];
  for (let i = 0; i < 4; i++) up.push(tx(`old${i}`, -95 - 30 * i, 2500, '腾讯视频'));
  for (let i = 0; i < 3; i++) up.push(tx(`new${i}`, -5 - 30 * i, 3000, '财付通-腾讯视频VIP'));
  const groups = detectSubscriptions(up, { today: TODAY });
  assert.equal(groups.length, 2);
  const names = new Map(groups.map((g) => [g.key, { name: '腾讯视频VIP', platform: '腾讯视频', platformKind: 'video' }]));
  const records = recordsFromGroups(groups, names);
  assert.deepEqual(records.map((r) => r.t), ['platform', 'membership']);
  const card = records[1];
  assert.deepEqual([card.name, card.platform, card.fee, card.lastChargeTxId, records[0].kind], ['腾讯视频VIP', '腾讯视频', 30, 'new0', 'video']);
  assert.deepEqual(card.payPattern, { keywords: ['腾讯视频VIP', '腾讯视频'], minCents: 2000, maxCents: 3600 });
  assert.deepEqual(payPatternFor(groups), card.payPattern);
});
