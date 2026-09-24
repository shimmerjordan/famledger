import 'dart:async';
import 'dart:convert';

import 'package:famledger/app/providers.dart';
import 'package:famledger/app/router.dart';
import 'package:famledger/app/theme.dart';
import 'package:famledger/capture/capture_types.dart';
import 'package:famledger/capture/classifier.dart';
import 'package:famledger/capture/naive_bayes.dart';
import 'package:famledger/capture/parser.dart';
import 'package:famledger/capture/pipeline.dart';
import 'package:famledger/data/api/api_client.dart';
import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/data/local/secure_store.dart';
import 'package:famledger/data/models/models.dart';
import 'package:famledger/data/repos/import_repo.dart';
import 'package:famledger/data/repos/ledger_repo.dart';
import 'package:famledger/data/repos/session_repo.dart';
import 'package:famledger/platform/file_capture_store.dart';
import 'package:famledger/platform/share_import.dart';
import 'package:famledger/ui/import/import_page.dart';
import 'package:famledger/ui/import/import_preview_page.dart';
import 'package:famledger/ui/import/import_providers.dart';
import 'package:famledger/ui/import/paste_import_page.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const LedgerData ledgerData = LedgerData(
  funds: [Fund(id: 'f1', name: '家庭公共', isDefault: true)],
  categories: [Category(id: 'c1', name: '餐饮', icon: 'restaurant')],
  accounts: [Account(id: 'a1', name: '支付宝', kind: 'alipay')],
  members: [Member(id: 'm1', username: 'mama', displayName: '妈妈')],
);

class FakeLedger extends LedgerController {
  @override
  Future<LedgerData> build() async => ledgerData;

  @override
  Future<void> sync({bool full = false}) async {}
}

Map<String, dynamic> previewJson() => {
  'source': 'wechat',
  'sourceLabel': '微信账单',
  'total': 2,
  'importable': 2,
  'skipped': 0,
  'rows': [
    for (final n in [1, 2])
      {
        'row': n,
        'clientId': 'imp-$n',
        'type': 'expense',
        'amountCents': 1200 * n,
        'occurredAt': '2026-09-1${n}T08:15:00+08:00',
        'merchant': '早餐店$n',
        'note': '',
        'rawCategory': '商户消费',
        'categoryId': null,
        'fundId': null,
        'accountId': null,
        'confidence': null,
        'skip': null,
        'exists': false,
        'duplicateOf': null,
        'hint': null,
      },
  ],
};

/// 按一段文字里的关键词给结论，免得测试依赖真解析器的细节。
class ScriptedPipeline extends CapturePipeline {
  ScriptedPipeline()
    : super(
        store: MemoryCaptureStore(),
        api: _NoopApi(),
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

  final List<String> seen = [];
  final List<String> resent = [];
  bool networkBack = false;

  static final CaptureDraft _draft = CaptureDraft(
    clientId: 'cap-3',
    type: 'expense',
    amountCents: 5800,
    occurredAt: DateTime.now(),
    memberId: 'm1',
    status: 'confirmed',
    confidence: 0.9,
    rawText: '',
    sourceApp: 'ios.clipboard',
    captureId: 'cap-3',
  );

  @override
  Future<CaptureOutcome> handle(RawNotification notification) async {
    seen.add(notification.text);
    final text = notification.text;
    if (text.contains('美团')) {
      return const CaptureOutcome(
        decision: CaptureDecision.recorded,
        title: '−¥35.00 · 餐饮 → 家庭公共',
        body: '92% 可信 · 美团',
        captureId: 'cap-1',
      );
    }
    if (text.contains('全家')) {
      return CaptureOutcome(
        decision: CaptureDecision.recorded,
        title: '−¥58.00 · 餐饮',
        body: '90% 可信 · 全家',
        captureId: 'cap-3',
        draft: _draft,
        offline: true,
      );
    }
    if (text.contains('滴滴')) {
      return const CaptureOutcome(
        decision: CaptureDecision.pending,
        title: '−¥23.00 · 待确认',
        body: '拿不准类别',
        captureId: 'cap-2',
      );
    }
    return const CaptureOutcome(
      decision: CaptureDecision.ignored,
      title: '没认出来',
      body: '不是支付通知',
    );
  }

  @override
  Future<CaptureOutcome?> resend(String captureId) async {
    resent.add(captureId);
    return CaptureOutcome(
      decision: CaptureDecision.recorded,
      title: '−¥58.00 · 餐饮',
      body: '90% 可信 · 全家',
      captureId: captureId,
      draft: _draft,
      offline: !networkBack,
    );
  }
}

class _NoopApi implements CaptureApi {
  @override
  Future<CaptureApiResult> createTransaction(Map<String, dynamic> body) async =>
      const CaptureApiResult(id: 'tx');

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

/// 真管线用的假服务端：送到的依次给 tx-1、tx-2…；[reject] 非空就按 4xx 拒收。
class _CountingApi extends _NoopApi {
  _CountingApi({this.reject});

  final String? reject;
  int _n = 0;

  @override
  Future<CaptureApiResult> createTransaction(Map<String, dynamic> body) async {
    final message = reject;
    if (message != null) {
      throw CaptureApiException(400, 'invalid_categoryId', message);
    }
    return CaptureApiResult(id: 'tx-${++_n}');
  }
}

CapturePipeline realPipeline({String? reject}) => CapturePipeline(
  store: MemoryCaptureStore(),
  api: _CountingApi(reject: reject),
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

class Harness {
  final List<http.Request> seen = [];
  final List<Uri> opened = [];

  /// 给了就用真管线（真解析器、真正文），不用按关键词给结论的 [pipeline]。
  CapturePipeline? real;
  PickedImportFile? picked;
  Object? pickError;
  FutureOr<http.Response> Function()? previewResponse;
  final ScriptedPipeline pipeline = ScriptedPipeline();
  late GoRouter router;

  late final MockClient client = MockClient((request) async {
    seen.add(request);
    if (request.url.path.endsWith('/import/preview')) {
      return await previewResponse?.call() ??
          http.Response(
            jsonEncode(previewJson()),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
    }
    if (request.url.path.endsWith('/transactions/batch')) {
      final items = (jsonDecode(request.body)['items'] as List)
          .cast<Map<String, dynamic>>();
      return http.Response(
        jsonEncode({
          'results': [
            for (final item in items)
              {
                'clientId': item['clientId'],
                'id': 'tx-${item['clientId']}',
                'status': 'created',
              },
          ],
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    return http.Response('{}', 404);
  });

  List<http.Request> get previews => [
    for (final r in seen)
      if (r.url.path.endsWith('/import/preview')) r,
  ];
}

Future<SessionRepo> loggedInSession(MemorySecureStore secure) async {
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
  return session;
}

Future<List<Override>> overridesFor(WidgetTester tester, Harness h) async {
  final secure = MemorySecureStore();
  final session = await loggedInSession(secure);
  final share = ShareImportService(
    pipeline: () async => h.real ?? h.pipeline,
    linkStream: const Stream<Uri>.empty(),
    initialLink: () async => null,
    observeLifecycle: false,
  );
  addTearDown(share.dispose);
  return [
    localStoreProvider.overrideWithValue(MemoryLocalStore()),
    secureStoreProvider.overrideWithValue(secure),
    sessionRepoProvider.overrideWithValue(session),
    ledgerProvider.overrideWith(FakeLedger.new),
    importRepoProvider.overrideWithValue(
      ImportRepo(
        ApiClient(baseUrl: 'https://x.dev', token: 'tok', inner: h.client),
      ),
    ),
    importFilePickerProvider.overrideWithValue(() async {
      final error = h.pickError;
      if (error != null) throw error;
      return h.picked;
    }),
    importUrlOpenerProvider.overrideWithValue((uri) async {
      h.opened.add(uri);
      return true;
    }),
    shareImportProvider.overrideWithValue(share),
  ];
}

void setSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 和 app 路由里导入那一段同形：/import 下挂 preview 与 paste。
Future<Harness> pumpImport(
  WidgetTester tester, {
  String initial = '/import',
  Size size = const Size(400, 900),
  Harness? harness,
}) async {
  final h = harness ?? Harness();
  setSize(tester, size);
  final router = GoRouter(
    initialLocation: initial,
    routes: [
      GoRoute(
        path: '/import',
        builder: (context, state) => const ImportPage(),
        routes: [
          GoRoute(
            path: 'preview',
            builder: (context, state) => const ImportPreviewRoute(),
          ),
          GoRoute(
            path: 'paste',
            builder: (context, state) => const PasteImportPage(),
          ),
        ],
      ),
      GoRoute(
        path: '/transactions',
        builder: (context, state) =>
            const Scaffold(body: Center(child: Text('账单列表'))),
        routes: [
          GoRoute(
            path: ':id',
            builder: (context, state) =>
                Scaffold(body: Text('流水 ${state.pathParameters['id']}')),
          ),
        ],
      ),
    ],
  );
  addTearDown(router.dispose);
  h.router = router;
  await tester.pumpWidget(
    ProviderScope(
      overrides: await overridesFor(tester, h),
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

PickedImportFile file(String name, [List<int>? bytes]) => PickedImportFile(
  name: name,
  bytes: Uint8List.fromList(bytes ?? utf8.encode('交易时间,收/支,当前状态\n')),
);

String? errorText(WidgetTester tester) {
  final finder = find.byKey(const ValueKey('import-error'));
  if (finder.evaluate().isEmpty) return null;
  return tester.widget<Text>(finder).data;
}

void main() {
  group('选文件', () {
    testWidgets('选好文件就 base64 发去预览，然后进核对页', (tester) async {
      final h = Harness()..picked = file('微信支付账单.xlsx', [1, 2, 3, 250]);
      await pumpImport(tester, harness: h);

      await tester.tap(find.byKey(const ValueKey('import-pick')));
      await tester.pumpAndSettle();

      final body = jsonDecode(h.previews.single.body) as Map<String, dynamic>;
      expect(body['filename'], '微信支付账单.xlsx');
      expect(base64Decode(body['data'] as String), [1, 2, 3, 250]);
      expect(find.text('核对导入'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('import-summary'))).data,
        '微信账单共 2 笔，都能导。',
      );
      expect(find.text('导入 2 笔'), findsOneWidget);

      // 返回选文件页还在，可以接着换一个文件。
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('import-pick')), findsOneWidget);
    });

    testWidgets('大写扩展名也认', (tester) async {
      final h = Harness()..picked = file('ALIPAY.CSV');
      await pumpImport(tester, harness: h);
      await tester.tap(find.byKey(const ValueKey('import-pick')));
      await tester.pumpAndSettle();
      expect(h.previews, hasLength(1));
    });

    testWidgets('不是 csv/xlsx、太大、没选：都不发请求', (tester) async {
      final h = Harness()..picked = file('账单.pdf');
      await pumpImport(tester, harness: h);

      await tester.tap(find.byKey(const ValueKey('import-pick')));
      await tester.pumpAndSettle();
      expect(errorText(tester), contains('只认 csv 和 xlsx'));

      h.picked = PickedImportFile(
        name: 'big.csv',
        bytes: Uint8List(ImportRepo.maxFileBytes + 1),
      );
      await tester.tap(find.byKey(const ValueKey('import-pick')));
      await tester.pumpAndSettle();
      expect(errorText(tester), contains('文件太大了'));

      h.picked = null;
      await tester.tap(find.byKey(const ValueKey('import-pick')));
      await tester.pumpAndSettle();
      expect(errorText(tester), isNull, reason: '取消选择不算错');

      h.pickError = Exception('权限被拒');
      await tester.tap(find.byKey(const ValueKey('import-pick')));
      await tester.pumpAndSettle();
      expect(errorText(tester), contains('打不开文件'));

      expect(h.previews, isEmpty);
      expect(find.text('核对导入'), findsNothing);
    });

    testWidgets('服务端认不出：把它的中文说明摆在按钮下面，留在这页', (tester) async {
      final h = Harness()
        ..picked = file('random.csv')
        ..previewResponse = () => http.Response(
          jsonEncode({
            'error': {
              'code': 'unsupported_file',
              'message': '认不出这个表格：支持支付宝账单、微信账单和通用模板',
            },
          }),
          400,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      await pumpImport(tester, harness: h);

      await tester.tap(find.byKey(const ValueKey('import-pick')));
      await tester.pumpAndSettle();
      expect(errorText(tester), '认不出这个表格：支持支付宝账单、微信账单和通用模板');
      expect(find.text('核对导入'), findsNothing);
    });

    testWidgets('认出来了但一笔交易都没有', (tester) async {
      final h = Harness()
        ..picked = file('empty.csv')
        ..previewResponse = () => http.Response(
          jsonEncode({
            'source': 'alipay',
            'sourceLabel': '支付宝账单',
            'total': 0,
            'importable': 0,
            'skipped': 0,
            'rows': <Object>[],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      await pumpImport(tester, harness: h);

      await tester.tap(find.byKey(const ValueKey('import-pick')));
      await tester.pumpAndSettle();
      expect(errorText(tester), '认出是支付宝账单，但里面一笔交易都没有');
    });
  });

  testWidgets('下载模板打开 {baseUrl}/api/v1/import/template.csv', (tester) async {
    final h = await pumpImport(tester);
    await tester.tap(find.text('下载模板'));
    await tester.pumpAndSettle();
    expect(h.opened, [Uri.parse('https://x.dev/api/v1/import/template.csv')]);
  });

  testWidgets('网页刷新后直接落在核对页：没有预览就请人回去选文件', (tester) async {
    await pumpImport(tester, initial: '/import/preview');
    expect(find.text('没有要核对的账单'), findsOneWidget);
    await tester.tap(find.text('去选文件'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('import-pick')), findsOneWidget);
  });

  testWidgets('离开导入这几页，传给核对页的那份预览就丢掉（浏览器后退回来不会再摆出那批）', (tester) async {
    final h = Harness()..picked = file('wechat.xlsx');
    await pumpImport(tester, harness: h);
    await tester.tap(find.byKey(const ValueKey('import-pick')));
    await tester.pumpAndSettle();
    expect(find.byType(ImportPreviewPage), findsOneWidget);

    h.router.go('/transactions');
    await tester.pumpAndSettle();
    h.router.go('/import/preview');
    await tester.pumpAndSettle();
    expect(find.byType(ImportPreviewPage), findsNothing);
    expect(find.text('没有要核对的账单'), findsOneWidget);
  });

  group('粘贴导入', () {
    testWidgets('空行分段，一段一笔；每段各给结论，顶上一句汇总', (tester) async {
      final h = await pumpImport(tester);
      await tester.tap(find.text('粘贴导入'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('paste-run')));
      await tester.pumpAndSettle();
      expect(find.text('先粘点东西进来'), findsOneWidget);
      expect(h.pipeline.seen, isEmpty);

      await tester.enterText(
        find.byKey(const ValueKey('paste-text')),
        '你有一笔35.00元的支出，来自美团\n\n滴滴出行\n快车 23.00 元\n\n\n今天天气不错',
      );
      await tester.pump();
      expect(find.text('分成了 3 段，一段记一笔'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('paste-run')));
      await tester.pumpAndSettle();

      expect(h.pipeline.seen, [
        '你有一笔35.00元的支出，来自美团',
        '滴滴出行\n快车 23.00 元',
        '今天天气不错',
      ]);
      expect(find.text('记下 1 笔，1 笔待确认，1 段没认出来'), findsOneWidget);
      expect(find.text('−¥35.00 · 餐饮 → 家庭公共'), findsOneWidget);
      expect(find.text('−¥23.00 · 待确认'), findsOneWidget);
      expect(find.text('不是支付通知'), findsOneWidget);
      // 每条结论下面带上原文，多行压成一行。
      expect(find.text('滴滴出行 快车 23.00 元'), findsOneWidget);

      await tester.tap(find.text('去看账单'));
      await tester.pumpAndSettle();
      expect(find.text('账单列表'), findsOneWidget);
    });

    testWidgets('没送到服务器的段单独标出来，不算「记下」；点重发补上', (tester) async {
      final h = await pumpImport(tester);
      await tester.tap(find.text('粘贴导入'));
      await tester.pumpAndSettle();
      expect(find.textContaining('没写日期的按今天记'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('paste-text')),
        '你有一笔35.00元的支出，来自美团\n\n全家 58.00 元',
      );
      await tester.tap(find.byKey(const ValueKey('paste-run')));
      await tester.pumpAndSettle();
      expect(find.text('记下 1 笔，1 笔没送到'), findsOneWidget);
      expect(find.text('没送到服务器，还没记上'), findsOneWidget);
      expect(find.textContaining('日期：今天'), findsOneWidget);

      // 网还没好：照旧标着没送到，按钮还在。
      await tester.tap(find.byKey(const ValueKey('paste-resend')));
      await tester.pumpAndSettle();
      expect(h.pipeline.resent, ['cap-3']);
      expect(find.text('记下 1 笔，1 笔没送到'), findsOneWidget);

      h.pipeline.networkBack = true;
      await tester.tap(find.byKey(const ValueKey('paste-resend')));
      await tester.pumpAndSettle();
      expect(h.pipeline.resent, ['cap-3', 'cap-3'], reason: '送到过的那段不再发');
      expect(find.text('记下 2 笔'), findsOneWidget);
      expect(find.text('没送到服务器，还没记上'), findsNothing);
      expect(find.byKey(const ValueKey('paste-resend')), findsNothing);
    });

    testWidgets('结果行不照搬通知的「点击修改」；送到了的整行点开那笔流水', (tester) async {
      final h = Harness()..real = realPipeline();
      await pumpImport(tester, harness: h);
      await tester.tap(find.text('粘贴导入'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('paste-text')),
        '你有一笔35.00元的支出，来自美团\n\n您尾号1234的卡消费58.00元',
      );
      await tester.tap(find.byKey(const ValueKey('paste-run')));
      await tester.pumpAndSettle();

      expect(find.textContaining('点击修改'), findsNothing);
      expect(find.textContaining('点击打开处理'), findsNothing);
      expect(find.textContaining('点这一行修改'), findsNWidgets(2));
      expect(find.textContaining('美团 · 点这一行修改'), findsOneWidget);

      await tester.tap(find.textContaining('美团 · 点这一行修改'));
      await tester.pumpAndSettle();
      expect(find.text('流水 tx-1'), findsOneWidget);
    });

    testWidgets('服务端拒收的那段：说没记上要手动补，不写「点击打开处理」，也不装作能点', (tester) async {
      final h = Harness()..real = realPipeline(reject: '类别不存在');
      await pumpImport(tester, harness: h);
      await tester.tap(find.text('粘贴导入'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('paste-text')),
        '你有一笔35.00元的支出，来自美团',
      );
      await tester.tap(find.byKey(const ValueKey('paste-run')));
      await tester.pumpAndSettle();

      expect(find.text('记账未成功'), findsOneWidget);
      expect(find.text('类别不存在 · 没记上，要手动记一笔'), findsOneWidget);
      expect(find.textContaining('点击打开处理'), findsNothing);
      expect(find.byType(InkWell).evaluate().where((e) {
        final key = e.widget.key;
        return key is ValueKey<String> && key.value.startsWith('paste-entry-');
      }), isEmpty);
    });

    testWidgets('读不到剪贴板（浏览器不让）和剪贴板真是空的，说法不一样', (tester) async {
      await pumpImport(tester);
      await tester.tap(find.text('粘贴导入'));
      await tester.pumpAndSettle();

      Object? clip;
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method != 'Clipboard.getData') return null;
        final value = clip;
        if (value is Exception) throw value;
        return value;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );

      clip = PlatformException(code: 'paste_fail');
      await tester.tap(find.text('从剪贴板粘贴'));
      await tester.pumpAndSettle();
      expect(find.text('剪贴板是空的'), findsNothing);
      expect(find.textContaining('读不到剪贴板，直接在框里'), findsOneWidget);

      clip = {'text': '  '};
      await tester.tap(find.text('从剪贴板粘贴'));
      await tester.pumpAndSettle();
      expect(find.text('剪贴板是空的'), findsOneWidget);

      clip = {'text': '你有一笔35.00元的支出，来自美团'};
      await tester.tap(find.text('从剪贴板粘贴'));
      await tester.pumpAndSettle();
      expect(find.text('剪贴板是空的'), findsNothing);
      expect(find.text('分成了 1 段，一段记一笔'), findsOneWidget);
    });
  });

  testWidgets('卡在服务端请求体上限上的文件（恰好 6MB）本地就拦下，不去吃 413', (tester) async {
    final h = Harness()
      ..picked = PickedImportFile(
        name: 'big.csv',
        bytes: Uint8List(6 * 1024 * 1024),
      );
    await pumpImport(tester, harness: h);
    await tester.tap(find.byKey(const ValueKey('import-pick')));
    await tester.pumpAndSettle();
    expect(errorText(tester), contains('文件太大了'));
    expect(h.previews, isEmpty);

    // base64 加 JSON 外壳正好压在 8MB 以内的照发。
    h.picked = PickedImportFile(name: 'ok.csv', bytes: Uint8List(6291432));
    await tester.tap(find.byKey(const ValueKey('import-pick')));
    await tester.pumpAndSettle();
    expect(h.previews, hasLength(1));
    expect(
      h.previews.single.bodyBytes.length,
      lessThanOrEqualTo(8 * 1024 * 1024),
    );
  });

  testWidgets('服务端还在读文件时，粘贴导入和下载模板点不了；读完不会把核对页叠到别的页上', (tester) async {
    final gate = Completer<http.Response>();
    final h = Harness()
      ..picked = file('wechat.xlsx')
      ..previewResponse = () => gate.future;
    await pumpImport(tester, harness: h);

    await tester.tap(find.byKey(const ValueKey('import-pick')));
    await tester.pump();
    expect(find.text('正在读…'), findsOneWidget);
    ButtonStyleButton button(String label) => tester.widget<ButtonStyleButton>(
      find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      ),
    );
    expect(button('粘贴导入').enabled, isFalse);
    expect(button('下载模板').enabled, isFalse);

    // 浏览器地址栏之类的办法还是能走开：预览回来时这页已经不在最上面，就别跳。
    h.router.push('/import/paste');
    await tester.pumpAndSettle();
    gate.complete(
      http.Response(
        jsonEncode(previewJson()),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PasteImportPage), findsOneWidget);
    expect(find.byType(ImportPreviewPage), findsNothing);
    expect(h.router.state.matchedLocation, '/import/paste');

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(button('粘贴导入').enabled, isTrue);
  });

  testWidgets('导完点「再导一个」，之后再进核对页（浏览器前进）不会把刚导过的那批再摆出来', (tester) async {
    final h = Harness()..picked = file('wechat.xlsx');
    await pumpImport(tester, harness: h);
    await tester.tap(find.byKey(const ValueKey('import-pick')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('import-submit')));
    await tester.pumpAndSettle();
    expect(find.text('导入好了'), findsOneWidget, reason: '结果页自己拿着那份预览，不受清空影响');

    await tester.tap(find.text('再导一个'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('import-pick')), findsOneWidget);

    h.router.go('/import/preview');
    await tester.pumpAndSettle();
    expect(find.byType(ImportPreviewPage), findsNothing);
    expect(find.text('没有要核对的账单'), findsOneWidget);
  });

  for (final width in [400.0, 800.0, 1400.0]) {
    testWidgets('宽 $width：选文件页（带报错）和粘贴结果都不溢出', (tester) async {
      final h = Harness()..picked = file('很长很长很长很长很长很长很长很长很长的文件名.numbers');
      await pumpImport(tester, harness: h, size: Size(width, 900));
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('import-pick')));
      await tester.pumpAndSettle();
      expect(errorText(tester), isNotNull);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('粘贴导入'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('paste-text')),
        '${'你有一笔35.00元的支出，来自美团外卖平台的某某某某某某餐厅' * 3}\n\n滴滴 23 元\n\n今天天气不错'
        '\n\n全家便利店 58 元',
      );
      await tester.tap(find.byKey(const ValueKey('paste-run')));
      await tester.pumpAndSettle();
      expect(find.text('记下 1 笔，1 笔待确认，1 笔没送到，1 段没认出来'), findsOneWidget);
      expect(find.byKey(const ValueKey('paste-resend')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('宽屏上鼠标停在两侧空白处，选文件页照样能用滚轮滚', (tester) async {
    await pumpImport(tester, size: const Size(1400, 400));
    final list = find
        .descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        )
        .first;
    final position = tester.state<ScrollableState>(list).position;
    expect(position.maxScrollExtent, greaterThan(0));
    expect(
      tester.getTopLeft(find.text('从表格导入')).dx,
      (1400 - 720) / 2 + LedgerLayout.widePagePadding,
    );
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    pointer.hover(const Offset(40, 200));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 200)));
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
  });

  group('接进 app 路由', () {
    Future<ProviderContainer> boot(WidgetTester tester, Harness h) async {
      final container = ProviderContainer(
        overrides: await overridesFor(tester, h),
      );
      addTearDown(container.dispose);
      setSize(tester, const Size(400, 900));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            theme: buildTheme(Brightness.light),
            routerConfig: container.read(routerProvider),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('设置页「导入账单」进 /import，粘贴导入是 /import/paste', (tester) async {
      final h = Harness();
      final container = await boot(tester, h);

      await tester.tap(find.text('我的').last);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('导入账单'),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.text('导入账单'));
      await tester.pumpAndSettle();
      expect(find.byType(ImportPage), findsOneWidget);
      final router = container.read(routerProvider);
      expect(router.state.matchedLocation, '/import');

      await tester.tap(find.text('粘贴导入'));
      await tester.pumpAndSettle();
      expect(find.byType(PasteImportPage), findsOneWidget);
      expect(router.state.matchedLocation, '/import/paste');
    });

    testWidgets('账单页顶栏的「导入」按钮进 /import，选文件能走到 /import/preview，返回回到账单页', (
      tester,
    ) async {
      final h = Harness()..picked = file('alipay.csv');
      final container = await boot(tester, h);
      final router = container.read(routerProvider);

      router.go('/transactions');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('导入'));
      await tester.pumpAndSettle();
      expect(find.byType(ImportPage), findsOneWidget);
      expect(router.state.matchedLocation, '/import');

      await tester.tap(find.byKey(const ValueKey('import-pick')));
      await tester.pumpAndSettle();
      expect(find.byType(ImportPreviewPage), findsOneWidget);
      expect(router.state.matchedLocation, '/import/preview');

      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(router.state.matchedLocation, '/transactions');
    });
  });
}
