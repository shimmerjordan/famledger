import 'dart:convert';

import 'package:famledger/data/api/api_client.dart';
import 'package:famledger/data/models/models.dart';
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
}
