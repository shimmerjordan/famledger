import 'package:famledger/data/api/api_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'perks_rig.dart';

void main() {
  group('PerksRepo 请求', () {
    test('新建平台：原样发请求体，回来的行先落本地再同步', () async {
      final rig = Rig({
        'POST $api/platforms': [
          {'platform': platformRow('tb', aliases: ['天猫'])},
        ],
        'GET $api/changes': [changes(next: 3)],
      });
      final p = await rig.perks.createPlatform({'name': '淘宝', 'aliases': ['天猫']});
      expect(rig.server.bodyOf('POST', '$api/platforms'), {'name': '淘宝', 'aliases': ['天猫']});
      expect(p.aliases, ['天猫']);
      expect(rig.ledger.platforms.single.id, 'tb');
      expect(rig.server.all('GET', '$api/changes'), hasLength(1));
    });

    test('重名：409 name_taken 原样抛出，details 里有已有那个平台的 id，本地不动', () async {
      final rig = Rig({
        'POST $api/platforms': [
          apiError(409, 'name_taken', '已经有叫「优酷」的平台了', {'id': 'yk', 'name': '优酷'}),
        ],
      });
      await expectLater(
        rig.perks.createPlatform({'name': 'YOUKU'}),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'name_taken').having((e) => e.details['id'], 'id', 'yk')),
      );
      expect(rig.ledger.platforms, isEmpty);
    });

    test('合并平台：POST /platforms/:id/merge 带 targetId 和 clientId；目标落本地、被并的拿掉', () async {
      final rig = Rig({
        'GET $api/changes': [
          changes(next: 2, platforms: [platformRow('tb'), platformRow('tm', name: '天猫')]),
          changes(next: 3),
        ],
        'POST $api/platforms/tm/merge': [
          {'platform': platformRow('tb', aliases: ['天猫']), 'moved': {'memberships': 1, 'benefits': 0}},
        ],
      });
      await rig.ledger.sync();
      final target = await rig.perks.mergePlatform('tm', targetId: 'tb', clientId: 'c-1');
      expect(rig.server.bodyOf('POST', '$api/platforms/tm/merge'), {'targetId': 'tb', 'clientId': 'c-1'});
      expect(target.aliases, ['天猫']);
      expect(rig.ledger.platforms.map((p) => p.id), ['tb']);
      expect(rig.ledger.platforms.single.aliases, ['天猫']);
    });

    test('会员：新建带 clientId 与 recordTransaction 原样发；编辑走 PATCH；级联删除带 ?cascade=1', () async {
      final rig = Rig({
        'POST $api/memberships': [
          {'membership': membershipRow('vip')},
        ],
        'PATCH $api/memberships/vip': [
          {'membership': {...membershipRow('vip'), 'expiresOn': null}},
        ],
        'DELETE $api/memberships/vip?cascade=1': [
          {'membership': membershipRow('vip', deletedAt: '2026-09-23T02:00:00.000Z')},
        ],
        'GET $api/changes': [changes(next: 3)],
      });
      final body = {
        'platformId': 'tb',
        'name': '88VIP',
        'clientId': 'c-9',
        'recordTransaction': {'accountId': 'bank'},
      };
      await rig.perks.createMembership(body);
      expect(rig.server.bodyOf('POST', '$api/memberships'), body);
      await rig.perks.updateMembership('vip', {'expiresOn': null});
      expect(rig.server.bodyOf('PATCH', '$api/memberships/vip'), {'expiresOn': null}, reason: 'null 就是清掉，要发出去');
      await rig.perks.deleteMembership('vip', cascade: true);
      expect(rig.server.all('DELETE', '$api/memberships/vip').single.url.queryParameters, {'cascade': '1'});
      expect(rig.ledger.memberships, isEmpty);
    });

    test('删权益没带 cascade 而服务端 409 has_children：原样抛出，本地不动', () async {
      final rig = Rig({
        'GET $api/changes': [
          changes(next: 2, benefits: [benefitRow('c1', name: '二选一'), benefitRow('o1', parentId: 'c1')]),
        ],
        'DELETE $api/benefits/c1': [
          apiError(409, 'has_children', '这条下面还有 1 个选项', {'options': 1, 'events': 0}),
        ],
      });
      await rig.ledger.sync();
      await expectLater(
        rig.perks.deleteBenefit('c1'),
        throwsA(isA<ApiException>().having((e) => e.details, 'details', {'options': 1, 'events': 0})),
      );
      expect(rig.ledger.benefits.map((b) => b.id), ['c1', 'o1']);
    });

    test('权益：新建走 POST，编辑走 PATCH，都落本地', () async {
      final rig = Rig({
        'POST $api/benefits': [
          {'benefit': benefitRow('b1', name: '优酷年卡')},
        ],
        'PATCH $api/benefits/b1': [
          {'benefit': benefitRow('b1', name: '优酷VIP年卡')},
        ],
        'GET $api/changes': [changes(next: 3)],
      });
      await rig.perks.createBenefit({'membershipId': 'vip', 'name': '优酷年卡'});
      await rig.perks.updateBenefit('b1', {'name': '优酷VIP年卡'});
      expect(rig.ledger.benefits.single.name, '优酷VIP年卡');
    });
  });
}
