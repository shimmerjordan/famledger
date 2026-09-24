import 'dart:convert';

import 'package:famledger/data/api/api_client.dart';
import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/data/local/outbox.dart';
import 'package:famledger/data/repos/transactions_repo.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// `POST /transactions/bulk` 的客户端：请求体形状以 server/src/modules/transactions.js 为准。
void main() {
  late List<http.Request> seen;
  late http.Response Function(http.Request) respond;
  var offline = false;

  ({TransactionsRepo repo, Outbox outbox}) build() {
    final outbox = Outbox(MemoryLocalStore());
    final client = MockClient((req) async {
      if (offline) throw http.ClientException('connection refused');
      seen.add(req);
      return respond(req);
    });
    return (
      repo: TransactionsRepo(
        api: ApiClient(baseUrl: 'https://x.dev', inner: client),
        outbox: outbox,
      ),
      outbox: outbox,
    );
  }

  http.Response json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  setUp(() {
    seen = [];
    offline = false;
    respond = (_) => json({'updated': 0});
  });

  Map<String, dynamic> bodyOf(http.Request req) =>
      jsonDecode(req.body) as Map<String, dynamic>;

  test('改：{ids, patch}，返回 updated', () async {
    respond = (_) => json({'updated': 2});
    final n = await build().repo.bulk(
      ['t1', 't2'],
      patch: {'categoryId': 'c2'},
    );

    expect(n, 2);
    expect(seen.single.method, 'POST');
    expect(seen.single.url.path, '/api/v1/transactions/bulk');
    expect(bodyOf(seen.single), {
      'ids': ['t1', 't2'],
      'patch': {'categoryId': 'c2'},
    });
  });

  test('删：{ids, delete: true}，不带 patch，返回 deleted', () async {
    respond = (_) => json({'deleted': 3});
    final n = await build().repo.bulk(['a', 'b', 'c'], delete: true);

    expect(n, 3);
    expect(bodyOf(seen.single), {
      'ids': ['a', 'b', 'c'],
      'delete': true,
    });
  });

  test('patch 和 delete 要恰好给一个，客户端先拦住', () async {
    final repo = build().repo;
    expect(() => repo.bulk(['a']), throwsArgumentError);
    expect(
      () => repo.bulk(['a'], patch: {'fundId': 'f1'}, delete: true),
      throwsArgumentError,
    );
    expect(seen, isEmpty);
  });

  test('服务端拒绝时把中文 message 原样抛出来', () async {
    respond = (_) => json({
      'error': {'code': 'not_found', 'message': '这笔流水不存在'},
    }, 404);

    await expectLater(
      build().repo.bulk(['gone'], delete: true),
      throwsA(
        isA<ApiException>()
            .having((e) => e.status, 'status', 404)
            .having((e) => e.code, 'code', 'not_found')
            .having((e) => e.message, 'message', '这笔流水不存在'),
      ),
    );
  });

  test('断网不进离线队列：一次事务，半截排队没有意义', () async {
    offline = true;
    final ctx = build();

    await expectLater(
      ctx.repo.bulk(['t1'], patch: {'fundId': 'f1'}),
      throwsA(
        isA<ApiException>().having((e) => e.isNetwork, 'isNetwork', true),
      ),
    );
    expect(await ctx.outbox.count(), 0);
  });
}
