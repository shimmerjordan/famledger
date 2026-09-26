import 'dart:async';
import 'dart:convert';

import 'package:famledger/ui/perk_import/perk_import_draft.dart';
import 'package:famledger/ui/perk_import/perk_import_preview_page.dart';
import 'package:famledger/ui/perk_import/perk_import_providers.dart';
import 'package:famledger/ui/perk_import/screenshots.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assets_harness.dart';
import 'import_fake.dart';
import 'perk_import_fixtures.dart';
import 'perks_fake.dart';
import 'screenshot_fixtures.dart';

// 输入页的「截图」分段（spec §6「截图」、§7 P5 验收「1080×8000 的截图能正常导入」「订单截图能导成物品」）：选图、切片缩略图、
// 删单片（一张原图删光了就不占名额）、合计几片、超过 8 片 / 合计太大挡住（原因写在按钮旁边）、一次最多 6 张、打不开的图单独说、
// 处理进度和处理中清空；截图模式只列没测出「看不了图」的渠道（都看不了：管理员 / 成员各说各的、一键改用粘贴）；识别请求带 PNG；
// 413 / provider_no_vision 说人话；预览里依据块显示出自的那片截图（按「图 N 的第 k/n 片」说、点开能放大），顶上整批说一次
// 「截图没法逐字核对」而不是每条挂「依据未核实」，截断横幅按「没续写 / 续写了还没写完 / 续写出错」「截图 / 粘贴」换说法。

const Map<String, dynamic> _visionOff = {'vision': false};

AssetsBackend shotBackend({Map<String, dynamic>? draft, List<Map<String, dynamic>>? providers}) {
  final backend = AssetsBackend(
    perks: PerksFake(platforms: [platformJson('tb')]),
    imports: ImportFake(providers: providers),
  );
  backend.imports.draft = draft ?? orderImageDraft();
  return backend;
}

Future<void> openShots(
  WidgetTester tester,
  AssetsBackend backend, {
  ScreenshotPicker? picker,
  ScreenshotPreparer? preparer,
  String location = '/assets/import?want=items',
}) async {
  await pumpAssetsAt(
    tester,
    bootAssets(
      backend,
      session: await sessionAs('admin'),
      overrides: [
        screenshotPickerProvider.overrideWithValue(picker ?? pickerOf([PickedScreenshot(name: 'order.png', bytes: tinyPng)])),
        screenshotPreparerProvider.overrideWithValue(preparer ?? fakePreparer()),
      ],
    ),
    location,
  );
  await tapVisible(tester, find.byKey(const ValueKey('import-source-image')));
}

bool startEnabled(WidgetTester tester) => tester.widget<FilledButton>(find.byKey(const ValueKey('import-start'))).onPressed != null;

bool pickEnabled(WidgetTester tester) =>
    tester.widget<ButtonStyleButton>(find.byKey(const ValueKey('import-pick-shots'))).onPressed != null;

/// 预览页直接打开一份截图草稿。
Future<void> openImagePreview(WidgetTester tester, Map<String, dynamic> json, {List<String> labels = const [], Size size = const Size(400, 2000)}) async {
  final container = bootAssets(shotBackend());
  container.listen(pendingPerkImportProvider, (_, _) {});
  container.read(pendingPerkImportProvider.notifier).state =
      PerkImportDraft.fromJson(json, clientId: 'cid-shot', images: [tinyPng, tinyPng], imageLabels: labels);
  await pumpAssetsAt(tester, container, '/assets/import/preview', size: size);
}

void main() {
  testWidgets('截图：选图 → 4 片缩略图、合计和 token 估算；删一片剩 3 片；开始识别发 3 张 PNG → 预览里依据块是出自的那片', (tester) async {
    final backend = shotBackend();
    await openShots(tester, backend);
    expect(find.text('选截图'), findsOneWidget);
    expect(startEnabled(tester), isFalse, reason: '还没选图');
    expect(find.textContaining('手机号、卡号不会自动打码'), findsOneWidget);

    await tapVisible(tester, find.byKey(const ValueKey('import-pick-shots')));
    for (final id in ['0-0', '0-1', '0-2', '0-3']) {
      expect(find.byKey(ValueKey('shot-$id')), findsOneWidget);
    }
    expect(find.text('图 1 · 3/4'), findsOneWidget);
    expect(find.text('4 片 · 约 0.0MB'), findsOneWidget);
    expect(find.text('预计输入约 ${1500 + 4 * 1640} token，最多输出 12000 token。'), findsOneWidget);

    await tapVisible(tester, find.byKey(const ValueKey('shot-remove-0-2')));
    expect(find.byKey(const ValueKey('shot-0-2')), findsNothing);
    expect(find.text('3 片 · 约 0.0MB'), findsOneWidget);

    await tapVisible(tester, find.byKey(const ValueKey('import-start')));
    final body = backend.imports.extractBodies.single;
    expect(body['kind'], 'image');
    expect(body['want'], 'items');
    expect(body['providerId'], 'ai-1');
    expect(body.containsKey('text'), isFalse);
    expect(body['images'], [
      for (var i = 0; i < 3; i++) {'mediaType': 'image/png', 'data': base64Encode(tinyPng)},
    ]);
    expect(find.byType(PerkImportPreviewPage), findsOneWidget);
    expect(find.text('实物 · 1 件'), findsOneWidget);
    // 依据块：i1 出自第 2 块 = 发出去的第 2 片（删掉 0-2 之后是「图 1 的第 2/4 片」），显示的就是那片
    await tapVisible(tester, find.byKey(const ValueKey('import-node-i1')));
    expect(find.byKey(const ValueKey('evidence-image')), findsOneWidget);
    expect(find.text('出自图 1 的第 2/4 片，点图放大看。'), findsOneWidget);
  });

  testWidgets('截图模式只列没测出「看不了图」的渠道：默认那个看不了图就选第一个能用的，没测过的也列', (tester) async {
    final backend = shotBackend(providers: [
      {'id': 'ai-1', 'name': 'DeepSeek', 'kind': 'openai', 'model': 'deepseek-chat', 'isDefault': true, 'enabled': true, 'hasKey': true, 'extra': _visionOff},
      {'id': 'ai-2', 'name': '家里的 cc-trans', 'kind': 'anthropic', 'model': 'claude-sonnet-5', 'enabled': true, 'hasKey': true, 'extra': {'vision': true}},
      {'id': 'ai-3', 'name': '没测过的', 'kind': 'openai', 'model': 'qwen-vl', 'enabled': true, 'hasKey': true},
    ]);
    await openShots(tester, backend);
    expect(find.byKey(const ValueKey('import-provider-ai-1')), findsNothing);
    expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('import-provider-ai-2'))).selected, isTrue, reason: '默认那个看不了图，选第一个能用的');
    expect(find.byKey(const ValueKey('import-provider-ai-3')), findsOneWidget, reason: '没测过的也列（vision != false）');
    await tapVisible(tester, find.byKey(const ValueKey('import-pick-shots')));
    await tapVisible(tester, find.byKey(const ValueKey('import-start')));
    expect(backend.imports.extractBodies.single['providerId'], 'ai-2');
  });

  testWidgets('渠道都测出来看不了图（管理员）：说清楚、给「去设置 AI 渠道」，开始识别点不了；「改用粘贴」一键切过去，照常列出渠道', (tester) async {
    final blind = shotBackend(providers: [
      {'id': 'ai-1', 'name': 'DeepSeek', 'kind': 'openai', 'model': 'deepseek-chat', 'isDefault': true, 'enabled': true, 'hasKey': true, 'extra': _visionOff},
    ]);
    await openShots(tester, blind);
    expect(find.byKey(const ValueKey('import-no-vision')), findsOneWidget);
    expect(find.textContaining('重新点「测看图」'), findsOneWidget);
    expect(find.byKey(const ValueKey('import-no-vision-settings')), findsOneWidget);
    await tapVisible(tester, find.byKey(const ValueKey('import-pick-shots')));
    expect(startEnabled(tester), isFalse);
    await tapVisible(tester, find.byKey(const ValueKey('import-no-vision-paste')));
    expect(find.byKey(const ValueKey('import-text')), findsOneWidget, reason: '切到了粘贴');
    expect(find.byKey(const ValueKey('import-provider-ai-1')), findsOneWidget, reason: '粘贴不挑看图');
  });

  testWidgets('渠道都测出来看不了图（普通成员）：请管理员加，不引去点只有管理员才有的按钮；一样能一键改用粘贴', (tester) async {
    final blind = shotBackend(providers: [
      {'id': 'ai-1', 'name': 'DeepSeek', 'kind': 'openai', 'model': 'deepseek-chat', 'isDefault': true, 'enabled': true, 'hasKey': true, 'extra': _visionOff},
    ]);
    await pumpAssetsAt(
      tester,
      bootAssets(blind, session: await sessionAs('member'), overrides: [screenshotPreparerProvider.overrideWithValue(fakePreparer())]),
      '/assets/import',
    );
    await tapVisible(tester, find.byKey(const ValueKey('import-source-image')));
    expect(find.text('家里现有的 AI 渠道都看不了图，请管理员加一个能看图的渠道。现在可以先把文字复制过来，改用粘贴。'), findsOneWidget);
    expect(find.textContaining('测看图'), findsNothing);
    expect(find.byKey(const ValueKey('import-no-vision-settings')), findsNothing);
    await tapVisible(tester, find.byKey(const ValueKey('import-no-vision-paste')));
    expect(find.byKey(const ValueKey('import-text')), findsOneWidget);
  });

  testWidgets('一次最多 6 张：选了 8 张只加前 6 张并说一声；切出超过 8 片挡住发送，删到 8 片放行；打不开的图单独说', (tester) async {
    final eight = [for (var i = 0; i < 8; i++) PickedScreenshot(name: 's$i.png', bytes: tinyPng)];
    final backend = shotBackend();
    await openShots(
      tester,
      backend,
      picker: pickerOf(eight),
      preparer: fakePreparer(perFile: 2, failed: const ['「s9.heic」打不开，换成 PNG 或 JPG 截图再试']),
    );
    await tapVisible(tester, find.byKey(const ValueKey('import-pick-shots')));
    expect(find.text('一次最多 6 张，只加了前 6 张'), findsOneWidget);
    expect(find.text('最多 6 张'), findsOneWidget);
    expect(pickEnabled(tester), isFalse, reason: '满了，选图按钮点不了');
    expect(find.text('12 片 · 约 0.0MB'), findsOneWidget);
    expect(find.textContaining('切出了 12 片，一次最多 8 片：删掉 4 片再开始'), findsOneWidget);
    expect(find.text('切出了 12 片，一次最多 8 片：先删掉 4 片再开始识别。'), findsOneWidget, reason: '挡住的原因写在开始识别旁边');
    expect(find.byKey(const ValueKey('import-estimate')), findsNothing);
    expect(find.text('「s9.heic」打不开，换成 PNG 或 JPG 截图再试'), findsOneWidget);
    expect(startEnabled(tester), isFalse);

    for (final id in ['5-1', '5-0', '4-1', '4-0']) {
      await tapVisible(tester, find.byKey(ValueKey('shot-remove-$id')));
    }
    expect(find.text('8 片 · 约 0.0MB'), findsOneWidget);
    expect(startEnabled(tester), isTrue);
    await tapVisible(tester, find.byKey(const ValueKey('shots-clear')));
    expect(find.text('选截图'), findsOneWidget);
    expect(startEnabled(tester), isFalse);
  });

  testWidgets('验收：1080×8000 的长截图 → 切成 4 片（每片 784×1568）→ 识别请求带 4 张 PNG → 预览 → 导入成物品', (tester) async {
    final long = (await tester.runAsync(() => stripedPng(1080, 8000)))!;
    final batch = (await tester.runAsync(() => prepareScreenshots([PickedScreenshot(name: 'order-long.png', bytes: long)])))!;
    expect(batch.slices.length, 4);
    final backend = shotBackend();
    await openShots(tester, backend, picker: pickerOf([PickedScreenshot(name: 'order-long.png', bytes: long)]), preparer: fixedPreparer(batch));
    await tapVisible(tester, find.byKey(const ValueKey('import-pick-shots')));
    expect(find.textContaining('4 片 · 约'), findsOneWidget);
    await tapVisible(tester, find.byKey(const ValueKey('import-start')));
    final images = (backend.imports.extractBodies.single['images'] as List).cast<Map<String, dynamic>>();
    expect(images, hasLength(4));
    for (final img in images) {
      expect(pngSize(base64Decode(img['data'] as String)), (784, 1568));
    }
    expect(find.byType(PerkImportPreviewPage), findsOneWidget);
    await tapVisible(tester, find.byKey(const ValueKey('perk-import-submit')));
    expect(find.text('导入好了'), findsOneWidget);
    expect(backend.assets.values.single['name'], 'iPhone 16 Pro 256GB');
    expect(backend.assets.values.single['transactionId'], 'tx-phone', reason: '订单截图导成物品，关联唯一那笔流水');
  });

  testWidgets('一张原图的片全删光：这张不再占 6 张的名额，后面的编号往前挪；再加图时，之前删掉的片照样不回来', (tester) async {
    final calls = <(int, Set<String>)>[];
    final six = [for (var i = 0; i < 6; i++) PickedScreenshot(name: 's$i.png', bytes: tinyPng)];
    var round = 0;
    await openShots(
      tester,
      shotBackend(),
      picker: () async => round++ == 0 ? six : [PickedScreenshot(name: 'extra.png', bytes: tinyPng)],
      preparer: fakePreparer(perFile: 2, calls: calls),
    );
    await tapVisible(tester, find.byKey(const ValueKey('import-pick-shots')));
    expect(pickEnabled(tester), isFalse, reason: '选满 6 张');
    await tapVisible(tester, find.byKey(const ValueKey('shot-remove-5-1'))); // 图 6 删一片
    await tapVisible(tester, find.byKey(const ValueKey('shot-remove-2-0')));
    await tapVisible(tester, find.byKey(const ValueKey('shot-remove-2-1'))); // 图 3 删光
    expect(pickEnabled(tester), isTrue, reason: '图 3 的片删光了，名额空出来');
    expect(find.text('再加几张'), findsOneWidget);
    expect(find.byKey(const ValueKey('shot-2-0')), findsOneWidget, reason: '原来的图 4 成了图 3');
    expect(find.text('图 5 · 1/2'), findsOneWidget, reason: '原来的图 6 只剩第 1 片，成了图 5');
    expect(find.byKey(const ValueKey('shot-4-1')), findsNothing);
    await tapVisible(tester, find.byKey(const ValueKey('import-pick-shots')));
    expect(calls.last.$1, 6, reason: '重切时 6 张原图');
    expect(calls.last.$2, {'4-1'}, reason: '原来删掉的「图 6 第 2 片」编号跟着挪成 4-1、照样跳过');
    expect(find.text('11 片 · 约 0.0MB'), findsOneWidget);
    expect(pickEnabled(tester), isFalse);
  });

  testWidgets('合计太大（降到 1024 还超）：挡住开始识别，原因写在按钮旁边', (tester) async {
    await openShots(tester, shotBackend(), preparer: fakePreparer(perFile: 2, totalBudget: 100));
    await tapVisible(tester, find.byKey(const ValueKey('import-pick-shots')));
    expect(startEnabled(tester), isFalse);
    expect(find.byKey(const ValueKey('import-blocked')), findsOneWidget);
    expect(find.text('截图合计 0.0MB 太大了，删掉几片再开始识别。'), findsOneWidget);
    await tapVisible(tester, find.byKey(const ValueKey('shot-remove-0-1')));
    expect(startEnabled(tester), isTrue, reason: '删到放得下就放行');
    expect(find.byKey(const ValueKey('import-blocked')), findsNothing);
  });

  testWidgets('服务端 413（截图合计太大）、400 provider_no_vision：行内说人话，截图都还在', (tester) async {
    final backend = shotBackend();
    await openShots(tester, backend);
    await tapVisible(tester, find.byKey(const ValueKey('import-pick-shots')));
    backend.failNext['POST /asset-import/extract'] = (413, 'body_too_large', '请求体过大');
    await tapVisible(tester, find.byKey(const ValueKey('import-start')));
    expect(find.text('截图合计太大了，删掉几片再试。'), findsOneWidget);
    expect(find.text('4 片 · 约 0.0MB'), findsOneWidget, reason: '选的截图都还在');
    backend.failNext['POST /asset-import/extract'] = (400, 'provider_no_vision', '这个渠道看不了图片');
    await tapVisible(tester, find.byKey(const ValueKey('import-start')));
    expect(find.text('这个渠道看不了图片，换一个支持看图的渠道。'), findsOneWidget);
  });

  testWidgets('处理截图：进度按原图报「第 i/n 张」；处理中能清空，清空后那轮的结果作废', (tester) async {
    final gate = Completer<void>();
    ScreenshotProgress? report;
    await openShots(
      tester,
      shotBackend(),
      picker: pickerOf([for (var i = 0; i < 3; i++) PickedScreenshot(name: 's$i.png', bytes: tinyPng)]),
      preparer: (files, removed, onProgress) async {
        report = onProgress;
        onProgress(1, files.length);
        await gate.future;
        return ScreenshotBatch(slices: [for (var f = 0; f < files.length; f++) fakeSlice(f, 0, 1)]);
      },
    );
    await tapVisible(tester, find.byKey(const ValueKey('import-pick-shots')));
    expect(find.byKey(const ValueKey('shots-preparing')), findsOneWidget);
    expect(find.text('正在切图、压缩：第 2/3 张…'), findsOneWidget);
    report!(2, 3);
    await tester.pump();
    expect(find.text('正在切图、压缩：第 3/3 张…'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('shots-clear')));
    await settle(tester);
    expect(find.text('选截图'), findsOneWidget);
    expect(find.byKey(const ValueKey('shots-preparing')), findsNothing);
    gate.complete();
    await settle(tester);
    expect(find.textContaining('片 · 约'), findsNothing, reason: '清空了，那轮迟到的结果不要');
  });

  testWidgets('预览：截图来的节点，依据块显示出自的那片截图（按输入页的叫法说是哪一片），点开能全屏放大；说明截图里的字没法自动核对', (tester) async {
    await openImagePreview(tester, orderImageDraft(), labels: const ['图 1 的第 1/2 片', '图 1 的第 2/2 片']);
    await tapVisible(tester, find.byKey(const ValueKey('import-node-i1')));
    expect(find.byKey(const ValueKey('evidence-image')), findsOneWidget);
    expect(find.text('出自图 1 的第 2/2 片，点图放大看。'), findsOneWidget);
    expect(find.text('模型读到的是「Apple iPhone 16 Pro 256GB 沙漠色钛金属 × 1」，截图里的字没法自动核对，先看一眼。'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('evidence-image-open')));
    await settle(tester);
    expect(find.byKey(const ValueKey('evidence-image-viewer')), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.text('截图 · 图 1 的第 2/2 片'), findsOneWidget);
    await tester.tap(find.byTooltip('关掉'));
    await settle(tester);
    expect(find.byKey(const ValueKey('evidence-image-viewer')), findsNothing);
  });

  testWidgets('预览（截图来源）：顶上整批说一次「没法逐字核对」；不给每条挂「依据未核实」，「需确认」不会变成全部（老草稿带着这个徽章也一样）', (tester) async {
    final json = orderImageDraft();
    ((json['items'] as List).first as Map<String, dynamic>)['badges'] = ['ev_unverified'];
    await openImagePreview(tester, json);
    expect(find.byKey(const ValueKey('import-image-hint')), findsOneWidget);
    expect(find.textContaining('截图里的字没法逐字核对'), findsOneWidget);
    expect(find.text('依据未核实'), findsNothing);
    expect(find.byKey(const ValueKey('import-filter-attention')), findsNothing, reason: '没有真正要确认的，就不出「需确认」');
  });

  testWidgets('截断横幅：续写那次出错（截图）→ 说「让它接着写时出错了」，不说成「续写了一次还是没写完」；截图说「只选后面那几片」', (tester) async {
    final json = orderImageDraft()
      ..['truncated'] = true
      ..['continued'] = true
      ..['continueFailed'] = true;
    await openImagePreview(tester, json);
    expect(find.text('材料太长，模型只写了一部分，让它接着写时出错了（下面是已经收到的 1 条）。没识别到的部分，只选后面那几片截图再导一次。'), findsOneWidget);
  });

  testWidgets('截断横幅：续写过一次还没写完（截图）', (tester) async {
    final json = orderImageDraft()
      ..['truncated'] = true
      ..['continued'] = true;
    await openImagePreview(tester, json);
    expect(find.text('材料太长，模型续写了一次还是没写完（下面是已经收到的 1 条）。没识别到的部分，只选后面那几片截图再导一次。'), findsOneWidget);
  });

  testWidgets('截断横幅：没续写（粘贴来源）', (tester) async {
    final container = bootAssets(shotBackend());
    container.listen(pendingPerkImportProvider, (_, _) {});
    container.read(pendingPerkImportProvider.notifier).state = PerkImportDraft.fromJson(orderDraft()..['truncated'] = true, clientId: 'cid-t');
    await pumpAssetsAt(tester, container, '/assets/import/preview', size: const Size(400, 2000));
    expect(find.text('材料太长，模型只写了一部分（下面是已经收到的 1 条）。剩下的建议分段再粘一次。'), findsOneWidget);
    expect(find.byKey(const ValueKey('import-image-hint')), findsNothing);
  });

  for (final size in kWidths) {
    testWidgets('宽 ${size.width}、字号 1.5 倍：截图来的预览（横幅、整批提示、依据块；宽屏在右栏）都不溢出', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final json = orderImageDraft()
        ..['truncated'] = true
        ..['continued'] = true
        ..['continueFailed'] = true;
      await openImagePreview(tester, json, labels: const ['图 1 的第 1/2 片', '图 1 的第 2/2 片'], size: size);
      await tapVisible(tester, find.byKey(const ValueKey('import-node-i1')));
      expect(find.byKey(const ValueKey('evidence-image')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in kWidths) {
    testWidgets('宽 ${size.width}：截图分段选了图、超过 8 片的提示都不溢出', (tester) async {
      await pumpAssetsAt(
        tester,
        bootAssets(
          shotBackend(),
          session: await sessionAs('admin'),
          overrides: [
            screenshotPickerProvider.overrideWithValue(pickerOf([for (var i = 0; i < 3; i++) PickedScreenshot(name: 's$i.png', bytes: tinyPng)])),
            screenshotPreparerProvider.overrideWithValue(fakePreparer()),
          ],
        ),
        '/assets/import',
        size: size,
      );
      await tapVisible(tester, find.byKey(const ValueKey('import-source-image')));
      await tapVisible(tester, find.byKey(const ValueKey('import-pick-shots')));
      expect(find.textContaining('切出了 12 片'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  }
}
