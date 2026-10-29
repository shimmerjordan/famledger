'use strict';

// 债务关联已有流水（modules/debts.js 文件头第 8 条）：借出 / 收回 / 借入 / 还款的钱已经记成支出 / 收入时，
// 选那笔流水而不是再记一笔 —— 借款类把它改成「真账户 ↔ 内部账户」的转账，账户只扣一次、月支出 / 收入里
// 不再有它；人情不改那笔，只当钱那一边记过。所有数字手算。

const test = require('node:test');
const assert = require('node:assert/strict');

const { household } = require('./fixtures');

const MONTH = '2026-09';

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
  const bank = ok(await a.post('/accounts', { name: '招行卡', kind: 'bank', initialBalanceCents: 1000000 }, auth), 'POST 招行卡').account;
  const food = h.categories.find((c) => c.name === '餐饮' && c.kind === 'expense');
  const salary = h.categories.find((c) => c.name === '工资' && c.kind === 'income');
  assert.ok(food && salary, '种子类别里要有餐饮/expense、工资/income');
  return {
    ...h, bank, food, salary,
    /** 记一笔，默认挂招行卡和种子板块（body 里能覆盖成 null）。 */
    mk: async (body) => ok(
      await a.post('/transactions', { accountId: bank.id, fundId: h.fund.id, ...body }, auth), `POST ${body.merchant || body.type}`,
    ).transaction,
    get: async (id) => ok(await a.get(`/transactions/${id}`, auth), 'GET /transactions/:id').transaction,
    debt: (body) => a.post('/debts', body, auth),
    settle: (id, body) => a.post(`/debts/${id}/settle`, body, auth),
    overview: async (month = MONTH) => ok(await a.get(`/stats/overview?month=${month}`, auth), 'GET /stats/overview'),
    txs: async () => ok(await a.get('/transactions?limit=200', auth), 'GET /transactions').items,
    accounts: async () => ok(await a.get('/accounts?archived=1', auth), 'GET /accounts').items,
  };
}

const balanceOf = (o, id) => o.accounts.find((x) => x.accountId === id)?.balanceCents;

test('借出起始关联一笔支出：那笔变成转账、月支出减少、银行只扣一次、净资产回到钱没动之前；对比「记了支出又建债务不记流水」', async (t) => {
  const h = await setup(t);
  const { a, auth, bank, fund, food } = h;
  const start = await h.overview();

  const t1 = await h.mk({
    type: 'expense', amountCents: 5000, occurredAt: '2026-09-03T10:00:00+08:00', categoryId: food.id,
    merchant: '微信转账', note: '借给张三的', tags: ['借款'],
  });
  const before = await h.overview();
  assert.equal(balanceOf(before, bank.id), 995000, '记成支出：银行扣了 50.00');
  assert.equal(before.month.expenseCents, 5000, '月支出里多了 50.00（这是错的，借出不是花钱）');
  assert.equal(before.netWorthCents, start.netWorthCents - 5000);

  const d = ok(await h.debt({
    direction: 'lend', counterparty: '张三', amountCents: 5000, startedOn: '2026-09-03', dueOn: '2026-12-31',
    recordTransaction: { transactionId: t1.id },
  }), 'POST 借出（关联）').debt;
  assert.deepEqual(d.memoLog, [], '经流水走的不留备忘');

  const linked = await h.get(t1.id);
  assert.equal(linked.type, 'transfer');
  assert.equal(linked.accountId, bank.id);
  assert.equal(linked.toAccountId, d.accountId);
  assert.equal(linked.categoryId, null, '借出不是花钱');
  assert.equal(linked.fundId, null, '板块余额回去');
  assert.equal(linked.toFundId, null);
  assert.equal(linked.amountCents, 5000);
  assert.equal(linked.occurredAt, '2026-09-03T10:00:00+08:00', '日期不动');
  assert.equal(linked.merchant, '微信转账', '商户不动');
  assert.equal(linked.note, '借给张三的', '备注不动');
  assert.deepEqual(linked.tags, ['借款']);
  assert.equal(linked.status, 'confirmed');
  assert.equal(linked.offBalance, false);
  assert.equal((await h.txs()).length, 1, '没有新记流水');

  let o = await h.overview();
  assert.equal(balanceOf(o, bank.id), 995000, '银行只扣一次');
  assert.equal(balanceOf(o, d.accountId), 5000, '内部账户记上还剩多少');
  assert.equal(o.debts.receivableCents, 5000);
  assert.equal(o.month.expenseCents, 0, '月支出里没有它了');
  assert.equal(o.netWorthCents, start.netWorthCents, '钱换了个地方：净资产回到记那笔支出之前');
  assert.equal(o.funds.find((f) => f.fundId === fund.id).balanceCents, 0, '板块余额回去了');

  // 对比：先记支出再建债务「不记流水」—— 余额一样（都只扣一次），但月支出里那笔还在。
  await h.mk({ type: 'expense', amountCents: 7000, occurredAt: '2026-09-05T10:00:00+08:00', categoryId: food.id, merchant: '转给李四' });
  const d2 = ok(await h.debt({ direction: 'lend', counterparty: '李四', amountCents: 7000, startedOn: '2026-09-05' }), 'POST 借出（不记流水）').debt;
  o = await h.overview();
  assert.equal(balanceOf(o, bank.id), 988000, '银行照样只扣一次');
  assert.equal(balanceOf(o, d2.accountId), 7000);
  assert.equal(o.netWorthCents, start.netWorthCents, '净资产也一样');
  assert.equal(o.month.expenseCents, 7000, '但月支出把借出的当成花掉了 —— 这就是要关联的原因');

  fail(await a.patch(`/debts/${d.id}`, { direction: 'borrow' }, auth), 409, 'debt_has_flows', '关联后内部账户有流水，方向锁住');
  fail(await a.del(`/debts/${d.id}`, auth), 409, 'debt_in_use', '有往来流水不能删');
});

test('收回关联一笔收入（settle 顶层 transactionId）：变成内部账户 → 银行的转账、月收入减少；幂等回放；收多了 400 且那笔不动', async (t) => {
  const h = await setup(t);
  const { bank, salary } = h;
  const start = await h.overview();
  const d = ok(await h.debt({
    direction: 'lend', counterparty: '张三', amountCents: 5000, startedOn: '2026-09-01', recordTransaction: { accountId: bank.id },
  }), 'POST 借出').debt;

  const t2 = await h.mk({ type: 'income', amountCents: 2000, occurredAt: '2026-09-10T10:00:00+08:00', categoryId: salary.id, merchant: '张三转账' });
  let o = await h.overview();
  assert.equal(balanceOf(o, bank.id), 997000, '记成收入：银行进了 20.00');
  assert.equal(o.month.incomeCents, 2000);

  const s = ok(await h.settle(d.id, { amountCents: 2000, occurredOn: '2026-09-10', transactionId: t2.id, clientId: 'link-1' }), '收回（关联）');
  assert.equal(s.transactions.length, 1, '响应带转换后的那笔');
  assert.equal(s.transactions[0].id, t2.id);
  assert.equal(s.transactions[0].type, 'transfer');
  assert.equal(s.transactions[0].accountId, d.accountId, '收回：内部账户 → 银行');
  assert.equal(s.transactions[0].toAccountId, bank.id);
  assert.equal(s.transactions[0].categoryId, null);
  assert.equal(s.transactions[0].fundId, null);
  assert.equal(s.transactions[0].merchant, '张三转账');
  assert.deepEqual(s.debt.memoLog, []);
  const again = ok(await h.settle(d.id, { amountCents: 2000, occurredOn: '2026-09-10', transactionId: t2.id, clientId: 'link-1' }), '重发');
  assert.equal(again.replayed, true);
  assert.equal(again.transactions[0].id, t2.id);

  o = await h.overview();
  assert.equal(balanceOf(o, bank.id), 997000, '银行只进一次');
  assert.equal(balanceOf(o, d.accountId), 3000, '重发只收回一次');
  assert.equal(o.month.incomeCents, 0, '月收入里没有它了');
  assert.equal(o.netWorthCents, start.netWorthCents, '借出、收回都不改净资产');
  assert.equal((await h.txs()).length, 2, '借出那笔 + 转换的那笔，没有新记');

  // 收多了：400，那笔收入原封不动。
  const t4 = await h.mk({ type: 'income', amountCents: 4000, occurredAt: '2026-09-12T10:00:00+08:00', merchant: '多收的' });
  fail(await h.settle(d.id, { amountCents: 4000, transactionId: t4.id }), 400, 'over_settle', '收多了');
  const untouched = await h.get(t4.id);
  assert.equal(untouched.type, 'income');
  assert.equal(untouched.accountId, bank.id);
  assert.equal(balanceOf(await h.overview(), d.accountId), 3000);
});

test('借入：起始关联一笔收入、还款关联一笔支出、再借入关联收入；负余额进负债', async (t) => {
  const h = await setup(t);
  const { bank, food, salary } = h;
  const start = await h.overview();

  const t1 = await h.mk({ type: 'income', amountCents: 3000, occurredAt: '2026-09-02T10:00:00+08:00', categoryId: salary.id, merchant: '李四转来' });
  const d = ok(await h.debt({
    direction: 'borrow', kind: 'credit', counterparty: '李四', amountCents: 3000, startedOn: '2026-09-02',
    recordTransaction: { transactionId: t1.id },
  }), 'POST 借入（关联）').debt;
  assert.deepEqual(d.memoLog, []);
  let tx = await h.get(t1.id);
  assert.equal(tx.type, 'transfer');
  assert.equal(tx.accountId, d.accountId, '借入：内部账户 → 银行');
  assert.equal(tx.toAccountId, bank.id);
  assert.equal(tx.categoryId, null);
  let o = await h.overview();
  assert.equal(balanceOf(o, bank.id), 1003000, '借来的钱只进一次');
  assert.equal(balanceOf(o, d.accountId), -3000);
  assert.equal(o.debts.payableCents, 3000);
  assert.equal(o.liabilitiesCents, start.liabilitiesCents + 3000, '欠的进负债');
  assert.equal(o.month.incomeCents, 0, '借来的不是收入');
  assert.equal(o.netWorthCents, start.netWorthCents, '借钱不改净资产');

  const t2 = await h.mk({ type: 'expense', amountCents: 1000, occurredAt: '2026-09-15T10:00:00+08:00', categoryId: food.id, merchant: '还李四' });
  const s = ok(await h.settle(d.id, { amountCents: 1000, occurredOn: '2026-09-15', transactionId: t2.id }), '还款（关联）');
  assert.equal(s.transactions[0].id, t2.id);
  tx = await h.get(t2.id);
  assert.equal(tx.type, 'transfer');
  assert.equal(tx.accountId, bank.id, '还款：银行 → 内部账户');
  assert.equal(tx.toAccountId, d.accountId);
  o = await h.overview();
  assert.equal(balanceOf(o, bank.id), 1002000, '只扣一次');
  assert.equal(balanceOf(o, d.accountId), -2000);
  assert.equal(o.month.expenseCents, 0, '还钱不是支出');
  assert.equal(o.netWorthCents, start.netWorthCents);

  const t3 = await h.mk({ type: 'income', amountCents: 500, occurredAt: '2026-09-20T10:00:00+08:00', merchant: '又借了点' });
  const added = ok(await h.settle(d.id, { action: 'add', amountCents: 500, occurredOn: '2026-09-20', transactionId: t3.id }), '再借入（关联）');
  assert.equal(added.debt.amountCents, 3500, '总额累加');
  assert.deepEqual(added.debt.memoLog, []);
  tx = await h.get(t3.id);
  assert.equal(tx.type, 'transfer');
  assert.equal(tx.accountId, d.accountId);
  assert.equal(tx.toAccountId, bank.id);
  o = await h.overview();
  assert.equal(balanceOf(o, d.accountId), -2500);
  assert.equal(balanceOf(o, bank.id), 1002500);
  assert.equal((await h.txs()).length, 3, '三笔都是原来那三笔');
});

test('人情关联：那笔支出 / 收入不改、不再新记；期初照改、备忘 recorded:true；方向不配 400', async (t) => {
  const h = await setup(t);
  const { bank, food, salary } = h;
  const t1 = await h.mk({ type: 'expense', amountCents: 80000, occurredAt: '2026-05-01T12:00:00+08:00', categoryId: food.id, merchant: '王五婚礼随礼' });
  const d = ok(await h.debt({
    direction: 'lend', kind: 'favor', counterparty: '王五', amountCents: 80000, startedOn: '2026-05-01',
    recordTransaction: { transactionId: t1.id },
  }), 'POST 随礼（关联）').debt;
  assert.equal(d.counted, false, '人情默认不计入');
  assert.deepEqual(
    d.memoLog, [{ on: '2026-05-01', amountCents: 80000, note: '起始', recorded: true, transactionId: t1.id }],
    '备忘标成「钱记过了」，并记下是哪笔',
  );
  const gift = await h.get(t1.id);
  assert.equal(gift.type, 'expense', '随礼本来就是花出去的钱，不动');
  assert.equal(gift.categoryId, food.id);
  assert.equal(gift.accountId, bank.id);
  assert.equal((await h.accounts()).find((x) => x.id === d.accountId).initialBalanceCents, 80000, '期初改了');
  let o = await h.overview('2026-05');
  assert.equal(balanceOf(o, d.accountId), 80000);
  assert.equal(balanceOf(o, bank.id), 920000);
  assert.equal(o.month.expenseCents, 80000, '随礼照样是月支出');
  assert.equal((await h.txs()).length, 1, '没有新记流水');

  const t2 = await h.mk({ type: 'income', amountCents: 80000, occurredAt: '2026-06-01T12:00:00+08:00', categoryId: salary.id, merchant: '王五回礼' });
  const s = ok(await h.settle(d.id, { amountCents: 80000, occurredOn: '2026-06-01', transactionId: t2.id }), '回礼（关联）');
  assert.deepEqual(s.transactions, [], '人情不改流水，也不新记');
  assert.deepEqual(s.debt.memoLog.at(-1), {
    on: '2026-06-01', amountCents: -80000, note: '收回人情 王五', recorded: true, action: 'settle', transactionId: t2.id,
  });
  assert.equal((await h.get(t2.id)).type, 'income', '回礼那笔不动');
  o = await h.overview('2026-06');
  assert.equal(balanceOf(o, d.accountId), 0);
  assert.equal(o.month.incomeCents, 80000);
  assert.equal((await h.txs()).length, 2);

  // 人情也看方向：再随要支出、收回要收入。关联过的那笔还是支出（没被改），拿它当收回就 400。
  const t3 = await h.mk({ type: 'expense', amountCents: 100, occurredAt: '2026-06-02T12:00:00+08:00', merchant: '再随' });
  ok(await h.settle(d.id, { action: 'add', amountCents: 100, occurredOn: '2026-06-02', transactionId: t3.id }), '再随 1.00（关联支出）');
  fail(await h.settle(d.id, { amountCents: 100, occurredOn: '2026-06-02', transactionId: t3.id }), 400, 'invalid_transactionId', '收回人情给了支出');
});

test('校验：amount_mismatch；已是转账 / 已删 / 作废 / 没账户 / 方向不配 / 挂在别的债务上 / 不存在 → invalid_transactionId；币种不同 currency_mismatch；二选一', async (t) => {
  const h = await setup(t);
  const { a, auth, bank, fund, food } = h;
  const lend = (transactionId) => h.debt({
    direction: 'lend', counterparty: '张三', amountCents: 5000, startedOn: '2026-09-01', recordTransaction: { transactionId },
  });

  const t1 = await h.mk({ type: 'expense', amountCents: 5000, occurredAt: '2026-09-01T12:00:00+08:00', categoryId: food.id, merchant: '对的' });
  const e = fail(await h.debt({
    direction: 'lend', counterparty: '张三', amountCents: 5001, startedOn: '2026-09-01', recordTransaction: { transactionId: t1.id },
  }), 400, 'amount_mismatch', '金额不等');
  assert.match(e.message, /¥50\.00/, '消息里说那笔是多少');
  assert.match(e.message, /¥50\.01/, '消息里说这里填的是多少');

  const other = ok(await a.post('/accounts', { name: '支付宝', kind: 'alipay' }, auth), 'POST 支付宝').account;
  const transfer = await h.mk({ type: 'transfer', amountCents: 5000, occurredAt: '2026-09-01T12:00:00+08:00', toAccountId: other.id, fundId: null, merchant: '已是转账' });
  fail(await lend(transfer.id), 400, 'invalid_transactionId', '已是转账');

  const deleted = await h.mk({ type: 'expense', amountCents: 5000, occurredAt: '2026-09-01T13:00:00+08:00', merchant: '要删的' });
  ok(await a.del(`/transactions/${deleted.id}`, auth), 'DELETE');
  fail(await lend(deleted.id), 400, 'invalid_transactionId', '已删');

  const voided = await h.mk({ type: 'expense', amountCents: 5000, occurredAt: '2026-09-01T14:00:00+08:00', merchant: '要作废的' });
  ok(await a.post(`/transactions/${voided.id}/void`, {}, auth), 'VOID');
  fail(await lend(voided.id), 400, 'invalid_transactionId', '作废');

  const noAccount = await h.mk({ type: 'expense', amountCents: 5000, occurredAt: '2026-09-01T15:00:00+08:00', accountId: null, merchant: '没账户' });
  fail(await lend(noAccount.id), 400, 'invalid_transactionId', '没账户');

  const income = await h.mk({ type: 'income', amountCents: 5000, occurredAt: '2026-09-01T16:00:00+08:00', merchant: '收入' });
  fail(await lend(income.id), 400, 'invalid_transactionId', '借出要支出，给了收入');
  fail(await h.debt({
    direction: 'borrow', counterparty: '李四', amountCents: 5000, startedOn: '2026-09-01', recordTransaction: { transactionId: t1.id },
  }), 400, 'invalid_transactionId', '借入要收入，给了支出');

  fail(await lend('nope'), 400, 'invalid_transactionId', '不存在');
  fail(await lend(''), 400, 'invalid_transactionId', '空串');

  const usd = ok(await a.post('/accounts', { name: '美元户', kind: 'bank', currency: 'USD' }, auth), 'POST 美元户').account;
  const usdTx = await h.mk({ type: 'expense', amountCents: 5000, occurredAt: '2026-09-01T17:00:00+08:00', accountId: usd.id, merchant: '美元支出' });
  assert.equal(usdTx.currency, 'USD');
  fail(await lend(usdTx.id), 400, 'currency_mismatch', '币种不同');

  fail(await h.debt({
    direction: 'lend', counterparty: '张三', amountCents: 5000, recordTransaction: { transactionId: t1.id, accountId: bank.id },
  }), 400, 'invalid_recordTransaction', '两个都给');
  assert.deepEqual(ok(await a.get('/debts', auth), 'GET /debts').items, [], '上面全失败，一笔债务都没建出来');
  assert.equal((await h.get(t1.id)).type, 'expense', '那笔也没被改');

  // 挂在别的债务的内部账户上的流水不能关联；已经转成转账的也不能再关联。
  const d = ok(await lend(t1.id), 'POST 借出（关联）').debt;
  const onDebt = await h.mk({ type: 'expense', amountCents: 5000, occurredAt: '2026-09-02T12:00:00+08:00', accountId: d.accountId, fundId: fund.id, merchant: '直接记在内部账户上' });
  fail(await h.debt({
    direction: 'lend', counterparty: '赵六', amountCents: 5000, startedOn: '2026-09-02', recordTransaction: { transactionId: onDebt.id },
  }), 400, 'invalid_transactionId', '挂在别的债务上');
  ok(await a.del(`/transactions/${onDebt.id}`, auth), 'DELETE 内部账户上的那笔');
  fail(await lend(t1.id), 400, 'invalid_transactionId', '已经转成转账的不能再关联');

  // settle：accountId 和 transactionId 二选一；金额不等；已是转账。失败的 settle 什么都不动。
  const back = await h.mk({ type: 'income', amountCents: 2000, occurredAt: '2026-09-10T12:00:00+08:00', merchant: '还回来' });
  fail(await h.settle(d.id, { amountCents: 2000, accountId: bank.id, transactionId: back.id }), 400, 'invalid_transactionId', 'settle 两个都给');
  fail(await h.settle(d.id, { amountCents: 1999, transactionId: back.id }), 400, 'amount_mismatch', 'settle 金额不等');
  fail(await h.settle(d.id, { amountCents: 2000, transactionId: t1.id }), 400, 'invalid_transactionId', 'settle 给了已是转账的');
  assert.equal((await h.get(back.id)).type, 'income', '失败的 settle 不动那笔');
  const o = await h.overview();
  assert.equal(balanceOf(o, d.accountId), 5000, '失败的 settle 不动余额');
  assert.deepEqual(ok(await a.get('/debts', auth), 'GET /debts').items.find((x) => x.id === d.id).memoLog, [], '也不留备忘');
});

test('新建时 settledCents 与 transactionId 并用：起始那笔转换，已收回的部分改期初、留备忘', async (t) => {
  const h = await setup(t);
  const { bank, food } = h;
  const t1 = await h.mk({ type: 'expense', amountCents: 10000, occurredAt: '2026-09-01T12:00:00+08:00', categoryId: food.id, merchant: '借给张三' });
  const d = ok(await h.debt({
    direction: 'lend', counterparty: '张三', amountCents: 10000, startedOn: '2026-09-01', settledCents: 4000,
    recordTransaction: { transactionId: t1.id },
  }), 'POST 借出（关联 + 已收回）').debt;
  assert.deepEqual(d.memoLog, [{ on: '2026-09-01', amountCents: -4000, note: '之前已收回', recorded: false, action: 'settle' }]);
  assert.equal((await h.get(t1.id)).type, 'transfer', '起始那笔转换了');
  const o = await h.overview();
  assert.equal(balanceOf(o, bank.id), 990000, '银行只扣起始那一次');
  assert.equal(balanceOf(o, d.accountId), 6000, '100.00 转进来 − 期初 −40.00');
  assert.equal((await h.accounts()).find((x) => x.id === d.accountId).initialBalanceCents, -4000);
  assert.equal(o.month.expenseCents, 0);
  assert.equal((await h.txs()).length, 1, '只有转换的那笔，没新记');
});

test('待确认的流水不能当往来；人情关联过的那笔不能再关联；POST /debts 的回应带转换后的那笔（幂等回放也带）', async (t) => {
  const h = await setup(t);
  const { food } = h;
  const pending = await h.mk({
    type: 'expense', amountCents: 5000, occurredAt: '2026-09-01T12:00:00+08:00', categoryId: food.id, merchant: '待确认', status: 'pending',
  });
  const e = fail(await h.debt({
    direction: 'lend', counterparty: '张三', amountCents: 5000, startedOn: '2026-09-01', recordTransaction: { transactionId: pending.id },
  }), 400, 'invalid_transactionId', '待确认的');
  assert.match(e.message, /还没确认/);
  assert.equal((await h.get(pending.id)).status, 'pending', '那笔不动');

  const t1 = await h.mk({ type: 'expense', amountCents: 80000, occurredAt: '2026-05-01T12:00:00+08:00', categoryId: food.id, merchant: '随礼' });
  const d = ok(await h.debt({
    direction: 'lend', kind: 'favor', counterparty: '王五', amountCents: 80000, startedOn: '2026-05-01',
    recordTransaction: { transactionId: t1.id },
  }), 'POST 人情').debt;
  assert.equal(d.memoLog[0].transactionId, t1.id);
  const e2 = fail(
    await h.settle(d.id, { action: 'add', amountCents: 80000, occurredOn: '2026-05-02', transactionId: t1.id }),
    400, 'invalid_transactionId', '同一笔再关联到同一笔人情',
  );
  assert.match(e2.message, /王五/);
  fail(await h.debt({
    direction: 'lend', kind: 'favor', counterparty: '赵六', amountCents: 80000, startedOn: '2026-05-01',
    recordTransaction: { transactionId: t1.id },
  }), 400, 'invalid_transactionId', '拿它再建一笔人情也不行');
  assert.equal((await h.accounts()).find((x) => x.id === d.accountId).initialBalanceCents, 80000, '期初没被加第二次');
  assert.equal((await h.accounts()).filter((x) => x.kind === 'debt').length, 1, '没建出第二笔债务');

  // 借款类：回应带转换后的那笔；同 clientId 回放也带。
  const t2 = await h.mk({ type: 'expense', amountCents: 5000, occurredAt: '2026-09-03T12:00:00+08:00', categoryId: food.id, merchant: '借给张三' });
  const body = {
    direction: 'lend', counterparty: '张三', amountCents: 5000, startedOn: '2026-09-03',
    recordTransaction: { transactionId: t2.id }, clientId: 'dl-1',
  };
  const r = await h.debt(body);
  assert.equal(r.status, 201, r.text);
  assert.equal(r.json.transactions.length, 1);
  assert.equal(r.json.transactions[0].id, t2.id);
  assert.equal(r.json.transactions[0].type, 'transfer');
  assert.equal(r.json.transactions[0].toAccountId, r.json.debt.accountId);
  const again = await h.debt(body);
  assert.equal(again.status, 200, again.text);
  assert.equal(again.json.replayed, true);
  assert.deepEqual(again.json.transactions.map((x) => x.id), [t2.id], '回放也带那笔');
  // 人情的回应没有流水可带。
  const r2 = ok(await h.debt({
    direction: 'lend', kind: 'favor', counterparty: '钱七', amountCents: 100, startedOn: '2026-09-03',
  }), 'POST 人情（不记流水）');
  assert.deepEqual(r2.transactions, []);
});
