import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assets_harness.dart';
import 'perks_fake.dart';

const Size tall = Size(400, 3000);

/// 88VIP（淘宝）下已有「年卡二选一」（flow=use、每年 1 次）和它的一个选项；优酷是另一个平台。
AssetsBackend vipBackend() => AssetsBackend(
  perks: PerksFake(
    platforms: [platformJson('tb', name: '淘宝'), platformJson('yk', name: '优酷', sort: 1)],
    memberships: [membershipJson('vip', feeCents: 8800)],
    benefits: [
      benefitJson('c1', name: '年卡二选一', kind: 'choice', flow: 'use', quota: [
        {'p': 'year', 'n': 1},
      ]),
      benefitJson('o1', parentId: 'c1', name: '芒果年卡', flow: 'use', sort: 1),
    ],
  ),
);

Finder onClaimButton(String text) =>
    find.descendant(of: find.byKey(const ValueKey('benefit-claim-platform')), matching: find.text(text));

void main() {
  group('权益表单', () {
    testWidgets('默认：会员本平台、领到手就算、不限次；只填名字就能存', (tester) async {
      final backend = vipBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/vip/benefits/new', size: tall);
      expect(find.text('加一项权益'), findsOneWidget);
      expect(onClaimButton('会员本平台（淘宝）'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('benefit-name')), '天猫超市 95 折');
      await tapVisible(tester, find.widgetWithText(FilledButton, '加好了'));
      final body = backend.lastBody('POST', '/benefits');
      expect(body, {
        'membershipId': 'vip',
        'name': '天猫超市 95 折',
        'kind': 'other',
        'flow': 'claim',
        'quota': <Object>[],
        'anchor': 'calendar',
        'remind': true,
        'clientId': body['clientId'],
      });
      expect(body['clientId'], isA<String>());
    });

    testWidgets('回应丢在路上：说清楚「再点一次也不会重复记」，再点保存沿用同一个 clientId，只加一条', (tester) async {
      final backend = vipBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/vip/benefits/new', size: tall);
      await tester.enterText(find.byKey(const ValueKey('benefit-name')), '优酷年卡');
      backend.dropResponseNext.add('POST /benefits');
      await tapVisible(tester, find.widgetWithText(FilledButton, '加好了'));
      expect(find.text('没等到服务器回应，不确定记上没有。再点一次也不会重复记。'), findsOneWidget);
      await tapVisible(tester, find.widgetWithText(FilledButton, '加好了'));
      final posts = backend.requests('POST', '/benefits');
      expect(posts, hasLength(2));
      expect(posts.map((r) => (jsonDecode(r.body) as Map)['clientId']).toSet(), hasLength(1));
      expect(backend.perks.benefits.values.where((b) => b['name'] == '优酷年卡'), hasLength(1));
    });

    testWidgets('额度预设：每月 N 次要填次数；高级里叠加「另外每年最多 6 次」、起算选会员本期；三个直白的算法', (tester) async {
      final backend = vipBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/vip/benefits/new', size: tall);
      await tester.enterText(find.byKey(const ValueKey('benefit-name')), '红包');
      expect(find.text('领到手就算'), findsOneWidget);
      expect(find.text('用一次算'), findsOneWidget);
      expect(find.text('先领再用'), findsOneWidget);
      await tapVisible(tester, find.byKey(const ValueKey('benefit-flow-claim_use')));
      expect(find.textContaining('本期还没领会提示「待领」'), findsOneWidget);

      await tapVisible(tester, find.byKey(const ValueKey('quota-preset-monthly')));
      await tester.enterText(find.byKey(const ValueKey('quota-count')), '2');
      await tapVisible(tester, find.text('高级'));
      await tapVisible(tester, find.byKey(const ValueKey('quota-add-extra')));
      await tester.enterText(find.byKey(const ValueKey('quota-extra-count-1')), '6');
      await tapVisible(tester, find.byKey(const ValueKey('benefit-anchor-term')));
      await tapVisible(tester, find.widgetWithText(FilledButton, '加好了'));

      final body = backend.lastBody('POST', '/benefits');
      expect(body['flow'], 'claim_use');
      expect(body['quota'], [
        {'p': 'month', 'n': 2},
        {'p': 'year', 'n': 6},
      ]);
      expect(body['anchor'], 'term');
    });

    testWidgets('其余预设：会籍期内 1 次、一次性', (tester) async {
      final backend = vipBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/vip/benefits/new', size: tall);
      await tester.enterText(find.byKey(const ValueKey('benefit-name')), '体检');
      await tapVisible(tester, find.byKey(const ValueKey('quota-preset-termOnce')));
      await tapVisible(tester, find.widgetWithText(FilledButton, '加好了'));
      expect(backend.lastBody('POST', '/benefits')['quota'], [
        {'p': 'term', 'n': 1},
      ]);

      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/vip/benefits/new', size: tall);
      await tester.enterText(find.byKey(const ValueKey('benefit-name')), '开卡礼');
      await tapVisible(tester, find.byKey(const ValueKey('quota-preset-once')));
      await tapVisible(tester, find.widgetWithText(FilledButton, '加好了'));
      expect(backend.lastBody('POST', '/benefits')['quota'], [
        {'p': 'total', 'n': 1},
      ]);
    });

    testWidgets('额度填错（0 次、周期重复）：行内报错，不发请求', (tester) async {
      final backend = vipBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/vip/benefits/new', size: tall);
      await tester.enterText(find.byKey(const ValueKey('benefit-name')), '红包');
      await tapVisible(tester, find.byKey(const ValueKey('quota-preset-monthly')));
      await tester.enterText(find.byKey(const ValueKey('quota-count')), '0');
      await tapVisible(tester, find.widgetWithText(FilledButton, '加好了'));
      expect(find.text('次数填 1 到 9999 的整数'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('quota-count')), '2');
      await tapVisible(tester, find.text('高级'));
      await tapVisible(tester, find.byKey(const ValueKey('quota-add-extra')));
      await tester.enterText(find.byKey(const ValueKey('quota-extra-count-1')), '6');
      await tapVisible(tester, find.byKey(const ValueKey('quota-period-1')));
      await tester.tap(find.text('每月').last);
      await settle(tester);
      await tapVisible(tester, find.widgetWithText(FilledButton, '加好了'));
      expect(find.text('同一个周期只能写一条上限'), findsOneWidget);
      expect(backend.requests('POST', '/benefits'), isEmpty);
    });

    testWidgets('在哪领：选别的平台、就地新建「优酷」；领取路径、链接、有效期、面值、限制条件都带上', (tester) async {
      final backend = vipBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/vip/benefits/new', size: tall);
      await tester.enterText(find.byKey(const ValueKey('benefit-name')), '腾讯视频年卡');
      await tapVisible(tester, find.byKey(const ValueKey('benefit-kind-subscription')));

      await tapVisible(tester, find.byKey(const ValueKey('benefit-claim-platform')));
      await tester.enterText(find.byKey(const ValueKey('platform-search')), '腾讯视频');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('platform-create')));
      await settle(tester);
      expect(onClaimButton('腾讯视频'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('benefit-claim-how')), '腾讯视频App › 我的 › 兑换');
      await tester.enterText(find.byKey(const ValueKey('benefit-claim-url')), 'https://v.qq.com/vip');
      await tapVisible(tester, find.byKey(const ValueKey('benefit-valid-until')));
      await tester.tap(find.byTooltip('Next month'));
      await settle(tester);
      await tester.tap(find.descendant(of: find.byType(DatePickerDialog), matching: find.text('31')));
      await tester.pump();
      await tester.tap(find.text('OK'));
      await settle(tester);
      await tester.enterText(find.byKey(const ValueKey('benefit-face')), '258');
      await tapVisible(tester, find.byKey(const ValueKey('benefit-limit-add')));
      await tester.enterText(find.byKey(const ValueKey('benefit-limit-text-0')), '限本人账号');
      await tapVisible(tester, find.byKey(const ValueKey('benefit-remind')));
      await tapVisible(tester, find.widgetWithText(FilledButton, '加好了'));

      final body = backend.lastBody('POST', '/benefits');
      final created = backend.perks.platforms.values.firstWhere((p) => p['name'] == '腾讯视频');
      expect(body['claimPlatformId'], created['id']);
      expect(body['kind'], 'subscription');
      expect(body['claimHow'], '腾讯视频App › 我的 › 兑换');
      expect(body['claimUrl'], 'https://v.qq.com/vip');
      expect(body['validUntil'], '2026-10-31');
      expect(body['faceValueCents'], 25800);
      expect(body['limits'], [
        {'type': 'other', 'text': '限本人账号'},
      ]);
      expect(body['remind'], false);
    });

    testWidgets('链接不是 http(s)、有效期结束早于开始：行内报错', (tester) async {
      final backend = vipBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/vip/benefits/new', size: tall);
      await tester.enterText(find.byKey(const ValueKey('benefit-name')), '券');
      await tester.enterText(find.byKey(const ValueKey('benefit-claim-url')), 'taobao://coupon');
      await tapVisible(tester, find.widgetWithText(FilledButton, '加好了'));
      expect(find.text('链接要以 http:// 或 https:// 开头'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('benefit-claim-url')), '');

      await tapVisible(tester, find.byKey(const ValueKey('benefit-valid-from')));
      await tester.tap(find.text('OK'));
      await settle(tester);
      await tapVisible(tester, find.byKey(const ValueKey('benefit-valid-until')));
      await tester.tap(find.descendant(of: find.byType(DatePickerDialog), matching: find.text('1')));
      await tester.pump();
      await tester.tap(find.text('OK'));
      await settle(tester);
      await tapVisible(tester, find.widgetWithText(FilledButton, '加好了'));
      expect(find.text('有效期的结束不能早于开始'), findsOneWidget);
      expect(backend.requests('POST', '/benefits'), isEmpty);
    });

    testWidgets('给 N 选 1 加选项：不出额度和算法，请求体带 parentId、不带 flow/quota', (tester) async {
      final backend = vipBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/vip/benefits/new?parentId=c1', size: tall);
      expect(find.text('加一个选项'), findsOneWidget);
      expect(find.text('88VIP ·「年卡二选一」的一个选项：额度和算法跟着它'), findsOneWidget);
      expect(find.byKey(const ValueKey('quota-preset-monthly')), findsNothing);
      expect(find.byKey(const ValueKey('benefit-flow-claim')), findsNothing);
      expect(find.byKey(const ValueKey('benefit-kind-choice')), findsNothing, reason: '选项不能再是 N 选 1');
      await tester.enterText(find.byKey(const ValueKey('benefit-name')), '优酷年卡');
      await tapVisible(tester, find.widgetWithText(FilledButton, '加好了'));
      final body = backend.lastBody('POST', '/benefits');
      expect(body['parentId'], 'c1');
      expect(body.containsKey('flow'), isFalse);
      expect(body.containsKey('quota'), isFalse);
    });

    testWidgets('选 N 选 1 类型时说清楚下一步：先建这条，再加选项；「在哪领」旁说明选项没写时跟这里', (tester) async {
      await pumpAssetsAt(tester, bootAssets(vipBackend()), '/assets/memberships/vip/benefits/new', size: tall);
      expect(find.byKey(const ValueKey('benefit-claim-choice-hint')), findsNothing);
      await tapVisible(tester, find.byKey(const ValueKey('benefit-kind-choice')));
      expect(find.byKey(const ValueKey('benefit-choice-hint')), findsOneWidget);
      expect(find.text('选项没写时跟这里'), findsOneWidget);
    });

    testWidgets('N 选 1 写了领取平台：给它加选项时「在哪领」的不选项写「跟着它」，不冒充会员本平台', (tester) async {
      final backend = vipBackend();
      backend.perks.benefits['c1']!['claimPlatformId'] = 'yk';
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/vip/benefits/new?parentId=c1', size: tall);
      expect(onClaimButton('跟着「年卡二选一」（优酷）'), findsOneWidget);
      expect(find.text('会员本平台（淘宝）'), findsNothing);

      // N 选 1 自己没写时，选项不写就是会员本平台。
      await pumpAssetsAt(tester, bootAssets(vipBackend()), '/assets/benefits/o1/edit', size: tall);
      expect(onClaimButton('会员本平台（淘宝）'), findsOneWidget);
    });

    testWidgets('编辑：带出原值；自定义额度（每周 2 次）在高级里改；清掉领取平台发 null', (tester) async {
      final backend = AssetsBackend(
        perks: PerksFake(
          platforms: [platformJson('tb', name: '淘宝'), platformJson('yk', name: '优酷', sort: 1)],
          memberships: [membershipJson('vip')],
          benefits: [
            benefitJson('b1', name: '优酷年卡', claimPlatformId: 'yk', quota: [
              {'p': 'week', 'n': 2},
            ], limits: [
              {'type': 'min_spend', 'text': '满 99'},
            ]),
          ],
        ),
      );
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/benefits/b1/edit', size: tall);
      expect(find.widgetWithText(TextField, '优酷年卡'), findsOneWidget);
      expect(onClaimButton('优酷'), findsOneWidget);
      expect(find.text('自定义额度：每周 2 次，在「高级」里改'), findsOneWidget);
      expect(find.byKey(const ValueKey('quota-period-0')), findsOneWidget, reason: '自定义时第一条也在高级里');
      expect(find.text('每'), findsNothing, reason: '第一条读「每周 最多 2 次」，不是「每 每周」');
      expect(find.text('另外'), findsNothing);
      await tapVisible(tester, find.byKey(const ValueKey('quota-add-extra')));
      expect(find.text('另外'), findsOneWidget, reason: '叠加的那条读「另外 每年 最多 … 次」');
      await tester.tap(find.byTooltip('去掉这条').at(1));
      await settle(tester);
      expect(find.widgetWithText(TextField, '满 99'), findsOneWidget);

      await tapVisible(tester, find.byKey(const ValueKey('benefit-claim-platform')));
      await tester.tap(find.byKey(const ValueKey('platform-none')));
      await settle(tester);
      await tester.enterText(find.byKey(const ValueKey('quota-extra-count-0')), '3');
      await tapVisible(tester, find.widgetWithText(FilledButton, '保存'));
      final body = backend.lastBody('PATCH', '/benefits/b1');
      expect(body['claimPlatformId'], isNull);
      expect(body.containsKey('claimPlatformId'), isTrue, reason: 'null 要发出去才清得掉');
      expect(body['quota'], [
        {'p': 'week', 'n': 3},
      ]);
      expect(body['limits'], [
        {'type': 'min_spend', 'text': '满 99'},
      ]);
    });

    testWidgets('删带出过派生卡的权益：说清楚那张卡会留着、只是不再关联', (tester) async {
      final backend = AssetsBackend(
        perks: PerksFake(
          platforms: [platformJson('tb', name: '淘宝'), platformJson('yk', name: '优酷', sort: 1)],
          memberships: [
            membershipJson('vip'),
            membershipJson('ykvip', platformId: 'yk', name: '优酷VIP', sourceBenefitId: 'b1', sort: 1),
          ],
          benefits: [benefitJson('b1', name: '优酷年卡', claimPlatformId: 'yk')],
        ),
      );
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/benefits/b1/edit', size: tall);
      await tester.tap(find.byKey(const ValueKey('benefit-delete')));
      await settle(tester);
      expect(find.text('删掉后找不回来。由它带出来的「优酷VIP」会留着，只是不再关联。'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '删掉'));
      await settle(tester);
      expect(backend.requests('DELETE', '/benefits/b1').single.url.queryParameters, <String, String>{});
      expect(backend.perks.memberships['ykvip']?['sourceBenefitId'], isNull);
      expect(backend.perks.memberships.containsKey('ykvip'), isTrue);
    });

    testWidgets('服务端有本地不知道的打卡记录（409 has_children）：按服务端的数说一句陈述，再确认就带 cascade', (tester) async {
      final backend = vipBackend();
      backend.perks.benefits['b9'] = benefitJson('b9', name: '贵宾厅', sort: 2);
      backend.perks.events['b9'] = 3;
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/benefits/b9/edit', size: tall);
      await tester.tap(find.byKey(const ValueKey('benefit-delete')));
      await settle(tester);
      expect(find.text('删掉后找不回来。'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '删掉'));
      await settle(tester);
      expect(find.text('别的设备刚给它加了选项或打卡记录。它下面的 3 条打卡记录会一起删掉。'), findsOneWidget);
      expect(find.textContaining('要一起删掉吗'), findsNothing, reason: '不拿服务端的问句去拼');
      await tester.tap(find.widgetWithText(FilledButton, '删掉'));
      await settle(tester);
      expect(backend.requests('DELETE', '/benefits/b9').map((r) => r.url.queryParameters), [<String, String>{}, {'cascade': '1'}]);
      expect(backend.perks.benefits.containsKey('b9'), isFalse);
    });

    testWidgets('409 之后第二次点「算了」：什么都不删，删除按钮恢复可点', (tester) async {
      final backend = vipBackend();
      backend.perks.benefits['b9'] = benefitJson('b9', name: '贵宾厅', sort: 2);
      backend.perks.events['b9'] = 1;
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/benefits/b9/edit', size: tall);
      await tester.tap(find.byKey(const ValueKey('benefit-delete')));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, '删掉'));
      await settle(tester);
      await tester.tap(find.text('算了'));
      await settle(tester);
      expect(backend.requests('DELETE', '/benefits/b9'), hasLength(1));
      expect(backend.perks.benefits.containsKey('b9'), isTrue);
      expect(tester.widget<IconButton>(find.byKey(const ValueKey('benefit-delete'))).onPressed, isNotNull);
    });

    testWidgets('编辑时能归档：请求体带 archived；归档的从会员详情的列表里收起来', (tester) async {
      final backend = vipBackend();
      backend.perks.benefits['b9'] = benefitJson('b9', name: '贵宾厅', sort: 2);
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/vip', size: tall);
      expect(find.text('权益 · 2 项'), findsOneWidget);
      await tapVisible(tester, find.text('贵宾厅'));
      expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('benefit-archived'))).value, isFalse);
      await tapVisible(tester, find.byKey(const ValueKey('benefit-archived')));
      await tapVisible(tester, find.widgetWithText(FilledButton, '保存'));
      expect(backend.lastBody('PATCH', '/benefits/b9')['archived'], isTrue);
      expect(find.text('权益 · 1 项'), findsOneWidget);
      expect(find.text('已归档 · 1 项'), findsOneWidget);
    });

    testWidgets('新建时没有「归档」开关', (tester) async {
      await pumpAssetsAt(tester, bootAssets(vipBackend()), '/assets/memberships/vip/benefits/new', size: tall);
      expect(find.byKey(const ValueKey('benefit-archived')), findsNothing);
    });

    for (final size in kWidths) {
      testWidgets('${size.width.toInt()} 宽：展开「高级」、加满上限和两条限制也不溢出', (tester) async {
        await pumpAssetsAt(tester, bootAssets(vipBackend()), '/assets/memberships/vip/benefits/new', size: Size(size.width, 3000));
        await tapVisible(tester, find.byKey(const ValueKey('quota-preset-monthly')));
        await tapVisible(tester, find.text('高级'));
        await tapVisible(tester, find.byKey(const ValueKey('quota-add-extra')));
        await tapVisible(tester, find.byKey(const ValueKey('quota-add-extra')));
        await tapVisible(tester, find.byKey(const ValueKey('benefit-limit-add')));
        await tapVisible(tester, find.byKey(const ValueKey('benefit-limit-add')));
        expect(find.byKey(const ValueKey('quota-extra-count-2')), findsOneWidget);
        expect(find.byKey(const ValueKey('benefit-limit-text-1')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tapVisible(tester, find.byKey(const ValueKey('benefit-claim-platform')));
        expect(find.byKey(const ValueKey('platform-search')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('${size.width.toInt()} 宽、字号 1.5 倍：权益表单不溢出', (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = 1.5;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await pumpAssetsAt(tester, bootAssets(vipBackend()), '/assets/memberships/vip/benefits/new', size: Size(size.width, 4000));
        await tapVisible(tester, find.text('高级'));
        await tapVisible(tester, find.byKey(const ValueKey('benefit-kind-choice')));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('删 N 选 1：说清楚连选项一起删，确认后带 cascade', (tester) async {
      final backend = vipBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/benefits/c1/edit', size: tall);
      await tester.tap(find.byKey(const ValueKey('benefit-delete')));
      await settle(tester);
      expect(find.text('它下面的 1 个选项会一起删掉。'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '删掉'));
      await settle(tester);
      expect(backend.requests('DELETE', '/benefits/c1').single.url.queryParameters, {'cascade': '1'});
      expect(backend.perks.benefits, isEmpty);
    });
  });
}
