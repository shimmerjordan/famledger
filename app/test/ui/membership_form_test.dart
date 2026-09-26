import 'package:famledger/ui/perks/membership_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assets_harness.dart';
import 'perks_fake.dart';

const Size tall = Size(400, 2600);

AssetsBackend withPlatforms({List<Map<String, dynamic>> memberships = const [], List<Map<String, dynamic>> benefits = const []}) =>
    AssetsBackend(
      perks: PerksFake(
        platforms: [platformJson('tb', name: '淘宝'), platformJson('yk', name: 'Youku 优酷', aliases: ['合一'], sort: 1)],
        memberships: memberships,
        benefits: benefits,
      ),
      members: const [
        {'id': 'u1', 'username': 'mama', 'displayName': '妈妈', 'role': 'admin'},
      ],
    );

/// 表单「平台」按钮上写的字（OutlinedButton.icon 是私有子类，widgetWithText 按类型找不到它）。
Finder onPlatformButton(String text) =>
    find.descendant(of: find.byKey(const ValueKey('membership-platform')), matching: find.text(text));

Future<void> pickPlatform(WidgetTester tester, String query, {String? tapKey}) async {
  await tapVisible(tester, find.byKey(const ValueKey('membership-platform')));
  await tester.enterText(find.byKey(const ValueKey('platform-search')), query);
  await tester.pump();
  await tester.tap(find.byKey(ValueKey(tapKey ?? 'platform-create')));
  await settle(tester);
}

void main() {
  group('会员表单', () {
    testWidgets('只填平台和名称就能存：请求体干净，带 clientId；存完到详情', (tester) async {
      final backend = withPlatforms();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/new', size: tall);

      await tapVisible(tester, find.byKey(const ValueKey('membership-platform')));
      await tester.tap(find.byKey(const ValueKey('platform-pick-tb')));
      await settle(tester);
      expect(onPlatformButton('淘宝'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('membership-name')), ' 88VIP ');
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));

      final body = backend.lastBody('POST', '/memberships');
      expect(body.keys.toSet(), {'platformId', 'name', 'clientId'});
      expect(body['platformId'], 'tb');
      expect(body['name'], '88VIP');
      expect(find.byType(MembershipDetailPage), findsOneWidget, reason: '建完直接到详情，下一步是加权益');
      expect(find.text('记好了，接着加权益吧'), findsOneWidget);
    });

    testWidgets('打卡后建子会员的入口：预填平台、来源权益、本期实付 0，存的请求体带上它们', (tester) async {
      final backend = withPlatforms(
        memberships: [membershipJson('vip')],
        benefits: [benefitJson('b1', name: '优酷年卡', kind: 'subscription', claimPlatformId: 'yk')],
      );
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/new?platformId=yk&sourceBenefitId=b1&termPaid=0', size: tall);
      expect(onPlatformButton('Youku 优酷'), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(const ValueKey('membership-paid'))).controller!.text, '0.00');
      expect(find.text('88VIP · 优酷年卡'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('membership-name')), '优酷VIP');
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      final body = backend.lastBody('POST', '/memberships');
      expect((body['platformId'], body['sourceBenefitId'], body['termPaidCents']), ('yk', 'b1', 0));
      expect(body.containsKey('recordTransaction'), isFalse, reason: '实付 0 不给「同时记一笔」');
    });

    testWidgets('没选平台、没写名字：行内说清楚，不发请求', (tester) async {
      final backend = withPlatforms();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/new', size: tall);
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      expect(find.text('先选一个平台（没有就新建一个）'), findsOneWidget);
      await tapVisible(tester, find.byKey(const ValueKey('membership-platform')));
      await tester.tap(find.byKey(const ValueKey('platform-pick-tb')));
      await settle(tester);
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      expect(find.text('给这张卡起个名字，例如「88VIP」'), findsOneWidget);
      expect(backend.requests('POST', '/memberships'), isEmpty);
    });

    testWidgets('平台选择：搜名字和别名；全角/大小写/空格同名时不给「新建」，直接列出已有的', (tester) async {
      await pumpAssetsAt(tester, bootAssets(withPlatforms()), '/assets/memberships/new', size: tall);
      await tapVisible(tester, find.byKey(const ValueKey('membership-platform')));

      await tester.enterText(find.byKey(const ValueKey('platform-search')), '合');
      await tester.pump();
      expect(find.byKey(const ValueKey('platform-pick-yk')), findsOneWidget, reason: '别名也搜得到');
      expect(find.byKey(const ValueKey('platform-pick-tb')), findsNothing);

      await tester.enterText(find.byKey(const ValueKey('platform-search')), 'ＹＯＵＫＵ 优酷');
      await tester.pump();
      expect(find.byKey(const ValueKey('platform-create')), findsNothing, reason: '规范化后同名，不该再建一个');
      expect(find.byKey(const ValueKey('platform-pick-yk')), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('platform-search')), '京东');
      await tester.pump();
      expect(find.text('新建「京东」'), findsOneWidget);
    });

    testWidgets('就地新建平台；撞上别的设备刚建的同名平台（409 name_taken）就直接用那一个', (tester) async {
      final backend = withPlatforms();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/new', size: tall);

      await pickPlatform(tester, '京东');
      expect(backend.lastBody('POST', '/platforms'), {'name': '京东'});
      expect(onPlatformButton('京东'), findsOneWidget);

      // 别的设备刚建了「爱奇艺」，这台还没同步到：本地搜不到，点「新建」撞上 409，改用已有的那个。
      backend.perks.platforms['iq'] = platformJson('iq', name: '爱奇艺', sort: 5);
      await pickPlatform(tester, '爱奇艺 ');
      expect(find.text('已有「爱奇艺」，直接用它了'), findsOneWidget);
      expect(onPlatformButton('爱奇艺'), findsOneWidget, reason: '同步过来了，写得出名字');
      await tester.enterText(find.byKey(const ValueKey('membership-name')), '黄金VIP');
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      expect(backend.lastBody('POST', '/memberships')['platformId'], 'iq');
    });

    testWidgets('「更多」：档位、类型、持有人、续费价、本期、续费、试用、提醒、备注都带上；到期日能选将来', (tester) async {
      final backend = withPlatforms();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/new?platformId=tb', size: tall);
      expect(onPlatformButton('淘宝'), findsOneWidget, reason: '从 query 预填平台');
      await tester.enterText(find.byKey(const ValueKey('membership-name')), '88VIP');

      // 到期日：日历的上限是 2100 年，不是今天；翻到下个月挑 28 号。
      await tapVisible(tester, find.byKey(const ValueKey('membership-expires')));
      final picker = find.byType(DatePickerDialog);
      expect(tester.widget<DatePickerDialog>(picker).lastDate, DateTime(2100, 12, 31));
      await tester.tap(find.byTooltip('Next month'));
      await settle(tester);
      await tester.tap(find.descendant(of: picker, matching: find.text('28')));
      await tester.pump();
      await tester.tap(find.text('OK'));
      await settle(tester);
      expect(find.text('2026-10-28'), findsOneWidget);

      await tapVisible(tester, find.text('更多'));
      await tester.enterText(find.byKey(const ValueKey('membership-tier')), '年卡');
      await tapVisible(tester, find.byKey(const ValueKey('membership-kind-subscription')));
      await tapVisible(tester, find.byKey(const ValueKey('membership-holder-u1')));
      await tester.enterText(find.byKey(const ValueKey('membership-fee')), '88');
      await tapVisible(tester, find.byKey(const ValueKey('membership-period-month')));
      await tester.enterText(find.byKey(const ValueKey('membership-paid')), '0');
      await tapVisible(tester, find.byKey(const ValueKey('membership-start')));
      await tester.tap(find.descendant(of: find.byType(DatePickerDialog), matching: find.text('1')));
      await tester.pump();
      await tester.tap(find.text('OK'));
      await settle(tester);
      await tapVisible(tester, find.byKey(const ValueKey('membership-renew-yes')));
      await tapVisible(tester, find.byKey(const ValueKey('membership-trial')));
      await tester.enterText(find.byKey(const ValueKey('membership-remind')), '0');
      await tester.enterText(find.byKey(const ValueKey('membership-note')), '妈妈的号');
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));

      final body = backend.lastBody('POST', '/memberships');
      expect(body, {
        'platformId': 'tb',
        'name': '88VIP',
        'clientId': body['clientId'],
        'tier': '年卡',
        'kind': 'subscription',
        'memberId': 'u1',
        'feeCents': 8800,
        'feePeriod': 'month',
        'termPaidCents': 0,
        'termStartOn': '2026-09-01',
        'expiresOn': '2026-10-28',
        'autoRenew': 'yes',
        'isTrial': true,
        'remindDays': 0,
        'note': '妈妈的号',
      });
      expect(body.containsKey('recordTransaction'), isFalse, reason: '实付 0：不给「同时记一笔」');
    });

    testWidgets('填错的：续费价、提醒天数、到期早于开始 —— 行内说清楚，不发请求', (tester) async {
      final backend = withPlatforms();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/new?platformId=tb', size: tall);
      await tester.enterText(find.byKey(const ValueKey('membership-name')), '88VIP');
      await tapVisible(tester, find.text('更多'));

      await tester.enterText(find.byKey(const ValueKey('membership-fee')), 'abc');
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      expect(find.text('续费价填得不对，例如 88'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('membership-fee')), '88');

      await tester.enterText(find.byKey(const ValueKey('membership-remind')), '400');
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      expect(find.text('到期提醒填 0 到 365 天，0 = 不提醒'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('membership-remind')), '');

      // 本期开始 9/23（今天），到期挑 9/1：早于开始。
      await tapVisible(tester, find.byKey(const ValueKey('membership-start')));
      await tester.tap(find.text('OK'));
      await settle(tester);
      await tapVisible(tester, find.byKey(const ValueKey('membership-expires')));
      await tester.tap(find.descendant(of: find.byType(DatePickerDialog), matching: find.text('1')));
      await tester.pump();
      await tester.tap(find.text('OK'));
      await settle(tester);
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      expect(find.text('到期日不能早于本期开始'), findsOneWidget);
      expect(backend.requests('POST', '/memberships'), isEmpty);
    });

    testWidgets('同时记一笔支出：默认不勾；勾上后带 recordTransaction（按本期实付，没填按续费价）', (tester) async {
      final backend = withPlatforms();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/new?platformId=tb', size: tall);
      await tester.enterText(find.byKey(const ValueKey('membership-name')), '88VIP');
      expect(find.byKey(const ValueKey('membership-record')), findsNothing, reason: '没有金额就不出这个开关');
      await tapVisible(tester, find.text('更多'));
      await tester.enterText(find.byKey(const ValueKey('membership-fee')), '88');
      await tester.pump();
      final record = find.byKey(const ValueKey('membership-record'));
      expect(tester.widget<SwitchListTile>(record).value, isFalse);
      expect(find.text('记 ¥88.00，记在今天（没填本期开始）'), findsOneWidget);
      await tapVisible(tester, record);
      await tapVisible(tester, find.byKey(const ValueKey('account-bank')));
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));

      final body = backend.lastBody('POST', '/memberships');
      expect(body['recordTransaction'], {'accountId': 'bank', 'fundId': 'f1'});
      expect(find.text('记好了，也记了一笔支出'), findsOneWidget);
    });

    testWidgets('同时记一笔支出记在哪天：本期开始在过去 → 那天；在将来（预约开通）→ 今天，和服务端一样', (tester) async {
      final backend = withPlatforms();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/new?platformId=tb', size: tall);
      await tester.enterText(find.byKey(const ValueKey('membership-name')), '88VIP');
      await tapVisible(tester, find.text('更多'));
      await tester.enterText(find.byKey(const ValueKey('membership-fee')), '88');
      await tester.pump();

      await tapVisible(tester, find.byKey(const ValueKey('membership-start')));
      await tester.tap(find.descendant(of: find.byType(DatePickerDialog), matching: find.text('1')));
      await tester.pump();
      await tester.tap(find.text('OK'));
      await settle(tester);
      expect(find.text('记 ¥88.00，记在本期开始那天（2026-09-01）'), findsOneWidget);

      await tapVisible(tester, find.byKey(const ValueKey('membership-start')));
      await tester.tap(find.byTooltip('Next month'));
      await settle(tester);
      await tester.tap(find.descendant(of: find.byType(DatePickerDialog), matching: find.text('5')));
      await tester.pump();
      await tester.tap(find.text('OK'));
      await settle(tester);
      expect(find.text('记 ¥88.00，记在今天（本期还没开始）'), findsOneWidget);
    });

    testWidgets('宽屏（≥ 840）：从会员权益 tab 新建，存完回到 tab、右栏选中新卡，不盖整页详情', (tester) async {
      final backend = withPlatforms(memberships: [membershipJson('vip')]);
      await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=perks', size: const Size(1400, 2000));
      await tester.tap(find.byTooltip('记一张会员卡'));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('perks-add-manual')));
      await settle(tester);
      await tapVisible(tester, find.byKey(const ValueKey('membership-platform')));
      await tester.tap(find.byKey(const ValueKey('platform-pick-yk')));
      await settle(tester);
      await tester.enterText(find.byKey(const ValueKey('membership-name')), '优酷VIP');
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      final id = backend.perks.memberships.keys.firstWhere((k) => k != 'vip');
      expect(find.byKey(ValueKey('perks-side-$id')), findsOneWidget);
      expect(find.byType(MembershipDetailPage), findsNothing);
      expect(find.text('记好了，接着加权益吧'), findsOneWidget);
    });

    for (final size in kWidths) {
      testWidgets('${size.width.toInt()} 宽：展开「更多」、勾上「同时记一笔」、打开平台选择都不溢出', (tester) async {
        await pumpAssetsAt(tester, bootAssets(withPlatforms()), '/assets/memberships/new?platformId=tb', size: Size(size.width, 3000));
        await tapVisible(tester, find.text('更多'));
        await tester.enterText(find.byKey(const ValueKey('membership-fee')), '88');
        await tapVisible(tester, find.byKey(const ValueKey('membership-kind-credit_card')));
        await tapVisible(tester, find.byKey(const ValueKey('membership-record')));
        expect(tester.takeException(), isNull);
        await tapVisible(tester, find.byKey(const ValueKey('membership-platform')));
        expect(find.byKey(const ValueKey('platform-search')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('${size.width.toInt()} 宽、字号 1.5 倍：会员表单的小标题和说明不撑破', (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = 1.5;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await pumpAssetsAt(tester, bootAssets(withPlatforms()), '/assets/memberships/new?platformId=tb', size: Size(size.width, 5000));
        await tapVisible(tester, find.text('更多'));
        expect(find.text('比如 88VIP 送的优酷会员'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('编辑：带出原值，「更多」直接展开；清掉到期日发 null；来源权益可以选别的卡的权益', (tester) async {
      final backend = withPlatforms(
        memberships: [
          membershipJson('vip', feeCents: 8800, expiresOn: '2027-02-28'),
          membershipJson('ykvip', platformId: 'yk', name: '优酷VIP', tier: '酷喵', sort: 1),
        ],
        benefits: [benefitJson('b1', name: '优酷年卡', claimPlatformId: 'yk')],
      );
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/ykvip/edit', size: tall);
      expect(find.text('编辑会员卡'), findsOneWidget);
      expect(find.widgetWithText(TextField, '酷喵'), findsOneWidget, reason: '档位填过，「更多」直接展开');

      await tapVisible(tester, find.byKey(const ValueKey('membership-source')));
      await tester.tap(find.text('88VIP · 优酷年卡').last);
      await settle(tester);
      await tapVisible(tester, find.widgetWithText(FilledButton, '保存'));

      final body = backend.lastBody('PATCH', '/memberships/ykvip');
      expect(body['sourceBenefitId'], 'b1');
      expect(body['expiresOn'], isNull);
      expect(body['tier'], '酷喵');
      expect(body['accountId'], isNull, reason: '不是信用卡就不挂账户');
      expect(body.keys, containsAll(['platformId', 'name', 'kind', 'memberId', 'feeCents', 'termPaidCents', 'note']));
    });
  });
}
