import 'package:famledger/app/theme.dart';
import 'package:famledger/ui/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget wrap(Widget child, {Brightness brightness = Brightness.light}) => MaterialApp(
  theme: buildTheme(brightness),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  group('MoneyText', () {
    testWidgets('支出用墨色只带减号', (tester) async {
      await tester.pumpWidget(wrap(const MoneyText(-123456)));
      expect(find.text('−¥1,234.56'), findsOneWidget);
      final text = tester.widget<Text>(find.text('−¥1,234.56'));
      expect(text.style?.color, buildTheme(Brightness.light).colorScheme.onSurface);
    });

    testWidgets('signed 的正数用收入色并带加号', (tester) async {
      await tester.pumpWidget(wrap(const MoneyText(900000, signed: true)));
      final text = tester.widget<Text>(find.text('+¥9,000.00'));
      expect(text.style?.color, LedgerColors.light.income);
    });

    testWidgets('金额一律等宽数字', (tester) async {
      await tester.pumpWidget(wrap(const MoneyText(100)));
      final text = tester.widget<Text>(find.text('¥1.00'));
      expect(text.style?.fontFeatures?.first.feature, 'tnum');
    });

    testWidgets('深色主题下收入色跟着换', (tester) async {
      await tester.pumpWidget(
        wrap(const MoneyText(100, signed: true), brightness: Brightness.dark),
      );
      final text = tester.widget<Text>(find.text('+¥1.00'));
      expect(text.style?.color, LedgerColors.dark.income);
    });
  });

  group('CategoryIcon', () {
    test('认识的名字映射到对应图标', () {
      expect(categoryIconData('restaurant'), Icons.restaurant);
      expect(categoryIconData('directions_bus'), Icons.directions_bus);
      expect(categoryIconData('currency_yen'), Icons.currency_yen);
    });

    test('不认识的名字退回 category', () {
      expect(categoryIconData('nope'), Icons.category);
      expect(categoryIconData(null), Icons.category);
    });
  });

  group('EmptyState', () {
    testWidgets('一句说明 + 一个主操作', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(
        wrap(
          EmptyState(
            title: '还没有基金',
            message: '先从模板建一个',
            icon: Icons.savings_outlined,
            actionLabel: '新建基金',
            onAction: () => tapped++,
          ),
        ),
      );
      expect(find.text('还没有基金'), findsOneWidget);
      await tester.tap(find.text('新建基金'));
      expect(tapped, 1);
    });
  });

  group('FundDot', () {
    testWidgets('没自定义颜色时按下标取 12 色盘', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(fundColorOf(ctx, null, 0), LedgerColors.light.fundPalette[0]);
      expect(fundColorOf(ctx, null, 13), LedgerColors.light.fundPalette[1]);
    });
  });

  group('describeError', () {
    test('把异常翻成中文', () {
      expect(describeError(const FormatException('坏了')), contains('坏了'));
    });
  });
}
