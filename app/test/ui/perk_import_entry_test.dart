import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assets_harness.dart';
import 'perk_import_page_test.dart' show importBackend;
import 'perks_fake.dart';

// AI 导入的四个入口（spec §6「入口」）：物品 tab 的「智能导入」（预选只要实物）、会员权益 tab 的「+」、会员权益空状态的主按钮、
// 会员详情的「AI 补充权益」（带 targetMembershipId）。

void main() {
  testWidgets('物品 tab 的 AppBar 有「智能导入」，预选只要实物；投资、会员权益 tab 没有', (tester) async {
    await pumpAssetsAt(tester, bootAssets(importBackend()), '/assets');
    await tester.tap(find.byTooltip('智能导入'));
    await settle(tester);
    expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('import-want-items'))).selected, isTrue);
    await tester.pageBack();
    await settle(tester);
    await tester.tap(find.text('投资'));
    await settle(tester);
    expect(find.byTooltip('智能导入'), findsNothing);
    await tester.tap(find.text('会员权益'));
    await settle(tester);
    expect(find.byTooltip('智能导入'), findsNothing);
  });

  testWidgets('从物品 tab 进来导的是会员（Review ㉚）：「去看看」切到会员权益的本期，看得到刚导的卡', (tester) async {
    final backend = importBackend();
    await pumpAssetsAt(tester, bootAssets(backend), '/assets');
    await tester.tap(find.byTooltip('智能导入'));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('import-text')), '88VIP 会员说明');
    await tester.pump();
    await tapVisible(tester, find.byKey(const ValueKey('import-start')));
    await tapVisible(tester, find.byKey(const ValueKey('perk-import-submit')));
    await tapVisible(tester, find.byKey(const ValueKey('perk-import-go')));
    expect(find.byTooltip('智能导入'), findsNothing, reason: '不在物品 tab 了');
    expect(find.text('本期'), findsWidgets);
    expect(find.text('88VIP'), findsWidgets);
  });

  testWidgets('会员权益 tab 的「+」先给智能导入（预选只要会员权益），也能手动记一张', (tester) async {
    final backend = importBackend();
    backend.perks.memberships['vip'] = membershipJson('vip');
    await pumpAssetsAt(tester, bootAssets(backend, store: allViewStore()), '/assets?tab=perks');
    await tester.tap(find.byTooltip('记一张会员卡'));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('perks-add-ai')));
    await settle(tester);
    expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('import-want-virtual'))).selected, isTrue);
    await tester.pageBack();
    await settle(tester);
    await tester.tap(find.byTooltip('记一张会员卡'));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('perks-add-manual')));
    await settle(tester);
    expect(find.text('记一张会员卡'), findsOneWidget);
  });

  testWidgets('会员权益空状态：主按钮是智能导入，下面还能手动记一张', (tester) async {
    await pumpAssetsAt(tester, bootAssets(importBackend()), '/assets?tab=perks');
    expect(find.text('还没记会员卡'), findsOneWidget);
    await tapVisible(tester, find.text('智能导入'));
    expect(find.byKey(const ValueKey('import-text')), findsOneWidget);
    await tester.pageBack();
    await settle(tester);
    await tapVisible(tester, find.byKey(const ValueKey('perks-empty-manual')));
    expect(find.text('记一张会员卡'), findsOneWidget);
  });

  testWidgets('会员详情的「AI 补充权益」打开导入页并带上这张卡；归档的卡没有这个按钮', (tester) async {
    final backend = importBackend();
    backend.perks.memberships['vip'] = membershipJson('vip');
    backend.perks.memberships['old'] = membershipJson('old', name: '旧卡', archived: true);
    await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/vip');
    await tapVisible(tester, find.byKey(const ValueKey('membership-ai-import')));
    expect(find.text('识别出的权益都归到「88VIP」，导入前可以逐条改。'), findsOneWidget);
    await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/old');
    expect(find.byKey(const ValueKey('membership-ai-import')), findsNothing);
  });
}
