import 'dart:convert';
import 'dart:io';

import 'package:famledger/data/models/models.dart';
import 'package:famledger/ui/assets/asset_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 服务端的类别名单就是估值默认表的键（server/src/lib/valuation.js），向量文件里存着一份。
/// 路径相对 `app/`（flutter test 的工作目录）。
const String _goldenPath = '../server/test/fixtures/valuation_golden.json';

void main() {
  test('类别名单与服务端同名同序；每个都有中文名和图标（新增的是购物袋、钻石）', () {
    final golden = jsonDecode(File(_goldenPath).readAsStringSync()) as Map<String, dynamic>;
    expect(Asset.categories, (golden['categories'] as Map).keys.toList());
    for (final c in Asset.categories) {
      expect(Asset.categoryLabels[c], isNotNull, reason: c);
      expect(kAssetCategoryIcons[c], isNotNull, reason: c);
    }
    expect(Asset.categoryLabels['luxury'], '箱包/奢侈品');
    expect(Asset.categoryLabels['jewelry'], '首饰/贵金属');
    expect(kAssetCategoryIcons['luxury'], Icons.shopping_bag_outlined);
    expect(kAssetCategoryIcons['jewelry'], Icons.diamond_outlined);
  });

  group('Asset 估值字段', () {
    const base = {
      'id': 'a1',
      'name': 'iPhone',
      'category': 'digital',
      'priceCents': 599900,
      'purchasedOn': '2026-09-01',
    };

    test('缺字段（005 之前的行、老缓存）按 auto 兜底，参数为 null', () {
      final a = Asset.fromJson(base);
      expect(a.valuationMethod, Asset.methodAuto);
      expect(a.netWorth, Asset.netWorthAuto);
      expect(a.rateBp, isNull);
      expect(a.residualBp, isNull);
      expect(a.manualValueCents, isNull);
      expect(a.manualValueOn, isNull);
    });

    test('不认识的方式 / 三态值（以后的版本写的）也按 auto', () {
      final a = Asset.fromJson({...base, 'valuationMethod': 'grant', 'netWorth': 'maybe'});
      expect(a.valuationMethod, Asset.methodAuto);
      expect(a.netWorth, Asset.netWorthAuto);
    });

    test('toJson 往返：六个估值字段都在（本地缓存靠它）', () {
      final json = {
        ...base,
        'status': 'in_use',
        'sortOrder': 0,
        'archived': false,
        'valuationMethod': 'declining',
        'rateBp': 2000,
        'residualBp': 1000,
        'manualValueCents': 450000,
        'manualValueOn': '2026-09-10',
        'netWorth': 'exclude',
      };
      expect(Asset.fromJson(json).toJson(), json);
    });
  });
}
