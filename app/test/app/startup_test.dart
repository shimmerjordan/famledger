import 'dart:async';
import 'dart:convert';

import 'package:famledger/app/providers.dart';
import 'package:famledger/app/router.dart';
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
import 'package:famledger/platform/perk_notifications.dart';
import 'package:famledger/platform/share_import.dart';
import 'package:famledger/ui/assets/asset_providers.dart';
import 'package:famledger/ui/perks/perk_alert_tile.dart';
import 'package:famledger/ui/transactions/tx_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../platform/perk_fake_scheduler.dart';

/// 只替掉「启动」和「结论流」：start() 记次数，结论由测试往 [feed] 里塞。
class FakeShareImport extends ShareImportService {
  FakeShareImport()
    : super(
        pipeline: () async => null,
        deepLinksEnabled: false,
        observeLifecycle: false,
      );

  int started = 0;
  final StreamController<CaptureOutcome> feed =
      StreamController<CaptureOutcome>.broadcast();

  @override
  Stream<CaptureOutcome> get outcomes => feed.stream;

  @override
  Future<void> start() async => started++;
}

CaptureRecord record(String captureId, {String? transactionId}) => CaptureRecord(
  captureId: captureId,
  decision: CaptureDecision.recorded,
  draft: CaptureDraft(
    clientId: captureId,
    type: 'expense',
    amountCents: 3500,
    occurredAt: DateTime(2026, 9, 12, 12, 30),
    memberId: 'm1',
    merchant: '美团',
    status: 'confirmed',
    confidence: 0.9,
    rawText: '你有一笔35.00元的支出，来自美团',
    sourceApp: 'ios.share',
    captureId: captureId,
  ),
  dedupeHash: 'hash-$captureId',
  learnText: '美团',
  features: const CaptureFeatures(hour: 12, weekday: 5),
  createdAt: DateTime(2026, 9, 12, 12, 30),
  transactionId: transactionId,
);

/// 只认详情页要的那一条流水，其余接口一律给空对象（模型都宽容解析）。
http.Client api() => MockClient((req) async {
  final path = req.url.path;
  Object body = const <String, dynamic>{};
  if (req.method == 'GET' && path == '/api/v1/transactions/t1') {
    body = {
      'transaction': {
        'id': 't1',
        'clientId': 'cap1',
        'type': 'expense',
        'amountCents': 3500,
        'occurredAt': '2026-09-12T12:30:00+08:00',
        'status': 'confirmed',
        'merchant': '美团',
      },
    };
  }
  return http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
});

({ProviderContainer container, FakeShareImport share, int Function() platformReads})
boot({required bool loggedIn, LocalCaptureStore? store, PerkNotificationScheduler? scheduler, DateTime Function()? clock}) {
  final secure = MemorySecureStore();
  secure.data[SessionRepo.baseUrlKey] = 'https://x.dev';
  if (loggedIn) {
    secure.data[SessionRepo.sessionKey] = jsonEncode({
      'baseUrl': 'https://x.dev',
      'token': 'tok',
      'deviceId': 'dev',
      'me': {'id': 'm1', 'username': 'mama', 'displayName': '妈妈', 'role': 'admin'},
    });
  }
  final repo = SessionRepo(secure: secure);
  final share = FakeShareImport();
  var platformReads = 0;
  final container = ProviderContainer(
    overrides: [
      localStoreProvider.overrideWithValue(MemoryLocalStore()),
      secureStoreProvider.overrideWithValue(secure),
      sessionRepoProvider.overrideWithValue(repo),
      apiProvider.overrideWithValue(
        ApiClient(baseUrl: 'https://x.dev', token: 'tok', inner: api()),
      ),
      capturePlatformProvider.overrideWith((ref) {
        platformReads++;
        return const UnsupportedCapturePlatform();
      }),
      shareImportProvider.overrideWithValue(share),
      captureStoreProvider.overrideWith(
        (ref) async => store ?? MemoryCaptureStore(),
      ),
      if (scheduler != null) perkNotificationSchedulerProvider.overrideWithValue(scheduler),
      if (clock != null) assetClockProvider.overrideWithValue(clock),
    ],
  );
  return (container: container, share: share, platformReads: () => platformReads);
}

Future<void> pumpApp(WidgetTester tester, ProviderContainer container) async {
  addTearDown(container.dispose);
  await container.read(sessionRepoProvider).restore();
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
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
}

void main() {
  testWidgets('登录后的外壳一挂上就拉活捕获平台与分享导入（不必进设置页）', (tester) async {
    final ctx = boot(loggedIn: true);
    addTearDown(ctx.share.feed.close);
    await pumpApp(tester, ctx.container);

    // 停在首页，没打开任何设置页。
    expect(find.text('首页'), findsWidgets);
    expect(ctx.platformReads(), 1);
    expect(ctx.share.started, 1);
  });

  testWidgets('没登录（停在认证页）时什么都不拉', (tester) async {
    final ctx = boot(loggedIn: false);
    addTearDown(ctx.share.feed.close);
    await pumpApp(tester, ctx.container);

    expect(find.text('登录'), findsWidgets);
    expect(ctx.platformReads(), 0);
    expect(ctx.share.started, 0);
  });

  testWidgets('导入结论弹 SnackBar；点「查看」跳到对应流水', (tester) async {
    final store = MemoryCaptureStore();
    await store.saveCapture(record('cap1', transactionId: 't1'));
    final ctx = boot(loggedIn: true, store: store);
    addTearDown(ctx.share.feed.close);
    await pumpApp(tester, ctx.container);

    ctx.share.feed.add(
      const CaptureOutcome(
        decision: CaptureDecision.recorded,
        title: '已记录 −¥35.00 · 餐饮',
        body: '92% 可信 · 美团',
        captureId: 'cap1',
      ),
    );
    // 等 SnackBar 完全滑上来再点：动画途中点不到「查看」（会落到底下的列表上）。
    await tester.pumpAndSettle();

    expect(find.text('已记录 −¥35.00 · 餐饮'), findsOneWidget);
    await tester.tap(find.text('查看'));
    await tester.pumpAndSettle();

    expect(find.byType(TxDetailPage), findsOneWidget);
    expect(
      (tester.widget(find.byType(TxDetailPage)) as TxDetailPage).id,
      't1',
    );
  });

  testWidgets('结论没有本地捕获记录：只提示，不给「查看」', (tester) async {
    final ctx = boot(loggedIn: true);
    addTearDown(ctx.share.feed.close);
    await pumpApp(tester, ctx.container);

    ctx.share.feed.add(
      const CaptureOutcome(
        decision: CaptureDecision.ignored,
        title: '家账还没登录',
        body: '',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('家账还没登录'), findsOneWidget);
    expect(find.text('查看'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('外壳挂上：会员提醒初始化并在 2 秒后排一次；第二天回到前台窗口往后挪；点通知跳到会员权益 tab「本期 · 我」', (tester) async {
    final scheduler = FakePerkScheduler();
    var now = DateTime(2026, 9, 23, 10);
    final ctx = boot(loggedIn: true, scheduler: scheduler, clock: () => now);
    addTearDown(ctx.share.feed.close);
    await pumpApp(tester, ctx.container);
    expect(scheduler.inits, 1);
    expect(scheduler.calls, isEmpty, reason: '防抖 2 秒');
    await tester.pump(const Duration(seconds: 2));
    expect(scheduler.cancels, hasLength(30), reason: '没有会员卡：只把窗口清一遍');
    expect(scheduler.cancels.last, 'cancel 20261023');

    scheduler.reset();
    now = DateTime(2026, 9, 24, 10);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 2));
    expect(scheduler.cancels.last, 'cancel 20261024', reason: '回到前台重排，窗口跟着今天走');

    scheduler.tap!(perkAgendaLocation);
    await tester.pumpAndSettle();
    final router = ctx.container.read(routerProvider);
    expect(router.state.uri.toString(), perkAgendaLocation);
  });

  testWidgets('冷启动是点通知进来的：一挂上就跳到会员权益 tab', (tester) async {
    final scheduler = FakePerkScheduler(launch: perkAgendaLocation);
    final ctx = boot(loggedIn: true, scheduler: scheduler);
    addTearDown(ctx.share.feed.close);
    await pumpApp(tester, ctx.container);
    final router = ctx.container.read(routerProvider);
    expect(router.state.uri.toString(), perkAgendaLocation);
  });

  testWidgets('没登录冷启动（停在认证页）：不初始化通知，但把系统里上一家的会员提醒撤干净（上次退出时进程可能被杀了）', (tester) async {
    final scheduler = FakePerkScheduler(pending: [20261001, 20261120, 7001]);
    final ctx = boot(loggedIn: false, scheduler: scheduler);
    addTearDown(ctx.share.feed.close);
    await pumpApp(tester, ctx.container);
    expect(scheduler.inits, 0);
    expect(scheduler.pending, [7001], reason: '会员提醒全撤，自动记账的不动');
    expect(scheduler.schedules, isEmpty);
  });

  testWidgets('登录着冷启动：不当成「上一家」去撤', (tester) async {
    final scheduler = FakePerkScheduler(pending: [20261120]);
    final ctx = boot(loggedIn: true, scheduler: scheduler, clock: () => DateTime(2026, 9, 23, 10));
    addTearDown(ctx.share.feed.close);
    await pumpApp(tester, ctx.container);
    expect(scheduler.calls, isEmpty, reason: '交给外壳里的排程（2 秒防抖后先取消整段再排）');
    await tester.pump(const Duration(seconds: 2));
  });
}
