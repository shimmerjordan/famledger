import 'dart:convert';
import 'dart:typed_data';

import 'package:famledger/data/api/api_client.dart';
import 'package:famledger/data/repos/import_repo.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response jsonResponse(Object body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

ImportRepo repoWith(MockClient client) => ImportRepo(
  ApiClient(baseUrl: 'https://x.dev', token: 'tok', inner: client),
);

ImportRow row(
  int n, {
  String merchant = '',
  String note = '',
  String type = 'expense',
}) => ImportRow(
  row: n,
  clientId: 'imp-$n',
  type: type,
  amountCents: 100 * n,
  occurredAt: '2026-09-13T21:05:00+08:00',
  merchant: merchant,
  note: note,
  accountId: 'a1',
);

/// 按请求里的 clientId 回结果；[status] 决定每一行怎么回。
MockClient batchServer(
  List<http.Request> seen, {
  String Function(String clientId)? status,
  int? failOnBatch,
}) {
  var batches = 0;
  return MockClient((request) async {
    seen.add(request);
    if (request.url.path.endsWith('/transactions/batch')) {
      batches++;
      if (failOnBatch == batches) {
        throw http.ClientException('Connection refused');
      }
      final items = (jsonDecode(request.body)['items'] as List)
          .cast<Map<String, dynamic>>();
      return jsonResponse({
        'results': [
          for (final item in items)
            switch (status?.call(item['clientId'] as String) ?? 'created') {
              'error' => {
                'clientId': item['clientId'],
                'status': 'error',
                'error': 'invalid_categoryId',
                'message': '类别不存在',
              },
              final s => {
                'clientId': item['clientId'],
                'id': 'tx-${item['clientId']}',
                'status': s,
              },
            },
        ],
      });
    }
    if (request.url.path.endsWith('/model/learn')) {
      return jsonResponse({
        'version': 2,
        'learned': {'category': 1, 'fund': 0},
      });
    }
    return jsonResponse({}, status: 404);
  });
}

List<Map<String, dynamic>> bodiesOf(List<http.Request> seen, String path) => [
  for (final r in seen)
    if (r.url.path.endsWith(path)) jsonDecode(r.body) as Map<String, dynamic>,
];

void main() {
  group('预览', () {
    test('base64 上传文件，按服务端的字段读回每一行', () async {
      late http.Request seen;
      final repo = repoWith(
        MockClient((request) async {
          seen = request;
          return jsonResponse({
            'source': 'alipay',
            'sourceLabel': '支付宝账单',
            'total': 2,
            'importable': 1,
            'skipped': 1,
            'rows': [
              {
                'row': 1,
                'clientId': 'imp-0123456789abcdef',
                'type': 'expense',
                'amountCents': 3500,
                'occurredAt': '2026-09-15T12:30:05+08:00',
                'merchant': '美团',
                'note': '午餐',
                'rawCategory': '餐饮美食',
                'categoryId': 'c1',
                'fundId': null,
                'accountId': 'a1',
                'confidence': 0.82,
                'skip': null,
                'exists': true,
                'duplicateOf': null,
                'hint': null,
              },
              {
                'row': 2,
                'clientId': 'imp-2',
                'type': 'expense',
                'amountCents': 50000,
                'occurredAt': '2026-09-14T08:00:00+08:00',
                'merchant': '余额宝',
                'note': '',
                'rawCategory': null,
                'categoryId': null,
                'fundId': null,
                'accountId': null,
                'confidence': null,
                'skip': {'code': 'neutral', 'message': '不计收支'},
                'exists': false,
                'duplicateOf': 'tx-9',
                'hint': null,
              },
            ],
          });
        }),
      );

      final bytes = Uint8List.fromList(utf8.encode('交易时间,收/支\n'));
      final preview = await repo.preview(filename: 'alipay.csv', bytes: bytes);

      expect(seen.method, 'POST');
      expect(seen.url.path, '/api/v1/import/preview');
      final body = jsonDecode(seen.body) as Map<String, dynamic>;
      expect(body['filename'], 'alipay.csv');
      expect(base64Decode(body['data'] as String), bytes);

      expect(preview.source, 'alipay');
      expect(preview.channel, 'alipay');
      expect(preview.sourceLabel, '支付宝账单');
      expect([preview.total, preview.importable, preview.skipped], [2, 1, 1]);
      final first = preview.rows.first;
      expect(first.clientId, 'imp-0123456789abcdef');
      expect(first.amountCents, 3500);
      expect(first.confidence, closeTo(0.82, 1e-9));
      expect(first.exists, isTrue);
      expect(first.importable, isTrue);
      // 按串里写的钟点读，不随本机时区漂。
      expect(first.wallTime, DateTime(2026, 9, 15, 12, 30));
      final skipped = preview.rows.last;
      expect(skipped.skip?.code, 'neutral');
      expect(skipped.importable, isFalse);
      expect(skipped.isDuplicate, isTrue);
    });

    test('认不出的表格：把服务端的中文说明原样抛出来', () async {
      final repo = repoWith(
        MockClient(
          (request) async => jsonResponse({
            'error': {
              'code': 'unsupported_file',
              'message': '认不出这个表格：支持支付宝账单、微信账单和通用模板',
            },
          }, status: 400),
        ),
      );
      await expectLater(
        repo.preview(filename: 'x.csv', bytes: Uint8List(3)),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'unsupported_file')
              .having((e) => e.message, 'message', contains('认不出')),
        ),
      );
    });

    test('请求体大小按真正发出去的 JSON 算（含外壳和中文文件名），卡在 8MB 上的文件不算放得下', () async {
      String? sent;
      final repo = repoWith(
        MockClient((request) async {
          sent = request.body;
          return jsonResponse({'source': 'template', 'rows': <Object>[]});
        }),
      );
      for (final (name, n) in [
        ('a.csv', 0),
        ('a.csv', 1),
        ('微信账单.xlsx', 2),
        ('b.csv', 3),
        ('b.csv', 1000),
      ]) {
        await repo.preview(filename: name, bytes: Uint8List(n));
        expect(
          ImportRepo.requestBytes(name, n),
          utf8.encode(sent!).length,
          reason: '$name / $n 字节',
        );
      }
      expect(ImportRepo.fits('ok.csv', 6291432), isTrue);
      expect(ImportRepo.fits('ok.csv', 6291433), isFalse);
      expect(ImportRepo.fits('a.csv', ImportRepo.maxFileBytes), isFalse);
    });

    test('模板没有渠道：channel 为空，训练样本不带 ch 特征', () {
      final preview = ImportPreview.fromJson({
        'source': 'template',
        'sourceLabel': '通用模板',
        'rows': [],
      });
      expect(preview.channel, '');
    });
  });

  group('提交', () {
    test('450 笔分 200/200/50 三批，每笔带 source:import 与 clientId，逐批汇总', () async {
      final seen = <http.Request>[];
      final repo = repoWith(
        batchServer(
          seen,
          status: (id) => switch (id) {
            'imp-3' => 'exists',
            'imp-201' => 'error',
            _ => 'created',
          },
        ),
      );
      final items = [
        for (var n = 1; n <= 450; n++)
          ImportItem(
            row: row(n, merchant: '店$n'),
            categoryId: 'c1',
          ),
      ];
      final progress = <int>[];

      final result = await repo.submit(
        items,
        channel: 'alipay',
        memberId: 'm1',
        onProgress: (done, total) {
          expect(total, 450);
          progress.add(done);
        },
      );

      final batches = bodiesOf(seen, '/transactions/batch');
      expect(batches.map((b) => (b['items'] as List).length), [200, 200, 50]);
      final first =
          (batches.first['items'] as List).first as Map<String, dynamic>;
      expect(first, {
        'clientId': 'imp-1',
        'type': 'expense',
        'amountCents': 100,
        'occurredAt': '2026-09-13T21:05:00+08:00',
        'merchant': '店1',
        'note': '',
        'source': 'import',
        'categoryId': 'c1',
        'accountId': 'a1',
      });
      expect(progress, [0, 200, 400, 450]);
      expect(result.created, 448);
      expect(result.exists, 1);
      expect(result.failed, 1);
      expect(result.failures.single.row, 201);
      expect(result.failures.single.message, '类别不存在');
      // 一行都没改过类别/基金：不训练。
      expect(bodiesOf(seen, '/model/learn'), isEmpty);
    });

    test('中途断网：这一批和后面的都记成没导进去，不再往下发', () async {
      final seen = <http.Request>[];
      final repo = repoWith(batchServer(seen, failOnBatch: 2));
      final items = [for (var n = 1; n <= 450; n++) ImportItem(row: row(n))];

      final result = await repo.submit(
        items,
        channel: 'alipay',
        memberId: 'm1',
      );

      expect(
        seen.where((r) => r.url.path.endsWith('/transactions/batch')),
        hasLength(2),
      );
      expect(result.created, 200);
      expect(result.failed, 250);
      expect(result.failures.first.row, 201);
      expect(result.failures.first.code, 'network');
    });

    test('learn 只发改过类别/基金、而且真的入了库的行，样本形状对得上服务端', () async {
      final seen = <http.Request>[];
      final repo = repoWith(
        batchServer(seen, status: (id) => id == 'imp-4' ? 'error' : 'created'),
      );
      final items = [
        ImportItem(
          row: row(1, merchant: '美团', note: '午餐'),
          categoryId: 'c1',
          categoryChanged: true,
        ),
        ImportItem(
          row: row(2, note: '超市采购'),
          categoryId: 'c2',
          fundId: 'f2',
          fundChanged: true,
        ),
        ImportItem(
          row: row(3, merchant: '滴滴'),
          categoryId: 'c3',
        ),
        ImportItem(
          row: row(4, merchant: '被拒的'),
          categoryId: 'c1',
          categoryChanged: true,
        ),
        // 改成「不设类别」不是一条能学的纠正。
        ImportItem(row: row(5, merchant: '清空的'), categoryChanged: true),
      ];

      final result = await repo.submit(
        items,
        channel: 'wechat',
        memberId: 'm1',
      );

      final learn = bodiesOf(seen, '/model/learn');
      expect(learn, hasLength(1));
      final samples = (learn.single['samples'] as List)
          .cast<Map<String, dynamic>>();
      expect(samples, [
        {
          'text': '美团',
          'merchant': '美团',
          'direction': 'expense',
          'channel': 'wechat',
          'amountCents': 100,
          'hour': 21,
          'weekday': 7,
          'memberId': 'm1',
          'categoryId': 'c1',
        },
        {
          'text': '超市采购',
          'direction': 'expense',
          'channel': 'wechat',
          'amountCents': 200,
          'hour': 21,
          'weekday': 7,
          'memberId': 'm1',
          'fundId': 'f2',
        },
      ]);
      expect(result.learned, 2);
      expect(result.learnError, isNull);
    });

    test('learn 超过 500 条按 500 一包发；关掉开关就一条都不发', () async {
      final seen = <http.Request>[];
      final items = [
        for (var n = 1; n <= 620; n++)
          ImportItem(
            row: row(n, merchant: '店$n'),
            categoryId: 'c1',
            categoryChanged: true,
          ),
      ];

      final result = await repoWith(
        batchServer(seen),
      ).submit(items, channel: 'alipay', memberId: 'm1');
      expect(
        bodiesOf(
          seen,
          '/model/learn',
        ).map((b) => (b['samples'] as List).length),
        [500, 120],
      );
      expect(result.learned, 620);

      seen.clear();
      await repoWith(
        batchServer(seen),
      ).submit(items, channel: 'alipay', memberId: 'm1', learn: false);
      expect(bodiesOf(seen, '/model/learn'), isEmpty);
    });

    test('训练失败不影响导入结果，只多一句说明', () async {
      final repo = repoWith(
        MockClient((request) async {
          if (request.url.path.endsWith('/model/learn')) {
            return jsonResponse({
              'error': {'code': 'model_too_large', 'message': '模型超出上限'},
            }, status: 400);
          }
          final items = (jsonDecode(request.body)['items'] as List)
              .cast<Map<String, dynamic>>();
          return jsonResponse({
            'results': [
              for (final item in items)
                {'clientId': item['clientId'], 'id': 'x', 'status': 'created'},
            ],
          });
        }),
      );
      final result = await repo.submit(
        [
          ImportItem(
            row: row(1, merchant: '美团'),
            categoryId: 'c1',
            categoryChanged: true,
          ),
        ],
        channel: 'alipay',
        memberId: 'm1',
      );
      expect(result.created, 1);
      expect(result.learned, 0);
      expect(result.learnError, '模型超出上限');
    });

    test('训练样本按 UTF-16 截长，不把表情从中间劈开', () {
      final long = '😀' * 300; // 600 个 UTF-16 码元
      final sample = ImportItem(
        row: row(1, merchant: long),
        categoryId: 'c1',
        categoryChanged: true,
      ).learnSample(channel: '', memberId: '').toJson();
      final text = sample['text'] as String;
      final merchant = sample['merchant'] as String;
      expect(text.length, lessThanOrEqualTo(500));
      expect(merchant.length, lessThanOrEqualTo(100));
      expect(text.runes.every((r) => r == 0x1F600), isTrue);
      expect(merchant.runes.every((r) => r == 0x1F600), isTrue);
      expect(sample.containsKey('channel'), isFalse);
      expect(sample.containsKey('memberId'), isFalse);
    });
  });
}
