import 'dart:convert';

import 'package:famledger/data/api/api_client.dart';
import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/data/repos/ledger_repo.dart';
import 'package:famledger/data/repos/perks_repo.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// 会员权益仓库测试共用：脚本化的假服务端、四张表的行、/changes 回应，以及接好的 LedgerRepo / PerksRepo。

/// 按 method+path 给脚本化响应（先找带 query 的键，如 `DELETE …?cascade=1`，找不到再找不带的；
/// 队列里最后一个一直复用），并记下每个请求。
class ScriptedServer {
  ScriptedServer(this.handlers);

  final Map<String, List<Object>> handlers;
  final List<http.Request> seen = [];

  http.Client get client => MockClient((req) async {
    seen.add(req);
    final key = '${req.method} ${req.url.path}';
    final queue = handlers['$key${req.url.hasQuery ? '?${req.url.query}' : ''}'] ?? handlers[key];
    if (queue == null || queue.isEmpty) {
      return http.Response(jsonEncode({'error': {'code': 'no_stub', 'message': key}}), 500);
    }
    final next = queue.length == 1 ? queue.first : queue.removeAt(0);
    if (next is http.Response) return next;
    return http.Response(
      jsonEncode(next),
      req.method == 'POST' && !req.url.path.endsWith('/merge') ? 201 : 200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });

  List<http.Request> all(String method, String path) => [
    for (final r in seen)
      if (r.method == method && r.url.path == path) r,
  ];

  Map<String, dynamic> bodyOf(String method, String path) =>
      jsonDecode(all(method, path).last.body) as Map<String, dynamic>;
}

const String api = '/api/v1';

/// 服务端的错误体（中文要按 UTF-8 编，不能用 http.Response 默认的 latin1）。
http.Response apiError(int status, String code, String message, [Map<String, dynamic>? details]) => http.Response(
  jsonEncode({
    'error': {'code': code, 'message': message, 'details': ?details},
  }),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Map<String, dynamic> platformRow(String id, {String name = '淘宝', List<String> aliases = const [], String? deletedAt}) => {
  'id': id,
  'name': name,
  'aliases': aliases,
  'kind': 'shopping',
  'sortOrder': 0,
  'archived': false,
  'deletedAt': deletedAt,
};

Map<String, dynamic> membershipRow(String id, {String platformId = 'tb', String name = '88VIP', String? deletedAt}) => {
  'id': id,
  'platformId': platformId,
  'name': name,
  'kind': 'membership',
  'feePeriod': 'year',
  'autoRenew': 'unknown',
  'isTrial': false,
  'origin': <String, dynamic>{},
  'sortOrder': 0,
  'archived': false,
  'deletedAt': deletedAt,
};

Map<String, dynamic> benefitRow(String id, {String membershipId = 'vip', String? parentId, String name = '券', String? deletedAt}) => {
  'id': id,
  'membershipId': membershipId,
  'parentId': parentId,
  'name': name,
  'kind': 'other',
  'flow': 'claim',
  'quota': <Object>[],
  'anchor': 'calendar',
  'limits': <Object>[],
  'remind': true,
  'sortOrder': 0,
  'archived': false,
  'deletedAt': deletedAt,
};

Map<String, dynamic> eventRow(String id, String benefitId) => {
  'id': id,
  'benefitId': benefitId,
  'kind': 'claim',
  'occurredOn': '2026-09-01',
  'count': 1,
};

Map<String, dynamic> changes({
  int next = 1,
  List<Map<String, dynamic>> platforms = const [],
  List<Map<String, dynamic>> memberships = const [],
  List<Map<String, dynamic>> benefits = const [],
  List<Map<String, dynamic>> events = const [],
}) => {
  'since': 0,
  'next': next,
  'more': false,
  'platforms': platforms,
  'memberships': memberships,
  'benefits': benefits,
  'benefit_events': events,
};

class Rig {
  Rig(Map<String, List<Object>> handlers) : server = ScriptedServer(handlers) {
    api = ApiClient(baseUrl: 'https://x.dev', inner: server.client);
    ledger = LedgerRepo(api: api, store: store);
    perks = PerksRepo(api: api, ledger: ledger);
  }

  final ScriptedServer server;
  final MemoryLocalStore store = MemoryLocalStore();
  late final ApiClient api;
  late final LedgerRepo ledger;
  late final PerksRepo perks;
}
