import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/ui/perks/membership_detail_page.dart';
import 'package:famledger/ui/perks/perk_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assets_harness.dart';
import 'perks_fake.dart';

/// 88VIP（淘宝，¥88/年，明年 2/28 到期）：优酷年卡去优酷领、购物券每月 4 张、「年卡二选一」两个选项
/// （芒果年卡去芒果TV领、饿了么月卡在淘宝领）；京东 PLUS（妈妈的）：运费券；归档的老卡。
PerksFake perksFixture() => PerksFake(
  platforms: [
    platformJson('tb', name: '淘宝'),
    platformJson('yk', name: '优酷', sort: 1),
    platformJson('jd', name: '京东', sort: 2),
    platformJson('mg', name: '芒果TV', sort: 3),
  ],
  memberships: [
    membershipJson('vip', feeCents: 8800, expiresOn: '2027-02-28'),
    membershipJson('plus', platformId: 'jd', name: '京东PLUS', memberId: 'u1', feeCents: 19800, sort: 1),
    membershipJson('old', name: '老卡', sort: 2, archived: true),
  ],
  benefits: [
    benefitJson('b1', name: '优酷年卡', kind: 'subscription', claimPlatformId: 'yk', quota: [
      {'p': 'term', 'n': 1},
    ]),
    benefitJson('b2', name: '购物券', kind: 'coupon', quota: [
      {'p': 'month', 'n': 4},
    ], sort: 1),
    benefitJson('c1', name: '年卡二选一', kind: 'choice', quota: [
      {'p': 'year', 'n': 1},
    ], sort: 2),
    benefitJson('o1', parentId: 'c1', name: '芒果年卡', claimPlatformId: 'mg', sort: 3),
    benefitJson('o2', parentId: 'c1', name: '饿了么月卡', sort: 4),
    benefitJson('b4', membershipId: 'plus', name: '运费券', sort: 0),
  ],
);

AssetsBackend perksBackend() => AssetsBackend(
  perks: perksFixture(),
  members: const [
    {'id': 'u1', 'username': 'mama', 'displayName': '妈妈', 'role': 'admin'},
  ],
);

void main() {
  group('会员权益 tab', () {
    testWidgets('?tab=perks 直接打开；一张卡都没有时是空态，点「记一张」去表单', (tester) async {
      await pumpAssetsAt(tester, bootAssets(AssetsBackend()), '/assets?tab=perks');
      expect(find.text('还没记会员卡'), findsOneWidget);
      await tapVisible(tester, find.text('记一张'));
      expect(find.text('记一张会员卡'), findsOneWidget);
    });

    testWidgets('按会员：卡的标题、平台 · 持有人 · 几项 · 到期、续费价；权益行带「去优酷领」；N 选 1 带选项', (tester) async {
      await pumpAssetsAt(tester, bootAssets(perksBackend(), store: allViewStore()), '/assets?tab=perks');

      expect(find.text('88VIP'), findsOneWidget);
      expect(find.text('淘宝 · 全家共用 · 4 项权益 · 还有 158 天到期'), findsOneWidget);
      expect(find.text('¥88.00/年'), findsOneWidget);
      expect(find.text('京东 · 妈妈 · 1 项权益 · 长期有效'), findsOneWidget);

      expect(find.text('优酷年卡'), findsOneWidget);
      expect(find.text('会员/年卡 · 会籍期内 1 次'), findsOneWidget);
      expect(find.byKey(const ValueKey('claim-badge-b1')), findsOneWidget);
      expect(find.text('去优酷领'), findsOneWidget);
      expect(find.byKey(const ValueKey('claim-badge-b2')), findsNothing, reason: '在会员本平台领的不挂徽章');
      expect(find.text('券 · 每月 4 次'), findsOneWidget);
      expect(find.text('N 选 1 · 每年 1 次'), findsOneWidget);
      expect(find.text('芒果年卡 · 去芒果TV领'), findsOneWidget);
      expect(find.text('饿了么月卡'), findsOneWidget);

      // 归档的卡收在底部。
      expect(find.text('老卡'), findsNothing);
      await tapVisible(tester, find.text('已归档 · 1 张'));
      expect(find.text('老卡'), findsOneWidget);
    });

    testWidgets('按领取平台：组头「优酷 · 1 项」，每行写来自哪张卡；选项按自己的领取平台归组', (tester) async {
      await pumpAssetsAt(tester, bootAssets(perksBackend(), store: allViewStore()), '/assets?tab=perks');
      await tapVisible(tester, find.text('按领取平台'));

      expect(find.text('淘宝 · 2 项'), findsOneWidget);
      expect(find.text('优酷 · 1 项'), findsOneWidget);
      expect(find.text('京东 · 1 项'), findsOneWidget);
      expect(find.text('芒果TV · 1 项'), findsOneWidget);
      expect(find.text('来自 88VIP · 会籍期内 1 次'), findsOneWidget);
      expect(find.text('来自 88VIP · 「年卡二选一」的选项 · 每年 1 次'), findsNWidgets(2));
      expect(find.text('年卡二选一'), findsNothing, reason: 'N 选 1 的父权益本身不是一行');

      await tapVisible(tester, find.byKey(const ValueKey('claim-entry-b1')));
      expect(find.byType(MembershipDetailPage), findsOneWidget, reason: '点一行打开那张卡');
    });

    testWidgets('AppBar：这个 tab 的「+」是记会员卡，溢出菜单里有「平台管理」', (tester) async {
      await pumpAssetsAt(tester, bootAssets(perksBackend(), store: allViewStore()), '/assets?tab=perks');
      await tester.tap(find.byTooltip('记一张会员卡'));
      await settle(tester);
      expect(find.text('记一张会员卡'), findsOneWidget);
      await tester.pageBack();
      await settle(tester);

      await tester.tap(find.byKey(const ValueKey('perks-menu')));
      await settle(tester);
      await tester.tap(find.text('平台管理'));
      await settle(tester);
      expect(find.text('平台管理'), findsOneWidget);
      expect(find.text('2 张卡 · 0 项在这领'), findsOneWidget, reason: '淘宝：88VIP 和归档的老卡都算');
      expect(find.text('0 张卡 · 1 项在这领'), findsNWidgets(2), reason: '优酷、芒果TV 只是领取地');
    });

    testWidgets('引用悬空（平台被并掉、成员删了、还没同步到）：用兜底的话画，不崩', (tester) async {
      final backend = AssetsBackend(
        perks: PerksFake(
          memberships: [membershipJson('ghost', platformId: 'gone', name: '孤儿卡', memberId: 'nobody')],
          benefits: [benefitJson('b9', membershipId: 'ghost', name: '孤儿券', claimPlatformId: 'gone-too')],
        ),
      );
      await pumpAssetsAt(tester, bootAssets(backend, store: allViewStore()), '/assets?tab=perks');
      expect(find.text('平台已删除 · 成员已删除 · 1 项权益 · 长期有效'), findsOneWidget);
      expect(find.text('去平台已删除领'), findsOneWidget);
      await tapVisible(tester, find.text('按领取平台'));
      expect(find.text('平台已删除 · 1 项'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('宽屏（≥ 840）：左边列表、右边详情；点另一张卡换右栏，不跳页', (tester) async {
      await pumpAssetsAt(tester, bootAssets(perksBackend(), store: allViewStore()), '/assets?tab=perks', size: const Size(1400, 900));
      expect(find.byType(MembershipDetailView), findsOneWidget);
      expect(find.byKey(const ValueKey('perks-side-vip')), findsOneWidget, reason: '默认看第一张');

      await tester.tap(find.byKey(const ValueKey('membership-plus')));
      await settle(tester);
      expect(find.byKey(const ValueKey('perks-side-plus')), findsOneWidget);
      expect(find.byType(MembershipDetailPage), findsNothing, reason: '宽屏不推新页');
    });

    testWidgets('宽屏：默认看第一张时在右栏归档它，右栏仍停在这张卡上，提示照样出来', (tester) async {
      final backend = perksBackend();
      await pumpAssetsAt(tester, bootAssets(backend, store: allViewStore()), '/assets?tab=perks', size: const Size(1400, 2000));
      expect(find.byKey(const ValueKey('perks-side-vip')), findsOneWidget);
      backend.delayNext['GET /changes'] = const Duration(milliseconds: 300);
      await tapVisible(tester, find.byKey(const ValueKey('membership-archive')));
      await settle(tester);
      expect(backend.lastBody('PATCH', '/memberships/vip'), {'archived': true});
      expect(find.byKey(const ValueKey('perks-side-vip')), findsOneWidget, reason: '不跳到下一张卡');
      expect(find.text('已归档：不进本期、不提醒'), findsOneWidget);
      expect(find.text('取消归档'), findsOneWidget, reason: '同一个位置的按钮还是这张卡的');
    });

    testWidgets('宽屏：在右栏删掉这张卡（同步还在路上），「已删掉」照样提示，右栏换到剩下的第一张', (tester) async {
      final backend = perksBackend();
      await pumpAssetsAt(tester, bootAssets(backend, store: allViewStore()), '/assets?tab=perks', size: const Size(1400, 2000));
      await tapVisible(tester, find.byKey(const ValueKey('membership-delete')));
      backend.delayNext['GET /changes'] = const Duration(milliseconds: 500);
      await tester.tap(find.widgetWithText(FilledButton, '删掉'));
      await settle(tester, frames: 10);
      expect(backend.perks.memberships.containsKey('vip'), isFalse);
      expect(find.text('已删掉'), findsOneWidget);
      expect(find.byKey(const ValueKey('perks-side-plus')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('宽屏：右栏里「来自」换成来源那张卡，不盖一整页上来', (tester) async {
      final backend = perksBackend();
      backend.perks.memberships['ykvip'] = membershipJson('ykvip', platformId: 'yk', name: '优酷VIP', sourceBenefitId: 'b1', sort: 3);
      await pumpAssetsAt(tester, bootAssets(backend, store: allViewStore()), '/assets?tab=perks', size: const Size(1400, 900));
      // 顶上多了「本期 | 全部」，这张卡在 900 高的窗口里要先滚到。
      await tapVisible(tester, find.byKey(const ValueKey('membership-ykvip')));
      await tapVisible(tester, find.byKey(const ValueKey('membership-source')));
      expect(find.byKey(const ValueKey('perks-side-vip')), findsOneWidget);
      expect(find.byType(MembershipDetailPage), findsNothing);
    });

    testWidgets('按领取平台：填了领取链接的行（含 N 选 1 的选项）右边能直接打开', (tester) async {
      final backend = perksBackend();
      backend.perks.benefits['o1']!['claimUrl'] = 'https://www.mgtv.com/vip';
      final opened = <Uri>[];
      final container = bootAssets(
        backend,
        store: allViewStore(),
        overrides: [
          perkUrlOpenerProvider.overrideWithValue((uri) async {
            opened.add(uri);
            return true;
          }),
        ],
      );
      await pumpAssetsAt(tester, container, '/assets?tab=perks');
      await tapVisible(tester, find.text('按领取平台'));
      expect(find.byKey(const ValueKey('claim-link-b1')), findsNothing);
      await tapVisible(tester, find.byKey(const ValueKey('claim-link-o1')));
      expect(opened, [Uri.parse('https://www.mgtv.com/vip')]);
    });

    testWidgets('「按会员 / 按领取平台」也记进本机：切过去，下次打开还是按领取平台', (tester) async {
      final store = allViewStore();
      await pumpAssetsAt(tester, bootAssets(perksBackend(), store: store), '/assets?tab=perks');
      await tapVisible(tester, find.text('按领取平台'));
      expect(await store.read<Map<String, dynamic>>(PerkViewPrefsController.storeKey), {'view': 'all', 'scope': 'family', 'grouping': 'byClaimPlatform'});

      await pumpAssetsAt(tester, bootAssets(perksBackend(), store: store), '/assets?tab=perks');
      expect(find.text('淘宝 · 2 项'), findsOneWidget, reason: '重开直接是按领取平台');
    });

    testWidgets('「本期 | 全部」记在本机：切到「本期」再重开还是「本期」', (tester) async {
      final store = allViewStore();
      await pumpAssetsAt(tester, bootAssets(perksBackend(), store: store), '/assets?tab=perks');
      expect(find.text('按领取平台'), findsOneWidget);
      await tapVisible(tester, find.byKey(const ValueKey('perk-view-current')));
      expect(find.textContaining('本期待领'), findsOneWidget);
      await pumpAssetsAt(tester, bootAssets(perksBackend(), store: store), '/assets?tab=perks');
      expect(find.text('按领取平台'), findsNothing);
      expect(find.textContaining('本期待领'), findsOneWidget);
    });

    testWidgets('会员行带回本条：已回本几成 · 已兑现 / 本期实付，竖刻度是时间过了几成；缺本期开始不画刻度；免费又没享受到的不画', (tester) async {
      final backend = perksBackend();
      backend.perks.memberships['vip']!['termStartOn'] = '2026-03-01';
      backend.perks.benefits['b1']!['faceValueCents'] = 24800;
      backend.perks.events['e1'] = eventJson('e1', 'b1', occurredOn: '2026-09-20');
      backend.perks.memberships['free'] = membershipJson('free', name: '免费卡', sort: 3);
      await pumpAssetsAt(tester, bootAssets(backend, store: allViewStore()), '/assets?tab=perks', size: const Size(400, 2000));

      expect(find.text('已回本 282% · ¥248.00 / ¥88.00'), findsOneWidget);
      expect(find.text('时间已过 57%'), findsOneWidget, reason: '3/1 ~ 明年 2/28，今天是第 207 天');
      expect(find.descendant(of: find.byKey(const ValueKey('payback-vip')), matching: find.byKey(const ValueKey('payback-time-tick'))), findsOneWidget);
      expect(find.text('已回本 0% · ¥0.00 / ¥198.00'), findsOneWidget, reason: '京东 PLUS：还没兑现');
      expect(find.descendant(of: find.byKey(const ValueKey('payback-plus')), matching: find.byKey(const ValueKey('payback-time-tick'))), findsNothing, reason: '没填本期开始，不画时间刻度');
      expect(find.byKey(const ValueKey('payback-free')), findsNothing);
    });

    testWidgets('免费、没填费用的卡也有到期进度：空条上画时间刻度；免费又享受到了的写「免费 · 已享」', (tester) async {
      final backend = perksBackend();
      // 88VIP 带出来的优酷VIP：本期实付 0；另一张没填费用的月卡。
      backend.perks.memberships['ykvip'] = membershipJson('ykvip', platformId: 'yk', name: '优酷VIP', sourceBenefitId: 'b1', termPaidCents: 0, termStartOn: '2026-03-01', expiresOn: '2027-02-28', sort: 3);
      backend.perks.memberships['nofee'] = membershipJson('nofee', name: '月卡', feePeriod: 'month', termStartOn: '2026-09-01', expiresOn: '2026-09-30', sort: 4);
      backend.perks.benefits['v1'] = benefitJson('v1', membershipId: 'ykvip', name: '观影券', faceValueCents: 500, quota: [
        {'p': 'month', 'n': 1},
      ]);
      backend.perks.events['e1'] = eventJson('e1', 'v1', occurredOn: '2026-09-10');
      await pumpAssetsAt(tester, bootAssets(backend, store: allViewStore()), '/assets?tab=perks', size: const Size(400, 2400));
      Finder tick(String id) => find.descendant(of: find.byKey(ValueKey('payback-$id')), matching: find.byKey(const ValueKey('payback-time-tick')));
      expect(find.descendant(of: find.byKey(const ValueKey('payback-ykvip')), matching: find.text('免费 · 已享 ¥5.00')), findsOneWidget);
      expect(tick('ykvip'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('payback-nofee')), matching: find.text('时间已过 77%')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('payback-nofee')), matching: find.textContaining('免费')), findsNothing, reason: '没填费用不说成免费');
      expect(tick('nofee'), findsOneWidget);
    });

    testWidgets('选「我」而名下一张卡都没有：说「你名下还没有卡」，不说「都归档了」；宽屏右栏不停在别人的卡上', (tester) async {
      final backend = AssetsBackend(
        perks: PerksFake(
          platforms: [platformJson('jd', name: '京东')],
          memberships: [membershipJson('plus', platformId: 'jd', name: '京东PLUS', memberId: 'u1', feeCents: 19800)],
        ),
        members: const [
          {'id': 'u1', 'username': 'baba', 'displayName': '爸爸', 'role': 'member'},
        ],
      );
      final store = MemoryLocalStore()..write(PerkViewPrefsController.storeKey, {'view': 'all', 'scope': 'family'});
      final container = bootAssets(backend, store: store, session: await sessionAs('member'));
      await pumpAssetsAt(tester, container, '/assets?tab=perks', size: const Size(1400, 1000));
      expect(find.byKey(const ValueKey('perks-side-plus')), findsOneWidget, reason: '全家：右栏看爸爸的卡');
      await tapVisible(tester, find.byKey(const ValueKey('perk-scope-mine')));
      expect(find.text('你名下还没有卡'), findsOneWidget);
      expect(find.text('在用的卡都归档了'), findsNothing);
      expect(find.byKey(const ValueKey('perks-side-plus')), findsNothing, reason: '切到「我」，右栏不再停在爸爸的卡上');
      expect(find.text('选一张卡看详情'), findsOneWidget);
    });

    for (final size in kWidths) {
      testWidgets('${size.width.toInt()} 宽、字号放大 1.5 倍、40 字的平台名：两种分组都不溢出', (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = 1.5;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final backend = perksBackend();
        backend.perks.platforms['yk']!['name'] = '优酷'.padRight(40, '长');
        backend.perks.platforms['mg']!['name'] = '芒果TV'.padRight(40, '长');
        await pumpAssetsAt(tester, bootAssets(backend, store: allViewStore()), '/assets?tab=perks', size: size);
        // 宽屏右栏的详情里也有一份，所以是「至少一个」。
        expect(find.byKey(const ValueKey('claim-badge-b1')), findsWidgets);
        expect(find.textContaining('去芒果TV长'), findsWidgets);
        expect(tester.takeException(), isNull);
        await tapVisible(tester, find.text('按领取平台'));
        expect(tester.takeException(), isNull);
      });

      testWidgets('${size.width.toInt()} 宽：两种分组都不溢出', (tester) async {
        await pumpAssetsAt(tester, bootAssets(perksBackend(), store: allViewStore()), '/assets?tab=perks', size: size);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('按领取平台'));
        await settle(tester);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
