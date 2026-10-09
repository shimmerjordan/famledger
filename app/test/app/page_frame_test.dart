import 'package:famledger/app/page_frame.dart';
import 'package:famledger/app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> pumpFrame(WidgetTester tester, String location, {required double width}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light),
      home: PageFrame(
        location: location,
        child: Scaffold(
          appBar: AppBar(title: const Text('页面标题')),
          body: const Center(child: Text('正文')),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

FloatingActionButton railFab(WidgetTester tester) =>
    tester.widget<FloatingActionButton>(find.widgetWithText(FloatingActionButton, '记一笔'));

void main() {
  test('整屏页归哪个 tab：按路径前缀，带查询参数也认；登录页这类不归任何 tab', () {
    expect(shellIndexFor('/home'), 0);
    expect(shellIndexFor('/transactions/new'), 1);
    expect(shellIndexFor('/transactions/t1'), 1);
    expect(shellIndexFor('/import/paste'), 1);
    expect(shellIndexFor('/assets/items/new'), 2);
    expect(shellIndexFor('/assets?tab=perks'), 2);
    expect(shellIndexFor('/funds/f1/edit'), 2);
    expect(shellIndexFor('/analysis'), 3);
    expect(shellIndexFor('/ai/chat'), 3);
    expect(shellIndexFor('/settings/members'), 4);
    expect(shellIndexFor('/login'), isNull);
    expect(shellIndexFor('/homework'), isNull, reason: '前缀要整段匹配');
  });

  group('PageFrame', () {
    testWidgets('宽屏：左边是导航轨，高亮归属的 tab，正文在右边', (tester) async {
      await pumpFrame(tester, '/settings/members', width: 1400);
      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.selectedIndex, 4);
      expect(rail.extended, isTrue);
      expect(find.text('页面标题'), findsOneWidget);
      expect(railFab(tester).onPressed, isNotNull);
      expect(
        tester.getTopLeft(find.text('页面标题')).dx,
        greaterThan(tester.getTopRight(find.byType(NavigationRail)).dx),
      );
    });

    testWidgets('中等宽度：轨不展开（只有图标和小标签）', (tester) async {
      await pumpFrame(tester, '/assets/items/new', width: 700);
      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.selectedIndex, 2);
      expect(rail.extended, isFalse);
    });

    testWidgets('已经在记一笔页上：轨首的「记一笔」灰掉，免得再叠一个', (tester) async {
      await pumpFrame(tester, '/transactions/new', width: 1400);
      expect(railFab(tester).onPressed, isNull);
    });

    testWidgets('手机：没有轨，整屏就是页面本身', (tester) async {
      await pumpFrame(tester, '/settings/members', width: 390);
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.text('页面标题'), findsOneWidget);
    });
  });
}
