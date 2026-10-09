import 'dart:convert';

import 'package:famledger/app/providers.dart';
import 'package:famledger/ui/settings/members_page.dart';
import 'package:famledger/ui/settings/categories_page.dart';
import 'package:famledger/app/theme_mode.dart';
import 'package:famledger/app/router.dart';
import 'package:famledger/app/shell.dart';
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
    for (final label in ['账单', '资产', '分析', '我的']) {
      expect(find.descendant(of: find.byType(NavigationBar), matching: find.text(label)), findsOneWidget);
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

  testWidgets('宽屏点进记一笔：整屏页左边还是导航轨，轨首「记一笔」灰掉；点「我的」直接切过去', (tester) async {
    await pumpApp(
      tester,
      await boot(baseUrl: 'https://ledger.example.com', loggedIn: true),
      size: const Size(1400, 1000),
    );
    await tester.tap(find.widgetWithText(FloatingActionButton, '记一笔'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('save-tx-appbar')), findsOneWidget);
    // 外壳的轨在底下、离屏（不算）；整屏页自己带一条，高亮「账单」。
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(tester.widget<NavigationRail>(find.byType(NavigationRail)).selectedIndex, 1);
    expect(
      tester.widget<FloatingActionButton>(find.widgetWithText(FloatingActionButton, '记一笔')).onPressed,
      isNull,
    );

    await tester.tap(find.descendant(of: find.byType(NavigationRail), matching: find.text('我的')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('save-tx-appbar')), findsNothing);
    expect(find.byKey(const ValueKey('settings-pane')), findsOneWidget);
  });

  testWidgets('切到「我的」：资产、账户、会员提醒、导入账单都挪走了', (tester) async {
    await pumpApp(
      tester,
      await boot(baseUrl: 'https://ledger.example.com', loggedIn: true),
    );
    await tester.tap(find.text('我的').last);
    await tester.pumpAndSettle();
    Finder entry(String label) => find.descendant(of: find.byType(ListView).last, matching: find.text(label));
    expect(find.text('妈妈'), findsOneWidget);
    expect(entry('成员'), findsOneWidget);
    expect(entry('类别'), findsOneWidget);
    // 设置页是懒加载列表，靠后的分组要滚到了才会建出来。
    await tester.dragUntilVisible(find.text('关于'), find.byType(ListView).last, const Offset(0, -200));
    expect(entry('服务器与账号'), findsOneWidget);
    expect(entry('关于'), findsOneWidget);
    for (final gone in ['资产', '账户', '会员提醒', '导入账单']) {
      expect(entry(gone), findsNothing, reason: '「$gone」不该再在「我的」里');
    }
  });

  testWidgets('宽屏「我的」：左边入口、右边嵌着子页（默认成员），点「类别」右边换成类别页；右上角能切外观', (tester) async {
    final container = await boot(baseUrl: 'https://ledger.example.com', loggedIn: true);
    await pumpApp(tester, container, size: const Size(1400, 1000));
    await tester.tap(find.text('我的').last);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('settings-pane')), findsOneWidget);
    expect(find.byType(MembersPage), findsOneWidget, reason: '默认嵌着「成员」');
    await tester.tap(find.byKey(const ValueKey('settings-entry-/settings/categories')));
    await tester.pumpAndSettle();
    expect(find.byType(CategoriesPage), findsOneWidget);
    expect(find.byType(MembersPage), findsNothing);
    expect(find.byType(ListTile).evaluate().where((e) => (e.widget as ListTile).selected).length, 1, reason: '选中的入口高亮');

    // 外观：顶栏右上角的按钮轮换，「外观」那一行也能直接选；都记进本机。
    expect(container.read(themeModeProvider), ThemeMode.system);
    await tester.tap(find.byKey(const ValueKey('theme-mode')).first);
    await tester.pumpAndSettle();
    expect(container.read(themeModeProvider), ThemeMode.light);
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('theme-mode-row')), matching: find.text('深色')));
    await tester.pumpAndSettle();
    expect(container.read(themeModeProvider), ThemeMode.dark);
    expect(await readThemeMode(container.read(localStoreProvider)), ThemeMode.dark);
  });

  testWidgets('底部「资产」：基金、物品、理财、会员权益四段，默认在基金，还在外壳里', (tester) async {
    await pumpApp(
      tester,
      await boot(baseUrl: 'https://ledger.example.com', loggedIn: true),
    );
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('资产')));
    await tester.pumpAndSettle();
    for (final label in ['基金', '物品', '理财', '会员权益']) {
      expect(find.widgetWithText(Tab, label), findsOneWidget);
    }
    expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 0);
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('老地址 /funds 转到资产 › 基金', (tester) async {
    final container = await boot(baseUrl: 'https://ledger.example.com', loggedIn: true);
    await pumpApp(tester, container);
    container.read(routerProvider).go('/funds');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(Tab, '基金'), findsOneWidget);
    expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 0);
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('资产的子页整屏盖住外壳（底部导航不露），返回回到资产 tab', (tester) async {
    final container = await boot(baseUrl: 'https://ledger.example.com', loggedIn: true);
    await pumpApp(tester, container);
    container.read(routerProvider).go('/assets/platforms');
    await tester.pumpAndSettle();
    expect(find.text('平台管理'), findsWidgets);
    expect(find.byType(NavigationBar), findsNothing);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.widgetWithText(Tab, '会员权益'), findsOneWidget);
  });

  testWidgets('「资产 › 会员权益 › 更多 › 会员提醒」进得去', (tester) async {
    final container = await boot(baseUrl: 'https://ledger.example.com', loggedIn: true);
    await pumpApp(tester, container);
    container.read(routerProvider).go('/assets?tab=perks');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('perks-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('menu-perk-reminders')));
    await tester.pumpAndSettle();
    expect(find.byType(PerkReminderPage), findsOneWidget);
  });

  int tabIndex(WidgetTester tester) => tester.widget<TabBar>(find.byType(TabBar)).controller!.index;

  testWidgets('go 到另一段的子页（导入后「去看看」某张卡）：子页照常打开，返回落在那一段、地址也跟上', (tester) async {
    final container = await boot(baseUrl: 'https://ledger.example.com', loggedIn: true);
    await pumpApp(tester, container);
    final router = container.read(routerProvider);
    router.go('/assets?tab=items');
    await tester.pumpAndSettle();
    router.go('/home');
    await tester.pumpAndSettle();

    router.go('/assets/memberships/m1');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(router.state.uri.path, '/assets/memberships/m1', reason: '切段的地址同步不能把刚打开的子页换掉');
    expect(find.byType(NavigationBar), findsNothing);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(tabIndex(tester), 3);
    expect(router.state.uri.toString(), '/assets?tab=perks');
  });

  testWidgets('停在基金段时 go 到理财的表单：表单不被弹掉', (tester) async {
    final container = await boot(baseUrl: 'https://ledger.example.com', loggedIn: true);
    await pumpApp(tester, container);
    final router = container.read(routerProvider);
    router.go('/assets');
    await tester.pumpAndSettle();
    router.go('/assets/holdings/new');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(router.state.uri.path, '/assets/holdings/new');
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('已经在资产 tab 时再点一次底部「资产」：段不变，地址补回当前段（刷新不会落到基金）', (tester) async {
    final container = await boot(baseUrl: 'https://ledger.example.com', loggedIn: true);
    await pumpApp(tester, container);
    final router = container.read(routerProvider);
    final bottomAssets = find.descendant(of: find.byType(NavigationBar), matching: find.text('资产'));
    await tester.tap(bottomAssets);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(Tab, '理财'));
    await tester.pumpAndSettle();
    expect(router.state.uri.toString(), '/assets?tab=invest');

    await tester.tap(bottomAssets);
    await tester.pumpAndSettle();
    expect(tabIndex(tester), 2);
    expect(router.state.uri.toString(), '/assets?tab=invest');
  });

  testWidgets('资产 tab 里的底部弹层盖在外壳上面（不被「记一笔」挡住、底栏点不到）', (tester) async {
    final container = await boot(baseUrl: 'https://ledger.example.com', loggedIn: true);
    await pumpApp(tester, container);
    container.read(routerProvider).go('/assets?tab=perks');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('记一张会员卡'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('perks-add-manual')), findsOneWidget);
    expect(
      find.ancestor(of: find.byType(BottomSheet), matching: find.byType(AdaptiveShell)),
      findsNothing,
      reason: '弹层挂在根 navigator 上',
    );
  });
}
