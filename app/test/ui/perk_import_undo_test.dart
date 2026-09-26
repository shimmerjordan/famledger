import 'package:famledger/data/models/models.dart';
import 'package:famledger/ui/perk_import/perk_import_draft.dart';
import 'package:famledger/ui/perk_import/perk_import_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assets_harness.dart';
import 'perk_import_fixtures.dart';
import 'perks_fake.dart';

// 结果页「撤销本次导入」（spec §4 undo、§6「结果页有『去看看』和『撤销本次导入』」）：先确认，撤完原地换成「已撤销」—— 删了什么、
// 随物品记的支出、改回了什么；导入后被改过的、被删了的、还在用的留着并说清楚；过期、回应丢了行内说；三种宽度、1.5 倍字号不溢出。

AssetsBackend undoBackend() => AssetsBackend(
  perks: PerksFake(platforms: [platformJson('tb'), platformJson('yk', name: '优酷', sort: 1)]),
);

Future<ProviderContainer> importAndShowResult(
  WidgetTester tester,
  AssetsBackend backend,
  Map<String, dynamic> draftJson, {
  PerkImportDraft Function(Map<String, dynamic>)? make,
  Size size = const Size(400, 2000),
}) async {
  final container = bootAssets(backend);
  container.listen(pendingPerkImportProvider, (_, _) {});
  container.read(pendingPerkImportProvider.notifier).state = (make ?? (j) => PerkImportDraft.fromJson(j, clientId: 'cid-undo'))(draftJson);
  await pumpAssetsAt(tester, container, '/assets/import/preview', size: size);
  await tapVisible(tester, find.byKey(const ValueKey('perk-import-submit')));
  expect(find.byKey(const ValueKey('perk-import-result-title')), findsOneWidget);
  return container;
}

Future<void> confirmUndo(WidgetTester tester) async {
  await tapVisible(tester, find.byKey(const ValueKey('perk-import-undo')));
  expect(find.text('撤销这次导入？'), findsOneWidget);
  await tester.tap(find.byKey(const ValueKey('perk-import-undo-confirm')));
  await settle(tester);
}

void main() {
  testWidgets('撤销：先问、确认后请求 undo → 原地换成「已撤销」写删了什么；物品跟着同步没了', (tester) async {
    final backend = undoBackend();
    final json = orderDraft();
    await importAndShowResult(tester, backend, json, make: (j) {
      final d = PerkImportDraft.fromJson(j, clientId: 'cid-undo');
      d.setLink('i1', ItemLink.record); // 同时记一笔：撤销时那笔一起删
      return d;
    });
    expect(backend.assets, hasLength(1));
    expect(find.textContaining('7 天内到资产页右上角的「最近的 AI 导入」里撤'), findsOneWidget, reason: '说清楚离开这一页之后去哪撤');

    await tapVisible(tester, find.byKey(const ValueKey('perk-import-undo')));
    await tester.tap(find.text('不撤了'));
    await settle(tester);
    expect(backend.imports.undoCalls, isEmpty, reason: '点「不撤了」什么都不发');

    final changesBefore = backend.requests('GET', '/changes').length;
    await confirmUndo(tester);
    expect(backend.imports.undoCalls, ['imp-order']);
    expect(find.byKey(const ValueKey('perk-import-undone-title')), findsOneWidget);
    expect(find.text('删掉：物品 1 件'), findsOneWidget);
    expect(find.text('随物品记的 1 笔支出一起删了'), findsOneWidget);
    expect(find.byKey(const ValueKey('perk-import-undo')), findsNothing, reason: '撤过了，不再给按钮');
    expect(find.byKey(const ValueKey('perk-import-go')), findsNothing);
    expect(backend.assets, isEmpty);
    expect(backend.requests('GET', '/changes').length, greaterThan(changesBefore), reason: '撤完同步一次');
  });

  testWidgets('撤销后有没动的：导入后改过的、还在用的分别说清楚；改回原样的也写出来', (tester) async {
    final backend = undoBackend();
    backend.imports.undoExtra = {
      'restored': {'memberships': 1, 'benefits': 0},
      'aliasesRemoved': 1,
      'skippedChanged': [
        {'table': 'memberships', 'id': 'vip', 'name': '88VIP', 'deleted': false},
        {'table': 'benefits', 'id': 'b-old', 'name': '88 折购物券', 'deleted': true},
      ],
      'skippedInUse': [
        {'table': 'platforms', 'id': 'p-imp-p3', 'name': '饿了么', 'reason': 'in_use'},
        {'table': 'benefits', 'id': 'b-choice', 'name': '三选一', 'reason': 'choice_in_use'},
        {'table': 'assets', 'id': 'a-1', 'name': 'iPhone', 'reason': 'sold'},
      ],
      'undone': {'platforms': 5, 'memberships': 1, 'benefits': 7, 'items': 0, 'transactions': 0, 'events': 3},
    };
    await importAndShowResult(tester, backend, vip88Draft());
    await confirmUndo(tester);
    expect(find.textContaining('删掉：平台 5 个、会员卡 1 张、权益 7 项'), findsOneWidget);
    expect(find.text('改回导入前：会员卡 1 张'), findsOneWidget);
    expect(find.text('去掉了导入时加的 1 个平台别名'), findsOneWidget);
    expect(find.text('导入的权益上打过的 3 次卡也一起删了'), findsOneWidget);
    expect(find.text('「88VIP」导入之后又改过，没动它；要改回去请自己改。'), findsOneWidget);
    expect(find.text('「88 折购物券」导入之后已经被删了，没法改回去。'), findsOneWidget, reason: '被删了和被改了分开说');
    expect(find.text('「饿了么」还有卡挂在它下面，或者有权益要去它那领，留着了。'), findsOneWidget);
    expect(find.text('「三选一」下面还有你后来加的选项，还是「N 选 1」，没改回去。'), findsOneWidget);
    expect(find.text('「iPhone」卖出时记过收入，留着了（买它时记的那笔支出也留着）。'), findsOneWidget);
  });

  testWidgets('撤销失败：超过 7 天行内说原因、按钮还在；回应丢了说不确定，再点一次（服务端撤过的原样回）', (tester) async {
    final backend = undoBackend();
    await importAndShowResult(tester, backend, orderDraft());
    backend.failNext['POST /asset-import/imp-order/undo'] = (409, 'undo_expired', '导入超过 7 天了');
    await confirmUndo(tester);
    expect(find.text('导入超过 7 天了，不能整批撤销；去对应的卡、物品里逐条改。'), findsOneWidget);
    expect(find.byKey(const ValueKey('perk-import-undo')), findsOneWidget);

    backend.dropResponseNext.add('POST /asset-import/imp-order/undo');
    await confirmUndo(tester);
    expect(find.text('没等到服务器回应，不确定撤掉没有。再点一次也不会多撤。'), findsOneWidget);
    expect(backend.assets, isEmpty, reason: '第一次其实撤掉了，只是回应丢了');
    await confirmUndo(tester);
    expect(backend.imports.undoCalls, ['imp-order', 'imp-order'], reason: '过期那次在假服务端门口就挡了；回应丢的那次和重试各一次');
    expect(find.byKey(const ValueKey('perk-import-undone-title')), findsOneWidget);
    expect(find.text('删掉：物品 1 件'), findsOneWidget, reason: '服务端原样回上次撤了什么（replayed），不是「没有要删的」');
  });

  for (final size in kWidths) {
    testWidgets('宽 ${size.width}、字号 1.5 倍：结果页和撤完之后的说明都不溢出', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final backend = undoBackend();
      backend.imports.undoExtra = {
        'skippedChanged': [
          {'table': 'memberships', 'id': 'vip', 'name': '88VIP 联名卡（导入后改过备注）', 'deleted': false},
        ],
        'skippedInUse': [
          {'table': 'platforms', 'id': 'p-imp-p3', 'name': '饿了么', 'reason': 'in_use'},
        ],
      };
      await importAndShowResult(tester, backend, vip88Draft(), size: size);
      expect(tester.takeException(), isNull);
      await confirmUndo(tester);
      expect(find.byKey(const ValueKey('perk-import-undone-changed')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
