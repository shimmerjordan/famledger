import 'package:famledger/capture/accuracy_stats.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('accuracySourceOfReason', () {
    test('ai 优先于 nb 优先于 rule', () {
      expect(accuracySourceOfReason('ai'), AccuracySource.ai);
      expect(accuracySourceOfReason('nb'), AccuracySource.nb);
      expect(accuracySourceOfReason('rule:r1'), AccuracySource.rule);
      expect(accuracySourceOfReason('rule:r1+nb'), AccuracySource.nb);
      expect(accuracySourceOfReason('default'), AccuracySource.fallback);
    });
  });

  group('AccuracyStats', () {
    test('样本不足 minSamples 时命中率是 null', () {
      final stats = AccuracyStats.empty();
      for (var i = 0; i < 19; i++) {
        stats.record(AccuracySource.nb, hit: true);
      }
      expect(stats.sampleCountOf(AccuracySource.nb), 19);
      expect(stats.hitRateOf(AccuracySource.nb), isNull);
      expect(stats.nbIsTrusted, isFalse);
    });

    test('样本够了就能算命中率', () {
      final stats = AccuracyStats.empty();
      for (var i = 0; i < 17; i++) {
        stats.record(AccuracySource.nb, hit: true);
      }
      for (var i = 0; i < 3; i++) {
        stats.record(AccuracySource.nb, hit: false);
      }
      expect(stats.sampleCountOf(AccuracySource.nb), 20);
      expect(stats.hitRateOf(AccuracySource.nb), closeTo(0.85, 1e-9));
      expect(stats.nbIsTrusted, isTrue);
    });

    test('命中率低于 trustedThreshold 就不可信', () {
      final stats = AccuracyStats.empty();
      for (var i = 0; i < 15; i++) {
        stats.record(AccuracySource.nb, hit: true);
      }
      for (var i = 0; i < 10; i++) {
        stats.record(AccuracySource.nb, hit: false);
      }
      expect(stats.hitRateOf(AccuracySource.nb), closeTo(0.6, 1e-9));
      expect(stats.nbIsTrusted, isFalse);
    });

    test('滚动窗口：超过 windowSize 就把最早的挤出去', () {
      final stats = AccuracyStats.empty();
      // 先来 200 条全命中，再来 50 条全不中——按窗口大小 200，
      // 最早的 50 条命中会被挤掉，命中率应该是 150/200 = 0.75。
      for (var i = 0; i < AccuracyStats.windowSize; i++) {
        stats.record(AccuracySource.ai, hit: true);
      }
      for (var i = 0; i < 50; i++) {
        stats.record(AccuracySource.ai, hit: false);
      }
      expect(stats.sampleCountOf(AccuracySource.ai), AccuracyStats.windowSize);
      expect(stats.hitRateOf(AccuracySource.ai), closeTo(0.75, 1e-9));
    });

    test('各来源互不影响', () {
      final stats = AccuracyStats.empty();
      for (var i = 0; i < 20; i++) {
        stats.record(AccuracySource.nb, hit: true);
        stats.record(AccuracySource.ai, hit: false);
      }
      expect(stats.hitRateOf(AccuracySource.nb), 1.0);
      expect(stats.hitRateOf(AccuracySource.ai), 0.0);
      expect(stats.hitRateOf(AccuracySource.rule), isNull);
      expect(stats.hitRateOf(AccuracySource.fallback), isNull);
    });

    test('往返：toJson/fromJson 保留每个来源的窗口', () {
      final stats = AccuracyStats.empty();
      for (var i = 0; i < 25; i++) {
        stats.record(AccuracySource.rule, hit: i % 5 != 0); // 20/25 命中
      }
      final restored = AccuracyStats.fromJson(stats.toJson());
      expect(restored.sampleCountOf(AccuracySource.rule), 25);
      expect(restored.hitRateOf(AccuracySource.rule), closeTo(0.8, 1e-9));
    });

    test('fromJson 对空/畸形输入宽容：缺字段、非 List 都当没有样本', () {
      final stats = AccuracyStats.fromJson(const {'nb': 'not-a-list', 'ai': null});
      expect(stats.sampleCountOf(AccuracySource.nb), 0);
      expect(stats.sampleCountOf(AccuracySource.ai), 0);
      expect(stats.sampleCountOf(AccuracySource.rule), 0);
    });

    test('fromJson 读到超长窗口也会裁到 windowSize（防止外部/旧数据把内存吃大）', () {
      final longList = List<bool>.filled(AccuracyStats.windowSize + 30, true);
      final stats = AccuracyStats.fromJson({'nb': longList});
      expect(stats.sampleCountOf(AccuracySource.nb), AccuracyStats.windowSize);
    });
  });
}
