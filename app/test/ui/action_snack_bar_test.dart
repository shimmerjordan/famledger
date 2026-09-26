import 'package:famledger/ui/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

SnackBar _undoBar() => SnackBar(
  content: const Text('领了：优酷VIP年卡'),
  action: SnackBarAction(label: '撤销', onPressed: () {}),
);

Future<void> _pumpApp(
  WidgetTester tester,
  void Function(ScaffoldMessengerState) show,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => show(ScaffoldMessenger.of(context)),
            child: const Text('打卡'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打卡'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300)); // 出场动画
}

void main() {
  group('无障碍导航开着（MacroDroid、Tasker 这类服务在的手机）', () {
    testWidgets('框架自己不收：带「撤销」的 SnackBar 10 秒后还挂着（这就是要兜底的原因）', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(accessibleNavigation: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await _pumpApp(tester, (m) => m.showSnackBar(_undoBar()));
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(find.text('领了：优酷VIP年卡'), findsOneWidget);
    });

    testWidgets('showActionSnackBar：4 秒时还在（多给一段），8 秒后收掉', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(accessibleNavigation: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await _pumpApp(tester, (m) => showActionSnackBar(m, _undoBar()));
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('领了：优酷VIP年卡'), findsOneWidget, reason: '无障碍导航下多给 4 秒');
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.text('领了：优酷VIP年卡'), findsNothing);
    });
  });

  testWidgets('平常的手机：照旧 4 秒收掉，兜底计时器到点什么也不做', (tester) async {
    await _pumpApp(tester, (m) => showActionSnackBar(m, _undoBar()));
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text('领了：优酷VIP年卡'), findsNothing);
    await tester.pump(const Duration(seconds: 5)); // 兜底计时器到点：已经收了，不能出错
    expect(tester.takeException(), isNull);
  });

  testWidgets('先收掉上一条：连着出两条，第二条立刻接上，到点关的是它自己', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(accessibleNavigation: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    late ScaffoldMessengerState messenger;
    await _pumpApp(tester, (m) {
      messenger = m;
      showActionSnackBar(m, _undoBar());
    });
    showActionSnackBar(
      messenger,
      SnackBar(
        content: const Text('已续到 2026-10-27'),
        action: SnackBarAction(label: '撤销', onPressed: () {}),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('领了：优酷VIP年卡'), findsNothing);
    expect(find.text('已续到 2026-10-27'), findsOneWidget);
    await tester.pump(const Duration(seconds: 9));
    await tester.pumpAndSettle();
    expect(find.text('已续到 2026-10-27'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
