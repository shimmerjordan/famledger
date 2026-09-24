import 'dart:convert';

import 'package:famledger/app/providers.dart';
import 'package:famledger/capture/capture_types.dart';
import 'package:famledger/capture/classifier.dart';
import 'package:famledger/capture/naive_bayes.dart';
import 'package:famledger/capture/parser.dart';
import 'package:famledger/capture/pipeline.dart';
import 'package:famledger/data/api/api_client.dart';
import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/data/local/secure_store.dart';
import 'package:famledger/data/repos/session_repo.dart';
import 'package:famledger/platform/capture_providers.dart';
import 'package:famledger/platform/file_capture_store.dart';
import 'package:famledger/platform/share_import.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_server.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('splitPasted', () {
    test('空行分段；段内换行保留；只有空白的「空行」也算；CRLF 照认', () {
      expect(
        ShareImportService.splitPasted(
          '美团 35 元\n\n滴滴\n快车 23 元\r\n\r\n  \n 喜茶 19 元 \n \t\n\n',
        ),
        ['美团 35 元', '滴滴\n快车 23 元', '喜茶 19 元'],
      );
      expect(ShareImportService.splitPasted('一段　\n　\n两段'), ['一段', '两段']);
      expect(ShareImportService.splitPasted('   \n\n  '), isEmpty);
    });
  });

  group('importPasted', () {
    ShareImportService service(CapturePipeline? pipeline) {
      final s = ShareImportService(
        pipeline: () async => pipeline,
        linkStream: const Stream<Uri>.empty(),
        initialLink: () async => null,
        observeLifecycle: false,
      );
      addTearDown(s.dispose);
      return s;
    }

    test('逐段按顺序喂管线，走剪贴板那条入口；结论只返回、不再进 outcomes', () async {
      final pipeline = _RecordingPipeline();
      final s = service(pipeline);
      final announced = <CaptureOutcome>[];
      s.outcomes.listen(announced.add);

      final entries = await s.importPasted('美团 35 元\n\n滴滴 23 元\n\n\n喜茶 19 元');

      expect(pipeline.seen.map((n) => n.text), [
        '美团 35 元',
        '滴滴 23 元',
        '喜茶 19 元',
      ]);
      expect(pipeline.seen.map((n) => n.packageName).toSet(), {
        'ios.clipboard',
      });
      expect(entries.map((e) => e.text), ['美团 35 元', '滴滴 23 元', '喜茶 19 元']);
      expect(
        entries.every((e) => e.outcome.decision == CaptureDecision.recorded),
        isTrue,
      );
      await pumpEventQueue();
      expect(announced, isEmpty);

      // 单段的 importText 不指定来源也能用，默认照旧广播给界面。
      await s.importText('麦当劳 23 元');
      await pumpEventQueue();
      expect(pipeline.seen.last.packageName, 'ios.clipboard');
      expect(announced, hasLength(1));
    });

    test('真管线：每段各有结论——记下、不是支付、10 分钟内重复', () async {
      final api = _RecordingApi();
      final pipeline = await CapturePipeline.bootstrap(
        store: MemoryCaptureStore(),
        api: api,
        config: const CapturePipelineConfig(memberId: 'm1'),
        categories: const [ClassifierCandidate(id: 'c1', name: '餐饮')],
        funds: const [ClassifierCandidate(id: 'f1', name: '家庭公共')],
        accounts: const [],
        defaultFundId: 'f1',
        now: () => DateTime(2026, 9, 13, 20),
      );
      final entries = await service(
        pipeline,
      ).importPasted('你有一笔35.00元的支出，来自美团\n\n今天天气不错\n\n你有一笔35.00元的支出，来自美团');

      expect(entries.map((e) => e.outcome.decision), [
        anyOf(CaptureDecision.recorded, CaptureDecision.pending),
        CaptureDecision.ignored,
        CaptureDecision.duplicate,
      ]);
      expect(entries[1].outcome.body, '不是支付通知');
      expect(api.created, hasLength(1));
      expect(api.created.single['amountCents'], 3500);
      expect(api.created.single['sourceApp'], 'ios.clipboard');
    });

    test('没登录 / 管线装配失败：每段都给一条结论，不抛', () async {
      final entries = await service(null).importPasted('a 1 元\n\nb 2 元');
      expect(entries.map((e) => e.outcome.title), ['家账还没登录', '家账还没登录']);
    });

    test('同一次粘贴里金额相同、都没写日期的两段都记下：粘贴按 import 来源提交，不吃服务端对通知的查重', () async {
      final api = _DedupingApi();
      final pipeline = await CapturePipeline.bootstrap(
        store: MemoryCaptureStore(),
        api: api,
        config: const CapturePipelineConfig(memberId: 'm1'),
        categories: const [ClassifierCandidate(id: 'c1', name: '餐饮')],
        funds: const [ClassifierCandidate(id: 'f1', name: '家庭公共')],
        accounts: const [],
        defaultFundId: 'f1',
      );
      final s = service(pipeline);

      final entries = await s.importPasted(
        '你有一笔35.00元的支出，来自美团\n\n你有一笔35.00元的支出，来自饿了么',
      );

      expect(
        entries.map((e) => e.outcome.decision),
        everyElement(anyOf(CaptureDecision.recorded, CaptureDecision.pending)),
        reason: entries
            .map((e) => '${e.outcome.title} ${e.outcome.body}')
            .join('；'),
      );
      expect(api.rows, hasLength(2));
      expect(api.rows.map((r) => r['source']), ['import', 'import']);
      expect(
        api.rows.map((r) => r['status']),
        everyElement(isNot('duplicate')),
      );

      // 分享/剪贴板那几条入口照旧按通知记，服务端查重对它们照常生效。
      await s.importText('你有一笔35.00元的支出，来自盒马', source: kShareSourceShare);
      expect(api.rows.last['source'], 'notification');
      expect(api.rows.last['status'], 'duplicate');
    });

    test('建流水没送到（断网）：这段标成没送到；重发用原来的 clientId，送到了就不再是没送到', () async {
      final api = _FlakyApi()..failuresLeft = 1;
      final store = MemoryCaptureStore();
      final pipeline = await CapturePipeline.bootstrap(
        store: store,
        api: api,
        config: const CapturePipelineConfig(memberId: 'm1'),
        categories: const [ClassifierCandidate(id: 'c1', name: '餐饮')],
        funds: const [ClassifierCandidate(id: 'f1', name: '家庭公共')],
        accounts: const [],
        defaultFundId: 'f1',
      );
      final s = service(pipeline);

      final entries = await s.importPasted(
        '你有一笔35.00元的支出，来自美团\n\n你有一笔42.00元的支出，来自滴滴出行',
      );
      expect(entries.map((e) => e.outcome.offline), [true, false]);
      expect(api.created, hasLength(1));
      final lostClientId = entries.first.outcome.draft!.clientId;

      final again = await s.resendPasted(entries);
      expect(again.map((e) => e.outcome.offline), [false, false]);
      expect(again.map((e) => e.text), entries.map((e) => e.text));
      expect(api.created, hasLength(2), reason: '送到过的那段不再发');
      expect(api.created.last['clientId'], lostClientId);
      expect((await store.loadCapture(lostClientId))!.synced, isTrue);

      // 还是不通：原样留着，下次还能重发。
      final stillDown = _FlakyApi()..failuresLeft = 99;
      final p2 = await CapturePipeline.bootstrap(
        store: MemoryCaptureStore(),
        api: stillDown,
        config: const CapturePipelineConfig(memberId: 'm1'),
        categories: const [ClassifierCandidate(id: 'c1', name: '餐饮')],
        funds: const [ClassifierCandidate(id: 'f1', name: '家庭公共')],
        accounts: const [],
      );
      final s2 = service(p2);
      final down = await s2.importPasted('你有一笔35.00元的支出，来自美团');
      final retried = await s2.resendPasted(down);
      expect(retried.single.outcome.offline, isTrue);
      expect(retried.single.outcome.captureId, down.single.outcome.captureId);
    });
  });

  test('打不开本地捕获存储（网页）也能粘贴导入：退到内存存储照样记账', () async {
    final server = FakeServer();
    final secure = MemorySecureStore();
    secure.data[SessionRepo.baseUrlKey] = 'https://x.dev';
    secure.data[SessionRepo.sessionKey] = jsonEncode({
      'baseUrl': 'https://x.dev',
      'token': 'tok',
      'deviceId': 'dev',
      'me': {
        'id': 'm1',
        'username': 'mama',
        'displayName': '妈妈',
        'role': 'admin',
      },
    });
    final session = SessionRepo(secure: secure);
    await session.restore();
    final container = ProviderContainer(
      overrides: [
        localStoreProvider.overrideWithValue(MemoryLocalStore()),
        secureStoreProvider.overrideWithValue(secure),
        sessionRepoProvider.overrideWithValue(session),
        apiProvider.overrideWithValue(
          ApiClient(
            baseUrl: 'https://x.dev',
            token: 'tok',
            inner: server.client,
          ),
        ),
        captureStoreProvider.overrideWith(
          (ref) async => throw UnsupportedError('网页没有文件系统'),
        ),
      ],
    );
    addTearDown(container.dispose);

    final entries = await container
        .read(shareImportProvider)
        .importPasted('你有一笔35.00元的支出，来自美团\n\n你有一笔42.00元的支出，来自滴滴出行');

    expect(
      entries.map((e) => e.outcome.decision),
      everyElement(anyOf(CaptureDecision.recorded, CaptureDecision.pending)),
      reason: entries
          .map((e) => '${e.outcome.title} ${e.outcome.body}')
          .join('；'),
    );
    expect(server.transactions, hasLength(2));
  });

  test('网页上服务端 503：不能冒充「记下」，标成没送到；恢复后重发补上，不重复', () async {
    final server = FakeServer();
    final secure = MemorySecureStore();
    secure.data[SessionRepo.baseUrlKey] = 'https://x.dev';
    secure.data[SessionRepo.sessionKey] = jsonEncode({
      'baseUrl': 'https://x.dev',
      'token': 'tok',
      'deviceId': 'dev',
      'me': {
        'id': 'm1',
        'username': 'mama',
        'displayName': '妈妈',
        'role': 'admin',
      },
    });
    final session = SessionRepo(secure: secure);
    await session.restore();
    final container = ProviderContainer(
      overrides: [
        localStoreProvider.overrideWithValue(MemoryLocalStore()),
        secureStoreProvider.overrideWithValue(secure),
        sessionRepoProvider.overrideWithValue(session),
        apiProvider.overrideWithValue(
          ApiClient(
            baseUrl: 'https://x.dev',
            token: 'tok',
            inner: server.client,
          ),
        ),
        captureStoreProvider.overrideWith(
          (ref) async => throw UnsupportedError('网页没有文件系统'),
        ),
      ],
    );
    addTearDown(container.dispose);
    final service = container.read(shareImportProvider);

    server.statusOverrides['POST /api/v1/transactions'] = 503;
    final entries = await service.importPasted(
      '你有一笔35.00元的支出，来自美团\n\n你有一笔42.00元的支出，来自滴滴出行',
    );
    expect(entries.map((e) => e.outcome.offline), [true, true]);
    expect(server.transactions, isEmpty);

    server.statusOverrides.clear();
    final again = await service.resendPasted(entries);
    expect(again.map((e) => e.outcome.offline), [false, false]);
    expect(server.transactions, hasLength(2));
    expect(
      server.transactions.values.map((t) => t['clientId']).toSet(),
      entries.map((e) => e.outcome.draft!.clientId).toSet(),
    );
    expect(
      server.transactions.values.map((t) => t['source']),
      everyElement('import'),
    );
  });
}

/// 照 server/src/modules/transactions.js 的查重：新记录来源是 notification/share 时，
/// 同类型、同金额、发生时间相差不超过 180 秒的未作废行就算重复。
class _DedupingApi extends _RecordingApi {
  final List<Map<String, dynamic>> rows = [];

  @override
  Future<CaptureApiResult> createTransaction(Map<String, dynamic> body) async {
    final at = DateTime.parse(body['occurredAt'] as String);
    final dedupe = const {
      'notification',
      'share',
    }.contains(body['source'] ?? 'manual');
    final duplicate =
        dedupe &&
        rows.any(
          (r) =>
              r['status'] != 'duplicate' &&
              r['type'] == body['type'] &&
              r['amountCents'] == body['amountCents'] &&
              DateTime.parse(
                    r['occurredAt'] as String,
                  ).difference(at).inSeconds.abs() <=
                  180,
        );
    rows.add({...body, if (duplicate) 'status': 'duplicate'});
    return CaptureApiResult(id: 'tx-${rows.length}', duplicate: duplicate);
  }
}

/// 前 [failuresLeft] 次建流水像断网一样直接抛。
class _FlakyApi extends _RecordingApi {
  int failuresLeft = 0;

  @override
  Future<CaptureApiResult> createTransaction(Map<String, dynamic> body) {
    if (failuresLeft > 0) {
      failuresLeft--;
      throw Exception('Connection refused');
    }
    return super.createTransaction(body);
  }
}

class _RecordingPipeline extends CapturePipeline {
  _RecordingPipeline()
    : super(
        store: MemoryCaptureStore(),
        api: _RecordingApi(),
        classifier: Classifier(
          categoryModel: NaiveBayes.empty(),
          fundModel: NaiveBayes.empty(),
          rules: const <CaptureRule>[],
          categories: const <ClassifierCandidate>[],
          funds: const <ClassifierCandidate>[],
          accounts: const <CaptureAccount>[],
        ),
        config: const CapturePipelineConfig(memberId: 'm1'),
      );

  final List<RawNotification> seen = <RawNotification>[];

  @override
  Future<CaptureOutcome> handle(RawNotification notification) async {
    seen.add(notification);
    return const CaptureOutcome(
      decision: CaptureDecision.recorded,
      title: '已记一笔',
      body: '',
      captureId: 'cap-1',
    );
  }
}

class _RecordingApi implements CaptureApi {
  final List<Map<String, dynamic>> created = [];

  @override
  Future<CaptureApiResult> createTransaction(Map<String, dynamic> body) async {
    created.add(body);
    return CaptureApiResult(id: 'tx-${created.length}');
  }

  @override
  Future<void> patchTransaction(String id, Map<String, dynamic> patch) async {}

  @override
  Future<void> confirmTransaction(String id) async {}

  @override
  Future<void> deleteTransaction(String id) async {}

  @override
  Future<void> learn(List<LearnSample> samples) async {}

  @override
  Future<Map<String, dynamic>?> aiClassify(Map<String, dynamic> input) async =>
      null;
}
