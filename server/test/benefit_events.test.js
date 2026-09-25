'use strict';

// 打卡事件：新建（默认值、今天、不校验额度）、校验（权益存活、N 选 1 父权益 400、日期不晚于今天、份数、价值、成员）、
// 幂等重发、改、删（撤销打卡）与 /changes 墓碑。

const test = require('node:test');
const assert = require('node:assert/strict');

const { household } = require('./fixtures');

const pad = (n) => String(n).padStart(2, '0');
/** 本地日期，偏移 `days` 天；helpers.js 已把本进程钉在 Asia/Shanghai，和子进程一致。 */
function localDay(days = 0) {
  const d = new Date();
  d.setDate(d.getDate() + days);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

/** 一户人家 + 淘宝下的 88VIP：购物券（每月 1 张）、「年卡二选一」和它的选项「优酷年卡」。 */
async function withPerks(t) {
  const h = await household(t);
  const { a, auth } = h;
  const tb = (await a.post('/platforms', { name: '淘宝' }, auth)).json.platform;
  const vip = (await a.post('/memberships', { platformId: tb.id, name: '88VIP', feeCents: 8800 }, auth)).json.membership;
  const post = async (body) => (await a.post('/benefits', { membershipId: vip.id, ...body }, auth)).json.benefit;
  const coupon = await post({ name: '购物券', kind: 'coupon', quota: [{ p: 'month', n: 1 }], faceValueCents: 500 });
  const choice = await post({ name: '年卡二选一', kind: 'choice', quota: [{ p: 'year', n: 1 }] });
  const option = await post({ name: '优酷年卡', parentId: choice.id });
  const event = (body) => a.post('/benefit-events', body, auth);
  return { ...h, vip, coupon, choice, option, event };
}

test('打卡：默认 claim ×1、今天；不校验额度（每月 1 张也能记第二次）；列表新的在前，/changes 带上', async (t) => {
  const { a, auth, member, coupon, option, event } = await withPerks(t);
  const before = (await a.get('/changes?since=0', auth)).json.next;

  const first = await event({ benefitId: coupon.id });
  assert.equal(first.status, 201, first.text);
  const e = first.json.event;
  assert.equal(e.benefitId, coupon.id);
  assert.equal(e.kind, 'claim');
  assert.equal(e.count, 1);
  assert.equal(e.occurredOn, localDay(0), '不给日期就是今天');
  assert.equal(e.valueCents, null);
  assert.equal(e.memberId, null);

  const again = await event({ benefitId: coupon.id, kind: 'use', count: 2, occurredOn: localDay(-3), valueCents: 450, memberId: member.id, note: '超市' });
  assert.equal(again.status, 201, '超额也照记：超额只在 App 里显示「超额 N」，不拦');
  assert.equal(again.json.event.count, 2);
  assert.equal(again.json.event.valueCents, 450);
  assert.equal(again.json.event.memberId, member.id);
  const skip = await event({ benefitId: option.id, kind: 'skip' });
  assert.equal(skip.status, 201, '选项可以打卡，也可以本期跳过');

  const listed = (await a.get('/benefit-events', auth)).json.items;
  assert.deepEqual(listed.map((x) => x.occurredOn), [localDay(0), localDay(0), localDay(-3)], '新的在前');
  const delta = (await a.get(`/changes?since=${before}`, auth)).json.benefit_events;
  assert.deepEqual(delta.map((x) => x.id).sort(), [e.id, again.json.event.id, skip.json.event.id].sort());
});

test('打卡校验：权益不存在 / 已删 / 是 N 选 1 本身，日期在将来，份数、价值、成员不对，一律 400', async (t) => {
  const { a, auth, coupon, choice, event } = await withPerks(t);
  const gone = (await a.post('/benefits', { membershipId: coupon.membershipId, name: '删掉的券' }, auth)).json.benefit;
  await a.del(`/benefits/${gone.id}`, auth);
  const ok = { benefitId: coupon.id };
  const cases = [
    [{}, 'invalid_benefitId'],
    [{ benefitId: '' }, 'invalid_benefitId'],
    [{ benefitId: 'nope' }, 'invalid_benefitId'],
    [{ benefitId: gone.id }, 'invalid_benefitId'],
    [{ benefitId: choice.id }, 'invalid_benefitId'],
    [{ ...ok, kind: 'grant' }, 'invalid_kind'],
    [{ ...ok, occurredOn: localDay(1) }, 'invalid_occurredOn'],
    [{ ...ok, occurredOn: '2026-02-30' }, 'invalid_occurredOn'],
    [{ ...ok, count: 0 }, 'invalid_count'],
    [{ ...ok, count: 1000 }, 'invalid_count'],
    [{ ...ok, count: 1.5 }, 'invalid_count'],
    [{ ...ok, valueCents: -1 }, 'invalid_valueCents'],
    [{ ...ok, memberId: 'nobody' }, 'invalid_memberId'],
    [{ ...ok, note: 'x'.repeat(201) }, 'invalid_note'],
  ];
  for (const [body, code] of cases) {
    const r = await event(body);
    assert.equal(r.status, 400, `${JSON.stringify(body)} → ${r.status} ${r.text}`);
    assert.equal(r.json.error.code, code, JSON.stringify(body));
  }
  const choiceError = await event({ benefitId: choice.id });
  assert.match(choiceError.json.error.message, /选项|选中/, '说清楚要点它下面的选项');
  assert.deepEqual((await a.get('/benefit-events', auth)).json.items, [], '校验失败一条都不落库');
});

test('打卡带 clientId：回应丢了再点，只记一条（重发回第一次那条）', async (t) => {
  const { a, auth, coupon, event } = await withPerks(t);
  const first = await event({ benefitId: coupon.id, clientId: 'tap-1' });
  assert.equal(first.status, 201, first.text);
  const again = await event({ benefitId: coupon.id, clientId: 'tap-1' });
  assert.equal(again.status, 200, again.text);
  assert.equal(again.json.replayed, true);
  assert.equal(again.json.event.id, first.json.event.id);
  assert.equal((await event({ benefitId: coupon.id, clientId: 'tap-2' })).status, 201, '换一个 clientId 就是另一次');
  assert.equal((await a.get('/benefit-events', auth)).json.items.length, 2);
});

test('改打卡：份数、价值、日期；改到将来 400，没传的字段不动', async (t) => {
  const { a, auth, coupon, event } = await withPerks(t);
  const e = (await event({ benefitId: coupon.id, occurredOn: localDay(-1), note: '第一张' })).json.event;
  const patched = await a.patch(`/benefit-events/${e.id}`, { count: 3, valueCents: 1200, occurredOn: localDay(-2) }, auth);
  assert.equal(patched.status, 200, patched.text);
  assert.equal(patched.json.event.count, 3);
  assert.equal(patched.json.event.valueCents, 1200);
  assert.equal(patched.json.event.occurredOn, localDay(-2));
  assert.equal(patched.json.event.note, '第一张');
  const future = await a.patch(`/benefit-events/${e.id}`, { occurredOn: localDay(1) }, auth);
  assert.equal(future.json.error.code, 'invalid_occurredOn');
  const cleared = await a.patch(`/benefit-events/${e.id}`, { occurredOn: null }, auth);
  assert.equal(cleared.json.error.code, 'invalid_occurredOn', '日期不能清空');
});

test('删打卡 = 撤销：软删，/changes 带墓碑；删过的再删 404', async (t) => {
  const { a, auth, coupon, event } = await withPerks(t);
  const e = (await event({ benefitId: coupon.id })).json.event;
  const before = (await a.get('/changes?since=0', auth)).json.next;
  const r = await a.del(`/benefit-events/${e.id}`, auth);
  assert.equal(r.status, 200, r.text);
  assert.ok(r.json.event.deletedAt);
  const tomb = (await a.get(`/changes?since=${before}`, auth)).json.benefit_events;
  assert.deepEqual(tomb.map((x) => [x.id, !!x.deletedAt]), [[e.id, true]]);
  assert.deepEqual((await a.get('/benefit-events', auth)).json.items, []);
  assert.equal((await a.del(`/benefit-events/${e.id}`, auth)).status, 404);
});
