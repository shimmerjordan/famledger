import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assets_harness.dart';

// P2 验收（spec §7）：手工建出 88VIP 和它的 3 项权益，其中 1 项是去优酷领。
// 从一张卡都没有的空库开始，全程走真的表单、平台选择和路由；假服务端记得住写进去的东西。

Future<void> addBenefit(
  WidgetTester tester, {
  required String name,
  required String kind,
  required String preset,
  String? count,
  String? claimPlatform,
}) async {
  await tapVisible(tester, find.text('加一项'));
  await tester.enterText(find.byKey(const ValueKey('benefit-name')), name);
  await tapVisible(tester, find.byKey(ValueKey('benefit-kind-$kind')));
  await tapVisible(tester, find.byKey(ValueKey('quota-preset-$preset')));
  if (count != null) await tester.enterText(find.byKey(const ValueKey('quota-count')), count);
  if (claimPlatform != null) {
    await tapVisible(tester, find.byKey(const ValueKey('benefit-claim-platform')));
    await tester.enterText(find.byKey(const ValueKey('platform-search')), claimPlatform);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('platform-create')));
    await settle(tester);
  }
  await tapVisible(tester, find.widgetWithText(FilledButton, '加好了'));
}

void main() {
  testWidgets('验收：从空库手工建出 88VIP 和 3 项权益，其中「优酷年卡」去优酷领；两种分组都看得到', (tester) async {
    final backend = AssetsBackend();
    await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=perks', size: const Size(400, 2400));

    // 1. 空态 → 记一张：就地新建平台「淘宝」，名字 88VIP，续费价 88/年。
    await tapVisible(tester, find.text('记一张'));
    await tapVisible(tester, find.byKey(const ValueKey('membership-platform')));
    await tester.enterText(find.byKey(const ValueKey('platform-search')), '淘宝');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('platform-create')));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('membership-name')), '88VIP');
    await tapVisible(tester, find.text('更多'));
    await tester.enterText(find.byKey(const ValueKey('membership-fee')), '88');
    await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
    expect(find.text('权益 · 0 项'), findsOneWidget, reason: '建完直接在详情页');

    // 2. 三项权益：优酷年卡（去优酷领、会籍期内 1 次）、购物券（每月 4 次）、95 折（不限次）。
    await addBenefit(tester, name: '优酷年卡', kind: 'subscription', preset: 'termOnce', claimPlatform: '优酷');
    await addBenefit(tester, name: '购物券', kind: 'coupon', preset: 'monthly', count: '4');
    await addBenefit(tester, name: '天猫超市 95 折', kind: 'discount', preset: 'unlimited');
    expect(find.text('权益 · 3 项'), findsOneWidget);
    expect(find.text('去优酷领'), findsOneWidget);

    final platforms = {for (final p in backend.perks.platforms.values) p['name']: p['id']};
    expect(platforms.keys.toSet(), {'淘宝', '优酷'});
    final vip = backend.perks.memberships.values.single;
    expect(vip['name'], '88VIP');
    expect(vip['platformId'], platforms['淘宝']);
    expect(vip['feeCents'], 8800);
    final perks = backend.perks.benefits.values.toList();
    expect(perks.map((b) => b['name']), ['优酷年卡', '购物券', '天猫超市 95 折']);
    expect(perks.every((b) => b['membershipId'] == vip['id']), isTrue);
    expect(perks.where((b) => b['claimPlatformId'] == platforms['优酷']).map((b) => b['name']), ['优酷年卡']);

    // 3. 回到会员权益 tab（默认是「本期」），切到「全部」：按会员、按领取平台都看得到。
    await tester.pageBack();
    await settle(tester);
    await tapVisible(tester, find.byKey(const ValueKey('perk-view-all')));
    expect(find.text('淘宝 · 全家共用 · 3 项权益 · 长期有效'), findsOneWidget);
    expect(find.text('去优酷领'), findsOneWidget);
    await tapVisible(tester, find.text('按领取平台'));
    expect(find.text('淘宝 · 2 项'), findsOneWidget);
    expect(find.text('优酷 · 1 项'), findsOneWidget);
    expect(find.text('来自 88VIP · 会籍期内 1 次'), findsOneWidget);
  });
}
