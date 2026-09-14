import 'package:famledger/core/money.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Money.format', () {
    test('正数带符号与千分位', () {
      expect(Money.format(123456), '¥1,234.56');
    });

    test('零', () {
      expect(Money.format(0), '¥0.00');
      expect(Money.format(0, signed: true), '¥0.00');
    });

    test('负数始终带 U+2212 减号', () {
      expect(Money.format(-123456), '−¥1,234.56');
      expect(Money.format(-50, signed: true), '−¥0.50');
    });

    test('signed 给正数加正号', () {
      expect(Money.format(123456, signed: true), '+¥1,234.56');
    });

    test('showSymbol=false 去掉货币符号', () {
      expect(Money.format(123456, showSymbol: false), '1,234.56');
      expect(Money.format(-123456, signed: true, showSymbol: false), '−1,234.56');
    });

    test('百万级三位一组', () {
      expect(Money.format(100000000), '¥1,000,000.00');
    });

    test('分位补零', () {
      expect(Money.format(5), '¥0.05');
    });
  });

  group('Money.parse', () {
    test('带千分位与一位小数', () {
      expect(Money.parse('1,234.5'), 123450);
    });

    test('带货币符号', () {
      expect(Money.parse('¥1,234.56'), 123456);
      expect(Money.parse('￥12'), 1200);
    });

    test('整数视为元', () {
      expect(Money.parse('12'), 1200);
    });

    test('U+2212 与 ASCII 负号都认', () {
      expect(Money.parse('−12.34'), -1234);
      expect(Money.parse('-0.5'), -50);
    });

    test('多余小数位四舍五入到分', () {
      expect(Money.parse('1.239'), 124);
      expect(Money.parse('1.234'), 123);
    });

    test('非数字抛 FormatException', () {
      expect(() => Money.parse('abc'), throwsFormatException);
      expect(() => Money.parse(''), throwsFormatException);
      expect(() => Money.parse('1.2.3'), throwsFormatException);
    });

    test('format/parse 往返', () {
      for (final cents in [0, 5, -5, 123456, -98765432]) {
        expect(Money.parse(Money.format(cents, showSymbol: false)), cents);
      }
    });
  });
}
