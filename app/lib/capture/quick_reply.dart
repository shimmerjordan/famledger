import 'classifier.dart';
import 'normalizer.dart';

/// 快捷回复解析出的修改项，字段为 null 表示「这次不改」。
class QuickReplyPatch {
  const QuickReplyPatch({
    this.fundId,
    this.categoryId,
    this.note,
    this.amountCents,
    this.type,
  });

  final String? fundId;
  final String? categoryId;
  final String? note;
  final int? amountCents;

  /// expense|income|transfer
  final String? type;

  bool get isEmpty =>
      fundId == null &&
      categoryId == null &&
      note == null &&
      amountCents == null &&
      type == null;

  /// 可直接作为 `PATCH /transactions/:id` 的请求体片段。
  Map<String, dynamic> toJson() => <String, dynamic>{
        if (fundId != null) 'fundId': fundId,
        if (categoryId != null) 'categoryId': categoryId,
        if (note != null) 'note': note,
        if (amountCents != null) 'amountCents': amountCents,
        if (type != null) 'type': type,
      };
}

/// 通知 RemoteInput 的文本 → 修改项。
///
/// **按分段判定**：先按空白与标点切成若干段，再逐段认领 ——
/// 纯数字段（可带 `¥` 前缀或「元/块」后缀）是金额，命中基金名/别名的是基金，
/// 命中类别名/别名的是类别，「收入/支出/转账」是方向，剩下的拼成备注。
///
/// 分段是关键：整句扫描会把「给猫买2袋粮」改成 2 元、「9月12日的午饭」改成 9 元，
/// 而快捷回复改完就直接 `status:'confirmed'` 落库，错了没人拦。
/// 基金先于类别，这样「宠物」优先理解成「宠物基金」（spec §6 的例子）。
class QuickReplyInterpreter {
  const QuickReplyInterpreter();

  /// 切段：先认「带千分位的数字」（`1,299` 不能被逗号切开），再认普通段。
  static final RegExp _segmentRe = RegExp(
    r'¥?\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?(?:元|块)?|[^\s,，、;；/|:]+',
  );

  /// 一整段就是金额：可选 `¥`、千分位、两位小数、可选「元/块」。
  static final RegExp _amountSegmentRe = RegExp(
    r'^¥?\s*(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d{1,2}))?\s*(?:元|块)?$',
  );

  /// 被空格拆出去的单位段（「88 元」）。
  static const Set<String> _unitOnly = <String>{'元', '块', '元整'};

  static final Map<String, RegExp> _directionRe = <String, RegExp>{
    'income': RegExp(r'收入|入账|进账|收到|收款'),
    'expense': RegExp(r'支出|花了|花掉|消费|付款'),
    'transfer': RegExp(r'转账|转出|还款'),
  };

  QuickReplyPatch interpret(
    String text, {
    required List<ClassifierCandidate> funds,
    required List<ClassifierCandidate> categories,
  }) {
    final segments = _segmentRe
        .allMatches(TextNormalizer.normalize(text))
        .map((m) => m.group(0)!)
        .toList();
    if (segments.isEmpty) return const QuickReplyPatch();

    int? amountCents;
    String? type;
    String? fundId;
    String? categoryId;
    final note = <String>[];

    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];

      if (amountCents == null) {
        final cents = _amountOf(segment);
        if (cents != null) {
          amountCents = cents;
          if (i + 1 < segments.length && _unitOnly.contains(segments[i + 1])) {
            i++; // 「88 元」
          }
          continue;
        }
      }
      if (type == null) {
        final direction = _directionOf(segment);
        if (direction != null) {
          type = direction;
          continue;
        }
      }
      if (fundId == null) {
        final id = _matchCandidate(segment, funds);
        if (id != null) {
          fundId = id;
          continue;
        }
      }
      if (categoryId == null) {
        final id = _matchCandidate(segment, categories);
        if (id != null) {
          categoryId = id;
          continue;
        }
      }
      note.add(segment);
    }

    return QuickReplyPatch(
      fundId: fundId,
      categoryId: categoryId,
      amountCents: amountCents,
      type: type,
      note: note.isEmpty ? null : note.join(' '),
    );
  }

  int? _amountOf(String segment) {
    final m = _amountSegmentRe.firstMatch(segment);
    if (m == null) return null;
    final frac = m.group(2);
    final cents = int.parse(m.group(1)!.replaceAll(',', '')) * 100 +
        (frac == null
            ? 0
            : frac.length == 1
                ? int.parse(frac) * 10
                : int.parse(frac));
    return cents > 0 ? cents : null;
  }

  String? _directionOf(String segment) {
    for (final entry in _directionRe.entries) {
      if (entry.value.hasMatch(segment)) return entry.key;
    }
    return null;
  }

  /// 段与候选项的匹配：整段相等 → 段里包含候选名 → 候选名以整段开头
  /// （「宠物」→「宠物基金」）。同时命中多个时取最长的名字。
  String? _matchCandidate(String segment, List<ClassifierCandidate> candidates) {
    String? best;
    var bestLength = 0;
    for (final candidate in candidates) {
      for (final name in candidate.allNames) {
        final hit = name == segment ||
            (name.length >= 2 && segment.contains(name)) ||
            (segment.length >= 2 && name.startsWith(segment));
        if (hit && name.length > bestLength) {
          best = candidate.id;
          bestLength = name.length;
        }
      }
    }
    return best;
  }
}
