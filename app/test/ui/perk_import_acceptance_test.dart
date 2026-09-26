import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assets_harness.dart';
import 'perk_import_fixtures.dart';
import 'perks_fake.dart';

// P4 验收（spec §7）：
//   ① 粘贴一段 88VIP 权益说明 → 预览里改领取平台 → 导入 → 在本期视图里能看到；
//   ② 粘贴一段订单文字 → 预览里物品默认关联到唯一匹配的流水 → 导入后物品带估值、没有重复记账。
// 假服务端回的草稿照服务端真实输出写（perk_import_fixtures.dart）；服务端那一半的验收在 server/test/asset_import_apply.test.js。

void main() {
  testWidgets('验收 ①：88VIP 说明 → 领取平台「优酷视频」并入已有的「优酷」→ 导入 → 本期待领里「优酷 · 1 项」有优酷视频年卡', (tester) async {
    final backend = AssetsBackend(perks: PerksFake(platforms: [platformJson('tb'), platformJson('yk', name: '优酷', sort: 1)]));
    backend.imports.draft = vip88Draft();
    await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=perks', size: const Size(400, 2400));

    await tapVisible(tester, find.text('智能导入'));
    await tester.enterText(find.byKey(const ValueKey('import-text')), vip88Source);
    await tapVisible(tester, find.byKey(const ValueKey('import-start')));
    expect(backend.imports.extractBodies.single['want'], 'virtual');

    await tapVisible(tester, find.byKey(const ValueKey('claim-mapping-entry')));
    await tester.tap(find.byKey(const ValueKey('claim-p2-candidate-yk')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('claim-confirm-all')));
    await settle(tester);
    await tapVisible(tester, find.byKey(const ValueKey('perk-import-submit')));

    final p2 = (backend.imports.applyBodies.single['platforms'] as List).cast<Map<String, dynamic>>().firstWhere((p) => p['key'] == 'p2');
    expect([p2['action'], p2['targetId']], ['merge', 'yk']);
    expect(backend.perks.platforms['yk']!['aliases'], ['优酷视频'], reason: '并入时名字记成已有平台的别名');
    expect(find.byKey(const ValueKey('perk-import-result-title')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('perk-import-go')));
    await settle(tester);
    expect(find.descendant(of: find.byKey(const ValueKey('current-group-yk')), matching: find.text('优酷 · 1 项')), findsOneWidget);
    expect(find.byKey(const ValueKey('current-b-imp-b1')), findsOneWidget);
    expect(find.text('优酷视频年卡'), findsOneWidget);
  });

  testWidgets('验收 ②：订单文字 → 物品默认关联唯一那笔流水 → 导入后带估值、没另记账', (tester) async {
    final backend = AssetsBackend();
    backend.imports.draft = orderDraft();
    await pumpAssetsAt(tester, bootAssets(backend), '/assets', size: const Size(400, 2000));

    await tester.tap(find.byTooltip('智能导入'));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('import-text')), orderSource);
    await tapVisible(tester, find.byKey(const ValueKey('import-start')));
    expect(backend.imports.extractBodies.single['want'], 'items');

    expect(find.textContaining('关联 09-21 Apple Store 的支出'), findsOneWidget, reason: '唯一一笔同金额、日期 ±3 天的支出默认关联');
    await tapVisible(tester, find.byKey(const ValueKey('perk-import-submit')));
    final item = (backend.imports.applyBodies.single['items'] as List).single as Map<String, dynamic>;
    expect(item['linkTransactionId'], 'tx-phone');
    expect(item.containsKey('recordTransaction'), isFalse);
    expect(backend.imports.recordedTransactions, 0, reason: '没有重复记账');
    expect(find.text('新建：物品 1 件'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('perk-import-go')));
    await settle(tester);
    expect(find.text('iPhone 16 Pro 256GB'), findsOneWidget);
    expect(find.textContaining('估值 ¥8,98'), findsWidgets, reason: '按预设 apple（每年打八折）算出来的估值：汇总和这一行都有');
    final row = backend.assets['a-imp-i1']!;
    expect([row['transactionId'], row['valuationMethod'], row['rateBp'], row['residualBp']], ['tx-phone', 'declining', 2000, 1000]);
  });
}
