import 'package:famledger/app/theme.dart';
import 'package:famledger/ui/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> pumpAt(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
        body: FormColumns(
          main: const [Text('主字段')],
          side: const [Text('次要段落')],
          bottom: const [Text('提交')],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('FormColumns', () {
    testWidgets('内容区 ≥ 900：主字段在左、次要在右、提交跟在左列末尾', (tester) async {
      await pumpAt(tester, 1200);
      final main = tester.getTopLeft(find.text('主字段'));
      final side = tester.getTopLeft(find.text('次要段落'));
      final submit = tester.getTopLeft(find.text('提交'));
      expect(side.dy, main.dy, reason: '两列顶对齐');
      expect(side.dx, greaterThan(main.dx + 300));
      expect(submit.dx, main.dx, reason: '提交在左列');
      expect(submit.dy, greaterThan(main.dy));
      // 整体限宽 1120，居中：左边有留白。
      expect(main.dx, greaterThan(16));
      expect(tester.getTopRight(find.text('次要段落')).dx, lessThan(1200 - 16));
    });

    testWidgets('窄了就一列：主 → 次要 → 提交，从上往下', (tester) async {
      await pumpAt(tester, 600);
      final main = tester.getTopLeft(find.text('主字段'));
      final side = tester.getTopLeft(find.text('次要段落'));
      final submit = tester.getTopLeft(find.text('提交'));
      expect(side.dx, main.dx);
      expect(submit.dx, main.dx);
      expect(side.dy, greaterThan(main.dy));
      expect(submit.dy, greaterThan(side.dy));
    });

    testWidgets('没有次要段落就不分列，再宽也是一列', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FormColumns(main: const [Text('只有主字段')], bottom: const [Text('提交')]),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Row), findsNothing);
      // 一列限宽 720、居中。
      final left = tester.getTopLeft(find.text('只有主字段')).dx;
      expect(left, closeTo((1400 - 720) / 2, 1));
    });
  });
}
