import 'dart:math' as math;

import '../../core/money.dart';
import 'asset.dart';
import 'asset_math.dart';

// 实物估值（spec §3）。和 server/src/lib/valuation.js 是同一套口径的两份实现，两边共读
// server/test/fixtures/valuation_golden.json（允许 ±1 分）：改公式必须两端同改，并重算向量。
// 全是纯函数，「现在」由调用方传进来。日均（asset_math.dart）和估值是两套数，互不影响。

/// 一个类别的默认估值参数。[rateBp] / [residualBp] / [years] 在类别自己的方法用不到时也有值：
/// 单件把方法改成别的、又没填参数时就用它们。
class CategoryValuation {
  const CategoryValuation({
    required this.method,
    required this.rateBp,
    required this.residualBp,
    required this.years,
    required this.netWorth,
    this.uncertain = false,
  });

  /// straight | declining | locked
  final String method;

  /// 每年打折法的年折率（基点）。
  final int rateBp;

  /// 直线法的残值率 / 打折法的保底比例（基点）。
  final int residualBp;

  /// 直线法的默认年限（物品没填预期天数时用）。
  final int years;

  /// 单件是 auto 时计不计入净资产。
  final bool netWorth;

  /// 界面上标「估值不确定」。
  final bool uncertain;
}

/// 类别默认表，键的顺序同 [Asset.categories]。与服务端 CATEGORY_DEFAULTS 逐项相同（向量测试比对）。
const Map<String, CategoryValuation> kCategoryValuation = {
  'digital': CategoryValuation(method: Asset.methodDeclining, rateBp: 2500, residualBp: 1000, years: 4, netWorth: true),
  'appliance': CategoryValuation(method: Asset.methodStraight, rateBp: 2000, residualBp: 500, years: 8, netWorth: false),
  'furniture': CategoryValuation(method: Asset.methodStraight, rateBp: 2000, residualBp: 0, years: 10, netWorth: false),
  'clothing': CategoryValuation(method: Asset.methodStraight, rateBp: 3000, residualBp: 0, years: 3, netWorth: false),
  'vehicle': CategoryValuation(method: Asset.methodDeclining, rateBp: 1800, residualBp: 1000, years: 10, netWorth: true),
  'luxury': CategoryValuation(method: Asset.methodDeclining, rateBp: 1500, residualBp: 3000, years: 10, netWorth: true, uncertain: true),
  'jewelry': CategoryValuation(method: Asset.methodLocked, rateBp: 1000, residualBp: 3000, years: 10, netWorth: true),
  'sports': CategoryValuation(method: Asset.methodStraight, rateBp: 2000, residualBp: 1000, years: 5, netWorth: false),
  'other': CategoryValuation(method: Asset.methodStraight, rateBp: 2000, residualBp: 0, years: 5, netWorth: false),
};

/// 不认识的类别按「其他」。
CategoryValuation categoryValuation(String category) =>
    kCategoryValuation[category] ?? kCategoryValuation['other']!;

/// 一键预设：点一下把方式、年折率、残值填好（spec §2：只写在客户端，不单独存一列）。
/// AI 导入（P4）给物品挑预设时也只能从这份名单里挑。
class ValuationPreset {
  const ValuationPreset({
    required this.key,
    required this.label,
    required this.categories,
    required this.method,
    this.rateBp,
    this.residualBp,
  });

  final String key;
  final String label;

  /// 在哪些类别的表单里出现。
  final List<String> categories;
  final String method;

  /// null = 清掉（跟随类别）；锁定类预设两个都是 null。
  final int? rateBp;
  final int? residualBp;
}

const List<ValuationPreset> kValuationPresets = [
  ValuationPreset(key: 'apple', label: '苹果设备', categories: ['digital'], method: Asset.methodDeclining, rateBp: 2000, residualBp: 1000),
  ValuationPreset(key: 'android_pc', label: '安卓/Windows', categories: ['digital'], method: Asset.methodDeclining, rateBp: 3000, residualBp: 1000),
  ValuationPreset(key: 'lens', label: '相机镜头', categories: ['digital'], method: Asset.methodDeclining, rateBp: 1000, residualBp: 3000),
  ValuationPreset(key: 'ev', label: '新能源车', categories: ['vehicle'], method: Asset.methodDeclining, rateBp: 2300, residualBp: 1000),
  ValuationPreset(key: 'bike', label: '自行车', categories: ['vehicle', 'sports'], method: Asset.methodDeclining, rateBp: 2500, residualBp: 1500),
  ValuationPreset(key: 'fashion_bag', label: '轻奢箱包', categories: ['luxury'], method: Asset.methodDeclining, rateBp: 3000, residualBp: 500),
  ValuationPreset(key: 'watch', label: '一般机械表', categories: ['luxury', 'jewelry'], method: Asset.methodDeclining, rateBp: 2000, residualBp: 2000),
  ValuationPreset(key: 'keep_value', label: '保值款', categories: ['luxury', 'jewelry'], method: Asset.methodLocked),
];

List<ValuationPreset> presetsFor(String category) => [
  for (final p in kValuationPresets)
    if (p.categories.contains(category)) p,
];

ValuationPreset? presetByKey(String key) {
  for (final p in kValuationPresets) {
    if (p.key == key) return p;
  }
  return null;
}

/// 这件物品实际用的方法与参数：单件字段 → 类别默认。
class ValuationParams {
  const ValuationParams({
    required this.method,
    required this.rateBp,
    required this.residualBp,
    required this.lifeDays,
    required this.followsCategory,
  });

  final String method;
  final int rateBp;
  final int residualBp;

  /// 直线法的年限（天）：预期天数，没填取类别默认年限 × 365。
  final int lifeDays;

  /// 单件的方式是 auto（跟着类别走）。
  final bool followsCategory;
}

ValuationParams resolveValuation(Asset a) {
  final cat = categoryValuation(a.category);
  final follows = a.valuationMethod == Asset.methodAuto;
  final expected = a.expectedDays;
  return ValuationParams(
    method: follows ? cat.method : a.valuationMethod,
    rateBp: a.rateBp ?? cat.rateBp,
    residualBp: a.residualBp ?? cat.residualBp,
    lifeDays: expected != null && expected > 0 ? expected : cat.years * 365,
    followsCategory: follows,
  );
}

/// [day]（[parseDay] 那种 UTC 零点表示）那天的估值（分），不看状态。
///
/// d = [day] − 买入日（买入当天估值 = 原价）。直线法 `P − P·(1−s)·min(d/L, 1)`；每年打折
/// `max(P·(1−r)^(d/365), P·s)`；锁定 `M ?? P`。手动锚点 M@D：打折法 `max(M·(1−r)^((d−dD)/365), min(M, P·s))`，
/// 直线法从 M 用剩余年限线性降到 `min(M, P·s)`、剩余年限不足直接取末值。锚点只管它那天以后；
/// 自动估值（没锚点）永远不超过原价；买入日期晚于 [day]（时钟不准）时天数按 0。
int valueAt(Asset a, DateTime day) {
  final p = resolveValuation(a);
  final price = a.priceCents.toDouble();
  final r = p.rateBp / 10000;
  final s = p.residualBp / 10000;
  final bought = parseDay(a.purchasedOn) ?? day;
  final d = math.max(0, day.difference(bought).inDays);
  final manual = a.manualValueCents;
  final anchorDay = manual == null ? null : parseDay(a.manualValueOn);
  final double v;
  if (p.method == Asset.methodLocked) {
    v = anchorDay != null && !day.isBefore(anchorDay) ? manual!.toDouble() : price;
  } else if (anchorDay == null || day.isBefore(anchorDay)) {
    final auto = p.method == Asset.methodStraight
        ? price - price * (1 - s) * math.min(d / p.lifeDays, 1.0)
        : math.max(price * math.pow(1 - r, d / 365), price * s);
    v = math.min(auto, price);
  } else {
    final m = manual!.toDouble();
    final dD = math.max(0, anchorDay.difference(bought).inDays);
    final floor = math.min(m, price * s);
    if (p.method == Asset.methodStraight) {
      final remain = p.lifeDays - dD;
      v = remain <= 0 ? floor : m - (m - floor) * math.min((d - dD) / remain, 1.0);
    } else {
      v = math.max(m * math.pow(1 - r, (d - dD) / 365), floor);
    }
  }
  return v.round();
}

/// 今天的估值；已卖出、已退役的是 0（退出汇总）。
int currentValue(Asset a, DateTime now) => a.isEnded ? 0 : valueAt(a, localDay(now));

/// 已结束的物品在结束那天的估值；在用、闲置的（或结束日期坏了）是 null。
int? endedValue(Asset a) {
  if (!a.isEnded) return null;
  final ended = parseDay(a.endedOn);
  return ended == null ? null : valueAt(a, ended);
}

/// 处置盈亏 = 卖出价（没有按 0）− 结束那天的估值。只展示，不记账。
int? disposalGain(Asset a) {
  final at = endedValue(a);
  return at == null ? null : (a.saleCents ?? 0) - at;
}

/// 单件 include / exclude 说了算，auto 跟类别默认。全局开关不在这里（服务端 overview 管）。
bool countsInNetWorth(Asset a) => switch (a.netWorth) {
  Asset.netWorthInclude => true,
  Asset.netWorthExclude => false,
  _ => categoryValuation(a.category).netWorth,
};

/// 箱包/奢侈品这种估值没谱的类别，又没手动估过：界面上标「估值不确定」。
bool valuationUncertain(Asset a) =>
    categoryValuation(a.category).uncertain && a.manualValueCents == null;

/// 手动锚点有多少个整月没更新；没超过 12 个月（或没锚点）是 null。
///
/// spec 说的是「超过 12 个月」：整一年那天还不提醒，过了那天才提醒（N 从 12 起）。
int? anchorStaleMonths(Asset a, DateTime now) {
  if (a.manualValueCents == null) return null;
  final on = parseDay(a.manualValueOn);
  if (on == null) return null;
  final today = localDay(now);
  var months = (today.year - on.year) * 12 + today.month - on.month;
  if (today.day < on.day) months--;
  final over = months > 12 || (months == 12 && today.day != on.day);
  return over ? months : null;
}

/// 估值较原价：`−9%`、`+20% 未实现`；原价 0 或四舍五入后是 0% 时不说（null）。
String? valueChangeLabel(int valueCents, int priceCents) {
  if (priceCents <= 0) return null;
  final pct = ((valueCents - priceCents) * 100 / priceCents).round();
  if (pct == 0) return null;
  return pct < 0 ? '${Money.minus}${-pct}%' : '+$pct% 未实现';
}

/// 基点 → 百分数（不带 %）：`2500` → `25`，`1250` → `12.5`。表单回显和说明文字共用。
String bpText(int bp) {
  final whole = bp ~/ 100;
  final frac = bp % 100;
  if (frac == 0) return '$whole';
  final digits = frac.toString().padLeft(2, '0');
  return '$whole.${digits.endsWith('0') ? digits[0] : digits}';
}

/// 一句人话：这件的估值怎么来的。表单「方式」下面和详情页「估值」里都用它。
String valuationExplain(Asset a) {
  final p = resolveValuation(a);
  final rule = switch (p.method) {
    Asset.methodLocked => a.manualValueCents != null ? '不折旧，按手动估值' : '不折旧，按原价',
    Asset.methodStraight =>
      '${_lifeLabel(p.lifeDays)}内匀速降到${p.residualBp == 0 ? ' 0' : '原价的 ${bpText(p.residualBp)}%'}',
    _ => '${_yearlyLabel(p.rateBp)}${p.residualBp == 0 ? '' : '，最低到原价的 ${bpText(p.residualBp)}%'}',
  };
  final manual = a.manualValueCents;
  final anchor = p.method != Asset.methodLocked && manual != null && a.manualValueOn != null
      ? '；从 ${a.manualValueOn} 的手动估值 ${Money.format(manual)} 起算'
      : '';
  final prefix = p.followsCategory ? '跟随「${a.categoryLabel}」：' : '';
  return '$prefix$rule$anchor';
}

/// 详情页「计入净资产」那一行。[switchOn] 是家庭设置里「实物计入净资产」的总开关：
/// 关着时本该计入的这件也不进净资产，得明说，不然和资产页顶上的「不含实物」对不上。
String netWorthLabel(Asset a, {bool switchOn = true}) {
  if (!switchOn && countsInNetWorth(a)) return '暂不计入（总开关已关）';
  return switch (a.netWorth) {
    Asset.netWorthInclude => '计入',
    Asset.netWorthExclude => '不计入',
    _ => categoryValuation(a.category).netWorth ? '计入（跟随类别）' : '不计入（跟随类别）',
  };
}

/// 1、2、3 年后（今天 + 365·k 天）的估值；已结束的物品不预估。
List<int> valueForecast(Asset a, DateTime now, {int years = 3}) {
  if (a.isEnded) return const [];
  final today = localDay(now);
  return [
    for (var k = 1; k <= years; k++) valueAt(a, today.add(Duration(days: 365 * k))),
  ];
}

String _lifeLabel(int days) => days % 365 == 0 ? '${days ~/ 365} 年' : '$days 天';

const List<String> _cnDigits = ['零', '一', '二', '三', '四', '五', '六', '七', '八', '九'];

/// 年折率 → 「每年打七五折」；不是整百分点（说不成几折）就说「每年降 12.5%」。
String _yearlyLabel(int rateBp) {
  if (rateBp == 0) return '不折旧';
  if (rateBp % 100 != 0) return '每年降 ${bpText(rateBp)}%';
  final keep = 100 - rateBp ~/ 100;
  final ones = keep % 10;
  return '每年打${_cnDigits[keep ~/ 10]}${ones == 0 ? '' : _cnDigits[ones]}折';
}
