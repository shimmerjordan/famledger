import 'package:famledger/app/theme.dart';
import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/data/models/models.dart';
import 'package:famledger/data/repos/session_repo.dart';
import 'package:famledger/ui/assets/asset_routes.dart';
import 'package:famledger/ui/home/home_page.dart';
import 'package:famledger/ui/perks/perk_providers.dart';
import 'package:famledger/ui/transactions/tx_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'assets_harness.dart';
import 'perks_fake.dart';

// 首页的「会员权益」段（spec §5）：写法照预算提醒，只在有事时出现，最多 3 行，权益行直接点 ✓、续费行有「续了」，
// 段头「全部 N 项」去会员权益 tab；窄屏在待确认之后，宽屏在右栏顶部。以及 P3 的验收：
// 在首页点一下 ✓，本期计数和回本条跟着变。「今天」= 2026-09-23。

final Transaction pendingTx = Transaction(
  id: 'p1',
  clientId: 'cp1',
  type: Transaction.typeExpense,
  amountCents: 3550,
  occurredAt: DateTime(2026, 9, 22, 12, 30),
  merchant: '巷口面馆',
  status: 'pending',
  source: 'notification',
);

/// 首页 + 资产路由，真的 LedgerRepo 接假服务端；返回路由，测试里可以直接跳。
Future<GoRouter> pumpHomeAt(
  WidgetTester tester,
  AssetsBackend backend, {
  Size size = const Size(400, 2000),
  SessionRepo? session,
  LocalStore? store,
  List<Transaction> pending = const [],
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = bootAssets(
    backend,
    session: session,
    store: store,
    overrides: [
      pendingTxProvider.overrideWith((ref) async => pending),
      recentTxProvider.overrideWith((ref) async => const <Transaction>[]),
    ],
  );
  addTearDown(container.dispose);
  final router = GoRouter(
    initialLocation: '/home',
    routes: [
      GoRoute(path: '/home', builder: (context, state) => const HomePage()),
      assetsRoute(),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(theme: buildTheme(Brightness.light), routerConfig: router),
    ),
  );
  await settle(tester);
  return router;
}

/// 88VIP（淘宝，本期 3/1 ~ 明年 2/28，¥88/年）：优酷年卡（去优酷领、面值 ¥248、9/28 前领，还没领）、购物券每月 4 张。
PerksFake acceptanceFixture() => PerksFake(
  platforms: [platformJson('tb', name: '淘宝'), platformJson('yk', name: '优酷', sort: 1)],
  memberships: [membershipJson('vip', feeCents: 8800, termStartOn: '2026-03-01', expiresOn: '2027-02-28')],
  benefits: [
    benefitJson('b1', name: '优酷年卡', kind: 'subscription', claimPlatformId: 'yk', faceValueCents: 24800, validUntil: '2026-09-28', quota: [
      {'p': 'total', 'n': 1},
    ]),
    benefitJson('b2', name: '购物券', kind: 'coupon', quota: [
      {'p': 'month', 'n': 4},
    ], sort: 1),
  ],
);

/// 四件事：腾讯视频应已自动续费（过期 3 天）、京东PLUS（爸爸的）明天到期、网盘 5 天后到期、88VIP 的优酷年卡快到期。
PerksFake busyFixture() => PerksFake(
  platforms: [platformJson('tb', name: '淘宝'), platformJson('tx', name: '腾讯视频', sort: 1), platformJson('jd', name: '京东', sort: 2)],
  memberships: [
    membershipJson('tv', platformId: 'tx', name: '腾讯视频', feeCents: 2500, feePeriod: 'month', autoRenew: 'yes', expiresOn: '2026-09-20'),
    membershipJson('plus', platformId: 'jd', name: '京东PLUS', memberId: 'u1', autoRenew: 'no', expiresOn: '2026-09-24', sort: 1),
    membershipJson('pan', name: '网盘', autoRenew: 'no', expiresOn: '2026-09-28', sort: 2),
    membershipJson('vip', sort: 3),
  ],
  benefits: [
    benefitJson('b1', membershipId: 'vip', name: '优酷年卡', quota: [
      {'p': 'total', 'n': 1},
    ], validUntil: '2026-09-29'),
  ],
);

void main() {
  testWidgets('没有会员卡、没到提醒的时候：整段不出现', (tester) async {
    await pumpHomeAt(tester, AssetsBackend(perks: PerksFake(memberships: [membershipJson('vip', expiresOn: '2027-02-28')])));
    expect(find.byKey(const ValueKey('home-perks')), findsNothing);
  });

  testWidgets('最多 3 行，过期待确认排最前；段头「全部 N 项」去会员权益 tab 的本期', (tester) async {
    await pumpHomeAt(tester, AssetsBackend(perks: busyFixture()));
    expect(find.text('全部 4 项'), findsOneWidget);
    expect(find.text('腾讯视频 应已自动续费，续上了吗？'), findsOneWidget);
    expect(find.text('京东PLUS 快到期'), findsOneWidget);
    expect(find.text('网盘 快到期'), findsOneWidget);
    expect(find.text('优酷年卡 快到期'), findsNothing, reason: '第 4 件收在「全部」里');
    expect(find.byKey(const ValueKey('alert-renew-tv')), findsOneWidget, reason: '续费行有「续了」');

    await tapVisible(tester, find.text('全部 4 项'));
    expect(find.text('要处理 · 4'), findsOneWidget, reason: '到了会员权益 tab 的本期');
  });

  testWidgets('只看「我的」加上全家共用的：爸爸的京东PLUS 不上妈妈的首页', (tester) async {
    await pumpHomeAt(
      tester,
      AssetsBackend(
        perks: busyFixture(),
        members: const [
          {'id': 'u1', 'username': 'baba', 'displayName': '爸爸', 'role': 'member'},
        ],
      ),
      session: await sessionAs('member'),
    );
    expect(find.text('全部 3 项'), findsOneWidget);
    expect(find.text('京东PLUS 快到期'), findsNothing);
    expect(find.text('优酷年卡 快到期'), findsOneWidget);
  });

  testWidgets('本机记着「全部」「全家」时点段头：照样落在「本期」、按「我」看，「要处理」和首页一样多（含「本期没领完」那一句）', (tester) async {
    final perks = busyFixture();
    // 本期 1/26 起的卡：按本期起算的这个月 8/26 ~ 9/25，券还没领 → 「本月还有 1 项没领」。
    perks.memberships['coupon'] = membershipJson('coupon', name: '购物卡', termStartOn: '2026-01-26', expiresOn: '2027-01-25', sort: 4);
    perks.benefits['q1'] = benefitJson('q1', membershipId: 'coupon', name: '月券', anchor: 'term', quota: [
      {'p': 'month', 'n': 4},
    ]);
    final store = MemoryLocalStore()..write(PerkViewPrefsController.storeKey, {'view': 'all', 'scope': 'family'});
    await pumpHomeAt(
      tester,
      AssetsBackend(
        perks: perks,
        members: const [
          {'id': 'u1', 'username': 'baba', 'displayName': '爸爸', 'role': 'member'},
        ],
      ),
      session: await sessionAs('member'),
      store: store,
    );
    expect(find.text('全部 4 项'), findsOneWidget, reason: '腾讯视频、网盘、优酷年卡、本月没领完；爸爸的京东PLUS 不算');
    await tapVisible(tester, find.text('全部 4 项'));
    expect(find.text('要处理 · 4'), findsOneWidget);
    expect(find.text('本月还有 1 项没领'), findsOneWidget);
    expect(find.text('京东PLUS 快到期'), findsNothing, reason: '和首页一样按「我」看');
    expect(await store.read<Map<String, dynamic>>(PerkViewPrefsController.storeKey), {'view': 'all', 'scope': 'family'}, reason: '不改本机记的选择');

    // 在 tab 里点「本期没领完」那一行不再跳一层；动了分段就以用户的为准。
    await tapVisible(tester, find.text('本月还有 1 项没领'));
    expect(find.text('要处理 · 4'), findsOneWidget);
    await tapVisible(tester, find.byKey(const ValueKey('perk-view-all')));
    expect(find.byKey(const ValueKey('perk-grouping')), findsOneWidget);
    expect(await store.read<Map<String, dynamic>>(PerkViewPrefsController.storeKey), {'view': 'all', 'scope': 'mine', 'grouping': 'byMembership'});
  });

  testWidgets('续费行点「续了」：续上一期，这一行就没了', (tester) async {
    final backend = AssetsBackend(perks: busyFixture());
    await pumpHomeAt(tester, backend);
    await tapVisible(tester, find.byKey(const ValueKey('alert-renew-tv')));
    expect(backend.requests('POST', '/memberships/tv/renew'), hasLength(1));
    expect(find.text('腾讯视频 应已自动续费，续上了吗？'), findsNothing);
    expect(find.text('全部 3 项'), findsOneWidget);
  });

  testWidgets('位置（窄屏）：在待确认之后、资产之前', (tester) async {
    await pumpHomeAt(tester, AssetsBackend(perks: acceptanceFixture()), pending: [pendingTx]);
    final perks = tester.getTopLeft(find.byKey(const ValueKey('home-perks'))).dy;
    expect(tester.getTopLeft(find.text('待确认 1')).dy, lessThan(perks));
    expect(perks, lessThan(tester.getTopLeft(find.text('记录资产')).dy));
  });

  testWidgets('位置（宽屏）：在右栏顶部，基金余额上面', (tester) async {
    await pumpHomeAt(tester, AssetsBackend(perks: acceptanceFixture()), size: const Size(1400, 1000));
    final side = tester.getTopLeft(find.byKey(const ValueKey('home-perks')));
    expect(side.dx, greaterThan(800), reason: '在右栏');
    expect(side.dy, lessThan(tester.getTopLeft(find.text('基金余额')).dy));
  });

  testWidgets('验收：在首页点一下 ✓，本期计数和回本条跟着变', (tester) async {
    final backend = AssetsBackend(perks: acceptanceFixture());
    final router = await pumpHomeAt(tester, backend);

    // 先看一眼会员权益 tab：本期待领 2 项；「全部」里 88VIP 还没回本。
    router.push('/assets?tab=perks');
    await settle(tester);
    expect(find.text('本期待领 · 2 项'), findsOneWidget);
    await tapVisible(tester, find.byKey(const ValueKey('perk-view-current')));
    await tapVisible(tester, find.byKey(const ValueKey('perk-view-all')));
    expect(find.text('已回本 0% · ¥0.00 / ¥88.00'), findsOneWidget);
    router.pop();
    await settle(tester);

    // 首页：优酷年卡快到期，直接点 ✓。
    expect(find.text('优酷年卡 快到期'), findsOneWidget);
    await tapVisible(tester, find.byKey(const ValueKey('alert-check-b1')));
    final body = backend.lastBody('POST', '/benefit-events');
    expect((body['benefitId'], body['kind'], body['count'], body['occurredOn']), ('b1', 'claim', 1, '2026-09-23'));
    expect(find.text('领了：优酷年卡'), findsOneWidget);
    expect(find.byKey(const ValueKey('home-perks')), findsNothing, reason: '领过了，首页这段没事了');

    // 回到 tab：还记得上次看的是「全部」—— 回本条变了；切到「本期」，待领少了一项、已完成多了一项。
    router.push('/assets?tab=perks');
    await settle(tester);
    expect(find.text('已回本 282% · ¥248.00 / ¥88.00'), findsOneWidget);
    await tapVisible(tester, find.byKey(const ValueKey('perk-view-current')));
    expect(find.text('本期待领 · 1 项'), findsOneWidget);
    expect(find.text('已完成 · 1 项'), findsOneWidget);
  });

  for (final size in kWidths) {
    testWidgets('${size.width.toInt()} 宽、字号 1.5 倍：首页的会员权益段不溢出', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpHomeAt(tester, AssetsBackend(perks: busyFixture()), size: size);
      expect(find.byKey(const ValueKey('home-perks')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
