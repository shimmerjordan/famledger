import 'dart:convert';
import 'dart:math' as math;

import 'capture_types.dart';
import 'classifier.dart';
import 'naive_bayes.dart';
import 'parser.dart';
import 'quick_reply.dart';
import 'source_profiles.dart';

/// 识别成「转账」时置信度的上限：一定低于默认阈值 0.75，必须人工确认。
const double kTransferConfidenceCap = 0.5;

/// 识别成「转账」时写进草稿的备注。
const String kTransferNote = '疑似转账，请确认类型';

/// 本地模型在 [CaptureStore] 里的键。
const String kCategoryModelKey = 'category';
const String kFundModelKey = 'fund';

/// 一条通知的处理结论。
enum CaptureDecision { recorded, pending, duplicate, ignored }

/// 创建流水的结果。
class CaptureApiResult {
  const CaptureApiResult({this.id, this.duplicate = false});

  final String? id;

  /// 服务端判定这是重复流水。
  final bool duplicate;
}

/// 服务端明确拒绝（HTTP 4xx/5xx）。网络层的超时/断网请照常抛 IO 异常，
/// 管线靠这个区分「重试有用」和「重试多少次都没用」。
class CaptureApiException implements Exception {
  const CaptureApiException(this.status, this.code, this.message);

  final int status;

  /// 服务端的机器码，如 `invalid_transfer`。
  final String code;

  /// 给人看的中文消息，直接进通知。
  final String message;

  /// 4xx：请求本身有问题，重试只会一直失败。
  ///
  /// 429（限流）是例外：请求没毛病，只是来得太快，过一会儿重试就行 ——
  /// 和 5xx 一样归到「临时故障」。
  bool get isClientError =>
      status >= 400 && status < 500 && status != _tooManyRequests;

  /// 429 / 5xx：值得重试。
  bool get isTransient => !isClientError;

  static const int _tooManyRequests = 429;

  @override
  String toString() => 'CaptureApiException($status $code: $message)';
}

/// 一条喂给 `POST /model/learn` 的样本。
///
/// 字段与 `server/src/modules/model.js` 的 `prepare()` 一一对应：服务端拿
/// **原始字段**自己 `tokenize(text, extrasFor(fields))`，所以这里不能发
/// token 列表，`text` 也必须与本地喂给模型的那一份完全一致（[Classifier.modelText]）。
class LearnSample {
  const LearnSample({
    required this.text,
    required this.features,
    this.categoryId,
    this.fundId,
  });

  /// 服务端 `MAX_TEXT`。
  static const int maxTextLength = 500;

  final String text;
  final CaptureFeatures features;
  final String? categoryId;
  final String? fundId;

  bool get isEmpty => categoryId == null && fundId == null;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'text': text.runes.length > maxTextLength
            ? String.fromCharCodes(text.runes.take(maxTextLength))
            : text,
        ...features.toJson(),
        if (categoryId != null) 'categoryId': categoryId,
        if (fundId != null) 'fundId': fundId,
      };
}

/// 本地捕获记录：结果通知的动作（正确/撤销/快捷回复）靠它找回上下文。
class CaptureRecord {
  const CaptureRecord({
    required this.captureId,
    required this.decision,
    required this.draft,
    required this.dedupeHash,
    required this.learnText,
    required this.features,
    required this.createdAt,
    this.transactionId,
    this.synced = false,
    this.syncError,
  });

  final String captureId;
  final CaptureDecision decision;
  final CaptureDraft draft;
  final String dedupeHash;

  /// 喂给 NB 的文本（商户优先），纠正时原样回放。
  final String learnText;

  /// 非文本特征，本地展开成 extras、同步时发原始字段。
  final CaptureFeatures features;
  final DateTime createdAt;
  final String? transactionId;

  /// 是否已成功提交到服务端。
  final bool synced;

  /// 服务端明确拒绝的原因（4xx）。非空 = 别再重试，等用户处理。
  final String? syncError;

  List<String> get extras => features.extras;

  /// outbox 该不该继续重试：没同步成功、且不是被服务端明确拒绝。
  bool get needsRetry => !synced && syncError == null;

  CaptureRecord copyWith({
    CaptureDecision? decision,
    CaptureDraft? draft,
    String? transactionId,
    bool? synced,
    String? syncError,
    bool clearSyncError = false,
  }) =>
      CaptureRecord(
        captureId: captureId,
        decision: decision ?? this.decision,
        draft: draft ?? this.draft,
        dedupeHash: dedupeHash,
        learnText: learnText,
        features: features,
        createdAt: createdAt,
        transactionId: transactionId ?? this.transactionId,
        synced: synced ?? this.synced,
        syncError: clearSyncError ? null : (syncError ?? this.syncError),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'captureId': captureId,
        'decision': decision.name,
        'draft': draft.toJson(),
        'dedupeHash': dedupeHash,
        'learnText': learnText,
        'features': features.toJson(),
        'createdAt': isoLocal(createdAt),
        if (transactionId != null) 'transactionId': transactionId,
        'synced': synced,
        if (syncError != null) 'syncError': syncError,
      };

  factory CaptureRecord.fromJson(Map<String, dynamic> json) => CaptureRecord(
        captureId: json['captureId'] as String,
        decision: CaptureDecision.values.firstWhere(
          (d) => d.name == json['decision'],
          orElse: () => CaptureDecision.pending,
        ),
        draft: CaptureDraft.fromJson(
            (json['draft'] as Map).cast<String, dynamic>()),
        dedupeHash: (json['dedupeHash'] as String?) ?? '',
        learnText: (json['learnText'] as String?) ?? '',
        features: CaptureFeatures.fromJson(
            ((json['features'] as Map?) ?? const <String, dynamic>{})
                .cast<String, dynamic>()),
        createdAt: DateTime.parse(json['createdAt'] as String).toLocal(),
        transactionId: json['transactionId'] as String?,
        synced: (json['synced'] as bool?) ?? false,
        syncError: json['syncError'] as String?,
      );
}

/// 本地存储：待确认捕获、去重哈希、模型 JSON。
abstract class CaptureStore {
  Future<DateTime?> lastSeen(String hash);
  Future<void> markSeen(String hash, DateTime at);
  Future<void> saveCapture(CaptureRecord record);
  Future<CaptureRecord?> loadCapture(String captureId);
  Future<void> deleteCapture(String captureId);
  Future<Map<String, dynamic>?> loadModel(String key);
  Future<void> saveModel(String key, Map<String, dynamic> json);
}

/// 服务端接口（实现方负责 outbox / 重试）。
abstract class CaptureApi {
  Future<CaptureApiResult> createTransaction(Map<String, dynamic> body);
  Future<void> patchTransaction(String id, Map<String, dynamic> patch);
  Future<void> confirmTransaction(String id);
  Future<void> deleteTransaction(String id);

  /// `POST /model/learn`
  Future<void> learn(List<LearnSample> samples);

  /// `POST /ai/classify`，未开启或不可用时返回 null。
  Future<Map<String, dynamic>?> aiClassify(Map<String, dynamic> input);
}

class CapturePipelineConfig {
  const CapturePipelineConfig({
    required this.memberId,
    this.threshold = 0.75,
    this.dedupeWindow = const Duration(minutes: 10),
    this.aiFallback = false,
  });

  /// 记在流水上的成员。
  final String memberId;

  /// ≥ 阈值才自动入账。
  final double threshold;
  final Duration dedupeWindow;

  /// 低于阈值时是否调 `/ai/classify` 兜底。
  final bool aiFallback;
}

class CaptureOutcome {
  const CaptureOutcome({
    required this.decision,
    required this.title,
    required this.body,
    this.draft,
    this.captureId,
  });

  final CaptureDecision decision;
  final CaptureDraft? draft;

  /// 结果通知标题，如「支付宝 −¥35.00 · 餐饮 → 家庭公共基金」。
  final String title;

  /// 结果通知正文，如「92% 可信 · 美团 · 点击修改」。
  final String body;

  /// 只有产生了本地捕获记录才有（可对它做 confirm/undo/快捷回复）。
  final String? captureId;
}

/// 通知动作（正确/撤销/快捷回复）的结果，用于更新同一条通知。
class CaptureActionResult {
  const CaptureActionResult({required this.title, required this.body, this.draft});

  final String title;
  final String body;
  final CaptureDraft? draft;
}

/// 通知 → 流水的完整管线。
class CapturePipeline {
  CapturePipeline({
    required this.store,
    required this.api,
    required this.classifier,
    required this.config,
    this.parser = const NotificationParser(),
    this.quickReply = const QuickReplyInterpreter(),
    DateTime Function()? now,
    String Function()? idGenerator,
  })  : _now = now ?? DateTime.now,
        _newId = idGenerator ?? newCaptureId;

  final CaptureStore store;
  final CaptureApi api;
  final Classifier classifier;
  final CapturePipelineConfig config;
  final NotificationParser parser;
  final QuickReplyInterpreter quickReply;
  final DateTime Function() _now;
  final String Function() _newId;

  /// 装配：本地没有模型就用种子训练一份并落盘。
  static Future<CapturePipeline> bootstrap({
    required CaptureStore store,
    required CaptureApi api,
    required CapturePipelineConfig config,
    required List<ClassifierCandidate> categories,
    required List<ClassifierCandidate> funds,
    required List<CaptureAccount> accounts,
    List<CaptureRule> rules = const <CaptureRule>[],
    String? defaultFundId,
    String? defaultAccountId,
    NotificationParser parser = const NotificationParser(),
    QuickReplyInterpreter quickReply = const QuickReplyInterpreter(),
    DateTime Function()? now,
    String Function()? idGenerator,
  }) async {
    final categoryJson = await store.loadModel(kCategoryModelKey);
    final NaiveBayes categoryModel;
    if (categoryJson == null) {
      categoryModel = NaiveBayes.empty();
      trainSeedCategoryModel(categoryModel, categories);
      await store.saveModel(kCategoryModelKey, categoryModel.toJson());
    } else {
      categoryModel = NaiveBayes.fromJson(categoryJson);
    }
    final fundJson = await store.loadModel(kFundModelKey);
    final fundModel =
        fundJson == null ? NaiveBayes.empty() : NaiveBayes.fromJson(fundJson);

    return CapturePipeline(
      store: store,
      api: api,
      classifier: Classifier(
        categoryModel: categoryModel,
        fundModel: fundModel,
        rules: rules,
        categories: categories,
        funds: funds,
        accounts: accounts,
        defaultFundId: defaultFundId,
        defaultAccountId: defaultAccountId,
      ),
      config: config,
      parser: parser,
      quickReply: quickReply,
      now: now,
      idGenerator: idGenerator,
    );
  }

  // ------------------------------------------------------------ 主流程

  Future<CaptureOutcome> handle(RawNotification notification) async {
    final payment = parser.parse(notification);
    if (!payment.isPayment) {
      return const CaptureOutcome(
        decision: CaptureDecision.ignored,
        title: '已忽略',
        body: '不是支付通知',
      );
    }

    final rawText = payment.normalizedText;
    final now = _now();
    final hash = captureHash(notification.packageName, rawText);
    final seen = await store.lastSeen(hash);
    if (seen != null && now.difference(seen) < config.dedupeWindow) {
      return CaptureOutcome(
        decision: CaptureDecision.duplicate,
        title: '${_sourceName(payment.sourceApp)} '
            '${_signed(_typeOf(payment, rawText), payment.amountCents!)} · 重复通知',
        body: '${config.dedupeWindow.inMinutes} 分钟内已记过这笔，已忽略',
      );
    }

    final input = ClassifyInput(
      payment: payment,
      rawText: rawText,
      memberId: config.memberId,
    );
    var result = classifier.classify(input);
    if (result.confidence < config.threshold && config.aiFallback) {
      result = await _aiFallback(input, result);
    }

    final captureId = _newId();
    // 转账永远不自动入账：服务端要求 transfer 必须成对（账户→账户 或
    // 基金→基金），通知里只看得到单边，硬发只会吃 400 invalid_transfer。
    final suspectedTransfer = payment.direction == PayDirection.transfer;
    final confidence = suspectedTransfer
        ? math.min(result.confidence, kTransferConfidenceCap)
        : result.confidence;
    final confirmed = confidence >= config.threshold;
    final draft = CaptureDraft(
      clientId: captureId,
      type: _typeOf(payment, rawText),
      amountCents: payment.amountCents!,
      occurredAt: payment.occurredAt,
      accountId: result.accountId,
      fundId: result.fundId,
      categoryId: result.categoryId,
      memberId: config.memberId,
      merchant: payment.merchant,
      note: suspectedTransfer ? kTransferNote : '',
      status: confirmed ? 'confirmed' : 'pending',
      confidence: confidence,
      rawText: rawText,
      sourceApp: notification.packageName,
      captureId: captureId,
    );

    await store.markSeen(hash, now);

    var record = CaptureRecord(
      captureId: captureId,
      decision: confirmed ? CaptureDecision.recorded : CaptureDecision.pending,
      draft: draft,
      dedupeHash: hash,
      learnText: Classifier.modelText(input),
      features: CaptureFeatures.of(input),
      createdAt: now,
    );

    CaptureApiResult? apiResult;
    CaptureApiException? rejected;
    try {
      apiResult = await api.createTransaction(draft.toJson());
    } on CaptureApiException catch (e) {
      // 4xx：重试没用，交给用户处理；5xx/429 是临时故障，和断网一样等重试。
      if (e.isClientError) rejected = e;
    } catch (_) {
      // 断网/超时：本地先留着，outbox 会重试
    }

    if (apiResult != null && apiResult.duplicate) {
      return CaptureOutcome(
        decision: CaptureDecision.duplicate,
        title: '${_sourceName(draft.sourceApp)} '
            '${_signed(draft.type, draft.amountCents)} · 重复流水',
        body: '服务端已有同一笔，已忽略',
      );
    }

    if (rejected != null) {
      record = record.copyWith(
        decision: CaptureDecision.pending,
        draft: draft.copyWith(status: 'pending'),
        syncError: rejected.message,
      );
      await store.saveCapture(record);
      return CaptureOutcome(
        decision: CaptureDecision.pending,
        draft: record.draft,
        captureId: captureId,
        title: '记账未成功',
        body: '${rejected.message} · 点击打开处理',
      );
    }

    record = record.copyWith(
      transactionId: apiResult?.id,
      synced: apiResult != null,
    );
    await store.saveCapture(record);

    return CaptureOutcome(
      decision: record.decision,
      draft: draft,
      captureId: captureId,
      title: _title(draft),
      body: _body(draft,
          pending: !confirmed, extra: suspectedTransfer ? '疑似转账' : null),
    );
  }



  Future<ClassifyResult> _aiFallback(
    ClassifyInput input,
    ClassifyResult local,
  ) async {
    Map<String, dynamic>? answer;
    try {
      answer = await api.aiClassify(<String, dynamic>{
        'text': input.rawText,
        'merchant': input.payment.merchant,
        'amountCents': input.payment.amountCents,
        'direction': input.payment.direction.name,
        'channel': input.payment.channel,
        'categories': <Map<String, String>>[
          for (final c in classifier.categories)
            <String, String>{'id': c.id, 'name': c.name},
        ],
        'funds': <Map<String, String>>[
          for (final f in classifier.funds)
            <String, String>{'id': f.id, 'name': f.name},
        ],
      });
    } catch (_) {
      return local;
    }
    if (answer == null) return local;
    final confidence = (answer['confidence'] as num?)?.toDouble();
    if (confidence == null || confidence <= local.confidence) return local;
    return local.copyWith(
      categoryId: answer['categoryId'] as String? ?? local.categoryId,
      fundId: answer['fundId'] as String? ?? local.fundId,
      confidence: confidence,
      reason: 'ai',
    );
  }

  // ------------------------------------------------------------ 通知动作

  /// 「修改…」的 RemoteInput 文本。
  Future<CaptureActionResult> applyQuickReply(
    String captureId,
    String text,
  ) async {
    final record = await store.loadCapture(captureId);
    if (record == null) return _notFound();

    final patch = quickReply.interpret(
      text,
      funds: classifier.funds,
      categories: classifier.categories,
    );
    if (patch.isEmpty) {
      return CaptureActionResult(
        title: '未识别的修改',
        body: '可以回复基金名、类别名、金额或备注',
        draft: record.draft,
      );
    }

    final draft = record.draft.copyWith(
      fundId: patch.fundId,
      categoryId: patch.categoryId,
      amountCents: patch.amountCents,
      type: patch.type,
      note: patch.note,
      status: 'confirmed',
      confidence: 1.0,
    );
    var updated = record.copyWith(
      draft: draft,
      decision: CaptureDecision.recorded,
      synced: false,
      clearSyncError: true,
    );
    // 先落本地、先学：没网也不能把用户的纠正弄丢。
    await _learn(updated);
    await store.saveCapture(updated);

    final error = await _push(
      updated,
      () => api.patchTransaction(record.transactionId!, <String, dynamic>{
        ...patch.toJson(),
        'status': 'confirmed',
      }),
    );
    updated = error.record;
    await store.saveCapture(updated);
    if (error.message != null) {
      return CaptureActionResult(
        title: '改动未同步',
        body: '${error.message} · 已存在本地 · 点击打开处理',
        draft: draft,
      );
    }

    return CaptureActionResult(
      title: '已更新：${_title(draft)}',
      body: _body(
        draft,
        pending: false,
        // 断网 / 5xx：改动已落本地、outbox 会重放，别让用户以为已经同步了。
        action: error.ok ? '再次点击可继续修改' : '已存本地，联网后自动同步',
      ),
      draft: draft,
    );
  }

  /// 「正确」按钮。
  Future<CaptureActionResult> confirm(String captureId) async {
    final record = await store.loadCapture(captureId);
    if (record == null) return _notFound();

    final draft = record.draft.copyWith(status: 'confirmed', confidence: 1.0);
    var updated = record.copyWith(
      draft: draft,
      decision: CaptureDecision.recorded,
      synced: false,
      clearSyncError: true,
    );
    await _learn(updated);
    await store.saveCapture(updated);

    final error = await _push(
        updated, () => api.confirmTransaction(record.transactionId!));
    updated = error.record;
    await store.saveCapture(updated);
    if (error.message != null) {
      return CaptureActionResult(
        title: '确认未同步',
        body: '${error.message} · 已存在本地 · 点击打开处理',
        draft: draft,
      );
    }

    return CaptureActionResult(
      title: '已确认：${_title(draft)}',
      body: _body(draft, pending: false, action: error.ok ? '已记入账本' : '已存本地，联网后自动同步'),
      draft: draft,
    );
  }

  /// 「撤销」按钮：删流水、删本地记录，并让去重窗口失效（可以重记）。
  Future<CaptureActionResult> undo(String captureId) async {
    final record = await store.loadCapture(captureId);
    if (record == null) return _notFound();

    // 撤销是用户已经做出的决定，同步失败也不该让这笔「复活」。
    if (record.dedupeHash.isNotEmpty) {
      await store.markSeen(
          record.dedupeHash, DateTime.fromMillisecondsSinceEpoch(0));
    }
    if (record.transactionId == null) {
      // 服务端还没有这笔（离线或被拒）：留一条「已作废」的墓碑，
      // outbox 就不会过一会儿又把它建出来。
      await store.saveCapture(record.copyWith(
        decision: CaptureDecision.ignored,
        synced: true,
        clearSyncError: true,
      ));
      return const CaptureActionResult(title: '已撤销', body: '这笔还没同步，已在本地作废');
    }

    await store.deleteCapture(captureId);
    final pushed =
        await _push(record, () => api.deleteTransaction(record.transactionId!));
    if (pushed.message != null) {
      await store.saveCapture(
          pushed.record.copyWith(decision: CaptureDecision.ignored));
      return CaptureActionResult(
        title: '已撤销（未同步）',
        body: '${pushed.message} · 点击打开处理',
      );
    }
    if (!pushed.ok) {
      await store.saveCapture(
          pushed.record.copyWith(decision: CaptureDecision.ignored));
      return const CaptureActionResult(title: '已撤销', body: '删除请求会在联网后重试');
    }
    return const CaptureActionResult(title: '已撤销', body: '这笔自动记账已删除');
  }

  /// 推一次服务端。
  ///
  /// * 成功（或流水还没建、无从推起）→ `ok`，`synced=true`；
  /// * 4xx → `message` 带回中文原因并记进 `syncError`（别再重试）；
  /// * 断网 / 5xx → `ok=false` 且没有 message，`synced=false` 等 outbox 重试。
  Future<({CaptureRecord record, String? message, bool ok})> _push(
    CaptureRecord record,
    Future<void> Function() call,
  ) async {
    if (record.transactionId == null) {
      return (record: record, message: null, ok: true); // 等 outbox 整体重放
    }
    try {
      await call();
      return (
        record: record.copyWith(synced: true, clearSyncError: true),
        message: null,
        ok: true,
      );
    } on CaptureApiException catch (e) {
      if (!e.isClientError) {
        return (record: record.copyWith(synced: false), message: null, ok: false);
      }
      return (
        record: record.copyWith(synced: false, syncError: e.message),
        message: e.message,
        ok: false,
      );
    } catch (_) {
      return (record: record.copyWith(synced: false), message: null, ok: false);
    }
  }

  CaptureActionResult _notFound() =>
      const CaptureActionResult(title: '找不到这笔自动记账', body: '可能已被撤销或清理');

  /// 用户确认/纠正后的样本：本地模型 + 服务端共享模型都学一份。
  Future<void> _learn(CaptureRecord record) async {
    final categoryId = record.draft.categoryId;
    final fundId = record.draft.fundId;
    if (categoryId == null && fundId == null) return;

    classifier.learnRaw(
      rawText: record.learnText,
      extras: record.extras,
      categoryId: categoryId,
      fundId: fundId,
    );
    // 服务端拿原始字段自己分词，所以 text 必须和本地喂模型的是同一份。
    try {
      await api.learn(<LearnSample>[
        LearnSample(
          text: record.learnText,
          features: record.features,
          categoryId: categoryId,
          fundId: fundId,
        ),
      ]);
    } catch (_) {
      // 共享模型晚点再同步，本地已经学到了
    }
    await store.saveModel(kCategoryModelKey, classifier.categoryModel.toJson());
    await store.saveModel(kFundModelKey, classifier.fundModel.toJson());
  }

  // ------------------------------------------------------------ 文案

  /// 通知抬头用**来源**名而不是渠道名：iOS 的三个导入口共用 `share` 渠道，
  /// 但用户看到的应该是「剪贴板」「快捷指令」而不是同一个词。
  String _sourceName(String packageName) =>
      SourceProfile.displayNameOfSource(packageName);

  String _title(CaptureDraft draft) {
    final buf = StringBuffer('${_sourceName(draft.sourceApp)} '
        '${_signed(draft.type, draft.amountCents)} · '
        '${_nameOf(classifier.categories, draft.categoryId) ?? '未分类'}');
    final fund = _nameOf(classifier.funds, draft.fundId);
    if (fund != null) buf.write(' → $fund');
    return buf.toString();
  }

  String _body(
    CaptureDraft draft, {
    required bool pending,
    String? action,
    String? extra,
  }) {
    final parts = <String>[
      '${(draft.confidence * 100).round()}% 可信',
      if (pending) '待确认',
      if (extra != null) extra,
      if (draft.merchant.isNotEmpty) draft.merchant,
      action ?? '点击修改',
    ];
    return parts.join(' · ');
  }

  String? _nameOf(List<ClassifierCandidate> candidates, String? id) {
    if (id == null) return null;
    for (final c in candidates) {
      if (c.id == id) return c.name;
    }
    return null;
  }

  /// 通知能看到的永远是单边，所以草稿只会是 expense / income。
  ///
  /// 方向识别不出来时按支出处理（占绝大多数）；识别成转账时按措辞落到
  /// 更可能的那一边（还款/提现/取款/转出＝支出，转入/已被接收/到账＝收入），
  /// 同时置信度被压到 [kTransferConfidenceCap] 以下，一定会进待确认。
  static String _typeOf(ParsedPayment payment, String text) {
    switch (payment.direction) {
      case PayDirection.income:
        return 'income';
      case PayDirection.transfer:
        if (_transferOutRe.hasMatch(text)) return 'expense';
        if (_transferInRe.hasMatch(text)) return 'income';
        return 'expense';
      case PayDirection.expense:
      case PayDirection.unknown:
        return 'expense';
    }
  }

  static final RegExp _transferOutRe = RegExp(r'还款|提现|取款|转出');
  static final RegExp _transferInRe = RegExp(r'转入|已被接收|已被领取|到账|入账');

  static String _signed(String type, int amountCents) => switch (type) {
        'income' => '+¥${formatYuan(amountCents)}',
        _ => '−¥${formatYuan(amountCents)}',
      };
}

/// 分 → 「1,299.00」（金额恒为非负，正负号由调用方按 type 决定）。
String formatYuan(int amountCents) {
  final cents = amountCents.abs();
  final yuan = (cents ~/ 100).toString();
  final frac = (cents % 100).toString().padLeft(2, '0');
  final buf = StringBuffer();
  for (var i = 0; i < yuan.length; i++) {
    if (i > 0 && (yuan.length - i) % 3 == 0) buf.write(',');
    buf.write(yuan[i]);
  }
  return '$buf.$frac';
}

/// 去重哈希：16 位十六进制，由两轮**32 位** FNV-1a 拼成。
///
/// 刻意不写 64 位常量：dart2js 的 int 是 double，`0xcbf29ce484222325`
/// 这样的字面量根本编译不过（integer literal can't be represented exactly
/// in JavaScript），`flutter build web` 会直接失败。这里所有中间值都 < 2^53，
/// VM / AOT / dart2js 三处结果完全一致。
String captureHash(String packageName, String normalizedText) {
  final bytes = utf8.encode('$packageName|$normalizedText');
  final first = _fnv1a32(bytes, _fnvOffset32);
  final second = _fnv1a32(bytes, _fnvOffset32 ^ 0xFFFFFFFF);
  return '${_hex8(first)}${_hex8(second)}';
}

const int _fnvOffset32 = 0x811C9DC5;
const int _fnvPrime32 = 0x01000193;

int _fnv1a32(List<int> bytes, int seed) {
  var hash = seed;
  for (final byte in bytes) {
    hash = (hash ^ byte) & 0xFFFFFFFF;
    hash = _mul32(hash, _fnvPrime32);
  }
  return hash;
}

/// `(a * b) mod 2^32`，拆成 16 位半字相乘，中间值最大 ~2^33，
/// 不碰 JS 那条 2^53 的精度红线。
int _mul32(int a, int b) {
  final aLo = a & 0xFFFF;
  final aHi = (a >> 16) & 0xFFFF;
  final bLo = b & 0xFFFF;
  final bHi = (b >> 16) & 0xFFFF;
  final low = aLo * bLo;
  final mid = (aHi * bLo + aLo * bHi) & 0xFFFF;
  return ((mid * 0x10000) + low) & 0xFFFFFFFF;
}

String _hex8(int value) => value.toRadixString(16).padLeft(8, '0');

/// 默认 captureId：时间戳 + 随机数，够本地唯一。
String newCaptureId() {
  final rnd = math.Random();
  final a = rnd.nextInt(0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
  final b = rnd.nextInt(0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
  return 'cap-${DateTime.now().millisecondsSinceEpoch.toRadixString(16)}-$a$b';
}
