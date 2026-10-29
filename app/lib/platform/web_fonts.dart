import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// 网页版：第一帧之前先把中文字体拉下来。
///
/// CanvasKit 只自带 Roboto，第一次遇到汉字才去 Google Fonts 下 Noto Sans SC，
/// 下完发一条 `fontsChange` 让所有文字重排。但 Flutter 3.32 的 RenderParagraph
/// 只重排「画出来」那个 TextPainter，算「本来该多宽」的那个（intrinsics）还留着
/// 没字体时的旧尺寸——于是凡是按文字本来宽度定大小的控件（SegmentedButton、
/// Chip、IntrinsicWidth）四个字的标签会折成两行，刷新页面也一样。
///
/// 这里在 runApp 前先排一段汉字触发下载，等到 `fontsChange` 再画第一帧，
/// 所有尺寸从一开始就是对的；顺便也没有了「先一帧空框再出字」。
/// 断网 / 太慢就到 [timeout] 为止照常启动，不卡死。手机和桌面端用系统字体，直接返回。
///
/// [isWeb] / [systemFonts] / [layoutProbe] 只是给测试注入用的。
Future<void> warmUpCjkFallbackFonts({
  Duration timeout = const Duration(seconds: 4),
  bool? isWeb,
  Listenable? systemFonts,
  void Function()? layoutProbe,
}) async {
  if (!(isWeb ?? kIsWeb)) return;
  final fonts = systemFonts ?? PaintingBinding.instance.systemFonts;
  final arrived = Completer<void>();
  void onFontsChange() {
    if (!arrived.isCompleted) arrived.complete();
  }

  fonts.addListener(onFontsChange);
  try {
    try {
      (layoutProbe ?? _layoutCjkProbe)();
    } catch (_) {
      // 排版探针都失败了就别拦着启动，让正常的懒加载去处理。
      return;
    }
    await arrived.future.timeout(timeout, onTimeout: () {});
  } finally {
    fonts.removeListener(onFontsChange);
  }
}

/// 排一行覆盖常用字的汉字：缺字就会触发回退字体下载。
void _layoutCjkProbe() {
  final builder = ui.ParagraphBuilder(ui.ParagraphStyle())..addText('家账：支出收入转账理财债务');
  final paragraph = builder.build()..layout(const ui.ParagraphConstraints(width: 400));
  paragraph.dispose();
}
