'use strict';

// GET /asset-import/candidates?months=13（spec §4、§7 P7 验收）：真服务 + 真 HTTP，纯规则、不花 token。种入腾讯视频 30 元 × 7 个月、
// 88VIP 88 元 × 1 次和噪声，断言候选名单和排序确定（两次一样）、噪声被排除；months 1–24、默认 13；只回前 40 组；要登录。

const test = require('node:test');
const assert = require('node:assert/strict');

const perks = require('../src/lib/perks_schema');
const { localDay, setupSubscriptions, seedAcceptance } = require('./subscription_fixtures');

test('验收：候选名单只有腾讯视频、88VIP，顺序确定、两次一样；外卖、咖啡、买一次的、超额、不到 1 元、待确认、收入、删掉的、13 个月前的都不进', async (t) => {
  const ctx = await setupSubscriptions(t, { provider: false });
  const { candidates } = ctx;
  const { tv, vip } = await seedAcceptance(ctx);
  const first = await candidates();
  assert.deepEqual(first.items.map((g) => g.merchant), ['腾讯视频', '88VIP']);
  assert.deepEqual([first.months, first.total, first.today, first.from], [13, 2, localDay(0), perks.addPeriod(localDay(0), 'month', -13)]);
  const [g1, g2] = first.items;
  assert.deepEqual(
    [g1.amountCents, g1.count, g1.period, g1.lastOn, g1.nextOn, g1.score, g1.checked, g1.linked, g1.lastTransactionId],
    [3000, 7, 'month', localDay(-5), perks.addPeriod(localDay(-5), 'month'), 7, true, null, tv[0].id],
  );
  assert.match(g1.key, /^g_[0-9a-f]{12}$/);
  assert.deepEqual([g2.count, g2.period, g2.score, g2.checked, g2.lastTransactionId], [1, 'year', 5, true, vip.id]);
  assert.deepEqual(await candidates(), first, '同样的流水、同样的名单');
});

test('months：默认 13，1–24 之外或不是整数 400 invalid_months；往前多看几个月，13 个月前那笔「优酷VIP」也列出来（停了的、不默认勾）；要登录', async (t) => {
  const ctx = await setupSubscriptions(t, { provider: false });
  const { h, candidates } = ctx;
  await seedAcceptance(ctx);
  for (const q of ['?months=0', '?months=25', '?months=abc', '?months=1.5']) {
    const r = await h.a.get(`/asset-import/candidates${q}`, h.auth);
    assert.deepEqual([r.status, r.json.error.code], [400, 'invalid_months'], q);
  }
  const wider = await candidates('?months=15');
  assert.equal(wider.months, 15);
  const old = wider.items.find((g) => g.merchant === '优酷VIP');
  assert.ok(old, wider.items.map((g) => g.merchant).join(','));
  assert.deepEqual([old.checked, old.reasons.includes('stale')], [false, true]);
  assert.equal((await h.a.get('/asset-import/candidates')).status, 401);
});

test('只回前 40 组，total 是一共认出几组', async (t) => {
  const { spend, candidates } = await setupSubscriptions(t, { provider: false });
  for (let i = 1; i <= 41; i++) await spend(-3, 1000 + i * 100, `会员${String(i).padStart(2, '0')}`);
  const r = await candidates();
  assert.deepEqual([r.total, r.items.length], [41, 40]);
});
