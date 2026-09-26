import 'dart:typed_data';

import 'package:famledger/ui/perk_import/screenshots.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screenshot_fixtures.dart';

// 截图的客户端切片与缩放（spec §6「截图」、§8「切片：1080×8000 的图切成 4 片，每片 ≤1568」）。
// 几何是纯函数；真编码走 dart:ui（flutter_tester 里有引擎），用程序画出来的 PNG 当原图。

void main() {
  test('切法：1080×8000 → 4 片，每片 2160 高、步长 1987（重叠 8%），最后一片贴底；不够长整张一片；空图没有片', () {
    expect(planSlices(1080, 8000), const [SliceRect(0, 2160), SliceRect(1987, 2160), SliceRect(3974, 2160), SliceRect(5840, 2160)]);
    expect(planSlices(1080, 2376), const [SliceRect(0, 2376)], reason: '高宽比正好 2.2 不切');
    expect(planSlices(1080, 2377).length, 2);
    expect(planSlices(3000, 1000), const [SliceRect(0, 1000)], reason: '横图不切');
    expect(planSlices(0, 100), isEmpty);
    final plan = planSlices(1080, 8000);
    for (var i = 1; i < plan.length; i++) {
      expect(plan[i - 1].top + plan[i - 1].height - plan[i].top, greaterThanOrEqualTo((2160 * 0.08).floor()), reason: '相邻两片至少重叠 8%');
    }
  });

  test('缩放：长边缩到 1568（只缩不放）', () {
    expect(fitLongEdge(1080, 2160, 1568), (784, 1568));
    expect(fitLongEdge(500, 800, 1568), (500, 800));
    expect(fitLongEdge(3000, 1000, 1568), (1568, 523));
    expect(fitLongEdge(1080, 2160, 1024), (512, 1024));
  });

  test('验收：1080×8000 的真截图 → 4 片 PNG，每片 784×1568；删掉一片后按原来的编号跳过；打不开的图单独说、不连累别的', () async {
    final long = await stripedPng(1080, 8000);
    final batch = await prepareScreenshots([PickedScreenshot(name: 'order.png', bytes: long)]);
    expect(batch.failed, isEmpty);
    expect(batch.longEdge, 1568);
    expect(batch.slices.map((s) => s.id), ['0-0', '0-1', '0-2', '0-3']);
    for (final s in batch.slices) {
      expect((s.width, s.height), (784, 1568));
      expect(pngSize(s.png), (784, 1568));
      expect(s.png.length, lessThanOrEqualTo(kSliceMaxBytes));
      expect(s.count, 4);
    }
    expect(batch.sendable, isTrue);
    expect(batch.estimatedTokens, 1500 + 4 * (784 * 1568 / 750).ceil());

    final trimmed = await prepareScreenshots(
      [PickedScreenshot(name: 'broken.heic', bytes: Uint8List.fromList(List.filled(64, 7))), PickedScreenshot(name: 'order.png', bytes: long)],
      removed: {'1-2'},
    );
    expect(trimmed.slices.map((s) => s.id), ['1-0', '1-1', '1-3']);
    expect(trimmed.failed, ['「broken.heic」打不开，换成 PNG 或 JPG 截图再试']);
  });

  test('超过 8 片不自动截掉、挡住发送；单片压不下来记进 failed；合计超了整批降档，降到 1024 还超就挡住', () async {
    final tall = await stripedPng(100, 1000); // 每张 6 片
    final many = await prepareScreenshots([PickedScreenshot(name: 'a.png', bytes: tall), PickedScreenshot(name: 'b.png', bytes: tall)]);
    expect(many.slices.length, 12);
    expect((many.overCount, many.sendable), (true, false));

    final small = await stripedPng(600, 800);
    final noSlice = await prepareScreenshots([PickedScreenshot(name: 'c.png', bytes: small)], sliceBudget: 10);
    expect(noSlice.slices, isEmpty);
    expect(noSlice.failed, ['「c.png」第 1 片内容太花，压不到 3.5MB 以下：换成普通截图，或者裁小一点']);

    final big = await stripedPng(1080, 8000);
    final progress = <(int, int)>[];
    final squeezed = await prepareScreenshots(
      [PickedScreenshot(name: 'd.png', bytes: big)],
      totalBudget: 1,
      onProgress: (done, total) => progress.add((done, total)),
    );
    expect(squeezed.longEdge, 1024, reason: '1568、1280 都超了，降到最后一档');
    expect(squeezed.slices.map((s) => (s.width, s.height)).toSet(), {(512, 1024)});
    expect((squeezed.overBytes, squeezed.sendable), (true, false), reason: '降到 1024 还超就挡住（上限跟着这一批走，不是写死的常量）');
    expect(progress, [(1, 1)], reason: '第一轮每处理完一张原图报一次，降档重编不重复报');
  });

  test('切片的叫法：「图 2 的第 1/3 片」，没切的是「图 2」；前面的原图删了编号往前挪，别的都不变', () {
    final s = ScreenshotSlice(source: 1, index: 0, count: 3, png: Uint8List(4), width: 784, height: 1568);
    expect(s.label, '图 2 的第 1/3 片');
    expect(ScreenshotSlice(source: 1, index: 0, count: 1, png: Uint8List(4), width: 1, height: 1).label, '图 2');
    final moved = s.withSource(0);
    expect([moved.id, moved.label, moved.index, moved.count, moved.width, moved.height], ['0-0', '图 1 的第 1/3 片', 0, 3, 784, 1568]);
    final batch = ScreenshotBatch(slices: [s], totalBudget: 2);
    expect(batch.withSlices([moved]).totalBudget, 2, reason: '删片之后上限不丢');
  });

  test('合计字节超过 5.5MB 就不能发', () {
    final fat = ScreenshotSlice(source: 0, index: 0, count: 1, png: Uint8List(kSlicesTotalBytes + 1), width: 1000, height: 1000);
    final batch = ScreenshotBatch(slices: [fat]);
    expect((batch.overBytes, batch.sendable), (true, false));
    expect(const ScreenshotBatch().sendable, isFalse, reason: '一片都没有也不能发');
  });
}
