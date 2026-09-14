/// 通知文本归一化。
///
/// 两种口径：
/// * [TextNormalizer.normalize]：给解析器用，全角转半角、`￥` 统一成 `¥`、
///   去 emoji、压缩空白，但保留 `:`「【】」等结构字符，正则才能定位字段。
/// * [TextNormalizer.tokenText]：给分词器用，在上面的基础上再小写、去掉
///   全部空白与标点，只留数字/字母/汉字。必须与服务端 `nb.js` 的口径一致。
class TextNormalizer {
  const TextNormalizer._();

  /// 全角转半角 + `￥`→`¥` + 去 emoji + 压缩空白。
  static String normalize(String input) {
    if (input.isEmpty) return '';
    final buf = StringBuffer();
    var pendingSpace = false;
    var started = false;
    for (final rune in input.runes) {
      var c = rune;
      if (_isDropped(c)) continue;
      if (c == 0x3000) {
        c = 0x20; // 全角空格
      } else if (c >= 0xFF01 && c <= 0xFF5E) {
        c -= 0xFEE0; // 全角 ASCII
      } else if (c == 0xFFE5) {
        c = 0xA5; // ￥ → ¥
      } else if (c == 0xFFE0) {
        c = 0xA2; // ￠ → ¢
      } else if (c == 0xFFE1) {
        c = 0xA3; // ￡ → £
      }
      if (_isSpace(c)) {
        if (started) pendingSpace = true;
        continue;
      }
      if (pendingSpace) {
        buf.writeCharCode(0x20);
        pendingSpace = false;
      }
      buf.writeCharCode(c);
      started = true;
    }
    return buf.toString();
  }

  /// 分词口径（**跨语言契约**，必须与 `server/src/lib/nb.js` 的 `normalize`
  /// 逐字符一致）：全角 ASCII 折半角 → 小写 → 丢掉所有非「字母/数字」的字符。
  ///
  /// 服务端先做 NFKC 再 `toLowerCase().replace(/[^\p{L}\p{N}]/gu,'')`；
  /// Dart 没有内置 NFKC，这里用「折全角 ASCII + U+3000」覆盖 NFKC 在真实
  /// 通知里唯一会碰到的那一类差异（ＡＢ→ab、￥→丢、．→丢）。
  /// `test/capture/nb_golden_test.dart` 用服务端生成的黄金样本钉住两边一致。
  static String tokenText(String input) {
    if (input.isEmpty) return '';
    final buf = StringBuffer();
    for (final rune in input.runes) {
      if (rune >= 0xFF01 && rune <= 0xFF5E) {
        buf.writeCharCode(rune - 0xFEE0);
      } else if (rune == 0x3000) {
        buf.writeCharCode(0x20);
      } else {
        buf.writeCharCode(rune);
      }
    }
    return buf.toString().toLowerCase().replaceAll(_nonAlphanumeric, '');
  }

  static final RegExp _nonAlphanumeric =
      RegExp(r'[^\p{L}\p{N}]', unicode: true);

  static bool _isSpace(int c) =>
      c == 0x20 ||
      c == 0x09 ||
      c == 0x0A ||
      c == 0x0B ||
      c == 0x0C ||
      c == 0x0D ||
      c == 0xA0;

  /// emoji、变体选择符、零宽连接符等。
  static bool _isDropped(int c) =>
      c == 0x200B ||
      c == 0x200D ||
      c == 0x20E3 ||
      c == 0xFEFF ||
      (c >= 0x2600 && c <= 0x27BF) ||
      (c >= 0x2B00 && c <= 0x2BFF) ||
      (c >= 0xFE00 && c <= 0xFE0F) ||
      (c >= 0x1F000 && c <= 0x1FAFF);
}
