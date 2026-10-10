import 'package:famledger/ui/perks/benefit_drafts.dart';
import 'package:famledger/ui/perks/benefit_form_page.dart';
import 'package:famledger/ui/perks/membership_detail_page.dart';
import 'package:famledger/ui/perks/membership_form_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assets_harness.dart';
import 'perks_fake.dart';

/// 新建时顺带子项，一步建好：会员卡带权益（「N 选 1」再带选项）、「N 选 1」带选项、债务带已收回的、理财带已领的分红 / 利息。

const Size tall = Size(400, 3000);

AssetsBackend withPlatforms({List<Map<String, dynamic>> memberships = const []}) => AssetsBackend(
  perks: PerksFake(
    platforms: [platformJson('tb', name: '淘宝'), platformJson('yk', name: '优酷', sort: 1)],
    memberships: memberships,
  ),
);

Future<void> pickPlatform(WidgetTester tester, String buttonKey, String pickKey) async {
  await tapVisible(tester, find.byKey(ValueKey(buttonKey)));
  await tester.tap(find.byKey(ValueKey(pickKey)));
  await settle(tester);
}

/// 在草稿表单里写名字、挑类型（和额度预设）后点「加好了」。
Future<void> fillDraft(WidgetTester tester, {required String name, String? kind, String? preset, String? count}) async {
  expect(find.byType(BenefitFormPage), findsOneWidget);
  await tester.enterText(find.byKey(const ValueKey('benefit-name')), name);
  if (kind != null) await tapVisible(tester, find.byKey(ValueKey('benefit-kind-$kind')));
  if (preset != null) await tapVisible(tester, find.byKey(ValueKey('quota-preset-$preset')));
  if (count != null) await tester.enterText(find.byKey(const ValueKey('quota-count')), count);
}

Future<void> quickOption(WidgetTester tester, String name, {bool viaButton = false}) async {
  await tester.ensureVisible(find.byKey(const ValueKey('benefit-option-quick')));
  await tester.enterText(find.byKey(const ValueKey('benefit-option-quick')), name);
  if (viaButton) {
    await tapVisible(tester, find.byKey(const ValueKey('benefit-option-quick-add')));
  } else {
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
  }
}

Finder rowText(String key, String text) => find.descendant(of: find.byKey(ValueKey(key)), matching: find.text(text));

void main() {
  group('建卡时一起加权益', () {
    testWidgets('加两项（一项「N 选 1」带两个选项）、改一项、去掉一项；一次存好，请求带上 benefits，到详情就看得到', (tester) async {
      final backend = withPlatforms();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/new', size: tall);
      await pickPlatform(tester, 'membership-platform', 'platform-pick-tb');
      await tester.enterText(find.byKey(const ValueKey('membership-name')), '88VIP');

      // 第一项：每月 4 张券。草稿表单的抬头是外面填的卡名。
      await tapVisible(tester, find.byKey(const ValueKey('membership-benefit-add')));
      expect(find.text('加一项权益'), findsWidgets);
      expect(find.text('88VIP'), findsOneWidget, reason: '抬头写卡名');
      expect(
        find.descendant(of: find.byKey(const ValueKey('benefit-claim-platform')), matching: find.text('会员本平台（淘宝）')),
        findsOneWidget,
        reason: '在哪领默认跟外面选的平台',
      );
      await fillDraft(tester, name: '每月 4 张红包', kind: 'coupon', preset: 'monthly', count: '4');
      await tapVisible(tester, find.widgetWithText(FilledButton, '加好了'));
      expect(find.byType(MembershipFormPage), findsOneWidget, reason: '回到卡的表单，没连服务端');
      expect(backend.requests('POST', '/benefits'), isEmpty);
      expect(rowText('membership-benefit-0', '每月 4 张红包'), findsOneWidget);
      expect(rowText('membership-benefit-0', '券 · 每月 4 次'), findsOneWidget);

      // 第二项：年卡二选一，选项打名字就加；点开一个补在哪领。
      await tapVisible(tester, find.byKey(const ValueKey('membership-benefit-add')));
      await fillDraft(tester, name: '年卡二选一', kind: 'choice', preset: 'yearly', count: '1');
      expect(find.byKey(const ValueKey('benefit-options')), findsOneWidget, reason: '新建「N 选 1」时选项就在表单里');
      await quickOption(tester, '优酷年卡');
      await quickOption(tester, '芒果年卡', viaButton: true);
      await quickOption(tester, '  ');
      expect(find.byKey(const ValueKey('benefit-option-2')), findsNothing, reason: '空名字不加');
      expect(rowText('benefit-option-0', '优酷年卡'), findsOneWidget);
      expect(rowText('benefit-option-1', '芒果年卡'), findsOneWidget);

      await tapVisible(tester, find.byKey(const ValueKey('benefit-option-0')));
      expect(find.text('改这个选项'), findsWidgets);
      expect(find.text('88VIP ·「年卡二选一」的一个选项：额度和算法跟着它'), findsOneWidget);
      expect(find.byKey(const ValueKey('quota-preset-monthly')), findsNothing, reason: '选项不设额度');
      await pickPlatform(tester, 'benefit-claim-platform', 'platform-pick-yk');
      await tapVisible(tester, find.widgetWithText(FilledButton, '改好了'));
      expect(rowText('benefit-option-0', '在优酷领'), findsOneWidget);
      await tapVisible(tester, find.widgetWithText(FilledButton, '加好了'));
      expect(rowText('membership-benefit-1', 'N 选 1 · 每年 1 次 · 2 个选项'), findsOneWidget);

      // 第三项加了又去掉；第一项点开改名。
      await tapVisible(tester, find.byKey(const ValueKey('membership-benefit-add')));
      await fillDraft(tester, name: '要去掉的');
      await tapVisible(tester, find.widgetWithText(FilledButton, '加好了'));
      await tapVisible(tester, find.byKey(const ValueKey('membership-benefit-remove-2')));
      expect(find.text('要去掉的'), findsNothing);
      await tapVisible(tester, find.byKey(const ValueKey('membership-benefit-0')));
      expect(find.text('改这项权益'), findsWidgets);
      expect(find.widgetWithText(TextField, '每月 4 张红包'), findsOneWidget, reason: '回填草稿');
      await tester.enterText(find.byKey(const ValueKey('benefit-name')), '每月 4 张天猫红包');
      await tapVisible(tester, find.widgetWithText(FilledButton, '改好了'));
      expect(rowText('membership-benefit-0', '每月 4 张天猫红包'), findsOneWidget);
      expect(rowText('membership-benefit-0', '券 · 每月 4 次'), findsOneWidget, reason: '额度没丢');

      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      final body = backend.lastBody('POST', '/memberships');
      expect(body['name'], '88VIP');
      final benefits = (body['benefits'] as List).cast<Map<String, dynamic>>();
      expect(benefits, hasLength(2));
      expect(benefits[0], {
        'name': '每月 4 张天猫红包',
        'kind': 'coupon',
        'flow': 'claim',
        'quota': [
          {'p': 'month', 'n': 4},
        ],
        'anchor': 'calendar',
        'remind': true,
      });
      expect(benefits[1]['kind'], 'choice');
      expect(benefits[1]['quota'], [
        {'p': 'year', 'n': 1},
      ]);
      final options = (benefits[1]['options'] as List).cast<Map<String, dynamic>>();
      expect(options.map((o) => o['name']), ['优酷年卡', '芒果年卡']);
      expect(options[0]['claimPlatformId'], 'yk');
      expect(options[0].containsKey('quota'), isFalse, reason: '选项不带额度和算法');
      expect(options[1], {'name': '芒果年卡', 'kind': 'other'});
      expect(backend.requests('POST', '/benefits'), isEmpty, reason: '一个请求建好，不再一项项发');

      expect(find.byType(MembershipDetailPage), findsOneWidget);
      expect(find.text('记好了，带上 2 项权益'), findsOneWidget);
      expect(find.text('每月 4 张天猫红包'), findsOneWidget, reason: '回应里的权益先落本地');
      expect(find.text('年卡二选一'), findsOneWidget);
      expect(find.text('芒果年卡'), findsOneWidget);
    });

    testWidgets('草稿表单点返回 = 不加；填错照样行内拦下', (tester) async {
      final backend = withPlatforms();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/new', size: tall);
      await tapVisible(tester, find.byKey(const ValueKey('membership-benefit-add')));
      expect(find.text('这张卡'), findsOneWidget, reason: '卡名还没填');
      expect(
        find.descendant(of: find.byKey(const ValueKey('benefit-claim-platform')), matching: find.text('会员本平台')),
        findsOneWidget,
        reason: '平台还没选',
      );
      await tapVisible(tester, find.widgetWithText(FilledButton, '加好了'));
      expect(find.text('给这项权益起个名字，例如「优酷年卡」'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('benefit-name')), '不要了');
      await tester.tap(find.byType(BackButton));
      await settle(tester);
      expect(find.byType(MembershipFormPage), findsOneWidget);
      expect(find.byKey(const ValueKey('membership-benefit-0')), findsNothing);
    });

    testWidgets('「N 选 1」换成别的类型：说清填的选项不会存；换回来还在', (tester) async {
      final backend = withPlatforms();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/new', size: tall);
      await tapVisible(tester, find.byKey(const ValueKey('membership-benefit-add')));
      await fillDraft(tester, name: '二选一', kind: 'choice');
      await quickOption(tester, '优酷');
      await tapVisible(tester, find.byKey(const ValueKey('benefit-kind-coupon')));
      expect(find.byKey(const ValueKey('benefit-options')), findsNothing);
      expect(find.text('换成了别的类型：刚才加的 1 个选项不会存，换回「N 选 1」还在。'), findsOneWidget);
      await tapVisible(tester, find.byKey(const ValueKey('benefit-kind-choice')));
      expect(rowText('benefit-option-0', '优酷'), findsOneWidget);
      await tapVisible(tester, find.byKey(const ValueKey('benefit-kind-coupon')));
      await tapVisible(tester, find.widgetWithText(FilledButton, '加好了'));
      expect(rowText('membership-benefit-0', '券 · 不限次'), findsOneWidget);
    });

    testWidgets('有没存的权益时点返回：先问一句；接着改就留下，不要了才走', (tester) async {
      final backend = withPlatforms();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/new', size: tall);
      expect(find.byType(MembershipFormPage), findsOneWidget);
      await tapVisible(tester, find.byKey(const ValueKey('membership-benefit-add')));
      await fillDraft(tester, name: '贵宾厅');
      await tapVisible(tester, find.widgetWithText(FilledButton, '加好了'));

      await tester.tap(find.byType(BackButton));
      await settle(tester);
      expect(find.text('权益还没存'), findsOneWidget);
      expect(find.text('退出去，刚加的 1 项权益就没了。'), findsOneWidget);
      await tester.tap(find.text('接着改'));
      await settle(tester);
      expect(find.byType(MembershipFormPage), findsOneWidget);
      expect(rowText('membership-benefit-0', '贵宾厅'), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await settle(tester);
      await tester.tap(find.text('不要了'));
      await settle(tester);
      expect(find.byType(MembershipFormPage), findsNothing);
    });

    testWidgets('改草稿的按钮叫「改好了」；名字超过 60 个字当场拦下', (tester) async {
      final backend = withPlatforms();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/new', size: tall);
      await tapVisible(tester, find.byKey(const ValueKey('membership-benefit-add')));
      await fillDraft(tester, name: '长' * 61);
      await tapVisible(tester, find.widgetWithText(FilledButton, '加好了'));
      expect(find.text('名称最多 60 个字'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('benefit-name')), '贵宾厅');
      await tapVisible(tester, find.widgetWithText(FilledButton, '加好了'));
      await tapVisible(tester, find.byKey(const ValueKey('membership-benefit-0')));
      expect(find.widgetWithText(FilledButton, '改好了'), findsOneWidget);
      await tapVisible(tester, find.byKey(const ValueKey('benefit-kind-choice')));
      await quickOption(tester, '选' * 70);
      expect(find.text('选' * 60), findsOneWidget, reason: '打名字的框最多收 60 个字');
    });

    testWidgets('编辑已有的卡不出「权益」这一栏（在详情里加）', (tester) async {
      final backend = withPlatforms(memberships: [membershipJson('vip')]);
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/vip/edit', size: tall);
      expect(find.byKey(const ValueKey('membership-benefits')), findsNothing);
    });
  });

  group('建「N 选 1」时一起加选项', () {
    testWidgets('选项跟着 POST /benefits 一起发；回应里的选项落本地；编辑已有的「N 选 1」不出这一栏', (tester) async {
      final backend = withPlatforms(memberships: [membershipJson('vip')]);
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/vip/benefits/new', size: tall);
      await fillDraft(tester, name: '视频年卡三选一', kind: 'choice', preset: 'yearly', count: '1');
      expect(find.textContaining('能选的几样在下面「选项」里一起加'), findsOneWidget);
      await quickOption(tester, '优酷');
      await quickOption(tester, '芒果');
      await quickOption(tester, '腾讯视频');
      await tapVisible(tester, find.byKey(const ValueKey('benefit-option-remove-1')));
      await tapVisible(tester, find.widgetWithText(FilledButton, '加好了'));

      final body = backend.lastBody('POST', '/benefits');
      expect(body['kind'], 'choice');
      expect((body['options'] as List).map((o) => (o as Map)['name']), ['优酷', '腾讯视频']);
      expect(backend.requests('POST', '/benefits'), hasLength(1));
      expect(find.text('加好了，带 2 个选项'), findsOneWidget);
      final choice = backend.perks.benefits.values.firstWhere((b) => b['name'] == '视频年卡三选一');
      expect(backend.perks.benefits.values.where((b) => b['parentId'] == choice['id']), hasLength(2));

      await pumpAssetsAt(tester, bootAssets(backend), '/assets/benefits/${choice['id']}/edit', size: tall);
      expect(find.byKey(const ValueKey('benefit-options')), findsNothing);
      expect(find.text('N 选 1：选项在会员详情里加、改。'), findsOneWidget);
    });
  });

  group('债务：一起记已经收回 / 还掉的', () {
    testWidgets('借出 5000、已经收回 2000：请求带 settledCents，提示还剩多少；比金额多行内拦下', (tester) async {
      final backend = AssetsBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/debts/new', size: tall);
      expect(find.text('已经收回（选填）'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('debt-counterparty')), '张三');
      await tester.enterText(find.byKey(const ValueKey('debt-amount')), '5000');
      await tapVisible(tester, find.byKey(const ValueKey('debt-record')));
      expect(find.text('只调还剩多少，不记账'), findsOneWidget, reason: '关了「同时记一笔」');
      await tester.enterText(find.byKey(const ValueKey('debt-settled')), '6000');
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      expect(find.text('收回的不能比借出去的还多'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('debt-settled')), 'abc');
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      expect(find.text('「已经收回」填得不对，例如 2000'), findsOneWidget);
      expect(backend.requests('POST', '/debts'), isEmpty);

      await tester.enterText(find.byKey(const ValueKey('debt-settled')), '2000');
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      final body = backend.lastBody('POST', '/debts');
      expect(body['amountCents'], 500000);
      expect(body['settledCents'], 200000);
      expect(find.text('记好了，还剩 ¥3,000.00'), findsOneWidget);
    });

    testWidgets('开着「同时记一笔」：已经收回的也经同一个账户记，说清记了两笔；全收回了说已结清', (tester) async {
      final backend = AssetsBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/debts/new', size: tall);
      expect(find.text('也经选的账户记一笔'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('debt-counterparty')), '张三');
      await tester.enterText(find.byKey(const ValueKey('debt-amount')), '5000');
      await tester.enterText(find.byKey(const ValueKey('debt-settled')), '5000');
      await tapVisible(tester, find.byKey(const ValueKey('debt-account-bank')));
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      final body = backend.lastBody('POST', '/debts');
      expect(body['recordTransaction'], {'accountId': 'bank'});
      expect(body['settledCents'], 500000);
      expect(find.text('记好了，记了 ¥5,000.00 和 ¥5,000.00 两笔流水，已结清'), findsOneWidget);
    });

    testWidgets('借入叫「已经还了」；还多了说「还掉的不能比借来的还多」；不填就不带', (tester) async {
      final backend = AssetsBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/debts/new', size: tall);
      await tapVisible(tester, find.text('我欠别人'));
      expect(find.text('已经还了（选填）'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('debt-counterparty')), '李四');
      await tester.enterText(find.byKey(const ValueKey('debt-amount')), '3000');
      await tapVisible(tester, find.byKey(const ValueKey('debt-record')));
      await tester.enterText(find.byKey(const ValueKey('debt-settled')), '3000.01');
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      expect(find.text('还掉的不能比借来的还多'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('debt-settled')), '');
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      expect(backend.lastBody('POST', '/debts').containsKey('settledCents'), isFalse);
    });
  });

  group('理财：一起记已领的分红 / 利息', () {
    testWidgets('定期叫「已领利息」、基金叫「已领分红」；活期、黄金没有这一栏', (tester) async {
      final backend = AssetsBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/holdings/new', size: tall);
      await tapVisible(tester, find.byKey(const ValueKey('holding-kind-fixed')));
      expect(find.text('已领利息（选填）'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('holding-name')), '大额存单');
      await tester.enterText(find.byKey(const ValueKey('holding-cost')), '100000');
      await tester.enterText(find.byKey(const ValueKey('holding-rate')), '2.6');
      await tapVisible(tester, find.byKey(const ValueKey('holding-term-36')));
      await tapVisible(tester, find.byKey(const ValueKey('holding-record')));
      await tester.enterText(find.byKey(const ValueKey('holding-realized')), '-5');
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      expect(find.text('已领利息填得不对，例如 120'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('holding-realized')), '650');
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      expect(backend.lastBody('POST', '/holdings')['realizedCents'], 65000);

      await pumpAssetsAt(tester, bootAssets(backend), '/assets/holdings/new', size: tall);
      expect(find.text('已领分红（选填）'), findsOneWidget, reason: '默认是基金');
      await tapVisible(tester, find.byKey(const ValueKey('holding-kind-demand')));
      expect(find.byKey(const ValueKey('holding-realized')), findsNothing);
      await tapVisible(tester, find.byKey(const ValueKey('holding-kind-gold')));
      expect(find.byKey(const ValueKey('holding-realized')), findsNothing);
    });
  });

  group('三种宽度都不溢出', () {
    for (final size in kWidths) {
      testWidgets('建卡表单带两项权益 @${size.width.toInt()}', (tester) async {
        final backend = withPlatforms();
        // 先在高的窗口里加好（表单是懒加载的列表，矮窗口里底下的「加好了」还没建出来），再换成要量的尺寸。
        await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/new', size: Size(size.width, 3000));
        for (final name in ['每月 4 张红包', '一项名字特别特别长、长到一行放不下的权益']) {
          await tapVisible(tester, find.byKey(const ValueKey('membership-benefit-add')));
          await tester.enterText(find.byKey(const ValueKey('benefit-name')), name);
          await tapVisible(tester, find.widgetWithText(FilledButton, '加好了'));
        }
        tester.view.physicalSize = size;
        await settle(tester);
        expect(find.byKey(const ValueKey('membership-benefit-1')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('草稿表单（N 选 1 带选项）@${size.width.toInt()}', (tester) async {
        final backend = withPlatforms();
        await pumpAssetsAt(tester, bootAssets(backend), '/assets/memberships/new', size: size);
        await tapVisible(tester, find.byKey(const ValueKey('membership-benefit-add')));
        await tapVisible(tester, find.byKey(const ValueKey('benefit-kind-choice')));
        await quickOption(tester, '优酷年卡');
        await quickOption(tester, '一个名字特别特别长、长到一行放不下的选项');
        if (size.width >= 600) expect(find.byType(NavigationRail), findsOneWidget, reason: '宽屏带着导航轨');
        expect(tester.takeException(), isNull);
      });
    }
  });

  test('草稿：「N 选 1」才带 options；preview 当成一条权益看', () {
    final option = BenefitDraft(body: {'name': '优酷', 'kind': 'other'});
    final choice = BenefitDraft(body: {
      'name': '二选一',
      'kind': 'choice',
      'quota': [
        {'p': 'year', 'n': 1},
      ],
    }, options: [option]);
    expect(choice.toJson()['options'], [
      {'name': '优酷', 'kind': 'other'},
    ]);
    expect(choice.preview.isChoice, isTrue);
    expect(choice.preview.quota.single.n, 1);
    expect(benefitDraftSummary(null, choice, option: false), 'N 选 1 · 每年 1 次 · 1 个选项');
    expect(benefitDraftSummary(null, option, option: true), '点开能补在哪领、面值、限制');
    final coupon = BenefitDraft(body: {'name': '券', 'kind': 'coupon'}, options: [option]);
    expect(coupon.toJson().containsKey('options'), isFalse, reason: '不是「N 选 1」不带选项');
    expect(choice.copyWith(options: const []).key, choice.key, reason: '改了还是同一条');
  });
}
