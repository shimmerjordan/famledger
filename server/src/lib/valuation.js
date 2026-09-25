'use strict';

// 实物估值（spec §3「实物估值」）。和 App 的 app/lib/data/models/asset_valuation.dart 是同一套口径的
// 两份实现，两边共读 test/fixtures/valuation_golden.json（允许 ±1 分）：改公式必须两端同改，并重算向量。
//
//   valueAt(asset, asOf)            某一天的估值（分），不看状态
//   currentValue(asset, today)      今天的估值；已卖出、已退役的是 0
//   countsInNetWorth(asset)         单件三态 + 类别默认（全局开关不在这里，见 stats.js）
//   summarizePhysical(assets, today) → { valueCents, includedCents, count }
//
// asset 是 API 形状（camelCase，也就是 rowToJson 之后的行）；日期都是 `YYYY-MM-DD`。
// 估值不落库：只存事实和用户的选择，每次现算，服务端和 App 才不会各记一个数。

const DAY_MS = 86400000;
const METHODS = ['auto', 'straight', 'declining', 'locked'];
const NET_WORTH = ['auto', 'include', 'exclude'];
const ENDED = new Set(['retired', 'sold']);

/**
 * 类别默认（spec §3 的默认表）。rateBp / residualBp / years 在类别自己的方法用不到时也给了值：
 * 单件把方法改成别的、又没填参数时就用它们。**键的顺序就是类别名单的顺序**（modules/assets.js
 * 直接拿它做校验，App 的类别 chip 也按这个顺序）。
 */
const CATEGORY_DEFAULTS = Object.freeze({
  digital: Object.freeze({ method: 'declining', rateBp: 2500, residualBp: 1000, years: 4, netWorth: true, uncertain: false }),
  appliance: Object.freeze({ method: 'straight', rateBp: 2000, residualBp: 500, years: 8, netWorth: false, uncertain: false }),
  furniture: Object.freeze({ method: 'straight', rateBp: 2000, residualBp: 0, years: 10, netWorth: false, uncertain: false }),
  clothing: Object.freeze({ method: 'straight', rateBp: 3000, residualBp: 0, years: 3, netWorth: false, uncertain: false }),
  vehicle: Object.freeze({ method: 'declining', rateBp: 1800, residualBp: 1000, years: 10, netWorth: true, uncertain: false }),
  luxury: Object.freeze({ method: 'declining', rateBp: 1500, residualBp: 3000, years: 10, netWorth: true, uncertain: true }),
  jewelry: Object.freeze({ method: 'locked', rateBp: 1000, residualBp: 3000, years: 10, netWorth: true, uncertain: false }),
  sports: Object.freeze({ method: 'straight', rateBp: 2000, residualBp: 1000, years: 5, netWorth: false, uncertain: false }),
  other: Object.freeze({ method: 'straight', rateBp: 2000, residualBp: 0, years: 5, netWorth: false, uncertain: false }),
});

const categoryOf = (category) => CATEGORY_DEFAULTS[category] || CATEGORY_DEFAULTS.other;

const pad = (n) => String(n).padStart(2, '0');

/** 服务器本地日期（部署镜像钉在 Asia/Shanghai），和 modules/assets.js 的 today() 同一个口径。 */
function localToday(d = new Date()) {
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

/** `YYYY-MM-DD` → 那天 UTC 零点的毫秒；认不出是 null。按 UTC 数天数，碰不上夏令时。 */
function dayMs(raw) {
  if (typeof raw !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(raw)) return null;
  const t = Date.parse(`${raw}T00:00:00Z`);
  return Number.isNaN(t) ? null : t;
}

/** 这件物品实际用的方法和参数：单件字段 → 类别默认。不认识的方法（以后的新值）按 auto。 */
function resolveParams(asset) {
  const cat = categoryOf(asset.category);
  const m = asset.valuationMethod;
  return {
    method: METHODS.includes(m) && m !== 'auto' ? m : cat.method,
    rateBp: Number.isInteger(asset.rateBp) ? asset.rateBp : cat.rateBp,
    residualBp: Number.isInteger(asset.residualBp) ? asset.residualBp : cat.residualBp,
    // 直线法的年限复用 expected_days，没填取类别默认年限。
    lifeDays: Number.isInteger(asset.expectedDays) && asset.expectedDays > 0 ? asset.expectedDays : cat.years * 365,
  };
}

/**
 * [asOf] 那天的估值（分，四舍五入）。d = asOf − 买入日（买入当天估值等于原价；和日均「首尾都算」的天数不同）。
 *
 *   直线法      V = P − P·(1−s)·min(d/L, 1)
 *   每年打折    V = max(P·(1−r)^(d/365), P·s)
 *   锁定        V = M ?? P
 *   手动锚点 M@D：打折法 max(M·(1−r)^((d−dD)/365), min(M, P·s))；直线法从 M 线性降到 min(M, P·s)，
 *               用剩余年限 L−dD 降完，剩余年限不足时直接取末值。
 *
 * 锚点只管它那天以后：算卖出那天的估值时，卖出之后才填的锚点不算数。自动估值（没有锚点）永远不超过原价；
 * 买入日期晚于 asOf（手机时钟不准）时天数按 0 算。
 */
function valueAt(asset, asOf) {
  const P = Number(asset.priceCents) || 0;
  const { method, rateBp, residualBp, lifeDays } = resolveParams(asset);
  const r = rateBp / 10000;
  const s = residualBp / 10000;
  const at = dayMs(asOf);
  const bought = dayMs(asset.purchasedOn) ?? at;
  const d = Math.max(0, Math.round((at - bought) / DAY_MS));
  const M = Number.isInteger(asset.manualValueCents) ? asset.manualValueCents : null;
  const anchorAt = M === null ? null : dayMs(asset.manualValueOn);
  const anchored = anchorAt !== null && at >= anchorAt;

  let v;
  if (method === 'locked') {
    v = anchored ? M : P;
  } else if (!anchored) {
    v = method === 'straight'
      ? P - P * (1 - s) * Math.min(d / lifeDays, 1)
      : Math.max(P * Math.pow(1 - r, d / 365), P * s);
    v = Math.min(v, P);
  } else {
    const dD = Math.max(0, Math.round((anchorAt - bought) / DAY_MS));
    const floor = Math.min(M, P * s);
    if (method === 'straight') {
      const remain = lifeDays - dD;
      v = remain <= 0 ? floor : M - (M - floor) * Math.min((d - dD) / remain, 1);
    } else {
      v = Math.max(M * Math.pow(1 - r, (d - dD) / 365), floor);
    }
  }
  return Math.round(v);
}

/** 今天的估值：已卖出、已退役的是 0（退出汇总，处置盈亏只在 App 详情页展示）。 */
function currentValue(asset, today) {
  return ENDED.has(asset.status) ? 0 : valueAt(asset, today);
}

/** 单件 include / exclude 说了算；auto（或缺字段、不认识的值）跟类别默认。 */
function countsInNetWorth(asset) {
  if (asset.netWorth === 'include') return true;
  if (asset.netWorth === 'exclude') return false;
  return categoryOf(asset.category).netWorth;
}

/**
 * 实物汇总：只算未归档、在用或闲置的。includedCents 是按单件/类别「该计入」的那部分，
 * 进不进净资产由调用方按家庭设置的全局开关决定。
 */
function summarizePhysical(assets, today) {
  let valueCents = 0;
  let includedCents = 0;
  let count = 0;
  for (const a of assets) {
    if (a.archived || ENDED.has(a.status)) continue;
    const v = currentValue(a, today);
    count++;
    valueCents += v;
    if (countsInNetWorth(a)) includedCents += v;
  }
  return { valueCents, includedCents, count };
}

module.exports = {
  METHODS,
  NET_WORTH,
  CATEGORY_DEFAULTS,
  localToday,
  resolveParams,
  valueAt,
  currentValue,
  countsInNetWorth,
  summarizePhysical,
};
