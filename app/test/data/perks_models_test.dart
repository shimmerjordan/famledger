import 'package:famledger/data/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PerkPlatform', () {
    test('fromJson/toJson 往返', () {
      final json = {
        'id': 'p1',
        'name': '淘宝',
        'aliases': ['天猫', 'Tmall'],
        'kind': 'shopping',
        'icon': 'shopping_bag',
        'color': '#c25430',
        'url': 'https://www.taobao.com',
        'note': '家里的号',
        'sortOrder': 2,
        'archived': true,
      };
      expect(PerkPlatform.fromJson(json).toJson(), json);
    });

    test('缺字段、不认识的类型按默认', () {
      final p = PerkPlatform.fromJson({'id': 'p1', 'name': '优酷', 'kind': 'metaverse'});
      expect(p.kind, 'other');
      expect(p.kindLabel, '其他');
      expect(p.aliases, isEmpty);
      expect(p.archived, isFalse);
    });

    test('matches / sameName：名字和别名都算，全角、大小写、空格、标点不计较', () {
      const p = PerkPlatform(id: 'p1', name: 'Youku 优酷', aliases: ['合一']);
      expect(p.matches(''), isTrue);
      expect(p.matches('you'), isTrue);
      expect(p.matches('ＹＯＵ'), isTrue);
      expect(p.matches('合'), isTrue);
      expect(p.matches('爱奇艺'), isFalse);
      expect(p.sameName('youku·优酷'), isTrue);
      expect(p.sameName(' 合一 '), isTrue);
      expect(p.sameName('优酷'), isFalse, reason: '只是包含，不算同名');
      expect(p.sameName('！！'), isFalse, reason: '规范化后是空的不算');
    });
  });

  test('perkNameKey：全角折半角 → 小写 → 去空白和标点', () {
    expect(perkNameKey('ＹＯＵＫＵ　优酷'), 'youku优酷');
    expect(perkNameKey('京东 PLUS（年卡）'), '京东plus年卡');
    expect(perkNameKey('Tencent·Video!'), 'tencentvideo');
    expect(perkNameKey('８８ＶＩＰ'), '88vip');
  });

  group('Membership', () {
    test('fromJson/toJson 往返（含 payPattern、origin 这些原样存着的）', () {
      final json = {
        'id': 'm1',
        'platformId': 'p1',
        'name': '88VIP',
        'kind': 'membership',
        'feePeriod': 'year',
        'autoRenew': 'yes',
        'isTrial': false,
        'sourceBenefitId': 'b0',
        'tier': '年卡',
        'memberId': 'u1',
        'feeCents': 8800,
        'termPaidCents': 0,
        'termStartOn': '2026-03-01',
        'expiresOn': '2027-02-28',
        'remindDays': 0,
        'payPattern': {'amountCents': 8800},
        'lastChargeTxId': 't1',
        'origin': {'src': 'ai', 'unverified': ['expiresOn']},
        'note': '妈妈的号',
        'sortOrder': 1,
        'archived': false,
      };
      expect(Membership.fromJson(json).toJson(), json);
    });

    test('缺字段、不认识的枚举按默认；title 带档位', () {
      final m = Membership.fromJson({
        'id': 'm1',
        'platformId': 'p1',
        'name': '经典白',
        'kind': 'nft',
        'feePeriod': 'week',
        'autoRenew': 'maybe',
      });
      expect(m.kind, 'membership');
      expect(m.feePeriod, 'year');
      expect(m.autoRenew, 'unknown');
      expect(m.isTrial, isFalse);
      expect(m.origin, isEmpty);
      expect(m.payPattern, isNull);
      expect(m.title, '经典白');
      expect(const Membership(id: 'x', platformId: 'p', name: '经典白', tier: '金卡').title, '经典白 · 金卡');
    });
  });

  group('Benefit', () {
    test('fromJson/toJson 往返', () {
      final json = {
        'id': 'b1',
        'membershipId': 'm1',
        'name': '优酷VIP年卡',
        'kind': 'subscription',
        'flow': 'claim_use',
        'quota': [
          {'p': 'year', 'n': 6},
          {'p': 'month', 'n': 2},
        ],
        'anchor': 'term',
        'limits': [
          {'type': 'min_spend', 'text': '满 99 可用'},
        ],
        'remind': false,
        'parentId': 'c1',
        'claimPlatformId': 'p2',
        'claimHow': '优酷App › 我的',
        'claimUrl': 'https://vip.youku.com',
        'validFrom': '2026-01-01',
        'validUntil': '2026-12-31',
        'faceValueCents': 24800,
        'myValueCents': 10000,
        'origin': {'src': 'ai'},
        'note': '二选一',
        'sortOrder': 3,
        'archived': false,
      };
      expect(Benefit.fromJson(json).toJson(), json);
    });

    test('缺字段按默认：不限次、领到手就算、自然周期、要提醒', () {
      final b = Benefit.fromJson({'id': 'b1', 'membershipId': 'm1', 'name': '券'});
      expect(b.kind, 'other');
      expect(b.flow, Benefit.flowClaim);
      expect(b.quota, isEmpty);
      expect(b.anchor, Benefit.anchorCalendar);
      expect(b.limits, isEmpty);
      expect(b.remind, isTrue, reason: 'remind 缺字段按「要提醒」，不是 false');
      expect(b.isChoice, isFalse);
      expect(b.isOption, isFalse);
    });

    test('怪数据：不认识的枚举、坏的额度和限制条件被丢掉或兜底', () {
      final b = Benefit.fromJson({
        'id': 'b1',
        'membershipId': 'm1',
        'name': '券',
        'kind': 'gift',
        'flow': 'grant',
        'anchor': 'date',
        'quota': [
          {'p': 'decade', 'n': 1},
          {'p': 'month', 'n': 0},
          {'p': 'month', 'n': '4'},
          'year',
        ],
        'limits': [
          {'type': 'weather', 'text': '晴天'},
          {'type': 'other', 'text': '  '},
        ],
      });
      expect(b.kind, 'other');
      expect(b.flow, Benefit.flowClaim, reason: '以后的新 flow（如 grant）先按 claim 画');
      expect(b.anchor, Benefit.anchorCalendar);
      expect(b.quota, const [PerkQuota('month', 4)]);
      expect(b.limits, const [PerkLimit('other', '晴天')]);
    });
  });

  test('BenefitEvent：往返；count 缺省 1', () {
    final json = {
      'id': 'e1',
      'benefitId': 'b1',
      'kind': 'use',
      'occurredOn': '2026-09-01',
      'count': 2,
      'valueCents': 500,
      'memberId': 'u1',
      'note': '机场',
    };
    expect(BenefitEvent.fromJson(json).toJson(), json);
    final bare = BenefitEvent.fromJson({'id': 'e2', 'benefitId': 'b1', 'occurredOn': '2026-09-02', 'kind': 'teleport'});
    expect(bare.count, 1);
    expect(bare.kind, 'claim');
  });

  test('PerkPayPattern：缓存里的 Map 读成扣费特征（去空白、没有关键词当没设），写回只带有值的键', () {
    final p = PerkPayPattern.tryParse({
      'keywords': [' 腾讯视频 ', '', 3, 'QQ会员'],
      'minCents': 2000,
    })!;
    expect(p.keywords, ['腾讯视频', 'QQ会员']);
    expect((p.minCents, p.maxCents), (2000, null));
    expect(p.toJson(), {
      'keywords': ['腾讯视频', 'QQ会员'],
      'minCents': 2000,
    });
    expect(PerkPayPattern.tryParse(null), isNull);
    expect(PerkPayPattern.tryParse({'keywords': []}), isNull);
    expect(PerkPayPattern.tryParse({'merchant': '淘宝'}), isNull, reason: '不认识的形状当没设');
  });

  test('扣费线索的说法：「已看到 9/21 扣 ¥25.00 → 续到 10/20」；跨年写全年份', () {
    final today = parseDay('2026-09-23')!;
    const hint = ChargeHint(
      membershipId: 'tv',
      transactionId: 'tx1',
      occurredOn: '2026-09-21',
      amountCents: 2500,
      expiresOn: '2026-09-20',
      renewTo: '2026-10-20',
    );
    expect(chargeHintLine(hint, today), '已看到 9/21 扣 ¥25.00 → 续到 10/20');
    expect(perkSlashDay('2027-09-20', today), '2027/9/20');
    expect(perkSlashDay('坏的', today), '坏的');
  });
}
