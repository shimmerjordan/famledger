/// 日期工具：不依赖 intl 的本地化数据，输出固定中文格式。
class Dates {
  const Dates._();

  /// `2026-09`
  static String monthKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';

  /// 当前月份 key。
  static String currentMonth() => monthKey(DateTime.now());

  /// `2026-09-12`
  static String isoDate(DateTime d) =>
      '${monthKey(d)}-${d.day.toString().padLeft(2, '0')}';

  /// `2026-09` → 该月 1 号 00:00（本地时区）。
  static DateTime monthStart(String month) {
    final parts = month.split('-');
    return DateTime(int.parse(parts[0]), int.parse(parts[1]));
  }

  /// `2026-09` → 下月 1 号 00:00（本地时区），用作右开区间。
  static DateTime monthEnd(String month) {
    final s = monthStart(month);
    return DateTime(s.year, s.month + 1);
  }

  /// 相对当月偏移 [delta] 个月。
  static String shiftMonth(String month, int delta) {
    final s = monthStart(month);
    return monthKey(DateTime(s.year, s.month + delta));
  }

  /// `2026年9月`
  static String monthLabel(String month) {
    final s = monthStart(month);
    return '${s.year}年${s.month}月';
  }

  /// 今天 / 昨天 / 9月12日 周五 / 2025年9月12日
  static String dayLabel(DateTime d, {DateTime? now}) {
    final today = _dateOnly(now ?? DateTime.now());
    final day = _dateOnly(d);
    final diff = today.difference(day).inDays;
    if (diff == 0) return '今天';
    if (diff == 1) return '昨天';
    if (diff == -1) return '明天';
    if (day.year == today.year) return '${day.month}月${day.day}日 ${weekday(day)}';
    return '${day.year}年${day.month}月${day.day}日';
  }

  /// `周五`
  static String weekday(DateTime d) => '周${const ['一', '二', '三', '四', '五', '六', '日'][d.weekday - 1]}';

  /// `2026-09-05T01:00:00+08:00` —— 本地墙上时间 + 时区偏移，秒级精度、不带毫秒。
  ///
  /// 发给服务端的时刻一律用这个格式：服务端原样存，并按字符串前缀判断
  /// 「属于哪天/哪个月」。发 UTC 的 `Z` 串会让跨零点的账记到前一天去。
  static String isoLocal(DateTime dt) {
    final d = dt.toLocal();
    final offset = d.timeZoneOffset;
    final abs = offset.abs();
    final sign = offset.isNegative ? '-' : '+';
    final hh = _two(abs.inHours);
    final mm = _two(abs.inMinutes.remainder(60));
    return '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}'
        'T${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}$sign$hh:$mm';
  }

  /// `09:05`
  static String timeLabel(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  /// `9月12日 09:05`
  static String dateTimeLabel(DateTime d, {DateTime? now}) =>
      '${dayLabel(d, now: now)} ${timeLabel(d)}';

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  static String _two(int n) => n.toString().padLeft(2, '0');
}
