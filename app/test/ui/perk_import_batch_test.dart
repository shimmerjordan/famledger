import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assets_harness.dart';
import 'perk_import_fixtures.dart';
import 'perk_import_preview_test.dart' show checkedOf, inTile, openPreview, previewBackend, tileOf;

// 预览页的「领取平台」映射视图和长按多选的批量操作（spec §6「预览」）：可能重复的候选不预选、点了才并入、就是会员本平台、
// 全部确认；批量设价值、不导入、把未归属的移到一张卡下。

void main() {
  testWidgets('领取平台入口写明要确认的个数；只当领取平台用的平台在这里，不在树里', (tester) async {
    await openPreview(tester, previewBackend(), vip88Draft());
    expect(find.text('领取平台 · 5 个'), findsOneWidget);
    expect(find.text('1 个要确认：是新平台，还是账本里已有的'), findsOneWidget);
    await tapVisible(tester, find.byKey(const ValueKey('claim-mapping-entry')));
    for (final k in ['p2', 'p3', 'p4', 'p5', 'p6']) {
      expect(find.byKey(ValueKey('claim-row-$k')), findsOneWidget);
    }
  });

  testWidgets('映射视图：「优酷视频」可能就是已有的「优酷」—— 候选单独一个 chip 不预选，点了才并入，权益行跟着写「去「优酷」领」', (tester) async {
    await openPreview(tester, previewBackend(), vip88Draft());
    await tapVisible(tester, find.byKey(const ValueKey('claim-mapping-entry')));
    final candidate = find.byKey(const ValueKey('claim-p2-candidate-yk'));
    expect(tester.widget<ChoiceChip>(candidate).selected, isFalse, reason: '可能重复只提示、不预选');
    expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('claim-p2-create'))).selected, isTrue);
    await tester.tap(candidate);
    await settle(tester);
    expect(tester.widget<ChoiceChip>(candidate).selected, isTrue);
    await tester.tap(find.byKey(const ValueKey('claim-p3-self')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('claim-confirm-all')));
    await settle(tester);
    expect(inTile('b1', '会籍期内 1 次 · 去「优酷」领'), findsOneWidget);
    expect(inTile('b2', '每年 1 次'), findsOneWidget, reason: '就在会员本平台领，不再写去哪领');
    expect(find.text('什么权益去哪领，点开能并入已有的平台'), findsOneWidget, reason: '选定了就不再「1 个要确认」（Review ㉔）');
    expect(find.byKey(const ValueKey('import-filter-attention')), findsNothing, reason: '需确认的一个都不剩');
  });

  testWidgets('批量：长按进多选，设价值、不导入都只动选中的权益', (tester) async {
    await openPreview(tester, previewBackend(), vip88Draft());
    await tester.longPress(tileOf('b3'));
    await settle(tester);
    await tester.tap(tileOf('b2'));
    await settle(tester);
    expect(find.text('选了 2 项'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('batch-value')));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('batch-value-field')), '5');
    await tester.tap(find.byKey(const ValueKey('batch-value-apply')));
    await settle(tester);
    expect(find.descendant(of: tileOf('b3'), matching: find.textContaining('面值 ¥5.00')), findsOneWidget);
    expect(find.descendant(of: tileOf('b1'), matching: find.textContaining('面值')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('batch-uncheck')));
    await settle(tester);
    await tester.tap(find.byTooltip('退出多选'));
    await settle(tester);
    expect([checkedOf(tester, 'b2'), checkedOf(tester, 'b3'), checkedOf(tester, 'b1')], [false, false, true]);
  });

  testWidgets('未归属：默认不勾、单列一组；多选「移到卡」挂到 88VIP 下就勾上', (tester) async {
    final json = vip88Draft();
    (json['benefits'] as List).add(importNode('b9', 'benefit', {'membership': null, 'parent': null, 'name': '免费停车', 'quota': <Object>[]}, checked: false, badges: const ['missing'], ev: '免费停车'));
    await openPreview(tester, previewBackend(), json);
    expect(find.byKey(const ValueKey('import-unowned')), findsOneWidget);
    expect(checkedOf(tester, 'b9'), isFalse);
    await tester.ensureVisible(tileOf('b9'));
    await tester.longPress(tileOf('b9'));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('batch-move')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('batch-move-key:m1')));
    await settle(tester);
    await tester.tap(find.byTooltip('退出多选'));
    await settle(tester);
    expect(find.byKey(const ValueKey('import-unowned')), findsNothing);
    expect(checkedOf(tester, 'b9'), isTrue);
    expect(find.text('导入 15 项'), findsOneWidget);
  });

  for (final size in kWidths) {
    testWidgets('宽 ${size.width}：多选和映射视图都不溢出', (tester) async {
      await openPreview(tester, previewBackend(), vip88Draft(), size: size);
      await tester.longPress(tileOf('b3'));
      await settle(tester);
      expect(find.text('选了 1 项'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('退出多选'));
      await settle(tester);
      await tapVisible(tester, find.byKey(const ValueKey('claim-mapping-entry')));
      expect(tester.takeException(), isNull);
    });
  }
}
