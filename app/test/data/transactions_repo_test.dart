import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:famledger/data/api/api_client.dart';
import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/data/local/outbox.dart';
import 'package:famledger/data/models/models.dart';
import 'package:famledger/data/repos/transactions_repo.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

typedef Stub = FutureOr<Object> Function(http.Request req);

/// 可以随时「拔网线」的假服务端。
///
/// 桩可以返回 JSON 体（带 `error` 的算 400，其余 200），也可以直接返回一个
/// [http.Response] 自定状态码（见 [reject]）；桩本身可以是 async 的，
/// 用来在「请求已到服务端、回应还没回来」的窗口里做点事。
class FakeServer {
  FakeServer([Map<String, Stub>? routes]) : routes = routes ?? {};

  final Map<String, Stub> routes;
  final List<http.Request> seen = [];
  bool offline = false;

  http.Client get client => MockClient((req) async {
    if (offline) throw http.ClientException('connection refused');
    seen.add(req);
    final key = '${req.method} ${req.url.path}';
    final handler = routes[key];
    if (handler == null) {
      return http.Response(
        jsonEncode({'error': {'code': 'no_stub', 'message': key}}),
        500,
      );
    }
    final body = await handler(req);
    if (body is http.Response) return body;
    // 带 error 体的桩就是一次真实的 400。
    final status = body is Map && body.containsKey('error') ? 400 : 200;
    return http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });

  List<String> get calls => seen.map((r) => '${r.method} ${r.url.path}').toList();
  int countOf(String call) => calls.where((c) => c == call).length;
}

/// 指定状态码的错误响应（服务端的 `{error:{code,message}}` 形状）。
http.Response reject(int status, String code, String message) => http.Response(
  jsonEncode({'error': {'code': code, 'message': message}}),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Map<String, dynamic> txRow(
  String id, {
  String clientId = 'cid-1',
  int amountCents = 3250,
  String status = 'confirmed',
  String? note,
}) => {
  'id': id,
  'clientId': clientId,
  'type': 'expense',
  'amountCents': amountCents,
  'occurredAt': '2026-09-12T12:30:00+08:00',
  'status': status,
  if (note != null) 'note': note,
};

TransactionDraft draft({String clientId = 'cid-1', int amountCents = 3250}) =>
    TransactionDraft(
      clientId: clientId,
      type: 'expense',
      amountCents: amountCents,
      occurredAt: DateTime(2026, 9, 12, 12, 30),
      fundId: 'f1',
    );

({TransactionsRepo repo, Outbox outbox, LocalStore store}) build(
  FakeServer server, {
  Duration? timeout,
  LocalStore? store,
}) {
  final shared = store ?? MemoryLocalStore();
  final outbox = Outbox(shared);
  return (
    repo: TransactionsRepo(
      api: ApiClient(
        baseUrl: 'https://x.dev',
        inner: server.client,
        timeout: timeout,
      ),
      outbox: outbox,
      store: shared,
    ),
    outbox: outbox,
    store: shared,
  );
}

/// 直接给一个「永远不回」的客户端，用来模拟「请求发出去了但没等到回应」。
http.Client hangingClient() {
  final never = Completer<http.StreamedResponse>();
  return MockClient.streaming((req, body) => never.future);
}

void main() {
  group('单实体信封', () {
    test('create 解开 {transaction: {...}}', () async {
      final server = FakeServer({
        'POST /api/v1/transactions': (req) => {'transaction': txRow('t1')},
      });
      final tx = await build(server).repo.create(draft());
      expect(tx.id, 't1');
      expect(tx.amountCents, 3250);
      expect(tx.serverDuplicate, isFalse);
    });

    test('顶层 duplicate:true 变成 serverDuplicate（不写进 JSON）', () async {
      final server = FakeServer({
        'POST /api/v1/transactions': (req) => {
          'transaction': txRow('t1', status: 'duplicate'),
          'duplicate': true,
        },
      });
      final tx = await build(server).repo.create(draft());
      expect(tx.serverDuplicate, isTrue);
      expect(tx.status, 'duplicate');
      expect(tx.toJson().containsKey('serverDuplicate'), isFalse);
    });

    test('create 发出去的是本地墙上时间带偏移，不是 Z', () async {
      final server = FakeServer({
        'POST /api/v1/transactions': (req) => {'transaction': txRow('t1')},
      });
      await build(server).repo.create(draft());
      final body = jsonDecode(server.seen.single.body) as Map<String, dynamic>;
      expect(body['occurredAt'], isNot(endsWith('Z')));
      expect(body['occurredAt'], startsWith('2026-09-12T12:30:00'));
      expect(body['occurredAt'], matches(r'[+-]\d{2}:\d{2}$'));
    });

    test('get / update 也解信封', () async {
      final server = FakeServer({
        'GET /api/v1/transactions/t1': (req) => {'transaction': txRow('t1')},
        'PATCH /api/v1/transactions/t1': (req) => {
          'transaction': txRow('t1', note: '改过了'),
        },
      });
      final repo = build(server).repo;
      expect((await repo.get('t1')).id, 't1');
      final updated = await repo.update('t1', {'note': '改过了'});
      expect(updated.id, 't1');
      expect(updated.note, '改过了');
      expect(updated.amountCents, 3250);
    });
  });

  group('断网', () {
    test('create 入队并返回本地乐观流水', () async {
      final server = FakeServer()..offline = true;
      final ctx = build(server);
      final tx = await ctx.repo.create(draft(clientId: 'cid-9'));

      expect(tx.pendingSync, isTrue);
      expect(tx.id, 'cid-9');
      final pending = await ctx.outbox.pending();
      expect(pending.single.op, 'create');
      expect(pending.single.clientId, 'cid-9');
    });

    test('update 不再抛错：入队 + 返回打过补丁的乐观流水', () async {
      final server = FakeServer()..offline = true;
      final ctx = build(server);
      final current = Transaction.fromJson(txRow('t1', note: '原来的'));

      final tx = await ctx.repo.update('t1', {'note': '改了'}, current: current);

      expect(tx.pendingSync, isTrue);
      expect(tx.id, 't1');
      expect(tx.note, '改了');
      expect(tx.amountCents, 3250);
      final pending = await ctx.outbox.pending();
      expect(pending.single.op, 'patch');
      expect(pending.single.payload['note'], '改了');
    });

    test('没给 current 也能返回一条带 id 的乐观流水', () async {
      final server = FakeServer()..offline = true;
      final tx = await build(server).repo.update('t1', {'note': 'x'});
      expect(tx.id, 't1');
      expect(tx.pendingSync, isTrue);
    });

    test('delete / confirm 入队且不抛', () async {
      final server = FakeServer()..offline = true;
      final ctx = build(server);
      await ctx.repo.delete('t1');
      await ctx.repo.confirm('t2');
      final ops = (await ctx.outbox.pending()).map((e) => '${e.op}:${e.clientId}');
      expect(ops, ['delete:t1', 'confirm:t2']);
    });

    test('非网络错误照常抛出去', () async {
      final server = FakeServer({
        'POST /api/v1/transactions': (req) => {
          'error': {'code': 'bad_request', 'message': '金额必须大于 0'},
        },
      });
      await expectLater(
        build(server).repo.create(draft()),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'bad_request')
              .having((e) => e.isNetwork, 'isNetwork', false),
        ),
      );
    });
  });

  group('attempted 的判定（超时 vs 连不上）', () {
    test('超时 = 可能已送达：入队时标成 attempted', () async {
      final outbox = Outbox(MemoryLocalStore());
      final repo = TransactionsRepo(
        api: ApiClient(
          baseUrl: 'https://x.dev',
          inner: hangingClient(),
          timeout: const Duration(milliseconds: 60),
        ),
        outbox: outbox,
      );

      final tx = await repo.create(draft(clientId: 'c1'));

      expect(tx.pendingSync, isTrue);
      final pending = await outbox.pending();
      expect(pending.single.clientId, 'c1');
      expect(pending.single.attempted, isTrue);
    });

    test('连都没连上 = 肯定没送达：attempted 为假', () async {
      final outbox = Outbox(MemoryLocalStore());
      final repo = TransactionsRepo(
        api: ApiClient(
          baseUrl: 'https://x.dev',
          inner: MockClient((req) async {
            throw const SocketException('Connection refused');
          }),
        ),
        outbox: outbox,
      );

      await repo.create(draft(clientId: 'c1'));

      expect((await outbox.pending()).single.attempted, isFalse);
    });

    test('ApiClient.maybeSent：连接阶段失败 vs 连上之后断', () {
      // 还没送出去
      for (final e in [
        const SocketException('Connection refused'),
        const SocketException('Failed host lookup: ledger.example.com'),
        const SocketException('Network is unreachable'),
        const SocketException('No route to host'),
        const SocketException('Connection timed out'),
        http.ClientException('Connection refused'),
        const HandshakeException('CERTIFICATE_VERIFY_FAILED'),
      ]) {
        expect(ApiClient.maybeSent(e), isFalse, reason: '$e');
      }

      // 已经在跟服务端说话了才断的：可能已经落库
      for (final e in [
        TimeoutException('x'),
        const SocketException('Connection reset by peer'),
        const SocketException('Broken pipe'),
        const SocketException('OS Error: write failed'),
        http.ClientException('Connection closed before full header was received'),
        Exception('说不清的错'),
      ]) {
        expect(ApiClient.maybeSent(e), isTrue, reason: '$e');
      }
    });

    test('超时入队的 create 被删：不丢，转成先重建再删', () async {
      final outbox = Outbox(MemoryLocalStore());
      final repo = TransactionsRepo(
        api: ApiClient(
          baseUrl: 'https://x.dev',
          inner: hangingClient(),
          timeout: const Duration(milliseconds: 60),
        ),
        outbox: outbox,
      );
      await repo.create(draft(clientId: 'c1'));
      await repo.delete('c1');

      final pending = await outbox.pending();
      expect(pending.single.op, 'delete');
      expect(pending.single.payload['create'], isNotNull);
    });
  });

  group('flushOutbox', () {
    test('created / exists 都算成功出队', () async {
      final server = FakeServer({
        'POST /api/v1/transactions/batch': (req) => {
          'results': [
            {'clientId': 'c1', 'id': 't1', 'status': 'created'},
            {'clientId': 'c2', 'id': 't2', 'status': 'exists'},
          ],
        },
      });
      final ctx = build(server);
      await ctx.outbox.enqueue(_item('c1', 'create', draft(clientId: 'c1').toJson()));
      await ctx.outbox.enqueue(_item('c2', 'create', draft(clientId: 'c2').toJson()));

      await ctx.repo.flushOutbox();
      expect(await ctx.outbox.pending(), isEmpty);
      expect(ctx.repo.failedItems, isEmpty);
    });

    test('status=error 出队并记进 failedItems，不会永远重发', () async {
      final server = FakeServer({
        'POST /api/v1/transactions/batch': (req) => {
          'results': [
            {'clientId': 'c1', 'status': 'created', 'id': 't1'},
            {
              'clientId': 'c2',
              'status': 'error',
              'error': 'bad_request',
              'message': '基金不存在',
            },
          ],
        },
      });
      final ctx = build(server);
      await ctx.outbox.enqueue(_item('c1', 'create', draft(clientId: 'c1').toJson()));
      await ctx.outbox.enqueue(_item('c2', 'create', draft(clientId: 'c2').toJson()));

      await ctx.repo.flushOutbox();

      expect(await ctx.outbox.pending(), isEmpty);
      expect(ctx.repo.failedItems.single.clientId, 'c2');
      expect(ctx.repo.failedItems.single.message, '基金不存在');

      // 再 flush 一次不该再打服务端（队列已空）。
      final before = server.countOf('POST /api/v1/transactions/batch');
      await ctx.repo.flushOutbox();
      expect(server.countOf('POST /api/v1/transactions/batch'), before);
    });

    test('还是断网就原样留着，并记下已尝试过', () async {
      final server = FakeServer()..offline = true;
      final ctx = build(server);
      await ctx.outbox.enqueue(_item('c1', 'create', draft(clientId: 'c1').toJson()));

      await ctx.repo.flushOutbox();

      final pending = await ctx.outbox.pending();
      expect(pending.single.clientId, 'c1');
      expect(pending.single.attempted, isTrue);
    });

    test('patch / confirm / delete 逐条补发', () async {
      final server = FakeServer({
        'PATCH /api/v1/transactions/t1': (req) => {'transaction': txRow('t1')},
        'POST /api/v1/transactions/t2/confirm': (req) => {'transaction': txRow('t2')},
        'DELETE /api/v1/transactions/t3': (req) => {'transaction': txRow('t3')},
      });
      final ctx = build(server);
      await ctx.outbox.enqueue(_item('t1', 'patch', {'id': 't1', 'note': 'x'}));
      await ctx.outbox.enqueue(_item('t2', 'confirm', {'id': 't2'}));
      await ctx.outbox.enqueue(_item('t3', 'delete', {'id': 't3'}));

      await ctx.repo.flushOutbox();

      expect(ctx.repo.failedItems, isEmpty);
      expect(await ctx.outbox.pending(), isEmpty);
      expect(server.calls, [
        'PATCH /api/v1/transactions/t1',
        'POST /api/v1/transactions/t2/confirm',
        'DELETE /api/v1/transactions/t3',
      ]);
      // 补发时 PATCH 体里不该带 id。
      expect(jsonDecode(server.seen.first.body), {'note': 'x'});
    });

    test('逐条补发时服务端明确拒绝（400）→ 出队并记账', () async {
      final server = FakeServer({
        'PATCH /api/v1/transactions/t1': (req) => {
          'error': {'code': 'bad_request', 'message': '金额必须大于 0'},
        },
      });
      final ctx = build(server);
      await ctx.outbox.enqueue(_item('t1', 'patch', {'id': 't1', 'amountCents': -1}));
      await ctx.repo.flushOutbox();

      expect(await ctx.outbox.pending(), isEmpty);
      expect(ctx.repo.failedItems.single.clientId, 't1');
      expect(ctx.repo.failedItems.single.code, 'bad_request');
      expect(ctx.repo.failedItems.single.payload['amountCents'], -1);
    });

    test('逐条补发遇到 5xx：留在队列里，后面的也先不发', () async {
      final server = FakeServer({
        'PATCH /api/v1/transactions/t1': (req) => reject(502, 'bad_gateway', '反代在重启'),
        'POST /api/v1/transactions/t2/confirm': (req) => {'transaction': txRow('t2')},
      });
      final ctx = build(server);
      await ctx.outbox.enqueue(_item('t1', 'patch', {'id': 't1', 'note': 'x'}));
      await ctx.outbox.enqueue(_item('t2', 'confirm', {'id': 't2'}));

      await ctx.repo.flushOutbox();

      expect((await ctx.outbox.pending()).map((e) => e.clientId), ['t1', 't2']);
      expect(ctx.repo.failedItems, isEmpty);
      expect(server.calls, ['PATCH /api/v1/transactions/t1']);
    });
  });

  group('404 / 410：目标行已经没了', () {
    test('逐条补发 PATCH 遇到 404：出队并记账，不堵住后面的', () async {
      final server = FakeServer({
        'PATCH /api/v1/transactions/t1': (req) => reject(404, 'not_found', '这条流水已经不在了'),
        'POST /api/v1/transactions/t2/confirm': (req) => {'transaction': txRow('t2')},
      });
      final ctx = build(server);
      await ctx.outbox.enqueue(_item('t1', 'patch', {'id': 't1', 'note': 'x'}));
      await ctx.outbox.enqueue(_item('t2', 'confirm', {'id': 't2'}));

      await ctx.repo.flushOutbox();

      expect(await ctx.outbox.pending(), isEmpty);
      expect(ctx.repo.failedItems.single.clientId, 't1');
      expect(ctx.repo.failedItems.single.code, 'not_found');
      expect(server.calls, [
        'PATCH /api/v1/transactions/t1',
        'POST /api/v1/transactions/t2/confirm',
      ]);
    });

    test('逐条补发 DELETE 遇到 410 同样出队', () async {
      final server = FakeServer({
        'DELETE /api/v1/transactions/t1': (req) => reject(410, 'gone', '已经删过了'),
      });
      final ctx = build(server);
      await ctx.outbox.enqueue(_item('t1', 'delete', {'id': 't1'}));

      await ctx.repo.flushOutbox();

      expect(await ctx.outbox.pending(), isEmpty);
      expect(ctx.repo.failedItems.single.code, 'gone');
    });

    test('整块 batch 遇到 404：留在队列里（那是服务端太老，不是数据的错）', () async {
      final server = FakeServer({
        'POST /api/v1/transactions/batch': (req) => reject(404, 'not_found', 'no such route'),
      });
      final ctx = build(server);
      await ctx.outbox.enqueue(_item('c1', 'create', draft(clientId: 'c1').toJson()));

      await ctx.repo.flushOutbox();

      expect((await ctx.outbox.pending()).single.clientId, 'c1');
      expect(ctx.repo.failedItems, isEmpty);
    });
  });

  group('在途改动不能丢（一边在补发、一边又被改）', () {
    test('patch 在发的时候用户又改了同一条：第二次改动留下来，下次补发', () async {
      final server = FakeServer();
      final ctx = build(server);
      var edited = false;
      server.routes['PATCH /api/v1/transactions/t1'] = (req) async {
        if (!edited) {
          edited = true;
          // 请求已经到了服务端、回应还没回来：用户（断网）又改了这一条。
          server.offline = true;
          final tx = await ctx.repo.update('t1', {'note': '在途中改的'});
          server.offline = false;
          expect(tx.pendingSync, isTrue);
        }
        return {'transaction': txRow('t1', amountCents: 500)};
      };
      await ctx.outbox.enqueue(_item('t1', 'patch', {'id': 't1', 'amountCents': 500}));

      await ctx.repo.flushOutbox();

      // 第一次补发发的是当时的快照……
      expect(server.calls, ['PATCH /api/v1/transactions/t1']);
      expect(jsonDecode(server.seen.single.body), {'amountCents': 500});
      // ……在途中的改动没有被 markDone 一起删掉。
      final rest = await ctx.outbox.pending();
      expect(rest.single.op, 'patch');
      expect(rest.single.payload, {'id': 't1', 'note': '在途中改的'});
      expect(ctx.repo.failedItems, isEmpty);

      // 再补发一次，第二次改动也到了服务端。
      await ctx.repo.flushOutbox();
      expect(server.calls, [
        'PATCH /api/v1/transactions/t1',
        'PATCH /api/v1/transactions/t1',
      ]);
      expect(jsonDecode(server.seen.last.body), {'note': '在途中改的'});
      expect(await ctx.outbox.pending(), isEmpty);
    });

    test('patch 在发的时候用户删了这一条：delete 留下来，下次补发', () async {
      final server = FakeServer();
      final ctx = build(server);
      var deleted = false;
      server.routes['PATCH /api/v1/transactions/t1'] = (req) async {
        if (!deleted) {
          deleted = true;
          server.offline = true;
          await ctx.repo.delete('t1');
          server.offline = false;
        }
        return {'transaction': txRow('t1')};
      };
      server.routes['DELETE /api/v1/transactions/t1'] = (req) => {'transaction': txRow('t1')};
      await ctx.outbox.enqueue(_item('t1', 'patch', {'id': 't1', 'note': 'x'}));

      await ctx.repo.flushOutbox();

      final rest = await ctx.outbox.pending();
      expect(rest.single.op, 'delete');
      expect(rest.single.payload['id'], 't1');

      await ctx.repo.flushOutbox();
      expect(server.calls, [
        'PATCH /api/v1/transactions/t1',
        'DELETE /api/v1/transactions/t1',
      ]);
      expect(await ctx.outbox.pending(), isEmpty);
    });

    test('轮到它发的时候要用队列里此刻的那份，不是 flush 开头的快照', () async {
      final server = FakeServer();
      final ctx = build(server);
      var edited = false;
      server.routes['PATCH /api/v1/transactions/t1'] = (req) async {
        if (!edited) {
          edited = true;
          // t1 在发、t2 还在排队没发过：用户断网改了 t2 → 并进 t2 的 payload。
          server.offline = true;
          await ctx.repo.update('t2', {'note': '排队时改的'});
          server.offline = false;
        }
        return {'transaction': txRow('t1')};
      };
      server.routes['PATCH /api/v1/transactions/t2'] = (req) => {'transaction': txRow('t2')};
      await ctx.outbox.enqueue(_item('t1', 'patch', {'id': 't1', 'amountCents': 100}));
      await ctx.outbox.enqueue(_item('t2', 'patch', {'id': 't2', 'amountCents': 200}));

      await ctx.repo.flushOutbox();

      expect(server.calls, [
        'PATCH /api/v1/transactions/t1',
        'PATCH /api/v1/transactions/t2',
      ]);
      // t2 发出去的是合并后的完整补丁，两次改动都到了服务端。
      expect(jsonDecode(server.seen.last.body), {'amountCents': 200, 'note': '排队时改的'});
      expect(await ctx.outbox.pending(), isEmpty);
      expect(ctx.repo.failedItems, isEmpty);
    });

    test('发过的 patch 补发时把 pendingPatch 一起带上（一个请求）', () async {
      final server = FakeServer({
        'PATCH /api/v1/transactions/t1': (req) => {'transaction': txRow('t1')},
      });
      final ctx = build(server);
      // 之前超时过一次（attempted），断网期间又改了备注 → 进 pendingPatch
      await ctx.outbox.enqueue(_item('t1', 'patch', {'id': 't1', 'amountCents': 500}));
      await ctx.outbox.markAttempted(['t1']);
      await ctx.outbox.enqueue(_item('t1', 'patch', {'id': 't1', 'note': '后来改的'}));

      await ctx.repo.flushOutbox();

      expect(server.calls, ['PATCH /api/v1/transactions/t1']);
      expect(jsonDecode(server.seen.single.body), {'amountCents': 500, 'note': '后来改的'});
      expect(await ctx.outbox.pending(), isEmpty);
    });

    test('先改再确认（断网）：一条 PATCH 把字段和 status 一起送到', () async {
      final server = FakeServer({
        'PATCH /api/v1/transactions/t1': (req) => {'transaction': txRow('t1')},
      });
      final ctx = build(server);
      server.offline = true;
      await ctx.repo.update('t1', {'note': '改过'});
      await ctx.repo.confirm('t1');
      expect(await ctx.repo.pendingCount(), 1);

      server.offline = false;
      await ctx.repo.flushOutbox();

      expect(server.calls, ['PATCH /api/v1/transactions/t1']);
      expect(jsonDecode(server.seen.single.body), {'note': '改过', 'status': 'confirmed'});
      expect(await ctx.outbox.pending(), isEmpty);
    });

    test('pendingLocal 显示的是合并了后续改动的那一版', () async {
      final ctx = build(FakeServer());
      await ctx.outbox.enqueue(_item('c1', 'create', draft(clientId: 'c1', amountCents: 100).toJson()));
      await ctx.outbox.markAttempted(['c1']);
      await ctx.outbox.enqueue(_item('c1', 'patch', {'id': 'c1', 'amountCents': 250, 'note': 'n'}));

      final local = await ctx.repo.pendingLocal();
      expect(local.single.amountCents, 250);
      expect(local.single.note, 'n');
    });
  });

  group('整块被拒 / 分块 / 落盘', () {
    test('超过 100 条分块发，不会一口气撑爆 MAX_BATCH', () async {
      var chunks = <int>[];
      final server = FakeServer({
        'POST /api/v1/transactions/batch': (req) {
          final items = (jsonDecode(req.body) as Map)['items'] as List;
          chunks.add(items.length);
          return {
            'results': [
              for (final item in items)
                {
                  'clientId': (item as Map)['clientId'],
                  'id': 't-${item['clientId']}',
                  'status': 'created',
                },
            ],
          };
        },
      });
      final ctx = build(server);
      for (var i = 0; i < 150; i++) {
        await ctx.outbox.enqueue(
          _item('c$i', 'create', draft(clientId: 'c$i').toJson()),
        );
      }

      await ctx.repo.flushOutbox();

      expect(chunks, [100, 50]);
      expect(await ctx.outbox.pending(), isEmpty);
    });

    test('整块 5xx / 401 / 429：留在队列里，不许悄悄丢用户的账', () async {
      for (final stub in [
        {'status': 502, 'body': '<html>502 Bad Gateway</html>'},
        {
          'status': 401,
          'body': jsonEncode({
            'error': {'code': 'unauthorized', 'message': '登录已过期'},
          }),
        },
        {
          'status': 429,
          'body': jsonEncode({
            'error': {'code': 'rate_limited', 'message': '太频繁'},
          }),
        },
      ]) {
        final outbox = Outbox(MemoryLocalStore());
        final repo = TransactionsRepo(
          api: ApiClient(
            baseUrl: 'https://x.dev',
            inner: MockClient(
              (req) async => http.Response(
                stub['body']! as String,
                stub['status']! as int,
                headers: {'content-type': 'application/json; charset=utf-8'},
              ),
            ),
          ),
          outbox: outbox,
        );
        await outbox.enqueue(_item('c1', 'create', draft(clientId: 'c1').toJson()));

        await repo.flushOutbox();

        expect(
          (await outbox.pending()).single.clientId,
          'c1',
          reason: 'HTTP ${stub['status']} 应该留着重试',
        );
        expect(repo.failedItems, isEmpty);
      }
    });

    test('整块被 4xx 拒掉：逐条记账出队，不把队列堵死', () async {
      final server = FakeServer({
        'POST /api/v1/transactions/batch': (req) => {
          'error': {'code': 'bad_request', 'message': 'items 最多 200 条'},
        },
        'POST /api/v1/transactions/t9/confirm': (req) => {
          'transaction': txRow('t9'),
        },
      });
      final ctx = build(server);
      await ctx.outbox.enqueue(_item('c1', 'create', draft(clientId: 'c1').toJson()));
      await ctx.outbox.enqueue(_item('c2', 'create', draft(clientId: 'c2').toJson()));
      await ctx.outbox.enqueue(_item('t9', 'confirm', {'id': 't9'}));

      await ctx.repo.flushOutbox();

      expect(await ctx.outbox.pending(), isEmpty);
      expect(ctx.repo.failedItems.map((e) => e.clientId), ['c1', 'c2']);
      expect(ctx.repo.failedItems.first.message, 'items 最多 200 条');
      expect(ctx.repo.failedItems.first.payload['clientId'], 'c1');
      // 后面的非 create 操作照样发出去了。
      expect(server.calls, contains('POST /api/v1/transactions/t9/confirm'));
    });

    test('被拒记录落盘，重启后还能读出来、也能清掉', () async {
      final store = MemoryLocalStore();
      final server = FakeServer({
        'POST /api/v1/transactions/batch': (req) => {
          'results': [
            {
              'clientId': 'c1',
              'status': 'error',
              'error': 'bad_request',
              'message': '基金不存在',
            },
          ],
        },
      });
      final ctx = build(server, store: store);
      await ctx.outbox.enqueue(_item('c1', 'create', draft(clientId: 'c1').toJson()));
      await ctx.repo.flushOutbox();
      expect(ctx.repo.failedItems, hasLength(1));

      // 「重启」：换一个实例，从本地读回来。
      final restarted = build(FakeServer(), store: store);
      expect(restarted.repo.failedItems, isEmpty);
      final loaded = await restarted.repo.loadFailed();
      expect(loaded.single.clientId, 'c1');
      expect(loaded.single.message, '基金不存在');
      expect(loaded.single.payload['clientId'], 'c1');

      await restarted.repo.clearFailed();
      expect(restarted.repo.failedItems, isEmpty);
      expect(await build(FakeServer(), store: store).repo.loadFailed(), isEmpty);
    });
  });

  group('发出去过的 create 又被改（补丁不能丢）', () {
    test('create 重放拿到 exists 后，再补打一次 PATCH', () async {
      final server = FakeServer({
        'POST /api/v1/transactions/batch': (req) => {
          'results': [
            {'clientId': 'c1', 'id': 't-server', 'status': 'exists'},
          ],
        },
        'PATCH /api/v1/transactions/t-server': (req) => {
          'transaction': txRow('t-server', note: '改过的'),
        },
      });
      final ctx = build(server);
      await ctx.outbox.enqueue(_item('c1', 'create', draft(clientId: 'c1').toJson()));
      await ctx.outbox.markAttempted(['c1']);
      // 发出去之后用户又改了备注
      await ctx.outbox.enqueue(_item('c1', 'patch', {'id': 'c1', 'note': '改过的'}));

      final queued = await ctx.outbox.pending();
      expect(queued.single.op, 'create');
      expect(queued.single.pendingPatch, {'note': '改过的'});

      await ctx.repo.flushOutbox();

      expect(server.calls, [
        'POST /api/v1/transactions/batch',
        'PATCH /api/v1/transactions/t-server',
      ]);
      expect(jsonDecode(server.seen.last.body), {'note': '改过的'});
      expect(await ctx.outbox.pending(), isEmpty);
    });

    test('还没发出去的 create 被改还是就地合并（不多发一次请求）', () async {
      final server = FakeServer({
        'POST /api/v1/transactions/batch': (req) => {
          'results': [
            {'clientId': 'c1', 'id': 't1', 'status': 'created'},
          ],
        },
      });
      final ctx = build(server);
      await ctx.outbox.enqueue(_item('c1', 'create', draft(clientId: 'c1').toJson()));
      await ctx.outbox.enqueue(_item('c1', 'patch', {'id': 'c1', 'note': '合并进去'}));

      final queued = await ctx.outbox.pending();
      expect(queued.single.op, 'create');
      expect(queued.single.payload['note'], '合并进去');
      expect(queued.single.pendingPatch, isEmpty);

      await ctx.repo.flushOutbox();
      expect(server.calls, ['POST /api/v1/transactions/batch']);
    });
  });

  group('发过一次的 create 又被删（孤儿防护）', () {
    test('先幂等重建拿到服务端 id，再删那一行', () async {
      final server = FakeServer({
        'POST /api/v1/transactions': (req) => {
          'transaction': txRow('t-server', clientId: 'c1'),
        },
        'DELETE /api/v1/transactions/t-server': (req) => {
          'transaction': txRow('t-server', clientId: 'c1'),
        },
      });
      final ctx = build(server);

      // 1) 断网记一笔
      server.offline = true;
      await ctx.repo.create(draft(clientId: 'c1'));
      // 2) 试着补发，请求发出去了但没收到回应
      await ctx.repo.flushOutbox();
      // 3) 用户马上又把它删了（仍然断网）
      await ctx.repo.delete('c1');

      final queued = await ctx.outbox.pending();
      expect(queued.single.op, 'delete');
      expect(queued.single.payload['create'], isNotNull);

      // 4) 网络回来，补发：先幂等重建再删
      server.offline = false;
      await ctx.repo.flushOutbox();

      expect(server.calls, [
        'POST /api/v1/transactions',
        'DELETE /api/v1/transactions/t-server',
      ]);
      expect(await ctx.outbox.pending(), isEmpty);
    });

    test('没发出去过的 create 被删就地丢掉，不打服务端', () async {
      final server = FakeServer()..offline = true;
      final ctx = build(server);
      await ctx.repo.create(draft(clientId: 'c1'));
      await ctx.repo.delete('c1');

      expect(await ctx.outbox.pending(), isEmpty);
      server.offline = false;
      await ctx.repo.flushOutbox();
      expect(server.calls, isEmpty);
    });
  });

  test('pendingLocal 把队列里的 create 还原成可显示的流水', () async {
    final server = FakeServer()..offline = true;
    final ctx = build(server);
    await ctx.repo.create(draft(clientId: 'c1', amountCents: 999));
    final local = await ctx.repo.pendingLocal();
    expect(local.single.amountCents, 999);
    expect(local.single.pendingSync, isTrue);
    expect(await ctx.repo.pendingCount(), 1);
  });
}

OutboxItem _item(String clientId, String op, Map<String, dynamic> payload) =>
    OutboxItem(
      clientId: clientId,
      op: op,
      payload: payload,
      queuedAt: DateTime(2026, 9, 12, 10),
    );
