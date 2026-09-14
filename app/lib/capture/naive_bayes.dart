import 'dart:math' as math;

import 'normalizer.dart';

/// 一条预测结果。
class Prediction {
  const Prediction(this.label, this.p);

  final String label;
  final double p;

  @override
  String toString() => 'Prediction($label, ${p.toStringAsFixed(4)})';
}

class _ClassStat {
  _ClassStat({this.docs = 0, this.tokens = 0, Map<String, int>? counts})
      : counts = counts ?? <String, int>{};

  int docs;
  int tokens;
  final Map<String, int> counts;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'docs': docs,
        'tokens': tokens,
        'counts': Map<String, int>.from(counts),
      };

  factory _ClassStat.fromJson(Map<String, dynamic> json) => _ClassStat(
        docs: (json['docs'] as num?)?.toInt() ?? 0,
        tokens: (json['tokens'] as num?)?.toInt() ?? 0,
        counts: <String, int>{
          for (final e in (json['counts'] as Map?)?.entries ??
              const <MapEntry<dynamic, dynamic>>[])
            e.key as String: (e.value as num).toInt(),
        },
      );
}

/// 多项式朴素贝叶斯（拉普拉斯平滑 α=1，log 域）。
///
/// 序列化格式必须与服务端 `server/src/lib/nb.js` 完全一致，双方才能合并计数：
/// `{version:int, classes:{[label]:{docs,tokens,counts}}, vocab:int, totalDocs:int}`
class NaiveBayes {
  NaiveBayes._(this.version, this._classes, this._totalDocs) {
    for (final stat in _classes.values) {
      _vocabulary.addAll(stat.counts.keys);
    }
  }

  NaiveBayes.empty() : this._(0, <String, _ClassStat>{}, 0);

  factory NaiveBayes.fromJson(Map<String, dynamic> json) {
    final classes = <String, _ClassStat>{};
    final raw = json['classes'];
    if (raw is Map) {
      for (final entry in raw.entries) {
        classes[entry.key as String] =
            _ClassStat.fromJson((entry.value as Map).cast<String, dynamic>());
      }
    }
    return NaiveBayes._(
      (json['version'] as num?)?.toInt() ?? 0,
      classes,
      (json['totalDocs'] as num?)?.toInt() ?? 0,
    );
  }

  static const double alpha = 1.0;

  /// 服务端 `/model` 端点维护的版本号。本地 `learn` **不动它**：服务端是
  /// 「每次请求 +1」，本地是「每条样本一次」，自增会让两边永远对不上。
  /// 拉到 `GET /model` 或 `POST /model/learn` 的响应后由同步层写回。
  int version;
  int _totalDocs;
  int _dirtyCount = 0;
  final Map<String, _ClassStat> _classes;
  final Set<String> _vocabulary = <String>{};

  /// 本地学了多少条还没推给服务端（不进共享 JSON）。
  int get dirtyCount => _dirtyCount;
  void clearDirty() => _dirtyCount = 0;

  int get totalDocs => _totalDocs;
  int get vocab => _vocabulary.length;
  int get classCount => _classes.length;
  bool get isEmpty => _totalDocs == 0 || _classes.isEmpty;
  bool hasLabel(String label) => _classes.containsKey(label);

  /// 后验值不值得信。
  ///
  /// **只有一个类别的模型是个常量分类器**：不管输入是什么，softmax 之后那唯一
  /// 一类永远是 p=1.0。真机上用户第一次快捷回复改了基金，基金模型就变成单类，
  /// 之后每一笔都被「满信」塞进那个基金。样本太少时后验同样只是噪声。
  ///
  /// 这是**调用方的策略**，故意不写进 [predict]：predict 必须与服务端
  /// `nb.js` 逐位一致（见 `test/capture/nb_golden_test.dart`）。
  static const int minReliableClasses = 2;
  static const int minReliableDocs = 3;

  bool get isReliable =>
      _classes.length >= minReliableClasses && _totalDocs >= minReliableDocs;

  /// 字符 1-gram + 2-gram，[extras] 原样追加在末尾。
  static List<String> tokenize(String text, [List<String> extras = const []]) {
    final cleaned = TextNormalizer.tokenText(text);
    final chars = cleaned.runes.map(String.fromCharCode).toList();
    final tokens = <String>[...chars];
    for (var i = 0; i + 1 < chars.length; i++) {
      tokens.add('${chars[i]}${chars[i + 1]}');
    }
    tokens.addAll(extras);
    return tokens;
  }

  void learn(List<String> tokens, String label) {
    if (tokens.isEmpty) return;
    final stat = _classes.putIfAbsent(label, () => _ClassStat());
    stat.docs += 1;
    stat.tokens += tokens.length;
    for (final token in tokens) {
      stat.counts[token] = (stat.counts[token] ?? 0) + 1;
      _vocabulary.add(token);
    }
    _totalDocs += 1;
    _dirtyCount += 1;
  }

  /// 后验概率降序；空模型返回空列表。
  ///
  /// 只对模型见过的 token 计分：通知正文里绝大多数字符从没出现在训练样本里，
  /// 若一并计入，得分就退化成「谁的 token 总数少谁赢」（长文本偏置），
  /// 实测会把「商户：麦当劳」判成「转账收入」。
  List<Prediction> predict(List<String> allTokens) {
    if (isEmpty) return const <Prediction>[];
    final tokens = allTokens.where(_vocabulary.contains).toList();
    final v = _vocabulary.length;
    final scores = <String, double>{};
    for (final entry in _classes.entries) {
      final stat = entry.value;
      // 与 nb.js 相同的两个退化保护：merge 进来的畸形模型可能出现
      // docs=0 或 tokens+vocab=0，少一个两端就会对不上。
      var score = math.log(math.max(stat.docs, 1) / _totalDocs);
      final denom = math.max(1.0, stat.tokens + alpha * v);
      for (final token in tokens) {
        final count = stat.counts[token] ?? 0;
        score += math.log((count + alpha) / denom);
      }
      scores[entry.key] = score;
    }
    // softmax（减最大值防溢出）
    final maxScore = scores.values.reduce(math.max);
    var sum = 0.0;
    final exps = <String, double>{};
    for (final entry in scores.entries) {
      final e = math.exp(entry.value - maxScore);
      exps[entry.key] = e;
      sum += e;
    }
    final out = <Prediction>[
      for (final entry in exps.entries)
        Prediction(entry.key, sum == 0 ? 0.0 : entry.value / sum),
    ];
    out.sort((a, b) {
      final byP = b.p.compareTo(a.p);
      return byP != 0 ? byP : a.label.compareTo(b.label);
    });
    return out;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': version,
        'classes': <String, dynamic>{
          for (final e in _classes.entries) e.key: e.value.toJson(),
        },
        'vocab': _vocabulary.length,
        'totalDocs': _totalDocs,
      };
}
