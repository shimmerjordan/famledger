import 'dart:io';

import 'package:famledger/capture/capture_types.dart';
import 'package:famledger/capture/classifier.dart';
import 'package:famledger/capture/naive_bayes.dart';
import 'package:famledger/capture/parser.dart';
import 'package:famledger/capture/pipeline.dart';
import 'package:famledger/capture/seed_dataset.dart';
import 'package:famledger/capture/source_profiles.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeStore implements CaptureStore {
  final Map<String, DateTime> seen = <String, DateTime>{};
  final Map<String, CaptureRecord> captures = <String, CaptureRecord>{};
  final Map<String, Map<String, dynamic>> models =
      <String, Map<String, dynamic>>{};

  @override
  Future<DateTime?> lastSeen(String hash) async => seen[hash];

  @override
  Future<void> markSeen(String hash, DateTime at) async => seen[hash] = at;

  @override
  Future<void> saveCapture(CaptureRecord record) async =>
      captures[record.captureId] = record;

  @override
  Future<CaptureRecord?> loadCapture(String captureId) async =>
      captures[captureId];

  @override
  Future<void> deleteCapture(String captureId) async =>
      captures.remove(captureId);

  @override
  Future<Map<String, dynamic>?> loadModel(String key) async => models[key];

  @override
  Future<void> saveModel(String key, Map<String, dynamic> json) async =>
      models[key] = json;
}

class FakeApi implements CaptureApi {
  final List<Map<String, dynamic>> created = <Map<String, dynamic>>[];
  final List<List<dynamic>> patched = <List<dynamic>>[];
  final List<String> confirmed = <String>[];
  final List<String> deleted = <String>[];
  final List<LearnSample> learned = <LearnSample>[];
  final List<Map<String, dynamic>> aiCalls = <Map<String, dynamic>>[];

  bool reportDuplicate = false;

  /// 断网/超时：值得重试。
  bool throwOnCreate = false;

  /// 服务端明确拒绝：重试也没用。
  CaptureApiException? rejectCreate;
  CaptureApiException? rejectWrites;
  bool throwOnWrites = false;
  Map<String, dynamic>? aiResponse;
  int _seq = 0;

  void _guardWrites() {
    if (rejectWrites != null) throw rejectWrites!;
    if (throwOnWrites) throw const SocketException('offline');
  }

  @override
  Future<CaptureApiResult> createTransaction(Map<String, dynamic> body) async {
    if (rejectCreate != null) throw rejectCreate!;
    if (throwOnCreate) throw const SocketException('offline');
    created.add(body);
    return CaptureApiResult(
        id: 'tx-${++_seq}', duplicate: reportDuplicate);
  }

  @override
  Future<void> patchTransaction(String id, Map<String, dynamic> patch) async {
    _guardWrites();
    patched.add(<dynamic>[id, patch]);
  }

  @override
  Future<void> confirmTransaction(String id) async {
    _guardWrites();
    confirmed.add(id);
  }

  @override
  Future<void> deleteTransaction(String id) async {
    _guardWrites();
    deleted.add(id);
  }

  @override
  Future<void> learn(List<LearnSample> samples) async =>
      learned.addAll(samples);

  @override
  Future<Map<String, dynamic>?> aiClassify(Map<String, dynamic> input) async {
    aiCalls.add(input);
    return aiResponse;
  }
}

final _categories = kSeedCategoryNames
    .map((n) => ClassifierCandidate(id: 'cat-$n', name: n))
    .toList();

const _funds = <ClassifierCandidate>[
  ClassifierCandidate(id: 'fund-public', name: '家庭公共基金'),
  ClassifierCandidate(id: 'fund-pet', name: '宠物基金', aliases: <String>['宠物']),
];

const _accounts = <CaptureAccount>[
  CaptureAccount(
    id: 'acc-alipay',
    name: '支付宝余额',
    kind: 'wallet',
    matchHints: <String, dynamic>{
      'packages': <String>['com.eg.android.AlipayGphone'],
    },
  ),
];

/// 商户特征足够强，种子模型就能高置信命中「交通」。
RawNotification _didi() => RawNotification(
      packageName: 'com.eg.android.AlipayGphone',
      title: '支付宝',
      text: '交易成功 ¥45.00 商户：滴滴出行',
      bigText: '',
      postedAt: DateTime(2026, 9, 12, 12, 30),
    );

/// 两字商户，种子模型证据不足 → 首次进 pending。
RawNotification _meituan() => RawNotification(
      packageName: 'com.eg.android.AlipayGphone',
      title: '支付宝',
      text: '你有一笔35.00元的支出，来自美团',
      bigText: '',
      postedAt: DateTime(2026, 9, 12, 12, 30),
    );

class _Harness {
  _Harness({
    bool trained = true,
    double threshold = 0.75,
    bool aiFallback = false,
  }) {
    final categoryModel = NaiveBayes.empty();
    if (trained) trainSeedCategoryModel(categoryModel, _categories);
    classifier = Classifier(
      categoryModel: categoryModel,
      fundModel: NaiveBayes.empty(),
      rules: const <CaptureRule>[],
      categories: _categories,
      funds: _funds,
      accounts: _accounts,
      defaultFundId: 'fund-public',
      defaultAccountId: 'acc-alipay',
    );
    pipeline = CapturePipeline(
      store: store,
      api: api,
      classifier: classifier,
      config: CapturePipelineConfig(
        threshold: threshold,
        memberId: 'member-1',
        aiFallback: aiFallback,
      ),
      now: () => clock,
      idGenerator: () => 'cap-${++_ids}',
    );
  }

  final FakeStore store = FakeStore();
  final FakeApi api = FakeApi();
  late final Classifier classifier;
  late final CapturePipeline pipeline;
  DateTime clock = DateTime(2026, 9, 12, 12, 30);
  int _ids = 0;
}

void main() {
  group('handle', () {
    test('高置信度 → recorded + status confirmed + 中文结果文案', () async {
      final h = _Harness();
      final out = await h.pipeline.handle(_didi());

      expect(out.decision, CaptureDecision.recorded);
      expect(out.captureId, 'cap-1');
      final draft = out.draft!;
      expect(draft.type, 'expense');
      expect(draft.amountCents, 4500);
      expect(draft.categoryId, 'cat-交通');
      expect(draft.fundId, 'fund-public');
      expect(draft.accountId, 'acc-alipay');
      expect(draft.memberId, 'member-1');
      expect(draft.source, 'notification');
      expect(draft.status, 'confirmed');
      expect(draft.sourceApp, 'com.eg.android.AlipayGphone');
      expect(draft.captureId, 'cap-1');
      expect(draft.merchant, '滴滴出行');
      expect(draft.rawText, contains('滴滴出行'));
      expect(draft.confidence, 0.92);

      expect(out.title, '支付宝 −¥45.00 · 交通 → 家庭公共基金');
      expect(out.body, '92% 可信 · 滴滴出行 · 点击修改');

      expect(h.api.created, hasLength(1));
      final body = h.api.created.single;
      expect(body['clientId'], isNotEmpty);
      expect(body['occurredAt'], isA<String>());
      expect(body['status'], 'confirmed');
      expect(h.store.captures['cap-1']!.transactionId, 'tx-1');
    });

    test('低置信度 → pending，草稿 status=pending', () async {
      final h = _Harness(trained: false);
      final out = await h.pipeline.handle(_didi());

      expect(out.decision, CaptureDecision.pending);
      expect(out.draft!.status, 'pending');
      expect(out.draft!.categoryId, isNull);
      expect(out.body, contains('待确认'));
      expect(h.api.created, hasLength(1));
    });

    test('同一通知 10 分钟内第二次 → duplicate 且不再落库', () async {
      final h = _Harness();
      final first = await h.pipeline.handle(_didi());
      expect(first.decision, CaptureDecision.recorded);

      h.clock = h.clock.add(const Duration(minutes: 3));
      final second = await h.pipeline.handle(_didi());
      expect(second.decision, CaptureDecision.duplicate);
      expect(h.api.created, hasLength(1));
      expect(h.store.captures, hasLength(1));
      expect(second.title, contains('重复'));
    });

    test('超过 10 分钟窗口后视为新流水', () async {
      final h = _Harness();
      await h.pipeline.handle(_didi());
      h.clock = h.clock.add(const Duration(minutes: 11));
      final again = await h.pipeline.handle(_didi());
      expect(again.decision, CaptureDecision.recorded);
      expect(h.api.created, hasLength(2));
    });

    test('服务端报 duplicate → decision duplicate', () async {
      final h = _Harness();
      h.api.reportDuplicate = true;
      final out = await h.pipeline.handle(_didi());
      expect(out.decision, CaptureDecision.duplicate);
    });

    test('噪声通知 → ignored，不调用任何接口', () async {
      final h = _Harness();
      final out = await h.pipeline.handle(RawNotification(
        packageName: 'com.miui.mms',
        title: '招商银行',
        text: '【招商银行】您的验证码是123456，请勿泄露。',
        bigText: '',
        postedAt: DateTime(2026, 9, 12, 9, 12),
      ));
      expect(out.decision, CaptureDecision.ignored);
      expect(out.draft, isNull);
      expect(out.captureId, isNull);
      expect(h.api.created, isEmpty);
      expect(h.store.captures, isEmpty);
      expect(h.store.seen, isEmpty);
    });

    test('接口异常不影响本地记录（等待 outbox 重试）', () async {
      final h = _Harness();
      h.api.throwOnCreate = true;
      final out = await h.pipeline.handle(_didi());
      expect(out.decision, CaptureDecision.recorded);
      final record = h.store.captures['cap-1']!;
      expect(record.transactionId, isNull);
      expect(record.synced, isFalse);
    });

    test('AI 兜底：低于阈值且开关打开时调用 /ai/classify', () async {
      final h = _Harness(trained: false, aiFallback: true);
      h.api.aiResponse = <String, dynamic>{
        'categoryId': 'cat-餐饮',
        'fundId': 'fund-public',
        'confidence': 0.9,
      };
      final out = await h.pipeline.handle(_didi());
      expect(h.api.aiCalls, hasLength(1));
      expect(out.decision, CaptureDecision.recorded);
      expect(out.draft!.categoryId, 'cat-餐饮');
      expect(out.draft!.confidence, 0.9);
    });

    test('AI 兜底关闭时不调用', () async {
      final h = _Harness(trained: false);
      await h.pipeline.handle(_didi());
      expect(h.api.aiCalls, isEmpty);
    });

    test('短商户首次 pending，用户确认一次后同一笔即可自动入账', () async {
      final h = _Harness();
      final first = await h.pipeline.handle(_meituan());
      expect(first.decision, CaptureDecision.pending);
      expect(first.draft!.categoryId, 'cat-餐饮'); // 方向对，只是证据不足

      await h.pipeline.confirm('cap-1');

      h.clock = h.clock.add(const Duration(minutes: 11));
      final second = await h.pipeline.handle(_meituan());
      expect(second.decision, CaptureDecision.recorded);
      expect(second.draft!.categoryId, 'cat-餐饮');
    });

    test('iOS 导入：通知抬头用来源名而不是渠道名', () async {
      final h = _Harness();
      final out = await h.pipeline.handle(RawNotification(
        packageName: kIosClipboardSource,
        title: '',
        text: '交易成功 ¥45.00 商户：滴滴出行',
        bigText: '',
        postedAt: DateTime(2026, 9, 13, 10),
      ));
      expect(out.decision, CaptureDecision.recorded);
      expect(out.title, '剪贴板 −¥45.00 · 交通 → 家庭公共基金');
      expect(out.draft!.sourceApp, kIosClipboardSource);
      expect(out.draft!.confidence, 0.85);
    });

    test('收入方向的文案用 + 号', () async {
      final h = _Harness();
      final out = await h.pipeline.handle(RawNotification(
        packageName: 'com.eg.android.AlipayGphone',
        title: '支付宝',
        text: '支付宝到账 88.00元',
        bigText: '',
        postedAt: DateTime(2026, 9, 12, 11, 11),
      ));
      expect(out.draft!.type, 'income');
      expect(out.title, startsWith('支付宝 +¥88.00 · '));
    });
  });

  group('applyQuickReply', () {
    test('改基金 + 备注 → patch 流水、learn 模型、写回本地', () async {
      final h = _Harness();
      final out = await h.pipeline.handle(_didi());
      final before = h.classifier.fundModel.totalDocs;

      final result = await h.pipeline.applyQuickReply('cap-1', '宠物 给猫买粮');

      expect(h.api.patched, hasLength(1));
      final patch = h.api.patched.single[1] as Map<String, dynamic>;
      expect(h.api.patched.single[0], 'tx-1');
      expect(patch['fundId'], 'fund-pet');
      expect(patch['note'], '给猫买粮');
      expect(patch['status'], 'confirmed');

      final record = h.store.captures['cap-1']!;
      expect(record.draft.fundId, 'fund-pet');
      expect(record.draft.note, '给猫买粮');
      expect(record.draft.status, 'confirmed');

      expect(h.classifier.fundModel.totalDocs, greaterThan(before));
      expect(h.api.learned, isNotEmpty);
      expect(h.api.learned.any((s) => s.fundId == 'fund-pet'), isTrue);
      expect(h.store.models.containsKey(kFundModelKey), isTrue);
      expect(result.title, contains('已更新'));
      expect(result.title, contains('宠物基金')); // 标题里能看到改后的基金
      expect(result.body, startsWith('100% 可信'));
      expect(out.captureId, 'cap-1');
    });

    test('改金额与方向（金额要带「元」或整条就是数字）', () async {
      final h = _Harness();
      await h.pipeline.handle(_didi());
      await h.pipeline.applyQuickReply('cap-1', '收入 50元');
      final draft = h.store.captures['cap-1']!.draft;
      expect(draft.amountCents, 5000);
      expect(draft.type, 'income');
      expect((h.api.patched.single[1] as Map)['amountCents'], 5000);
    });

    test('改类别会把纠正样本喂给类别模型', () async {
      final h = _Harness();
      await h.pipeline.handle(_didi());
      await h.pipeline.applyQuickReply('cap-1', '宠物基金 宠物');
      expect(h.api.learned.any((s) => s.categoryId == 'cat-宠物'), isTrue);
      expect(h.store.models.containsKey(kCategoryModelKey), isTrue);
    });

    test('无法识别的回复 → 不 patch，提示原文', () async {
      final h = _Harness();
      await h.pipeline.handle(_didi());
      final r = await h.pipeline.applyQuickReply('cap-1', '   ');
      expect(h.api.patched, isEmpty);
      expect(r.title, contains('未识别'));
    });

    test('captureId 不存在 → 安全返回', () async {
      final h = _Harness();
      final r = await h.pipeline.applyQuickReply('nope', '宠物');
      expect(r.title, contains('找不到'));
      expect(h.api.patched, isEmpty);
    });
  });

  group('转账（服务端要求成对，管线永远不发 transfer）', () {
    test('还款类 → 支出草稿 + 待确认 + 备注', () async {
      final h = _Harness();
      final out = await h.pipeline.handle(RawNotification(
        packageName: 'com.eg.android.AlipayGphone',
        title: '支付宝',
        text: '花呗还款成功 1,299.00元',
        bigText: '',
        postedAt: DateTime(2026, 9, 10, 9),
      ));
      expect(out.decision, CaptureDecision.pending);
      expect(out.draft!.type, 'expense');
      expect(out.draft!.amountCents, 129900);
      expect(out.draft!.status, 'pending');
      expect(out.draft!.note, kTransferNote);
      expect(out.draft!.confidence, lessThanOrEqualTo(kTransferConfidenceCap));
      expect(out.body, contains('疑似转账'));
      expect(h.api.created.single['type'], 'expense');
    });

    test('转入类 → 收入草稿', () async {
      final h = _Harness();
      final out = await h.pipeline.handle(RawNotification(
        packageName: 'com.tencent.mm',
        title: '微信支付',
        text: '转账已被接收 ¥300.00',
        bigText: '',
        postedAt: DateTime(2026, 9, 12, 20, 10),
      ));
      expect(out.draft!.type, 'income');
      expect(out.decision, CaptureDecision.pending);
      expect(out.draft!.note, kTransferNote);
    });
  });

  group('接口失败分流', () {
    test('4xx → pending + syncError + 「记账未成功」', () async {
      final h = _Harness();
      h.api.rejectCreate = const CaptureApiException(
          400, 'invalid_transfer', '转账至少要填一对：账户→账户，或基金→基金');
      final out = await h.pipeline.handle(_didi());

      expect(out.decision, CaptureDecision.pending);
      expect(out.title, '记账未成功');
      expect(out.body, contains('转账至少要填一对'));
      expect(out.body, endsWith('点击打开处理'));
      final record = h.store.captures['cap-1']!;
      expect(record.syncError, contains('转账至少要填一对'));
      expect(record.synced, isFalse);
      expect(record.needsRetry, isFalse, reason: '4xx 不该无限重试');
      expect(record.draft.status, 'pending');
    });

    test('5xx 当作临时故障，仍按离线处理并等待重试', () async {
      final h = _Harness();
      h.api.rejectCreate =
          const CaptureApiException(503, 'unavailable', '服务暂时不可用');
      final out = await h.pipeline.handle(_didi());
      expect(out.decision, CaptureDecision.recorded);
      final record = h.store.captures['cap-1']!;
      expect(record.syncError, isNull);
      expect(record.needsRetry, isTrue);
    });

    test('429 限流当作临时故障，等重试', () async {
      final h = _Harness();
      h.api.rejectCreate =
          const CaptureApiException(429, 'rate_limited', '请求太频繁');
      final out = await h.pipeline.handle(_didi());
      expect(out.decision, CaptureDecision.recorded);
      final record = h.store.captures['cap-1']!;
      expect(record.syncError, isNull);
      expect(record.needsRetry, isTrue);
    });

    test('CaptureApiException 的 4xx / 临时故障判定', () {
      const rejected = CaptureApiException(400, 'bad', 'x');
      const limited = CaptureApiException(429, 'rate_limited', 'x');
      const broken = CaptureApiException(503, 'unavailable', 'x');
      expect(rejected.isClientError, isTrue);
      expect(rejected.isTransient, isFalse);
      expect(limited.isClientError, isFalse);
      expect(limited.isTransient, isTrue);
      expect(broken.isTransient, isTrue);
    });

    test('断网 → recorded + 等待 outbox 重试', () async {
      final h = _Harness();
      h.api.throwOnCreate = true;
      final out = await h.pipeline.handle(_didi());
      expect(out.decision, CaptureDecision.recorded);
      final record = h.store.captures['cap-1']!;
      expect(record.transactionId, isNull);
      expect(record.synced, isFalse);
      expect(record.needsRetry, isTrue);
    });

    test('断网时的快捷回复：本地已改、已学，等联网重试', () async {
      final h = _Harness();
      await h.pipeline.handle(_didi());
      h.api.throwOnWrites = true;

      final result = await h.pipeline.applyQuickReply('cap-1', '宠物 给猫买粮');

      final record = h.store.captures['cap-1']!;
      expect(record.draft.fundId, 'fund-pet');
      expect(record.draft.note, '给猫买粮');
      expect(record.draft.status, 'confirmed');
      expect(record.synced, isFalse);
      expect(record.needsRetry, isTrue);
      expect(h.classifier.fundModel.totalDocs, greaterThan(0));
      expect(h.store.models.containsKey(kFundModelKey), isTrue);
      expect(h.api.patched, isEmpty);
      expect(result.title, contains('已更新'));
    });

    test('快捷回复被服务端拒绝：本地保留，文案说清楚', () async {
      final h = _Harness();
      await h.pipeline.handle(_didi());
      h.api.rejectWrites =
          const CaptureApiException(400, 'invalid_amount', '金额必须大于 0');

      final result = await h.pipeline.applyQuickReply('cap-1', '宠物');

      final record = h.store.captures['cap-1']!;
      expect(record.draft.fundId, 'fund-pet', reason: '本地改动不能丢');
      expect(record.syncError, '金额必须大于 0');
      expect(record.needsRetry, isFalse);
      expect(result.title, '改动未同步');
      expect(result.body, contains('金额必须大于 0'));
    });

    test('断网时的确认：本地已确认并学习', () async {
      final h = _Harness(trained: false);
      await h.pipeline.handle(_didi());
      h.api.throwOnWrites = true;
      await h.pipeline.confirm('cap-1');
      final record = h.store.captures['cap-1']!;
      expect(record.draft.status, 'confirmed');
      expect(record.decision, CaptureDecision.recorded);
      expect(record.synced, isFalse);
      expect(h.api.confirmed, isEmpty);
    });
  });

  group('confirm / undo', () {
    test('confirm → 调用 confirm 接口并转为 confirmed', () async {
      final h = _Harness(trained: false);
      final out = await h.pipeline.handle(_didi());
      expect(out.decision, CaptureDecision.pending);

      final r = await h.pipeline.confirm('cap-1');
      expect(h.api.confirmed, <String>['tx-1']);
      expect(h.store.captures['cap-1']!.draft.status, 'confirmed');
      expect(h.store.captures['cap-1']!.decision, CaptureDecision.recorded);
      expect(r.title, contains('已确认'));
    });

    test('undo → 删除流水与本地记录', () async {
      final h = _Harness();
      await h.pipeline.handle(_didi());
      final r = await h.pipeline.undo('cap-1');
      expect(h.api.deleted, <String>['tx-1']);
      expect(h.store.captures, isEmpty);
      expect(r.title, contains('已撤销'));
    });

    test('还没同步就撤销 → 留一条作废墓碑，避免 outbox 把它建出来', () async {
      final h = _Harness();
      h.api.throwOnCreate = true;
      await h.pipeline.handle(_didi());
      expect(h.store.captures['cap-1']!.transactionId, isNull);

      final r = await h.pipeline.undo('cap-1');
      expect(h.api.deleted, isEmpty);
      final tomb = h.store.captures['cap-1']!;
      expect(tomb.decision, CaptureDecision.ignored);
      expect(tomb.needsRetry, isFalse);
      expect(r.title, '已撤销');
      expect(r.body, contains('还没同步'));
    });

    test('删除请求断网 → 本地已撤销，等联网重试', () async {
      final h = _Harness();
      await h.pipeline.handle(_didi());
      h.api.throwOnWrites = true;
      final r = await h.pipeline.undo('cap-1');
      expect(h.api.deleted, isEmpty);
      expect(h.store.captures['cap-1']!.decision, CaptureDecision.ignored);
      expect(r.body, contains('重试'));
    });

    test('undo 后同一通知不再被当作重复', () async {
      final h = _Harness();
      await h.pipeline.handle(_didi());
      await h.pipeline.undo('cap-1');
      h.clock = h.clock.add(const Duration(minutes: 1));
      final again = await h.pipeline.handle(_didi());
      expect(again.decision, CaptureDecision.recorded);
    });
  });

  group('bootstrap', () {
    test('无本地模型时用种子训练并落盘', () async {
      final store = FakeStore();
      final api = FakeApi();
      final pipeline = await CapturePipeline.bootstrap(
        store: store,
        api: api,
        config: const CapturePipelineConfig(memberId: 'member-1'),
        categories: _categories,
        funds: _funds,
        accounts: _accounts,
        defaultFundId: 'fund-public',
        defaultAccountId: 'acc-alipay',
      );
      expect(store.models.containsKey(kCategoryModelKey), isTrue);
      final out = await pipeline.handle(_didi());
      expect(out.draft!.categoryId, 'cat-交通');
    });

    test('已有本地模型时直接复用，不重复种子训练', () async {
      final store = FakeStore();
      final seeded = NaiveBayes.empty();
      // 故意和种子给出不同的答案（滴滴出行 → 购物），且够两类够样本才可信
      seeded.learn(NaiveBayes.tokenize('滴滴出行'), 'cat-购物');
      seeded.learn(NaiveBayes.tokenize('滴滴出行'), 'cat-购物');
      seeded.learn(NaiveBayes.tokenize('美团外卖'), 'cat-其他');
      store.models[kCategoryModelKey] = seeded.toJson();

      final pipeline = await CapturePipeline.bootstrap(
        store: store,
        api: FakeApi(),
        config: const CapturePipelineConfig(memberId: 'member-1'),
        categories: _categories,
        funds: _funds,
        accounts: _accounts,
      );
      final out = await pipeline.handle(_didi());
      expect(out.draft!.categoryId, 'cat-购物');
    });
  });

  test('LearnSample 的 JSON 与服务端 /model/learn 的字段一致', () async {
    final h = _Harness();
    await h.pipeline.handle(_didi());
    await h.pipeline.applyQuickReply('cap-1', '宠物基金 宠物');

    expect(h.api.learned, hasLength(1));
    final json = h.api.learned.single.toJson();
    expect(json['text'], '滴滴出行'); // 与本地喂模型的是同一份文本
    expect(json['merchant'], '滴滴出行');
    expect(json['direction'], 'expense');
    expect(json['channel'], 'alipay');
    expect(json['amountCents'], 4500);
    expect(json['hour'], 12);
    expect(json['weekday'], 6);
    expect(json['memberId'], 'member-1');
    expect(json['categoryId'], 'cat-宠物');
    expect(json['fundId'], 'fund-pet');
    expect(json.containsKey('tokens'), isFalse, reason: '服务端自己分词');
  });

  test('默认阈值为 0.75、去重窗口为 10 分钟', () {
    const config = CapturePipelineConfig(memberId: 'm');
    expect(config.threshold, 0.75);
    expect(config.dedupeWindow, const Duration(minutes: 10));
  });
}
