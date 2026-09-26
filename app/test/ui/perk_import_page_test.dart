import 'dart:async';

import 'package:famledger/data/api/api_client.dart';
import 'package:famledger/data/models/models.dart';
import 'package:famledger/data/repos/asset_import_repo.dart';
import 'package:famledger/data/repos/ledger_repo.dart';
import 'package:famledger/ui/perk_import/perk_import_preview_page.dart';
import 'package:famledger/ui/perk_import/perk_import_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assets_harness.dart';
import 'import_fake.dart';
import 'perk_import_fixtures.dart';
import 'perks_fake.dart';

// AI 导入的输入页和进度（spec §6「输入页」「识别中」）：只开放「粘贴」、识别范围 chip、渠道 chip（没有渠道时去设置）、
// token 估算、SSE 进度可取消、识别失败 / 连接断了留在输入页、指定卡。四个入口在 perk_import_entry_test.dart。

AssetsBackend importBackend({Map<String, dynamic>? draft, ImportFake? imports}) {
  final backend = AssetsBackend(
    perks: PerksFake(platforms: [platformJson('tb'), platformJson('yk', name: '优酷', sort: 1)]),
    imports: imports,
  );
  backend.imports.draft = draft ?? vip88Draft();
  return backend;
}

Future<void> typeSource(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const ValueKey('import-text')), text);
  await tester.pump();
}

void main() {
  testWidgets('输入页：只有「粘贴」，识别范围按入口预选，渠道默认选中，写出 token 估算；识别完进预览', (tester) async {
    final backend = importBackend(draft: orderDraft());
    await pumpAssetsAt(tester, bootAssets(backend, session: await sessionAs('admin')), '/assets/import?want=items');
    expect(find.text('智能导入'), findsOneWidget);
    expect(find.text('截图'), findsNothing, reason: '截图、网址、从流水在 P5 / P7，不放半成品入口');
    expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('import-want-items'))).selected, isTrue);
    expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('import-provider-ai-1'))).selected, isTrue);
    expect(find.text('识别完先在预览里逐条核对，确认了才会落库。'), findsOneWidget, reason: '先识别、后核对（Review ⑯ 的文案）');

    await typeSource(tester, orderSource);
    expect(find.textContaining('预计输入约'), findsOneWidget);
    await tapVisible(tester, find.byKey(const ValueKey('import-start')));
    expect(backend.imports.extractBodies.single, {'kind': 'text', 'text': orderSource, 'want': 'items', 'providerId': 'ai-1'});
    expect(find.byType(PerkImportPreviewPage), findsOneWidget);
    expect(find.text('实物 · 1 件'), findsOneWidget);
  });

  testWidgets('没有可用的 AI 渠道：说清楚、管理员给「去设置 AI 渠道」，开始识别点不了', (tester) async {
    final backend = importBackend(imports: ImportFake(providers: const []));
    await pumpAssetsAt(tester, bootAssets(backend, session: await sessionAs('admin')), '/assets/import');
    expect(find.byKey(const ValueKey('import-no-provider')), findsOneWidget);
    expect(find.text('去设置 AI 渠道'), findsOneWidget);
    await typeSource(tester, vip88Source);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('import-start'))).onPressed, isNull);
  });

  testWidgets('识别失败：行内说原因，粘贴的内容都在，改完能再试', (tester) async {
    final backend = importBackend();
    backend.imports.extractError = ('ai_bad_output', '模型没有按要求返回结果，换个渠道或把材料删短一点再试');
    await pumpAssetsAt(tester, bootAssets(backend), '/assets/import');
    await typeSource(tester, vip88Source);
    await tapVisible(tester, find.byKey(const ValueKey('import-start')));
    expect(find.text('模型没有按要求返回结果，换个渠道或把材料删短一点再试'), findsOneWidget);
    expect(find.text(vip88Source), findsOneWidget, reason: '粘贴的内容都还在');
    backend.imports.extractError = null;
    await tapVisible(tester, find.byKey(const ValueKey('import-start')));
    expect(find.byType(PerkImportPreviewPage), findsOneWidget);
  });

  testWidgets('识别到一半连接断了（Review Focus ②）：说清楚没记账、内容都在，再点一次照常', (tester) async {
    final backend = importBackend();
    backend.imports.cutNextStream = true;
    await pumpAssetsAt(tester, bootAssets(backend), '/assets/import');
    await typeSource(tester, vip88Source);
    await tapVisible(tester, find.byKey(const ValueKey('import-start')));
    expect(find.text('识别到一半连接断了，再试一次；已经识别的不会记账。'), findsOneWidget);
    expect(find.text(vip88Source), findsOneWidget);
    await tapVisible(tester, find.byKey(const ValueKey('import-start')));
    expect(find.byType(PerkImportPreviewPage), findsOneWidget);
    expect(backend.imports.extractBodies, hasLength(2));
  });

  testWidgets('进度页能取消：回到输入页、内容都在，迟到的结果不再把预览叠上来', (tester) async {
    final backend = importBackend();
    backend.delayNext['POST /asset-import/extract'] = const Duration(seconds: 2);
    await pumpAssetsAt(tester, bootAssets(backend), '/assets/import');
    await typeSource(tester, vip88Source);
    await tester.tap(find.byKey(const ValueKey('import-start')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('正在识别…'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('import-cancel')));
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('正在识别…'), findsNothing);
    expect(find.text(vip88Source), findsOneWidget);
    expect(find.byType(PerkImportPreviewPage), findsNothing);
  });

  testWidgets('进度页（Review ㉚）：边收边写「已识别 N 条」，收到 done 才进预览', (tester) async {
    final backend = importBackend();
    final events = StreamController<ImportEvent>();
    addTearDown(events.close);
    final container = bootAssets(backend, overrides: [assetImportRepoProvider.overrideWithValue(_StreamRepo(events.stream))]);
    await pumpAssetsAt(tester, container, '/assets/import');
    await typeSource(tester, vip88Source);
    await tapVisible(tester, find.byKey(const ValueKey('import-start')));
    expect(find.text('正在请模型识别…'), findsOneWidget);
    events.add(const ImportProgress(3));
    await tester.pump();
    expect(find.text('已识别 3 条'), findsOneWidget);
    events.add(const ImportProgress(9));
    await tester.pump();
    expect(find.text('已识别 9 条'), findsOneWidget);
    expect(find.byType(PerkImportPreviewPage), findsNothing);
    events.add(ImportDone('imp-vip', vip88Draft()));
    await settle(tester);
    expect(find.byType(PerkImportPreviewPage), findsOneWidget);
  });

  testWidgets('指定卡（?membership=）：写明归到哪张卡、不给识别范围，请求带 targetMembershipId、want 固定 virtual', (tester) async {
    final backend = importBackend();
    backend.perks.memberships['vip'] = membershipJson('vip');
    await pumpAssetsAt(tester, bootAssets(backend), '/assets/import?membership=vip');
    expect(find.text('补充权益'), findsOneWidget);
    expect(find.text('识别出的权益都归到「88VIP」，导入前可以逐条改。'), findsOneWidget);
    expect(find.byKey(const ValueKey('import-want-auto')), findsNothing);
    await typeSource(tester, vip88Source);
    await tapVisible(tester, find.byKey(const ValueKey('import-start')));
    expect(backend.imports.extractBodies.single['targetMembershipId'], 'vip');
    expect(backend.imports.extractBodies.single['want'], 'virtual');
  });

  testWidgets('超过 12000 字提示只挑相关段落；输入框最多收 20000 字', (tester) async {
    await pumpAssetsAt(tester, bootAssets(importBackend()), '/assets/import');
    await typeSource(tester, '字' * 12001);
    expect(find.text('超过 12000 字，只会挑最相关的段落发给模型。'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('import-text'))).maxLength, 20000);
  });

  for (final size in kWidths) {
    testWidgets('宽 ${size.width}：输入页和进度页都不溢出', (tester) async {
      final backend = importBackend();
      backend.delayNext['POST /asset-import/extract'] = const Duration(seconds: 2);
      await pumpAssetsAt(tester, bootAssets(backend, session: await sessionAs('admin')), '/assets/import', size: size);
      await typeSource(tester, vip88Source);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byKey(const ValueKey('import-start')));
      await tester.tap(find.byKey(const ValueKey('import-start')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('正在识别…'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 3));
      await settle(tester);
    });
  }
}

/// 识别流由测试一条条喂（假服务端的 SSE 是一次性整段回的，看不到「边收边写」）。
class _StreamRepo extends AssetImportRepo {
  _StreamRepo(this.events) : super(api: ApiClient(baseUrl: 'https://x.dev'), ledger: _NoLedger());

  final Stream<ImportEvent> events;

  @override
  Stream<ImportEvent> extract({required String text, ImportWant want = ImportWant.auto, String? targetMembershipId, String? providerId}) => events;
}

class _NoLedger implements LedgerRepo {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
