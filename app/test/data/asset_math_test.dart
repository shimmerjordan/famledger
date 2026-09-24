import 'package:famledger/data/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

Asset item({
  String id = 'a1',
  int price = 600000,
  String purchasedOn = '2026-09-01',
  String status = Asset.statusInUse,
  String? endedOn,
  int? sale,
  int? expectedDays,
  int sortOrder = 0,
  bool archived = false,
}) => Asset(
  id: id,
  name: id,
  priceCents: price,
  purchasedOn: purchasedOn,
  status: status,
  endedOn: endedOn,
  saleCents: sale,
  expectedDays: expectedDays,
  sortOrder: sortOrder,
  archived: archived,
);

Holding holding({
  String id = 'h1',
  int qty = 10000000,
  int cost = 100000,
  int? price,
  int? prev,
  String source = Holding.sourceAuto,
  DateTime? priceAt,
  String openedOn = '2026-09-14',
  bool archived = false,
}) => Holding(
  id: id,
  name: id,
  code: '161725',
  market: 'fund',
  quantityE4: qty,
  costCents: cost,
  priceE4: price,
  prevCloseE4: prev,
  priceSource: source,
  priceAt: priceAt,
  openedOn: openedOn,
  archived: archived,
);

void main() {
  // 本地 9 月 23 日上午十点。
  final now = DateTime(2026, 9, 23, 10);

  group('物品天数与日均（B3）', () {
    test('首尾都算：今天买的 = 1 天，日均就是买价', () {
      final u = assetUsage(item(purchasedOn: '2026-09-23', price: 5999), now);
      expect(u.days, 1);
      expect(u.dailyCents, 5999);
    });

    test('9/1 买、9/23 看 = 23 天', () {
      final u = assetUsage(item(price: 690000), now);
      expect(u.days, 23);
      expect(u.dailyCents, closeTo(30000, 0.001));
    });

    test('按本地日期数：午夜前后差一天', () {
      final a = item();
      expect(assetUsage(a, DateTime(2026, 9, 23, 23, 59)).days, 23);
      expect(assetUsage(a, DateTime(2026, 9, 24, 0, 1)).days, 24);
      // 传进来的是 UTC 时刻也换成本地那天再数。
      final utc = DateTime(2026, 9, 24, 0, 1).toUtc();
      expect(assetUsage(a, utc).days, 24);
    });

    test('买入日期晚于今天（时钟不准）也至少 1 天，不除以 0', () {
      final u = assetUsage(item(purchasedOn: '2026-10-01', price: 100), now);
      expect(u.days, 1);
      expect(u.dailyCents, 100);
    });

    test('退役后天数停在结束那天，之后不再涨', () {
      final a = item(
        status: Asset.statusRetired,
        endedOn: '2026-09-10',
        price: 100000,
      );
      expect(assetUsage(a, now).days, 10);
      expect(assetUsage(a, DateTime(2027, 1, 1)).days, 10);
      expect(assetUsage(a, now).dailyCents, 10000);
    });

    test('卖出：日均 = (买价 − 卖出价) / 天数', () {
      final a = item(
        status: Asset.statusSold,
        endedOn: '2026-09-10',
        price: 100000,
        sale: 40000,
      );
      final u = assetUsage(a, DateTime(2030, 1, 1));
      expect(u.days, 10);
      expect(u.dailyCents, 6000);
    });

    test('卖得比买得贵：日均为负', () {
      final a = item(
        status: Asset.statusSold,
        endedOn: '2026-09-04',
        price: 10000,
        sale: 12000,
      );
      expect(assetUsage(a, now).dailyCents, -500);
    });

    test('有预期天数：目标日均 = 买价 / 预期天数，进度 = 天数 / 预期天数', () {
      final u = assetUsage(item(price: 1095000, expectedDays: 1095), now);
      expect(u.targetDailyCents, 1000);
      expect(u.progress, closeTo(23 / 1095, 1e-9));
    });

    test('用超了预期，进度大于 1', () {
      final u = assetUsage(item(purchasedOn: '2026-09-01', expectedDays: 10), now);
      expect(u.progress, closeTo(2.3, 1e-9));
    });

    test('没设预期：没有目标也没有进度', () {
      final u = assetUsage(item(), now);
      expect(u.targetDailyCents, isNull);
      expect(u.progress, isNull);
    });
  });

  group('物品汇总与排序', () {
    test('汇总只算在用和闲置的，退役/卖出/归档的不算', () {
      final s = summarizeAssets([
        item(id: 'a', price: 23000), // 23 天 → 1000/天
        item(id: 'b', price: 46000, status: Asset.statusIdle), // 2000/天
        item(id: 'c', status: Asset.statusRetired, endedOn: '2026-09-02'),
        item(id: 'd', status: Asset.statusSold, endedOn: '2026-09-02', sale: 1),
        item(id: 'e', archived: true),
      ], now);
      expect(s.count, 2);
      expect(s.idleCount, 1);
      expect(s.priceCents, 69000);
      expect(s.dailyCents, closeTo(3000, 1e-9));
      expect(s.isEmpty, isFalse);
    });

    test('一件都不在用：isEmpty', () {
      expect(summarizeAssets(const [], now).isEmpty, isTrue);
    });

    test('按日均 / 天数 / 价格从大到小', () {
      final list = [
        item(id: 'cheap-old', price: 1000, purchasedOn: '2026-01-01'),
        item(id: 'pricey-new', price: 900000, purchasedOn: '2026-09-22'),
        item(id: 'mid', price: 50000, purchasedOn: '2026-06-01'),
      ];
      String ids(AssetSort by) =>
          sortAssets(list, by, now).map((a) => a.id).join(',');
      expect(ids(AssetSort.daily), 'pricey-new,mid,cheap-old');
      expect(ids(AssetSort.days), 'cheap-old,mid,pricey-new');
      expect(ids(AssetSort.price), 'pricey-new,mid,cheap-old');
    });

    test('一样大的按用户自己的顺序', () {
      final list = [
        item(id: 'second', sortOrder: 2),
        item(id: 'first', sortOrder: 1),
      ];
      expect(
        sortAssets(list, AssetSort.price, now).map((a) => a.id),
        ['first', 'second'],
      );
    });
  });

  group('持仓（C3）', () {
    test('市值 / 收益 / 收益率 / 今日涨跌 / 持有天数 / 日均收益', () {
      // 1000 份、净值 1.2 → 市值 1200 元；成本 1000 元；昨收 1.1。
      final h = holding(
        price: 12000,
        prev: 11000,
        priceAt: now.subtract(const Duration(hours: 2)),
      );
      final m = holdingMetrics(h, now);
      expect(m.marketCents, 120000);
      expect(m.gainCents, 20000);
      expect(m.gainRate, closeTo(0.2, 1e-9));
      expect(m.todayChangeCents, 10000);
      expect(m.days, 10); // 9/14 → 9/23
      expect(m.dailyGainCents, 2000);
      expect(m.cleared, isFalse);
      expect(m.stale, isFalse);
      expect(m.manual, isFalse);
    });

    test('跌了：收益、收益率、今日涨跌都是负的', () {
      final h = holding(price: 9000, prev: 9500, priceAt: now);
      final m = holdingMetrics(h, now);
      expect(m.gainCents, -10000);
      expect(m.gainRate, closeTo(-0.1, 1e-9));
      expect(m.todayChangeCents, -5000);
    });

    test('没价格：市值、收益都说不出来', () {
      final m = holdingMetrics(holding(), now);
      expect(m.hasPrice, isFalse);
      expect(m.marketCents, isNull);
      expect(m.gainCents, isNull);
      expect(m.dailyGainCents, isNull);
      expect(m.todayChangeCents, isNull);
      expect(m.stale, isFalse);
    });

    test('手动价没有昨收：今日涨跌为 null，标成手动', () {
      final h = holding(price: 12000, source: Holding.sourceManual, priceAt: now);
      final m = holdingMetrics(h, now);
      expect(m.manual, isTrue);
      expect(m.todayChangeCents, isNull);
      expect(m.marketCents, 120000);
    });

    test('价格超过一天没更新算过期', () {
      final fresh = holding(
        price: 1,
        priceAt: now.subtract(const Duration(hours: 23)),
      );
      final old = holding(
        price: 1,
        priceAt: now.subtract(const Duration(hours: 25)),
      );
      expect(holdingMetrics(fresh, now).stale, isFalse);
      expect(holdingMetrics(old, now).stale, isTrue);
      expect(holdingMetrics(holding(price: 1), now).stale, isTrue);
    });

    test('成本为 0 说不出收益率', () {
      final m = holdingMetrics(holding(cost: 0, price: 10000, priceAt: now), now);
      expect(m.gainRate, isNull);
      expect(m.gainCents, 100000);
    });

    test('份额为 0 = 已清仓', () {
      final m = holdingMetrics(holding(qty: 0, cost: 0, price: 10000), now);
      expect(m.cleared, isTrue);
      expect(m.marketCents, 0);
    });

    test('今天开仓 = 持有 1 天', () {
      expect(holdingMetrics(holding(openedOn: '2026-09-23'), now).days, 1);
    });

    test('大数走 BigInt 不丢精度，四舍五入与服务端一致', () {
      // 中间积 ≈ 1.2e18，早就越过 2^53（网页端的 double 会丢尾数）。
      expect(marketCentsOf(12345678901, 98765432), 1219326309991);
      expect(marketCentsOf(15, 100000), 2); // 1.5 → 2
      expect(marketCentsOf(14, 100000), 1); // 1.4 → 1
    });

    test('汇总：没价格和清仓的不进市值与成本，今日涨跌只加有昨收的', () {
      final s = summarizeHoldings([
        holding(id: 'a', price: 12000, prev: 11000, priceAt: now),
        holding(
          id: 'b',
          qty: 20000,
          cost: 150,
          price: 10000,
          source: Holding.sourceManual,
          priceAt: now,
        ),
        holding(id: 'c'),
        holding(id: 'd', qty: 0, cost: 0, price: 10000),
        holding(id: 'e', price: 99999, archived: true),
      ], now);
      expect(s.marketCents, 120000 + 200);
      expect(s.costCents, 100000 + 150);
      expect(s.gainCents, 20000 + 50);
      expect(s.todayChangeCents, 10000);
      expect(s.heldCount, 3);
      expect(s.unpricedCount, 1);
      expect(s.clearedCount, 1);
      expect(s.gainRate, closeTo(20050 / 100150, 1e-12));
    });

    test('一只都没有：isEmpty；只剩清仓的不算空', () {
      expect(summarizeHoldings(const [], now).isEmpty, isTrue);
      expect(
        summarizeHoldings([holding(qty: 0, cost: 0)], now).isEmpty,
        isFalse,
      );
    });
  });

  group('减仓预计盈亏（与 holdings.js 逐位一致）', () {
    final h = holding(qty: 30000, cost: 10000);

    test('按移动平均摊成本，四舍五入', () {
      final one = previewSell(h, 10000, 5000)!;
      expect(one.costCents, 3333);
      expect(one.realizedCents, 1667);
      expect(one.remainingQuantityE4, 20000);
      expect(one.remainingCostCents, 6667);

      final two = previewSell(h, 20000, 5000)!;
      expect(two.costCents, 6667);
      expect(two.realizedCents, -1667);
    });

    test('全卖：成本整份摊掉', () {
      final all = previewSell(h, 30000, 12000)!;
      expect(all.costCents, 10000);
      expect(all.realizedCents, 2000);
      expect(all.remainingCostCents, 0);
      expect(all.remainingQuantityE4, 0);
    });

    test('份额 ≤ 0 或超过持有：null', () {
      expect(previewSell(h, 0, 1), isNull);
      expect(previewSell(h, 30001, 1), isNull);
    });
  });

  group('格式', () {
    test('parseE4：千分位、全角逗号、第 5 位四舍五入', () {
      expect(parseE4('1,234.5678'), 12345678);
      expect(parseE4('1，000'), 10000000);
      expect(parseE4('0.00005'), 1);
      expect(parseE4('0.00004'), 0);
      expect(parseE4('.5'), 5000);
      expect(parseE4('12.'), 120000);
      expect(parseE4(''), isNull);
      expect(parseE4('.'), isNull);
      expect(parseE4('-1'), isNull);
      expect(parseE4('abc'), isNull);
    });

    test('formatE4：去掉末尾的 0，至少留 minFraction 位', () {
      expect(formatE4(12345678), '1,234.5678');
      expect(formatE4(10000000), '1,000');
      expect(formatE4(15000, minFraction: 2), '1.50');
      expect(formatE4(-5000), '−0.5');
    });

    test('formatRate：正数带 +，负数用排版减号，0 不带符号', () {
      expect(formatRate(0.0523), '+5.23%');
      expect(formatRate(-0.1), '−10.00%');
      expect(formatRate(0.00001), '0.00%');
      expect(formatRate(0), '0.00%');
    });
  });
}
