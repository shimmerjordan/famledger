import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/ui/perks/perk_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assets_harness.dart';
import 'perks_fake.dart';

// 扣费线索（spec §5「要处理」）：「已看到 9/21 扣 ¥25.00 → 续到 10/20」，一点就续上（只关联不记账，能撤销）；
// 替掉这张卡的卡片级提醒（权益快到期、本期没领完照旧）；「不是这笔」只记在本机；按「我」看只看我的和全家共用的；
// 取不到线索不打扰；线索第一次还没取回来时「续了 / 停了」先等一等；窄屏大字号时那一句不截断。「今天」= 2026-09-23。

const String line = '腾讯视频：已看到 9/21 扣 ¥25.00 → 续到 10/20';

/// 腾讯视频（自动续费、9/20 到期，应已续上）有一条线索：9/21 扣了 25 元；京东 PLUS 10/3 到期。
AssetsBackend hintBackend({String? tvMember}) => AssetsBackend(
  perks: PerksFake(
    platforms: [platformJson('tx', name: '腾讯视频'), platformJson('jd', name: '京东', sort: 1)],
    memberships: [
      membershipJson('tv', platformId: 'tx', name: '腾讯视频', memberId: tvMember, feeCents: 2500, feePeriod: 'month', autoRenew: 'yes', termStartOn: '2026-08-21', expiresOn: '2026-09-20'),
      membershipJson('plus', platformId: 'jd', name: '京东PLUS', feeCents: 19800, autoRenew: 'no', expiresOn: '2026-10-03', sort: 1),
    ],
  )..chargeHints.add(chargeHintJson('tv')),
);

void main() {
  testWidgets('有线索：这张卡的「续上了吗」换成线索那一行；「续上」只关联不记账；撤销连上次扣费一起改回去', (tester) async {
    final backend = hintBackend();
    await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=perks', size: const Size(400, 2000));
    expect(find.text('要处理 · 2'), findsOneWidget);
    expect(find.text(line), findsOneWidget);
    expect(find.text('腾讯视频 · 续上只关联这笔流水，不另记账'), findsOneWidget);
    expect(find.text('腾讯视频 应已自动续费，续上了吗？'), findsNothing, reason: '一张卡不说两遍');

    await tapVisible(tester, find.byKey(const ValueKey('charge-renew-tv')));
    final body = backend.lastBody('POST', '/memberships/tv/renew');
    expect(body, {'clientId': body['clientId'], 'expiresOn': '2026-10-20', 'paidCents': 2500, 'chargeTransactionId': 'tx1'});
    expect(backend.perks.memberships['tv']!['lastChargeTxId'], 'tx1');
    expect(find.text(line), findsNothing, reason: '同步回来重新取线索，这笔已经挂上了');
    expect(find.text('已续到 2026-10-20：腾讯视频'), findsOneWidget);
    expect(backend.requests('POST', '/transactions'), isEmpty, reason: '不另记账');

    await tester.tap(find.text('撤销'));
    await settle(tester);
    expect(backend.lastBody('PATCH', '/memberships/tv'), {
      'expiresOn': '2026-09-20',
      'termStartOn': '2026-08-21',
      'termPaidCents': null,
      'isTrial': false,
      'lastChargeTxId': null,
    });
    expect(find.text(line), findsOneWidget, reason: '撤销后这笔又没挂上，线索回来');
  });

  testWidgets('撤销时原来那笔「上次扣费」用不了了（400 invalid_lastChargeTxId）：不带它再改一次，到期日照样改回去', (tester) async {
    final backend = hintBackend();
    backend.perks.memberships['tv']!['lastChargeTxId'] = 'tx0';
    await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=perks', size: const Size(400, 2000));
    await tapVisible(tester, find.byKey(const ValueKey('charge-renew-tv')));
    expect(backend.perks.memberships['tv']!['expiresOn'], '2026-10-20');
    // 老服务端：原来那笔 tx0 后来被删了，PATCH 带着它就整个 400。
    backend.failNext['PATCH /memberships/tv'] = (400, 'invalid_lastChargeTxId', '这笔流水不存在');
    await tester.tap(find.text('撤销'));
    await settle(tester);
    final patches = backend.requests('PATCH', '/memberships/tv');
    expect(patches, hasLength(2));
    expect(backend.lastBody('PATCH', '/memberships/tv'), {
      'expiresOn': '2026-09-20',
      'termStartOn': '2026-08-21',
      'termPaidCents': null,
      'isTrial': false,
      'lastChargeTxId': null,
    });
    expect(backend.perks.memberships['tv']!['expiresOn'], '2026-09-20', reason: '到期日一定改回去');
    expect(find.text('已撤销'), findsOneWidget);
    expect(find.textContaining('没撤销成功'), findsNothing);
  });

  testWidgets('撤销时网络断了：说没撤销成功，不乱重试', (tester) async {
    final backend = hintBackend();
    await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=perks', size: const Size(400, 2000));
    await tapVisible(tester, find.byKey(const ValueKey('charge-renew-tv')));
    backend.failNext['PATCH /memberships/tv'] = (500, 'internal', '服务器出错了');
    await tester.tap(find.text('撤销'));
    await settle(tester);
    expect(backend.requests('PATCH', '/memberships/tv'), hasLength(1));
    expect(find.textContaining('没撤销成功'), findsOneWidget);
  });

  testWidgets('线索只替掉卡片级提醒（续费 / 到期 / 试用结束 / 过期待确认）：权益快到期、别的卡的提醒留着；条数 = 线索 + 留下的', (tester) async {
    final backend = hintBackend();
    backend.perks
      ..memberships['trial'] = membershipJson('trial', platformId: 'tx', name: '爱奇艺试用', feeCents: 1500, feePeriod: 'month', isTrial: true, expiresOn: '2026-09-25', sort: 2)
      ..benefits['b1'] = benefitJson('b1', membershipId: 'tv', name: '观影券', quota: const [{'p': 'month', 'n': 1}], validUntil: '2026-09-28')
      ..chargeHints.add(chargeHintJson('trial', transactionId: 'tx2', occurredOn: '2026-09-22', merchant: '爱奇艺', expiresOn: '2026-09-25', renewTo: '2026-10-25'));
    await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=perks', size: const Size(400, 2400));
    expect(find.text(line), findsOneWidget);
    expect(find.text('爱奇艺试用：已看到 9/22 扣 ¥25.00 → 续到 10/25'), findsOneWidget);
    expect(find.text('腾讯视频 应已自动续费，续上了吗？'), findsNothing);
    expect(find.text('爱奇艺试用 试用快结束'), findsNothing, reason: '试用结束也是卡片级的，由线索替掉');
    expect(find.text('观影券 快到期'), findsOneWidget, reason: '权益快到期照旧（有线索的那张卡上的也留着）');
    expect(find.text('京东PLUS 快到期'), findsOneWidget, reason: '没线索的卡照旧');
    expect(find.text('要处理 · 4'), findsOneWidget);
  });

  testWidgets('线索第一次还没取回来：可能有线索的那张卡「续了」先转圈、点了不做事；线索一到换成线索那一行', (tester) async {
    final backend = hintBackend();
    backend.perks.memberships['tv']!['payPattern'] = {'keywords': ['腾讯视频']};
    backend.delayNext['GET /memberships/charge-hints'] = const Duration(seconds: 3);
    await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=perks', size: const Size(400, 2000));
    expect(find.text('腾讯视频 应已自动续费，续上了吗？'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('alert-renew-tv')), matching: find.byType(CircularProgressIndicator)), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('alert-renew-tv')));
    await tester.tap(find.byKey(const ValueKey('alert-stop-tv')));
    await settle(tester);
    expect(backend.requests('POST', '/memberships/tv/renew'), isEmpty, reason: '手快点了也不走不关联流水的「续了」');
    expect(backend.requests('PATCH', '/memberships/tv'), isEmpty);
    expect(find.text('续了'), findsNWidgets(1), reason: '京东PLUS 没设扣费特征，不用等');

    await tester.pump(const Duration(seconds: 3));
    await settle(tester);
    expect(find.text(line), findsOneWidget);
    expect(find.text('腾讯视频 应已自动续费，续上了吗？'), findsNothing);
  });

  testWidgets('「不是这笔」：线索收起、只记在本机；这张卡的「续上了吗」回来', (tester) async {
    final backend = hintBackend();
    final store = MemoryLocalStore();
    await pumpAssetsAt(tester, bootAssets(backend, store: store), '/assets?tab=perks', size: const Size(400, 2000));
    await tapVisible(tester, find.byKey(const ValueKey('charge-dismiss-tv')));
    expect(find.text(line), findsNothing);
    expect(find.text('腾讯视频 应已自动续费，续上了吗？'), findsOneWidget);
    final saved = await store.read<Map<String, dynamic>>(PerkDismissedController.storeKey);
    expect(saved!.keys, ['charge:tv:tx1']);
    expect(backend.requests('PATCH', '/memberships/tv'), isEmpty);
  });

  testWidgets('按「我」看：别人的卡的线索不显示；看全家才有', (tester) async {
    final backend = hintBackend(tvMember: 'u2');
    await pumpAssetsAt(tester, bootAssets(backend, session: await sessionAs('member')), '/assets?tab=perks&view=current&scope=mine', size: const Size(400, 2000));
    expect(find.text(line), findsNothing);
    await tapVisible(tester, find.byKey(const ValueKey('perk-scope-family')));
    expect(find.text(line), findsOneWidget);
  });

  testWidgets('线索取不到（离线、老服务端）：「要处理」照常，不报错', (tester) async {
    final backend = hintBackend()..failAlways['GET /memberships/charge-hints'] = (404, 'not_found', '没有这个接口');
    await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=perks', size: const Size(400, 2000));
    expect(find.text(line), findsNothing);
    expect(find.text('腾讯视频 应已自动续费，续上了吗？'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('续上时这笔已经被别的卡关联（409 charge_linked）：说一句、不续，重新取线索', (tester) async {
    final backend = hintBackend();
    await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=perks', size: const Size(400, 2000));
    // 另一台设备刚把这笔挂到了京东PLUS 上，这台还没刷新。
    backend.perks.memberships['plus']!['lastChargeTxId'] = 'tx1';
    await tapVisible(tester, find.byKey(const ValueKey('charge-renew-tv')));
    expect(find.text('这笔扣费已经算在「京东PLUS」上了，没有续'), findsOneWidget);
    expect(backend.perks.memberships['tv']!['expiresOn'], '2026-09-20');
    expect(find.text(line), findsNothing, reason: '重新取回来的线索里已经没有这笔');
  });

  group('不溢出、不截断', () {
    for (final size in kWidths) {
      testWidgets('${size.width.toInt()} 宽、字号 1.5 倍：线索那一句整句看得见（扣了多少、续到哪天不被省略号吃掉），按钮点得到', (tester) async {
        final backend = hintBackend();
        backend.perks.memberships['tv']!['name'] = '腾讯视频超长名字的连续包月会员卡';
        tester.platformDispatcher.textScaleFactorTestValue = 1.5;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await pumpAssetsAt(tester, bootAssets(backend), '/assets?tab=perks', size: Size(size.width, 2000));
        final text = find.descendant(of: find.byKey(const ValueKey('charge-line-tv')), matching: find.byType(RichText));
        final paragraph = tester.renderObject<RenderParagraph>(text);
        expect(paragraph.text.toPlainText(), '腾讯视频超长名字的连续包月会员卡：已看到 9/21 扣 ¥25.00 → 续到 10/20');
        expect(paragraph.didExceedMaxLines, isFalse, reason: '没有被截成「…」');
        expect(tester.getRect(text).right, lessThanOrEqualTo(size.width));
        if (size.width < 500) {
          expect(tester.getTopLeft(find.byKey(const ValueKey('charge-renew-tv'))).dy, greaterThanOrEqualTo(tester.getBottomLeft(text).dy),
              reason: '窄屏大字号：按钮挪到文字下面，整行宽度留给那一句');
        }
        expect(tester.takeException(), isNull);
        await tapVisible(tester, find.byKey(const ValueKey('charge-renew-tv')));
        expect(backend.requests('POST', '/memberships/tv/renew'), hasLength(1));
      });
    }
  });
}
