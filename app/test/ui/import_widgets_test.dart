import 'package:famledger/app/theme.dart';
import 'package:famledger/ui/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// 账单导入和 AI 导入共用的三个组件（spec §6「公共组件只抽 3 个」）：带计数的筛选 chip、限宽底栏、PopScope 放弃确认。

Widget _app(Widget home) => MaterialApp(theme: buildTheme(Brightness.light), home: home);

void main() {
  testWidgets('CountFilterChip：写「标签 计数」，点了回调，选中态照传', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(_app(Scaffold(
      body: CountFilterChip(label: '需确认', count: 3, selected: true, onSelected: () => tapped++),
    )));
    expect(find.text('需确认 3'), findsOneWidget);
    expect(tester.widget<ChoiceChip>(find.byType(ChoiceChip)).selected, isTrue);
    await tester.tap(find.text('需确认 3'));
    expect(tapped, 1);
  });

  testWidgets('ConstrainedBottomBar：内容限宽居中；紧凑 16、展开 24 的页边距', (tester) async {
    Future<Rect> pumpAt(double width) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(_app(const Scaffold(
        bottomNavigationBar: ConstrainedBottomBar(maxWidth: 600, child: SizedBox(key: ValueKey('bar-body'), height: 40, width: double.infinity)),
      )));
      return tester.getRect(find.byKey(const ValueKey('bar-body')));
    }

    addTearDown(tester.view.reset);
    final narrow = await pumpAt(400);
    expect([narrow.left, narrow.width], [16, 400 - 32]);
    final wide = await pumpAt(1400);
    expect(wide.width, 600 - 48);
    expect(wide.left, (1400 - 600) / 2 + 24);
  });

  testWidgets('DiscardGuard：能走就直接走；有改动时先问，「接着核对」留下，「不导了」才走并先调 onDiscard；onBlocked 处理了就不问', (tester) async {
    var discarded = 0;
    var blocked = false;
    var canPop = false;
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: nav,
      theme: buildTheme(Brightness.light),
      home: const Scaffold(body: Text('首页')),
    ));
    void open() => nav.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => StatefulBuilder(
        builder: (context, setState) => DiscardGuard(
          canPop: canPop,
          title: '不导了？',
          message: '刚才改的都会丢掉。',
          stayLabel: '接着核对',
          leaveLabel: '不导了',
          onBlocked: () => blocked,
          onDiscard: () => discarded++,
          child: const Scaffold(body: Text('核对页')),
        ),
      ),
    ));

    open();
    await tester.pumpAndSettle();
    await nav.currentState!.maybePop();
    await tester.pumpAndSettle();
    expect(find.text('不导了？'), findsOneWidget);
    await tester.tap(find.text('接着核对'));
    await tester.pumpAndSettle();
    expect(find.text('核对页'), findsOneWidget);
    expect(discarded, 0);

    await nav.currentState!.maybePop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('不导了'));
    await tester.pumpAndSettle();
    expect(find.text('首页'), findsOneWidget);
    expect(discarded, 1);

    blocked = true;
    open();
    await tester.pumpAndSettle();
    await nav.currentState!.maybePop();
    await tester.pumpAndSettle();
    expect(find.text('不导了？'), findsNothing, reason: '页面自己处理了（比如退出多选）');
    expect(find.text('核对页'), findsOneWidget);

    canPop = true;
    blocked = false;
    nav.currentState!.pop();
    await tester.pumpAndSettle();
    open();
    await tester.pumpAndSettle();
    await nav.currentState!.maybePop();
    await tester.pumpAndSettle();
    expect(find.text('首页'), findsOneWidget, reason: '没有改动直接走');
  });
}
