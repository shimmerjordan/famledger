import 'dart:convert';

import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/ui/perks/perk_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assets_harness.dart';
import 'perks_fake.dart';

// 会员权益 tab 的「本期」（spec §5）：本期待领（按领取平台分组）、随时可用、已完成；一键打卡 + snackbar 撤销、
// 长按记多份 / 改日期 / 改价值 / 本期跳过、N 选 1 点 chip 打卡、打卡后建子会员、我 / 全家。「要处理」在 perks_todo_test.dart。
// 「今天」= 2026-09-23。

/// 88VIP（淘宝，本期 1/31 ~ 明年 1/30）：优酷年卡去优酷领（会籍期内 1 次）、购物券先领再用（每月 4 张）、95 折不限次、
/// 「年卡二选一」（每年 1 次：芒果年卡去芒果TV领、饿了么月卡）、贵宾厅（每年 6 次，已经用完）；
/// 京东 PLUS（爸爸的）：运费券每月 2 张。
PerksFake currentFixture() => PerksFake(
  platforms: [
    platformJson('tb', name: '淘宝')..['url'] = 'https://www.taobao.com',
    platformJson('yk', name: '优酷', sort: 1),
    platformJson('jd', name: '京东', sort: 2),
    platformJson('mg', name: '芒果TV', sort: 3),
  ],
  memberships: [
    membershipJson('vip', feeCents: 8800, termStartOn: '2026-01-31', expiresOn: '2027-01-30'),
    membershipJson('plus', platformId: 'jd', name: '京东PLUS', memberId: 'u1', feeCents: 19800, sort: 1),
  ],
  benefits: [
    benefitJson('b1', name: '优酷年卡', kind: 'subscription', claimPlatformId: 'yk', claimHow: '优酷App › 我的 › 88VIP', faceValueCents: 24800, quota: [
      {'p': 'term', 'n': 1},
    ]),
    benefitJson('b2', name: '购物券', kind: 'coupon', flow: 'claim_use', faceValueCents: 500, quota: [
      {'p': 'month', 'n': 4},
    ], sort: 1),
    benefitJson('b3', name: '95 折', kind: 'discount', flow: 'use', sort: 2),
    benefitJson('c1', name: '年卡二选一', kind: 'choice', quota: [
      {'p': 'year', 'n': 1},
    ], sort: 3),
    benefitJson('o1', parentId: 'c1', name: '芒果年卡', claimPlatformId: 'mg', claimUrl: 'https://www.mgtv.com/vip', sort: 4),
    benefitJson('o2', parentId: 'c1', name: '饿了么月卡', sort: 5),
    benefitJson('b5', name: '贵宾厅', kind: 'lounge', flow: 'use', quota: [
      {'p': 'year', 'n': 6},
    ], sort: 6),
    benefitJson('b4', membershipId: 'plus', name: '运费券', kind: 'shipping', quota: [
      {'p': 'month', 'n': 2},
    ]),
  ],
  events: [eventJson('e-lounge', 'b5', kind: 'use', occurredOn: '2026-03-01', count: 6)],
);

AssetsBackend currentBackend() => AssetsBackend(
  perks: currentFixture(),
  members: const [
    {'id': 'u1', 'username': 'baba', 'displayName': '爸爸', 'role': 'member'},
  ],
);

Finder inGroup(String platformId, Finder f) => find.descendant(of: find.byKey(ValueKey('current-group-$platformId')), matching: f);

void main() {
  group('本期', () {
    testWidgets('默认打开「本期」：本期待领按领取平台分组，组头「淘宝 · 2 项」带「打开」；每行来源卡、进度、截止、大按钮；不限次和已完成折叠', (tester) async {
      await pumpAssetsAt(tester, bootAssets(currentBackend()), '/assets?tab=perks', size: const Size(400, 2000));

      expect(find.text('本期待领 · 4 项'), findsOneWidget);
      expect(find.text('淘宝 · 2 项'), findsOneWidget);
      expect(find.text('优酷 · 1 项'), findsOneWidget);
      expect(find.text('京东 · 1 项'), findsOneWidget);
      expect(find.byKey(const ValueKey('current-group-open-tb')), findsOneWidget, reason: '淘宝填了网址');
      expect(find.byKey(const ValueKey('current-group-open-yk')), findsNothing);

      expect(find.text('本月 0/4 · 待领 · 还剩 7 天'), findsOneWidget, reason: '购物券先领再用，本月还没领');
      expect(find.widgetWithText(FilledButton, '领了'), findsNWidgets(3), reason: '购物券（先领）、优酷年卡、运费券');
      expect(find.text('本期 0/1 · 还剩 129 天'), findsOneWidget);
      expect(find.text('优酷App › 我的 › 88VIP'), findsOneWidget);
      expect(find.text('长按或右键一行：记多份、改日期、改价值、本期跳过'), findsOneWidget, reason: '长按藏着的东西说一句');
      expect(find.text('88VIP'), findsNWidgets(3), reason: '每行的来源卡');
      expect(find.text('芒果年卡 · 去芒果TV领'), findsOneWidget);

      expect(find.text('随时可用 · 1 项'), findsOneWidget);
      expect(find.text('95 折'), findsNothing, reason: '随时可用默认折叠');
      expect(find.text('已完成 · 1 项'), findsOneWidget);
      await tapVisible(tester, find.text('已完成 · 1 项'));
      expect(find.text('本年 6/6 · 本期用完'), findsOneWidget);
    });

    testWidgets('一键打卡：记 count=1、今天、带 clientId；先领再用的领过就变「用了」；snackbar 撤销就删掉那条', (tester) async {
      final backend = currentBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=perks', size: const Size(400, 2000));

      await tapVisible(tester, find.byKey(const ValueKey('check-in-b2')));
      final body = backend.lastBody('POST', '/benefit-events');
      expect(body['benefitId'], 'b2');
      expect(body['kind'], 'claim');
      expect(body['count'], 1);
      expect(body['occurredOn'], '2026-09-23');
      expect(body['clientId'], isA<String>());
      expect(find.text('领了：购物券'), findsOneWidget);
      expect(find.text('本月 0/4 · 还剩 7 天'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('check-in-b2')), matching: find.text('用了')), findsOneWidget);

      final id = backend.perks.events.values.singleWhere((e) => e['benefitId'] == 'b2')['id'];
      await tester.tap(find.text('撤销'));
      await settle(tester);
      expect(backend.requests('DELETE', '/benefit-events/$id'), hasLength(1));
      expect(find.text('已撤销'), findsOneWidget);
      expect(find.text('本月 0/4 · 待领 · 还剩 7 天'), findsOneWidget);
    });

    testWidgets('年卡类去别的平台领的打完卡：挪进已完成；snackbar 附「在优酷建会员卡」，点了预填平台、来源权益、本期实付 0', (tester) async {
      final backend = currentBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=perks', size: const Size(400, 2000));

      await tapVisible(tester, find.byKey(const ValueKey('check-in-b1')));
      expect(find.text('优酷 · 1 项'), findsNothing, reason: '用完就不在本期待领了');
      expect(find.text('已完成 · 2 项'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('snack-derived-card')));
      await settle(tester);
      expect(find.text('记一张会员卡'), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(const ValueKey('membership-paid'))).controller!.text, '0.00');
      expect(find.text('88VIP · 优酷年卡'), findsOneWidget, reason: '来源权益预选好了');
      expect(find.descendant(of: find.byKey(const ValueKey('membership-platform')), matching: find.text('优酷')), findsOneWidget);
    });

    testWidgets('已经建过由它带出的卡：不再给「建会员卡」', (tester) async {
      final backend = currentBackend();
      backend.perks.memberships['ykvip'] = membershipJson('ykvip', platformId: 'yk', name: '优酷VIP', sourceBenefitId: 'b1', sort: 2);
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=perks', size: const Size(400, 2000));
      await tapVisible(tester, find.byKey(const ValueKey('check-in-b1')));
      expect(find.text('领了：优酷年卡'), findsOneWidget);
      expect(find.byKey(const ValueKey('snack-derived-card')), findsNothing);
    });

    testWidgets('长按：记多份、改日期、改价值；再长按「本期跳过」进已完成', (tester) async {
      final backend = currentBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=perks', size: const Size(400, 2000));

      await tester.ensureVisible(find.byKey(const ValueKey('current-b4')));
      await tester.longPress(find.byKey(const ValueKey('current-b4')));
      await settle(tester);
      await tester.enterText(find.byKey(const ValueKey('check-in-count')), '2');
      await tester.enterText(find.byKey(const ValueKey('check-in-value')), '6.5');
      await tester.tap(find.byIcon(Icons.today_outlined));
      await settle(tester);
      await tester.tap(find.text('20'));
      await tester.tap(find.text('OK'));
      await settle(tester);
      await tapVisible(tester, find.byKey(const ValueKey('check-in-save')));
      final body = backend.lastBody('POST', '/benefit-events');
      expect((body['benefitId'], body['kind'], body['count'], body['valueCents'], body['occurredOn']), ('b4', 'claim', 2, 650, '2026-09-20'));
      expect(find.text('领了：运费券 ×2'), findsOneWidget);
      expect(find.text('京东 · 1 项'), findsNothing, reason: '每月 2 张，一次记了 2 张');

      await tester.ensureVisible(find.byKey(const ValueKey('current-b2')));
      await tester.longPress(find.byKey(const ValueKey('current-b2')));
      await settle(tester);
      await tapVisible(tester, find.byKey(const ValueKey('check-in-skip')));
      expect(backend.lastBody('POST', '/benefit-events')['kind'], 'skip');
      await tapVisible(tester, find.text('已完成 · 3 项'));
      expect(find.text('本月 0/4 · 本期已跳过'), findsOneWidget);
    });

    testWidgets('长按里份数、价值填错：行内说，不发请求', (tester) async {
      final backend = currentBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=perks', size: const Size(400, 2000));
      await tester.ensureVisible(find.byKey(const ValueKey('current-b4')));
      await tester.longPress(find.byKey(const ValueKey('current-b4')));
      await settle(tester);
      await tester.enterText(find.byKey(const ValueKey('check-in-count')), '0');
      await tapVisible(tester, find.byKey(const ValueKey('check-in-save')));
      expect(find.text('份数填 1 到 999'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('check-in-count')), '1');
      await tester.enterText(find.byKey(const ValueKey('check-in-value')), '五块');
      await tapVisible(tester, find.byKey(const ValueKey('check-in-save')));
      expect(find.text('这次的价值填得不对，例如 5'), findsOneWidget);
      expect(backend.requests('POST', '/benefit-events'), isEmpty);
    });

    testWidgets('N 选 1：点选项 chip 打卡；本期领完后没选的置灰（已完成里），撤销就恢复；选项的领取链接在 chip 上能打开', (tester) async {
      final backend = currentBackend();
      final opened = <Uri>[];
      final container = bootAssets(
        backend,
        overrides: [
          perkUrlOpenerProvider.overrideWithValue((uri) async {
            opened.add(uri);
            return true;
          }),
        ],
      );
      await pumpAssetsAt(tester, container, '/assets?tab=perks', size: const Size(400, 2000));

      final mango = find.byKey(const ValueKey('option-check-in-o1'));
      await tester.ensureVisible(mango);
      await tester.tap(find.descendant(of: mango, matching: find.byIcon(Icons.open_in_new)));
      await settle(tester);
      expect(opened, [Uri.parse('https://www.mgtv.com/vip')]);
      expect(backend.requests('POST', '/benefit-events'), isEmpty, reason: '点链接不算打卡');

      await tapVisible(tester, find.byKey(const ValueKey('option-check-in-o2')));
      expect(backend.lastBody('POST', '/benefit-events')['benefitId'], 'o2', reason: '打在选项上，不打在父权益上');
      expect(find.text('淘宝 · 1 项'), findsOneWidget);
      await tapVisible(tester, find.text('已完成 · 2 项'));
      expect(tester.widget<InputChip>(find.byKey(const ValueKey('option-check-in-o1'))).isEnabled, isFalse, reason: '没选的置灰');
      expect(tester.widget<InputChip>(find.byKey(const ValueKey('option-check-in-o2'))).selected, isTrue);

      await tester.tap(find.text('撤销'));
      await settle(tester);
      expect(find.text('淘宝 · 2 项'), findsOneWidget);
      expect(tester.widget<InputChip>(find.byKey(const ValueKey('option-check-in-o1'))).isEnabled, isTrue);
    });

    testWidgets('N 选 1：手机上长按选项 chip 打开长按弹层（记多份、改日期……），本期跳过记在选项上', (tester) async {
      final backend = currentBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=perks', size: const Size(400, 2000));
      final chip = find.byKey(const ValueKey('option-check-in-o2'));
      await tester.ensureVisible(chip);
      await tester.longPress(chip);
      await settle(tester);
      expect(find.byKey(const ValueKey('check-in-save')), findsOneWidget, reason: '长按不能只弹出 tooltip');
      await tapVisible(tester, find.byKey(const ValueKey('check-in-skip')));
      final body = backend.lastBody('POST', '/benefit-events');
      expect((body['benefitId'], body['kind']), ('o2', 'skip'));
    });

    testWidgets('领取路径点一下复制：可点区域至少 48 高，不会点成打开卡片', (tester) async {
      final copied = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text']);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final backend = currentBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=perks', size: const Size(400, 2000));
      final copy = find.byKey(const ValueKey('claim-how-b1'));
      expect(tester.getSize(copy).height, greaterThanOrEqualTo(48));
      expect(find.descendant(of: copy, matching: find.byIcon(Icons.copy_outlined)), findsOneWidget);
      await tapVisible(tester, copy);
      expect(copied, ['优酷App › 我的 › 88VIP']);
      expect(find.text('领取路径已复制'), findsOneWidget);
      expect(find.text('本期回本'), findsNothing, reason: '没有打开会员详情');
    });

    testWidgets('请求还在路上时再点「领了」：按钮转圈、这一下不做事（也不漏到整行打开卡片），不会换个 clientId 再记一条', (tester) async {
      final backend = currentBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=perks', size: const Size(400, 2000));
      backend.delayNext['POST /benefit-events'] = const Duration(seconds: 2);
      final button = find.byKey(const ValueKey('check-in-b4'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.descendant(of: button, matching: find.byType(CircularProgressIndicator)), findsOneWidget, reason: '请求没回来之前转圈');
      await tester.tap(button);
      await tester.pump(const Duration(milliseconds: 100));
      await settle(tester, frames: 30);
      expect(backend.requests('POST', '/benefit-events'), hasLength(1));
      expect(backend.perks.events.values.where((e) => e['benefitId'] == 'b4'), hasLength(1));
      expect(find.text('本期回本'), findsNothing, reason: '第二下没有漏到整行上去打开卡片');
      expect(find.descendant(of: button, matching: find.text('领了')), findsOneWidget, reason: '回来了就能再点');
    });

    testWidgets('N 选 1 请求还在路上时，连点另一个选项也不会记第二个', (tester) async {
      final backend = currentBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=perks', size: const Size(400, 2000));
      backend.delayNext['POST /benefit-events'] = const Duration(seconds: 2);
      await tester.ensureVisible(find.byKey(const ValueKey('option-check-in-o2')));
      await tester.tap(find.byKey(const ValueKey('option-check-in-o2')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const ValueKey('option-check-in-o1')), warnIfMissed: false);
      await settle(tester, frames: 30);
      expect(backend.requests('POST', '/benefit-events').map((r) => (jsonDecode(r.body) as Map<String, dynamic>)['benefitId']), ['o2']);
    });

    testWidgets('回应丢了、这条又被删掉以后再点：服务端回放的是墓碑，不放回本地；说一句，下一次换新的 clientId 照常记', (tester) async {
      final backend = currentBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=perks', size: const Size(400, 2000));
      backend.dropResponseNext.add('POST /benefit-events');
      await tapVisible(tester, find.byKey(const ValueKey('check-in-b4')));
      // 别的设备把这条删了（或者同步回来后在详情里删了）。
      final id = backend.perks.events.values.singleWhere((e) => e['benefitId'] == 'b4')['id'] as String;
      backend.perks.handle('DELETE', ['benefit-events', id], const {}, const {});

      await tapVisible(tester, find.byKey(const ValueKey('check-in-b4')));
      expect(find.text('这一次其实之前已经记上了，后来又被删掉；要记就再点一次'), findsOneWidget);
      expect(find.text('本月 0/2 · 还剩 7 天'), findsOneWidget, reason: '墓碑没被当成活的放回本地');

      await tapVisible(tester, find.byKey(const ValueKey('check-in-b4')));
      final ids = backend.requests('POST', '/benefit-events').map((r) => (jsonDecode(r.body) as Map<String, dynamic>)['clientId']).toList();
      expect(ids, hasLength(3));
      expect(ids[2], isNot(ids[0]), reason: '换了新的 clientId');
      expect(find.text('本月 1/2 · 还剩 7 天'), findsOneWidget);
    });

    testWidgets('打卡回应丢在路上：说清楚再点也不会重复记；再点沿用同一个 clientId，只记一条', (tester) async {
      final backend = currentBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=perks', size: const Size(400, 2000));
      backend.dropResponseNext.add('POST /benefit-events');
      await tapVisible(tester, find.byKey(const ValueKey('check-in-b4')));
      expect(find.text('没等到服务器回应，不确定记上没有。再点一次也不会重复记。'), findsOneWidget);
      await tapVisible(tester, find.byKey(const ValueKey('check-in-b4')));
      final posts = backend.requests('POST', '/benefit-events');
      expect(posts, hasLength(2));
      expect(posts.map((r) => (jsonDecode(r.body) as Map<String, dynamic>)['clientId']).toSet(), hasLength(1));
      expect(backend.perks.events.values.where((e) => e['benefitId'] == 'b4'), hasLength(1));
      expect(find.text('本月 1/2 · 还剩 7 天'), findsOneWidget);
    });

    testWidgets('回应丢了之后改用长按记了不一样的（×2）：是另一次打卡，换新的 clientId，不被当成重发吞掉', (tester) async {
      final backend = currentBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=perks', size: const Size(400, 2000));
      backend.dropResponseNext.add('POST /benefit-events');
      await tapVisible(tester, find.byKey(const ValueKey('check-in-b4')));
      await tester.ensureVisible(find.byKey(const ValueKey('current-b4')));
      await tester.longPress(find.byKey(const ValueKey('current-b4')));
      await settle(tester);
      await tester.enterText(find.byKey(const ValueKey('check-in-count')), '2');
      await tapVisible(tester, find.byKey(const ValueKey('check-in-save')));
      final ids = backend.requests('POST', '/benefit-events').map((r) => (jsonDecode(r.body) as Map<String, dynamic>)['clientId']);
      expect(ids.toSet(), hasLength(2));
      expect(backend.perks.events.values.where((e) => e['benefitId'] == 'b4').map((e) => e['count']), [1, 2]);
    });

    testWidgets('「我 / 全家」：登录了才有；选「我」只看自己的和全家共用的（「全部」里也是）；选择记进本机', (tester) async {
      final store = MemoryLocalStore();
      await pumpAssetsAt(
        tester,
        bootAssets(currentBackend(), store: store, session: await sessionAs('member')),
        '/assets?tab=perks',
        size: const Size(400, 2000),
      );
      expect(find.text('京东 · 1 项'), findsOneWidget, reason: '默认全家');
      await tapVisible(tester, find.byKey(const ValueKey('perk-scope-mine')));
      expect(find.text('京东 · 1 项'), findsNothing, reason: '京东PLUS 是爸爸的');
      expect(find.text('淘宝 · 2 项'), findsOneWidget, reason: '全家共用的照样看得到');
      expect(await store.read<Map<String, dynamic>>(PerkViewPrefsController.storeKey), {'view': 'current', 'scope': 'mine', 'grouping': 'byMembership'});

      await tapVisible(tester, find.byKey(const ValueKey('perk-view-all')));
      expect(find.text('京东PLUS'), findsNothing, reason: '「全部」里也按「我」过滤');
      expect(find.text('88VIP'), findsOneWidget);
    });

    testWidgets('没登录：不给「我 / 全家」，按全家看', (tester) async {
      await pumpAssetsAt(tester, bootAssets(currentBackend()), '/assets?tab=perks', size: const Size(400, 2000));
      expect(find.byKey(const ValueKey('perk-scope')), findsNothing);
      expect(find.text('京东 · 1 项'), findsOneWidget);
    });

    testWidgets('本期用完的（已完成里）长按照样能记：超额只提示「超额 N」，不拦', (tester) async {
      final backend = currentBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=perks', size: const Size(400, 2000));
      await tapVisible(tester, find.text('已完成 · 1 项'));
      expect(find.byKey(const ValueKey('check-in-b5')), findsNothing, reason: '用完了不给大按钮');
      await tester.ensureVisible(find.byKey(const ValueKey('current-b5')));
      await tester.longPress(find.byKey(const ValueKey('current-b5')));
      await settle(tester);
      await tapVisible(tester, find.byKey(const ValueKey('check-in-save')));
      final body = backend.lastBody('POST', '/benefit-events');
      expect((body['benefitId'], body['kind'], body['count']), ('b5', 'use', 1));
      expect(find.text('本年 7/6 · 超额 1'), findsOneWidget);
    });

    testWidgets('自动续费过期不到 15 天的卡：权益按推算本期算，行上标「推算本期」', (tester) async {
      final backend = AssetsBackend(
        perks: PerksFake(
          platforms: [platformJson('tx', name: '腾讯视频')],
          memberships: [
            membershipJson('tv', platformId: 'tx', name: '腾讯视频', feeCents: 2500, feePeriod: 'month', autoRenew: 'yes', termStartOn: '2026-08-21', expiresOn: '2026-09-20'),
          ],
          benefits: [
            benefitJson('b1', membershipId: 'tv', name: '观影券', quota: [
              {'p': 'term', 'n': 1},
            ]),
          ],
          events: [eventJson('e1', 'b1', occurredOn: '2026-09-01')],
        ),
      );
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=perks', size: const Size(400, 2000));
      expect(find.text('本期 0/1 · 还剩 27 天'), findsOneWidget, reason: '推算本期 9/21 ~ 10/20，上一期领的不算');
      expect(find.descendant(of: find.byKey(const ValueKey('current-b1')), matching: find.text('推算本期')), findsOneWidget);
    });

    testWidgets('都领完了：说一句，随时可用和已完成还在下面', (tester) async {
      final backend = AssetsBackend(
        perks: PerksFake(
          platforms: [platformJson('tb', name: '淘宝')],
          memberships: [membershipJson('vip')],
          benefits: [
            benefitJson('b1', name: '券', quota: [
              {'p': 'month', 'n': 1},
            ]),
            benefitJson('b2', name: '95 折', sort: 1),
          ],
          events: [eventJson('e1', 'b1', occurredOn: '2026-09-02')],
        ),
      );
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=perks');
      expect(find.text('本期的都领完了'), findsOneWidget);
      expect(find.text('随时可用 · 1 项'), findsOneWidget);
      expect(find.text('已完成 · 1 项'), findsOneWidget);
    });
  });
}
