import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 一个能「拔网线」、能改设置的假服务端。
class FakeServer {
  final List<http.Request> seen = [];
  bool offline = false;
  int modelVersion = 1;
  double threshold = 0.75;
  final Map<String, Map<String, dynamic>> transactions = {};
  int _txSeq = 0;

  /// 强制某个请求（"METHOD /path"）回指定状态码，直到从这里删掉。
  final Map<String, int> statusOverrides = {};

  /// `GET /model` 里类别模型的内容（测试可以改，看「内容没变就不算更新」）。
  Map<String, dynamic> categoryClasses = {
    'c2': {'docs': 1, 'tokens': 2, 'counts': {'滴': 1, '滴滴': 1}},
  };

  /// 学习样本里 categoryId == 'bad' 视为坏样本（服务端会整批 400）。
  int learnRequests = 0;
  final List<int> learnBatchSizes = [];

  /// 第 N 次（从 1 数）及之后的 learn 请求回 503，直到置回 null。
  int? learnFailFrom;

  List<String> get calls => seen.map((r) => '${r.method} ${r.url.path}').toList();
  Map<String, dynamic> bodyOf(String call) {
    final req = seen.lastWhere((r) => '${r.method} ${r.url.path}' == call);
    return jsonDecode(req.body) as Map<String, dynamic>;
  }

  http.Client get client => MockClient((req) async {
    if (offline) throw http.ClientException('Connection refused');
    seen.add(req);
    final path = req.url.path;
    Object? body;
    var status = 200;
    final forced = statusOverrides['${req.method} $path'];
    if (forced != null) {
      return http.Response(
        jsonEncode({'error': {'code': 'forced', 'message': '强制 $forced'}}),
        forced,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    if (path == '/healthz') {
      body = {'ok': true};
    } else if (path == '/api/v1/setup/status') {
      body = {'needsSetup': false, 'householdName': '测试家庭'};
    } else if (path == '/api/v1/auth/login') {
      body = {
        'token': 'tok-e2e',
        'deviceId': 'dev-e2e',
        'member': {'id': 'm1', 'username': 'e2e', 'displayName': '测试', 'role': 'admin'},
      };
    } else if (path == '/api/v1/changes') {
      body = {
        'since': 0,
        'next': 5,
        'more': false,
        'members': [{'id': 'm1', 'username': 'mama', 'displayName': '妈妈', 'role': 'admin'}],
        'accounts': [{'id': 'a1', 'name': '支付宝', 'kind': 'alipay', 'matchHints': {'packages': ['com.eg.android.AlipayGphone']}}],
        'funds': [
          {'id': 'f1', 'name': '家庭公共', 'isDefault': true, 'sortOrder': 0},
          {'id': 'f2', 'name': '宠物', 'sortOrder': 1},
          {'id': 'f3', 'name': '旅行', 'sortOrder': 2},
        ],
        'categories': [
          {'id': 'c1', 'name': '餐饮', 'kind': 'expense', 'sortOrder': 0},
          {'id': 'c2', 'name': '交通', 'kind': 'expense', 'sortOrder': 1},
          {'id': 'c3', 'name': '宠物', 'kind': 'expense', 'sortOrder': 2},
        ],
        'rules': <Object>[],
        'budgets': <Object>[],
        'transactions': <Object>[],
      };
    } else if (path == '/api/v1/settings') {
      body = {
        'name': '测试家庭',
        'currency': 'CNY',
        'capture': {
          'defaultFundId': null,
          'defaultAccountId': null,
          'autoConfirmThreshold': threshold,
          'aiTrigger': 'off',
          'aiAutoConfirm': false,
          'aiProviderId': null,
        },
        'ui': {'firstDayOfMonth': 1},
      };
    } else if (path == '/api/v1/transactions' && req.method == 'POST') {
      final draft = jsonDecode(req.body) as Map<String, dynamic>;
      final id = 't${++_txSeq}';
      transactions[id] = {...draft, 'id': id};
      body = {'transaction': transactions[id]};
      status = 201;
    } else if (path.startsWith('/api/v1/transactions/')) {
      final parts = path.split('/');
      final id = parts[4];
      final tx = transactions[id];
      if (tx == null) {
        status = 404;
        body = {'error': {'code': 'not_found', 'message': '这笔流水不存在'}};
      } else if (req.method == 'PATCH') {
        final patch = jsonDecode(req.body) as Map<String, dynamic>;
        if (patch['fundId'] == 'reject') {
          status = 400;
          body = {'error': {'code': 'invalid_fundId', 'message': 'fundId 指向的基金不存在'}};
        } else {
          tx.addAll(patch);
          body = {'transaction': tx};
        }
      } else if (req.method == 'DELETE') {
        transactions.remove(id);
        body = {'transaction': tx};
      } else if (path.endsWith('/confirm')) {
        tx['status'] = 'confirmed';
        body = {'transaction': tx};
      } else {
        body = {'transaction': tx};
      }
    } else if (path == '/api/v1/model/learn') {
      learnRequests++;
      final samples = (jsonDecode(req.body) as Map<String, dynamic>)['samples'] as List<dynamic>;
      final failFrom = learnFailFrom;
      if (failFrom != null && learnRequests >= failFrom) {
        return http.Response(
          jsonEncode({'error': {'code': 'busy', 'message': '模型服务暂时不可用'}}),
          503,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      learnBatchSizes.add(samples.length);
      final bad = samples.indexWhere((s) => (s as Map)['categoryId'] == 'bad');
      if (bad >= 0) {
        status = 400;
        body = {'error': {'code': 'invalid_categoryId', 'message': 'samples[$bad]: categoryId 指向的类别不存在'}};
      } else {
        modelVersion++;
        body = {'version': modelVersion, 'learned': {'category': samples.length, 'fund': samples.length}};
      }
    } else if (path == '/api/v1/model') {
      body = {
        'version': modelVersion,
        'category': {
          'version': modelVersion,
          'classes': categoryClasses,
          'vocab': 2,
          'totalDocs': categoryClasses.length,
        },
        'fund': {'version': modelVersion, 'classes': <String, Object>{}, 'vocab': 0, 'totalDocs': 0},
      };
    } else {
      status = 404;
      body = {'error': {'code': 'no_stub', 'message': path}};
    }
    return http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});
  });
}

