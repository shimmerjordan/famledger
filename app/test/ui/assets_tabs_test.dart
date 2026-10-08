import 'package:famledger/ui/assets/asset_routes.dart';
import 'package:famledger/ui/assets/assets_page.dart';
import 'package:famledger/ui/funds/funds_tab.dart';
import 'package:famledger/ui/perks/perk_alert_tile.dart' show perkAgendaLocation;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'assets_harness.dart';

int tabIndex(WidgetTester tester) => tester.widget<TabBar>(find.byType(TabBar)).controller!.index;

GoRouter routerOf(WidgetTester tester) => GoRouter.of(tester.element(find.byType(AssetsPage)));

void main() {
  group('地址点名要哪一段（requestedAssetsTab）', () {
    test('?tab= 写了按它；不认识的当第一段；只有 /assets 就是没点名', () {
      expect(requestedAssetsTab(Uri.parse('/assets')), isNull);
      expect(requestedAssetsTab(Uri.parse('/assets?tab=funds')), AssetsPage.fundsTab);
      expect(requestedAssetsTab(Uri.parse('/assets?tab=items')), AssetsPage.itemsTab);
      expect(requestedAssetsTab(Uri.parse('/assets?tab=invest')), AssetsPage.investTab);
      expect(requestedAssetsTab(Uri.parse(perkAgendaLocation)), AssetsPage.perksTab);
      expect(requestedAssetsTab(Uri.parse('/assets?tab=bogus')), AssetsPage.fundsTab);
    });

    test('没写 tab 但落在子页上：垫在底下的资产页开子页归属的那一段', () {
      expect(requestedAssetsTab(Uri.parse('/assets/items/new')), AssetsPage.itemsTab);
      expect(requestedAssetsTab(Uri.parse('/assets/items/a1/edit')), AssetsPage.itemsTab);
      expect(requestedAssetsTab(Uri.parse('/assets/holdings/h1')), AssetsPage.investTab);
      expect(requestedAssetsTab(Uri.parse('/assets/memberships/m1/benefits/new')), AssetsPage.perksTab);
      expect(requestedAssetsTab(Uri.parse('/assets/benefits/b1/edit')), AssetsPage.perksTab);
      expect(requestedAssetsTab(Uri.parse('/assets/platforms/new')), AssetsPage.perksTab);
      expect(requestedAssetsTab(Uri.parse('/assets/import?want=items')), AssetsPage.itemsTab);
      expect(requestedAssetsTab(Uri.parse('/assets/import?want=virtual')), AssetsPage.perksTab);
    });

    test('assetsLocation 和 requestedAssetsTab 来回对得上', () {
      for (var i = 0; i < AssetsPage.tabCount; i++) {
        expect(requestedAssetsTab(Uri.parse(assetsLocation(i))), i);
      }
    });
  });

  testWidgets('四段依次是基金、物品、理财、会员权益；不带 tab 打开是基金，顶栏的「+」是新建基金', (tester) async {
    await pumpAssetsAt(tester, bootAssets(AssetsBackend()), '/assets');

    final labels = tester.widget<TabBar>(find.byType(TabBar)).tabs.map((t) => (t as Tab).text).toList();
    expect(labels, ['基金', '物品', '理财', '会员权益']);
    expect(tabIndex(tester), AssetsPage.fundsTab);
    expect(find.byType(FundsTab), findsOneWidget);
    expect(find.byTooltip('新建基金'), findsOneWidget);
    expect(find.byTooltip('智能导入'), findsNothing, reason: '智能导入只在物品段');
  });

  testWidgets('顶栏跟着段走：物品有智能导入和记一件，理财是添加持仓，会员权益的「更多」里有会员提醒', (tester) async {
    await pumpAssetsAt(tester, bootAssets(AssetsBackend()), '/assets?tab=items');
    expect(find.byTooltip('智能导入'), findsOneWidget);
    expect(find.byTooltip('记一件物品'), findsOneWidget);

    await tester.tap(find.widgetWithText(Tab, '理财'));
    await settle(tester);
    expect(find.byTooltip('添加持仓'), findsOneWidget);
    expect(find.byTooltip('智能导入'), findsNothing);

    await tester.tap(find.widgetWithText(Tab, '会员权益'));
    await settle(tester);
    expect(find.byTooltip('记一张会员卡'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('perks-menu')));
    await settle(tester);
    expect(find.byKey(const ValueKey('menu-perk-reminders')), findsOneWidget);
    expect(find.text('平台管理'), findsOneWidget);
  });

  testWidgets('切段时地址跟着改；切走以后同一个「本期 · 我」链接再来一次还切得回去，带的视图也还在', (tester) async {
    await pumpAssetsAt(tester, bootAssets(AssetsBackend()), perkAgendaLocation);
    final router = routerOf(tester);
    expect(tabIndex(tester), AssetsPage.perksTab);
    expect(router.state.uri.toString(), perkAgendaLocation, reason: '从链接切过来的那一下不改地址，不冲掉 view/scope');

    await tester.tap(find.widgetWithText(Tab, '基金'));
    await settle(tester);
    expect(tabIndex(tester), AssetsPage.fundsTab);
    expect(router.state.uri.toString(), '/assets?tab=funds');

    router.go(perkAgendaLocation);
    await settle(tester);
    expect(tabIndex(tester), AssetsPage.perksTab);
    expect(router.state.uri.toString(), perkAgendaLocation);
  });

  testWidgets('深链接进子页（网页刷新到表单）：返回回到子页归属的那一段，不跳回基金', (tester) async {
    await pumpAssetsAt(tester, bootAssets(AssetsBackend()), '/assets/holdings/new');
    expect(find.byType(AssetsPage), findsNothing, reason: '表单盖在上面');

    await tester.tap(find.byType(BackButton));
    await settle(tester);
    expect(tabIndex(tester), AssetsPage.investTab);
  });

  testWidgets('净资产明细里有「管理账户」（从「我的」挪过来），点了去账户页', (tester) async {
    final backend = AssetsBackend()..accountBalances = {'bank': 1000000};
    await pumpAssetsAt(tester, bootAssets(backend), '/assets');

    await tester.tap(find.byKey(const ValueKey('net-worth-strip')));
    await settle(tester);
    await tapVisible(tester, find.byKey(const ValueKey('net-worth-accounts')));
    expect(find.text('账户管理页'), findsOneWidget);
  });

  testWidgets('大字号（1.3×）：净资产条、顶栏「新建基金」、基金列表在 360 宽上不溢出', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpAssetsAt(tester, bootAssets(AssetsBackend()), '/assets', size: const Size(360, 1600));
    expect(tester.takeException(), isNull, reason: '不能有 RenderFlex overflow');
    expect(find.byTooltip('新建基金'), findsOneWidget);
    expect(find.byKey(const ValueKey('net-worth-strip')), findsOneWidget);
  });

}
