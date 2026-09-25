'use strict';

// 实物估值口径（spec §3）。向量在 fixtures/valuation_golden.json，App 的 asset_valuation_test.dart
// 读同一份：两端各算各的，差不过 1 分。改公式要两端同改，并重算向量。

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const valuation = require('../src/lib/valuation');

const golden = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', 'valuation_golden.json'), 'utf8'));

const near = (actual, expected, what) =>
  assert.ok(Math.abs(actual - expected) <= 1, `${what}：算出 ${actual}，向量是 ${expected}`);

test('类别默认表与向量文件逐项相同，顺序也一样（顺序就是类别名单的顺序）', () => {
  assert.deepEqual(valuation.CATEGORY_DEFAULTS, golden.categories);
  assert.deepEqual(Object.keys(valuation.CATEGORY_DEFAULTS), Object.keys(golden.categories));
});

for (const c of golden.cases) {
  test(`向量：${c.name}`, () => {
    near(valuation.valueAt(c.asset, c.asOf), c.valueAtCents, 'valueAt');
    near(valuation.currentValue(c.asset, c.asOf), c.currentCents, 'currentValue');
    assert.equal(valuation.countsInNetWorth(c.asset), c.countsInNetWorth, 'countsInNetWorth');
    if (c.endedValueCents !== undefined) {
      near(valuation.valueAt(c.asset, c.asset.endedOn), c.endedValueCents, '结束那天的估值');
    }
  });
}

test('summarizePhysical：只算未归档、在用或闲置的；计入额看单件三态和类别默认', () => {
  const today = '2026-09-23';
  // 都是今天买的：估值 = 原价，数字好手算。
  const item = (o) => ({ category: 'digital', priceCents: 100000, purchasedOn: today, status: 'in_use', ...o });
  const s = valuation.summarizePhysical([
    item({}),
    item({ status: 'idle', priceCents: 50000 }),
    item({ category: 'appliance', priceCents: 30000 }),
    item({ netWorth: 'exclude', priceCents: 20000 }),
    item({ category: 'furniture', netWorth: 'include', priceCents: 7000 }),
    item({ archived: true, priceCents: 999999 }),
    item({ archived: 1, priceCents: 999999 }),
    item({ status: 'sold', endedOn: today, priceCents: 999999 }),
    item({ status: 'retired', endedOn: today, priceCents: 999999 }),
  ], today);
  assert.deepEqual(s, { valueCents: 207000, includedCents: 157000, count: 5 });
});

test('localToday 按服务器本地日历给 YYYY-MM-DD', () => {
  assert.equal(valuation.localToday(new Date(2026, 0, 5, 23, 59)), '2026-01-05');
});

test('METHODS / NET_WORTH 是 /assets 校验用的取值表', () => {
  assert.deepEqual(valuation.METHODS, ['auto', 'straight', 'declining', 'locked']);
  assert.deepEqual(valuation.NET_WORTH, ['auto', 'include', 'exclude']);
});
