import 'dart:convert';

import 'package:famledger/app/providers.dart';
import 'package:famledger/app/theme.dart';
import 'package:famledger/capture/capture_types.dart';
import 'package:famledger/capture/classifier.dart';
import 'package:famledger/capture/pipeline.dart';
import 'package:famledger/data/api/api_client.dart';
import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/data/local/secure_store.dart';
import 'package:famledger/data/repos/session_repo.dart';
import 'package:famledger/platform/capture_channel.dart';
import 'package:famledger/platform/capture_providers.dart';
import 'package:famledger/platform/file_capture_store.dart';
import 'package:famledger/platform/share_import.dart';
import 'package:famledger/ui/settings/capture_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class FakeCapturePlatform implements CapturePlatform {
  FakeCapturePlatform({
    this.listenerEnabled = false,
    this.permission = NotificationPermission.denied,
    this.allowed = const ['com.eg.android.AlipayGphone', 'com.tencent.mm'],
    this.device = const DeviceInfo(manufacturer: 'Xiaomi', brand: 'Redmi', sdkInt: 33, debug: true),
  });

  bool listenerEnabled;
  NotificationPermission permission;
  List<String> allowed;
  DeviceInfo device;
  int openedListenerSettings = 0;
  int openedAutoStart = 0;
  int requestedPermission = 0;
  int testNotifications = 0;

  @override
  bool get isSupported => true;

  @override
  Stream<String> get openCapture => const Stream.empty();

  @override
  Future<bool> isListenerEnabled() async => listenerEnabled;

  @override
  Future<void> openListenerSettings() async => openedListenerSettings++;

  @override
  Future<String> openAutoStartSettings() async {
    openedAutoStart++;
    return 'miui_autostart';
  }

  @override
  Future<List<String>> getAllowedPackages() async => allowed;

  @override
  Future<void> setAllowedPackages(List<String> packages) async => allowed = packages;

  @override
  Future<List<InstalledApp>> getInstalledApps() async => const [
    InstalledApp(package: 'com.eg.android.AlipayGphone', label: '支付宝'),
    InstalledApp(package: 'com.tencent.mm', label: '微信'),
    InstalledApp(package: 'com.unionpay', label: '云闪付'),
  ];

  @override
  Future<bool> postTestNotification(String title, String text) async {
    testNotifications++;
    return true;
  }

  @override
  Future<NotificationPermission> notificationPermission() async => permission;

  @override
  Future<void> requestNotificationPermission() async => requestedPermission++;

  @override
  Future<DeviceInfo> deviceInfo() async => device;
}

/// 假的分享导入服务：剪贴板里有什么由测试决定。
class FakeShareImport extends ShareImportService {
  FakeShareImport(this.outcome)
    : super(pipeline: () async => null, observeLifecycle: false, deepLinksEnabled: false);

  final CaptureOutcome? outcome;
  int calls = 0;

  @override
  Future<CaptureOutcome?> importFromClipboard() async {
    calls++;
    return outcome;
  }
}

http.Response jsonOk(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

const Map<String, dynamic> changesBody = {
  'since': 0,
  'next': 3,
  'more': false,
  'members': [{'id': 'm1', 'username': 'mama', 'displayName': '妈妈', 'role': 'admin'}],
  'accounts': [{'id': 'a1', 'name': '我的支付宝', 'kind': 'alipay'}],
  'funds': [
    {'id': 'f1', 'name': '家庭公共', 'isDefault': true},
    {'id': 'f2', 'name': '宠物'},
  ],
  'categories': [
    {'id': 'c1', 'name': '餐饮', 'kind': 'expense'},
    {'id': 'c2', 'name': '交通', 'kind': 'expense'},
  ],
  'rules': [],
  'budgets': [],
  'transactions': [],
};

MockClient api({List<http.Request>? seen, double threshold = 0.75}) => MockClient((request) async {
  seen?.add(request);
  final path = request.url.path;
  if (path.endsWith('/changes')) return jsonOk(changesBody);
  if (path.endsWith('/settings')) {
    final patch = request.method == 'PATCH' ? jsonDecode(request.body) as Map<String, dynamic> : const {};
    final capture = <String, dynamic>{
      'defaultFundId': null,
      'defaultAccountId': null,
      'autoConfirmThreshold': threshold,
      'aiTrigger': 'off',
      'aiAutoConfirm': false,
      'aiProviderId': null,
      ...?(patch['capture'] as Map<String, dynamic>?),
    };
    return jsonOk({'name': '测试家庭', 'currency': 'CNY', 'capture': capture, 'ui': {'firstDayOfMonth': 1}});
  }
  if (path.endsWith('/ai/providers')) return jsonOk(const {'items': []});
  return jsonOk(const {});
});

Future<ProviderContainer> boot({
  required CapturePlatform platform,
  required LocalCaptureStore store,
  MockClient? client,
  String role = 'admin',
  ShareImportService? shareImport,
}) async {
  final secure = MemorySecureStore();
  secure.data[SessionRepo.baseUrlKey] = 'https://x.dev';
  secure.data[SessionRepo.sessionKey] = jsonEncode({
    'baseUrl': 'https://x.dev',
    'token': 'tok',
    'deviceId': 'dev',
    'me': {'id': 'm1', 'username': 'mama', 'displayName': '妈妈', 'role': role},
  });
  final repo = SessionRepo(secure: secure);
  await repo.restore();
  return ProviderContainer(
    overrides: [
      localStoreProvider.overrideWithValue(MemoryLocalStore()),
      secureStoreProvider.overrideWithValue(secure),
      sessionRepoProvider.overrideWithValue(repo),
      apiProvider.overrideWithValue(ApiClient(baseUrl: 'https://x.dev', token: 'tok', inner: client ?? api())),
      capturePlatformProvider.overrideWithValue(platform),
      captureStoreProvider.overrideWith((ref) async => store),
      if (shareImport != null) shareImportProvider.overrideWithValue(shareImport),
    ],
  );
}

Future<void> pumpPage(WidgetTester tester, ProviderContainer container) async {
  addTearDown(container.dispose);
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: buildTheme(Brightness.light), home: const CapturePage()),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  // 用内存存储：testWidgets 跑在 FakeAsync 里，真实文件 IO 永远等不到回调。
  late MemoryCaptureStore store;

  setUp(() => store = MemoryCaptureStore());

  testWidgets('权限卡：监听未开启给「去开启」，点了会跳系统设置；MIUI 给保活引导', (tester) async {
    final platform = FakeCapturePlatform();
    await pumpPage(tester, await boot(platform: platform, store: store));

    expect(find.text('通知使用权'), findsOneWidget);
    expect(find.text('未开启 · 系统还不允许家账读取支付通知'), findsOneWidget);
    await tester.tap(find.text('去开启'));
    await tester.pump();
    expect(platform.openedListenerSettings, 1);

    expect(find.text('通知权限'), findsOneWidget);
    await tester.tap(find.text('允许'));
    await tester.pump();
    expect(platform.requestedPermission, 1);

    expect(find.text('后台保活（MIUI）'), findsOneWidget);
    expect(find.text('去设置'), findsOneWidget);
  });

  testWidgets('监听已开启时打勾、没有按钮；允许的应用按名字显示', (tester) async {
    final platform = FakeCapturePlatform(listenerEnabled: true, permission: NotificationPermission.granted);
    await pumpPage(tester, await boot(platform: platform, store: store));

    expect(find.text('去开启'), findsNothing);
    expect(find.byIcon(Icons.check_circle), findsNWidgets(2));
    expect(find.widgetWithText(Chip, '支付宝'), findsOneWidget);
    expect(find.widgetWithText(Chip, '微信'), findsOneWidget);
  });

  testWidgets('阈值滑条取自家庭设置，松手后 PATCH /settings', (tester) async {
    final seen = <http.Request>[];
    await pumpPage(
      tester,
      await boot(platform: FakeCapturePlatform(), store: store, client: api(seen: seen, threshold: 0.8)),
    );

    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.value, closeTo(0.8, 1e-9));
    expect(find.text('80%'), findsOneWidget);
    expect(slider.onChanged, isNotNull, reason: '管理员可以改');

    slider.onChangeEnd!(0.6);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final patch = seen.lastWhere((r) => r.method == 'PATCH');
    expect(patch.url.path, '/api/v1/settings');
    expect(jsonDecode(patch.body), {'capture': {'autoConfirmThreshold': 0.6}});
  });

  testWidgets('非管理员看得到但改不了', (tester) async {
    await pumpPage(tester, await boot(platform: FakeCapturePlatform(), store: store, role: 'member'));
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
    expect(find.text('只有管理员能改识别设置。'), findsOneWidget);
    expect(
      tester.widget<SegmentedButton<String>>(find.byType(SegmentedButton<String>)).onSelectionChanged,
      isNull,
    );
  });

  testWidgets('AI 兜底默认关闭：只有触发方式选择，没有自动入账开关和渠道', (tester) async {
    await pumpPage(tester, await boot(platform: FakeCapturePlatform(), store: store));
    expect(find.text('AI 兜底怎么触发'), findsOneWidget);
    final segmented = tester.widget<SegmentedButton<String>>(find.byType(SegmentedButton<String>));
    expect(segmented.selected, {'off'});
    expect(find.text('AI 结果可以自动入账'), findsNothing);
    expect(find.text('记账兜底用哪个渠道'), findsNothing);
  });

  testWidgets('选「自动」→ PATCH aiTrigger，出现自动入账开关与渠道选择', (tester) async {
    final seen = <http.Request>[];
    await pumpPage(
      tester,
      await boot(platform: FakeCapturePlatform(), store: store, client: api(seen: seen)),
    );

    final segmented = tester.widget<SegmentedButton<String>>(find.byType(SegmentedButton<String>));
    segmented.onSelectionChanged!({'auto'});
    await tester.pumpAndSettle();

    final patch = seen.lastWhere((r) => r.method == 'PATCH');
    expect(jsonDecode(patch.body), {'capture': {'aiTrigger': 'auto'}});
    expect(find.text('AI 结果可以自动入账'), findsOneWidget);
    expect(find.text('记账兜底用哪个渠道'), findsOneWidget);

    final autoConfirm = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'AI 结果可以自动入账'),
    );
    expect(autoConfirm.value, isFalse);
    autoConfirm.onChanged!(true);
    await tester.pumpAndSettle();
    final second = seen.lastWhere((r) => r.method == 'PATCH');
    expect(jsonDecode(second.body), {'capture': {'aiAutoConfirm': true}});
  });

  testWidgets('最近识别情况：有样本才显示，样本不够写「样本还不够」', (tester) async {
    await store.saveModel(kAccuracyModelKey, {
      'nb': [for (var i = 0; i < 25; i++) i >= 5], // 5 次未命中 + 20 次命中 = 80%
      'ai': List<bool>.filled(5, true),
    });
    await pumpPage(tester, await boot(platform: FakeCapturePlatform(), store: store));
    expect(find.text('最近识别情况'), findsOneWidget);
    expect(find.textContaining('80% 准'), findsOneWidget); // 20/25
    expect(find.textContaining('样本还不够（5/20）'), findsOneWidget); // ai 只有 5 条
    expect(find.text('本地规则'), findsNothing); // rule 桶一条没有，不显示这一行
  });

  testWidgets('没有任何识别记录时不显示「最近识别情况」', (tester) async {
    await pumpPage(tester, await boot(platform: FakeCapturePlatform(), store: store));
    expect(find.text('最近识别情况'), findsNothing);
  });

  testWidgets('最近捕获：显示日志与结论芯片；空态有说明', (tester) async {
    await store.appendLog(
      CaptureLogEntry(
        at: DateTime.now(),
        package: 'com.eg.android.AlipayGphone',
        title: '支付宝 −¥35.00 · 餐饮 → 家庭公共',
        body: '92% 可信 · 美团',
        decision: 'recorded',
        captureId: 'cap-1',
        transactionId: 't1',
      ),
    );
    await pumpPage(tester, await boot(platform: FakeCapturePlatform(), store: store));
    expect(find.text('支付宝 −¥35.00 · 餐饮 → 家庭公共'), findsOneWidget);
    expect(find.text('已入账'), findsOneWidget);
    expect(find.text('还没有捕获记录'), findsNothing);
  });

  testWidgets('测试解析：粘贴通知 → 解析出金额、商户与结论', (tester) async {
    await pumpPage(tester, await boot(platform: FakeCapturePlatform(), store: store));

    await tester.enterText(find.widgetWithText(TextField, '通知正文'), '你有一笔35.00元的支出，来自美团');
    await tester.tap(find.text('解析'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('¥35.00'), findsOneWidget);
    expect(find.text('美团'), findsOneWidget);
    expect(find.textContaining('支付宝 −¥35.00'), findsOneWidget);
    expect(find.text('餐饮'), findsWidgets);
  });

  testWidgets('iOS / Web：只给说明与识别设置，没有权限卡', (tester) async {
    await pumpPage(
      tester,
      await boot(platform: const UnsupportedCapturePlatform(), store: store),
    );
    expect(find.text('iOS 不能读取其他应用的通知'), findsOneWidget);
    expect(find.text('通知使用权'), findsNothing);
    expect(find.text('允许的应用'), findsNothing);
    expect(find.byType(Slider), findsOneWidget);
  });

  group('iOS 剪贴板导入', () {
    // 平台覆盖必须在测试体结束前复原（binding 会在 tearDown 之前检查这些全局量）。
    testWidgets('剪贴板是空的 → 提示，不出结果面板', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final share = FakeShareImport(null);
      await pumpPage(
        tester,
        await boot(platform: const UnsupportedCapturePlatform(), store: store, shareImport: share),
      );
      expect(find.text('iOS 不能读取其他应用的通知'), findsOneWidget);
      expect(find.text('从剪贴板导入'), findsOneWidget);
      expect(find.textContaining('docs/ios.md'), findsOneWidget);

      await tester.tap(find.text('从剪贴板导入'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(share.calls, 1);
      expect(find.text('剪贴板是空的'), findsOneWidget);
      expect(find.text('打开'), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('导入成功 → 显示结论与标题，有流水 id 就给「打开」', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await store.saveCapture(
        CaptureRecord(
          captureId: 'cap-1',
          decision: CaptureDecision.recorded,
          draft: CaptureDraft(
            clientId: 'cap-1',
            type: 'expense',
            amountCents: 3500,
            occurredAt: DateTime(2026, 9, 12, 12, 30),
            memberId: 'm1',
            merchant: '美团',
            status: 'confirmed',
            confidence: 0.92,
            rawText: '你有一笔35.00元的支出，来自美团',
            sourceApp: 'ios.clipboard',
            captureId: 'cap-1',
          ),
          dedupeHash: 'h',
          learnText: '美团',
          features: const CaptureFeatures(hour: 12, weekday: 5),
          createdAt: DateTime(2026, 9, 12, 12, 30),
          transactionId: 't1',
          synced: true,
        ),
      );
      final share = FakeShareImport(
        const CaptureOutcome(
          decision: CaptureDecision.recorded,
          title: '剪贴板 −¥35.00 · 餐饮 → 家庭公共',
          body: '92% 可信 · 美团 · 点击修改',
          captureId: 'cap-1',
        ),
      );
      await pumpPage(
        tester,
        await boot(platform: const UnsupportedCapturePlatform(), store: store, shareImport: share),
      );
      await tester.tap(find.text('从剪贴板导入'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('剪贴板 −¥35.00 · 餐饮 → 家庭公共'), findsOneWidget);
      expect(find.text('92% 可信 · 美团 · 点击修改'), findsOneWidget);
      expect(find.text('已入账'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '打开'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
