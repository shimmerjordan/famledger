import 'package:famledger/ui/perk_import/perk_import_preview_page.dart';
import 'package:famledger/ui/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assets_harness.dart';
import 'import_fake.dart';
import 'perk_import_fixtures.dart';
import 'perks_fake.dart';

// 导入页的「网址」「从流水」两个分段（spec §6「输入页」、§7 P7）：
//   · 网址：先抓取，正文放进可编辑的框，改完按文字识别（kind=url，带跳转后的地址）；要登录、正文太短、PDF、抓不到时说清楚，
//     一键「改用截图 / 改用粘贴」（整个分段只有一排）；抓取中有文字说明、「开始识别」点不了；地址清空再点抓取先收起上一次的；
//     被当成 fake-ip 拦下时按管理员 / 成员分开说；
//   · 从流水：进分段取候选，默认勾分数 ≥4、没关联的；没勾的说清楚为什么（已关联卡或物品、好像停了、把握不大）；「直接生成」
//     不带渠道、没有渠道也能点；「AI 整理名称」带渠道，出错时提示改点「直接生成」；勾的组对不上了（groups_stale）重新取，
//     保留手动改过的勾选、重取期间两个按钮点不了；一组都没有时说只看确认过的支出、给「改用粘贴」；进度页按「直接生成 /
//     AI 整理名称」换说法；指定卡时不给从流水；三种宽度 × 1.0 / 1.5 倍字号都不溢出、四段都是一行。
// 从流水的草稿在预览里的样子在 perk_import_preview_test.dart。

AssetsBackend sourcesBackend({ImportFake? imports}) => AssetsBackend(
  perks: PerksFake(platforms: [platformJson('tb'), platformJson('tv-platform', name: '腾讯视频', sort: 1)]),
  imports: imports,
);

const Map<String, dynamic> vipPage = {
  'url': 'https://vip.example/88',
  'finalUrl': 'https://vip.example/88vip',
  'title': '88VIP 权益',
  'text': vip88Source,
  'chars': 170,
  'truncated': false,
  'hint': null,
  'message': null,
};

Future<void> openSource(WidgetTester tester, String source) async {
  await tester.tap(find.byKey(ValueKey('import-source-$source')));
  await settle(tester);
}

Set<String> selectedSource(WidgetTester tester) => tester.widget<SegmentedButton<String>>(find.byKey(const ValueKey('import-source'))).selected;

bool? tickOf(WidgetTester tester, String key) => tester.widget<CheckboxListTile>(find.byKey(ValueKey('import-tx-$key'))).value;

void main() {
  testWidgets('网址：抓取 → 正文进可编辑的框 → 改了再识别：请求是 kind=url，带跳转后的地址；识别完进预览', (tester) async {
    final backend = sourcesBackend();
    backend.imports
      ..page = vipPage
      ..draft = vip88Draft();
    await pumpAssetsAt(tester, bootAssets(backend), '/assets/import');
    await openSource(tester, 'url');
    expect(find.textContaining('会员页大多要登录或靠脚本加载'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('import-url')), 'vip.example/88');
    await tapVisible(tester, find.byKey(const ValueKey('import-fetch')));
    expect(backend.imports.fetchBodies.single, {'url': 'vip.example/88'});
    expect(find.text('抓到「88VIP 权益」，${vip88Source.length} 字，先删掉没用的再识别'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('import-url-text'))).controller!.text, vip88Source);
    expect(find.byKey(const ValueKey('import-url-fallback')), findsNothing, reason: '抓得好好的不用劝人换方式');

    final edited = vip88Source.split('\n').take(3).join('\n');
    await tester.enterText(find.byKey(const ValueKey('import-url-text')), edited);
    await tester.pump();
    expect(find.textContaining('预计输入约'), findsOneWidget);
    await tapVisible(tester, find.byKey(const ValueKey('import-start')));
    expect(backend.imports.extractBodies.single, {
      'kind': 'url', 'text': edited, 'sourceUrl': 'https://vip.example/88vip', 'want': 'auto', 'providerId': 'ai-1',
    });
    expect(find.byType(PerkImportPreviewPage), findsOneWidget);
  });

  testWidgets('网址：要登录、PDF → 说明 + 改用截图 / 改用粘贴一键切过去；抓不到（被拦）也说清楚；没抓到正文点识别行内提示', (tester) async {
    final backend = sourcesBackend();
    backend.imports.page = {
      ...vipPage, 'title': '登录', 'text': '请登录后查看', 'chars': 6, 'hint': 'login',
      'message': '这个页面要登录才能看到内容，抓到的多半只是登录页。登录后截图，或者把权益说明复制出来粘贴。',
    };
    await pumpAssetsAt(tester, bootAssets(backend), '/assets/import');
    await openSource(tester, 'url');
    await tester.enterText(find.byKey(const ValueKey('import-url')), 'https://vip.example/88');
    await tapVisible(tester, find.byKey(const ValueKey('import-fetch')));
    expect(find.text('这个页面要登录才能看到内容，抓到的多半只是登录页。登录后截图，或者把权益说明复制出来粘贴。'), findsOneWidget);
    await tapVisible(tester, find.byKey(const ValueKey('import-url-to-image')));
    expect(selectedSource(tester), {'image'});

    await openSource(tester, 'url');
    expect(find.byKey(const ValueKey('import-url-fallback')), findsOneWidget, reason: '切回来抓到的还在');
    expect(find.text('抓到「登录」，6 字'), findsOneWidget, reason: '抓到的是登录页时不催人「删掉没用的再识别」');
    backend.imports.page = {
      ...vipPage, 'title': '', 'text': '', 'chars': 0, 'hint': 'pdf', 'message': '这是一个 PDF 文件，网页抓取读不了里面的字。截个图，或者把文字复制出来粘贴。',
    };
    await tapVisible(tester, find.byKey(const ValueKey('import-fetch')));
    expect(find.textContaining('这是一个 PDF 文件'), findsOneWidget);
    expect(find.byKey(const ValueKey('import-url-text')), findsNothing, reason: '没有正文就不给空框');
    await tapVisible(tester, find.byKey(const ValueKey('import-start')));
    expect(find.text('先抓取网页；抓不到就点「改用粘贴」'), findsOneWidget, reason: '没有框可粘，不说「粘进来」');
    expect(backend.imports.extractBodies, isEmpty);
    await tapVisible(tester, find.byKey(const ValueKey('import-url-to-paste')));
    expect(selectedSource(tester), {'paste'});

    await openSource(tester, 'url');
    backend.imports.fetchError = (400, 'url_blocked', '这个网址指向本机或内网地址，不能抓取');
    await tapVisible(tester, find.byKey(const ValueKey('import-fetch')));
    expect(find.text('这个网址指向本机或内网地址，不能抓取'), findsOneWidget);
    expect(find.byKey(const ValueKey('import-url-to-image')), findsOneWidget);
    expect(find.byKey(const ValueKey('import-url-text')), findsNothing, reason: '上一次抓到的不再留着冒充这一次的');
  });

  testWidgets('网址：抓到登录页后把地址清空再点抓取 → 收起上一次的页面，只说「先填一个网址」，只有一排「改用截图 / 改用粘贴」', (tester) async {
    final backend = sourcesBackend();
    backend.imports.page = {...vipPage, 'title': '登录', 'text': '请登录后查看', 'chars': 6, 'hint': 'login', 'message': '这个页面要登录才能看到内容。'};
    await pumpAssetsAt(tester, bootAssets(backend), '/assets/import');
    await openSource(tester, 'url');
    await tester.enterText(find.byKey(const ValueKey('import-url')), 'https://vip.example/88');
    await tapVisible(tester, find.byKey(const ValueKey('import-fetch')));
    expect(find.byKey(const ValueKey('import-fetch-hint')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('import-url')), '  ');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await settle(tester);
    expect(tester.takeException(), isNull, reason: '不能有两个同 key 的按钮行');
    expect(find.text('先填一个网址'), findsOneWidget);
    expect(find.byKey(const ValueKey('import-url-fallback')), findsOneWidget);
    expect(find.byKey(const ValueKey('import-fetch-summary')), findsNothing, reason: '上一次的页面收起来了');
    expect(find.byKey(const ValueKey('import-fetch-hint')), findsNothing);
    expect(backend.imports.fetchBodies, hasLength(1), reason: '空地址不发请求');
    // 按钮也一样。
    await tapVisible(tester, find.byKey(const ValueKey('import-fetch')));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('import-url-fallback')), findsOneWidget);
  });

  testWidgets('网址：抓取中有文字说明、加载圈能读出来，「抓取」「开始识别」都点不了，上一次的结果收起；回来后恢复；超长正文说只留了前 20000 字', (tester) async {
    final backend = sourcesBackend();
    backend.imports.page = vipPage;
    await pumpAssetsAt(tester, bootAssets(backend), '/assets/import');
    await openSource(tester, 'url');
    await tester.enterText(find.byKey(const ValueKey('import-url')), 'https://vip.example/88');
    await tapVisible(tester, find.byKey(const ValueKey('import-fetch')));
    expect(find.byKey(const ValueKey('import-url-text')), findsOneWidget);

    backend.imports.page = {...vipPage, 'truncated': true};
    backend.delayNext['POST /asset-import/fetch'] = const Duration(seconds: 3);
    await tapVisible(tester, find.byKey(const ValueKey('import-fetch')));
    expect(find.text('正在抓取网页…（最多 10 秒）'), findsOneWidget);
    expect(find.bySemanticsLabel('正在抓取'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('import-fetch'))).onPressed, isNull);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('import-start'))).onPressed, isNull, reason: '抓取中不能拿旧正文去识别');
    expect(find.byKey(const ValueKey('import-url-text')), findsNothing, reason: '上一次的正文收起来了');
    await tester.pump(const Duration(seconds: 3));
    await settle(tester);
    expect(find.byKey(const ValueKey('import-fetching')), findsNothing);
    expect(find.byKey(const ValueKey('import-url-text')), findsOneWidget);
    expect(find.byKey(const ValueKey('import-url-truncated')), findsOneWidget);
    expect(find.text('正文超过 20000 字，只留了前 20000 字。'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('import-start'))).onPressed, isNotNull);
  });

  const fakeIpText = '这个网址解析到了 fake-ip 代理用的 198.18.0.0/15 段，默认不抓。管理员可以在 compose 的 .env 里加 URL_FETCH_ALLOW_FAKEIP=1，'
      '再 docker compose up -d 重启服务才生效；放开后服务端没法核实网址的真实目标地址。';
  for (final role in ['member', 'admin']) {
    testWidgets('网址：被当成 fake-ip 拦下（details.fakeIp）—— $role：成员看到「请管理员」和换方式，管理员看到服务端给的步骤和代价', (tester) async {
      const adminText = fakeIpText;
      final backend = sourcesBackend();
      backend.imports
        ..fetchError = (400, 'url_blocked', adminText)
        ..fetchErrorDetails = {'fakeIp': true};
      await pumpAssetsAt(tester, bootAssets(backend, session: await sessionAs(role)), '/assets/import');
      await openSource(tester, 'url');
      await tester.enterText(find.byKey(const ValueKey('import-url')), 'https://vip.example/88');
      await tapVisible(tester, find.byKey(const ValueKey('import-fetch')));
      final shown = tester.widget<InlineError>(find.byKey(const ValueKey('import-fetch-error'))).message;
      if (role == 'member') {
        expect(shown, contains('请管理员'));
        expect(shown, contains('改用截图或粘贴'));
        expect(shown, isNot(contains('URL_FETCH_ALLOW_FAKEIP')), reason: '成员改不了服务端，不给一段环境变量');
      } else {
        expect(shown, adminText);
      }
      expect(find.byKey(const ValueKey('import-url-fallback')), findsOneWidget);
    });
  }

  testWidgets('从流水：进分段取一次候选，默认勾分数高、没关联的；已关联的、只扣过一次的写出来；直接生成不带渠道、没有渠道也能点', (tester) async {
    final backend = sourcesBackend(imports: ImportFake(providers: const []));
    backend.imports
      ..candidates = candidatesJson()
      ..draft = txDraft();
    await pumpAssetsAt(tester, bootAssets(backend, session: await sessionAs('admin')), '/assets/import');
    expect(backend.requests('GET', '/asset-import/candidates'), isEmpty, reason: '没进分段不取');
    await openSource(tester, 'transactions');
    expect(backend.requests('GET', '/asset-import/candidates').single.url.queryParameters, {'months': '13'});
    expect(
      [for (final k in ['g_tv', 'g_vip', 'g_iq', 'g_jd', 'g_ap', 'g_wps']) tickOf(tester, k)],
      [true, true, false, false, false, false],
    );
    expect(find.text('腾讯视频 · ¥30.00'), findsOneWidget);
    expect(find.text('每月 · 7 次 · 最近 2026-09-18 · ¥28.00–¥30.00'), findsOneWidget, reason: '价格有高有低的写出区间');
    expect(find.text('每年 · 1 次 · 最近 2026-08-14 · 只扣过一次，按每年算'), findsOneWidget);
    // 默认没勾的都说清楚为什么。
    expect(find.text('每月 · 4 次 · 最近 2026-03-02 · 好像停了（2026-04-02 该扣的没扣）'), findsOneWidget);
    expect(find.text('每年 · 2 次 · 最近 2026-09-01 · 已关联「京东PLUS」'), findsOneWidget);
    expect(find.text('每年 · 1 次 · 最近 2026-09-01 · 只扣过一次，按每年算 · 已关联物品「iPhone 16 Plus 保护壳」'), findsOneWidget);
    expect(find.text('每年 · 1 次 · 最近 2026-07-01 · 只扣过一次，按每年算 · 把握不大，默认没勾'), findsOneWidget);
    expect(find.text('一共认出 8 组，只列了最像的 6 组。'), findsOneWidget);
    expect(find.byKey(const ValueKey('import-want-auto')), findsNothing, reason: '从流水只出会员卡，不给识别范围');
    expect(find.text('「AI 整理名称」用哪个渠道'), findsOneWidget, reason: '「直接生成」不用渠道');
    expect(find.byKey(const ValueKey('import-no-provider-tx')), findsOneWidget);
    expect(find.byKey(const ValueKey('import-no-provider-tx-settings')), findsOneWidget, reason: '管理员没有渠道时给「去设置 AI 渠道」');
    expect(find.textContaining('财付通-腾讯视频VIP → 平台「腾讯视频」'), findsOneWidget, reason: '说清楚 AI 整理名称能带来什么');
    expect(tester.widget<OutlinedButton>(find.byKey(const ValueKey('import-tx-ai'))).onPressed, isNull, reason: '没有渠道时 AI 整理名称点不了');
    expect(find.text('勾了 2 组。直接生成不花 token；AI 整理名称预计输入约 660 token。'), findsOneWidget);
    await tapVisible(tester, find.byKey(const ValueKey('import-tx-g_iq')));
    expect(find.textContaining('勾了 3 组'), findsOneWidget);
    await tapVisible(tester, find.byKey(const ValueKey('import-tx-g_iq')));

    await openSource(tester, 'paste');
    await openSource(tester, 'transactions');
    expect(backend.requests('GET', '/asset-import/candidates'), hasLength(1), reason: '切走再回来不重取，勾的都在');
    backend.delayNext['POST /asset-import/extract'] = const Duration(seconds: 2);
    await tapVisible(tester, find.byKey(const ValueKey('import-tx-direct')));
    // 进度页：直接生成不说「识别」「花 token」。
    expect(find.text('正在生成…'), findsOneWidget);
    expect(find.textContaining('token'), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    await settle(tester);
    expect(backend.imports.extractBodies.single, {'kind': 'transactions', 'groups': ['g_tv', 'g_vip'], 'months': 13, 'useAi': false});
    expect(find.byType(PerkImportPreviewPage), findsOneWidget);
    expect(find.text('¥30.00 每月 · 到期 2026-10-18 · 自动续费'), findsOneWidget);
  });

  testWidgets('从流水：成员没有渠道时只说直接生成照样能用（没有设置按钮）', (tester) async {
    final none = sourcesBackend(imports: ImportFake(providers: const []));
    none.imports.candidates = candidatesJson();
    await pumpAssetsAt(tester, bootAssets(none), '/assets/import');
    await openSource(tester, 'transactions');
    expect(find.byKey(const ValueKey('import-no-provider-tx')), findsOneWidget);
    expect(find.byKey(const ValueKey('import-no-provider-tx-settings')), findsNothing);
  });

  testWidgets('从流水：AI 整理名称出错时提示改点「直接生成」，进度页说「整理名称」', (tester) async {
    final backend = sourcesBackend();
    backend.imports.candidates = candidatesJson();
    await pumpAssetsAt(tester, bootAssets(backend), '/assets/import');
    await openSource(tester, 'transactions');
    backend.delayNext['POST /asset-import/extract'] = const Duration(seconds: 2);
    backend.imports.extractError = ('ai_upstream', '渠道回了 500，稍后再试');
    await tapVisible(tester, find.byKey(const ValueKey('import-tx-ai')));
    expect(find.text('正在整理名称…'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await settle(tester);
    expect(find.text('渠道回了 500，稍后再试 可以先点「直接生成」（不用 AI），名字导入前能改。'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('import-tx-direct'))).onPressed, isNotNull);
  });

  testWidgets('从流水：AI 整理名称带上渠道；全不勾两个按钮都点不了；取候选失败能重试', (tester) async {
    final backend = sourcesBackend();
    backend.imports
      ..candidatesError = (500, 'internal', '服务器内部错误')
      ..draft = txDraft();
    await pumpAssetsAt(tester, bootAssets(backend), '/assets/import');
    await openSource(tester, 'transactions');
    expect(find.byKey(const ValueKey('import-tx-error')), findsOneWidget);
    expect(find.textContaining('没取到流水里像订阅的扣费'), findsOneWidget, reason: '不说内部叫法「候选」');
    expect(find.byKey(const ValueKey('import-estimate')), findsNothing, reason: '没东西可勾时不写「先勾几组」');
    backend.imports
      ..candidatesError = null
      ..candidates = candidatesJson();
    await tapVisible(tester, find.text('重试'));
    expect(find.byKey(const ValueKey('import-tx-g_tv')), findsOneWidget);
    await tapVisible(tester, find.byKey(const ValueKey('import-tx-g_tv')));
    await tapVisible(tester, find.byKey(const ValueKey('import-tx-g_vip')));
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('import-tx-direct'))).onPressed, isNull);
    expect(tester.widget<OutlinedButton>(find.byKey(const ValueKey('import-tx-ai'))).onPressed, isNull);
    expect(find.text('先勾几组。生成之后先在预览里逐条核对，确认了才会落库。'), findsOneWidget);
    await tapVisible(tester, find.byKey(const ValueKey('import-tx-g_jd')));
    await tapVisible(tester, find.byKey(const ValueKey('import-tx-ai')));
    expect(backend.imports.extractBodies.single, {'kind': 'transactions', 'groups': ['g_jd'], 'months': 13, 'useAi': true, 'providerId': 'ai-1'});
  });

  testWidgets('从流水：一组都没有时说清楚只看确认过的支出、要什么样的扣费，给「改用粘贴」；两个按钮都点不了，也不写「先勾几组」', (tester) async {
    final empty = sourcesBackend();
    empty.imports.candidates = const {'months': 13, 'total': 0, 'items': <Object>[]};
    await pumpAssetsAt(tester, bootAssets(empty), '/assets/import');
    await openSource(tester, 'transactions');
    expect(find.byKey(const ValueKey('import-tx-empty')), findsOneWidget);
    expect(find.textContaining('确认过的支出'), findsOneWidget);
    expect(find.byKey(const ValueKey('import-estimate')), findsNothing);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('import-tx-direct'))).onPressed, isNull);
    await tapVisible(tester, find.byKey(const ValueKey('import-tx-empty-paste')));
    expect(selectedSource(tester), {'paste'});
  });

  testWidgets('从流水：勾的组对不上了（groups_stale）→ 先说正在重新取（期间两个按钮点不了），取完保留手动改过的勾选、新组按默认勾', (tester) async {
    final backend = sourcesBackend();
    backend.imports.candidates = candidatesJson();
    await pumpAssetsAt(tester, bootAssets(backend), '/assets/import');
    await openSource(tester, 'transactions');
    // 手动改：取消默认勾的 88VIP，勾上默认没勾的爱奇艺。
    await tapVisible(tester, find.byKey(const ValueKey('import-tx-g_vip')));
    await tapVisible(tester, find.byKey(const ValueKey('import-tx-g_iq')));
    // 重取回来：腾讯视频来了一笔更便宜的，key 变了（g_tv2，默认勾）；多了一组新的（g_new，默认勾）；其余照旧。
    final next = candidatesJson();
    final items = [for (final i in next['items'] as List) Map<String, dynamic>.of(i as Map<String, dynamic>)];
    items.first['key'] = 'g_tv2';
    items.add({...items.first, 'key': 'g_new', 'merchant': '网易云音乐', 'checked': true});
    backend.imports.candidates = {...next, 'items': items};
    backend.failNext['POST /asset-import/extract'] = (409, 'groups_stale', '勾的这几组和现在的流水对不上了');
    backend.delayNext['GET /asset-import/candidates'] = const Duration(seconds: 2);
    await tapVisible(tester, find.byKey(const ValueKey('import-tx-direct')));
    expect(find.text('勾的几组和现在的流水对不上了（刚记了新流水？），正在重新取…'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('import-tx-direct'))).onPressed, isNull, reason: '重取期间不能拿旧 key 再撞一次');
    expect(tester.widget<OutlinedButton>(find.byKey(const ValueKey('import-tx-ai'))).onPressed, isNull);
    await tester.pump(const Duration(seconds: 2));
    await settle(tester);
    expect(backend.requests('GET', '/asset-import/candidates'), hasLength(2));
    expect(find.text('重新取好了：还在的组保留了你的勾选，新出现的按默认勾。看一眼再生成。'), findsOneWidget);
    expect(
      {for (final k in ['g_tv2', 'g_vip', 'g_iq', 'g_jd', 'g_new']) k: tickOf(tester, k)},
      {'g_tv2': true, 'g_vip': false, 'g_iq': true, 'g_jd': false, 'g_new': true},
    );
    expect(find.byType(PerkImportPreviewPage), findsNothing);
    await tapVisible(tester, find.byKey(const ValueKey('import-tx-direct')));
    expect((backend.imports.extractBodies.last['groups'] as List), ['g_tv2', 'g_iq', 'g_new']);
  });

  testWidgets('会员详情的「AI 补充权益」（指定卡）：不给「从流水」，网址照样能用', (tester) async {
    final backend = sourcesBackend();
    backend.perks.memberships['vip'] = membershipJson('vip');
    await pumpAssetsAt(tester, bootAssets(backend), '/assets/import?membership=vip');
    expect(find.byKey(const ValueKey('import-source-transactions')), findsNothing);
    expect(find.byKey(const ValueKey('import-source-url')), findsOneWidget);
  });

  for (final scale in [1.0, 1.5]) {
    for (final size in kWidths) {
      testWidgets('宽 ${size.width}、字号 $scale 倍：四个来源分段、网址（带降级提示和正文框）、从流水（列表 + 底栏）都不溢出', (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final backend = sourcesBackend();
        backend.imports
          ..candidates = candidatesJson()
          ..page = {...vipPage, 'hint': 'short', 'truncated': true, 'message': '只抓到很少的字（这类页面常靠脚本加载内容）。截图或者复制粘贴会更准。'};
        await pumpAssetsAt(tester, bootAssets(backend, session: await sessionAs('admin')), '/assets/import', size: size);
        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byKey(const ValueKey('import-source'))).height, lessThanOrEqualTo(48 * scale), reason: '四段都是一行（窄屏不带图标）');
        expect(tester.getSize(find.byKey(const ValueKey('import-source-transactions'))).height, lessThan(30 * scale), reason: '「从流水」不折成两行');
        await openSource(tester, 'url');
        await tester.enterText(find.byKey(const ValueKey('import-url')), 'https://vip.example/88');
        await tapVisible(tester, find.byKey(const ValueKey('import-fetch')));
        expect(find.byKey(const ValueKey('import-url-fallback')), findsOneWidget);
        expect(find.byKey(const ValueKey('import-url-text')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await openSource(tester, 'transactions');
        final page = find.byType(Scrollable).first;
        await tester.scrollUntilVisible(find.byKey(const ValueKey('import-tx-g_wps')), 200, scrollable: page);
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(find.byKey(const ValueKey('import-tx-ai')), 200, scrollable: page);
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }
  }
}
