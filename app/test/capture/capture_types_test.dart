import 'dart:convert';

import 'package:famledger/capture/capture_types.dart';
import 'package:famledger/capture/classifier.dart';
import 'package:famledger/capture/parser.dart';
import 'package:famledger/capture/pipeline.dart';
import 'package:flutter_test/flutter_test.dart';

/// 这些序列化/适配入口给 Task 13（本地存储 + MethodChannel）用，
/// 管线内部不走，所以单独钉住。
void main() {
  group('CaptureRule', () {
    test('JSON 往返', () {
      const rule = CaptureRule(
        id: 'r1',
        priority: 7,
        field: 'merchant',
        op: 'contains',
        pattern: '美团',
        categoryId: 'c1',
        fundId: 'f1',
        accountId: 'a1',
        memberId: 'm1',
      );
      final back = CaptureRule.fromJson(
          jsonDecode(jsonEncode(rule.toJson())) as Map<String, dynamic>);
      expect(back.toJson(), rule.toJson());
    });

    test('缺省字段有安全默认值', () {
      final rule = CaptureRule.fromJson(<String, dynamic>{'id': 'x'});
      expect(rule.field, 'text');
      expect(rule.op, 'contains');
      expect(rule.enabled, isTrue);
      expect(rule.matches(merchant: '', text: '任意', app: ''), isFalse);
    });

    test('非法正则不抛异常', () {
      const rule = CaptureRule(
          id: 'bad', priority: 1, field: 'text', op: 'regex', pattern: '[');
      expect(rule.matches(merchant: '', text: '美团', app: ''), isFalse);
    });
  });

  group('CaptureAccount', () {
    test('matchHints 读取与 JSON 往返', () {
      const account = CaptureAccount(
        id: 'acc',
        name: '招行信用卡',
        kind: 'credit',
        matchHints: <String, dynamic>{
          'cardTails': <String>['1234'],
          'packages': <String>['cmb.pb'],
          'keywords': <String>['招商银行'],
        },
      );
      expect(account.cardTails, <String>['1234']);
      expect(account.packages, <String>['cmb.pb']);
      expect(account.keywords, <String>['招商银行']);
      final back = CaptureAccount.fromJson(
          jsonDecode(jsonEncode(account.toJson())) as Map<String, dynamic>);
      expect(back.cardTails, <String>['1234']);
      expect(back.kind, 'credit');
    });

    test('没有 matchHints 时返回空列表', () {
      const account = CaptureAccount(id: 'a', name: '现金', kind: 'cash');
      expect(account.cardTails, isEmpty);
      expect(account.packages, isEmpty);
      expect(account.keywords, isEmpty);
    });
  });

  group('CaptureDraft', () {
    final draft = CaptureDraft(
      clientId: 'cap-1',
      type: 'expense',
      amountCents: 3500,
      occurredAt: DateTime(2026, 9, 12, 12, 30),
      accountId: 'acc-1',
      fundId: 'fund-1',
      categoryId: 'cat-1',
      memberId: 'mem-1',
      merchant: '美团',
      note: '午饭',
      status: 'confirmed',
      confidence: 0.92,
      rawText: '支付宝 你有一笔35.00元的支出，来自美团',
      sourceApp: 'com.eg.android.AlipayGphone',
      captureId: 'cap-1',
    );

    test('toJson 是 POST /transactions 的请求体形状', () {
      final json = draft.toJson();
      expect(json['source'], 'notification');
      // 服务端拒收没有时区偏移的 occurredAt（400 invalid_occurredAt）
      expect(json['occurredAt'], isoLocal(draft.occurredAt));
      expect(json['occurredAt'], isNot(endsWith('Z')));
      expect(DateTime.parse(json['occurredAt'] as String).toLocal(),
          draft.occurredAt);
      expect(() => jsonEncode(json), returnsNormally);
    });

    test('copyWith 传 null 表示「不改」', () {
      final json = draft.copyWith(fundId: null, categoryId: null).toJson();
      expect(json['fundId'], 'fund-1');
      expect(json['categoryId'], 'cat-1');
    });

    test('没有基金/类别/账户时这些键不出现在请求体里', () {
      final bare = CaptureDraft(
        clientId: 'c',
        type: 'expense',
        amountCents: 100,
        occurredAt: DateTime(2026, 9, 12),
        memberId: 'm',
        status: 'pending',
        confidence: 0,
        rawText: '',
        sourceApp: '',
        captureId: 'c',
      ).toJson();
      expect(bare.containsKey('fundId'), isFalse);
      expect(bare.containsKey('categoryId'), isFalse);
      expect(bare.containsKey('accountId'), isFalse);
      expect(bare['status'], 'pending');
    });

    test('JSON 往返', () {
      final back = CaptureDraft.fromJson(
          jsonDecode(jsonEncode(draft.toJson())) as Map<String, dynamic>);
      expect(back.toJson(), draft.toJson());
      expect(back.occurredAt, draft.occurredAt);
    });

    test('copyWith 只改传入的字段', () {
      final changed = draft.copyWith(fundId: 'fund-2', note: '晚饭');
      expect(changed.fundId, 'fund-2');
      expect(changed.note, '晚饭');
      expect(changed.categoryId, 'cat-1');
      expect(changed.amountCents, 3500);
      expect(changed.captureId, draft.captureId);
    });
  });

  group('isoLocal', () {
    String expectedOffset(DateTime dt) {
      final o = dt.timeZoneOffset;
      final sign = o.isNegative ? '-' : '+';
      final hh = o.inHours.abs().toString().padLeft(2, '0');
      final mm = (o.inMinutes.abs() % 60).toString().padLeft(2, '0');
      return '$sign$hh:$mm';
    }

    test('本地时间 + 偏移，秒级精度，没有毫秒也不是 Z', () {
      final dt = DateTime(2026, 9, 5, 1, 0, 0, 123);
      final text = isoLocal(dt);
      expect(text, '2026-09-05T01:00:00${expectedOffset(dt)}');
      expect(text, isNot(contains('.')));
      expect(text, isNot(endsWith('Z')));
      expect(RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$')
          .hasMatch(text), isTrue);
    });

    test('补零与往返解析', () {
      final dt = DateTime(2026, 1, 2, 3, 4, 5);
      expect(isoLocal(dt), '2026-01-02T03:04:05${expectedOffset(dt)}');
      expect(DateTime.parse(isoLocal(dt)).toLocal(), dt);
    });

    test('UTC 时间先转本地再输出，绝不输出 Z', () {
      final utc = DateTime.utc(2026, 9, 5, 1);
      final text = isoLocal(utc);
      expect(text, isNot(endsWith('Z')));
      expect(DateTime.parse(text).toUtc(), utc);
    });
  });

  group('CaptureRecord', () {
    test('JSON 往返', () {
      final record = CaptureRecord(
        captureId: 'cap-1',
        decision: CaptureDecision.pending,
        draft: CaptureDraft(
          clientId: 'cap-1',
          type: 'expense',
          amountCents: 3500,
          occurredAt: DateTime(2026, 9, 12, 12, 30),
          memberId: 'mem-1',
          merchant: '美团',
          status: 'pending',
          confidence: 0.3,
          rawText: '来自美团',
          sourceApp: 'com.eg.android.AlipayGphone',
          captureId: 'cap-1',
        ),
        dedupeHash: 'abcdef0123456789',
        learnText: '美团',
        features: const CaptureFeatures(
          merchant: '美团',
          direction: 'expense',
          channel: 'alipay',
          amountCents: 3500,
          hour: 12,
          weekday: 6,
          memberId: 'mem-1',
        ),
        createdAt: DateTime(2026, 9, 12, 12, 30),
        transactionId: 'tx-1',
        synced: true,
      );
      final back = CaptureRecord.fromJson(
          jsonDecode(jsonEncode(record.toJson())) as Map<String, dynamic>);
      expect(back.toJson(), record.toJson());
      expect(back.decision, CaptureDecision.pending);
      expect(back.extras, <String>[
        'm:美团',
        'dir:expense',
        'ch:alipay',
        'amt:b1',
        'h:12',
        'wd:6',
        'mem:mem-1',
      ]);
      expect(back.createdAt, record.createdAt);
      expect(back.needsRetry, isFalse);
    });

    test('4xx 拒绝后不再重试，断网则继续重试', () {
      final base = CaptureRecord(
        captureId: 'cap-1',
        decision: CaptureDecision.pending,
        draft: CaptureDraft(
          clientId: 'cap-1',
          type: 'expense',
          amountCents: 100,
          occurredAt: DateTime(2026, 9, 12),
          memberId: 'm',
          status: 'pending',
          confidence: 0,
          rawText: '',
          sourceApp: '',
          captureId: 'cap-1',
        ),
        dedupeHash: 'h',
        learnText: '',
        features: const CaptureFeatures(hour: 0, weekday: 1),
        createdAt: DateTime(2026, 9, 12),
      );
      expect(base.needsRetry, isTrue);
      expect(base.copyWith(syncError: '转账要成对').needsRetry, isFalse);
      expect(base.copyWith(synced: true).needsRetry, isFalse);
      expect(
        base.copyWith(syncError: 'x').copyWith(clearSyncError: true).needsRetry,
        isTrue,
      );
    });
  });

  group('RawNotification', () {
    test('fromMap 兼容 MethodChannel 的字段与时间格式', () {
      final fromMillis = RawNotification.fromMap(<dynamic, dynamic>{
        'package': 'com.tencent.mm',
        'title': '微信支付',
        'text': '支付成功 ¥25.00',
        'bigText': '',
        'postedAt': DateTime(2026, 9, 12, 12, 30).millisecondsSinceEpoch,
      });
      expect(fromMillis.packageName, 'com.tencent.mm');
      expect(fromMillis.postedAt, DateTime(2026, 9, 12, 12, 30));

      final fromIso = RawNotification.fromMap(<dynamic, dynamic>{
        'packageName': 'com.unionpay',
        'postedAt': '2026-09-12T12:30:00',
      });
      expect(fromIso.packageName, 'com.unionpay');
      expect(fromIso.title, '');
      expect(fromIso.postedAt, DateTime(2026, 9, 12, 12, 30));
    });

    test('body 在 bigText 更完整时用 bigText，且不重复拼接', () {
      final n = RawNotification(
        packageName: 'p',
        title: '支付宝',
        text: '付款成功 ¥18.50',
        bigText: '付款成功 ¥18.50 收款方：瑞幸咖啡',
        postedAt: DateTime(2026, 9, 12, 9, 5),
      );
      expect(n.body, '付款成功 ¥18.50 收款方：瑞幸咖啡');
      expect(n.combinedText, '支付宝 付款成功 ¥18.50 收款方：瑞幸咖啡');

      final noBig = RawNotification(
        packageName: 'p',
        title: '支付宝',
        text: '付款成功 ¥18.50',
        postedAt: DateTime(2026, 9, 12, 9, 5),
      );
      expect(noBig.body, '付款成功 ¥18.50');
    });
  });

  test('formatYuan 带千分位', () {
    expect(formatYuan(3500), '35.00');
    expect(formatYuan(129900), '1,299.00');
    expect(formatYuan(85), '0.85');
    expect(formatYuan(123456789), '1,234,567.89');
  });

  test('captureHash 稳定且区分包名与文本', () {
    final a = captureHash('com.a', '文本');
    expect(a, captureHash('com.a', '文本'));
    expect(a, isNot(captureHash('com.b', '文本')));
    expect(a, isNot(captureHash('com.a', '文本2')));
    // 两轮 32 位 FNV-1a 拼出的 16 位小写十六进制
    expect(a, matches(RegExp(r'^[0-9a-f]{16}$')));
  });

  test('captureHash 是 web 安全的：不依赖 64 位整数', () {
    // 所有中间值都必须 < 2^53，dart2js 才能算出和 VM 一样的结果。
    // 这里顺带钉住具体取值，换实现时能立刻看出去重会不会全体失效。
    // 两个向量由独立的 FNV-1a 32 参考实现算出，换实现时能立刻发现不一致
    expect(captureHash('', ''), 'f90c4a3b05f3b432');
    expect(captureHash('com.a', '文本'), 'de0320085f7b7b5f');
    final hashes = <String>{
      for (var i = 0; i < 500; i++) captureHash('pkg', '文本 $i'),
    };
    expect(hashes, hasLength(500), reason: '短窗口去重不该撞车');
  });

  test('newCaptureId 每次不同', () {
    final ids = List<String>.generate(50, (_) => newCaptureId());
    expect(ids.toSet(), hasLength(50));
  });
}
