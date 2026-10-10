'use strict';

// 新建时顺带子项（一步建好，不用建完再去详情里补）：
//   · 会员卡 + benefits（「N 选 1」再带 options）：同一个事务，哪项不对整张卡都不建，报错说清第几项、哪一栏；
//     卡的 clientId 重发原样回、不多建；回应带上建好的权益。
//   · 「N 选 1」权益 + options。
//   · 债务 + settledCents（已经收回 / 还掉的部分）：记了借出那笔就经同一个账户记收回，没记就只改期初留备忘。
//   · 理财 + realizedCents（记账前已领的分红 / 利息；定期类估值扣掉它）。
// 所有数字手算。

const test = require('node:test');
const assert = require('node:assert/strict');

const { household } = require('./fixtures');

function ok(r, what) {
  assert.ok(r.status >= 200 && r.status < 300, `${what} → ${r.status} ${r.text}`);
  return r.json;
}

function fail(r, status, code, what) {
  assert.equal(r.status, status, `${what} → ${r.status} ${r.text}`);
  assert.equal(r.json.error.code, code, `${what} 的错误码`);
  return r.json.error;
}

async function setup(t) {
  const h = await household(t);
  const { a, auth } = h;
  const tb = ok(await a.post('/platforms', { name: '淘宝' }, auth), 'POST 淘宝').platform;
  const yk = ok(await a.post('/platforms', { name: '优酷' }, auth), 'POST 优酷').platform;
  const bank = ok(await a.post('/accounts', { name: '招行卡', kind: 'bank', initialBalanceCents: 1000000 }, auth), 'POST 招行卡').account;
  const list = async (path) => ok(await a.get(path, auth), `GET ${path}`).items;
  return {
    ...h, tb, yk, bank,
    card: (body) => a.post('/memberships', body, auth),
    benefit: (body) => a.post('/benefits', body, auth),
    memberships: () => list('/memberships?archived=1'),
    benefits: () => list('/benefits?archived=1'),
    txs: () => list('/transactions?limit=200'),
    overview: async () => ok(await a.get('/stats/overview', auth), 'GET /stats/overview'),
  };
}

/** 88VIP：一项每年 1 次的「N 选 1」带两个选项，一项每月 4 张的券。 */
const vipBenefits = (yk) => [
  {
    name: '年卡四选一', kind: 'choice', flow: 'claim', quota: [{ p: 'year', n: 1 }],
    options: [
      { name: '优酷年卡', kind: 'subscription', claimPlatformId: yk.id, faceValueCents: 19800 },
      { name: '网易云年卡', kind: 'subscription' },
    ],
  },
  { name: '每月 4 张红包', kind: 'coupon', flow: 'claim_use', quota: [{ p: 'month', n: 4 }], limits: [{ type: 'min_spend', text: '满 99 可用' }] },
];

test('建卡顺带权益和选项：一个请求建好；选项挂在「N 选 1」下、flow 跟它；回应带上；重发不多建', async (t) => {
  const h = await setup(t);
  const body = { platformId: h.tb.id, name: '88VIP', clientId: 'card-1', benefits: vipBenefits(h.yk) };

  const res = await h.card(body);
  assert.equal(res.status, 201, res.text);
  const { membership: vip, benefits } = res.json;
  assert.equal(vip.name, '88VIP');
  assert.equal(benefits.length, 4, '两项顶层 + 两个选项');
  for (const b of benefits) assert.equal(b.membershipId, vip.id);

  const choice = benefits.find((b) => b.name === '年卡四选一');
  const coupon = benefits.find((b) => b.name === '每月 4 张红包');
  const youku = benefits.find((b) => b.name === '优酷年卡');
  const music = benefits.find((b) => b.name === '网易云年卡');
  assert.equal(choice.kind, 'choice');
  assert.equal(choice.parentId, null);
  assert.deepEqual(choice.quota, [{ p: 'year', n: 1 }]);
  assert.equal(coupon.parentId, null);
  assert.equal(coupon.flow, 'claim_use');
  assert.deepEqual(coupon.quota, [{ p: 'month', n: 4 }]);
  assert.deepEqual(coupon.limits, [{ type: 'min_spend', text: '满 99 可用' }]);
  assert.equal(youku.parentId, choice.id);
  assert.equal(youku.claimPlatformId, h.yk.id);
  assert.equal(youku.faceValueCents, 19800);
  assert.equal(music.parentId, choice.id);
  assert.equal(music.flow, 'claim', '选项的 flow 跟着「N 选 1」');
  assert.deepEqual(music.quota, [], '选项不设额度');
  assert.ok(choice.sortOrder < coupon.sortOrder, '顶层按填的顺序排');

  const stored = await h.benefits();
  assert.equal(stored.length, 4, '库里就是这四条');

  const again = await h.card(body);
  assert.equal(again.status, 200, again.text);
  assert.equal(again.json.replayed, true);
  assert.equal(again.json.membership.id, vip.id);
  assert.equal(again.json.benefits.length, 4, '重发也带上权益（现在的样子）');
  assert.equal((await h.benefits()).length, 4, '重发不多建');
  assert.equal((await h.memberships()).length, 1);

  const bare = ok(await h.card({ platformId: h.tb.id, name: '京东 PLUS', clientId: 'card-2' }), 'POST 不带权益');
  assert.equal(bare.benefits, undefined, '没带权益的回应不变');
  const bareAgain = ok(await h.card({ platformId: h.tb.id, name: '京东 PLUS', clientId: 'card-2' }), '重发不带权益的');
  assert.deepEqual(Object.keys(bareAgain).sort(), ['membership', 'replayed'], '老 App 重发看到的还是原来的形状');
  const empty = ok(await h.card({ platformId: h.tb.id, name: '经典白', benefits: [] }), 'POST 空列表');
  assert.equal(empty.benefits, undefined);
  ok(await h.card({ platformId: h.tb.id, name: '空着的', benefits: null }), 'benefits: null 当没给');
});

test('建卡时「N 选 1」的选项跟着它的算法；带长备注的 50 项也收得下（不止 64KB）', async (t) => {
  const h = await setup(t);
  const made = ok(await h.card({
    platformId: h.tb.id, name: '88VIP',
    benefits: [{ name: '用一次算的二选一', kind: 'choice', flow: 'use', options: [{ name: '贵宾厅', flow: 'claim' }] }],
  }), 'POST');
  const option = made.benefits.find((b) => b.name === '贵宾厅');
  assert.equal(option.flow, 'use', '选项写了别的算法也跟着「N 选 1」');

  const note = '备'.repeat(500);
  const many = Array.from({ length: 50 }, (_, i) => ({ name: `权益 ${i}`, note, claimHow: '路'.repeat(200) }));
  assert.ok(Buffer.byteLength(JSON.stringify(many)) > 64 * 1024);
  const big = ok(await h.card({ platformId: h.tb.id, name: '大卡', benefits: many }), 'POST 50 项长备注');
  assert.equal(big.benefits.length, 50);
});

test('顺带的权益哪项不对：整张卡连同「同时记一笔」一起回滚，说清第几项、哪一栏', async (t) => {
  const h = await setup(t);
  const base = { platformId: h.tb.id, name: '88VIP', feeCents: 8800, recordTransaction: { accountId: h.bank.id } };

  let err = fail(
    await h.card({ ...base, benefits: [{ name: '每月红包', quota: [{ p: 'month', n: 4 }] }, { kind: 'coupon' }] }),
    400, 'invalid_name', '第 2 项没名字',
  );
  assert.match(err.message, /^第 2 项权益：/);
  assert.equal(err.details.path, 'benefits.1.name');

  err = fail(
    await h.card({ ...base, benefits: [{ name: '年卡二选一', kind: 'choice', options: [{ name: '优酷' }, { name: '芒果', quota: [{ p: 'year', n: 1 }] }] }] }),
    400, 'invalid_quota', '选项设了额度',
  );
  assert.equal(err.message, '第 1 项权益「年卡二选一」：第 2 个选项「芒果」：选项不单独设额度，额度看它的「N 选 1」');
  assert.equal(err.details.path, 'benefits.0.options.1.quota');

  err = fail(
    await h.card({ ...base, benefits: [{ name: '每月红包', options: [{ name: '优酷' }] }] }),
    400, 'invalid_options', '不是「N 选 1」带选项',
  );
  assert.equal(err.details.path, 'benefits.0.options');
  fail(
    await h.card({ ...base, benefits: [{ name: '年卡二选一', kind: 'choice', options: [{ name: '优酷', kind: 'choice' }] }] }),
    400, 'invalid_kind', '选项不能再是「N 选 1」',
  );
  fail(
    await h.card({ ...base, benefits: [{ name: '年卡二选一', kind: 'choice', options: [{ name: '优酷', options: [{ name: 'x' }] }] }] }),
    400, 'invalid_options', '选项下面不能再挂选项',
  );
  fail(await h.card({ ...base, benefits: [{ name: '贵宾厅', claimPlatformId: 'nope' }] }), 400, 'invalid_claimPlatformId', '领取平台不存在');
  fail(await h.card({ ...base, benefits: { name: '贵宾厅' } }), 400, 'invalid_benefits', '不是数组');
  err = fail(await h.card({ ...base, benefits: ['贵宾厅'] }), 400, 'invalid_benefits', '每项要是对象');
  assert.equal(err.details.path, 'benefits.0');
  err = fail(await h.card({ ...base, benefits: [{ name: '二选一', kind: 'choice', options: [{ name: '优酷' }, 'x'] }] }), 400, 'invalid_options', '选项要是对象');
  assert.equal(err.details.path, 'benefits.0.options.1');
  fail(
    await h.card({ ...base, recordTransaction: 'bank', benefits: [{ name: '贵宾厅' }] }),
    400, 'invalid_recordTransaction', '「同时记一笔」形状不对，先查',
  );
  fail(
    await h.card({ ...base, benefits: Array.from({ length: 51 }, (_, i) => ({ name: `权益 ${i}` })) }),
    400, 'invalid_benefits', '超过 50 项',
  );
  fail(
    await h.card({ ...base, benefits: [{ name: '年卡', kind: 'choice', options: Array.from({ length: 31 }, (_, i) => ({ name: `选项 ${i}` })) }] }),
    400, 'invalid_options', '超过 30 个选项',
  );

  assert.deepEqual(await h.memberships(), [], '一张卡都没建');
  assert.deepEqual(await h.benefits(), [], '一条权益都没建');
  assert.deepEqual(await h.txs(), [], '「同时记一笔」也回滚了');

  // 父权益的 membershipId / parentId 由卡决定：子项里写了别的也不算。
  const other = ok(await h.card({ platformId: h.tb.id, name: '别的卡' }), 'POST 别的卡').membership;
  const made = ok(await h.card({ ...base, benefits: [{ name: '贵宾厅', membershipId: other.id, parentId: 'x' }] }), 'POST 写了别的卡');
  assert.equal(made.benefits[0].membershipId, made.membership.id);
  assert.equal(made.benefits[0].parentId, null);
  assert.equal((await h.txs()).length, 1, '这次记了一笔支出');

  fail(await h.a.patch(`/memberships/${made.membership.id}`, { benefits: [{ name: 'x' }] }, h.auth), 400, 'invalid_benefits', 'PATCH 不收');
  ok(await h.a.patch(`/memberships/${made.membership.id}`, { benefits: null, note: '改个备注' }, h.auth), 'PATCH benefits: null 当没给');
});

test('建「N 选 1」顺带选项：回应带上；PATCH 不收；不是「N 选 1」不收；哪个选项不对整条不建', async (t) => {
  const h = await setup(t);
  const vip = ok(await h.card({ platformId: h.tb.id, name: '88VIP' }), 'POST 88VIP').membership;

  const res = ok(await h.benefit({
    membershipId: vip.id, name: '年卡二选一', kind: 'choice', flow: 'use', quota: [{ p: 'year', n: 1 }], clientId: 'b-1',
    options: [{ name: '优酷年卡', claimPlatformId: h.yk.id }, { name: '芒果年卡' }],
  }), 'POST N 选 1');
  assert.equal(res.benefit.kind, 'choice');
  assert.deepEqual(res.options.map((o) => o.name), ['优酷年卡', '芒果年卡']);
  for (const o of res.options) {
    assert.equal(o.parentId, res.benefit.id);
    assert.equal(o.membershipId, vip.id);
    assert.equal(o.flow, 'use');
  }
  const replay = ok(await h.benefit({ membershipId: vip.id, name: '年卡二选一', kind: 'choice', clientId: 'b-1', options: [{ name: '优酷年卡' }] }), '重发');
  assert.equal(replay.replayed, true);
  assert.equal(replay.options.length, 2, '重发原样回');
  assert.equal((await h.benefits()).length, 3);

  fail(await h.a.patch(`/benefits/${res.benefit.id}`, { options: [{ name: 'x' }] }, h.auth), 400, 'invalid_options', 'PATCH 不收');
  fail(await h.benefit({ membershipId: vip.id, name: '红包', kind: 'coupon', options: [{ name: 'x' }] }), 400, 'invalid_options', '不是 N 选 1');
  const err = fail(
    await h.benefit({ membershipId: vip.id, name: '三选一', kind: 'choice', options: [{ name: '优酷' }, { name: '' }] }),
    400, 'invalid_name', '第 2 个选项没名字',
  );
  assert.equal(err.details.path, 'options.1.name');
  assert.equal((await h.benefits()).length, 3, '整条没建');
  ok(await h.benefit({ membershipId: vip.id, name: '红包', kind: 'coupon', options: null }), 'options: null 当没给');
});

test('债务带「之前已收回 / 已还」：没记账就改期初留备忘、记了账就经同一个账户记收回；超过总数 400；PATCH 不收', async (t) => {
  const h = await setup(t);
  const debt = (body) => h.a.post('/debts', body, h.auth);
  const balance = async (accountId) => (await h.overview()).accounts.find((x) => x.accountId === accountId)?.balanceCents;

  fail(await debt({ direction: 'lend', counterparty: '张三', amountCents: 500000, settledCents: 500001 }), 400, 'invalid_settledCents', '收回的比借的多');
  fail(await debt({ direction: 'lend', counterparty: '张三', amountCents: 500000, settledCents: -1 }), 400, 'invalid_settledCents', '负数');

  const lend = ok(await debt({ direction: 'lend', counterparty: '张三', amountCents: 500000, startedOn: '2026-01-05', settledCents: 200000 }), 'POST 借出').debt;
  assert.equal(lend.amountCents, 500000, '总数还是借出去的那么多');
  assert.equal(await balance(lend.accountId), 300000, '还剩 3000');
  assert.deepEqual(lend.memoLog.map((m) => [m.amountCents, m.note, m.recorded]), [[500000, '起始', false], [-200000, '之前已收回', false]]);
  assert.equal(lend.memoLog[1].action, 'settle');
  assert.equal(lend.memoLog[1].on, '2026-01-05', '哪天收回的不知道：排在起始那天');
  const netBefore = (await h.overview()).netWorthCents;

  const borrow = ok(await debt({
    direction: 'borrow', counterparty: '李四', amountCents: 300000, startedOn: '2026-02-01', settledCents: 100000,
    recordTransaction: { accountId: h.bank.id },
  }), 'POST 借入并记账').debt;
  assert.equal(await balance(borrow.accountId), -200000, '还欠 2000');
  assert.equal(await balance(h.bank.id), 1200000, '借来的 3000 进了招行卡，还掉的 1000 也从招行卡出');
  assert.equal((await h.overview()).netWorthCents, netBefore, '借钱、还钱都不改净资产');
  assert.deepEqual(borrow.memoLog, [], '两笔都是转账，不留备忘');
  const txs = await h.txs();
  assert.deepEqual(
    txs.map((x) => [x.type, x.amountCents, x.merchant, x.occurredAt.slice(0, 10)]).sort(),
    [['transfer', 100000, '还 李四', '2026-02-01'], ['transfer', 300000, '借入 李四', '2026-02-01']],
  );

  const replayBody = { direction: 'lend', counterparty: '重发', amountCents: 1000, settledCents: 400, clientId: 'debt-1' };
  const first = ok(await debt(replayBody), 'POST 重发前').debt;
  ok(await debt(replayBody), '重发');
  assert.equal(await balance(first.accountId), 600, '重发不会再收回一次');

  const favor = ok(await debt({
    direction: 'lend', kind: 'favor', counterparty: '王五', amountCents: 80000, startedOn: '2026-03-01', settledCents: 30000,
    recordTransaction: { accountId: h.bank.id },
  }), 'POST 人情').debt;
  assert.equal(await balance(favor.accountId), 50000, '随了 800、回了 300');
  assert.deepEqual(favor.memoLog.map((m) => [m.amountCents, m.recorded]), [[80000, true], [-30000, true]]);
  const favorTxs = (await h.txs()).filter((x) => x.merchant.includes('王五'));
  assert.deepEqual(favorTxs.map((x) => [x.type, x.amountCents]).sort(), [['expense', 80000], ['income', 30000]], '人情的钱记支出 / 收入');

  const clear = ok(await debt({ direction: 'lend', counterparty: '王五', amountCents: 1000, settledCents: 0 }), 'POST 0').debt;
  assert.equal(clear.memoLog.length, 1, '0 不留行');
  const all = ok(await debt({ direction: 'lend', counterparty: '赵六', amountCents: 1000, settledCents: 1000 }), 'POST 全收回').debt;
  assert.equal(await balance(all.accountId), 0, '早就收回了也能记');

  fail(await h.a.patch(`/debts/${lend.id}`, { settledCents: 1 }, h.auth), 400, 'invalid_settledCents', 'PATCH 不收');
  ok(await h.a.patch(`/debts/${lend.id}`, { settledCents: null, note: '备注' }, h.auth), 'PATCH settledCents: null 当没给');
});

test('理财带已领的分红 / 利息：定期估值扣掉、份额类进已实现盈亏；按金额记的不收；PATCH 不收', async (t) => {
  const h = await setup(t);
  const hold = (body) => h.a.post('/holdings', body, h.auth);

  // 10 万 × 2.15% × 181 天 / 365 = 1066.16；已经领了 500 → 估值 100566.16。
  const fixed = ok(await hold({
    kind: 'fixed', name: '按季付息定期', costCents: 10000000, rateE6: 21500, openedOn: '2025-01-01', maturesOn: '2025-07-01', realizedCents: 50000,
  }), 'POST 定期').holding;
  assert.equal(fixed.realizedCents, 50000);
  const o = await h.overview();
  assert.equal(o.investByKind.find((k) => k.kind === 'fixed').valueCents, 10056616, '领过的利息从估值里扣掉');

  // 到期取出 100566.16（本金 + 还没领的利息）：已实现 = 领过的 500 + 这次多拿的 566.16 = 全部利息 1066.16。
  const done = ok(await h.a.post(`/holdings/${fixed.id}/trade`, { side: 'sell', amountCents: 10056616 }, h.auth), '到期取出').holding;
  assert.equal(done.realizedCents, 106616);

  const fund = ok(await hold({ kind: 'fund', name: '蓝筹精选', quantityE4: 10000000, costCents: 2400000, realizedCents: 12000 }), 'POST 基金').holding;
  assert.equal(fund.realizedCents, 12000, '分红进已实现盈亏');
  ok(await hold({ kind: 'demand', name: '活期', costCents: 1000, realizedCents: null }), 'realizedCents: null 当没给');

  fail(await hold({ kind: 'demand', name: '余额宝', costCents: 1000, realizedCents: 1 }), 400, 'invalid_realizedCents', '活期不收');
  fail(await hold({ kind: 'fund', name: '负数', quantityE4: 1, costCents: 1, realizedCents: -1 }), 400, 'invalid_realizedCents', '负数');
  fail(await h.a.patch(`/holdings/${fund.id}`, { realizedCents: 1 }, h.auth), 400, 'invalid_realizedCents', 'PATCH 不收');
  assert.deepEqual(await h.txs(), [], '都不记流水');
});
