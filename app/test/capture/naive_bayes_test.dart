import 'dart:convert';

import 'package:famledger/capture/naive_bayes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('tokenize', () {
    test('字符 1-gram + 2-gram，顺序稳定', () {
      expect(NaiveBayes.tokenize('美团'), <String>['美', '团', '美团']);
      expect(
        NaiveBayes.tokenize('美团外卖'),
        <String>['美', '团', '外', '卖', '美团', '团外', '外卖'],
      );
    });

    test('单字只有 1-gram', () {
      expect(NaiveBayes.tokenize('猫'), <String>['猫']);
    });

    test('去空白标点、全角转半角、小写', () {
      expect(NaiveBayes.tokenize('A B！'), <String>['a', 'b', 'ab']);
      expect(NaiveBayes.tokenize('ＡＢ'), <String>['a', 'b', 'ab']);
    });

    test('extras 原样追加在最后', () {
      final tokens = NaiveBayes.tokenize('美团', const <String>[
        'm:美团',
        'dir:expense',
        'ch:alipay',
        'amt:b1',
        'h:12',
        'wd:5',
      ]);
      expect(tokens.sublist(0, 3), <String>['美', '团', '美团']);
      expect(tokens.sublist(3), <String>[
        'm:美团',
        'dir:expense',
        'ch:alipay',
        'amt:b1',
        'h:12',
        'wd:5',
      ]);
    });

    test('空文本只留 extras', () {
      expect(NaiveBayes.tokenize('  ', const <String>['dir:income']),
          <String>['dir:income']);
    });
  });

  group('learn / predict', () {
    test('空模型 predict 返回空列表', () {
      final nb = NaiveBayes.empty();
      expect(nb.predict(NaiveBayes.tokenize('美团外卖')), isEmpty);
      expect(nb.totalDocs, 0);
    });

    test('学习 5 条样本后 predict 命中正确类别', () {
      final nb = NaiveBayes.empty();
      nb.learn(NaiveBayes.tokenize('美团外卖'), '餐饮');
      nb.learn(NaiveBayes.tokenize('肯德基'), '餐饮');
      nb.learn(NaiveBayes.tokenize('星巴克咖啡'), '餐饮');
      nb.learn(NaiveBayes.tokenize('滴滴出行'), '交通');
      nb.learn(NaiveBayes.tokenize('地铁乘车码'), '交通');

      final food = nb.predict(NaiveBayes.tokenize('美团外卖订单'));
      expect(food.first.label, '餐饮');
      final ride = nb.predict(NaiveBayes.tokenize('滴滴快车'));
      expect(ride.first.label, '交通');
      expect(nb.totalDocs, 5);
    });

    test('概率降序排列且归一化到 1', () {
      final nb = NaiveBayes.empty();
      nb.learn(NaiveBayes.tokenize('美团外卖'), '餐饮');
      nb.learn(NaiveBayes.tokenize('滴滴出行'), '交通');
      nb.learn(NaiveBayes.tokenize('国家电网电费'), '水电');

      final preds = nb.predict(NaiveBayes.tokenize('美团'));
      expect(preds.length, 3);
      for (var i = 1; i < preds.length; i++) {
        expect(preds[i - 1].p, greaterThanOrEqualTo(preds[i].p));
      }
      final sum = preds.fold<double>(0, (a, b) => a + b.p);
      expect(sum, closeTo(1.0, 1e-9));
      expect(preds.first.label, '餐饮');
      expect(preds.first.p, greaterThan(0.5));
    });

    test('extras 特征参与判别', () {
      final nb = NaiveBayes.empty();
      for (var i = 0; i < 3; i++) {
        nb.learn(NaiveBayes.tokenize('转账', const ['dir:income']), '转账收入');
        nb.learn(NaiveBayes.tokenize('转账', const ['dir:expense']), '人情');
      }
      final income =
          nb.predict(NaiveBayes.tokenize('转账', const ['dir:income']));
      expect(income.first.label, '转账收入');
    });

    test('未知 token 不会让某一类概率变成 NaN', () {
      final nb = NaiveBayes.empty();
      nb.learn(NaiveBayes.tokenize('美团外卖'), '餐饮');
      nb.learn(NaiveBayes.tokenize('滴滴出行'), '交通');
      final preds = nb.predict(NaiveBayes.tokenize('完全没见过的词'));
      for (final p in preds) {
        expect(p.p.isNaN, isFalse);
        expect(p.p, inInclusiveRange(0.0, 1.0));
      }
    });
  });

  group('序列化', () {
    test('JSON 结构与服务端 nb.js 一致', () {
      final nb = NaiveBayes.empty();
      nb.learn(<String>['美', '团', '美团'], '餐饮');
      final json = nb.toJson();

      expect(json.keys.toSet(),
          <String>{'version', 'classes', 'vocab', 'totalDocs'});
      expect(json['version'], isA<int>());
      expect(json['totalDocs'], 1);
      expect(json['vocab'], 3);
      final classes = json['classes'] as Map<String, dynamic>;
      final food = classes['餐饮'] as Map<String, dynamic>;
      expect(food.keys.toSet(), <String>{'docs', 'tokens', 'counts'});
      expect(food['docs'], 1);
      expect(food['tokens'], 3);
      expect((food['counts'] as Map)['美团'], 1);
      // 可直接 jsonEncode，不含非法类型
      expect(() => jsonEncode(json), returnsNormally);
    });

    test('往返序列化后预测结果一致', () {
      final nb = NaiveBayes.empty();
      nb.learn(NaiveBayes.tokenize('美团外卖'), '餐饮');
      nb.learn(NaiveBayes.tokenize('滴滴出行'), '交通');
      nb.learn(NaiveBayes.tokenize('美团打车'), '交通');

      final restored = NaiveBayes.fromJson(
          jsonDecode(jsonEncode(nb.toJson())) as Map<String, dynamic>);
      expect(restored.toJson(), nb.toJson());

      final a = nb.predict(NaiveBayes.tokenize('美团外卖'));
      final b = restored.predict(NaiveBayes.tokenize('美团外卖'));
      expect(b.first.label, a.first.label);
      expect(b.first.p, closeTo(a.first.p, 1e-12));
    });

    test('version 镜像服务端：本地 learn 不动它，只涨 dirtyCount', () {
      // 服务端是「每次 /model/learn 请求 +1」，本地是「每条样本一次」，
      // 本地自增会让两边永远对不上，所以本地只记「有多少没同步」。
      final nb = NaiveBayes.fromJson(<String, dynamic>{
        'version': 7,
        'classes': <String, dynamic>{},
        'vocab': 0,
        'totalDocs': 0,
      });
      expect(nb.version, 7);
      expect(nb.dirtyCount, 0);

      nb.learn(NaiveBayes.tokenize('美团'), '餐饮');
      nb.learn(NaiveBayes.tokenize('肯德基'), '餐饮');
      expect(nb.version, 7);
      expect(nb.dirtyCount, 2);
      expect(nb.toJson()['version'], 7);

      nb.version = 9; // 同步层拿到服务端返回的新版本后写回
      nb.clearDirty();
      expect(nb.toJson()['version'], 9);
      expect(nb.dirtyCount, 0);
    });

    test('空样本不改动模型', () {
      final nb = NaiveBayes.empty();
      nb.learn(const <String>[], '餐饮');
      expect(nb.totalDocs, 0);
      expect(nb.dirtyCount, 0);
    });

    test('畸形模型（docs=0 / tokens=0）不会算出 NaN 或 -Infinity', () {
      // 与 nb.js 的两个退化保护对齐：prior 用 max(docs,1)，分母用 max(1,…)
      final nb = NaiveBayes.fromJson(<String, dynamic>{
        'version': 1,
        'classes': <String, dynamic>{
          'a': <String, dynamic>{'docs': 0, 'tokens': 0, 'counts': <String, int>{}},
          'b': <String, dynamic>{'docs': 1, 'tokens': 1, 'counts': <String, int>{'x': 1}},
        },
        'vocab': 1,
        'totalDocs': 1,
      });
      final preds = nb.predict(const <String>['x']);
      expect(preds, hasLength(2));
      for (final p in preds) {
        expect(p.p.isNaN, isFalse);
        expect(p.p.isFinite, isTrue);
      }
      // 两边得分都是 0（max(docs,1) 与 max(1,tokens+vocab) 各自抵消），
      // 并列时按 label 升序 —— 与 nb.js 的 tie-break 一致。
      expect(preds.map((e) => e.label), <String>['a', 'b']);
      expect(preds.first.p, closeTo(0.5, 1e-12));
    });

    test('fromJson 容错：缺字段按空模型处理', () {
      final nb = NaiveBayes.fromJson(const <String, dynamic>{});
      expect(nb.totalDocs, 0);
      expect(nb.predict(const <String>['x']), isEmpty);
    });

    test('重复 token 按多项式计数累加', () {
      final nb = NaiveBayes.empty();
      nb.learn(const <String>['猫', '猫', '猫'], '宠物');
      final counts = (nb.toJson()['classes'] as Map)['宠物'] as Map;
      expect((counts['counts'] as Map)['猫'], 3);
      expect(counts['tokens'], 3);
      expect(nb.toJson()['vocab'], 1);
    });
  });
}
