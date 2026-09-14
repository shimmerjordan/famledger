import 'dart:math' as math;

import 'capture_types.dart';
import 'naive_bayes.dart';
import 'parser.dart';
import 'seed_dataset.dart';

/// 模型还太薄（单类 / 样本不足）却又必须给个答案时，置信度的上限。
/// 低于默认阈值 0.75 → 一定进待确认，由用户来教。
const double kThinModelConfidenceCap = 0.5;

/// 可被分类到的候选项（类别或基金）。
class ClassifierCandidate {
  const ClassifierCandidate({
    required this.id,
    required this.name,
    this.aliases = const <String>[],
  });

  final String id;
  final String name;
  final List<String> aliases;

  /// 名称 + 别名，长的排前面，匹配时先长后短。
  List<String> get allNames =>
      <String>[name, ...aliases].where((s) => s.isNotEmpty).toList()
        ..sort((a, b) => b.length.compareTo(a.length));
}

/// 一条样本的「非文本特征」。
///
/// 本地把它展开成 extras 喂给 [NaiveBayes]，同步时把**原始字段**发给
/// `POST /model/learn`（服务端用 `nb.extrasFor` 自己再展开一遍）。
/// 两边的取舍规则必须完全一致：`m:`/`dir:`/`ch:`/`mem:` 只在有值时出现，
/// `amt:` 只在金额非空时出现，`h:`/`wd:` 恒有 —— 与 `server/src/lib/nb.js`
/// 的 `extrasFor` 逐行对应（空串或 unknown 都不发，服务端就不会造出 `ch:`）。
class CaptureFeatures {
  const CaptureFeatures({
    this.merchant = '',
    this.direction = '',
    this.channel = '',
    this.amountCents,
    required this.hour,
    required this.weekday,
    this.memberId = '',
  });

  factory CaptureFeatures.of(ClassifyInput input) {
    final p = input.payment;
    return CaptureFeatures(
      merchant: p.merchant,
      // unknown 不是一个特征，发出去只会变成一个谁都有的噪声 token。
      direction:
          p.direction == PayDirection.unknown ? '' : p.direction.name,
      channel: p.channel == 'unknown' ? '' : p.channel,
      amountCents: p.amountCents,
      hour: p.occurredAt.hour,
      weekday: p.occurredAt.weekday,
      memberId: input.memberId ?? '',
    );
  }

  final String merchant;

  /// expense|income|transfer（unknown 与空串一样，不产生特征）
  final String direction;
  final String channel;
  final int? amountCents;
  final int hour;

  /// `DateTime.weekday`，1=周一 … 7=周日（服务端原样接收，不做换算）。
  final int weekday;
  final String memberId;

  List<String> get extras => <String>[
        if (merchant.isNotEmpty) 'm:$merchant',
        if (direction.isNotEmpty) 'dir:$direction',
        if (channel.isNotEmpty) 'ch:$channel',
        if (amountCents != null) 'amt:${Classifier.amountBucket(amountCents!)}',
        'h:$hour',
        'wd:$weekday',
        if (memberId.isNotEmpty) 'mem:$memberId',
      ];

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (merchant.isNotEmpty) 'merchant': merchant,
        if (direction.isNotEmpty) 'direction': direction,
        if (channel.isNotEmpty) 'channel': channel,
        if (amountCents != null) 'amountCents': amountCents,
        'hour': hour,
        'weekday': weekday,
        if (memberId.isNotEmpty) 'memberId': memberId,
      };

  factory CaptureFeatures.fromJson(Map<String, dynamic> json) =>
      CaptureFeatures(
        merchant: (json['merchant'] as String?) ?? '',
        direction: (json['direction'] as String?) ?? '',
        channel: (json['channel'] as String?) ?? '',
        amountCents: (json['amountCents'] as num?)?.toInt(),
        hour: (json['hour'] as num?)?.toInt() ?? 0,
        weekday: (json['weekday'] as num?)?.toInt() ?? 1,
        memberId: (json['memberId'] as String?) ?? '',
      );
}

class ClassifyInput {
  const ClassifyInput({
    required this.payment,
    required this.rawText,
    this.memberId,
  });

  final ParsedPayment payment;
  final String rawText;
  final String? memberId;
}

class ClassifyResult {
  const ClassifyResult({
    this.categoryId,
    this.fundId,
    this.accountId,
    required this.confidence,
    required this.reason,
  });

  final String? categoryId;
  final String? fundId;
  final String? accountId;
  final double confidence;

  /// `rule:<id>` | `nb` | `ai` | `default`
  final String reason;

  ClassifyResult copyWith({
    String? categoryId,
    String? fundId,
    String? accountId,
    double? confidence,
    String? reason,
  }) =>
      ClassifyResult(
        categoryId: categoryId ?? this.categoryId,
        fundId: fundId ?? this.fundId,
        accountId: accountId ?? this.accountId,
        confidence: confidence ?? this.confidence,
        reason: reason ?? this.reason,
      );
}

/// 规则 → 朴素贝叶斯 → 默认值。
class Classifier {
  Classifier({
    required this.categoryModel,
    required this.fundModel,
    required List<CaptureRule> rules,
    required this.categories,
    required this.funds,
    required this.accounts,
    this.defaultFundId,
    this.defaultAccountId,
  }) : rules = List<CaptureRule>.unmodifiable(
          <CaptureRule>[...rules]..sort((a, b) {
            final byPriority = b.priority.compareTo(a.priority);
            return byPriority != 0 ? byPriority : a.id.compareTo(b.id);
          }),
        );

  final NaiveBayes categoryModel;
  final NaiveBayes fundModel;

  /// 已按优先级降序排好。
  final List<CaptureRule> rules;
  final List<ClassifierCandidate> categories;
  final List<ClassifierCandidate> funds;
  final List<CaptureAccount> accounts;
  final String? defaultFundId;
  final String? defaultAccountId;

  /// NB 特征：商户、方向、渠道、金额桶、小时、星期、成员。
  static List<String> featureExtras(ClassifyInput input) =>
      CaptureFeatures.of(input).extras;

  /// b0 <10 元、b1 <50、b2 <200、b3 <1000、b4 ≥1000（与 `nb.js` 同一套阈值）。
  static String amountBucket(int amountCents) {
    final n = amountCents.abs();
    if (n < 1000) return 'b0';
    if (n < 5000) return 'b1';
    if (n < 20000) return 'b2';
    if (n < 100000) return 'b3';
    return 'b4';
  }

  ClassifyResult classify(ClassifyInput input) {
    String? categoryId;
    String? fundId;
    String? accountId;
    String? ruleId;

    for (final rule in rules) {
      if (!rule.matches(
        merchant: input.payment.merchant,
        text: input.rawText,
        app: input.payment.sourceApp,
      )) {
        continue;
      }
      ruleId ??= rule.id;
      categoryId ??= rule.categoryId;
      fundId ??= rule.fundId;
      accountId ??= rule.accountId;
    }

    final tokens = NaiveBayes.tokenize(modelText(input), featureExtras(input));
    // 逐字段置信度：规则给的字段是 1.0（用户自己写的），模型给的字段用后验，
    // 设置里的默认基金不是「猜的」也算 1.0。只有规则钉死了**类别**，
    // 整条才可能满信；规则只指定账户时，低置信的类别照样进待确认。
    var categoryConfidence = categoryId == null ? 0.0 : 1.0;
    var fundConfidence = 1.0;
    var usedModel = false;

    // 薄模型（单类 / 样本不足）的后验没有意义，宁可不分类让用户来确认，
    // 也不能让一个常量分类器把每一笔都「满信」塞进同一个类别/基金。
    if (categoryId == null && categoryModel.isReliable) {
      final preds = categoryModel.predict(tokens);
      if (preds.isNotEmpty) {
        categoryId = preds.first.label;
        categoryConfidence = preds.first.p;
        usedModel = true;
      }
    }
    if (fundId == null) {
      if (fundModel.isReliable) {
        final preds = fundModel.predict(tokens);
        if (preds.isNotEmpty) {
          fundId = preds.first.label;
          fundConfidence = preds.first.p;
          usedModel = true;
        } else {
          fundId = defaultFundId;
        }
      } else {
        fundId = defaultFundId;
        if (_thinModelWouldDisagree(fundModel, defaultFundId)) {
          fundConfidence = math.min(fundConfidence, kThinModelConfidenceCap);
        }
      }
    }
    // 账户选错不影响「这笔记得对不对」，不进 min。
    accountId ??= _matchAccount(input) ?? defaultAccountId;

    final confidence = <double>[
      input.payment.parseConfidence,
      categoryConfidence,
      fundConfidence,
    ].reduce(math.min);

    final reasons = <String>[
      if (ruleId != null) 'rule:$ruleId',
      if (usedModel) 'nb',
    ];

    return ClassifyResult(
      categoryId: categoryId,
      fundId: fundId,
      accountId: accountId,
      confidence: (confidence * 1000).round() / 1000,
      reason: reasons.isEmpty ? 'default' : reasons.join('+'),
    );
  }

  /// 薄模型是否「指着另一个地方」。
  ///
  /// 空模型不算：那只是「还没学过」，退回设置里的默认基金是天经地义的，
  /// 不该因此把每一笔都打成待确认。只有一个类别、而且那个类别恰好就是默认
  /// 基金时同理 —— 结果反正一样，没什么可问用户的（单基金家庭就是这种）。
  /// 剩下的情况（学过别的基金、或几条样本分散在多个类）才压低置信度。
  static bool _thinModelWouldDisagree(NaiveBayes model, String? fallbackId) {
    if (model.isEmpty) return false;
    if (model.classCount == 1 &&
        fallbackId != null &&
        model.hasLabel(fallbackId)) {
      return false;
    }
    return true;
  }

  /// 卡尾号 → 文本关键词 → 来源包名（由具体到笼统）。
  String? _matchAccount(ClassifyInput input) {
    final tail = input.payment.cardTail;
    if (tail != null) {
      for (final a in accounts) {
        if (a.cardTails.contains(tail)) return a.id;
      }
    }
    for (final a in accounts) {
      if (a.keywords.any(input.rawText.contains)) return a.id;
    }
    for (final a in accounts) {
      if (a.packages.contains(input.payment.sourceApp)) return a.id;
    }
    return null;
  }

  /// 喂给 NB 的文本：有商户就只用商户。
  ///
  /// 种子样本是「商户关键词 → 类别」的短文本，拿整条通知去预测会产生
  /// train/serve skew（「元」「成功」这类噪声字压过商户词）。
  static String modelText(ClassifyInput input) =>
      input.payment.merchant.isNotEmpty ? input.payment.merchant : input.rawText;

  void learn(ClassifyInput input, {String? categoryId, String? fundId}) =>
      learnRaw(
        rawText: modelText(input),
        extras: featureExtras(input),
        categoryId: categoryId,
        fundId: fundId,
      );

  /// 从本地捕获记录（只存了文本 + extras）回放学习。
  void learnRaw({
    required String rawText,
    required List<String> extras,
    String? categoryId,
    String? fundId,
  }) {
    final tokens = NaiveBayes.tokenize(rawText, extras);
    if (categoryId != null) categoryModel.learn(tokens, categoryId);
    if (fundId != null) fundModel.learn(tokens, fundId);
  }
}

/// 用种子样本训练类别模型：种子里只有类别名，这里按候选的 name/aliases
/// 映射成 id；映射不到的类别直接跳过（用户删掉的类别不会污染模型）。
void trainSeedCategoryModel(
  NaiveBayes model,
  List<ClassifierCandidate> categories, {
  List<SeedSample> samples = kCaptureSeedSamples,
}) {
  final idByName = <String, String>{};
  for (final c in categories) {
    idByName.putIfAbsent(c.name, () => c.id);
    for (final alias in c.aliases) {
      idByName.putIfAbsent(alias, () => c.id);
    }
  }
  for (final sample in samples) {
    final id = idByName[sample.category];
    if (id == null) continue;
    model.learn(NaiveBayes.tokenize(sample.text), id);
  }
}
