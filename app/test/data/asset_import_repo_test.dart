import 'dart:convert';
import 'dart:typed_data';

import 'package:famledger/data/api/api_client.dart';
import 'package:famledger/data/models/models.dart';
import 'package:famledger/data/repos/ai_repo.dart';
import 'package:famledger/data/repos/asset_import_repo.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'perks_rig.dart';

// AssetImportRepo（server/src/modules/asset_import.js）：识别的 SSE 事件翻成 ImportEvent、error 抛异常、流断了说清楚；
// 导入成功后同步一次，失败时把服务端的逐条错误原样带出来。

http.Response sseBody(String text) => http.Response.bytes(
  utf8.encode(text),
  200,
  headers: {'content-type': 'text/event-stream; charset=utf-8'},
);

AssetImportRepo repoOf(Rig rig) => AssetImportRepo(api: rig.api, ledger: rig.ledger);

void main() {
  test('识别：请求体带 kind/text/want/指定卡/渠道；stage → record → done 依次吐出来，done 之后收流', () async {
    final rig = Rig({
      'POST $api/asset-import/extract': [
        sseBody(
          ': open\n\n'
          'event: stage\ndata: {"stage":"asking","message":"正在请模型识别…"}\n\n'
          'event: record\ndata: {"n":3}\n\n'
          'event: record\ndata: {"n":8}\n\n'
          'event: done\ndata: {"importId":"imp-1","draft":{"importId":"imp-1","platforms":[]}}\n\n'
          'event: record\ndata: {"n":99}\n\n',
        ),
      ],
    });
    final events = await repoOf(rig)
        .extract(text: '88VIP 年费 88 元', want: ImportWant.virtual, targetMembershipId: 'vip', providerId: 'p1')
        .toList();
    expect(rig.server.bodyOf('POST', '$api/asset-import/extract'), {
      'kind': 'text',
      'text': '88VIP 年费 88 元',
      'want': 'virtual',
      'targetMembershipId': 'vip',
      'providerId': 'p1',
    });
    expect(events, hasLength(4));
    expect((events[0] as ImportStage).message, '正在请模型识别…');
    expect([(events[1] as ImportProgress).count, (events[2] as ImportProgress).count], [3, 8]);
    final done = events[3] as ImportDone;
    expect([done.importId, done.draft['importId']], ['imp-1', 'imp-1']);
  });

  test('识别：error 事件抛出带服务端 code 的异常；没等到 done 就断了当网络问题（可能已经送到）；409 原样抛', () async {
    final bad = Rig({
      'POST $api/asset-import/extract': [
        sseBody('event: stage\ndata: {"message":"x"}\n\nevent: error\ndata: {"code":"ai_bad_output","message":"模型没有按要求返回结果"}\n\n'),
      ],
    });
    await expectLater(
      repoOf(bad).extract(text: 'x').toList(),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'ai_bad_output').having((e) => e.message, 'message', '模型没有按要求返回结果')),
    );
    final cut = Rig({
      'POST $api/asset-import/extract': [sseBody('event: record\ndata: {"n":2}\n\n')],
    });
    await expectLater(
      repoOf(cut).extract(text: 'x').toList(),
      throwsA(isA<ApiException>().having((e) => e.isNetwork, 'isNetwork', isTrue).having((e) => e.message, 'message', contains('连接断了'))),
    );
    final busy = Rig({
      'POST $api/asset-import/extract': [apiError(409, 'import_in_progress', '你还有一次识别没结束')],
    });
    await expectLater(
      repoOf(busy).extract(text: 'x').toList(),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'import_in_progress')),
    );
  });

  test('导入：请求体原样发，结果解析好，然后同步一次；400 import_invalid 的逐条错误在 details 里', () async {
    final rig = Rig({
      'POST $api/asset-import/apply': [
        {
          'importId': 'imp-1',
          'created': {'platforms': 4, 'memberships': 1, 'benefits': 7, 'items': 0, 'transactions': 0},
          'updated': {'platforms': 1, 'memberships': 0, 'benefits': 0},
          'autoMerged': [
            {'key': 'p3', 'id': 'elm', 'name': '饿了么'},
          ],
          'ids': {'m1': 'vip-new'},
        },
      ],
      'GET $api/changes': [changes(next: 5)],
    });
    final body = {'clientId': 'c1', 'importId': 'imp-1', 'platforms': <Object>[], 'memberships': <Object>[], 'benefits': <Object>[], 'items': <Object>[]};
    final r = await repoOf(rig).apply(body);
    expect(rig.server.bodyOf('POST', '$api/asset-import/apply'), body);
    expect([r.createdOf('benefits'), r.updatedOf('platforms'), r.ids['m1'], r.autoMerged.single['name'], r.replayed], [7, 1, 'vip-new', '饿了么', false]);
    expect(rig.server.all('GET', '$api/changes'), hasLength(1));

    final bad = Rig({
      'POST $api/asset-import/apply': [
        apiError(400, 'import_invalid', '有 1 处要改，一条都没导入', {
          'errors': [
            {'key': 'b2', 'field': 'membership', 'message': '会员卡没有导入'},
          ],
        }),
      ],
    });
    await expectLater(
      repoOf(bad).apply(body),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'import_invalid').having((e) => (e.details['errors'] as List).single['key'], 'key', 'b2')),
    );
    expect(bad.server.all('GET', '$api/changes'), isEmpty, reason: '失败了不同步');
  });

  test('模型小工具：识别范围、token 估算、origin.unverified、物品 origin 缺字段兜底、渠道 extra 的两个键', () {
    expect(ImportWant.parse('items'), ImportWant.items);
    expect(ImportWant.parse('bogus'), ImportWant.auto);
    expect(ImportWant.virtual.label, '只要会员权益');
    expect(estimateImportTokens(''), 1500);
    expect(estimateImportTokens('会员权益'), 1504);
    expect(estimateImportTokens('abcdefgh'), 1502);
    expect(estimateImportTokens('字' * 20000), 1500 + importPickLimit, reason: '超过 12000 字只算挑出来的那部分');
    expect(originUnverified({'unverified': ['expiresOn']}), ['expiresOn']);
    expect(originUnverified(const {}), isEmpty);
    final old = Asset.fromJson({'id': 'a', 'name': '手机', 'priceCents': 1, 'purchasedOn': '2026-09-01'});
    expect(old.origin, isEmpty);
    final imported = Asset.fromJson({'id': 'a', 'name': '手机', 'priceCents': 1, 'purchasedOn': '2026-09-01', 'origin': {'src': 'ai_text', 'unverified': ['purchasedOn']}});
    expect(originUnverified(imported.origin), ['purchasedOn']);
    expect(imported.toJson()['origin'], {'src': 'ai_text', 'unverified': ['purchasedOn']});
    final p = AiProvider.fromJson({'id': 'p', 'name': 'x', 'extra': {'requestExtras': {'temperature': 0.2}, 'importMaxTokens': 8000}});
    expect([p.requestExtras, p.importMaxTokens], [{'temperature': 0.2}, 8000]);
    expect(AiProvider.fromJson({'id': 'q', 'name': 'y'}).importMaxTokens, isNull);
  });

  test('截图识别：给了 images 就是 kind=image，每片 {mediaType:image/png, data:base64}，不带 text', () async {
    final rig = Rig({
      'POST $api/asset-import/extract': [sseBody('event: done\ndata: {"importId":"imp-2","draft":{"importId":"imp-2"}}\n\n')],
    });
    final a = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 1, 2, 3]);
    final b = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 4, 5]);
    await repoOf(rig).extract(images: [a, b], want: ImportWant.items, providerId: 'p2').toList();
    expect(rig.server.bodyOf('POST', '$api/asset-import/extract'), {
      'kind': 'image',
      'images': [
        {'mediaType': 'image/png', 'data': base64Encode(a)},
        {'mediaType': 'image/png', 'data': base64Encode(b)},
      ],
      'want': 'items',
      'providerId': 'p2',
    });
  });

  test('撤销：POST /asset-import/:id/undo，结果解析好，然后同步一次；超过 7 天的 409 原样抛、不同步', () async {
    final rig = Rig({
      'POST $api/asset-import/imp-1/undo': [
        {
          'importId': 'imp-1',
          'undone': {'platforms': 0, 'memberships': 0, 'benefits': 0, 'items': 2, 'transactions': 1, 'events': 0},
          'restored': {'memberships': 1, 'benefits': 0},
          'aliasesRemoved': 1,
          'skippedChanged': [
            {'table': 'memberships', 'id': 'vip', 'name': '88VIP'},
          ],
          'skippedInUse': [
            {'table': 'assets', 'id': 'a1', 'name': 'iPhone', 'reason': 'sold'},
          ],
        },
      ],
      'GET $api/changes': [changes(next: 7)],
    });
    final r = await repoOf(rig).undo('imp-1');
    expect([r.undoneOf('items'), r.undoneOf('transactions'), r.restoredOf('memberships'), r.aliasesRemoved], [2, 1, 1, 1]);
    expect([r.skippedChanged.single['name'], r.skippedInUse.single['reason'], r.replayed], ['88VIP', 'sold', false]);
    expect(rig.server.all('GET', '$api/changes'), hasLength(1));

    final late = Rig({
      'POST $api/asset-import/imp-9/undo': [apiError(409, 'undo_expired', '导入超过 7 天了')],
    });
    await expectLater(repoOf(late).undo('imp-9'), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'undo_expired')));
    expect(late.server.all('GET', '$api/changes'), isEmpty);
  });

  test('最近的 AI 导入：GET /asset-import/recent 解析成 RecentImport（谁导的、截图还是粘贴、计数、还能撤几天）；缺字段有兜底', () async {
    final rig = Rig({
      'GET $api/asset-import/recent': [
        {
          'items': [
            {
              'importId': 'imp-1',
              'memberId': 'm2',
              'memberName': '小红',
              'mine': false,
              'sourceKind': 'image',
              'createdAt': '2026-09-22T05:55:00.000Z',
              'appliedAt': '2026-09-22T06:03:00.000Z',
              'created': {'platforms': 1, 'memberships': 1, 'benefits': 3, 'items': 0, 'transactions': 0},
              'updated': {'platforms': 0, 'memberships': 1, 'benefits': 0},
              'daysLeft': 3,
            },
            {'importId': 'imp-2'},
          ],
        },
      ],
    });
    final list = await repoOf(rig).recent();
    expect(list, hasLength(2));
    final a = list.first;
    expect([a.importId, a.memberName, a.mine, a.sourceKind, a.daysLeft], ['imp-1', '小红', false, 'image', 3]);
    expect(a.appliedAt!.toUtc(), DateTime.utc(2026, 9, 22, 6, 3));
    expect([a.created['benefits'], a.updated['memberships']], [3, 1]);
    final b = list.last;
    expect([b.mine, b.sourceKind, b.daysLeft, b.appliedAt, b.created], [true, 'text', 1, null, <String, int>{}]);
  });

  test('撤销结果：skippedChanged 带 deleted（被删了还是被改了）、skippedInUse 的 choice_in_use 原样解析', () {
    final r = PerkImportUndoResult.fromJson({
      'skippedChanged': [
        {'table': 'benefits', 'id': 'b1', 'name': '88 折购物券', 'deleted': true},
      ],
      'skippedInUse': [
        {'table': 'benefits', 'id': 'b2', 'name': '三选一', 'reason': 'choice_in_use'},
      ],
      'replayed': true,
    });
    expect([r.skippedChanged.single['deleted'], r.skippedInUse.single['reason'], r.replayed], [true, 'choice_in_use', true]);
  });

  test('看图探测：POST /ai/providers/:id/test?vision=1，结果和写好的渠道解析出来；渠道的 vision / maybeVision', () async {
    final rig = Rig({
      'POST $api/ai/providers/p1/test?vision=1': [
        {
          'ok': true,
          'vision': false,
          'sample': '蓝色',
          'message': '它说「蓝色」，看起来没看到图',
          'latencyMs': 420,
          'provider': {'id': 'p1', 'name': 'DeepSeek', 'extra': {'vision': false}},
        },
      ],
    });
    final r = await AiRepo(rig.api).testVision('p1');
    expect([r.vision, r.sample, r.latencyMs, r.provider!.vision], [false, '蓝色', 420, false]);
    expect(rig.server.seen.single.url.query, 'vision=1');
    expect(AiVisionTest.fromJson(const {'ok': false, 'vision': null, 'message': '上游返回 500'}).vision, isNull);
    expect([AiProvider.fromJson(const {'id': 'a', 'name': 'x'}).vision, AiProvider.fromJson(const {'id': 'a', 'name': 'x'}).maybeVision], [null, true]);
    final no = AiProvider.fromJson(const {'id': 'b', 'name': 'y', 'extra': {'vision': false}});
    expect([no.vision, no.maybeVision], [false, false]);
    expect(AiProvider.fromJson(const {'id': 'c', 'name': 'z', 'extra': {'vision': 'yes'}}).vision, isNull, reason: '不是布尔的当没测过');
  });

  test('草稿节点存本机：toJson → fromJson 原样（动作、勾选、差异勾选、关联、img、edited）', () {
    final n = ImportNode.fromJson({
      'key': 'i1',
      't': 'item',
      'action': 'create',
      'fields': {'name': 'iPhone', 'priceCents': 899900},
      'ev': 'iPhone',
      'img': 2,
      'conf': 0.9,
      'unverified': ['purchasedOn'],
      'badges': ['ev_unverified'],
      'diff': [
        {'field': 'expiresOn', 'old': '2026-10-01', 'new': '2026-12-31', 'take': true},
      ],
      'txCandidates': [
        {'id': 'tx1', 'occurredAt': '2026-09-21T09:00:00+08:00', 'merchant': 'Apple', 'amountCents': 899900},
      ],
      'link': {'mode': 'link', 'transactionId': 'tx1'},
    });
    n
      ..checked = false
      ..link = ItemLink.record
      ..linkTransactionId = null
      ..edited.add('priceCents');
    n.diff.single.take = false;
    final back = ImportNode.fromJson(jsonDecode(jsonEncode(n.toJson())) as Map<String, dynamic>);
    expect([back.key, back.t, back.action, back.checked, back.img, back.ev, back.conf], ['i1', 'item', 'create', false, 2, 'iPhone', 0.9]);
    expect([back.link, back.linkTransactionId, back.edited, back.badges, back.unverified], [ItemLink.record, null, {'priceCents'}, {'ev_unverified'}, ['purchasedOn']]);
    expect([back.diff.single.field, back.diff.single.take, back.diff.single.hasOld], ['expiresOn', false, true]);
    expect(back.txCandidates.single.amountCents, 899900);
  });

  test('网址和从流水的识别：请求体各是 kind=url（正文 + 跳转后的地址）、kind=transactions（分组、月数、useAi；直接生成不带渠道）', () async {
    final done = sseBody('event: done\ndata: {"importId":"imp-1","draft":{"importId":"imp-1"}}\n\n');
    final rig = Rig({'POST $api/asset-import/extract': [done]});
    final repo = repoOf(rig);
    await repo.extractUrl(text: '88VIP 年费 88 元', sourceUrl: 'https://vip.example/88vip', want: ImportWant.virtual, providerId: 'p1').toList();
    expect(rig.server.bodyOf('POST', '$api/asset-import/extract'), {
      'kind': 'url', 'text': '88VIP 年费 88 元', 'sourceUrl': 'https://vip.example/88vip', 'want': 'virtual', 'providerId': 'p1',
    });
    await repo.extractTransactions(groups: ['g_a', 'g_b'], providerId: 'p1').toList();
    expect(rig.server.bodyOf('POST', '$api/asset-import/extract'), {'kind': 'transactions', 'groups': ['g_a', 'g_b'], 'months': 13, 'useAi': false});
    final events = await repo.extractTransactions(groups: ['g_a'], useAi: true, months: 6, providerId: 'p1').toList();
    expect(rig.server.bodyOf('POST', '$api/asset-import/extract'), {'kind': 'transactions', 'groups': ['g_a'], 'months': 6, 'useAi': true, 'providerId': 'p1'});
    expect((events.single as ImportDone).importId, 'imp-1');
  });

  test('候选分组：GET 带 months，读出默认勾选和已关联；抓网页：POST {url}，降级提示原样带回，被拦的错误原样抛；扣费特征的说法', () async {
    final rig = Rig({
      'GET $api/asset-import/candidates': [
        {
          'months': 13,
          'total': 41,
          'items': [
            {
              'key': 'g_tv', 'merchant': '腾讯视频', 'amountCents': 3000, 'minCents': 3000, 'maxCents': 3000, 'count': 7, 'period': 'month',
              'periodSource': 'observed', 'firstOn': '2026-03-22', 'lastOn': '2026-09-18', 'nextOn': '2026-10-18', 'score': 7, 'checked': true, 'linked': null,
            },
            {
              'key': 'g_jd', 'merchant': '京东PLUS', 'amountCents': 19800, 'minCents': 19800, 'maxCents': 19800, 'count': 2, 'period': 'year',
              'firstOn': '2025-09-01', 'lastOn': '2026-09-01', 'score': 8, 'checked': false, 'linked': {'membershipId': 'm-jd', 'name': '京东PLUS'},
            },
            {
              'key': 'g_ap', 'merchant': 'Apple Store', 'amountCents': 59900, 'minCents': 59900, 'maxCents': 59900, 'count': 1, 'period': 'year',
              'firstOn': '2026-09-01', 'lastOn': '2026-09-01', 'score': 5, 'reasons': ['keyword', 'once', 'stale'], 'checked': false,
              'linked': {'assetId': 'a-case', 'name': '保护壳'},
            },
          ],
        },
      ],
      'POST $api/asset-import/fetch': [
        {'url': 'https://vip.example/88', 'finalUrl': 'https://passport.vip.example/login', 'title': '登录', 'text': '请登录', 'chars': 3, 'truncated': false, 'hint': 'login', 'message': '这个页面要登录才能看到内容'},
        apiError(400, 'url_blocked', '这个网址指向本机或内网地址，不能抓取', {'fakeIp': false}),
      ],
    });
    final repo = repoOf(rig);
    final c = await repo.candidates();
    expect(rig.server.seen.single.url.queryParameters, {'months': '13'});
    expect([c.months, c.total, c.items.length], [13, 41, 3]);
    final tv = c.items.first;
    expect([tv.key, tv.merchant, tv.amountCents, tv.count, tv.period, tv.periodSource, tv.lastOn, tv.nextOn, tv.checked, tv.linked], ['g_tv', '腾讯视频', 3000, 7, 'month', 'observed', '2026-09-18', '2026-10-18', true, false]);
    final jd = c.items[1];
    expect([jd.linked, jd.linkedId, jd.linkedName, jd.linkedAsset, jd.checked, jd.periodSource, jd.nextOn, jd.reasons], [true, 'm-jd', '京东PLUS', false, false, 'observed', null, <String>[]]);
    final ap = c.items.last;
    expect([ap.linked, ap.linkedId, ap.linkedName, ap.linkedAsset, ap.stale, ap.reasons], [true, 'a-case', '保护壳', true, true, ['keyword', 'once', 'stale']]);

    final page = await repo.fetchPage('vip.example/88');
    expect(rig.server.bodyOf('POST', '$api/asset-import/fetch'), {'url': 'vip.example/88'});
    expect([page.finalUrl, page.title, page.text, page.hint, page.message, page.truncated], ['https://passport.vip.example/login', '登录', '请登录', 'login', '这个页面要登录才能看到内容', false]);
    await expectLater(
      repo.fetchPage('http://10.0.0.8/'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'url_blocked').having((e) => e.message, 'message', contains('内网'))),
    );
    expect(estimateNamingTokens(2), 660);
    expect(payPatternLabel(const PerkPayPattern(keywords: ['腾讯视频'], minCents: 2400, maxCents: 3600)), '「腾讯视频」 · ¥24.00–¥36.00');
    expect(payPatternLabel(const PerkPayPattern(keywords: ['A', 'B'], maxCents: 1000)), '「A」「B」 · ¥10.00 以下');
    expect(payPatternLabel(const PerkPayPattern(keywords: ['A'], minCents: 500)), '「A」 · ¥5.00 以上');
    expect(payPatternLabel(const PerkPayPattern(keywords: ['A'])), '「A」');
  });
}
