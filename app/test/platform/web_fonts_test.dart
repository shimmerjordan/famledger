import 'package:famledger/platform/web_fonts.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

class _Fonts extends ChangeNotifier {
  bool get listened => hasListeners;
  void arrive() => notifyListeners();
}

void main() {
  test('不是网页端：直接返回，不挂监听也不排版', () async {
    final fonts = _Fonts();
    var probed = false;
    await warmUpCjkFallbackFonts(isWeb: false, systemFonts: fonts, layoutProbe: () => probed = true);
    expect(probed, isFalse);
    expect(fonts.listened, isFalse);
  });

  test('网页端：排版探针触发下载，字体到了就放行，监听摘掉', () async {
    final fonts = _Fonts();
    var probed = false;
    final done = warmUpCjkFallbackFonts(
      isWeb: true,
      systemFonts: fonts,
      layoutProbe: () => probed = true,
      timeout: const Duration(seconds: 10),
    );
    expect(probed, isTrue);
    expect(fonts.listened, isTrue);
    fonts.arrive();
    await done.timeout(const Duration(seconds: 1));
    expect(fonts.listened, isFalse);
    // 后面再来 fontsChange 也不会炸（Completer 只完成一次）。
    fonts.arrive();
  });

  test('网页端：字体一直不来，到超时就照常启动', () async {
    final fonts = _Fonts();
    final sw = Stopwatch()..start();
    await warmUpCjkFallbackFonts(
      isWeb: true,
      systemFonts: fonts,
      layoutProbe: () {},
      timeout: const Duration(milliseconds: 50),
    );
    expect(sw.elapsed, lessThan(const Duration(seconds: 1)));
    expect(fonts.listened, isFalse);
  });

  test('网页端：探针自己抛了，不拦启动，监听也摘掉', () async {
    final fonts = _Fonts();
    await warmUpCjkFallbackFonts(
      isWeb: true,
      systemFonts: fonts,
      layoutProbe: () => throw StateError('no canvas'),
      timeout: const Duration(seconds: 10),
    );
    expect(fonts.listened, isFalse);
  });
}
