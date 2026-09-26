import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:famledger/ui/perk_import/perk_import_providers.dart';
import 'package:famledger/ui/perk_import/screenshots.dart';

// 截图导入的测试共用：程序画出来的长截图、一张真的小 PNG、假切片和假的切片器（widget 测试里 dart:ui 编码等不到，用现成的结果）。

/// 2×2 的纯红 PNG（74 字节，和服务端看图探测用的是同一张）：Image.memory 解得开，不会在测试里报图片错误。
final Uint8List tinyPng = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEUlEQVR4nGP4z8DwnwGMgRQAH+4D/dJQfRoAAAAASUVORK5CYII=');

/// 画一张 [w]×[h] 的白底黑条纹 PNG（每 400 像素一条，切出来的片各不一样）。要真实的异步：widget 测试里包在 tester.runAsync 里调。
Future<Uint8List> stripedPng(int w, int h) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), ui.Paint()..color = const ui.Color(0xFFFFFFFF));
  for (var y = 0; y < h; y += 400) {
    canvas.drawRect(ui.Rect.fromLTWH(0, y.toDouble(), w.toDouble(), 40), ui.Paint()..color = const ui.Color(0xFF000000));
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(w, h);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

/// PNG 的 IHDR 宽高（第 16–24 字节，大端）。
(int, int) pngSize(Uint8List png) {
  final b = ByteData.sublistView(png);
  return (b.getUint32(16), b.getUint32(20));
}

/// 一片假切片：字节是 [tinyPng]，尺寸照 1080 宽截图切出来的样子写。
ScreenshotSlice fakeSlice(int source, int index, int count) =>
    ScreenshotSlice(source: source, index: index, count: count, png: tinyPng, width: 784, height: 1568);

/// 假的切片器：每张原图切 [perFile] 片，[removed] 里的跳过；[failed] 原样带上；[totalBudget] 调小了走得到「合计太大」。
/// [calls] 记下每次收到的（原图张数, removed）。
ScreenshotPreparer fakePreparer({
  int perFile = 4,
  List<String> failed = const [],
  int totalBudget = kSlicesTotalBytes,
  List<(int, Set<String>)>? calls,
}) => (files, removed, onProgress) async {
  calls?.add((files.length, {...removed}));
  return ScreenshotBatch(
    slices: [
      for (var f = 0; f < files.length; f++)
        for (var k = 0; k < perFile; k++)
          if (!removed.contains('$f-$k')) fakeSlice(f, k, perFile),
    ],
    failed: failed,
    totalBudget: totalBudget,
  );
};

/// 用现成的一批（真切出来的）当切片器的结果。
ScreenshotPreparer fixedPreparer(ScreenshotBatch batch) => (files, removed, onProgress) async => ScreenshotBatch(
  slices: [
    for (final s in batch.slices)
      if (!removed.contains(s.id)) s,
  ],
  failed: batch.failed,
  longEdge: batch.longEdge,
);

/// 选图：回这几张。
ScreenshotPicker pickerOf(List<PickedScreenshot> files) => () async => files;
