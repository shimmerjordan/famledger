/// 金额：内部一律整数「分」，展示才转成元。
///
/// 正负永远靠符号表达，不靠颜色（见 DESIGN.md）。负号用排版减号 U+2212。
class Money {
  const Money._();

  /// 人民币符号。
  static const String symbol = '¥';

  /// 排版减号 U+2212（比 ASCII '-' 与数字等宽）。
  static const String minus = '−';

  /// `123456` → `¥1,234.56`；[signed] 时正数带 `+`；[showSymbol] 关掉货币符号。
  static String format(int cents, {bool signed = false, bool showSymbol = true}) {
    final abs = cents.abs();
    final digits = _group('${abs ~/ 100}');
    final frac = (abs % 100).toString().padLeft(2, '0');
    final sign = cents < 0
        ? minus
        : (signed && cents > 0 ? '+' : '');
    return '$sign${showSymbol ? symbol : ''}$digits.$frac';
  }

  /// 只要「1,234.56」这一段，用于输入框回显。
  static String plain(int cents) => format(cents, showSymbol: false);

  /// `'1,234.5'` → `123450`。认 `¥`/`￥`/千分位/空格/U+2212；超过两位小数四舍五入到分。
  ///
  /// 解析不出数字时抛 [FormatException]。
  static int parse(String s) {
    var t = s.trim();
    for (final ch in const ['¥', '￥', ',', '，', ' ', ' ']) {
      t = t.replaceAll(ch, '');
    }
    t = t.replaceAll(minus, '-').replaceAll('–', '-').replaceAll('—', '-');
    var negative = false;
    if (t.startsWith('+')) {
      t = t.substring(1);
    } else if (t.startsWith('-')) {
      negative = true;
      t = t.substring(1);
    }
    if (!_numeric.hasMatch(t)) {
      throw FormatException('无法识别的金额', s);
    }
    final dot = t.indexOf('.');
    final intPart = dot < 0 ? t : t.substring(0, dot);
    final fracPart = dot < 0 ? '' : t.substring(dot + 1);
    final yuan = intPart.isEmpty ? 0 : int.parse(intPart);
    final padded = fracPart.padRight(3, '0');
    var cents = int.parse(padded.substring(0, 2));
    if (int.parse(padded.substring(2, 3)) >= 5) cents += 1;
    final total = yuan * 100 + cents;
    return negative ? -total : total;
  }

  /// 能解析就返回，不能就返回 null（输入框实时校验用）。
  static int? tryParse(String s) {
    try {
      return parse(s);
    } on FormatException {
      return null;
    }
  }

  /// 至少要有一位数字，最多一个小数点。
  static final RegExp _numeric = RegExp(r'^(?=.*\d)\d*(\.\d*)?$');

  static String _group(String digits) {
    final buf = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
      buf.write(digits[i]);
    }
    return buf.toString();
  }
}
