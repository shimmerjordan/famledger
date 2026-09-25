import 'package:famledger/ui/perks/benefit_form_page.dart';
import 'package:famledger/ui/perks/membership_detail_page.dart';
import 'package:famledger/ui/perks/membership_form_page.dart';
import 'package:famledger/ui/perks/perk_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assets_harness.dart';
import 'perks_fake.dart';

const Size tall = Size(400, 2200);

/// 88VIP：优酷年卡（去优酷领，有领取路径、面值、限制、有效期）带出了「优酷VIP」；二选一带一个选项。
AssetsBackend detailBackend() => AssetsBackend(
  perks: PerksFake(
    platforms: [platformJson('tb', name: '淘宝'), platformJson('yk', name: '优酷', sort: 1)],
    memberships: [
      membershipJson('vip', feeCents: 8800, termPaidCents: 0, termStartOn: '2026-03-01', expiresOn: '2027-02-28'),
      membershipJson('ykvip', platformId: 'yk', name: '优酷VIP', sourceBenefitId: 'b1', sort: 1),
    ],
    benefits: [
      benefitJson('b1', name: '优酷年卡', kind: 'subscription', claimPlatformId: 'yk', claimHow: '优酷App › 我的', faceValueCents: 24800, validUntil: '2026-12-31', quota: [
        {'p': 'term', 'n': 1},
      ], limits: [
        {'type': 'holder', 'text': '仅限本人'},
      ]),
      benefitJson('c1', name: '年卡二选一', kind: 'choice', quota: [
        {'p': 'year', 'n': 1},
      ], sort: 1),
      benefitJson('o1', parentId: 'c1', name: '芒果年卡', sort: 2),
    ],
  ),
);

void main() {
  group('会员详情', () {
    testWidgets('头部信息、权益（去优酷领、领取路径、有效期、面值、限制、已带出的卡）、N 选 1 的选项', (tester) async {
      await pumpAssetsAt(tester, bootAssets(detailBackend()), '/assets/memberships/vip', size: tall);
      expect(find.text('淘宝 · 会员'), findsOneWidget);
      expect(find.text('全家共用'), findsOneWidget);
      expect(find.text('还有 158 天到期'), findsOneWidget);
      expect(find.text('2026-03-01 至 2027-02-28'), findsOneWidget);
      expect(find.text('¥88.00/年'), findsOneWidget);
      expect(find.text('免费'), findsOneWidget, reason: '本期实付 0');
      expect(find.text('权益 · 2 项'), findsOneWidget, reason: '优酷年卡 + 二选一的 1 个选项');

      expect(find.text('去优酷领'), findsOneWidget);
      expect(
        find.text('会员/年卡 · 会籍期内 1 次\n领取：优酷App › 我的\n有效期至 2026-12-31\n面值 ¥248.00\n已带出：优酷 · 优酷VIP'),
        findsOneWidget,
      );
      expect(find.text('持有人 仅限本人'), findsOneWidget);
      expect(find.text('芒果年卡'), findsOneWidget);
      expect(find.byKey(const ValueKey('add-option-c1')), findsOneWidget);
    });

    testWidgets('派生会员写明来自哪张卡的哪项权益，点过去是那张卡', (tester) async {
      await pumpAssetsAt(tester, bootAssets(detailBackend()), '/assets/memberships/ykvip', size: tall);
      expect(find.text('88VIP · 优酷年卡'), findsOneWidget);
      await tapVisible(tester, find.byKey(const ValueKey('membership-source')));
      expect(find.text('淘宝 · 会员'), findsOneWidget);
    });

    testWidgets('归档 / 取消归档', (tester) async {
      final backend = detailBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/vip', size: tall);
      await tapVisible(tester, find.byKey(const ValueKey('membership-archive')));
      expect(backend.lastBody('PATCH', '/memberships/vip'), {'archived': true});
      expect(find.text('淘宝 · 会员 · 已归档'), findsOneWidget);
      await tapVisible(tester, find.byKey(const ValueKey('membership-archive')));
      expect(backend.lastBody('PATCH', '/memberships/vip'), {'archived': false});
    });

    testWidgets('删除：项数和「权益 · 2 项」一个数法、派生卡留着；确认后 cascade，退回上一页', (tester) async {
      final backend = detailBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/vip', size: tall);
      await tapVisible(tester, find.byKey(const ValueKey('membership-delete')));
      expect(
        find.text('它名下的 2 项权益和打卡记录会一起删掉；由这些权益带出来的别的卡会留着，只是不再关联。'),
        findsOneWidget,
        reason: 'N 选 1 本身不算一项，算它的选项 —— 和页面上的标题对得上',
      );
      await tester.tap(find.widgetWithText(FilledButton, '删掉'));
      await settle(tester);
      expect(backend.requests('DELETE', '/memberships/vip').single.url.queryParameters, {'cascade': '1'});
      expect(backend.perks.memberships['ykvip']?['sourceBenefitId'], isNull);
      expect(find.text('已删掉'), findsOneWidget);
      expect(backend.perks.memberships.keys, ['ykvip'], reason: '派生卡还在');
      expect(find.byType(MembershipDetailPage), findsNothing, reason: '删完退回上一页');
    });

    testWidgets('本地没有权益、服务端却有（别的设备刚加的）：409 后按服务端的数再问一次', (tester) async {
      final backend = AssetsBackend(
        perks: PerksFake(platforms: [platformJson('tb', name: '淘宝')], memberships: [membershipJson('vip')]),
      );
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/vip', size: tall);
      // 服务端多了两项，这台还没同步到：删的时候才撞上。
      backend.perks.benefits['x1'] = benefitJson('x1', name: '新券');
      backend.perks.benefits['x2'] = benefitJson('x2', name: '新券2');

      await tapVisible(tester, find.byKey(const ValueKey('membership-delete')));
      expect(find.text('删掉后找不回来。'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '删掉'));
      await settle(tester);
      expect(find.text('别的设备刚给它加了权益。它名下的 2 项权益（含选项）和打卡记录会一起删掉；由这些权益带出来的别的卡会留着，只是不再关联。'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '删掉'));
      await settle(tester);
      final deletes = backend.requests('DELETE', '/memberships/vip');
      expect(deletes.map((r) => r.url.queryParameters), [<String, String>{}, {'cascade': '1'}]);
      expect(backend.perks.memberships, isEmpty);
    });

    testWidgets('第二次也点「算了」：什么都不删，按钮恢复可点', (tester) async {
      final backend = AssetsBackend(
        perks: PerksFake(platforms: [platformJson('tb', name: '淘宝')], memberships: [membershipJson('vip')]),
      );
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/vip', size: tall);
      backend.perks.benefits['x1'] = benefitJson('x1', name: '新券');
      await tapVisible(tester, find.byKey(const ValueKey('membership-delete')));
      await tester.tap(find.widgetWithText(FilledButton, '删掉'));
      await settle(tester);
      await tester.tap(find.text('算了'));
      await settle(tester);
      expect(backend.perks.memberships, hasLength(1));
      expect(tester.widget<OutlinedButton>(find.byKey(const ValueKey('membership-delete'))).onPressed, isNotNull);
    });

    testWidgets('归档的权益收在底部「已归档」（归档的 N 选 1 连选项一起收）；点开能改；删卡时另外说', (tester) async {
      final backend = detailBackend();
      backend.perks.benefits['a1'] = benefitJson('a1', name: '去年的券', archived: true, sort: 3);
      backend.perks.benefits['c2'] = benefitJson('c2', name: '旧的二选一', kind: 'choice', archived: true, sort: 4);
      backend.perks.benefits['o2'] = benefitJson('o2', parentId: 'c2', name: '旧选项', sort: 5);
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/vip', size: tall);
      expect(find.text('权益 · 2 项'), findsOneWidget, reason: '归档的不算');
      expect(find.text('去年的券'), findsNothing);
      expect(find.text('旧选项'), findsNothing, reason: '父权益归档了，选项不能冒出来当顶层画');

      await tapVisible(tester, find.text('已归档 · 2 项'));
      expect(find.text('去年的券'), findsOneWidget);
      expect(find.text('旧选项'), findsOneWidget);

      await tapVisible(tester, find.byKey(const ValueKey('membership-delete')));
      expect(
        find.text('它名下的 2 项权益、2 项已归档的权益和打卡记录会一起删掉；由这些权益带出来的别的卡会留着，只是不再关联。'),
        findsOneWidget,
      );
      await tester.tap(find.text('算了'));
      await settle(tester);

      await tapVisible(tester, find.text('去年的券'));
      expect(find.byType(BenefitFormPage), findsOneWidget);
      expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('benefit-archived'))).value, isTrue);
      await tapVisible(tester, find.byKey(const ValueKey('benefit-archived')));
      await tapVisible(tester, find.widgetWithText(FilledButton, '保存'));
      expect(backend.lastBody('PATCH', '/benefits/a1')['archived'], isFalse);
      expect(find.text('权益 · 3 项'), findsOneWidget, reason: '取消归档后回到列表');
    });

    testWidgets('填了领取链接的权益有「打开领取链接」，交给外部打开；打不开时说一句', (tester) async {
      final backend = detailBackend();
      backend.perks.benefits['b1']!['claimUrl'] = 'https://vip.youku.com/88vip';
      final opened = <Uri>[];
      var result = true;
      final container = bootAssets(
        backend,
        overrides: [
          perkUrlOpenerProvider.overrideWithValue((uri) async {
            opened.add(uri);
            return result;
          }),
        ],
      );
      await pumpAssetsAt(tester, container, '/assets/memberships/vip', size: tall);
      expect(find.byKey(const ValueKey('claim-link-c1')), findsNothing, reason: '没填链接的不出按钮');
      await tapVisible(tester, find.byKey(const ValueKey('claim-link-b1')));
      expect(opened, [Uri.parse('https://vip.youku.com/88vip')]);
      expect(find.textContaining('打不开这个链接'), findsNothing);

      result = false;
      await tapVisible(tester, find.byKey(const ValueKey('claim-link-b1')));
      expect(find.text('打不开这个链接，可以复制到浏览器里试试'), findsOneWidget);
    });

    for (final size in kWidths) {
      testWidgets('${size.width.toInt()} 宽：详情不溢出', (tester) async {
        await pumpAssetsAt(tester, bootAssets(detailBackend()), '/assets/memberships/vip', size: size);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('「编辑」去会员表单', (tester) async {
      await pumpAssetsAt(tester, bootAssets(detailBackend()), '/assets/memberships/vip', size: tall);
      await tester.tap(find.byTooltip('编辑'));
      await settle(tester);
      expect(find.byType(MembershipFormPage), findsOneWidget);
      expect(find.text('编辑会员卡'), findsOneWidget);
    });

    testWidgets('「加一项」「加一个选项」去权益表单', (tester) async {
      await pumpAssetsAt(tester, bootAssets(detailBackend()), '/assets/memberships/vip', size: tall);
      await tapVisible(tester, find.text('加一项'));
      expect(find.byType(BenefitFormPage), findsOneWidget);
      expect(find.text('加一项权益'), findsOneWidget);
      await tester.pageBack();
      await settle(tester);

      await tapVisible(tester, find.byKey(const ValueKey('add-option-c1')));
      expect(find.text('加一个选项'), findsOneWidget);
    });
  });
}
