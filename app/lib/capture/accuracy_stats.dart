/// 「最近这个来源准不准」的本地滚动统计，只用来回答两个问题：
/// 设置页那个只读小面板要显示什么、以及「自动」模式下要不要为了省一次
/// AI 调用而跳过兜底。刻意不做任何机器学习，只数最近命中了多少次。
library;

/// 一条分类结果最终是从哪儿来的。
enum AccuracySource {
  /// 命中了一条用户自己写的规则。
  rule,

  /// 本地朴素贝叶斯给的。
  nb,

  /// AI 兜底给的（含手动触发的复核）。
  ai,

  /// 什么都没命中，落到默认基金/不分类。
  fallback,
}

/// [ClassifyResult.reason] → [AccuracySource]。
///
/// `reason`可能是 `rule:xxx`、`nb`、`rule:xxx+nb`（规则只定了账户，类别仍
/// 来自 NB）、`ai`、或 `default`。归类时 ai 优先于 nb 优先于 rule ——
/// 这反映的是「这一次类别/基金的判断到底信了谁」，不是「有没有任何规则命中」。
AccuracySource accuracySourceOfReason(String reason) {
  if (reason.contains('ai')) return AccuracySource.ai;
  if (reason.contains('nb')) return AccuracySource.nb;
  if (reason.startsWith('rule:')) return AccuracySource.rule;
  return AccuracySource.fallback;
}

/// 每个来源最近 [AccuracyStats.windowSize] 次的命中/未命中。
///
/// 存储沿用 [CaptureStore.loadModel]/[saveModel] 那一套（跟朴素贝叶斯模型
/// 同一个机制），key 见 `kAccuracyModelKey`。
class AccuracyStats {
  AccuracyStats._(this._windows);

  factory AccuracyStats.empty() => AccuracyStats._({
        for (final s in AccuracySource.values) s: <bool>[],
      });

  /// 每个来源只留最近这么多条，早的先出（环形窗口）。
  static const int windowSize = 200;

  /// 样本数够这个数，命中率才算数——否则「3 次 3 中」也敢说 100%，没意义。
  static const int minSamples = 20;

  /// 「自动」模式下，本地模型命中率到这个数就不必再叫醒 AI 了。
  static const double trustedThreshold = 0.85;

  final Map<AccuracySource, List<bool>> _windows;

  /// 记一次样本：[hit] = 用户没纠正 / 明确说了「正确」。
  void record(AccuracySource source, {required bool hit}) {
    final list = _windows[source]!;
    list.add(hit);
    if (list.length > windowSize) list.removeAt(0);
  }

  int sampleCountOf(AccuracySource source) => _windows[source]!.length;

  /// 样本不足 [minSamples] 时返回 null——数字还不可信，别拿去做判断，
  /// 也别在界面上唬人地显示一个「100%」。
  double? hitRateOf(AccuracySource source) {
    final list = _windows[source]!;
    if (list.length < minSamples) return null;
    final hits = list.where((h) => h).length;
    return hits / list.length;
  }

  /// 本地朴素贝叶斯最近够不够可信——够的话「自动」模式可以省一次 AI 调用。
  bool get nbIsTrusted => (hitRateOf(AccuracySource.nb) ?? 0) >= trustedThreshold;

  factory AccuracyStats.fromJson(Map<String, dynamic> json) {
    final windows = <AccuracySource, List<bool>>{
      for (final s in AccuracySource.values) s: <bool>[],
    };
    for (final s in AccuracySource.values) {
      final raw = json[s.name];
      if (raw is List) {
        final list = raw.map((e) => e == true).toList();
        windows[s] = list.length > windowSize
            ? list.sublist(list.length - windowSize)
            : list;
      }
    }
    return AccuracyStats._(windows);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        for (final e in _windows.entries) e.key.name: e.value,
      };
}
