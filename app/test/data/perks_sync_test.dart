import 'package:famledger/data/repos/ledger_repo.dart';
import 'package:flutter_test/flutter_test.dart';

import 'perks_rig.dart';

void main() {
  group('LedgerRepo 同步会员权益四张表', () {
    test('/changes 里的四个桶合并进来、落本地缓存，LedgerData 能按 id 找到', () async {
      final rig = Rig({
        'GET $api/changes': [
          changes(
            next: 5,
            platforms: [platformRow('tb')],
            memberships: [membershipRow('vip')],
            benefits: [benefitRow('b1')],
            events: [eventRow('e1', 'b1')],
          ),
        ],
      });
      await rig.ledger.sync();
      final data = rig.ledger.snapshot;
      expect(data.platform('tb')?.name, '淘宝');
      expect(data.membership('vip')?.name, '88VIP');
      expect(data.benefit('b1')?.name, '券');
      expect(data.benefitEvents.single.id, 'e1');

      final cached = await rig.store.read<Map<String, dynamic>>(LedgerRepo.cacheKey);
      expect((cached!['platforms'] as List).single['id'], 'tb');
      expect((cached['memberships'] as List).single['id'], 'vip');
      expect((cached['benefits'] as List).single['id'], 'b1');
      expect((cached['benefit_events'] as List).single['id'], 'e1');

      // 再开一个仓库读缓存：四张表都回得来，游标接着走。
      final again = LedgerRepo(api: rig.api, store: rig.store);
      await again.load();
      expect(again.benefits.single.id, 'b1');
      expect(again.seq, 5);
    });

    test('墓碑行把本地那条删掉；归档的在 active 列表里看不到', () async {
      final rig = Rig({
        'GET $api/changes': [
          changes(next: 2, platforms: [platformRow('tb'), platformRow('yk', name: '优酷')], benefits: [benefitRow('b1')]),
          changes(
            next: 3,
            platforms: [
              platformRow('yk', name: '优酷', deletedAt: '2026-09-23T02:00:00.000Z'),
              {...platformRow('tb'), 'archived': true},
            ],
            benefits: [benefitRow('b1', deletedAt: '2026-09-23T02:00:00.000Z')],
          ),
        ],
      });
      await rig.ledger.sync();
      await rig.ledger.sync();
      expect(rig.ledger.platforms.map((p) => p.id), ['tb']);
      expect(rig.ledger.snapshot.activePlatforms, isEmpty);
      expect(rig.ledger.benefits, isEmpty);
    });

    test('P1 留下的缓存（有 assets / holdings、没有会员权益四个键）：游标归零，从头拉一遍', () async {
      final rig = Rig({
        'GET $api/changes': [changes(next: 80, platforms: [platformRow('tb')], memberships: [membershipRow('vip')])],
      });
      await rig.store.write(LedgerRepo.cacheKey, {
        'members': <Object>[],
        'accounts': <Object>[],
        'funds': <Object>[],
        'categories': <Object>[],
        'rules': <Object>[],
        'budgets': <Object>[],
        'assets': <Object>[],
        'holdings': <Object>[],
        'seq': 42,
      });
      await rig.ledger.load();
      await rig.ledger.sync();
      expect(rig.server.all('GET', '$api/changes').first.url.queryParameters['since'], '0');
      expect(rig.ledger.memberships.single.id, 'vip');
      expect(rig.ledger.seq, 80);
    });

    test('四个键都在的新缓存照常从上次的游标接着拉', () async {
      final rig = Rig({
        'GET $api/changes': [changes(next: 43)],
      });
      await rig.store.write(LedgerRepo.cacheKey, {
        'assets': <Object>[],
        'holdings': <Object>[],
        'platforms': [platformRow('tb')],
        'memberships': <Object>[],
        'benefits': <Object>[],
        'benefit_events': <Object>[],
        'seq': 42,
      });
      await rig.ledger.load();
      await rig.ledger.sync();
      expect(rig.server.all('GET', '$api/changes').single.url.queryParameters['since'], '42');
      expect(rig.ledger.platforms.single.id, 'tb');
    });

    test('full=true 连四张表一起清掉重来', () async {
      final rig = Rig({
        'GET $api/changes': [
          changes(next: 2, platforms: [platformRow('old')], benefits: [benefitRow('b-old')], events: [eventRow('e-old', 'b-old')]),
          changes(next: 2, platforms: [platformRow('new')]),
        ],
      });
      await rig.ledger.sync();
      await rig.ledger.sync(full: true);
      expect(rig.ledger.platforms.single.id, 'new');
      expect(rig.ledger.benefits, isEmpty);
      expect(rig.ledger.benefitEvents, isEmpty);
    });

    test('本地级联：dropMembership(cascade) 连权益和事件拿掉；dropBenefit(cascade) 连选项拿掉', () async {
      final rig = Rig({
        'GET $api/changes': [
          changes(
            next: 2,
            memberships: [membershipRow('vip'), membershipRow('plus', name: 'PLUS')],
            benefits: [
              benefitRow('b1'),
              benefitRow('c1', name: '二选一'),
              benefitRow('o1', parentId: 'c1'),
              benefitRow('b9', membershipId: 'plus'),
            ],
            events: [eventRow('e1', 'b1'), eventRow('e9', 'b9')],
          ),
        ],
      });
      await rig.ledger.sync();
      await rig.ledger.dropBenefit('c1', cascade: true);
      expect(rig.ledger.benefits.map((b) => b.id), ['b1', 'b9']);
      await rig.ledger.dropMembership('vip', cascade: true);
      expect(rig.ledger.memberships.map((m) => m.id), ['plus']);
      expect(rig.ledger.benefits.map((b) => b.id), ['b9']);
      expect(rig.ledger.benefitEvents.map((e) => e.id), ['e9']);
    });
  });
}
