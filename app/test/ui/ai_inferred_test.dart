import 'package:famledger/ui/perks/benefit_form_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assets_harness.dart';
import 'perks_fake.dart';

// 「AI 推断」小点（spec §5、§6）：导入写进 origin.unverified 的字段在详情页旁边点一个点；点开说依据，
// 「没错」把它从 unverified 拿掉（PATCH origin），「去改」打开编辑页。会员、权益、物品三处。

const Map<String, dynamic> _origin = {'src': 'ai_text', 'importId': 'imp-1', 'ev': '到期日 2026-12-31', 'unverified': ['expiresOn']};

void main() {
  testWidgets('会员详情：到期日旁边有小点；「没错」把 origin.unverified 里的 expiresOn 拿掉，小点消失', (tester) async {
    final backend = AssetsBackend(
      perks: PerksFake(platforms: [platformJson('tb')], memberships: [membershipJson('vip', expiresOn: '2026-12-31')..['origin'] = _origin]),
    );
    await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/vip');
    expect(find.byKey(const ValueKey('ai-dot-feeCents')), findsNothing, reason: '没推断的字段没有点');
    await tapVisible(tester, find.byKey(const ValueKey('ai-dot-expiresOn')));
    expect(find.text('「到期日」是 AI 推断的'), findsOneWidget);
    expect(find.text('依据：「到期日 2026-12-31」'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ai-dot-confirm')));
    await settle(tester);
    expect(backend.lastBody('PATCH', '/memberships/vip'), {
      'origin': {'src': 'ai_text', 'importId': 'imp-1', 'ev': '到期日 2026-12-31', 'unverified': <String>[]},
    });
    expect(find.byKey(const ValueKey('ai-dot-expiresOn')), findsNothing);
  });

  testWidgets('权益：一行一个点，写明是哪几个字段；「去改」打开编辑页', (tester) async {
    final backend = AssetsBackend(
      perks: PerksFake(
        platforms: [platformJson('tb')],
        memberships: [membershipJson('vip')],
        benefits: [
          benefitJson('b1', name: '优酷年卡')..['origin'] = {'src': 'ai_text', 'unverified': ['claimPlatformId', 'quota']},
        ],
      ),
    );
    await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/vip');
    await tapVisible(tester, find.byKey(const ValueKey('ai-dot-benefit-b1')));
    expect(find.text('「领取平台、额度」是 AI 推断的'), findsOneWidget);
    expect(find.text('导入时材料里没找到明确的依据，核对一下。'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ai-dot-edit')));
    await settle(tester);
    expect(find.byType(BenefitFormPage), findsOneWidget);
  });

  testWidgets('物品详情：买入日期旁边有小点，「没错」PATCH /assets/:id 的 origin', (tester) async {
    final backend = AssetsBackend(assets: [
      {...assetJson('a1'), 'origin': {'src': 'ai_text', 'ev': '下单时间 9 月 1 日', 'unverified': ['purchasedOn']}},
    ]);
    await pumpAssetsAt(tester, bootAssets(backend), '/assets/items/a1');
    expect(find.byKey(const ValueKey('ai-dot-priceCents')), findsNothing);
    await tapVisible(tester, find.byKey(const ValueKey('ai-dot-purchasedOn')));
    expect(find.text('「买入日期」是 AI 推断的'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ai-dot-confirm')));
    await settle(tester);
    expect(backend.lastBody('PATCH', '/assets/a1'), {
      'origin': {'src': 'ai_text', 'ev': '下单时间 9 月 1 日', 'unverified': <String>[]},
    });
    expect(find.byKey(const ValueKey('ai-dot-purchasedOn')), findsNothing);
  });
}
