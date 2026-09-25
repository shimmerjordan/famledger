import 'dart:convert';

import 'package:famledger/ui/perks/platforms_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assets_harness.dart';
import 'perks_fake.dart';

const Size tall = Size(400, 1800);

/// 淘宝挂着 88VIP；天猫挂着一张重复建的卡、还是一项权益的领取地；优酷只是领取地；京东没人用；归档的老平台。
AssetsBackend platformsBackend() => AssetsBackend(
  perks: PerksFake(
    platforms: [
      platformJson('tb', name: '淘宝', aliases: ['淘宝网']),
      platformJson('tm', name: '天猫', sort: 1),
      platformJson('yk', name: '优酷', sort: 2),
      platformJson('jd', name: '京东', sort: 3),
      platformJson('old', name: '老平台', sort: 4, archived: true),
    ],
    memberships: [
      membershipJson('vip'),
      membershipJson('dup', platformId: 'tm', name: '88VIP（重复）', sort: 1),
    ],
    benefits: [
      benefitJson('b1', name: '优酷年卡', claimPlatformId: 'yk'),
      benefitJson('b2', name: '天猫券', claimPlatformId: 'tm', sort: 1),
    ],
  ),
);

void main() {
  group('平台管理', () {
    testWidgets('列表：每个平台几张卡、几项在这领、别名；归档的收在后面', (tester) async {
      await pumpAssetsAt(tester, bootAssets(platformsBackend()), '/assets/platforms', size: tall);
      expect(find.text('1 张卡 · 0 项在这领\n也叫 淘宝网'), findsOneWidget);
      expect(find.text('1 张卡 · 1 项在这领'), findsOneWidget);
      expect(find.text('0 张卡 · 1 项在这领'), findsOneWidget);
      expect(find.text('0 张卡 · 0 项在这领'), findsNWidgets(2), reason: '京东 + 归档的老平台');
      expect(find.text('已归档'), findsOneWidget);
      expect(tester.getTopLeft(find.text('老平台')).dy, greaterThan(tester.getTopLeft(find.text('京东')).dy));
    });

    testWidgets('改名、加别名（同名的别名不重复加）、改类型', (tester) async {
      final backend = platformsBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/platforms/tb/edit', size: tall);
      expect(find.byKey(const ValueKey('platform-alias-淘宝网')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('platform-name')), '淘宝天猫');
      await tester.enterText(find.byKey(const ValueKey('platform-alias-input')), 'Taobao');
      await tester.tap(find.byKey(const ValueKey('platform-alias-add')));
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('platform-alias-input')), 'ＴＡＯＢＡＯ');
      await tester.tap(find.byKey(const ValueKey('platform-alias-add')));
      await tester.pump();
      await tapVisible(tester, find.byKey(const ValueKey('platform-kind-shopping')));
      await tapVisible(tester, find.widgetWithText(FilledButton, '保存'));
      expect(backend.lastBody('PATCH', '/platforms/tb'), {
        'name': '淘宝天猫',
        'kind': 'shopping',
        'aliases': ['淘宝网', 'Taobao'],
        'url': null,
        'note': null,
      });
      expect(find.byType(PlatformsPage), findsOneWidget, reason: '存完回到列表');
    });

    testWidgets('别名框里写了没点「加上」就点保存：照样带上，不悄悄丢掉；太长的行内拦下', (tester) async {
      final backend = platformsBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/platforms/tb/edit', size: tall);
      await tester.enterText(find.byKey(const ValueKey('platform-alias-input')), ' 天猫 ');
      await tapVisible(tester, find.widgetWithText(FilledButton, '保存'));
      expect(backend.lastBody('PATCH', '/platforms/tb')['aliases'], ['淘宝网', '天猫']);

      await pumpAssetsAt(tester, bootAssets(backend), '/assets/platforms/jd/edit', size: tall);
      await tester.enterText(find.byKey(const ValueKey('platform-alias-input')), '长'.padRight(31, '长'));
      await tapVisible(tester, find.widgetWithText(FilledButton, '保存'));
      expect(find.text('每个别名最多 30 个字'), findsOneWidget);
      expect(backend.requests('PATCH', '/platforms/jd'), isEmpty);
    });

    testWidgets('平台选择里输入全是标点：不给「新建」、不发请求，归档的也不翻出来', (tester) async {
      final backend = platformsBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/new', size: tall);
      await tapVisible(tester, find.byKey(const ValueKey('membership-platform')));
      await tester.enterText(find.byKey(const ValueKey('platform-search')), '！！');
      await tester.pump();
      expect(find.byKey(const ValueKey('platform-create')), findsNothing);
      expect(find.text('名称里至少要有一个字或字母'), findsOneWidget);
      expect(find.byKey(const ValueKey('platform-pick-old')), findsNothing, reason: '归档的平台只在真搜到时给');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(backend.requests('POST', '/platforms'), isEmpty);
    });

    testWidgets('改名撞上别的平台：把服务端的话原样说出来', (tester) async {
      await pumpAssetsAt(tester, bootAssets(platformsBackend()), '/assets/platforms/jd/edit', size: tall);
      await tester.enterText(find.byKey(const ValueKey('platform-name')), ' 天猫 ');
      await tapVisible(tester, find.widgetWithText(FilledButton, '保存'));
      expect(find.text('已经有叫「天猫」的平台了'), findsOneWidget);
    });

    testWidgets('合并：选目标、确认里说清楚要改哪些；并完天猫的卡和领取地都到淘宝，天猫记成别名', (tester) async {
      final backend = platformsBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/platforms/tm/edit', size: tall);
      await tapVisible(tester, find.byKey(const ValueKey('platform-merge')));
      await tester.tap(find.byKey(const ValueKey('merge-target-tb')));
      await settle(tester);
      expect(find.text('把「天猫」并入「淘宝」？'), findsOneWidget);
      expect(find.text('「天猫」下的 1 张卡、1 项领取地都改到「淘宝」，「天猫」记成「淘宝」的别名，然后删掉「天猫」。'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '合并'));
      await settle(tester);

      final body = backend.lastBody('POST', '/platforms/tm/merge');
      expect(body['targetId'], 'tb');
      expect(body['clientId'], isA<String>());
      expect(find.text('已并入「淘宝」'), findsOneWidget);
      expect(find.text('2 张卡 · 1 项在这领\n也叫 淘宝网、天猫'), findsOneWidget, reason: '同步回来后列表按新引用数画');
      expect(find.text('天猫'), findsNothing);
    });

    testWidgets('合并的回应丢了：说清楚「再点一次也不会重复」；并入同一个平台沿用 clientId，只并一次', (tester) async {
      final backend = platformsBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/platforms/tm/edit', size: tall);
      backend.dropResponseNext.add('POST /platforms/tm/merge');
      await tapVisible(tester, find.byKey(const ValueKey('platform-merge')));
      await tester.tap(find.byKey(const ValueKey('merge-target-tb')));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, '合并'));
      await settle(tester);
      expect(find.text('没等到服务器回应，不确定记上没有。再点一次也不会重复记。'), findsOneWidget);

      await tapVisible(tester, find.byKey(const ValueKey('platform-merge')));
      await tester.tap(find.byKey(const ValueKey('merge-target-tb')));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, '合并'));
      await settle(tester);
      final ids = backend.requests('POST', '/platforms/tm/merge').map((r) => (jsonDecode(r.body) as Map)['clientId']).toList();
      expect(ids, hasLength(2));
      expect(ids.toSet(), hasLength(1));
      expect(find.text('已并入「淘宝」'), findsOneWidget);
    });

    testWidgets('合并换了目标就换一个 clientId：不会把上一次的结果回放成「已并入」新目标', (tester) async {
      final backend = platformsBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/platforms/tm/edit', size: tall);
      backend.dropResponseNext.add('POST /platforms/tm/merge');
      await tapVisible(tester, find.byKey(const ValueKey('platform-merge')));
      await tester.tap(find.byKey(const ValueKey('merge-target-tb')));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, '合并'));
      await settle(tester);

      // 第一次其实已经并进淘宝了；这时改选优酷，服务端会说天猫已经不在了，而不是回「已并入优酷」。
      await tapVisible(tester, find.byKey(const ValueKey('platform-merge')));
      await tester.tap(find.byKey(const ValueKey('merge-target-yk')));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, '合并'));
      await settle(tester);
      final ids = backend.requests('POST', '/platforms/tm/merge').map((r) => (jsonDecode(r.body) as Map)['clientId']).toList();
      expect(ids, hasLength(2));
      expect(ids[0], isNot(ids[1]));
      expect(find.text('已并入「优酷」'), findsNothing);
      expect(find.text('平台不存在'), findsOneWidget);
    });

    for (final size in kWidths) {
      testWidgets('${size.width.toInt()} 宽：平台列表、编辑页、合并弹层都不溢出', (tester) async {
        await pumpAssetsAt(tester, bootAssets(platformsBackend()), '/assets/platforms', size: size);
        expect(tester.takeException(), isNull);
        await pumpAssetsAt(tester, bootAssets(platformsBackend()), '/assets/platforms/tm/edit', size: Size(size.width, 1800));
        expect(tester.takeException(), isNull);
        await tapVisible(tester, find.byKey(const ValueKey('platform-merge')));
        expect(find.byKey(const ValueKey('merge-target-tb')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('删除：没人用的直接删；还有卡挂着的说清楚原因（409 platform_in_use）', (tester) async {
      final backend = platformsBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/platforms/jd/edit', size: tall);
      await tapVisible(tester, find.byKey(const ValueKey('platform-delete')));
      await tester.tap(find.widgetWithText(FilledButton, '删掉'));
      await settle(tester);
      expect(backend.perks.platforms.containsKey('jd'), isFalse);
      expect(find.text('已删掉'), findsOneWidget);

      await pumpAssetsAt(tester, bootAssets(backend), '/assets/platforms/tb/edit', size: tall);
      await tapVisible(tester, find.byKey(const ValueKey('platform-delete')));
      await tester.tap(find.widgetWithText(FilledButton, '删掉'));
      await settle(tester);
      expect(find.text('还有 1 张会员卡挂在它下面，不能删；可以归档，或并入别的平台'), findsOneWidget);
      expect(backend.perks.platforms.containsKey('tb'), isTrue);
    });

    testWidgets('归档：选平台时不再列出，已有的卡照常显示名字', (tester) async {
      final backend = platformsBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/platforms/yk/edit', size: tall);
      await tapVisible(tester, find.byKey(const ValueKey('platform-archive')));
      expect(backend.lastBody('PATCH', '/platforms/yk'), {'archived': true});

      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/new', size: tall);
      await tapVisible(tester, find.byKey(const ValueKey('membership-platform')));
      expect(find.byKey(const ValueKey('platform-pick-yk')), findsNothing, reason: '归档的平时藏起来');
      await tester.enterText(find.byKey(const ValueKey('platform-search')), '优酷');
      await tester.pump();
      expect(find.byKey(const ValueKey('platform-pick-yk')), findsOneWidget, reason: '搜到了照样能接着用');
      expect(find.byKey(const ValueKey('platform-create')), findsNothing, reason: '同名的归档平台也算，不再新建一个');
    });

    testWidgets('新建平台：名字全是标点时行内拦下', (tester) async {
      final backend = platformsBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/platforms/new', size: tall);
      await tester.enterText(find.byKey(const ValueKey('platform-name')), '！！');
      await tapVisible(tester, find.widgetWithText(FilledButton, '建好了'));
      expect(find.text('名称里至少要有一个字或字母'), findsOneWidget);
      expect(backend.requests('POST', '/platforms'), isEmpty);
    });
  });
}
