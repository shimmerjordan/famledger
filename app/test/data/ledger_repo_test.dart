import 'dart:convert';

import 'package:famledger/data/api/api_client.dart';
import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/data/models/models.dart';
import 'package:famledger/data/repos/ledger_repo.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 记下每次请求，并按 method+path 给脚本化响应。
class FakeServer {
  FakeServer(this.handlers);

  final Map<String, List<Object>> handlers;
  final List<http.Request> seen = [];

  http.Client get client => MockClient((req) async {
    seen.add(req);
    final key = '${req.method} ${req.url.path}';
    final queue = handlers[key];
    if (queue == null || queue.isEmpty) {
      return http.Response(jsonEncode({'error': {'code': 'no_stub', 'message': key}}), 500);
    }
    final next = queue.length == 1 ? queue.first : queue.removeAt(0);
    return http.Response(
      jsonEncode(next),
      req.method == 'POST' ? 201 : 200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });

  http.Request requestFor(String method, String path) =>
      seen.firstWhere((r) => r.method == method && r.url.path == path);

  int countOf(String method, String path) =>
      seen.where((r) => r.method == method && r.url.path == path).length;
}

Map<String, dynamic> fundRow(String id, String name, {int sort = 0, String? deletedAt}) => {
  'id': id,
  'name': name,
  'kind': 'shared',
  'sortOrder': sort,
  if (deletedAt != null) 'deletedAt': deletedAt,
};

LedgerRepo repoWith(FakeServer server, LocalStore store) => LedgerRepo(
  api: ApiClient(baseUrl: 'https://x.dev', inner: server.client),
  store: store,
);

void main() {
  group('sync()', () {
    test('首次同步用 since=0，落盘 next 与实体', () async {
      final server = FakeServer({
        'GET /api/v1/changes': [
          {
            'since': 0,
            'next': 12,
            'more': false,
            'funds': [fundRow('f1', '家庭公共')],
            'accounts': [
              {'id': 'a1', 'name': '现金', 'kind': 'cash'},
            ],
          },
        ],
      });
      final store = MemoryLocalStore();
      final repo = repoWith(server, store);
      await repo.sync();

      expect(server.requestFor('GET', '/api/v1/changes').url.queryParameters['since'], '0');
      expect(repo.funds.single.name, '家庭公共');
      expect(repo.seq, 12);

      // 换一个实例读缓存，拿到的应该是同样的东西。
      final reopened = repoWith(server, store);
      await reopened.load();
      expect(reopened.funds.single.id, 'f1');
      expect(reopened.accounts.single.id, 'a1');
      expect(reopened.seq, 12);
    });

    test('more=true 时接着用新的 since 翻页，直到 more=false', () async {
      final server = FakeServer({
        'GET /api/v1/changes': [
          {
            'since': 0,
            'next': 5,
            'more': true,
            'funds': [fundRow('f1', '第一页')],
          },
          {
            'since': 5,
            'next': 9,
            'more': false,
            'funds': [fundRow('f2', '第二页')],
          },
        ],
      });
      final repo = repoWith(server, MemoryLocalStore());
      await repo.sync();

      expect(server.countOf('GET', '/api/v1/changes'), 2);
      expect(server.seen[1].url.queryParameters['since'], '5');
      expect(repo.funds.map((f) => f.id), ['f1', 'f2']);
      expect(repo.seq, 9);
    });

    test('软删的墓碑行把本地那条删掉', () async {
      final server = FakeServer({
        'GET /api/v1/changes': [
          {
            'since': 0,
            'next': 3,
            'more': false,
            'funds': [fundRow('f1', '旧的'), fundRow('f2', '留着', sort: 1)],
          },
          {
            'since': 3,
            'next': 7,
            'more': false,
            'funds': [fundRow('f1', '旧的', deletedAt: '2026-09-12T10:00:00+08:00')],
          },
        ],
      });
      final repo = repoWith(server, MemoryLocalStore());
      await repo.sync();
      expect(repo.funds, hasLength(2));
      await repo.sync();
      expect(repo.funds.map((f) => f.id), ['f2']);
      expect(repo.seq, 7);
    });

    test('full=true 从头重来', () async {
      final server = FakeServer({
        'GET /api/v1/changes': [
          {'since': 0, 'next': 4, 'more': false, 'funds': [fundRow('f1', '甲')]},
          {'since': 0, 'next': 4, 'more': false, 'funds': [fundRow('f9', '乙')]},
        ],
      });
      final repo = repoWith(server, MemoryLocalStore());
      await repo.sync();
      await repo.sync(full: true);
      expect(server.seen.last.url.queryParameters['since'], '0');
      expect(repo.funds.map((f) => f.id), ['f9']);
    });
  });

  group('单实体信封', () {
    test('createFund 解开 {fund: {...}} 而不是把信封当实体', () async {
      final server = FakeServer({
        'POST /api/v1/funds': [
          {
            'fund': fundRow('f-new', '育儿基金'),
          },
        ],
      });
      final repo = repoWith(server, MemoryLocalStore());
      final fund = await repo.createFund({'name': '育儿基金'});

      expect(fund.id, 'f-new');
      expect(fund.name, '育儿基金');
      expect(repo.funds.single.id, 'f-new');
    });

    test('updateFund 解开信封，不会把本地行洗成空对象', () async {
      final server = FakeServer({
        'GET /api/v1/changes': [
          {'since': 0, 'next': 1, 'more': false, 'funds': [fundRow('f1', '旧名字')]},
        ],
        'PATCH /api/v1/funds/f1': [
          {
            'fund': fundRow('f1', '新名字'),
          },
        ],
      });
      final repo = repoWith(server, MemoryLocalStore());
      await repo.sync();
      final fund = await repo.updateFund('f1', {'name': '新名字'});

      expect(fund.id, 'f1');
      expect(repo.funds, hasLength(1));
      expect(repo.funds.single.name, '新名字');
    });

    test('没包信封（老服务端）也认', () async {
      final server = FakeServer({
        'POST /api/v1/accounts': [fundRow('a1', '招商卡')],
      });
      final repo = repoWith(server, MemoryLocalStore());
      final account = await repo.createAccount({'name': '招商卡'});
      expect(account.id, 'a1');
    });
  });

  group('预算', () {
    test('setBudget 用服务端回的行（带真 id）', () async {
      final server = FakeServer({
        'PUT /api/v1/budgets': [
          {
            'budget': {
              'id': 'b-server',
              'scope': 'fund',
              'refId': 'f1',
              'month': '2026-09',
              'amountCents': 300000,
            },
          },
        ],
      });
      final repo = repoWith(server, MemoryLocalStore());
      await repo.setBudget(
        scope: 'fund',
        refId: 'f1',
        month: '2026-09',
        amountCents: 300000,
      );
      expect(repo.budgets.single.id, 'b-server');
      expect(repo.budgets.single.amountCents, 300000);
    });

    test('amountCents=null 就是取消这条', () async {
      final server = FakeServer({
        'PUT /api/v1/budgets': [
          {'budget': null},
        ],
      });
      final repo = repoWith(server, MemoryLocalStore());
      repo.budgets.add(
        const Budget(id: 'b1', scope: 'fund', refId: 'f1', month: '2026-09', amountCents: 1),
      );
      await repo.setBudget(scope: 'fund', refId: 'f1', month: '2026-09');
      expect(repo.budgets, isEmpty);
    });

    test('预算按 (scope, refId, month) 合并，服务端那条不会变成第二条', () async {
      final server = FakeServer({
        'PUT /api/v1/budgets': [
          {
            'budget': {
              'scope': 'fund',
              'refId': 'f1',
              'month': '2026-09',
              'amountCents': 300000,
            },
          },
        ],
        'GET /api/v1/changes': [
          {
            'since': 0,
            'next': 2,
            'more': false,
            'budgets': [
              {
                'id': 'b-server',
                'scope': 'fund',
                'refId': 'f1',
                'month': '2026-09',
                'amountCents': 300000,
              },
            ],
          },
        ],
      });
      final repo = repoWith(server, MemoryLocalStore());
      // 服务端这次没回 id（兜底路径），本地先按三元组存着。
      await repo.setBudget(
        scope: 'fund',
        refId: 'f1',
        month: '2026-09',
        amountCents: 300000,
      );
      expect(repo.budgets, hasLength(1));

      await repo.sync();
      expect(repo.budgets, hasLength(1));
      expect(repo.budgets.single.id, 'b-server');
    });
  });

  test('changes 事件在每次本地数据变化后打一下', () async {
    final server = FakeServer({
      'GET /api/v1/changes': [
        {'since': 0, 'next': 1, 'more': false, 'funds': [fundRow('f1', '甲')]},
      ],
    });
    final repo = repoWith(server, MemoryLocalStore());
    var beats = 0;
    final sub = repo.changes.listen((_) => beats++);
    await repo.sync();
    await Future<void>.delayed(Duration.zero);
    expect(beats, 1);
    await sub.cancel();
    repo.dispose();
  });
}
