import 'dart:convert';
import 'dart:io';

import 'package:famledger/data/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 双端黄金向量：server/test/valuation.test.js 读同一份，两边各算各的，差不过 1 分。
/// 路径相对 `app/`（flutter test 的工作目录）。
const String _goldenPath = '../server/test/fixtures/valuation_golden.json';

Asset item(Map<String, dynamic> fields) => Asset.fromJson({'id': 'x', 'name': 'x', ...fields});

void main() {
  final file = File(_goldenPath);
  if (!file.existsSync()) {
    test('黄金向量缺失', () => fail('找不到 $_goldenPath'));
    return;
  }
  final golden = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final now = DateTime(2026, 9, 23, 10);

  test('类别默认表与向量文件逐项相同，顺序也一样', () {
    final categories = (golden['categories'] as Map).cast<String, dynamic>();
    expect(kCategoryValuation.keys.toList(), categories.keys.toList());
    for (final entry in categories.entries) {
      final got = kCategoryValuation[entry.key]!;
      expect({
        'method': got.method,
        'rateBp': got.rateBp,
        'residualBp': got.residualBp,
        'years': got.years,
        'netWorth': got.netWorth,
        'uncertain': got.uncertain,
      }, entry.value, reason: entry.key);
    }
  });

  group('向量（±1 分）', () {
    final cases = (golden['cases'] as List).cast<Map<String, dynamic>>();
    for (var i = 0; i < cases.length; i++) {
      final c = cases[i];
      test(c['name'] as String, () {
        final asset = Asset.fromJson({
          'id': 'g$i',
          'name': c['name'],
          ...(c['asset'] as Map).cast<String, dynamic>(),
        });
        final day = parseDay(c['asOf'] as String)!;
        // currentValue 吃的是「现在」这一刻：取那天本地中午，跑在哪个时区都落在同一天。
        final noon = DateTime(day.year, day.month, day.day, 12);
        expect(valueAt(asset, day), closeTo(c['valueAtCents'] as int, 1));
        expect(currentValue(asset, noon), closeTo(c['currentCents'] as int, 1));
        expect(countsInNetWorth(asset), c['countsInNetWorth']);
        if (c.containsKey('endedValueCents')) {
          expect(endedValue(asset), closeTo(c['endedValueCents'] as int, 1));
          expect(disposalGain(asset), closeTo(c['disposalCents'] as int, 1));
        } else {
          expect(disposalGain(asset), isNull);
        }
      });
    }
  });

  group('说明文字', () {
    test('跟随类别时带类别名；打折法说成「打几折」，说不成就说降百分之几', () {
      expect(
        valuationExplain(item({'category': 'digital', 'priceCents': 1, 'purchasedOn': '2026-09-01'})),
        '跟随「数码」：每年打七五折，最低到原价的 10%',
      );
      expect(
        valuationExplain(item({'category': 'luxury', 'priceCents': 1, 'purchasedOn': '2026-09-01'})),
        '跟随「箱包/奢侈品」：每年打八五折，最低到原价的 30%',
      );
      expect(
        valuationExplain(item({
          'category': 'digital', 'priceCents': 1, 'purchasedOn': '2026-09-01',
          'valuationMethod': 'declining', 'rateBp': 1250, 'residualBp': 0,
        })),
        '每年降 12.5%',
      );
    });

    test('直线法：年限按预期天数（整年说几年）；残值 0 说「降到 0」', () {
      expect(
        valuationExplain(item({'category': 'appliance', 'priceCents': 1, 'purchasedOn': '2026-09-01'})),
        '跟随「家电」：8 年内匀速降到原价的 5%',
      );
      expect(
        valuationExplain(item({
          'category': 'digital', 'priceCents': 1, 'purchasedOn': '2026-09-01',
          'valuationMethod': 'straight', 'expectedDays': 730, 'residualBp': 2000,
        })),
        '2 年内匀速降到原价的 20%',
      );
      expect(
        valuationExplain(item({
          'category': 'appliance', 'priceCents': 1, 'purchasedOn': '2026-09-01',
          'valuationMethod': 'straight', 'expectedDays': 1000, 'residualBp': 0,
        })),
        '1000 天内匀速降到 0',
      );
    });

    test('锁定：有锚点按手动估值，没有按原价；打折法有锚点说从哪天起算', () {
      expect(
        valuationExplain(item({
          'category': 'jewelry', 'priceCents': 1, 'purchasedOn': '2020-05-01',
          'manualValueCents': 1200000, 'manualValueOn': '2025-08-01',
        })),
        '跟随「首饰/贵金属」：不折旧，按手动估值',
      );
      expect(
        valuationExplain(item({'category': 'jewelry', 'priceCents': 1, 'purchasedOn': '2020-05-01'})),
        '跟随「首饰/贵金属」：不折旧，按原价',
      );
      expect(
        valuationExplain(item({
          'category': 'digital', 'priceCents': 1, 'purchasedOn': '2025-03-01',
          'manualValueCents': 400000, 'manualValueOn': '2026-03-01',
        })),
        '跟随「数码」：每年打七五折，最低到原价的 10%；从 2026-03-01 的手动估值 ¥4,000.00 起算',
      );
    });
  });

  test('较原价：低了写负百分比，高了写「未实现」，原价 0 或不到 1% 不写', () {
    expect(valueChangeLabel(589588, 599900), '−2%');
    expect(valueChangeLabel(292411, 320000), '−9%');
    expect(valueChangeLabel(1200000, 1000000), '+20% 未实现');
    expect(valueChangeLabel(599900, 599900), isNull);
    expect(valueChangeLabel(599000, 599900), isNull);
    expect(valueChangeLabel(100, 0), isNull);
  });

  test('锚点超过 12 个月才提醒：整一年那天不算，过了那天从 12 起', () {
    Asset anchored(String on) => item({
      'priceCents': 1, 'purchasedOn': '2020-01-01', 'manualValueCents': 1, 'manualValueOn': on,
    });
    expect(anchorStaleMonths(anchored('2025-08-01'), now), 13);
    expect(anchorStaleMonths(anchored('2025-09-22'), now), 12);
    expect(anchorStaleMonths(anchored('2025-09-23'), now), isNull, reason: '今天正好满一年，还没超过');
    expect(anchorStaleMonths(anchored('2025-09-24'), now), isNull);
    // 月底：8/31 的锚点，第二年 8/31 不算、9/1 才算超过。
    expect(anchorStaleMonths(anchored('2024-08-31'), DateTime(2025, 8, 31, 10)), isNull);
    expect(anchorStaleMonths(anchored('2024-08-31'), DateTime(2025, 9, 1, 10)), 12);
    expect(anchorStaleMonths(item({'priceCents': 1, 'purchasedOn': '2020-01-01'}), now), isNull);
  });

  test('1/2/3 年后的估值；已结束的不预估', () {
    final phone = item({'category': 'digital', 'priceCents': 599900, 'purchasedOn': '2026-09-01'});
    final forecast = valueForecast(phone, now);
    expect(forecast, hasLength(3));
    expect(forecast[0], closeTo(442191, 1));
    expect(forecast[1], closeTo(331643, 1));
    expect(forecast[2], closeTo(248732, 1));
    final sold = item({
      'category': 'digital', 'priceCents': 599900, 'purchasedOn': '2026-01-01',
      'status': 'sold', 'endedOn': '2026-09-10',
    });
    expect(valueForecast(sold, now), isEmpty);
  });

  test('预设：按类别挑、键不重复、参数在服务端允许的范围里', () {
    expect(presetsFor('digital').map((p) => p.key), ['apple', 'android_pc', 'lens']);
    expect(presetsFor('furniture'), isEmpty);
    expect(kValuationPresets.map((p) => p.key).toSet(), hasLength(kValuationPresets.length));
    for (final p in kValuationPresets) {
      expect(p.categories.every(Asset.categories.contains), isTrue, reason: p.key);
      expect(p.rateBp == null || (p.rateBp! >= 0 && p.rateBp! <= 9000), isTrue, reason: p.key);
      expect(p.residualBp == null || (p.residualBp! >= 0 && p.residualBp! <= 10000), isTrue, reason: p.key);
    }
    expect(presetByKey('keep_value')!.method, Asset.methodLocked);
    expect(presetByKey('nope'), isNull);
  });

  test('计入净资产那一行、估值不确定、百分数文字', () {
    expect(netWorthLabel(item({'category': 'digital', 'priceCents': 1, 'purchasedOn': '2026-09-01'})), '计入（跟随类别）');
    expect(netWorthLabel(item({'category': 'appliance', 'priceCents': 1, 'purchasedOn': '2026-09-01'})), '不计入（跟随类别）');
    expect(netWorthLabel(item({'category': 'appliance', 'priceCents': 1, 'purchasedOn': '2026-09-01', 'netWorth': 'include'})), '计入');
    expect(netWorthLabel(item({'category': 'digital', 'priceCents': 1, 'purchasedOn': '2026-09-01', 'netWorth': 'exclude'})), '不计入');
    // 总开关关着：本该计入的写「暂不计入」，本来就不计入的照旧。
    expect(
      netWorthLabel(item({'category': 'digital', 'priceCents': 1, 'purchasedOn': '2026-09-01'}), switchOn: false),
      '暂不计入（总开关已关）',
    );
    expect(
      netWorthLabel(item({'category': 'appliance', 'priceCents': 1, 'purchasedOn': '2026-09-01', 'netWorth': 'include'}), switchOn: false),
      '暂不计入（总开关已关）',
    );
    expect(
      netWorthLabel(item({'category': 'appliance', 'priceCents': 1, 'purchasedOn': '2026-09-01'}), switchOn: false),
      '不计入（跟随类别）',
    );
    expect(valuationUncertain(item({'category': 'luxury', 'priceCents': 1, 'purchasedOn': '2026-09-01'})), isTrue);
    expect(
      valuationUncertain(item({
        'category': 'luxury', 'priceCents': 1, 'purchasedOn': '2026-09-01',
        'manualValueCents': 1, 'manualValueOn': '2026-09-02',
      })),
      isFalse,
      reason: '手动估过就不算没谱了',
    );
    expect(valuationUncertain(item({'category': 'digital', 'priceCents': 1, 'purchasedOn': '2026-09-01'})), isFalse);
    expect([bpText(2500), bpText(1250), bpText(1205), bpText(0), bpText(10000)], ['25', '12.5', '12.05', '0', '100']);
  });
}
