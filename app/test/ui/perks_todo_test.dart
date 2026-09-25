import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/ui/perks/membership_detail_page.dart';
import 'package:famledger/ui/perks/perk_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assets_harness.dart';
import 'perks_fake.dart';

// 会员权益 tab「本期」顶上的「要处理」（spec §5）：续费、到期、过期待确认、权益快到期；「续了」「停了」都能撤销，
// 权益快到期直接点 ✓，「知道了」只记在本机。「今天」= 2026-09-23。

/// 腾讯视频：自动续费、9/20 到期（应已续上）；京东 PLUS：不续费，10/3 到期；88VIP 的优酷年卡 9/28 到期还没领。
AssetsBackend todoBackend() => AssetsBackend(
  perks: PerksFake(
    platforms: [platformJson('tb', name: '淘宝'), platformJson('tx', name: '腾讯视频', sort: 1), platformJson('jd', name: '京东', sort: 2)],
    memberships: [
      membershipJson('tv', platformId: 'tx', name: '腾讯视频', feeCents: 2500, feePeriod: 'month', autoRenew: 'yes', termStartOn: '2026-08-21', expiresOn: '2026-09-20'),
      membershipJson('plus', platformId: 'jd', name: '京东PLUS', feeCents: 19800, autoRenew: 'no', expiresOn: '2026-10-03', sort: 1),
      membershipJson('vip', feeCents: 8800, sort: 2),
    ],
    benefits: [
      benefitJson('b1', membershipId: 'vip', name: '优酷年卡', quota: [
        {'p': 'total', 'n': 1},
      ], validUntil: '2026-09-28'),
    ],
  ),
);

void main() {
  group('要处理', () {
    testWidgets('续费、到期、过期待确认、权益快到期都在「要处理」，过期待确认排最前', (tester) async {
      await pumpAssetsAt(tester, bootAssets(todoBackend()), '/assets?tab=perks', size: const Size(400, 2000));
      expect(find.text('要处理 · 3'), findsOneWidget);
      expect(find.text('腾讯视频 应已自动续费，续上了吗？'), findsOneWidget);
      expect(find.text('9月20日到期 · 已过 3 天'), findsOneWidget);
      expect(find.text('优酷年卡 快到期'), findsOneWidget);
      expect(find.text('京东PLUS 快到期'), findsOneWidget);
      final titles = tester.widgetList<ListTile>(find.byWidgetPredicate((w) => w is ListTile && w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('alert-')));
      expect((titles.first.title! as Text).data, '腾讯视频 应已自动续费，续上了吗？');
    });

    testWidgets('「续了」：POST renew（带 clientId），这条就没了；snackbar 撤销把到期日改回去', (tester) async {
      final backend = todoBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=perks', size: const Size(400, 2000));
      await tapVisible(tester, find.byKey(const ValueKey('alert-renew-tv')));
      final body = backend.lastBody('POST', '/memberships/tv/renew');
      expect(body.keys.toSet(), {'clientId', 'expiresOn'}, reason: '到期日总是算好了发过去；实付没特别的不带（按续费价）');
      expect(body['expiresOn'], '2026-10-20');
      expect(backend.perks.memberships['tv']!['expiresOn'], '2026-10-20');
      expect(find.text('腾讯视频 应已自动续费，续上了吗？'), findsNothing);
      expect(find.text('已续到 2026-10-20：腾讯视频'), findsOneWidget);

      await tester.tap(find.text('撤销'));
      await settle(tester);
      expect(backend.lastBody('PATCH', '/memberships/tv'), {'expiresOn': '2026-09-20', 'termStartOn': '2026-08-21', 'termPaidCents': null, 'isTrial': false});
      expect(find.text('腾讯视频 应已自动续费，续上了吗？'), findsOneWidget);
    });

    testWidgets('「续了」请求还在路上时再点：转圈、不做事，只续一期（不会一下子多出一年）', (tester) async {
      final backend = todoBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=perks', size: const Size(400, 2000));
      backend.delayNext['POST /memberships/tv/renew'] = const Duration(seconds: 2);
      final renew = find.byKey(const ValueKey('alert-renew-tv'));
      await tester.ensureVisible(renew);
      await tester.tap(renew);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.descendant(of: renew, matching: find.byType(CircularProgressIndicator)), findsOneWidget);
      await tester.tap(renew);
      await tester.tap(find.byKey(const ValueKey('alert-stop-tv')));
      await settle(tester, frames: 30);
      expect(backend.requests('POST', '/memberships/tv/renew'), hasLength(1));
      expect(backend.requests('PATCH', '/memberships/tv'), isEmpty, reason: '续费还没回来时「停了」也不做');
      expect(backend.perks.memberships['tv']!['expiresOn'], '2026-10-20');
      expect(find.text('本期回本'), findsNothing, reason: '再点没有漏到整行上去打开卡片');
    });

    testWidgets('两台设备各点一次「续了」：后点的那台本地还是旧到期日，服务端 400，说一句「已经续过了」再同步，不续第二期', (tester) async {
      final backend = todoBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=perks', size: const Size(400, 2000));
      // 另一台设备刚续过：服务端已经到 10/20，这台还没同步到。
      backend.perks.memberships['tv']!
        ..['expiresOn'] = '2026-10-20'
        ..['termStartOn'] = '2026-09-21';
      await tapVisible(tester, find.byKey(const ValueKey('alert-renew-tv')));
      expect(backend.lastBody('POST', '/memberships/tv/renew')['expiresOn'], '2026-10-20');
      expect(backend.perks.memberships['tv']!['expiresOn'], '2026-10-20', reason: '没有续到 11/20');
      expect(find.text('「腾讯视频」已经续过了（可能是别的设备或家人刚点的），这就刷新'), findsOneWidget);
      expect(find.text('腾讯视频 应已自动续费，续上了吗？'), findsNothing, reason: '同步回来就不再问');
    });

    testWidgets('免年费（本期实付 0）、大会员带出来的卡「续了」：本期实付照原样带上，不被清空成按续费价', (tester) async {
      final backend = todoBackend();
      backend.perks.memberships['tv']!['termPaidCents'] = 0;
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=perks', size: const Size(400, 2000));
      await tapVisible(tester, find.byKey(const ValueKey('alert-renew-tv')));
      expect(backend.lastBody('POST', '/memberships/tv/renew')['paidCents'], 0);
      expect(backend.perks.memberships['tv']!['termPaidCents'], 0);
    });

    testWidgets('自动续费扣费的提醒行也有「续了」（到期当天看到扣款就能点），续完权益照样在本期', (tester) async {
      final backend = AssetsBackend(
        perks: PerksFake(
          platforms: [platformJson('tx', name: '腾讯视频')],
          memberships: [
            membershipJson('tv', platformId: 'tx', name: '腾讯视频', feeCents: 2500, feePeriod: 'month', autoRenew: 'yes', termStartOn: '2026-08-24', expiresOn: '2026-09-23'),
          ],
          benefits: [
            benefitJson('b1', membershipId: 'tv', name: '观影券', quota: [
              {'p': 'term', 'n': 1},
            ]),
          ],
        ),
      );
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=perks', size: const Size(400, 2000));
      expect(find.text('腾讯视频 将自动续费'), findsOneWidget);
      await tapVisible(tester, find.byKey(const ValueKey('alert-renew-tv')));
      expect(backend.perks.memberships['tv']!['termStartOn'], '2026-09-24', reason: '本期开始挪到明天');
      expect(find.text('腾讯视频 将自动续费'), findsNothing);
      expect(find.text('本期 0/1 · 今天截止'), findsOneWidget, reason: '今天还是上一期的最后一天，券照样能领');
    });

    testWidgets('N 选 1 快到期：行尾「挑一个」，弹层里点选项就打在选项上', (tester) async {
      final backend = todoBackend();
      backend.perks.benefits['c1'] = benefitJson('c1', membershipId: 'vip', name: '年卡二选一', kind: 'choice', validUntil: '2026-09-26', quota: [
        {'p': 'total', 'n': 1},
      ], sort: 1);
      backend.perks.benefits['o1'] = benefitJson('o1', membershipId: 'vip', parentId: 'c1', name: '芒果年卡', sort: 2);
      backend.perks.benefits['o2'] = benefitJson('o2', membershipId: 'vip', parentId: 'c1', name: '饿了么月卡', sort: 3);
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=perks', size: const Size(400, 2000));
      expect(find.text('年卡二选一 快到期'), findsOneWidget);
      await tapVisible(tester, find.byKey(const ValueKey('alert-pick-c1')));
      await tapVisible(tester, find.byKey(const ValueKey('pick-option-o2')));
      expect(backend.lastBody('POST', '/benefit-events')['benefitId'], 'o2');
      expect(find.text('领了：饿了么月卡'), findsOneWidget);
      expect(find.text('年卡二选一 快到期'), findsNothing, reason: '挑过了，不再提醒');
    });

    testWidgets('一次性的卡过期：问「还留着吗」，只有「归档」和「知道了」，没有「续了」', (tester) async {
      final backend = AssetsBackend(
        perks: PerksFake(
          platforms: [platformJson('tb', name: '淘宝')],
          memberships: [membershipJson('course', name: '网课', feePeriod: 'once', expiresOn: '2026-09-20')],
        ),
      );
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=perks', size: const Size(400, 2000));
      expect(find.text('9月20日到期 · 还留着吗？'), findsOneWidget);
      expect(find.byKey(const ValueKey('alert-renew-course')), findsNothing);
      expect(find.descendant(of: find.byKey(const ValueKey('alert-stop-course')), matching: find.text('归档')), findsOneWidget);
      await tapVisible(tester, find.byKey(const ValueKey('alert-dismiss-renewCheck:course:2026-09-20')));
      expect(find.text('9月20日到期 · 还留着吗？'), findsNothing);
      expect(backend.requests('PATCH', '/memberships/course'), isEmpty);
    });

    testWidgets('「停了」：改成不续费并归档，这张卡不进本期、不提醒；能撤销', (tester) async {
      final backend = todoBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=perks', size: const Size(400, 2000));
      await tapVisible(tester, find.byKey(const ValueKey('alert-stop-tv')));
      expect(backend.lastBody('PATCH', '/memberships/tv'), {'autoRenew': 'no', 'archived': true});
      expect(find.text('腾讯视频 应已自动续费，续上了吗？'), findsNothing);
      expect(find.text('已停：「腾讯视频」收进已归档'), findsOneWidget);
      await tester.tap(find.text('撤销'));
      await settle(tester);
      expect(backend.lastBody('PATCH', '/memberships/tv'), {'autoRenew': 'yes', 'archived': false});
    });

    testWidgets('权益快到期直接点 ✓；「知道了」只记在本机，重开也不再出现', (tester) async {
      final backend = todoBackend();
      final store = MemoryLocalStore();
      await pumpAssetsAt(tester, bootAssets(backend, store: store), '/assets?tab=perks', size: const Size(400, 2000));
      await tapVisible(tester, find.byKey(const ValueKey('alert-check-b1')));
      expect(backend.lastBody('POST', '/benefit-events')['benefitId'], 'b1');
      expect(find.text('优酷年卡 快到期'), findsNothing, reason: '领过了，不再提醒');

      await tapVisible(tester, find.byKey(const ValueKey('alert-dismiss-expiry:plus:2026-10-03')));
      expect(find.text('京东PLUS 快到期'), findsNothing);
      expect(backend.requests('PATCH', '/memberships/plus'), isEmpty, reason: '「知道了」不同步');
      final saved = await store.read<Map<String, dynamic>>(PerkDismissedController.storeKey);
      expect(saved!.keys, ['expiry:plus:2026-10-03']);
    });

    testWidgets('「知道了」过的，下次打开还是不出现', (tester) async {
      final store = MemoryLocalStore()..write(PerkDismissedController.storeKey, {'expiry:plus:2026-10-03': '2026-09-22T10:00:00.000'});
      await pumpAssetsAt(tester, bootAssets(todoBackend(), store: store), '/assets?tab=perks', size: const Size(400, 2000));
      expect(find.text('要处理 · 2'), findsOneWidget);
      expect(find.text('京东PLUS 快到期'), findsNothing);
    });
  });

  group('宽屏', () {
    testWidgets('1400 宽的「本期」：点提醒行、点本期待领的一行，都是换右栏，不推详情页', (tester) async {
      await pumpAssetsAt(tester, bootAssets(todoBackend()), '/assets?tab=perks', size: const Size(1400, 1000));
      expect(find.byKey(const ValueKey('perks-side-tv')), findsOneWidget, reason: '默认看第一张');
      await tapVisible(tester, find.text('京东PLUS 快到期'));
      expect(find.byKey(const ValueKey('perks-side-plus')), findsOneWidget);
      await tapVisible(tester, find.byKey(const ValueKey('current-b1')));
      expect(find.byKey(const ValueKey('perks-side-vip')), findsOneWidget);
      expect(find.byType(MembershipDetailPage), findsNothing, reason: '没有盖一整页上来');
    });
  });

  group('不溢出', () {
    for (final size in kWidths) {
      testWidgets('${size.width.toInt()} 宽、字号放大 1.5 倍、登录了：本期视图（含要处理、我 / 全家、N 选 1、推算本期带链接的最宽一行、展开的已完成）不溢出', (tester) async {
        final backend = todoBackend();
        backend.perks.memberships['tv']!['name'] = '腾讯视频超长名字的连续包月会员卡';
        backend.perks.benefits['c1'] = benefitJson('c1', membershipId: 'vip', name: '年卡二选一', kind: 'choice', quota: [
          {'p': 'year', 'n': 1},
        ], sort: 1);
        backend.perks.benefits['o1'] = benefitJson('o1', membershipId: 'vip', parentId: 'c1', name: '芒果年卡', claimUrl: 'https://www.mgtv.com/vip', sort: 2);
        backend.perks.benefits['o2'] = benefitJson('o2', membershipId: 'vip', parentId: 'c1', name: '饿了么月卡', sort: 3);
        backend.perks.benefits['b9'] = benefitJson('b9', membershipId: 'vip', name: '用完的券', quota: [
          {'p': 'month', 'n': 1},
        ], sort: 4);
        backend.perks.events['e9'] = eventJson('e9', 'b9', occurredOn: '2026-09-02');
        // 最宽的一种行：推算本期的卡（名字超长）上一项先领再用、带领取链接和领取路径的券。
        backend.perks.benefits['w1'] = benefitJson('w1', membershipId: 'tv', name: '每月观影红包券（先领再用）', flow: 'claim_use', claimUrl: 'https://v.qq.com/vip', claimHow: '腾讯视频App › 我的 › VIP会员 › 福利中心 › 观影券', quota: [
          {'p': 'month', 'n': 4},
        ]);
        tester.platformDispatcher.textScaleFactorTestValue = 1.5;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        // 登录了才有「我 / 全家」那一排；高一点，让「已完成」也画出来（列表是懒加载的）。
        await pumpAssetsAt(tester, bootAssets(backend, session: await sessionAs('member')), '/assets?tab=perks', size: Size(size.width, 2400));
        expect(find.byKey(const ValueKey('perk-scope')), findsOneWidget);
        expect(find.descendant(of: find.byKey(const ValueKey('current-w1')), matching: find.text('推算本期')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tapVisible(tester, find.textContaining('已完成'));
        expect(tester.takeException(), isNull);
      });
    }
  });
}
