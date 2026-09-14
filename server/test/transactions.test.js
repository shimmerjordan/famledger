'use strict';

// 流水：幂等写入、过滤、游标分页、状态流转、批量、服务端查重。

const test = require('node:test');
const assert = require('node:assert/strict');

const { household } = require('./fixtures');

const AT = (iso) => new Date(iso).toISOString();

test('POST 支出带 clientId → 201；同 clientId 再 POST → 200 且同 id', async (t) => {
  const { a, auth, fund, account, category, member } = await household(t);

  const body = {
    clientId: 'c7e4a1f0-0000-4000-8000-000000000001',
    type: 'expense',
    amountCents: 2350,
    occurredAt: '2026-09-10T12:00:00.000Z',
    fundId: fund.id,
    accountId: account.id,
    categoryId: category.id,
    merchant: '楼下拉面',
    note: '午饭',
    tags: ['午餐', '工作日'],
  };
  const first = await a.post('/transactions', body, auth);
  assert.equal(first.status, 201, first.text);
  const tx = first.json.transaction;
  assert.ok(tx.id);
  assert.equal(tx.amountCents, 2350);
  assert.equal(tx.occurredAt, '2026-09-10T12:00:00.000Z');
  assert.equal(tx.currency, 'CNY');
  assert.equal(tx.status, 'confirmed');
  assert.equal(tx.source, 'manual');
  assert.deepEqual(tx.tags, ['午餐', '工作日']);
  assert.equal(tx.memberId, member.id, 'memberId 默认是当前成员');
  assert.equal(tx.createdBy, member.id);
  assert.equal(first.json.duplicate, undefined, '手工记账不标查重');

  const again = await a.post('/transactions', { ...body, merchant: '改个名也没用' }, auth);
  assert.equal(again.status, 200, again.text);
  assert.equal(again.json.transaction.id, tx.id);
  assert.equal(again.json.transaction.merchant, '楼下拉面', '幂等：返回已存在的那条，不覆盖');

  assert.equal((await a.get('/transactions', auth)).json.items.length, 1);
});

test('POST 校验：金额/类型/时间非法 → 400；支出不传 fundId 落到默认基金', async (t) => {
  const { a, auth, fund } = await household(t);

  const cases = [
    [{ type: 'gift', amountCents: 1 }, 'invalid_type'],
    [{ type: 'expense', amountCents: -1 }, 'invalid_amountCents'],
    [{ type: 'expense', amountCents: 1.5 }, 'invalid_amountCents'],
    [{ type: 'expense' }, 'invalid_amountCents'],
    [{ type: 'expense', amountCents: 1, occurredAt: '昨天' }, 'invalid_occurredAt'],
    [{ type: 'expense', amountCents: 1, status: 'duplicate' }, 'invalid_status'],
    [{ type: 'expense', amountCents: 1, source: 'sms' }, 'invalid_source'],
    [{ type: 'expense', amountCents: 1, tags: [1, 2] }, 'invalid_tags'],
  ];
  for (const [body, code] of cases) {
    const r = await a.post('/transactions', body, auth);
    assert.equal(r.status, 400, `${JSON.stringify(body)} 应当 400，实际 ${r.text}`);
    assert.equal(r.json.error.code, code, JSON.stringify(body));
  }

  const ok = await a.post('/transactions', { type: 'expense', amountCents: 800 }, auth);
  assert.equal(ok.status, 201, ok.text);
  assert.equal(ok.json.transaction.fundId, fund.id, '没传 fundId 时落到默认基金');
  assert.ok(ok.json.transaction.occurredAt, '没传 occurredAt 时用当前时间');
});

test('转账：只填 fund 对合法；两对都空 → 400；同一侧相同 → 400', async (t) => {
  const { a, auth, fund, account } = await household(t);
  const other = (await a.post('/funds', { name: '旅行基金', kind: 'goal' }, auth)).json.fund;
  const otherAcct = (await a.post('/accounts', { name: '支付宝', kind: 'alipay' }, auth)).json.account;

  const fundOnly = await a.post('/transactions', {
    type: 'transfer', amountCents: 100000, fundId: fund.id, toFundId: other.id, note: '拨款',
  }, auth);
  assert.equal(fundOnly.status, 201, fundOnly.text);
  assert.equal(fundOnly.json.transaction.toFundId, other.id);
  assert.equal(fundOnly.json.transaction.accountId, null);

  const acctOnly = await a.post('/transactions', {
    type: 'transfer', amountCents: 5000, accountId: account.id, toAccountId: otherAcct.id,
  }, auth);
  assert.equal(acctOnly.status, 201, acctOnly.text);
  assert.equal(acctOnly.json.transaction.fundId, null, '转账不套用默认基金');

  const neither = await a.post('/transactions', { type: 'transfer', amountCents: 100 }, auth);
  assert.equal(neither.status, 400, neither.text);
  assert.equal(neither.json.error.code, 'invalid_transfer');

  const halfPair = await a.post('/transactions', { type: 'transfer', amountCents: 100, fundId: fund.id }, auth);
  assert.equal(halfPair.status, 400);
  assert.equal(halfPair.json.error.code, 'invalid_transfer');

  const same = await a.post('/transactions', {
    type: 'transfer', amountCents: 100, fundId: fund.id, toFundId: fund.id,
  }, auth);
  assert.equal(same.status, 400);
  assert.equal(same.json.error.code, 'invalid_toFundId');

  // 一对只填一半 = 钱从一边消失、没有落点，即使另一对是完整的也不行。
  const strayAccount = await a.post('/transactions', {
    type: 'transfer', amountCents: 100, fundId: fund.id, toFundId: other.id, accountId: account.id,
  }, auth);
  assert.equal(strayAccount.status, 400, strayAccount.text);
  assert.equal(strayAccount.json.error.code, 'invalid_transfer');

  const strayFund = await a.post('/transactions', {
    type: 'transfer', amountCents: 100, accountId: account.id, toAccountId: otherAcct.id, toFundId: other.id,
  }, auth);
  assert.equal(strayFund.status, 400, strayFund.text);
  assert.equal(strayFund.json.error.code, 'invalid_transfer');

  // PATCH 也按「旧行 + 本次改动」重算：把一对拆成一半同样挡住。
  const id = fundOnly.json.transaction.id;
  const half = await a.patch(`/transactions/${id}`, { accountId: account.id }, auth);
  assert.equal(half.status, 400, half.text);
  assert.equal(half.json.error.code, 'invalid_transfer');

  const dropHalf = await a.patch(`/transactions/${id}`, { toFundId: null }, auth);
  assert.equal(dropHalf.status, 400);
  assert.equal(dropHalf.json.error.code, 'invalid_transfer');

  const both = await a.patch(`/transactions/${id}`, { accountId: account.id, toAccountId: otherAcct.id }, auth);
  assert.equal(both.status, 200, both.text);
  assert.equal(both.json.transaction.toAccountId, otherAcct.id);
});

test('occurredAt 原样存带偏移的本地时间，日期过滤按本地日期', async (t) => {
  const { a, auth, fund } = await household(t);
  const mk = (occurredAt, merchant) =>
    a.post('/transactions', { type: 'expense', amountCents: 100, fundId: fund.id, occurredAt, merchant }, auth);

  // 北京时间 9/5 凌晨 1 点 —— 它的 UTC 日期是 9/4，但用户心里是 5 号的账。
  const night = await mk('2026-09-05T01:00:00+08:00', '夜宵');
  assert.equal(night.status, 201, night.text);
  assert.equal(night.json.transaction.occurredAt, '2026-09-05T01:00:00+08:00', '服务端不做时区换算');

  assert.equal((await mk('2026-09-04T23:30:00+08:00', '前一天')).status, 201);
  assert.equal((await mk('2026-09-05T12:00:00Z', '同一天UTC')).status, 201);

  const names = async (qs) => {
    const r = await a.get(`/transactions${qs}`, auth);
    assert.equal(r.status, 200, r.text);
    return r.json.items.map((x) => x.merchant);
  };
  assert.deepEqual(await names('?from=2026-09-05&to=2026-09-05'), ['同一天UTC', '夜宵'], '按本地日期算，不是 UTC 日期');
  assert.deepEqual(await names('?from=2026-09-04&to=2026-09-04'), ['前一天']);
  assert.deepEqual(await names('?to=2026-09-04'), ['前一天']);

  // 完整 ISO 时刻按字符串原样比
  const q = (v) => encodeURIComponent(v);
  assert.deepEqual(
    await names(`?from=${q('2026-09-05T00:00:00+08:00')}&to=${q('2026-09-05T23:59:59+08:00')}`),
    ['同一天UTC', '夜宵'],
  );

  assert.equal((await a.get('/transactions?from=2026-9-5', auth)).json.error.code, 'invalid_from');
  assert.equal((await a.get('/transactions?to=2026-13-01', auth)).json.error.code, 'invalid_to');
  const noOffset = await a.post('/transactions', {
    type: 'expense', amountCents: 100, fundId: fund.id, occurredAt: '2026-09-05T01:00:00',
  }, auth);
  assert.equal(noOffset.status, 400, '不带时区偏移就说不清是哪一天');
  assert.equal(noOffset.json.error.code, 'invalid_occurredAt');

  // 查重比的是真实瞬间：同一时刻用不同偏移写两遍，照样算重复。
  const one = await a.post('/transactions', {
    type: 'expense', amountCents: 777, fundId: fund.id, occurredAt: '2026-09-05T09:00:00+08:00', source: 'notification',
  }, auth);
  assert.equal(one.status, 201, one.text);
  const two = await a.post('/transactions', {
    type: 'expense', amountCents: 777, fundId: fund.id, occurredAt: '2026-09-05T01:01:00Z', source: 'notification',
  }, auth);
  assert.equal(two.json.duplicate, true, '01:01Z 就是 09:01+08:00，离前一笔只有 60 秒');
  assert.equal(two.json.transaction.duplicateOfId, one.json.transaction.id);
});

test('不传 occurredAt 时落服务器本地时间 + 偏移，而不是 UTC', async (t) => {
  const { a, auth, fund } = await household(t, { TZ: 'Asia/Shanghai' });
  const r = await a.post('/transactions', { type: 'expense', amountCents: 100, fundId: fund.id }, auth);
  assert.equal(r.status, 201, r.text);

  const at = r.json.transaction.occurredAt;
  assert.match(at, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+08:00$/, `实际是 ${at}`);

  // 北京时间凌晨 0~8 点记的那笔，本地日期必须还是「今天」，不能掉回 UTC 的昨天
  const today = new Date(Date.now() + 8 * 3600 * 1000).toISOString().slice(0, 10);
  assert.equal(at.slice(0, 10), today, '默认时间的本地日期要和北京时间的今天一致');

  const hit = await a.get(`/transactions?from=${today}&to=${today}`, auth);
  assert.equal(hit.status, 200, hit.text);
  assert.equal(hit.json.items.length, 1, '按本地日期筛得到它');
});

test('引用必须存在：乱填/已删除的 id → 400；已归档的可以用', async (t) => {
  const { a, auth, fund, account, category } = await household(t);
  const base = { type: 'expense', amountCents: 100, fundId: fund.id };

  for (const [body, code] of [
    [{ ...base, fundId: 'typo' }, 'invalid_fundId'],
    [{ ...base, accountId: 'typo' }, 'invalid_accountId'],
    [{ ...base, categoryId: 'typo' }, 'invalid_categoryId'],
    [{ ...base, memberId: 'nobody' }, 'invalid_memberId'],
    [{ type: 'transfer', amountCents: 100, fundId: fund.id, toFundId: 'typo' }, 'invalid_toFundId'],
    [{ type: 'transfer', amountCents: 100, accountId: account.id, toAccountId: 'typo' }, 'invalid_toAccountId'],
  ]) {
    const r = await a.post('/transactions', body, auth);
    assert.equal(r.status, 400, `${JSON.stringify(body)} → ${r.text}`);
    assert.equal(r.json.error.code, code);
  }

  const batch = await a.post('/transactions/batch', {
    items: [
      { clientId: 'ref-1', ...base, fundId: 'typo' },
      { clientId: 'ref-2', ...base },
    ],
  }, auth);
  assert.equal(batch.status, 200, batch.text);
  assert.equal(batch.json.results[0].status, 'error');
  assert.equal(batch.json.results[0].error, 'invalid_fundId');
  assert.equal(batch.json.results[1].status, 'created');

  // 归档只是「别再显示在选择器里」，历史记账照样能指
  const archived = (await a.post('/funds', { name: '去年的旅行', kind: 'goal', archived: true }, auth)).json.fund;
  assert.equal((await a.post('/transactions', { ...base, fundId: archived.id }, auth)).status, 201);

  // 软删就是真的没了
  const doomed = (await a.post('/funds', { name: '建错了', kind: 'custom' }, auth)).json.fund;
  assert.equal((await a.del(`/funds/${doomed.id}`, auth)).status, 200);
  const gone = await a.post('/transactions', { ...base, fundId: doomed.id }, auth);
  assert.equal(gone.status, 400);
  assert.equal(gone.json.error.code, 'invalid_fundId');

  // PATCH 同样校验
  const tx = (await a.post('/transactions', { ...base, categoryId: category.id }, auth)).json.transaction;
  const badPatch = await a.patch(`/transactions/${tx.id}`, { categoryId: 'nope' }, auth);
  assert.equal(badPatch.status, 400);
  assert.equal(badPatch.json.error.code, 'invalid_categoryId');

  // 但「旧引用后来被删了」不该把这一行锁死：没传的字段不重新校验
  const temp = (await a.post('/funds', { name: '临时', kind: 'custom' }, auth)).json.fund;
  const old = (await a.post('/transactions', { ...base, fundId: temp.id }, auth)).json.transaction;
  assert.equal((await a.post(`/transactions/${old.id}/void`, {}, auth)).status, 200);
  assert.equal((await a.del(`/funds/${temp.id}`, auth)).status, 200);
  const edit = await a.patch(`/transactions/${old.id}`, { note: '基金没了也得能改备注' }, auth);
  assert.equal(edit.status, 200, edit.text);
  assert.equal(edit.json.transaction.fundId, temp.id);
});

test('GET 过滤：fundId / type / q / 日期区间', async (t) => {
  const { a, auth, fund, account, category } = await household(t);
  const other = (await a.post('/funds', { name: '旅行基金', kind: 'goal' }, auth)).json.fund;

  const mk = (body) => a.post('/transactions', body, auth);
  const a1 = (await mk({ type: 'expense', amountCents: 100, fundId: fund.id, occurredAt: AT('2026-09-01T02:00:00Z'), merchant: '盒马', categoryId: category.id })).json.transaction;
  const a2 = (await mk({ type: 'income', amountCents: 900000, fundId: fund.id, occurredAt: AT('2026-09-05T02:00:00Z'), note: '发工资啦' })).json.transaction;
  const b1 = (await mk({ type: 'expense', amountCents: 300, fundId: other.id, occurredAt: AT('2026-09-20T02:00:00Z'), merchant: '携程' })).json.transaction;
  const mv = (await mk({ type: 'transfer', amountCents: 50000, fundId: fund.id, toFundId: other.id, occurredAt: AT('2026-09-25T02:00:00Z') })).json.transaction;

  const ids = async (qs) => {
    const r = await a.get(`/transactions${qs}`, auth);
    assert.equal(r.status, 200, r.text);
    return r.json.items.map((x) => x.id);
  };

  assert.deepEqual(await ids(''), [mv.id, b1.id, a2.id, a1.id], '默认按发生时间倒序');
  assert.deepEqual(await ids(`?fundId=${other.id}`), [mv.id, b1.id], '转入该基金的转账也算这个基金的流水');
  assert.deepEqual(await ids(`?fundId=${fund.id}&type=expense`), [a1.id]);
  assert.deepEqual(await ids(`?accountId=${account.id}`), []);
  assert.deepEqual(await ids(`?categoryId=${category.id}`), [a1.id]);
  assert.deepEqual(await ids('?type=income'), [a2.id]);
  assert.deepEqual(await ids('?q=' + encodeURIComponent('盒马')), [a1.id], 'q 匹配 merchant');
  assert.deepEqual(await ids('?q=' + encodeURIComponent('工资')), [a2.id], 'q 匹配 note');
  assert.deepEqual(await ids('?q=' + encodeURIComponent('%')), [], 'LIKE 通配符要被转义');
  assert.deepEqual(await ids('?from=2026-09-05&to=2026-09-20'), [b1.id, a2.id], '日期端点都算在内');
  assert.deepEqual(await ids('?from=2026-09-21T00:00:00Z'), [mv.id]);

  const badLimit = await a.get('/transactions?limit=0', auth);
  assert.equal(badLimit.status, 400);
  assert.equal(badLimit.json.error.code, 'invalid_limit');
  assert.equal((await a.get('/transactions?limit=500', auth)).status, 400, 'limit 上限 200');
});

test('游标分页：三条数据 limit=2 分两页且不重不漏', async (t) => {
  const { a, auth, fund } = await household(t);
  const made = [];
  for (const d of ['2026-09-01T00:00:00Z', '2026-09-02T00:00:00Z', '2026-09-03T00:00:00Z']) {
    const r = await a.post('/transactions', { type: 'expense', amountCents: 100, fundId: fund.id, occurredAt: AT(d) }, auth);
    made.push(r.json.transaction.id);
  }
  const expect = [...made].reverse();

  const p1 = await a.get('/transactions?limit=2', auth);
  assert.equal(p1.status, 200, p1.text);
  assert.deepEqual(p1.json.items.map((x) => x.id), expect.slice(0, 2));
  assert.ok(p1.json.nextCursor, '还有下一页时必须给 nextCursor');

  const p2 = await a.get(`/transactions?limit=2&cursor=${encodeURIComponent(p1.json.nextCursor)}`, auth);
  assert.deepEqual(p2.json.items.map((x) => x.id), expect.slice(2));
  assert.equal(p2.json.nextCursor, undefined, '最后一页没有 nextCursor');

  const bad = await a.get('/transactions?cursor=@@@', auth);
  assert.equal(bad.status, 400);
  assert.equal(bad.json.error.code, 'invalid_cursor');
});

test('PATCH 改金额；DELETE 后 GET /:id → 404', async (t) => {
  const { a, auth, fund } = await household(t);
  const tx = (await a.post('/transactions', {
    type: 'expense', amountCents: 2350, fundId: fund.id, merchant: '拉面', tags: ['午餐'],
  }, auth)).json.transaction;

  const got = await a.get(`/transactions/${tx.id}`, auth);
  assert.equal(got.status, 200, got.text);
  assert.equal(got.json.transaction.amountCents, 2350);

  const p = await a.patch(`/transactions/${tx.id}`, { amountCents: 9900, note: '加了份叉烧', tags: [] }, auth);
  assert.equal(p.status, 200, p.text);
  assert.equal(p.json.transaction.amountCents, 9900);
  assert.equal(p.json.transaction.note, '加了份叉烧');
  assert.equal(p.json.transaction.merchant, '拉面', 'PATCH 不动没传的字段');
  assert.deepEqual(p.json.transaction.tags, []);
  assert.ok(p.json.transaction.seq > tx.seq);

  const badPatch = await a.patch(`/transactions/${tx.id}`, { amountCents: -5 }, auth);
  assert.equal(badPatch.status, 400);

  const d = await a.del(`/transactions/${tx.id}`, auth);
  assert.equal(d.status, 200, d.text);
  assert.ok(d.json.transaction.deletedAt);

  assert.equal((await a.get(`/transactions/${tx.id}`, auth)).status, 404);
  assert.equal((await a.patch(`/transactions/${tx.id}`, { note: 'x' }, auth)).status, 404);
  assert.equal((await a.get('/transactions', auth)).json.items.length, 0);
});

test('POST /:id/confirm 把 pending 变 confirmed；/void 置 void', async (t) => {
  const { a, auth, fund } = await household(t);
  const tx = (await a.post('/transactions', {
    type: 'expense', amountCents: 1000, fundId: fund.id, status: 'pending', source: 'notification', confidence: 0.4,
  }, auth)).json.transaction;
  assert.equal(tx.status, 'pending');
  assert.equal(tx.confidence, 0.4);

  const c = await a.post(`/transactions/${tx.id}/confirm`, {}, auth);
  assert.equal(c.status, 200, c.text);
  assert.equal(c.json.transaction.status, 'confirmed');
  assert.ok(c.json.transaction.seq > tx.seq);

  const vo = await a.post(`/transactions/${tx.id}/void`, {}, auth);
  assert.equal(vo.status, 200, vo.text);
  assert.equal(vo.json.transaction.status, 'void');

  assert.deepEqual((await a.get('/transactions?status=void', auth)).json.items.map((x) => x.id), [tx.id]);
  assert.deepEqual((await a.get('/transactions?status=confirmed', auth)).json.items, []);
  assert.equal((await a.post('/transactions/nope/confirm', {}, auth)).status, 404);
});

test('batch：created / exists / error 混在一起，HTTP 仍是 200', async (t) => {
  const { a, auth, fund } = await household(t);
  const cid = 'batch-0001';
  const r = await a.post('/transactions/batch', {
    items: [
      { clientId: cid, type: 'expense', amountCents: 1500, fundId: fund.id, merchant: '早餐' },
      { clientId: cid, type: 'expense', amountCents: 1500, fundId: fund.id, merchant: '早餐' },
      { clientId: 'batch-0002', type: 'expense', amountCents: -3, fundId: fund.id },
      { clientId: 'batch-0003', type: 'income', amountCents: 700, fundId: fund.id },
    ],
  }, auth);
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.results.length, 4);

  assert.equal(r.json.results[0].status, 'created');
  assert.equal(r.json.results[0].clientId, cid);
  assert.ok(r.json.results[0].id);
  assert.equal(r.json.results[1].status, 'exists');
  assert.equal(r.json.results[1].id, r.json.results[0].id, '同批次内重复也要幂等');
  assert.equal(r.json.results[2].status, 'error');
  assert.equal(r.json.results[2].error, 'invalid_amountCents');
  assert.equal(r.json.results[2].id, undefined);
  assert.equal(r.json.results[3].status, 'created');

  assert.equal((await a.get('/transactions', auth)).json.items.length, 2, '出错的那条没有落库');

  const empty = await a.post('/transactions/batch', { items: [] }, auth);
  assert.equal(empty.status, 200);
  assert.deepEqual(empty.json.results, []);
  const tooMany = await a.post('/transactions/batch', { items: new Array(201).fill({ type: 'expense', amountCents: 1 }) }, auth);
  assert.equal(tooMany.status, 400);
  assert.equal(tooMany.json.error.code, 'invalid_items');
});

test('查重：notification 两分钟内同金额第二笔 → duplicate；manual 不查重', async (t) => {
  const { a, auth, fund } = await household(t);
  const base = '2026-09-10T12:00:00.000Z';
  const at = (sec) => new Date(Date.parse(base) + sec * 1000).toISOString();

  const first = await a.post('/transactions', {
    type: 'expense', amountCents: 3900, fundId: fund.id, occurredAt: base,
    source: 'notification', merchant: '瑞幸', rawText: '支付宝支付 39.00 元', sourceApp: 'com.eg.android.AlipayGphone',
  }, auth);
  assert.equal(first.status, 201, first.text);
  assert.equal(first.json.duplicate, undefined);
  assert.equal(first.json.transaction.status, 'confirmed');
  assert.equal(first.json.transaction.rawText, '支付宝支付 39.00 元');

  const dup = await a.post('/transactions', {
    type: 'expense', amountCents: 3900, fundId: fund.id, occurredAt: at(120), source: 'share', merchant: '瑞幸咖啡',
  }, auth);
  assert.equal(dup.status, 201, dup.text);
  assert.equal(dup.json.duplicate, true, '响应要带 duplicate:true');
  assert.equal(dup.json.transaction.status, 'duplicate');
  assert.equal(dup.json.transaction.duplicateOfId, first.json.transaction.id);

  const far = await a.post('/transactions', {
    type: 'expense', amountCents: 3900, fundId: fund.id, occurredAt: at(200), source: 'notification',
  }, auth);
  assert.equal(far.json.duplicate, undefined, '超过 ±180s 不算重复');
  assert.equal(far.json.transaction.status, 'confirmed');

  const otherAmount = await a.post('/transactions', {
    type: 'expense', amountCents: 3901, fundId: fund.id, occurredAt: at(10), source: 'notification',
  }, auth);
  assert.equal(otherAmount.json.transaction.status, 'confirmed', '金额不同不算重复');

  const manual = await a.post('/transactions', {
    type: 'expense', amountCents: 3900, fundId: fund.id, occurredAt: at(30), source: 'manual',
  }, auth);
  assert.equal(manual.json.duplicate, undefined, '手工录入永不查重');
  assert.equal(manual.json.transaction.status, 'confirmed');

  // 用户说「这不是重复」：PATCH 回 confirmed
  const fixed = await a.patch(`/transactions/${dup.json.transaction.id}`, { status: 'confirmed' }, auth);
  assert.equal(fixed.status, 200, fixed.text);
  assert.equal(fixed.json.transaction.status, 'confirmed');

  // 原始那笔被删掉之后不能再当「原始记录」，应当落到还活着的最早一笔（manual，at+30s）
  assert.equal((await a.del(`/transactions/${first.json.transaction.id}`, auth)).status, 200);
  const third = await a.post('/transactions', {
    type: 'expense', amountCents: 3900, fundId: fund.id, occurredAt: at(45), source: 'notification',
  }, auth);
  assert.equal(third.json.duplicate, true);
  assert.equal(third.json.transaction.duplicateOfId, manual.json.transaction.id, '指向还活着的最早那笔');
});

test('流水接口都要登录', async (t) => {
  const { a } = await household(t);
  assert.equal((await a.get('/transactions')).status, 401);
  assert.equal((await a.post('/transactions', { type: 'expense', amountCents: 1 })).status, 401);
});
