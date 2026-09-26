import 'dart:convert';

import 'package:famledger/app/providers.dart';
import 'package:famledger/app/router.dart';
import 'package:famledger/app/theme.dart';
import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/data/local/secure_store.dart';
import 'package:famledger/data/repos/session_repo.dart';
import 'package:famledger/ui/settings/perk_reminder_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Future<ProviderContainer> boot({String? baseUrl, bool loggedIn = false}) async {
  final secure = MemorySecureStore();
  if (baseUrl != null) secure.data[SessionRepo.baseUrlKey] = baseUrl;
  if (loggedIn) {
    secure.data[SessionRepo.sessionKey] = jsonEncode({
      'baseUrl': baseUrl,
      'token': 'tok',
      'deviceId': 'dev',
      'me': {'id': 'm1', 'username': 'mama', 'displayName': '妈妈', 'role': 'admin'},
    });
  }
  final repo = SessionRepo(secure: secure);
  await repo.restore();
  return ProviderContainer(
    overrides: [
      localStoreProvider.overrideWithValue(MemoryLocalStore()),
      secureStoreProvider.overrideWithValue(secure),
      sessionRepoProvider.overrideWithValue(repo),
    ],
  );
}

/// 默认测试窗口是 800×600（= 中等宽度），手机形态要显式调小。
Future<void> pumpApp(
  WidgetTester tester,
  ProviderContainer container, {
  Size size = const Size(390, 844),
}) async {
  addTearDown(container.dispose);
  tester.view.physicalSize = size;
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
  testWidgets('没有会话也没连过服务器 → 连接向导', (tester) async {
    await pumpApp(tester, await boot());
    expect(find.text('连接你的家账服务器'), findsOneWidget);
  });

  testWidgets('连接向导底部的检查地址跟着输入更新', (tester) async {
    await pumpApp(tester, await boot());
    await tester.enterText(find.byType(TextField), '192.168.1.5');
    await tester.pump();
    expect(find.text('会检查 http://192.168.1.5:48090/healthz 是否可达。'), findsOneWidget);
  });

  testWidgets('连过服务器但没登录 → 登录页', (tester) async {
    await pumpApp(tester, await boot(baseUrl: 'https://ledger.example.com'));
    expect(find.text('登录'), findsWidgets);
    expect(find.text('https://ledger.example.com'), findsOneWidget);
  });

  testWidgets('有会话 → 首页，并带五个导航目的地和记一笔 FAB', (tester) async {
    await pumpApp(
      tester,
      await boot(baseUrl: 'https://ledger.example.com', loggedIn: true),
    );
    expect(find.text('首页'), findsWidgets);
    expect(find.byType(NavigationBar), findsOneWidget);
    for (final label in ['账单', '基金', '分析', '我的']) {
      expect(find.text(label), findsWidgets);
    }
    expect(find.byTooltip('记一笔'), findsOneWidget);
  });

  testWidgets('点「记一笔」推出记账页', (tester) async {
    await pumpApp(
      tester,
      await boot(baseUrl: 'https://ledger.example.com', loggedIn: true),
    );
    await tester.tap(find.byTooltip('记一笔'));
    await tester.pumpAndSettle();
    expect(find.text('记一笔'), findsWidgets);
  });

  testWidgets('宽屏用导航轨而不是底部导航', (tester) async {
    await pumpApp(
      tester,
      await boot(baseUrl: 'https://ledger.example.com', loggedIn: true),
      size: const Size(1400, 1000),
    );
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('切到「我的」显示设置分组', (tester) async {
    await pumpApp(
      tester,
      await boot(baseUrl: 'https://ledger.example.com', loggedIn: true),
    );
    await tester.tap(find.text('我的').last);
    await tester.pumpAndSettle();
    expect(find.text('妈妈'), findsOneWidget);
    expect(find.text('资产'), findsOneWidget);
    expect(find.text('会员提醒'), findsOneWidget);
    // 设置页是懒加载列表，靠后的分组要滚到了才会建出来。
    await tester.dragUntilVisible(find.text('关于'), find.byType(ListView).last, const Offset(0, -200));
    expect(find.text('导入账单'), findsOneWidget);
    expect(find.text('服务器与账号'), findsOneWidget);
    expect(find.text('关于'), findsOneWidget);
  });

  testWidgets('「我的 › 会员提醒」进得去', (tester) async {
    await pumpApp(
      tester,
      await boot(baseUrl: 'https://ledger.example.com', loggedIn: true),
    );
    await tester.tap(find.text('我的').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('会员提醒'));
    await tester.pumpAndSettle();
    expect(find.byType(PerkReminderPage), findsOneWidget);
  });
}
