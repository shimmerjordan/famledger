import 'dart:math' as math;

import '../../core/money.dart';
import 'asset.dart';
import 'asset_valuation.dart';
import 'holding.dart';

// 物品与投资的派生数（spec B3 / C3）。服务端不算这些，两边口径不会分叉。
// 全是纯函数，「现在」一律由调用方传进来。

/// `YYYY-MM-DD` → 那一天（UTC 零点）。
///
/// 只拿来数天数：拿本地时间相减的话，碰上夏令时那天只有 23 小时，`inDays` 会少算一天。
DateTime? parseDay(String? raw) {
  if (raw == null) return null;
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(raw.trim());
  if (m == null) return null;
  final year = int.parse(m[1]!);
  final month = int.parse(m[2]!);
  final day = int.parse(m[3]!);
  final date = DateTime.utc(year, month, day);
  if (date.month != month || date.day != day) return null;
  return date;
}

/// [now] 在本地日历上是哪一天（与 [parseDay] 同一种表示）。
DateTime localDay(DateTime now) {
  final local = now.isUtc ? now.toLocal() : now;
  return DateTime.utc(local.year, local.month, local.day);
}

/// 首尾都算：同一天 = 1 天。
int daysInclusive(DateTime fromDay, DateTime toDay) =>
    toDay.difference(fromDay).inDays + 1;

// —— 物品 ——

class AssetUsage {
  const AssetUsage({
    required this.days,
    required this.dailyCents,
    this.targetDailyCents,
    this.progress,
  });

  /// 已用天数，至少 1。
  final int days;

  /// (买价 − 卖出价) / 天数。卖得比买得贵时为负。
  final double dailyCents;

  /// 买价 / 预期天数；没设预期就是 null。
  final double? targetDailyCents;

  /// 天数 / 预期天数，用满了会超过 1。
  final double? progress;
}

AssetUsage assetUsage(Asset asset, DateTime now) {
  final today = localDay(now);
  final start = parseDay(asset.purchasedOn) ?? today;
  // 有结束日期（退役/卖出）就停在那天，之后天数不再涨。
  final end = parseDay(asset.endedOn) ?? today;
  final days = math.max(1, daysInclusive(start, end));
  final expected = asset.expectedDays;
  final hasTarget = expected != null && expected > 0;
  return AssetUsage(
    days: days,
    dailyCents: (asset.priceCents - (asset.saleCents ?? 0)) / days,
    targetDailyCents: hasTarget ? asset.priceCents / expected : null,
    progress: hasTarget ? days / expected : null,
  );
}

class AssetSummary {
  const AssetSummary({
    this.count = 0,
    this.idleCount = 0,
    this.priceCents = 0,
    this.dailyCents = 0,
    this.valueCents = 0,
  });

  /// 在用 + 闲置的件数。
  final int count;

  /// 其中闲置的件数。
  final int idleCount;
  final int priceCents;

  /// 每天花费合计。
  final double dailyCents;

  /// 估值合计（asset_valuation.dart 的 [currentValue]），和日均是两套数。
  final int valueCents;

  /// 已折旧 = 原价合计 − 估值合计；手动估值高过原价时是负数（界面改说「比原价高」）。
  int get depreciationCents => priceCents - valueCents;

  bool get isEmpty => count == 0;
}

/// 只算还在家里的（在用 + 闲置）：退役、卖掉的日均已经定格，加进「每天花多少」会一直虚高。
AssetSummary summarizeAssets(Iterable<Asset> assets, DateTime now) {
  var count = 0;
  var idle = 0;
  var price = 0;
  var daily = 0.0;
  var value = 0;
  for (final asset in assets) {
    if (asset.archived || !asset.isHeld) continue;
    count++;
    if (asset.status == Asset.statusIdle) idle++;
    price += asset.priceCents;
    daily += assetUsage(asset, now).dailyCents;
    value += currentValue(asset, now);
  }
  return AssetSummary(
    count: count,
    idleCount: idle,
    priceCents: price,
    dailyCents: daily,
    valueCents: value,
  );
}

enum AssetSort { daily, days, price, value }

/// 一律从大到小；一样大的按用户自己的排序。
List<Asset> sortAssets(Iterable<Asset> assets, AssetSort by, DateTime now) {
  final usage = {for (final a in assets) a.id: assetUsage(a, now)};
  final values = by == AssetSort.value
      ? {for (final a in assets) a.id: currentValue(a, now)}
      : const <String, int>{};
  num key(Asset a) => switch (by) {
    AssetSort.daily => usage[a.id]!.dailyCents,
    AssetSort.days => usage[a.id]!.days,
    AssetSort.price => a.priceCents,
    AssetSort.value => values[a.id]!,
  };
  return assets.toList()..sort((a, b) {
    final c = key(b).compareTo(key(a));
    return c != 0 ? c : a.sortOrder.compareTo(b.sortOrder);
  });
}

// —— 投资 ——

final BigInt _e6 = BigInt.from(1000000);

/// n / d 四舍五入（d > 0，负数对称）。份额E4 × 价格E4 早就越过 2^53，只能走 BigInt。
BigInt _roundDiv(BigInt n, BigInt d) {
  final half = d ~/ BigInt.two;
  return n.isNegative ? -((-n + half) ~/ d) : (n + half) ~/ d;
}

/// 市值（分）= 份额E4 × 价格E4 / 1e6，与服务端 stats_sql.js 的 marketCents 同一个式子。
int marketCentsOf(int quantityE4, int priceE4) =>
    _roundDiv(BigInt.from(quantityE4) * BigInt.from(priceE4), _e6).toInt();

/// 价格多久没更新算过期。
const Duration priceStaleAfter = Duration(days: 1);

class HoldingMetrics {
  const HoldingMetrics({
    required this.days,
    required this.cleared,
    required this.stale,
    required this.manual,
    this.marketCents,
    this.gainCents,
    this.gainRate,
    this.dailyGainCents,
    this.todayChangeCents,
  });

  /// 没有价格时都是 null。
  final int? marketCents;
  final int? gainCents;

  /// 成本为 0 时说不出比例，也是 null。
  final double? gainRate;

  /// 持有天数（今天 − 开仓日 + 1），至少 1。
  final int days;
  final double? dailyGainCents;

  /// 没有昨收（手动价）时为 null。
  final int? todayChangeCents;

  /// 份额为 0：全卖光了，只剩已实现盈亏。
  final bool cleared;

  /// 有价格但超过 [priceStaleAfter] 没更新。
  final bool stale;
  final bool manual;

  bool get hasPrice => marketCents != null;
}

HoldingMetrics holdingMetrics(Holding h, DateTime now) {
  final today = localDay(now);
  final days = math.max(1, daysInclusive(parseDay(h.openedOn) ?? today, today));
  final price = h.priceE4;
  final prev = h.prevCloseE4;
  final market = price == null ? null : marketCentsOf(h.quantityE4, price);
  final gain = market == null ? null : market - h.costCents;
  final at = h.priceAt;
  return HoldingMetrics(
    days: days,
    cleared: h.isCleared,
    manual: !h.isAuto,
    stale: price != null && (at == null || now.difference(at) > priceStaleAfter),
    marketCents: market,
    gainCents: gain,
    gainRate: gain == null || h.costCents <= 0 ? null : gain / h.costCents,
    dailyGainCents: gain == null ? null : gain / days,
    todayChangeCents: price == null || prev == null
        ? null
        : _roundDiv(
            BigInt.from(h.quantityE4) * BigInt.from(price - prev),
            _e6,
          ).toInt(),
  );
}

class PortfolioSummary {
  const PortfolioSummary({
    this.marketCents = 0,
    this.costCents = 0,
    this.todayChangeCents = 0,
    this.heldCount = 0,
    this.unpricedCount = 0,
    this.clearedCount = 0,
  });

  final int marketCents;

  /// 只含有价格的持仓，和 [marketCents] 同一批（与服务端 overview 同口径）。
  final int costCents;
  final int todayChangeCents;

  /// 份额 > 0 的只数（含没价格的）。
  final int heldCount;
  final int unpricedCount;
  final int clearedCount;

  int get gainCents => marketCents - costCents;
  double? get gainRate => costCents > 0 ? gainCents / costCents : null;
  bool get isEmpty => heldCount == 0 && clearedCount == 0;
}

/// 没价格的、清了仓的都不进市值：前者不知道值多少，后者已经不值钱了。
PortfolioSummary summarizeHoldings(Iterable<Holding> holdings, DateTime now) {
  var market = 0;
  var cost = 0;
  var todayChange = 0;
  var held = 0;
  var unpriced = 0;
  var cleared = 0;
  for (final h in holdings) {
    if (h.archived) continue;
    if (h.isCleared) {
      cleared++;
      continue;
    }
    held++;
    final m = holdingMetrics(h, now);
    if (!m.hasPrice) {
      unpriced++;
      continue;
    }
    market += m.marketCents!;
    cost += h.costCents;
    todayChange += m.todayChangeCents ?? 0;
  }
  return PortfolioSummary(
    marketCents: market,
    costCents: cost,
    todayChangeCents: todayChange,
    heldCount: held,
    unpricedCount: unpriced,
    clearedCount: cleared,
  );
}

class SellPreview {
  const SellPreview({
    required this.costCents,
    required this.realizedCents,
    required this.remainingQuantityE4,
    required this.remainingCostCents,
  });

  /// 按移动平均摊给这次卖出的成本。
  final int costCents;
  final int realizedCents;
  final int remainingQuantityE4;
  final int remainingCostCents;
}

/// 减仓的预计已实现盈亏：round(成本 × 卖出份额 / 持有份额)，与服务端 holdings.js 逐位一致。
/// 份额填错（≤0 或超过持有）返回 null。
SellPreview? previewSell(Holding h, int quantityE4, int amountCents) {
  if (quantityE4 <= 0 || quantityE4 > h.quantityE4) return null;
  final int cost;
  if (quantityE4 == h.quantityE4) {
    cost = h.costCents;
  } else {
    final qty = BigInt.from(h.quantityE4);
    cost = ((BigInt.from(h.costCents) * BigInt.from(quantityE4) * BigInt.two + qty) ~/
            (BigInt.two * qty))
        .toInt();
  }
  return SellPreview(
    costCents: cost,
    realizedCents: amountCents - cost,
    remainingQuantityE4: h.quantityE4 - quantityE4,
    remainingCostCents: h.costCents - cost,
  );
}

// —— 格式 ——

/// `'1,234.5678'` → `12345678`；第 5 位小数四舍五入（同服务端 quotes.toE4）。负数、认不出返回 null。
int? parseE4(String raw) {
  var t = raw.trim();
  for (final ch in const [',', '，', ' ']) {
    t = t.replaceAll(ch, '');
  }
  final m = RegExp(r'^(\d*)(?:\.(\d*))?$').firstMatch(t);
  if (m == null || !RegExp(r'\d').hasMatch(t)) return null;
  final whole = m[1]!.isEmpty ? 0 : int.parse(m[1]!);
  final frac = (m[2] ?? '').padRight(5, '0');
  return whole * 10000 +
      int.parse(frac.substring(0, 4)) +
      (int.parse(frac[4]) >= 5 ? 1 : 0);
}

/// `12345678` → `'1,234.5678'`；末尾的 0 去掉，但至少留 [minFraction] 位小数。
String formatE4(int e4, {int minFraction = 0}) {
  final abs = e4.abs();
  var frac = (abs % 10000).toString().padLeft(4, '0');
  while (frac.length > minFraction && frac.endsWith('0')) {
    frac = frac.substring(0, frac.length - 1);
  }
  final whole = _group('${abs ~/ 10000}');
  final sign = e4 < 0 ? Money.minus : '';
  return frac.isEmpty ? '$sign$whole' : '$sign$whole.$frac';
}

/// `0.0523` → `'+5.23%'`；负数用排版减号，四舍五入后是 0 就不带符号。
String formatRate(double rate) {
  final pct = rate * 100;
  final text = pct.abs().toStringAsFixed(2);
  if (text == '0.00') return '0.00%';
  return '${pct > 0 ? '+' : Money.minus}$text%';
}

String _group(String digits) {
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
    buf.write(digits[i]);
  }
  return buf.toString();
}
