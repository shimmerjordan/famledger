import 'dart:async';

import 'package:famledger/app/providers.dart';
import 'package:famledger/app/theme.dart';
import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/data/local/secure_store.dart';
import 'package:famledger/data/models/models.dart';
import 'package:famledger/data/repos/ledger_repo.dart';
import 'package:famledger/platform/capture_channel.dart';
import 'package:famledger/platform/capture_providers.dart';
import 'package:famledger/platform/perk_notifications.dart';
import 'package:famledger/platform/perk_reminders.dart';
import 'package:famledger/ui/assets/asset_providers.dart';
import 'package:famledger/ui/settings/perk_reminder_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../platform/perk_fake_scheduler.dart';
import 'assets_harness.dart' show sessionAs, kWidths;

// 「我的 › 会员提醒」（spec §5）：本机开关和时间（存本机、不同步）、通知权限复用自动记账那套、MIUI 自启动、
// 接下来几条的预览；不能推送时照实说为什么（网页版、iOS 版、这台手机上通知组件用不了）。三种宽度、1.5 倍字号不溢出。
// 「现在」= 本地 2026-09-23 上午十点。

/// 通知权限、MIUI 由测试决定；其余照「不支持」。
class FakePlatform extends UnsupportedCapturePlatform {
  FakePlatform({this.permission = NotificationPermission.denied, this.miui = true});

  NotificationPermission permission;
  final bool miui;
  int requested = 0;
  int autoStart = 0;

  @override
  bool get isSupported => true;

  @override
  Future<NotificationPermission> notificationPermission() async => permission;

  @override
  Future<void> requestNotificationPermission() async => requested++;

  @override
  Future<String> openAutoStartSettings() async {
    autoStart++;
    return 'miui_autostart';
  }

  @override
  Future<DeviceInfo> deviceInfo() async =>
      DeviceInfo(manufacturer: miui ? 'Xiaomi' : 'Google', brand: miui ? 'Redmi' : 'google', sdkInt: 34);
}

class FakeLedger extends LedgerController {
  FakeLedger(this.data);

  final LedgerData data;

  @override
  Future<LedgerData> build() async => data;

  @override
  Future<void> sync({bool full = false}) async {}
}

/// 一直读不完的 ledger（刚打开 App、缓存还没读出来）。
class LoadingLedger extends LedgerController {
  @override
  Future<LedgerData> build() => Completer<LedgerData>().future;
}

/// 88VIP 10/28 到期：接下来是 9/28（T−30）和 10/21（T−7）。
final LedgerData vip = LedgerData(
  memberships: const [Membership(id: 'vip', platformId: 'tb', name: '88VIP', expiresOn: '2026-10-28')],
);

Future<({MemoryLocalStore store, FakePlatform platform, ProviderContainer container})> pumpPage(
  WidgetTester tester, {
  PerkNotificationScheduler? scheduler,
  FakePlatform? platform,
  LedgerController Function()? ledger,
  MemoryLocalStore? store,
  Size size = const Size(400, 1400),
  bool startReminders = false,
}) async {
  final local = store ?? MemoryLocalStore();
  final fake = platform ?? FakePlatform();
  final container = ProviderContainer(
    overrides: [
      localStoreProvider.overrideWithValue(local),
      secureStoreProvider.overrideWithValue(MemorySecureStore()),
      sessionRepoProvider.overrideWithValue(await sessionAs('member')),
      capturePlatformProvider.overrideWithValue(fake),
      perkNotificationSchedulerProvider.overrideWithValue(scheduler ?? FakePerkScheduler()),
      assetClockProvider.overrideWithValue(() => DateTime(2026, 9, 23, 10)),
      ledgerProvider.overrideWith(ledger ?? () => FakeLedger(vip)),
    ],
  );
  addTearDown(container.dispose);
  // 外壳挂上时排程就起来了（读回本机记着的排程时刻）；设置页的预览和它用同一个「今天那条到过点没有」。
  if (startReminders) await container.read(perkReminderControllerProvider).start();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: buildTheme(Brightness.light), home: const PerkReminderPage()),
    ),
  );
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return (store: local, platform: fake, container: container);
}

void main() {
  testWidgets('Android：默认开、09:00；接下来的两条；没允许通知给「允许」（复用自动记账那套）；MIUI 给自启动引导', (tester) async {
    final page = await pumpPage(tester);
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('perk-reminder-enabled'))).value, isTrue);
    expect(find.text('09:00'), findsOneWidget);
    expect(find.text('会员权益 · 88VIP 快到期'), findsNWidgets(2));
    expect(find.text('每天最多一条，和「要处理」同一套：续费、到期、试用结束、权益快到期、本期没领完的'), findsOneWidget);
    expect(find.text('未允许 · 收不到会员提醒（自动记账的结果通知也要它）。拒绝过的话，点「允许」会打开系统的通知设置，在那里打开'), findsOneWidget,
        reason: '连着拒绝两次后系统不再弹框：说清楚下一步');
    await tester.tap(find.text('允许'));
    await tester.pump();
    expect(page.platform.requested, 1);
    await tester.tap(find.text('去设置'));
    await tester.pump();
    expect(page.platform.autoStart, 1);
    expect(find.textContaining('网页版不能推送'), findsOneWidget, reason: '说明里也写明网页版不能推送');
  });

  testWidgets('已允许：打勾、没有按钮；不是 MIUI 不给自启动引导', (tester) async {
    await pumpPage(tester, platform: FakePlatform(permission: NotificationPermission.granted, miui: false));
    expect(find.text('已允许'), findsOneWidget);
    expect(find.text('允许'), findsNothing);
    expect(find.text('允许自启动（MIUI）'), findsNothing);
  });

  testWidgets('关掉：存到本机；预览说已关闭', (tester) async {
    final page = await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('perk-reminder-enabled')));
    await tester.pump();
    expect(await page.store.read<Map<String, dynamic>>(PerkReminderPrefsController.storeKey), {'enabled': false, 'hour': 9, 'minute': 0});
    expect(find.text('已关闭：不发通知（首页和「要处理」照常提醒）'), findsOneWidget);
    expect(find.text('会员权益 · 88VIP 快到期'), findsNothing);
  });

  testWidgets('改时间：在时间选择器里输入 20:30，存到本机，预览跟着换', (tester) async {
    final page = await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('perk-reminder-time')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.keyboard_outlined));
    await tester.pumpAndSettle();
    final fields = find.descendant(of: find.byType(Dialog), matching: find.byType(TextField));
    await tester.enterText(fields.at(0), '20');
    await tester.enterText(fields.at(1), '30');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(await page.store.read<Map<String, dynamic>>(PerkReminderPrefsController.storeKey), {'enabled': true, 'hour': 20, 'minute': 30});
    expect(find.text('20:30'), findsOneWidget);
    expect(find.textContaining('20:30'), findsNWidgets(3), reason: '右边的时间 + 两条预览');
  });

  testWidgets('不能推送时照实说为什么：网页版、iOS 版、这台手机上通知组件用不了；都没有开关', (tester) async {
    final cases = <(PerkNotificationScheduler, String, String)>[
      (const UnsupportedPerkNotificationScheduler(PerkPushBlock.web), '网页版不能推送', '网页版不发系统通知。'),
      (const UnsupportedPerkNotificationScheduler(PerkPushBlock.ios), 'iOS 版暂不推送', 'iOS 版这一期还不发系统通知。'),
      (FakePerkScheduler()..supported = false, '这台手机上用不了系统通知', '家账的通知组件没能启动'),
    ];
    for (final (scheduler, title, why) in cases) {
      await pumpPage(tester, scheduler: scheduler);
      expect(find.text(title), findsOneWidget);
      expect(find.textContaining(why), findsOneWidget);
      expect(find.textContaining('「要处理」照样会提醒'), findsOneWidget);
      expect(find.text('网页版不能推送'), title == '网页版不能推送' ? findsOneWidget : findsNothing, reason: '不在网页上就别说「网页版」');
      expect(find.byKey(const ValueKey('perk-reminder-enabled')), findsNothing);
    }
  });

  testWidgets('Android 12 及更早（不需要申请通知权限）：没有权限那一行', (tester) async {
    await pumpPage(tester, platform: FakePlatform(permission: NotificationPermission.notRequired));
    expect(find.text('通知权限'), findsNothing);
    expect(find.byKey(const ValueKey('perk-reminder-enabled')), findsOneWidget);
  });

  testWidgets('去系统设置里允许了再回来：回到前台重新查，变成「已允许」', (tester) async {
    final page = await pumpPage(tester);
    expect(find.text('允许'), findsOneWidget);
    page.platform.permission = NotificationPermission.granted;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(find.text('已允许'), findsOneWidget);
    expect(find.text('允许'), findsNothing);
  });

  testWidgets('数据还没读出来：预览写「正在读取…」，不说「未来 30 天没有要提醒的」', (tester) async {
    await pumpPage(tester, ledger: LoadingLedger.new);
    expect(find.text('正在读取…'), findsOneWidget);
    expect(find.text('未来 30 天没有要提醒的'), findsNothing);
  });

  testWidgets('今天那条 9 点已经弹过、改到 21:00：预览不写「今天」，从下一次起（和排程一个判断）', (tester) async {
    final plus = LedgerData(
      memberships: const [Membership(id: 'plus', platformId: 'jd', name: '京东PLUS', feePeriod: 'month', expiresOn: '2026-09-24')],
    );
    final store = MemoryLocalStore();
    await store.write(PerkReminderController.logKey, {'20260923': DateTime(2026, 9, 23, 9).millisecondsSinceEpoch});
    await store.write(PerkReminderPrefsController.storeKey, {'enabled': true, 'hour': 21, 'minute': 0});
    final page = await pumpPage(tester, ledger: () => FakeLedger(plus), store: store, startReminders: true);
    expect(find.text('21:00'), findsOneWidget);
    expect(page.container.read(perkReminderControllerProvider).todaySpent, isTrue);
    expect(find.byKey(const ValueKey('perk-reminder-next-20260923')), findsNothing);
    expect(find.byKey(const ValueKey('perk-reminder-next-20260925')), findsOneWidget);
    // 排程的防抖（2 秒）跑完，不留悬空的计时器。
    await tester.pump(const Duration(seconds: 3));
  });

  group('不溢出', () {
    for (final size in kWidths) {
      testWidgets('${size.width.toInt()} 宽、字号 1.5 倍：Android（没允许、MIUI）和不能推送两种样子都不溢出', (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = 1.5;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await pumpPage(tester, size: size);
        expect(find.text('允许'), findsOneWidget);
        expect(find.text('去设置'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await pumpPage(tester, size: size, scheduler: const UnsupportedPerkNotificationScheduler(PerkPushBlock.ios));
        expect(find.text('iOS 版暂不推送'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
