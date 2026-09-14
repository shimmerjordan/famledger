import 'dart:convert';
import 'dart:io';

import 'package:famledger/capture/naive_bayes.dart';
import 'package:flutter_test/flutter_test.dart';

/// 跨语言黄金样本：`server/scripts/gen-nb-golden.js` 生成，Dart 与 Node 的
/// 分词与打分必须逐项一致（tokens 完全相等，p 误差 ≤ 1e-6）。
/// 路径相对 `app/`（`flutter test` 的工作目录）。
const String _goldenPath = '../server/test/fixtures/nb_golden.json';

void main() {
  final file = File(_goldenPath);
  if (!file.existsSync()) {
    test('黄金样本缺失', () {
      fail('找不到 $_goldenPath（由 server/scripts/gen-nb-golden.js 生成）');
    });
    return;
  }
  final golden = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final extras = (golden['extras'] as List).cast<String>();
  final strings = (golden['strings'] as List).cast<String>();
  final tokens = (golden['tokens'] as List)
      .map((e) => (e as List).cast<String>())
      .toList();
  final predictions = (golden['predictions'] as List)
      .map((e) => (e as List).cast<dynamic>())
      .toList();

  NaiveBayes trained() {
    final model = NaiveBayes.empty();
    for (final raw in (golden['training'] as List)) {
      final sample = (raw as Map).cast<String, dynamic>();
      model.learn(
          NaiveBayes.tokenize(sample['text'] as String), sample['label'] as String);
    }
    return model;
  }

  test('训练出的模型计数与服务端一致', () {
    final model = trained().toJson();
    final expected = (golden['model'] as Map).cast<String, dynamic>();
    // notes：version 不属于跨语言契约，只比 classes / vocab / totalDocs。
    expect(model['totalDocs'], expected['totalDocs']);
    expect(model['vocab'], expected['vocab']);
    expect(jsonDecode(jsonEncode(model['classes'])), expected['classes']);
  });

  group('tokenize 与服务端逐项相等', () {
    for (var i = 0; i < strings.length; i++) {
      test('#$i ${jsonEncode(strings[i])}', () {
        expect(NaiveBayes.tokenize(strings[i], extras), tokens[i]);
      });
    }
  });

  group('predict 与服务端一致（p 误差 ≤ 1e-6）', () {
    final model = trained();
    for (var i = 0; i < strings.length; i++) {
      test('#$i ${jsonEncode(strings[i])}', () {
        final actual = model.predict(NaiveBayes.tokenize(strings[i], extras));
        final expected = predictions[i];
        expect(actual.length, expected.length);
        for (var k = 0; k < expected.length; k++) {
          final row = (expected[k] as Map).cast<String, dynamic>();
          expect(actual[k].label, row['label'], reason: '#$i 第 $k 位标签');
          expect(actual[k].p, closeTo((row['p'] as num).toDouble(), 1e-6),
              reason: '#$i 第 $k 位概率');
        }
      });
    }
  });
}
