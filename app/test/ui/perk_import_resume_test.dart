import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/ui/perk_import/draft_store.dart';
import 'package:famledger/ui/perk_import/perk_import_draft.dart';
import 'package:famledger/ui/perk_import/perk_import_preview_page.dart';
import 'package:famledger/ui/perk_import/perk_import_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assets_harness.dart';
import 'perk_import_fixtures.dart';
import 'perks_fake.dart';

// 预览草稿防丢（spec §6「草稿同时存一份到本机……意外关闭后可以恢复；apply 成功后清掉」）：核对页每改一次存一份（防抖，
// 离开页面时还没落盘的补一次）；输入页顶上给「继续核对 / 不要了」；网页刷新到核对页时原地接着核对；导入成功、选「不导了」、
// 服务端说这批已经导过 / 撤销了 / 不在了都清掉；三种宽度、1.5 倍字号不溢出。

AssetsBackend resumeBackend() => AssetsBackend(
  perks: PerksFake(platforms: [platformJson('tb'), platformJson('yk', name: '优酷', sort: 1)]),
);

Future<Map<String, dynamic>?> savedJson(LocalStore store) => store.read<Map<String, dynamic>>(kPerkImportDraftKey);

Future<ProviderContainer> openPreviewWith(WidgetTester tester, AssetsBackend backend, LocalStore store, PerkImportDraft draft) async {
  final container = bootAssets(backend, store: store);
  container.listen(pendingPerkImportProvider, (_, _) {});
  container.read(pendingPerkImportProvider.notifier).state = draft;
  await pumpAssetsAt(tester, container, '/assets/import/preview', size: const Size(400, 2400));
  return container;
}

void main() {
  bool b2Checked(Map<String, dynamic> saved) =>
      (saved['benefits'] as List).cast<Map<String, dynamic>>().firstWhere((b) => b['key'] == 'b2')['checked'] as bool;

  testWidgets('核对页一打开就存一份，改一项防抖之后再存（没到点不存）；存的是改过的样子', (tester) async {
    final store = MemoryLocalStore();
    await openPreviewWith(tester, resumeBackend(), store, PerkImportDraft.fromJson(vip88Draft(), clientId: 'cid-r'));
    final first = (await savedJson(store))!;
    expect([first['importId'], first['clientId']], ['imp-vip', 'cid-r']);
    await tester.ensureVisible(find.byKey(const ValueKey('import-check-b2')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('import-check-b2')));
    await tester.pump(PerkImportPreviewPage.saveDelay - const Duration(milliseconds: 100));
    expect(b2Checked((await savedJson(store))!), isTrue, reason: '防抖还没到点');
    await tester.pump(const Duration(milliseconds: 150));
    expect(b2Checked((await savedJson(store))!), isFalse);
  });

  testWidgets('改完还没到防抖就离开了（页面被拆掉）：走之前补存一次', (tester) async {
    final store = MemoryLocalStore();
    await openPreviewWith(tester, resumeBackend(), store, PerkImportDraft.fromJson(vip88Draft(), clientId: 'cid-r'));
    await tester.ensureVisible(find.byKey(const ValueKey('import-check-b2')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('import-check-b2')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(b2Checked((await savedJson(store))!), isFalse, reason: 'dispose 时把没落盘的补上');
  });

  testWidgets('网页刷新到核对页（交过来的草稿没了）：本机存着就原地接着核对；也没存着才请人回导入页', (tester) async {
    final store = MemoryLocalStore();
    final draft = PerkImportDraft.fromJson(vip88Draft(), clientId: 'cid-refresh');
    draft.setChecked('b2', false);
    await PerkImportDraftStore(store, clock: () => testNow).save(draft);
    final backend = resumeBackend();
    await pumpAssetsAt(tester, bootAssets(backend, store: store), '/assets/import/preview', size: const Size(400, 2400));
    expect(find.byType(PerkImportPreviewPage), findsOneWidget);
    expect(tester.widget<Checkbox>(find.byKey(const ValueKey('import-check-b2'))).value, isFalse, reason: '改过的还在');
    await tapVisible(tester, find.byKey(const ValueKey('perk-import-submit')));
    expect(backend.imports.applyBodies.single['clientId'], 'cid-refresh', reason: '用的还是原来的 clientId');
  });

  testWidgets('网页刷新到核对页、本机也没存着：说清楚，给「回导入页」', (tester) async {
    await pumpAssetsAt(tester, bootAssets(resumeBackend()), '/assets/import/preview');
    expect(find.byKey(const ValueKey('perk-import-preview-lost')), findsOneWidget);
    expect(find.text('回导入页'), findsOneWidget);
    expect(find.text('去粘贴'), findsNothing);
  });

  testWidgets('意外关掉后再进输入页：顶上「继续核对」→ 改过的都在，导入用的还是原来的 clientId → 导完清掉本机那份', (tester) async {
    final store = MemoryLocalStore();
    final draft = PerkImportDraft.fromJson(vip88Draft(), clientId: 'cid-old');
    draft.setChecked('b2', false);
    await PerkImportDraftStore(store, clock: () => testNow).save(draft);
    final backend = resumeBackend();
    await pumpAssetsAt(tester, bootAssets(backend, store: store, session: await sessionAs('admin')), '/assets/import');
    expect(find.byKey(const ValueKey('import-saved')), findsOneWidget);
    expect(find.textContaining('上次还有一份没导完的识别结果'), findsOneWidget);
    expect(find.textContaining('勾了 ${draft.includedCount} 项'), findsOneWidget);
    await tapVisible(tester, find.byKey(const ValueKey('import-saved-resume')));
    expect(find.byType(PerkImportPreviewPage), findsOneWidget);
    expect(tester.widget<Checkbox>(find.byKey(const ValueKey('import-check-b2'))).value, isFalse, reason: '改过的还在');
    await tapVisible(tester, find.byKey(const ValueKey('perk-import-submit')));
    expect(find.byKey(const ValueKey('perk-import-result-title')), findsOneWidget);
    expect(backend.imports.applyBodies.single['clientId'], 'cid-old');
    expect(await savedJson(store), isNull, reason: '导进去了就清掉');
  });

  testWidgets('「不要了」清掉本机那份、横幅消失', (tester) async {
    final store = MemoryLocalStore();
    await PerkImportDraftStore(store, clock: () => testNow).save(PerkImportDraft.fromJson(orderDraft()));
    await pumpAssetsAt(tester, bootAssets(resumeBackend(), store: store, session: await sessionAs('admin')), '/assets/import');
    await tapVisible(tester, find.byKey(const ValueKey('import-saved-drop')));
    expect(find.byKey(const ValueKey('import-saved')), findsNothing);
    expect(await savedJson(store), isNull);
  });

  testWidgets('核对页选「不导了」→ 清掉本机那份', (tester) async {
    final store = MemoryLocalStore();
    await openPreviewWith(tester, resumeBackend(), store, PerkImportDraft.fromJson(vip88Draft()));
    expect(await savedJson(store), isNotNull);
    await tester.pageBack();
    await settle(tester);
    await tester.tap(find.text('不导了'));
    await settle(tester);
    expect(await savedJson(store), isNull);
  });

  testWidgets('恢复的是截图草稿：依据块按存下来的叫法说是哪一片、说明恢复的草稿没带截图；这批在别处导过（import_used）→ 清掉本机那份', (tester) async {
    final store = MemoryLocalStore();
    await PerkImportDraftStore(store, clock: () => testNow)
        .save(PerkImportDraft.fromJson(orderImageDraft(), imageLabels: const ['图 1 的第 1/2 片', '图 1 的第 2/2 片']));
    final backend = resumeBackend();
    await pumpAssetsAt(tester, bootAssets(backend, store: store, session: await sessionAs('admin')), '/assets/import');
    await tapVisible(tester, find.byKey(const ValueKey('import-saved-resume')));
    await tapVisible(tester, find.byKey(const ValueKey('import-node-i1')));
    expect(find.text('出自图 1 的第 2/2 片（恢复的草稿没带截图，对照原图看）。'), findsOneWidget);
    expect(find.byKey(const ValueKey('evidence-image')), findsNothing);
    await tester.tap(find.text('好了'));
    await settle(tester);
    backend.imports.applyError = {'code': 'import_used', 'message': '这批识别结果已经导入过了'};
    await tapVisible(tester, find.byKey(const ValueKey('perk-import-submit')));
    expect(find.text('这批识别结果已经导入过了，去看看有没有；要重来得重新识别一次。'), findsOneWidget);
    expect(await savedJson(store), isNull);
  });

  for (final (code, message, shown) in const [
    ('import_undone', '这批导入已经撤销了', '这批导入已经撤销了；要再导得重新识别一次。'),
    ('not_found', '这批识别结果不在了', '这批识别结果在服务器上找不到了（超过 90 天会清掉），重新识别一次吧。'),
  ]) {
    testWidgets('恢复的草稿导入时服务端回 $code：说清楚，清掉本机那份（下次不再冒出「继续核对」）', (tester) async {
      final store = MemoryLocalStore();
      await PerkImportDraftStore(store, clock: () => testNow).save(PerkImportDraft.fromJson(orderDraft()));
      final backend = resumeBackend();
      await pumpAssetsAt(tester, bootAssets(backend, store: store, session: await sessionAs('admin')), '/assets/import');
      await tapVisible(tester, find.byKey(const ValueKey('import-saved-resume')));
      backend.imports.applyError = {'code': code, 'message': message};
      await tapVisible(tester, find.byKey(const ValueKey('perk-import-submit')));
      expect(find.text(shown), findsOneWidget);
      expect(await savedJson(store), isNull);
    });
  }

  for (final size in kWidths) {
    testWidgets('宽 ${size.width}、字号 1.5 倍：输入页顶上的「继续核对」横幅不溢出', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final store = MemoryLocalStore();
      await PerkImportDraftStore(store, clock: () => testNow).save(PerkImportDraft.fromJson(vip88Draft()));
      await pumpAssetsAt(tester, bootAssets(resumeBackend(), store: store, session: await sessionAs('admin')), '/assets/import', size: size);
      expect(find.byKey(const ValueKey('import-saved')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
