import 'package:famledger/ui/perk_import/recent_imports_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assets_harness.dart';
import 'perks_fake.dart';

// 「最近的 AI 导入」（spec §1「7 天内可以整批撤销」、§4 `GET /asset-import/recent`）：会员权益 tab 和物品 tab 的溢出菜单都能进；
// 列出 7 天内导入了、还没撤销的（什么时候、从哪导的、新建和更新了什么、还能撤几天；管理员看到家里人的写明是谁导的）；
// 撤销和结果页同一套 —— 先确认、撤完原地说撤了什么、哪些没动；过期行内说；三种宽度、1.5 倍字号不溢出。

Map<String, dynamic> recentJson(
  String id, {
  String sourceKind = 'text',
  bool mine = true,
  String memberName = '妈妈',
  int daysLeft = 6,
  Map<String, int> created = const {'platforms': 1, 'memberships': 1, 'benefits': 3, 'items': 0, 'transactions': 0},
  Map<String, int> updated = const {'platforms': 0, 'memberships': 0, 'benefits': 0},
}) => {
  'importId': id,
  'memberId': mine ? 'm1' : 'm2',
  'memberName': memberName,
  'mine': mine,
  'sourceKind': sourceKind,
  'createdAt': '2026-09-22T05:55:00.000Z',
  'appliedAt': '2026-09-22T06:03:00.000Z',
  'created': created,
  'updated': updated,
  'daysLeft': daysLeft,
};

AssetsBackend recentBackend(List<Map<String, dynamic>> recent) {
  final backend = AssetsBackend(perks: PerksFake(platforms: [platformJson('tb')]));
  backend.imports.recent = recent;
  return backend;
}

Future<void> openFromMenu(WidgetTester tester, AssetsBackend backend, {String role = 'admin', String tab = 'perks', Size size = const Size(400, 1600)}) async {
  await pumpAssetsAt(tester, bootAssets(backend, session: await sessionAs(role)), tab == 'perks' ? '/assets?tab=perks' : '/assets', size: size);
  await tester.tap(find.byKey(ValueKey(tab == 'perks' ? 'perks-menu' : 'items-menu')));
  await settle(tester);
  await tester.tap(find.byKey(const ValueKey('menu-recent-imports')));
  await settle(tester);
  expect(find.byType(RecentImportsPage), findsOneWidget);
}

Future<void> confirmUndo(WidgetTester tester, String id) async {
  await tapVisible(tester, find.byKey(ValueKey('recent-undo-$id')));
  expect(find.text('撤销这次导入？'), findsOneWidget);
  await tester.tap(find.byKey(const ValueKey('perk-import-undo-confirm')));
  await settle(tester);
}

void main() {
  testWidgets('会员权益 tab 的溢出菜单 →「最近的 AI 导入」：一次导入一段，写清什么时候、截图还是粘贴、新建更新了什么、还能撤几天；管理员看到家里人导的写明是谁', (tester) async {
    final backend = recentBackend([
      recentJson('imp-a', sourceKind: 'image', updated: const {'platforms': 0, 'memberships': 1, 'benefits': 2}),
      recentJson('imp-b', mine: false, memberName: '小红', daysLeft: 1, created: const {'platforms': 0, 'memberships': 0, 'benefits': 0, 'items': 2, 'transactions': 1}),
    ]);
    await openFromMenu(tester, backend);
    expect(backend.requests('GET', '/asset-import/recent'), hasLength(1));
    expect(find.textContaining('截图导入'), findsOneWidget);
    expect(find.textContaining('粘贴导入'), findsOneWidget);
    expect(find.text('新建：平台 1 个、会员卡 1 张、权益 3 项'), findsOneWidget);
    expect(find.text('更新：会员卡 1 张、权益 2 项'), findsOneWidget);
    expect(find.text('还能撤 6 天'), findsOneWidget);
    expect(find.text('新建：物品 2 件'), findsOneWidget);
    expect(find.text('同时记了 1 笔支出'), findsOneWidget);
    expect(find.text('还能撤 1 天 · 小红导入的'), findsOneWidget);
    expect(find.textContaining('家里 7 天内导进来的都在这'), findsOneWidget);
  });

  testWidgets('网址、从流水导入的写成「网址导入」「流水导入」', (tester) async {
    await openFromMenu(tester, recentBackend([recentJson('imp-u', sourceKind: 'url'), recentJson('imp-t', sourceKind: 'transactions')]));
    expect(find.textContaining('网址导入'), findsOneWidget);
    expect(find.textContaining('流水导入'), findsOneWidget);
    expect(find.textContaining('粘贴导入'), findsNothing);
  });

  testWidgets('撤销：先问，「不撤了」什么都不发；确认后原地换成「已撤销」和撤了什么、没动什么，按钮没了；别的那条照旧能撤', (tester) async {
    final backend = recentBackend([recentJson('imp-a'), recentJson('imp-b')]);
    backend.imports.undoExtra = {
      'undone': {'platforms': 1, 'memberships': 1, 'benefits': 3, 'items': 0, 'transactions': 0, 'events': 0},
      'skippedChanged': [
        {'table': 'memberships', 'id': 'vip', 'name': '88VIP', 'deleted': false},
      ],
    };
    await openFromMenu(tester, backend);
    await tapVisible(tester, find.byKey(const ValueKey('recent-undo-imp-a')));
    await tester.tap(find.text('不撤了'));
    await settle(tester);
    expect(backend.imports.undoCalls, isEmpty);

    await confirmUndo(tester, 'imp-a');
    expect(backend.imports.undoCalls, ['imp-a']);
    expect(find.byKey(const ValueKey('recent-undone-imp-a')), findsOneWidget);
    expect(find.text('删掉：平台 1 个、会员卡 1 张、权益 3 项'), findsOneWidget);
    expect(find.text('「88VIP」导入之后又改过，没动它；要改回去请自己改。'), findsOneWidget);
    expect(find.byKey(const ValueKey('recent-undo-imp-a')), findsNothing, reason: '撤过了，不再给按钮');
    expect(find.byKey(const ValueKey('recent-undo-imp-b')), findsOneWidget);
    expect(backend.requests('GET', '/changes').length, greaterThan(1), reason: '撤完同步一次，删掉的跟着没了');
  });

  testWidgets('物品 tab 的溢出菜单也能进；普通成员的说明写「你」', (tester) async {
    final backend = recentBackend([recentJson('imp-a', created: const {'items': 1})]);
    await openFromMenu(tester, backend, role: 'member', tab: 'items');
    expect(find.text('新建：物品 1 件'), findsOneWidget);
    expect(find.textContaining('你 7 天内导进来的都在这'), findsOneWidget);
  });

  testWidgets('撤销失败：超过 7 天行内说原因、按钮还在', (tester) async {
    final backend = recentBackend([recentJson('imp-a')]);
    await openFromMenu(tester, backend);
    backend.failNext['POST /asset-import/imp-a/undo'] = (409, 'undo_expired', '导入超过 7 天了');
    await confirmUndo(tester, 'imp-a');
    expect(find.text('导入超过 7 天了，不能整批撤销；去对应的卡、物品里逐条改。'), findsOneWidget);
    expect(find.byKey(const ValueKey('recent-undo-imp-a')), findsOneWidget);
  });

  testWidgets('7 天内没有导入 → 空态一句话 + 去智能导入', (tester) async {
    final empty = recentBackend([]);
    await openFromMenu(tester, empty);
    expect(find.byKey(const ValueKey('recent-imports-empty')), findsOneWidget);
    expect(find.text('7 天内没有能撤销的导入'), findsOneWidget);
    expect(find.text('去智能导入'), findsOneWidget);
  });

  testWidgets('列表拉不下来：行内说原因 + 重试', (tester) async {
    final backend = recentBackend([recentJson('imp-a')]);
    backend.failNext['GET /asset-import/recent'] = (500, 'internal', '服务器出错了');
    await openFromMenu(tester, backend);
    expect(find.text('服务器出错了'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await settle(tester);
    expect(find.byKey(const ValueKey('recent-undo-imp-a')), findsOneWidget);
  });

  for (final size in kWidths) {
    testWidgets('宽 ${size.width}、字号 1.5 倍：列表和撤完的说明都不溢出', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final backend = recentBackend([
        recentJson('imp-a', sourceKind: 'image', created: const {'platforms': 12, 'memberships': 8, 'benefits': 120, 'items': 30, 'transactions': 3}),
        recentJson('imp-b', mine: false, memberName: '家里的长辈账号'),
      ]);
      backend.imports.undoExtra = {
        'skippedInUse': [
          {'table': 'platforms', 'id': 'p1', 'name': '一个名字特别长的平台（天猫超市）', 'reason': 'in_use'},
        ],
      };
      await openFromMenu(tester, backend, size: size);
      expect(tester.takeException(), isNull);
      await confirmUndo(tester, 'imp-a');
      expect(find.byKey(const ValueKey('recent-undone-imp-a')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
