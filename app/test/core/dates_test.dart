import 'package:famledger/core/dates.dart';
import 'package:flutter_test/flutter_test.dart';

/// 期望的偏移按机器时区算出来，测试不绑定 Asia/Shanghai。
String offsetOf(DateTime local) {
  final o = local.timeZoneOffset;
  final sign = o.isNegative ? '-' : '+';
  final abs = o.abs();
  String two(int n) => n.toString().padLeft(2, '0');
  return '$sign${two(abs.inHours)}:${two(abs.inMinutes.remainder(60))}';
}

void main() {
  group('Dates.isoLocal', () {
    test('本地墙上时间 + 偏移，秒级精度不带毫秒', () {
      final dt = DateTime(2026, 9, 5, 1, 0);
      expect(Dates.isoLocal(dt), '2026-09-05T01:00:00${offsetOf(dt)}');
    });

    test('UTC 时刻先转成本地再格式化，绝不出现 Z', () {
      final utc = DateTime.utc(2026, 9, 4, 17);
      final local = utc.toLocal();
      expect(Dates.isoLocal(utc), Dates.isoLocal(local));
      expect(Dates.isoLocal(utc), isNot(contains('Z')));
      expect(Dates.isoLocal(utc).substring(0, 10), Dates.isoDate(local));
    });

    test('补零到两位', () {
      final dt = DateTime(2026, 1, 2, 3, 4, 5);
      expect(Dates.isoLocal(dt), '2026-01-02T03:04:05${offsetOf(dt)}');
    });

    test('DateTime.parse 能原样读回同一时刻', () {
      final dt = DateTime(2026, 9, 5, 1, 0);
      expect(DateTime.parse(Dates.isoLocal(dt)).toUtc(), dt.toUtc());
    });
  });

  group('Dates 其它', () {
    test('monthKey / isoDate / shiftMonth', () {
      expect(Dates.monthKey(DateTime(2026, 9, 5)), '2026-09');
      expect(Dates.isoDate(DateTime(2026, 9, 5)), '2026-09-05');
      expect(Dates.shiftMonth('2026-01', -1), '2025-12');
      expect(Dates.monthEnd('2026-12'), DateTime(2027, 1));
    });

    test('dayLabel 认今天昨天', () {
      final now = DateTime(2026, 9, 12, 10);
      expect(Dates.dayLabel(now, now: now), '今天');
      expect(Dates.dayLabel(now.subtract(const Duration(days: 1)), now: now), '昨天');
    });
  });
}
