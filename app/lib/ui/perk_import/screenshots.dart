import 'dart:typed_data';
import 'dart:ui' as ui;

/// 截图导入的客户端处理（spec §6「截图」）：选来的图用 dart:ui 解码；长图（高宽比 > 2.2）切片，每片高 = 宽 × 2、相邻重叠 8%；
/// 每片缩到长边 ≤ 1568 编成 PNG，单片超过 3.5MB 就依次降到 1280、1024。可以删掉单个切片（按 [ScreenshotSlice.id] 记）。
///
/// 两道总量闸（服务端同样守着，这里先说清楚）：一次最多 [kMaxScreenshots] 张原图、合计最多 [kMaxSlices] 片；
/// 合计字节超过 [kSlicesTotalBytes]（base64 后约 7.3MB，塞得进 8MB 的请求体）时整批降一档长边重编，降到 1024 还超就挡住发送。
/// 超过 8 片不自动截掉（会悄悄丢掉长图下半截）：照样切出来，挡住发送，让人删掉不要的那几片。
///
/// 每次加图都把全部原图重切一遍（没有按原图缓存）：合计超限时的降档是整批一起降的，缓存了也得重编；6 张以内的截图，
/// 真机上一轮是秒级。处理中可以「清空」（旧的那轮结果作废），进度按原图报（[ScreenshotProgress]）。

/// 高宽比超过它才切。
const double kSliceAspect = 2.2;

/// 每片高 = 宽 × 2。
const double kSliceHeightRatio = 2;

/// 相邻两片重叠片高的 8%。
const double kSliceOverlap = 0.08;

/// 一次最多几张原图。
const int kMaxScreenshots = 6;

/// 合计最多几片。
const int kMaxSlices = 8;

/// 缩放长边的阶梯：先 1568；单片编出来超过 [kSliceMaxBytes] 往下降。
const List<int> kLongEdges = [1568, 1280, 1024];

/// 单片 PNG 的上限（服务端单张 3.75MB）。
const int kSliceMaxBytes = 3670016; // 3.5MB

/// 合计的 PNG 字节上限。
const int kSlicesTotalBytes = 5767168; // 5.5MB

/// 一片在原图里的位置（整宽，只记纵向）。
class SliceRect {
  const SliceRect(this.top, this.height);

  final int top;
  final int height;

  @override
  bool operator ==(Object other) => other is SliceRect && other.top == top && other.height == height;

  @override
  int get hashCode => Object.hash(top, height);

  @override
  String toString() => 'SliceRect($top, $height)';
}

/// 一张 [width]×[height] 的图怎么切：不够长就整张一片；够长就每片高 = 宽 × 2、步长 = 片高 × 92%，最后一片贴着底边。
List<SliceRect> planSlices(int width, int height) {
  if (width <= 0 || height <= 0) return const [];
  if (height / width <= kSliceAspect) return [SliceRect(0, height)];
  final sliceHeight = (width * kSliceHeightRatio).round();
  final step = (sliceHeight * (1 - kSliceOverlap)).floor();
  final out = <SliceRect>[];
  for (var top = 0; ; top += step) {
    if (top + sliceHeight >= height) {
      out.add(SliceRect(height - sliceHeight, sliceHeight));
      return out;
    }
    out.add(SliceRect(top, sliceHeight));
  }
}

/// 缩到长边不超过 [longEdge]（只缩不放）。
(int, int) fitLongEdge(int width, int height, int longEdge) {
  final long = width > height ? width : height;
  if (long <= longEdge) return (width, height);
  final scale = longEdge / long;
  final w = (width * scale).round();
  final h = (height * scale).round();
  return (w < 1 ? 1 : w, h < 1 ? 1 : h);
}

/// 选来的一张原图。
class PickedScreenshot {
  const PickedScreenshot({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

/// 切好、缩好、编成 PNG 的一片。
class ScreenshotSlice {
  const ScreenshotSlice({
    required this.source,
    required this.index,
    required this.count,
    required this.png,
    required this.width,
    required this.height,
  });

  /// 第几张原图（0 起）。
  final int source;

  /// 这张原图的第几片（0 起）。
  final int index;

  /// 这张原图一共几片。
  final int count;
  final Uint8List png;
  final int width;
  final int height;

  /// 删掉单片时记它：长边降档重编也不变（切法只看原图尺寸）。
  String get id => '$source-$index';

  /// 给人看的叫法：「图 2 的第 1/3 片」（没切的就是「图 2」）。依据块、恢复的草稿都用它说是哪一片。
  String get label => count > 1 ? '图 ${source + 1} 的第 ${index + 1}/$count 片' : '图 ${source + 1}';

  /// 前面的原图删掉了，编号往前挪。
  ScreenshotSlice withSource(int source) =>
      ScreenshotSlice(source: source, index: index, count: count, png: png, width: width, height: height);
}

/// 处理进度：这一轮处理完了几张原图、一共几张。
typedef ScreenshotProgress = void Function(int done, int total);

/// 一批处理结果：留下的切片（按原图、片序）、处理不了的原图（一句话说明）、这次用的长边、合计字节的上限。
class ScreenshotBatch {
  const ScreenshotBatch({this.slices = const [], this.failed = const [], this.longEdge = 1568, this.totalBudget = kSlicesTotalBytes});

  final List<ScreenshotSlice> slices;
  final List<String> failed;
  final int longEdge;

  /// 合计字节的上限（真用时就是 [kSlicesTotalBytes]；测试调小了走得到「降到 1024 还超」）。
  final int totalBudget;

  int get totalBytes => slices.fold(0, (n, s) => n + s.png.length);
  bool get overCount => slices.length > kMaxSlices;
  bool get overBytes => totalBytes > totalBudget;

  /// 换一批切片，别的照旧（删片之后）。
  ScreenshotBatch withSlices(List<ScreenshotSlice> slices) =>
      ScreenshotBatch(slices: slices, failed: failed, longEdge: longEdge, totalBudget: totalBudget);

  /// 能发：有片、不超过 8 片、合计不超过上限。
  bool get sendable => slices.isNotEmpty && !overCount && !overBytes;

  /// 发给模型的估计 token：每片约 宽×高/750（Anthropic 的口径），加提示词约 1500。只是量级提示。
  int get estimatedTokens => 1500 + slices.fold(0, (n, s) => n + (s.width * s.height / 750).ceil());
}

/// 解码 [files]、切片、缩放、编码；[removed] 里的切片跳过。解不开的原图、压不下来的片记进 failed，其余照常。
/// [onProgress] 在第一轮（长边 1568）每处理完一张原图报一次。
/// [sliceBudget] / [totalBudget] 只给测试调小（真用时就是 [kSliceMaxBytes] / [kSlicesTotalBytes]）。
Future<ScreenshotBatch> prepareScreenshots(
  List<PickedScreenshot> files, {
  Set<String> removed = const {},
  ScreenshotProgress? onProgress,
  int sliceBudget = kSliceMaxBytes,
  int totalBudget = kSlicesTotalBytes,
}) async {
  final decoded = <int, ui.Image>{};
  final failed = <String>[];
  try {
    for (var i = 0; i < files.length; i++) {
      try {
        decoded[i] = await _decode(files[i].bytes);
      } catch (_) {
        failed.add('「${files[i].name}」打不开，换成 PNG 或 JPG 截图再试');
      }
    }
    var batch = ScreenshotBatch(failed: failed, totalBudget: totalBudget);
    for (final edge in kLongEdges) {
      final slices = <ScreenshotSlice>[];
      final tooBig = <String>[];
      for (final MapEntry(key: source, value: image) in decoded.entries) {
        final plan = planSlices(image.width, image.height);
        for (var k = 0; k < plan.length; k++) {
          if (removed.contains('$source-$k')) continue;
          final slice = await _slice(image, plan[k], edge, sliceBudget, source: source, index: k, count: plan.length);
          if (slice == null) {
            // PNG 压不下来是内容太花（照片、噪点），不是不够清楚：越清楚越大。
            tooBig.add('「${files[source].name}」第 ${k + 1} 片内容太花，压不到 3.5MB 以下：换成普通截图，或者裁小一点');
          } else {
            slices.add(slice);
          }
        }
        if (edge == kLongEdges.first) onProgress?.call(source + 1, files.length);
      }
      batch = ScreenshotBatch(slices: slices, failed: [...failed, ...tooBig], longEdge: edge, totalBudget: totalBudget);
      if (batch.totalBytes <= totalBudget) break;
    }
    return batch;
  } finally {
    for (final image in decoded.values) {
      image.dispose();
    }
  }
}

Future<ui.Image> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}

/// 一片：从 [edge] 起按阶梯往下试，编出来不超过 [budget] 就用；都超了回 null。
Future<ScreenshotSlice?> _slice(ui.Image image, SliceRect rect, int edge, int budget, {required int source, required int index, required int count}) async {
  for (final e in kLongEdges.where((x) => x <= edge)) {
    final (w, h) = fitLongEdge(image.width, rect.height, e);
    final png = await _render(image, rect, w, h);
    if (png.length <= budget) {
      return ScreenshotSlice(source: source, index: index, count: count, png: png, width: w, height: h);
    }
  }
  return null;
}

Future<Uint8List> _render(ui.Image image, SliceRect rect, int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawImageRect(
    image,
    ui.Rect.fromLTWH(0, rect.top.toDouble(), image.width.toDouble(), rect.height.toDouble()),
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..filterQuality = ui.FilterQuality.medium,
  );
  final picture = recorder.endRecording();
  final out = await picture.toImage(width, height);
  picture.dispose();
  try {
    final data = await out.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    out.dispose();
  }
}
