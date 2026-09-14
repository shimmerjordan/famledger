import 'dart:convert';
import 'dart:io';

import 'package:famledger/capture/parser.dart';
import 'package:famledger/capture/source_profiles.dart';
import 'package:flutter_test/flutter_test.dart';

/// `flutter test` 的工作目录是包根目录 `app/`。
const String _fixturePath = 'test/capture/fixtures/notifications.json';

List<Map<String, dynamic>> _loadFixtures() {
  final file = File(_fixturePath);
  final list = jsonDecode(file.readAsStringSync()) as List<dynamic>;
  return list.cast<Map<String, dynamic>>();
}

RawNotification _toNotification(Map<String, dynamic> f) => RawNotification(
      packageName: f['packageName'] as String,
      title: f['title'] as String,
      text: f['text'] as String,
      bigText: (f['bigText'] as String?) ?? '',
      postedAt: DateTime.parse(f['postedAt'] as String),
    );

void main() {
  final fixtures = _loadFixtures();
  const parser = NotificationParser();

  test('样本集覆盖度符合任务要求', () {
    expect(fixtures.length, greaterThanOrEqualTo(40));
    int byPkg(String pkg) =>
        fixtures.where((f) => f['packageName'] == pkg).length;
    int byChannel(String ch) => fixtures
        .where((f) => (f['expected'] as Map)['channel'] == ch)
        .length;
    expect(byPkg('com.eg.android.AlipayGphone'), greaterThanOrEqualTo(12));
    expect(byPkg('com.tencent.mm'), greaterThanOrEqualTo(12));
    expect(byPkg('com.unionpay'), greaterThanOrEqualTo(4));
    expect(byChannel('bank_sms'), greaterThanOrEqualTo(10));
    expect(
      fixtures
          .where((f) => (f['expected'] as Map)['isPayment'] == false)
          .length,
      greaterThanOrEqualTo(6),
    );
  });

  group('逐条样本解析', () {
    for (final f in fixtures) {
      final name = f['name'] as String;
      final expected = (f['expected'] as Map).cast<String, dynamic>();
      test(name, () {
        final parsed = parser.parse(_toNotification(f));
        expect(parsed.channel, expected['channel'], reason: '$name 渠道');
        expect(parsed.isPayment, expected['isPayment'],
            reason: '$name 是否支付通知');
        expect(parsed.sourceApp, f['packageName'], reason: '$name 来源包名');
        if (expected['isPayment'] != true) {
          return;
        }
        expect(parsed.amountCents, expected['amountCents'],
            reason: '$name 金额');
        expect(parsed.direction.name, expected['direction'],
            reason: '$name 方向');
        expect(parsed.parseConfidence, greaterThan(0.0), reason: '$name 置信度');
        expect(parsed.parseConfidence, lessThanOrEqualTo(1.0),
            reason: '$name 置信度上限');
        if (expected['merchantContains'] != null) {
          expect(parsed.merchant, contains(expected['merchantContains']),
              reason: '$name 商户');
        }
        if (expected['merchantEquals'] != null) {
          expect(parsed.merchant, expected['merchantEquals'],
              reason: '$name 商户（完全相等）');
        }
        if (expected['cardTail'] != null) {
          expect(parsed.cardTail, expected['cardTail'], reason: '$name 卡尾号');
        }
        if (expected['occurredAt'] != null) {
          expect(parsed.occurredAt,
              DateTime.parse(expected['occurredAt'] as String),
              reason: '$name 发生时间');
        }
      });
    }
  });

  test('商户抽取命中率 ≥ 80%', () {
    final withExpectation = fixtures
        .where((f) =>
            (f['expected'] as Map)['merchantContains'] != null ||
            (f['expected'] as Map)['merchantEquals'] != null)
        .toList();
    final hit = withExpectation.where((f) {
      final expected = f['expected'] as Map;
      final parsed = parser.parse(_toNotification(f));
      final exact = expected['merchantEquals'] as String?;
      if (exact != null) return parsed.merchant == exact;
      return parsed.merchant
          .contains(expected['merchantContains'] as String);
    }).length;
    final rate = hit / withExpectation.length;
    // ignore: avoid_print
    print('商户抽取：$hit/${withExpectation.length} = '
        '${(rate * 100).toStringAsFixed(1)}%');
    expect(rate, greaterThanOrEqualTo(0.8));
  });

  test('支付类金额与方向 100% 正确', () {
    final payments =
        fixtures.where((f) => (f['expected'] as Map)['isPayment'] == true);
    var ok = 0;
    var total = 0;
    for (final f in payments) {
      total++;
      final expected = f['expected'] as Map;
      final parsed = parser.parse(_toNotification(f));
      if (parsed.amountCents == expected['amountCents'] &&
          parsed.direction.name == expected['direction']) {
        ok++;
      }
    }
    // ignore: avoid_print
    print('金额+方向：$ok/$total');
    expect(ok, total);
  });

  group('解析细节', () {
    test('bigText 比 text 更完整时优先用于抽取', () {
      final parsed = parser.parse(RawNotification(
        packageName: 'com.eg.android.AlipayGphone',
        title: '支付宝',
        text: '付款成功 ¥18.50',
        bigText: '付款成功 ¥18.50 收款方：瑞幸咖啡',
        postedAt: DateTime(2026, 9, 12, 9, 5),
      ));
      expect(parsed.merchant, '瑞幸咖啡');
    });

    test('余额/尾号/验证码附近的数字不被当作金额', () {
      final parsed = parser.parse(RawNotification(
        packageName: 'com.miui.mms',
        title: '招商银行',
        text: '【招商银行】您尾号1234的账户余额为10,000.00元。',
        bigText: '',
        postedAt: DateTime(2026, 9, 12, 9, 30),
      ));
      expect(parsed.amountCents, isNull);
      expect(parsed.isPayment, isFalse);
    });

    test('无金额的微信聊天消息判为噪声', () {
      final parsed = parser.parse(RawNotification(
        packageName: 'com.tencent.mm',
        title: '张三',
        text: '晚上一起吃饭吗',
        bigText: '',
        postedAt: DateTime(2026, 9, 12, 18, 0),
      ));
      expect(parsed.isPayment, isFalse);
      expect(parsed.channel, 'wechat');
    });

    test('微信聊天里出现金额但不是微信支付通知，仍判为噪声', () {
      final parsed = parser.parse(RawNotification(
        packageName: 'com.tencent.mm',
        title: '张三',
        text: '我等下转你 50.00 元',
        bigText: '',
        postedAt: DateTime(2026, 9, 12, 18, 0),
      ));
      expect(parsed.isPayment, isFalse);
    });

    test('银行短信解析出交易时间，否则回落到通知时间', () {
      final withTime = parser.parse(RawNotification(
        packageName: 'com.miui.mms',
        title: '招商银行',
        text: '【招商银行】您尾号1234的信用卡于09月12日12:30消费人民币35.00元，商户：美团。',
        bigText: '',
        postedAt: DateTime(2026, 9, 12, 12, 31),
      ));
      expect(withTime.occurredAt, DateTime(2026, 9, 12, 12, 30));

      final withoutTime = parser.parse(RawNotification(
        packageName: 'com.eg.android.AlipayGphone',
        title: '支付宝',
        text: '支付宝到账 88.00元',
        bigText: '',
        postedAt: DateTime(2026, 9, 12, 11, 11),
      ));
      expect(withoutTime.occurredAt, DateTime(2026, 9, 12, 11, 11));
    });

    test('商户名到括号为止', () {
      final parsed = parser.parse(RawNotification(
        packageName: 'com.eg.android.AlipayGphone',
        title: '支付宝',
        text: '支付成功 ¥33.00 商户：肯德基（已立减2元）',
        bigText: '',
        postedAt: DateTime(2026, 9, 12, 12, 10),
      ));
      expect(parsed.merchant, '肯德基');
      expect(parsed.amountCents, 3300);
      final store = parser.parse(RawNotification(
        packageName: 'com.eg.android.AlipayGphone',
        title: '支付宝',
        text: '向 星巴克(国贸店) 付款32.00元',
        bigText: '',
        postedAt: DateTime(2026, 9, 12, 8, 15),
      ));
      expect(store.merchant, '星巴克');
    });

    test('营销文案里的「8元券」不是流水金额', () {
      final parsed = parser.parse(RawNotification(
        packageName: 'com.eg.android.AlipayGphone',
        title: '支付宝',
        text: '限时优惠：领取8元券，消费立减，点击查看',
        bigText: '',
        postedAt: DateTime(2026, 9, 12, 10, 3),
      ));
      expect(parsed.isPayment, isFalse);
      expect(parsed.amountCents, isNull);
    });

    test('未知包名走通用兜底，置信度低于专用渠道', () {
      final generic = parser.parse(RawNotification(
        packageName: 'com.example.pay',
        title: '某支付',
        text: '交易 ¥15.00',
        bigText: '',
        postedAt: DateTime(2026, 9, 12, 14, 10),
      ));
      final alipay = parser.parse(RawNotification(
        packageName: 'com.eg.android.AlipayGphone',
        title: '支付宝',
        text: '你有一笔35.00元的支出，来自美团',
        bigText: '',
        postedAt: DateTime(2026, 9, 12, 12, 30),
      ));
      expect(generic.channel, 'unknown');
      expect(generic.direction, PayDirection.unknown);
      expect(generic.parseConfidence, lessThan(alipay.parseConfidence));
    });
  });

  group('SourceProfile', () {
    test('按包名匹配到对应渠道', () {
      expect(SourceProfile.forPackage('com.eg.android.AlipayGphone').channel,
          'alipay');
      expect(SourceProfile.forPackage('com.tencent.mm').channel, 'wechat');
      expect(SourceProfile.forPackage('com.unionpay').channel, 'unionpay');
      expect(SourceProfile.forPackage('com.miui.mms').channel, 'bank_sms');
      expect(
          SourceProfile.forPackage('com.samsung.android.messaging').channel,
          'bank_sms');
      expect(SourceProfile.forPackage('com.foo.bar').channel, 'unknown');
    });

    test('iOS 三个导入来源各有画像，不掉进通用兜底', () {
      for (final source in kIosImportSources) {
        final profile = SourceProfile.forPackage(source);
        expect(profile.channel, 'share', reason: source);
        expect(profile.baseConfidence, 0.85, reason: source);
        expect(profile.titleFallbackMerchant, isFalse, reason: source);
        expect(profile.id, isNot('generic'), reason: source);
      }
      expect(SourceProfile.displayNameOfSource(kIosShareSource), '分享导入');
      expect(SourceProfile.displayNameOfSource(kIosShortcutSource), '快捷指令');
      expect(SourceProfile.displayNameOfSource(kIosClipboardSource), '剪贴板');
      expect(SourceProfile.displayNameOfChannel('share'), '分享导入');
    });

    test('iOS 导入来源不是通知包名，不进默认允许列表', () {
      for (final source in kIosImportSources) {
        expect(kDefaultAllowedPackages, isNot(contains(source)));
      }
      expect(kDefaultAllowedPackages, hasLength(17));
    });

    test('分享进来的文本照样解析，置信度 ≥ 0.85', () {
      for (final source in kIosImportSources) {
        final parsed = parser.parse(RawNotification(
          packageName: source,
          title: '',
          text: '星巴克 消费 ¥38.00',
          bigText: '',
          postedAt: DateTime(2026, 9, 13, 10),
        ));
        expect(parsed.isPayment, isTrue, reason: source);
        expect(parsed.channel, 'share', reason: source);
        expect(parsed.amountCents, 3800, reason: source);
        expect(parsed.direction, PayDirection.expense, reason: source);
        expect(parsed.parseConfidence, greaterThanOrEqualTo(0.85),
            reason: source);
        expect(parsed.occurredAt, DateTime(2026, 9, 13, 10), reason: source);
      }
    });

    test('分享文本里有结构化商户时照样抽得出来', () {
      final parsed = parser.parse(RawNotification(
        packageName: kIosClipboardSource,
        title: '',
        text: '交易成功 ¥38.00 商户：星巴克',
        bigText: '',
        postedAt: DateTime(2026, 9, 13, 10),
      ));
      expect(parsed.merchant, '星巴克');
      expect(parsed.parseConfidence, 0.85);
    });

    test('标题不会被当成商户（分享来的标题多是 App 名）', () {
      final parsed = parser.parse(RawNotification(
        packageName: kIosShareSource,
        title: '微信',
        text: '消费 ¥38.00',
        bigText: '',
        postedAt: DateTime(2026, 9, 13, 10),
      ));
      expect(parsed.merchant, isEmpty);
    });

    test('默认允许监听的包名包含 spec 列出的应用', () {
      expect(
        kDefaultAllowedPackages,
        containsAll(<String>[
          'com.eg.android.AlipayGphone',
          'com.tencent.mm',
          'com.unionpay',
          'com.miui.mms',
          'com.android.mms',
          'com.google.android.apps.messaging',
          'com.samsung.android.messaging',
        ]),
      );
    });
  });
}
