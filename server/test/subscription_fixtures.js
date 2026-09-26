'use strict';

// 从流水识别的测试共用（P7）：纯规则测试的固定「今天」、造流水的小工具和验收那组流水；接口测试的一户人家 + 记流水、取候选、
// 发识别的小工具，以及往真服务里种验收流水。只用 helpers.js / fixtures.js / import_fixtures.js 现有的导出，不改它们。

const assert = require('node:assert/strict');

const { household } = require('./fixtures');
const perks = require('../src/lib/perks_schema');
const { startFakeAnthropic } = require('./fake_upstream');
const { ANT_KEY, sse, addProvider } = require('./import_fixtures');

/** 纯规则测试的「今天」（和 App 测试的固定时钟同一天）。 */
const TODAY = '2026-09-23';
/** 纯函数的一笔确认支出：TODAY 往前 [days] 天上午九点。 */
const tx = (id, days, cents, merchant, note = '') => ({ id, occurred_at: `${perks.addDays(TODAY, days)}T09:00:00+08:00`, amount_cents: cents, merchant, note });

/** 验收那一组（纯函数版）：腾讯视频 30 元 × 7 个月、88VIP 88 元 × 1 次，外加各种噪声。 */
function acceptanceTxs() {
  const txs = [];
  for (let i = 0; i < 7; i++) txs.push(tx(`tv${i}`, -5 - 30 * i, 3000, '腾讯视频'));
  txs.push(tx('vip', -40, 8800, '88VIP'));
  // 噪声：金额每次不同的外卖、隔三差五的咖啡、买一次的东西、超过 ¥5000 的、不到 ¥1 的（带关键词也不要）、13 个月以前的。
  [[3550, -3], [4200, -9], [2880, -17], [5120, -26]].forEach(([c, d], i) => txs.push(tx(`mt${i}`, d, c, '美团外卖')));
  [-2, -4, -7, -16, -20].forEach((d, i) => txs.push(tx(`sb${i}`, d, 3300, '星巴克')));
  txs.push(tx('jd', -50, 29900, '京东'));
  for (let i = 0; i < 3; i++) txs.push(tx(`big${i}`, -10 - 30 * i, 699900, 'Apple Store'));
  txs.push(tx('tiny', -12, 50, '会员积分兑换'));
  txs.push(tx('old', -430, 2500, '优酷VIP'));
  return txs;
}

const pad = (n) => String(n).padStart(2, '0');
/** 本地日期，偏移 `days` 天（helpers.js 已把本进程钉在 Asia/Shanghai，和子进程一致）。 */
function localDay(days = 0) {
  const d = new Date();
  d.setDate(d.getDate() + days);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}
const at = (days) => `${localDay(days)}T09:00:00+08:00`;

/**
 * 一户人家（[provider] 为真时挂一个指向假上游的渠道，用来断言「一个请求都没打到上游」）+ 小工具：
 *   spend(days, cents, merchant, body)  记一笔确认支出（今天往前 days 天）
 *   candidates(query)                   GET /asset-import/candidates，断言 200 回 json
 *   extract(body)                       POST /asset-import/extract（kind 默认 transactions），回 sse() 的结果
 */
async function setupSubscriptions(t, { provider = true, env } = {}) {
  const up = await startFakeAnthropic({ key: ANT_KEY });
  t.after(() => up.stop());
  const h = await household(t, env);
  if (provider) await addProvider(h, up);
  const spend = async (days, cents, merchant, body = {}) => {
    const r = await h.tx({
      type: 'expense', amountCents: cents, accountId: h.account.id, fundId: h.fund.id, categoryId: h.category.id,
      occurredAt: at(days), merchant, ...body,
    });
    assert.equal(r.status, 201, r.text);
    return r.json.transaction;
  };
  const candidates = async (query = '') => {
    const r = await h.a.get(`/asset-import/candidates${query}`, h.auth);
    assert.equal(r.status, 200, r.text);
    return r.json;
  };
  const extract = (body) => sse(h.srv.base, '/asset-import/extract', { token: h.token, body: { kind: 'transactions', ...body } });
  return { up, h, spend, candidates, extract };
}

/**
 * 往真服务里种验收流水：腾讯视频 30 × 7 个月（最近那笔备注里有句不该发给模型的话）、88VIP 88 × 1 次，外加噪声（金额每次不同、
 * 隔三差五、买一次、超额、不到 1 元、待确认、收入、删掉的、13 个月前的）。回 {tv:[最近的在前], vip}。
 */
async function seedAcceptance({ h, spend }) {
  const tv = [];
  for (let i = 0; i < 7; i++) tv.push(await spend(-5 - 30 * i, 3000, '腾讯视频', { note: i === 0 ? '订单备注：请勿外传' : '' }));
  const vip = await spend(-40, 8800, '88VIP');
  for (const [c, d] of [[3550, -3], [4200, -9], [2880, -17], [5120, -26]]) await spend(d, c, '美团外卖');
  for (const d of [-2, -4, -7, -16, -20]) await spend(d, 3300, '星巴克');
  await spend(-50, 29900, '京东');
  for (let i = 0; i < 3; i++) await spend(-10 - 30 * i, 699900, 'Apple Store');
  await spend(-12, 50, '会员积分兑换');
  await spend(-6, 3000, '腾讯视频', { status: 'pending' });
  for (let i = 0; i < 3; i++) {
    const r = await h.a.post('/transactions', {
      type: 'income', amountCents: 2500, accountId: h.account.id, fundId: h.fund.id, occurredAt: at(-8 - 30 * i), merchant: '爱奇艺VIP',
    }, h.auth);
    assert.equal(r.status, 201, r.text);
  }
  const gone = await spend(-15, 1900, '网易云音乐 黑胶VIP');
  await h.a.del(`/transactions/${gone.id}`, h.auth);
  await spend(-430, 2500, '优酷VIP');
  return { tv, vip };
}

module.exports = { TODAY, tx, acceptanceTxs, localDay, at, setupSubscriptions, seedAcceptance };
