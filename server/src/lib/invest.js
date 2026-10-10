'use strict';

// 理财品类与估值。**App 端 app/lib/data/models/asset_math.dart 逐条对应**：两边按同一个式子算，
// 首页、理财页和服务端的净资产才对得上。改这里就要改那边，test/lib.test.js 和 asset_math_test.dart
// 用同一组手算常量钉着。
//
// 三种估值方式（mode）：
//   unit     份额 × 价格。基金、股票、黄金。没价格就不知道值多少（null），不进市值。
//   deposit  本金 + 按天单利计息（年化 rate_e6，起息日 opened_on 到 min(今天, 到期日)），
//            减去已经付出来的利息（realized_cents）。定期、结构性存款（按保底）、国债、逆回购。
//   balance  手动更新的当前金额（value_cents，没填就按本金）。活期/货币、银行理财、保险存单、其他。
// 清了仓（quantity_e4 = 0）一律是 0。非 unit 的品类 quantity_e4 恒为 HELD_E4，只当「还持有着」的标记。

const KINDS = ['fund', 'stock', 'demand', 'fixed', 'structured', 'wealth', 'bond', 'repo', 'insurance', 'gold', 'other'];

const MODE = {
  fund: 'unit',
  stock: 'unit',
  gold: 'unit',
  fixed: 'deposit',
  structured: 'deposit',
  bond: 'deposit',
  repo: 'deposit',
  demand: 'balance',
  wealth: 'balance',
  insurance: 'balance',
  other: 'balance',
};

const HELD_E4 = 10000;

/** 年化上限 100%（×1e6）。 */
const MAX_RATE_E6 = 1000000;

const modeOf = (kind) => MODE[kind] || 'balance';

/** 老行没有 kind 时按 market 推：场外基金是基金，其余按股票。 */
const kindOf = (row) => (row && KINDS.includes(row.kind) ? row.kind : row && row.market === 'fund' ? 'fund' : 'stock');

/** 市值（分）= 份额E4 × 价格E4 / 1e6，四舍五入；两个 ×10000 的数一乘就越过 2^53，走 BigInt。 */
function marketCents(quantityE4, priceE4) {
  return Number((BigInt(quantityE4) * BigInt(priceE4) + 500000n) / 1000000n);
}

/** `YYYY-MM-DD` → 自 1970-01-01 起的天数；认不出是 null。 */
function dayNumber(raw) {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(raw || ''));
  if (!m) return null;
  const ms = Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
  return Number.isNaN(ms) ? null : Math.round(ms / 86400000);
}

/**
 * 按天单利：round(本金 × 年化 × 天数 / 365)。天数 = endOn − startOn（起息当天不算，到期当天算），
 * 不足 0 按 0。round 是四舍五入（×2 + 分母 再整除）。
 */
function accruedCents(principalCents, rateE6, startOn, endOn) {
  if (!rateE6 || !(principalCents > 0)) return 0;
  const start = dayNumber(startOn);
  const end = dayNumber(endOn);
  if (start === null || end === null || end <= start) return 0;
  const den = 365n * 1000000n;
  const num = BigInt(principalCents) * BigInt(rateE6) * BigInt(end - start);
  return Number((num * 2n + den) / (2n * den));
}

/** 计息算到哪天：到期了就停在到期日。 */
function accrualEnd(row, today) {
  const due = row.matures_on;
  return due && due < today ? due : today;
}

/**
 * 这笔理财今天值多少（分）。清仓 0；unit 没价格是 null（不知道值多少，统计里跳过）。
 * `row` 是数据库行（snake_case）。
 */
function valueOf(row, today) {
  if (!(Number(row.quantity_e4) > 0)) return 0;
  const cost = Number(row.cost_cents) || 0;
  switch (modeOf(kindOf(row))) {
    case 'unit':
      return row.price_e4 === null || row.price_e4 === undefined ? null : marketCents(row.quantity_e4, row.price_e4);
    case 'deposit': {
      const accrued = accruedCents(cost, Number(row.rate_e6) || 0, row.opened_on, accrualEnd(row, today));
      const paid = Math.max(0, Number(row.realized_cents) || 0);
      return cost + Math.max(0, accrued - paid);
    }
    default:
      return row.value_cents === null || row.value_cents === undefined ? cost : Number(row.value_cents);
  }
}

module.exports = { KINDS, MODE, HELD_E4, MAX_RATE_E6, modeOf, kindOf, marketCents, dayNumber, accruedCents, valueOf };
