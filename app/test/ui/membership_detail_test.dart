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

/// 88VIP（本期 3/1 ~ 明年 2/28，¥88/年）：优酷年卡（面值 ¥248）9/20 领了；购物券（每月 4 张，没估值）9/21 领了一张；
/// 「年卡二选一」的选项芒果年卡面值 ¥198。
AssetsBackend paybackBackend() => AssetsBackend(
  perks: PerksFake(
    platforms: [platformJson('tb', name: '淘宝'), platformJson('yk', name: '优酷', sort: 1)],
    memberships: [membershipJson('vip', feeCents: 8800, termStartOn: '2026-03-01', expiresOn: '2027-02-28')],
    benefits: [
      benefitJson('b1', name: '优酷年卡', kind: 'subscription', claimPlatformId: 'yk', faceValueCents: 24800, quota: [
        {'p': 'term', 'n': 1},
      ]),
      benefitJson('b2', name: '购物券', kind: 'coupon', quota: [
        {'p': 'month', 'n': 4},
      ], sort: 1),
      benefitJson('c1', name: '年卡二选一', kind: 'choice', quota: [
        {'p': 'year', 'n': 1},
      ], sort: 2),
      benefitJson('o1', parentId: 'c1', name: '芒果年卡', faceValueCents: 19800, sort: 3),
    ],
    events: [eventJson('e1', 'b1', occurredOn: '2026-09-20'), eventJson('e2', 'b2', occurredOn: '2026-09-21')],
  ),
);

void main() {
  group('会员详情：回本、本期进度、打卡记录、续了', () {
    testWidgets('本期回本：已回本 · 时间进度、还能再享（N 选 1 取最贵的）、含面值估算、N 项未估值；每项权益一行本期进度', (tester) async {
      await pumpAssetsAt(tester, bootAssets(paybackBackend()), '/assets/memberships/vip', size: tall);
      expect(find.text('本期回本'), findsOneWidget);
      expect(find.text('已回本 282% · ¥248.00 / ¥88.00'), findsOneWidget);
      expect(find.text('时间已过 57%'), findsOneWidget);
      expect(find.text('¥396.00'), findsOneWidget, reason: '二选一今年、明年 1 月各挑一次芒果年卡；购物券没估值不算');
      expect(find.text('含面值估算'), findsOneWidget);
      expect(find.text('1 项未估值'), findsOneWidget, reason: '购物券打过卡但没填价值');
      expect(find.byKey(const ValueKey('benefit-status-b1')), findsOneWidget);
      expect(find.text('本期 1/1 · 本期用完'), findsOneWidget);
      expect(find.text('本月 1/4 · 还剩 7 天'), findsOneWidget);
      expect(find.text('本年 0/1 · 还剩 99 天'), findsOneWidget);
    });

    testWidgets('打卡记录：新的在前，写日期、领了/用了、价值；删一条回本跟着变，snackbar 撤销照原样再记一条', (tester) async {
      final backend = paybackBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/vip', size: tall);
      expect(find.text('打卡记录 · 2 条'), findsOneWidget);
      expect(find.text('9月21日 · 领了'), findsOneWidget, reason: '没估值的不写价值');
      expect(find.text('9月20日 · 领了 · ¥248.00'), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('event-e2'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const ValueKey('event-e1'))).dy),
        reason: '新的在前',
      );

      await tapVisible(tester, find.byKey(const ValueKey('event-delete-e1')));
      expect(backend.requests('DELETE', '/benefit-events/e1'), hasLength(1));
      expect(find.text('已删掉这条打卡'), findsOneWidget);
      expect(find.text('已回本 0% · ¥0.00 / ¥88.00'), findsOneWidget);

      await tester.tap(find.text('撤销'));
      await settle(tester);
      final body = backend.lastBody('POST', '/benefit-events');
      expect((body['benefitId'], body['kind'], body['count'], body['occurredOn']), ('b1', 'claim', 1, '2026-09-20'));
      expect(find.text('已回本 282% · ¥248.00 / ¥88.00'), findsOneWidget);
    });

    testWidgets('打卡记录超过 10 条先收着，点「再看 N 条」全部列出', (tester) async {
      final backend = paybackBackend();
      for (var i = 1; i <= 12; i++) {
        backend.perks.events['m$i'] = eventJson('m$i', 'b2', occurredOn: '2026-08-${i.toString().padLeft(2, '0')}');
      }
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/vip', size: const Size(400, 4000));
      expect(find.text('打卡记录 · 14 条'), findsOneWidget);
      expect(find.byKey(const ValueKey('event-m1')), findsNothing, reason: '最早的那几条先收着');
      await tapVisible(tester, find.byKey(const ValueKey('history-more')));
      expect(find.byKey(const ValueKey('event-m1')), findsOneWidget);
    });

    testWidgets('「续了一期」（到期前就点）：POST renew，到期日跟着变；还在跑的这一期照旧 —— 回本、进度、时间都不变，存的那期写成「下一期」；一次性的卡没有这个按钮', (tester) async {
      final backend = paybackBackend();
      backend.perks.memberships['course'] = membershipJson('course', name: '网课', feePeriod: 'once', expiresOn: '2026-12-31', sort: 1);
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/vip', size: tall);
      await tapVisible(tester, find.byKey(const ValueKey('membership-renew')));
      expect(backend.requests('POST', '/memberships/vip/renew'), hasLength(1));
      expect(find.text('已续到 2028-02-28：88VIP'), findsOneWidget);
      expect(find.text('还有 523 天到期'), findsOneWidget);
      expect(backend.perks.memberships['vip']!['termStartOn'], '2027-03-01', reason: '服务端把本期开始挪到原到期日次日');
      expect(find.text('已回本 282% · ¥248.00 / ¥88.00'), findsOneWidget, reason: '回本没清零');
      expect(find.text('时间已过 57%'), findsOneWidget);
      expect(find.text('本期 1/1 · 本期用完'), findsOneWidget);
      expect(find.text('本月 1/4 · 还剩 7 天'), findsOneWidget, reason: '没变成「未生效」');
      expect(find.text('2026-03-01 至 2027-02-28'), findsOneWidget, reason: '本期写还在跑的这一期');
      expect(find.text('2027-03-01 至 2028-02-28'), findsOneWidget, reason: '下一期');
      expect(find.byKey(const ValueKey('membership-renew')), findsNothing, reason: '下一期已经续上了，不再给「续了一期」');

      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/course', size: tall);
      expect(find.byKey(const ValueKey('membership-renew')), findsNothing);
    });

    testWidgets('按会员本期起算的权益、卡却没填本期开始：说一句先按自然周期算，「去补」到编辑页', (tester) async {
      final backend = AssetsBackend(
        perks: PerksFake(
          platforms: [platformJson('tb', name: '淘宝')],
          memberships: [membershipJson('vip', expiresOn: '2027-02-28')],
          benefits: [
            benefitJson('b1', name: '贵宾厅', anchor: 'term', quota: [
              {'p': 'month', 'n': 1},
            ]),
          ],
        ),
      );
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/vip', size: tall);
      expect(find.text('有权益按会员本期起算，这张卡没填本期开始，先按自然周期算'), findsOneWidget);
      await tapVisible(tester, find.byKey(const ValueKey('anchor-fallback-fix')));
      expect(find.text('编辑会员卡'), findsOneWidget);
    });

    testWidgets('先领再用的打卡记录：「领了」不写价值（回本不算它），「用了」才写', (tester) async {
      final backend = AssetsBackend(
        perks: PerksFake(
          platforms: [platformJson('tb', name: '淘宝')],
          memberships: [membershipJson('vip', feeCents: 8800, termStartOn: '2026-03-01', expiresOn: '2027-02-28')],
          benefits: [
            benefitJson('r1', name: '红包', flow: 'claim_use', faceValueCents: 500, quota: [
              {'p': 'month', 'n': 4},
            ]),
          ],
          events: [eventJson('e1', 'r1', occurredOn: '2026-09-20'), eventJson('e2', 'r1', kind: 'use', occurredOn: '2026-09-21')],
        ),
      );
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/vip', size: tall);
      expect(find.text('9月20日 · 领了'), findsOneWidget);
      expect(find.text('9月21日 · 用了 · ¥5.00'), findsOneWidget);
      expect(find.text('已回本 6% · ¥5.00 / ¥88.00'), findsOneWidget, reason: '和记录上的价值加起来对得上');
    });

    testWidgets('没填本期开始的卡：本期按到期日往前推一期算，说一句、「去补」', (tester) async {
      final backend = AssetsBackend(
        perks: PerksFake(
          platforms: [platformJson('tb', name: '淘宝')],
          memberships: [membershipJson('vip', feeCents: 8800, expiresOn: '2027-02-28')],
          benefits: [
            benefitJson('b1', name: '年卡', kind: 'subscription', faceValueCents: 24800, quota: [
              {'p': 'term', 'n': 1},
            ]),
          ],
          events: [eventJson('e1', 'b1', occurredOn: '2025-03-10')],
        ),
      );
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/vip', size: tall);
      expect(find.text('这张卡没填本期开始，本期先按到期日往前推一期算'), findsOneWidget);
      expect(find.text('本期 0/1 · 还剩 158 天'), findsOneWidget, reason: '去年那次不算这一期');
      expect(find.text('已回本 0% · ¥0.00 / ¥88.00'), findsOneWidget);
      expect(find.byKey(const ValueKey('anchor-fallback-fix')), findsOneWidget);
    });

    for (final size in kWidths) {
      testWidgets('${size.width.toInt()} 宽：回本、进度、打卡记录都不溢出', (tester) async {
        await pumpAssetsAt(tester, bootAssets(paybackBackend()), '/assets/memberships/vip', size: Size(size.width, 2400));
        expect(tester.takeException(), isNull);
      });
    }
  });

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
