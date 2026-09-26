import 'dart:convert';

import 'package:famledger/ui/perk_import/perk_import_draft.dart';
import 'package:famledger/ui/perk_import/perk_import_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assets_harness.dart';
import 'perk_import_fixtures.dart';
import 'perks_fake.dart';

// AI 导入的预览页（spec §6「预览」、§8「预览页用 fixture 草稿做 widget 测试」）：树形 + 实物一节、徽章、筛选、勾选联动、
// 宽屏左树右表单与原文依据高亮、导入被拦住的两类情况、失败留在原地并标到节点、回应丢了再点不重复、结果页。
// 映射视图和批量操作在 perk_import_batch_test.dart。

AssetsBackend previewBackend() => AssetsBackend(
  perks: PerksFake(platforms: [platformJson('tb'), platformJson('yk', name: '优酷', sort: 1)]),
);

/// 把 [draftJson] 交给预览页并打开 `/assets/import/preview`。
Future<ProviderContainer> openPreview(
  WidgetTester tester,
  AssetsBackend backend,
  Map<String, dynamic> draftJson, {
  Size size = const Size(400, 2400),
}) async {
  final container = bootAssets(backend);
  // autoDispose：先挂一个监听，免得页面接手之前就被回收。
  container.listen(pendingPerkImportProvider, (_, _) {});
  container.read(pendingPerkImportProvider.notifier).state = PerkImportDraft.fromJson(draftJson, clientId: 'cid-test');
  await pumpAssetsAt(tester, container, '/assets/import/preview', size: size);
  return container;
}

Finder tileOf(String key) => find.byKey(ValueKey('import-node-$key'));
Finder inTile(String key, String text) => find.descendant(of: tileOf(key), matching: find.text(text));
bool checkedOf(WidgetTester tester, String key) => tester.widget<Checkbox>(find.byKey(ValueKey('import-check-$key'))).value!;

void main() {
  testWidgets('树：淘宝（合并）→ 88VIP（新建）→ 权益，N 选 1 带三个选项；只当领取平台用的不进树', (tester) async {
    await openPreview(tester, previewBackend(), vip88Draft());
    expect(find.text('识别出 平台 6 个、会员卡 1 张、权益 7 项，勾了 14 项。'), findsOneWidget);
    expect(inTile('p1', '合并到「淘宝」'), findsOneWidget);
    expect(inTile('m1', '新建'), findsOneWidget);
    expect(inTile('m1', '¥88.00 每年 · 到期 2026-12-31 · 自动续费'), findsOneWidget);
    expect(inTile('b1', '会籍期内 1 次 · 去「优酷视频」领'), findsOneWidget);
    for (final k in ['b4', 'b5', 'b6']) {
      expect(tileOf(k), findsOneWidget);
    }
    expect(tileOf('p2'), findsNothing, reason: '只当领取平台用的不进树');
    expect(find.byKey(const ValueKey('import-filter-attention')), findsOneWidget);
  });

  testWidgets('勾选联动：取消 88VIP → 它的权益都取消、导入数跟着变；再勾一个选项 → 「三选一」和卡跟着勾上', (tester) async {
    await openPreview(tester, previewBackend(), vip88Draft());
    await tapVisible(tester, find.byKey(const ValueKey('import-check-m1')));
    for (final k in ['b1', 'b2', 'b3', 'b7', 'b4']) {
      expect(checkedOf(tester, k), isFalse, reason: k);
    }
    expect(find.text('导入 1 项'), findsOneWidget, reason: '剩并入已有的淘宝；五个领取平台没有勾着的权益在用，跟着不导');
    await tapVisible(tester, find.byKey(const ValueKey('import-check-b4')));
    expect([checkedOf(tester, 'b4'), checkedOf(tester, 'b7'), checkedOf(tester, 'm1'), checkedOf(tester, 'b5')], [true, true, true, false]);
  });

  testWidgets('手机上点一行：弹层里改（顶上高亮原文依据），改完列表立刻变；宽屏在右栏改、不弹层', (tester) async {
    await openPreview(tester, previewBackend(), vip88Draft());
    await tapVisible(tester, tileOf('m1'));
    final highlight = tester.widget<RichText>(find.descendant(of: find.byKey(const ValueKey('evidence-highlight')), matching: find.byType(RichText)));
    expect(highlight.text.toPlainText(), contains('年费 88 元（淘气值 1000 分以上），到期日 2026-12-31'));
    await tester.enterText(find.byKey(const ValueKey('node-money')), '99');
    await tester.tap(find.text('好了'));
    await settle(tester);
    expect(inTile('m1', '¥99.00 每年 · 到期 2026-12-31 · 自动续费'), findsOneWidget);

    await openPreview(tester, previewBackend(), vip88Draft(), size: const Size(1400, 1200));
    expect(find.text('点左边一项，在这里改'), findsOneWidget);
    await tester.tap(tileOf('b3'));
    await settle(tester);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byKey(const ValueKey('node-form-b3')), findsOneWidget);
    expect(find.byKey(const ValueKey('evidence-highlight')), findsOneWidget);
  });

  testWidgets('拦截：同名两张卡没选时导入按钮点不了，底栏写原因；点开选一张就放行，换上那张的差异、卡里已有的权益变成更新', (tester) async {
    await openPreview(tester, previewBackend(), vipPickJson());
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('perk-import-submit'))).onPressed, isNull);
    expect(find.text('还有 1 处要处理：「88VIP」有同名的好几张，选一张更新或新建'), findsOneWidget);
    expect(inTile('m1', '同名 2 张，要选'), findsOneWidget);
    await tapVisible(tester, tileOf('m1'));
    await tester.tap(find.byKey(const ValueKey('node-pick-c1')));
    await tester.tap(find.text('好了'));
    await settle(tester);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('perk-import-submit'))).onPressed, isNotNull);
    expect(inTile('m1', '更新 1 项'), findsOneWidget, reason: '爸爸那张的到期日更早，默认勾上');
    expect(inTile('b3', '新建'), findsOneWidget);
    await tapVisible(tester, tileOf('m1'));
    await tester.tap(find.byKey(const ValueKey('node-pick-c2')));
    await tester.tap(find.text('好了'));
    await settle(tester);
    expect(inTile('m1', '已有，没有变化'), findsOneWidget);
    expect(inTile('b3', '更新 1 项'), findsOneWidget, reason: '妈妈那张下面已经有「88 折购物券」：更新它，不再新建一份');
  });

  testWidgets('更新已有的卡（Review ①）：表单里改续费价 → 徽章写「更新 1 项」、差异行是「原来 → 改后」，提交体 take 里有 feeCents', (tester) async {
    final backend = previewBackend();
    await openPreview(tester, backend, vipAgainJson());
    expect(inTile('m1', '已有，没有变化'), findsOneWidget);
    await tapVisible(tester, tileOf('m1'));
    await tester.enterText(find.byKey(const ValueKey('node-money')), '99');
    await tester.pump();
    expect(
      find.descendant(of: find.byKey(const ValueKey('node-diff-feeCents')), matching: find.text('¥88.00 → ¥99.00')),
      findsOneWidget,
      reason: '服务端没列这项差异：原来的值取服务端给的 current（账本里不用有那一行）',
    );
    await tester.tap(find.text('好了'));
    await settle(tester);
    expect(inTile('m1', '更新 1 项'), findsOneWidget);
    await tapVisible(tester, find.byKey(const ValueKey('perk-import-submit')));
    final m = (backend.imports.applyBodies.single['memberships'] as List).single as Map<String, dynamic>;
    expect([m['action'], m['targetId'], m['take'], (m['fields'] as Map)['feeCents']], ['update', 'old-vip', ['feeCents'], 9900]);
    expect(find.text('更新：会员卡 1 张'), findsOneWidget);
  });

  testWidgets('400 宽、字号放大 1.5 倍：点开带差异的更新节点，差异区不溢出（Review ㉘）', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final json = vipAgainJson();
    ((json['memberships'] as List).first as Map<String, dynamic>)['diff'] = [
      {'field': 'expiresOn', 'old': '2026-06-30', 'new': '2026-12-31', 'take': true},
      {'field': 'feeCents', 'old': 9900, 'new': 8800, 'take': false},
    ];
    await openPreview(tester, previewBackend(), json, size: const Size(400, 2400));
    await tapVisible(tester, tileOf('m1'));
    await tester.scrollUntilVisible(find.byKey(const ValueKey('node-diff-feeCents')), 200, scrollable: find.byType(Scrollable).last);
    expect(find.text('和库里不一样的（勾上的才写入，不删）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没写平台的卡（Review ⑭）：挡住导入，点开在表单里选一个平台就放行', (tester) async {
    final json = vip88Draft();
    (((json['memberships'] as List).first as Map<String, dynamic>)['fields'] as Map)['platform'] = null;
    await openPreview(tester, previewBackend(), json);
    expect(find.text('没写平台的卡'), findsOneWidget);
    expect(find.text('还有 1 处要处理：「88VIP」缺平台'), findsOneWidget);
    await tapVisible(tester, tileOf('m1'));
    await tester.tap(find.byKey(const ValueKey('node-platform')));
    await settle(tester);
    await tester.tap(find.text('淘宝').last);
    await settle(tester);
    await tester.tap(find.text('好了'));
    await settle(tester);
    expect(find.text('没写平台的卡'), findsNothing);
    expect(find.byKey(const ValueKey('perk-import-blockers')), findsNothing);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('perk-import-submit'))).onPressed, isNotNull);
  });

  testWidgets('「已存在」的物品（Review ②）：默认不导；勾上 → 按钮变「导入 1 项」、提交体是 create', (tester) async {
    final backend = previewBackend();
    final json = orderDraft();
    ((json['items'] as List).first as Map<String, dynamic>)
      ..['action'] = 'skip'
      ..['checked'] = false
      ..['badges'] = ['exists']
      ..['match'] = {'kind': 'exists', 'id': 'a-old', 'name': 'iPhone 16 Pro 256GB'};
    await openPreview(tester, backend, json);
    expect(inTile('i1', '已存在'), findsOneWidget);
    expect(find.text('一项都没勾'), findsOneWidget);
    await tapVisible(tester, find.byKey(const ValueKey('import-check-i1')));
    expect(inTile('i1', '已存在，再建一件'), findsOneWidget);
    await tapVisible(tester, find.byKey(const ValueKey('perk-import-submit')));
    expect(((backend.imports.applyBodies.single['items'] as List).single as Map)['action'], 'create');
  });

  testWidgets('什么都没识别出来（Review ㉕）：一句说明 + 「回去改一下材料」，没有导入按钮，返回不问「不导了？」', (tester) async {
    final json = vip88Draft()
      ..['platforms'] = <Object>[]
      ..['memberships'] = <Object>[]
      ..['benefits'] = <Object>[]
      ..['notices'] = ['材料里没找到会员、权益或买的东西'];
    await openPreview(tester, previewBackend(), json);
    expect(find.byKey(const ValueKey('perk-import-nothing')), findsOneWidget);
    expect(find.text('材料里没找到会员、权益或买的东西'), findsOneWidget, reason: '同一句只出现一次');
    expect(find.byKey(const ValueKey('perk-import-submit')), findsNothing);
    await tester.pageBack();
    await settle(tester);
    expect(find.text('不导了？'), findsNothing);
  });

  testWidgets('提交中（Review ㉖）：限宽的进度条和「别关这个页面」，导完到结果页', (tester) async {
    final backend = previewBackend();
    backend.delayNext['POST /asset-import/apply'] = const Duration(seconds: 2);
    await openPreview(tester, backend, vip88Draft());
    await tester.ensureVisible(find.byKey(const ValueKey('perk-import-submit')));
    await tester.tap(find.byKey(const ValueKey('perk-import-submit')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.descendant(of: find.byKey(const ValueKey('perk-import-submitting')), matching: find.byType(LinearProgressIndicator)), findsOneWidget);
    expect(find.textContaining('别关这个页面'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await settle(tester);
    expect(find.byKey(const ValueKey('perk-import-result-title')), findsOneWidget);
  });

  testWidgets('平台表单（Review ⑯）：可能重复的主平台能并入已有的（提交体 merge + 目标）；名字一模一样的不给「新建」', (tester) async {
    final backend = previewBackend();
    final json = vip88Draft();
    ((json['platforms'] as List).first as Map<String, dynamic>)
      ..['fields'] = {'name': '淘宝网', 'kind': 'shopping'}
      ..['action'] = 'create'
      ..['targetId'] = null
      ..['badges'] = ['maybe_dup']
      ..['match'] = {
        'kind': 'maybe',
        'candidates': [
          {'id': 'tb', 'name': '淘宝'},
        ],
      };
    await openPreview(tester, backend, json);
    expect(inTile('p1', '可能重复'), findsOneWidget);
    await tapVisible(tester, tileOf('p1'));
    expect(find.byKey(const ValueKey('claim-p1-self')), findsNothing, reason: '挂着卡的平台没有「就是会员本平台」');
    await tester.tap(find.byKey(const ValueKey('claim-p1-candidate-tb')));
    await settle(tester);
    expect(find.textContaining('导入时会并进原来那张'), findsOneWidget);
    await tester.tap(find.text('好了'));
    await settle(tester);
    expect(inTile('p1', '合并到「淘宝」'), findsOneWidget);
    expect(inTile('p1', '可能重复'), findsNothing);
    await tapVisible(tester, find.byKey(const ValueKey('perk-import-submit')));
    final p1 = (backend.imports.applyBodies.single['platforms'] as List).first as Map<String, dynamic>;
    expect([p1['action'], p1['targetId'], p1['match']], ['merge', 'tb', 'maybe']);

    await openPreview(tester, previewBackend(), vip88Draft());
    await tapVisible(tester, tileOf('p1'));
    expect(find.byKey(const ValueKey('claim-p1-existing')), findsOneWidget);
    expect(find.byKey(const ValueKey('claim-p1-create')), findsNothing, reason: '和已有的「淘宝」同名，只能并入');
  });

  testWidgets('命中归档的卡（Review ⑩）：徽章写「原来归档了，导入后恢复」；不勾恢复就提醒看不到；选「新建一张」就另建', (tester) async {
    final backend = previewBackend();
    final json = vipAgainJson();
    final m = (json['memberships'] as List).first as Map<String, dynamic>;
    final diff = [
      {'field': 'expiresOn', 'old': '2025-12-31', 'new': '2026-12-31', 'take': true},
      {'field': 'archived', 'old': true, 'new': false, 'take': true},
    ];
    final current = membershipCurrentOf(m['fields'] as Map<String, dynamic>, {'expiresOn': '2025-12-31'});
    m
      ..['diff'] = diff
      ..['current'] = current
      ..['match'] = {
        'kind': 'update', 'id': 'old-vip', 'name': '88VIP', 'archived': true,
        'candidates': [
          {'id': 'old-vip', 'name': '88VIP', 'tier': null, 'memberId': null, 'expiresOn': '2025-12-31', 'archived': true, 'diff': diff, 'current': current, 'notMentioned': <Object>[]},
        ],
      };
    await openPreview(tester, backend, json);
    expect(inTile('m1', '更新 2 项'), findsOneWidget);
    expect(inTile('m1', '原来归档了，导入后恢复'), findsOneWidget);
    await tapVisible(tester, tileOf('m1'));
    expect(find.text('库里同名的这张已经归档（停了），这次？'), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('node-diff-archived')), 200, scrollable: find.byType(Scrollable).last);
    await tester.tap(find.byKey(const ValueKey('node-diff-archived')));
    await tester.pump();
    expect(inTile('m1', '原来归档了，不恢复就看不到'), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('node-pick-new')), -200, scrollable: find.byType(Scrollable).last);
    await tester.tap(find.byKey(const ValueKey('node-pick-new')));
    await tester.tap(find.text('好了'));
    await settle(tester);
    expect(inTile('m1', '新建'), findsOneWidget);
    expect(inTile('m1', '原来归档了，不恢复就看不到'), findsNothing);
    await tapVisible(tester, find.byKey(const ValueKey('perk-import-submit')));
    final sent = (backend.imports.applyBodies.single['memberships'] as List).single as Map<String, dynamic>;
    expect([sent['action'], sent.containsKey('targetId')], ['create', false]);
  });

  testWidgets('未归属的权益点开能选「归到哪张卡」（Review ⑫）：选了就挂过去、勾上', (tester) async {
    final json = vip88Draft();
    (json['benefits'] as List).add(importNode('b9', 'benefit', {'membership': null, 'parent': null, 'name': '免费停车', 'quota': <Object>[]}, checked: false, badges: const ['missing'], ev: '免费停车'));
    await openPreview(tester, previewBackend(), json);
    expect(find.text('找不到属于哪张卡，默认不导。长按多选后「移到卡」，或点开改。'), findsOneWidget);
    await tapVisible(tester, tileOf('b9'));
    await tester.tap(find.byKey(const ValueKey('node-membership')));
    await settle(tester);
    await tester.tap(find.text('88VIP（新建）').last);
    await settle(tester);
    await tester.tap(find.text('好了'));
    await settle(tester);
    expect(find.byKey(const ValueKey('import-unowned')), findsNothing);
    expect(checkedOf(tester, 'b9'), isTrue);
    expect(find.text('导入 15 项'), findsOneWidget);
  });

  testWidgets('物品名字相近（Review ⑬）：表单列出账本里相近的那件；「不是同一件」去掉「可能重复」', (tester) async {
    final json = orderDraft();
    ((json['items'] as List).first as Map<String, dynamic>)
      ..['badges'] = ['maybe_dup']
      ..['match'] = {
        'kind': 'near',
        'candidates': [
          {'id': 'a-old', 'name': 'iPhone 16 Pro', 'priceCents': 799900, 'purchasedOn': '2025-09-20'},
        ],
      };
    await openPreview(tester, previewBackend(), json);
    expect(inTile('i1', '可能重复'), findsOneWidget);
    await tapVisible(tester, tileOf('i1'));
    expect(find.text('iPhone 16 Pro · ¥7,999.00 · 2025-09-20'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('node-not-dup')));
    await tester.pump();
    expect(find.byKey(const ValueKey('node-not-dup')), findsNothing);
    await tester.tap(find.text('好了'));
    await settle(tester);
    expect(inTile('i1', '可能重复'), findsNothing);
  });

  testWidgets('手机上改一项的弹层给软键盘让位（Review ⑱）', (tester) async {
    await openPreview(tester, previewBackend(), vip88Draft(), size: const Size(400, 860));
    await tapVisible(tester, tileOf('m1'));
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();
    final pad = tester.widget<Padding>(find.ancestor(of: find.byType(DraggableScrollableSheet), matching: find.byType(Padding)).first);
    expect((pad.padding as EdgeInsets).bottom, 320);
    expect(tester.takeException(), isNull);
  });

  testWidgets('单独的平台（Review ④）：没挂卡、也没人去它那领的列在树末尾，默认不勾', (tester) async {
    final json = vip88Draft();
    (json['platforms'] as List).add(importNode('p7', 'platform', {'name': '天猫', 'kind': 'shopping'}, action: 'merge', targetId: 'tb', match: {'kind': 'alias', 'id': 'tb', 'name': '淘宝'}));
    await openPreview(tester, previewBackend(), json);
    expect(find.byKey(const ValueKey('import-standalone')), findsOneWidget);
    expect(checkedOf(tester, 'p7'), isFalse);
    expect(find.text('导入 14 项'), findsOneWidget);
  });

  testWidgets('物品：缺价格挡住导入，点开填上就放行（Review Focus ⑤）；关联方式改成「同时记一笔」写进提交体', (tester) async {
    final backend = previewBackend();
    final json = orderDraft();
    ((json['items'] as List).first as Map<String, dynamic>)['fields']['priceCents'] = null;
    await openPreview(tester, backend, json);
    expect(find.text('实物 · 1 件'), findsOneWidget);
    expect(inTile('i1', '缺字段'), findsOneWidget);
    expect(find.text('还有 1 处要处理：「iPhone 16 Pro 256GB」缺价格'), findsOneWidget);
    await tapVisible(tester, tileOf('i1'));
    await tester.enterText(find.byKey(const ValueKey('node-money')), '8999');
    expect(find.textContaining('这笔钱已经记过账就别选，免得记两遍'), findsOneWidget, reason: '找不到候选时选「同时记一笔」可能重复记账，先提醒（Review ⑮）');
    await tester.tap(find.byKey(const ValueKey('node-link-record')));
    await tester.tap(find.text('好了'));
    await settle(tester);
    await tapVisible(tester, find.byKey(const ValueKey('perk-import-submit')));
    final item = (backend.imports.applyBodies.single['items'] as List).single as Map<String, dynamic>;
    expect((item['fields'] as Map)['priceCents'], 899900);
    expect(item['recordTransaction'], <String, dynamic>{});
    expect(item.containsKey('linkTransactionId'), isFalse);
  });

  testWidgets('导入成功 → 结果页写新建了什么，「去看看」去会员权益的本期', (tester) async {
    final backend = previewBackend();
    await openPreview(tester, backend, vip88Draft());
    await tapVisible(tester, find.byKey(const ValueKey('perk-import-submit')));
    expect(find.byKey(const ValueKey('perk-import-result-title')), findsOneWidget);
    expect(find.text('新建：平台 5 个、会员卡 1 张、权益 7 项'), findsOneWidget);
    expect(backend.imports.applyBodies.single['clientId'], 'cid-test');
    await tester.tap(find.byKey(const ValueKey('perk-import-go')));
    await settle(tester);
    expect(find.text('本期'), findsWidgets);
    expect(find.text('88VIP'), findsWidgets);
  });

  testWidgets('导入失败（import_invalid）：留在核对页，错误标到对应的项上，改过的都在', (tester) async {
    final backend = previewBackend();
    backend.imports.applyError = {
      'code': 'import_invalid',
      'message': '有 1 处要改，一条都没导入',
      'details': {
        'errors': [
          {'key': 'b2', 'field': 'membership', 'message': '会员卡没有导入（没勾选或它自己出错了）'},
        ],
      },
    };
    await openPreview(tester, backend, vip88Draft());
    await tapVisible(tester, find.byKey(const ValueKey('import-check-b3')));
    await tapVisible(tester, find.byKey(const ValueKey('perk-import-submit')));
    expect(find.byKey(const ValueKey('perk-import-result-title')), findsNothing);
    expect(find.byKey(const ValueKey('import-error-b2')), findsOneWidget);
    expect(find.text('有 1 处要改，已经标在对应的项上；一条都没导入。'), findsOneWidget);
    expect(checkedOf(tester, 'b3'), isFalse, reason: '刚才的改动还在');
  });

  testWidgets('回应丢在路上（Review Focus ③）：说不确定、再点一次用同一个 clientId，只导一次', (tester) async {
    final backend = previewBackend();
    backend.dropResponseNext.add('POST /asset-import/apply');
    await openPreview(tester, backend, vip88Draft());
    await tapVisible(tester, find.byKey(const ValueKey('perk-import-submit')));
    expect(find.text('没等到服务器回应，不确定导进去没有。再点一次也不会重复导入。'), findsOneWidget);
    await tapVisible(tester, find.byKey(const ValueKey('perk-import-submit')));
    expect(find.byKey(const ValueKey('perk-import-result-title')), findsOneWidget);
    final sent = backend.requests('POST', '/asset-import/apply').map((r) => (jsonDecode(r.body) as Map)['clientId']).toList();
    expect(sent, ['cid-test', 'cid-test']);
    expect(backend.imports.applyBodies, hasLength(1), reason: '第二次是重放，服务端只执行了一次');
    expect(backend.perks.memberships.values.where((m) => m['name'] == '88VIP'), hasLength(1));
  });

  testWidgets('截断：顶部横幅提示分段导入（说法按草稿的标记来，服务端别的提示照常列出）；返回时先问「不导了？」', (tester) async {
    final json = vip88Draft()
      ..['truncated'] = true
      ..['notices'] = ['材料有 15000 字，只挑了最相关的 6 段（约 9000 字）'];
    await openPreview(tester, previewBackend(), json);
    expect(find.byKey(const ValueKey('import-truncated')), findsOneWidget);
    expect(find.textContaining('剩下的建议分段再粘一次'), findsOneWidget);
    expect(find.text('材料有 15000 字，只挑了最相关的 6 段（约 9000 字）'), findsOneWidget, reason: '不再按「分段」两个字过滤服务端的提示');
    await tester.pageBack();
    await settle(tester);
    expect(find.text('不导了？'), findsOneWidget);
    await tester.tap(find.text('接着核对'));
    await settle(tester);
    expect(find.byKey(const ValueKey('import-truncated')), findsOneWidget);
  });

  for (final size in kWidths) {
    testWidgets('宽 ${size.width}：核对、改一项、结果三种状态都不溢出', (tester) async {
      await openPreview(tester, previewBackend(), vip88Draft(), size: size);
      expect(tester.takeException(), isNull);
      await tapVisible(tester, tileOf('b3'));
      expect(tester.takeException(), isNull);
      if (size.width < 840) {
        await tester.tap(find.text('好了'));
        await settle(tester);
      }
      await tapVisible(tester, find.byKey(const ValueKey('perk-import-submit')));
      expect(find.byKey(const ValueKey('perk-import-result-title')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
