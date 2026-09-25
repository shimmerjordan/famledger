import 'dart:convert';

import 'package:famledger/app/providers.dart';
import 'package:famledger/app/theme.dart';
import 'package:famledger/data/api/api_client.dart';
import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/data/local/secure_store.dart';
import 'package:famledger/data/repos/session_repo.dart';
import 'package:famledger/ui/assets/asset_providers.dart';
import 'package:famledger/ui/assets/asset_routes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'perks_fake.dart';

// 资产页 widget 测试共用：一个记得住状态的假服务端（写完再 /changes 能拿到新样子），
// 加上真的 LedgerRepo / AssetsRepo / HoldingsRepo 和 go_router 路由。

/// 测试里的「现在」：本地 2026-09-23 上午十点。
final DateTime testNow = DateTime(2026, 9, 23, 10);

/// 三种要验「不溢出」的宽度：手机、中等、网页宽屏。
const List<Size> kWidths = [Size(400, 860), Size(800, 1000), Size(1400, 900)];

Map<String, dynamic> assetJson(
  String id, {
  String name = 'iPhone 16',
  String category = 'digital',
  int price = 599900,
  String purchasedOn = '2026-09-01',
  String status = 'in_use',
  String? endedOn,
  int? saleCents,
  int? expectedDays,
  String? note,
  String? transactionId,
  String? saleTransactionId,
  int sort = 0,
  String? valuationMethod,
  int? rateBp,
  int? residualBp,
  int? manualValueCents,
  String? manualValueOn,
  String? netWorth,
}) => {
  'id': id,
  'name': name,
  'category': category,
  'icon': null,
  'priceCents': price,
  'purchasedOn': purchasedOn,
  'status': status,
  'endedOn': endedOn,
  'saleCents': saleCents,
  'expectedDays': expectedDays,
  'note': note,
  'memberId': null,
  'transactionId': transactionId,
  'saleTransactionId': saleTransactionId,
  'sortOrder': sort,
  'archived': false,
  'deletedAt': null,
  // 估值字段：不给就不带这个键 —— 和 005 之前写下的老行一个样子，客户端得按 auto 兜底。
  if (valuationMethod != null) 'valuationMethod': valuationMethod,
  if (rateBp != null) 'rateBp': rateBp,
  if (residualBp != null) 'residualBp': residualBp,
  if (manualValueCents != null) 'manualValueCents': manualValueCents,
  if (manualValueOn != null) 'manualValueOn': manualValueOn,
  if (netWorth != null) 'netWorth': netWorth,
};

/// 物品接口认的估值字段（server/src/modules/assets.js）。
const List<String> kValuationKeys = [
  'valuationMethod',
  'rateBp',
  'residualBp',
  'manualValueCents',
  'manualValueOn',
  'netWorth',
];

Map<String, dynamic> holdingJson(
  String id, {
  String name = '招商中证白酒',
  String? code = '161725',
  String market = 'fund',
  int qty = 10000000,
  int cost = 100000,
  int? price = 12000,
  int? prev = 11000,
  String source = 'auto',
  DateTime? priceAt,
  String openedOn = '2026-09-14',
  String? accountId = 'inv',
  int realized = 0,
  int sort = 0,
}) => {
  'id': id,
  'name': name,
  'code': code,
  'market': market,
  'quantityE4': qty,
  'costCents': cost,
  'priceE4': price,
  'prevCloseE4': prev,
  'priceSource': source,
  'priceAt': price == null
      ? null
      : (priceAt ?? testNow.subtract(const Duration(hours: 1)))
            .toUtc()
            .toIso8601String(),
  'openedOn': openedOn,
  'accountId': accountId,
  'realizedCents': realized,
  'note': null,
  'sortOrder': sort,
  'archived': false,
  'deletedAt': null,
};

const List<Map<String, dynamic>> defaultAccounts = [
  {'id': 'bank', 'name': '工行卡', 'kind': 'bank', 'sortOrder': 0},
  {'id': 'inv', 'name': '证券户', 'kind': 'invest', 'sortOrder': 1},
  {'id': 'wx', 'name': '微信', 'kind': 'wechat', 'sortOrder': 2},
];

/// 记得住状态的假服务端：只实现资产页会碰到的接口，行为照 server/src/modules/*.js。
class AssetsBackend {
  AssetsBackend({
    List<Map<String, dynamic>> assets = const [],
    List<Map<String, dynamic>> holdings = const [],
    List<Map<String, dynamic>> accounts = defaultAccounts,
    this.members = const [],
    PerksFake? perks,
  }) : accounts = [for (final a in accounts) {...a}],
       perks = perks ?? PerksFake() {
    for (final a in assets) {
      this.assets[a['id'] as String] = {...a};
    }
    for (final h in holdings) {
      this.holdings[h['id'] as String] = {...h};
    }
  }

  final Map<String, Map<String, dynamic>> assets = {};
  final Map<String, Map<String, dynamic>> holdings = {};
  final List<Map<String, dynamic>> accounts;

  /// `/changes` 里的家庭成员（会员卡的持有人 chip 用）。
  final List<Map<String, dynamic>> members;

  /// 会员权益那几张表和接口（test/ui/perks_fake.dart）。
  final PerksFake perks;
  final List<Map<String, dynamic>> _tombstones = [];
  final List<http.Request> seen = [];

  /// 下一次打到这个 `METHOD /path`（不带 /api/v1）就回这个错误。
  final Map<String, (int, String, String)> failNext = {};

  /// 打到这个 `METHOD /path` 一直回这个错误，拿掉之前每次都是（重试也是）。
  final Map<String, (int, String, String)> failAlways = {};

  /// 打到这个 `METHOD /path` 一直连不上（网络错误），拿掉之前每次都是。
  final Set<String> offline = {};

  /// 下一次打到这个 `METHOD /path` 先等这么久再回（看「请求还在路上」那几帧）。
  final Map<String, Duration> delayNext = {};

  /// 为真时 `/changes` 的 next 不往前走 —— 像真服务端那样「没有新数据」。
  bool frozenSeq = false;

  /// 下一次打到这个 `METHOD /path` 时照常处理、落库，但回应丢在路上（连接被重置）——
  /// App 那边拿到的是「可能已经送到」的网络错误。
  final Set<String> dropResponseNext = {};

  /// 照 server/src/lib/idempotency.js：同一个接口、同一个 clientId 再来，回第一次的结果并标 replayed。
  final Map<String, Map<String, dynamic>> _replies = {};

  /// `GET /stats/overview` 按下面几样现拼（照 server/src/modules/stats.js 的口径）。
  Map<String, int> accountBalances = {'bank': 1000000};
  int investNetCents = 0;

  /// 持仓总市值；null = 不回这个键。比 [investNetCents] 大出来的就是挂了账户的持仓成本。
  int? investMarketCents;

  /// `{valueCents, includedCents, count}`；null = 老服务端，不回 physical / netWorthExPhysicalCents。
  Map<String, dynamic>? physical;

  /// `GET /settings` 回它，`PATCH /settings` 一层深合并进来。
  final Map<String, dynamic> settings = {
    'name': '小明家',
    'currency': 'CNY',
    'capture': <String, dynamic>{},
    'ui': <String, dynamic>{'firstDayOfMonth': 1},
    'assets': <String, dynamic>{'netWorthIncludesPhysical': true},
  };

  /// `POST /holdings/refresh` 回什么。
  Map<String, dynamic> refreshResult = {
    'updated': 0,
    'failed': <Object>[],
    'refreshedAt': testNow.toUtc().toIso8601String(),
    'throttled': false,
  };

  int _seq = 0;
  int _ids = 0;

  List<http.Request> requests(String method, String path) => [
    for (final r in seen)
      if (r.method == method && r.url.path == '/api/v1$path') r,
  ];

  Map<String, dynamic> lastBody(String method, String path) =>
      jsonDecode(requests(method, path).last.body) as Map<String, dynamic>;

  http.Client get client => MockClient((req) async {
    seen.add(req);
    final path = req.url.path.replaceFirst('/api/v1', '');
    final key = '${req.method} $path';
    final delay = delayNext.remove(key);
    if (delay != null) await Future<void>.delayed(delay);
    if (offline.contains(key)) {
      throw http.ClientException('Network is unreachable', req.url);
    }
    final fail = failNext.remove(key) ?? failAlways[key];
    if (fail != null) return _error(fail.$1, fail.$2, fail.$3);
    final body = req.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(req.body) as Map<String, dynamic>;
    final seg = path.split('/').where((s) => s.isNotEmpty).toList();

    final clientId = body['clientId'];
    final replyKey = clientId is String ? '${req.method} $path|$clientId' : null;
    final first = replyKey == null ? null : _replies[replyKey];
    if (first != null) return _ok({...first, 'replayed': true});

    final http.Response res;
    if (req.method == 'GET' && path == '/changes') {
      res = _ok(_changes());
    } else if (req.method == 'GET' && path == '/stats/overview') {
      res = _ok(overview());
    } else if (path == '/settings') {
      res = _settings(req.method, body);
    } else if (seg.isNotEmpty && seg.first == 'assets') {
      res = _assets(req.method, seg, body);
    } else if (seg.isNotEmpty && seg.first == 'holdings') {
      res = _holdings(req.method, seg, body);
    } else if (seg.isNotEmpty && PerksFake.resources.contains(seg.first)) {
      res = perks.handle(req.method, seg, body, req.url.queryParameters);
    } else {
      res = _error(404, 'not_found', '没有这个接口 $path');
    }
    if (replyKey != null && res.statusCode < 300) {
      _replies[replyKey] = jsonDecode(res.body) as Map<String, dynamic>;
    }
    if (dropResponseNext.remove('${req.method} $path')) {
      throw http.ClientException('Connection reset by peer', req.url);
    }
    return res;
  });

  Map<String, dynamic> _changes() => {
    'since': 0,
    'next': frozenSeq ? _seq : ++_seq,
    'more': false,
    'members': members,
    'accounts': accounts,
    'funds': [
      {'id': 'f1', 'name': '家庭公共', 'kind': 'shared', 'isDefault': true, 'sortOrder': 0},
      {'id': 'f2', 'name': '个人零花', 'kind': 'personal', 'sortOrder': 1},
    ],
    'categories': [
      {'id': 'c1', 'name': '数码', 'kind': 'expense', 'sortOrder': 0},
      {'id': 'c2', 'name': '二手', 'kind': 'income', 'sortOrder': 1},
    ],
    'assets': [...assets.values, ..._tombstones.where((t) => t['kind'] == 'asset')],
    'holdings': [
      ...holdings.values,
      ..._tombstones.where((t) => t['kind'] == 'holding'),
    ],
    ...perks.changes(),
  };

  Map<String, dynamic> overview() {
    final accountsNet = accountBalances.values.fold<int>(0, (sum, v) => sum + v);
    final exPhysical = accountsNet + investNetCents;
    final counted = (settings['assets'] as Map)['netWorthIncludesPhysical'] == true;
    final p = physical;
    final included = p == null || !counted ? 0 : p['includedCents'] as int;
    return {
      'netWorthCents': exPhysical + included,
      'assetsCents': exPhysical + included,
      'liabilitiesCents': 0,
      'month': {
        'expenseCents': 0,
        'incomeCents': 0,
        'byFund': <Object>[],
        'byCategory': <Object>[],
        'byMember': <Object>[],
        'budgets': <Object>[],
      },
      'pendingCount': 0,
      'funds': <Object>[],
      'accounts': [
        for (final e in accountBalances.entries)
          {'accountId': e.key, 'balanceCents': e.value},
      ],
      if (investMarketCents != null) 'investMarketCents': investMarketCents,
      if (p != null) 'netWorthExPhysicalCents': exPhysical,
      if (p != null) 'physical': {...p, 'counted': counted},
    };
  }

  http.Response _settings(String method, Map<String, dynamic> body) {
    if (method == 'PATCH') {
      body.forEach((key, value) {
        final current = settings[key];
        if (value is Map && current is Map) {
          current.addAll(value);
        } else {
          settings[key] = value;
        }
      });
    }
    return _ok(settings);
  }

  String _id(String prefix) => '$prefix-new${++_ids}';

  http.Response _assets(String method, List<String> seg, Map<String, dynamic> body) {
    if (method == 'POST' && seg.length == 1) {
      final price = body['priceCents'] as int;
      final record = body['recordTransaction'] != null && price > 0;
      final row = assetJson(
        _id('a'),
        name: body['name'] as String,
        category: body['category'] as String? ?? 'other',
        price: price,
        purchasedOn: body['purchasedOn'] as String,
        expectedDays: body['expectedDays'] as int?,
        note: body['note'] as String?,
        transactionId: record ? 'tx-buy' : null,
        sort: assets.length,
      );
      for (final key in kValuationKeys) {
        if (body.containsKey(key)) row[key] = body[key];
      }
      assets[row['id'] as String] = row;
      return _ok({'asset': row}, 201);
    }
    final row = assets[seg[1]];
    if (row == null) return _error(404, 'not_found', '物品不存在');
    if (method == 'PATCH') {
      row.addAll(body);
      if (row['status'] == 'in_use' || row['status'] == 'idle') {
        row['endedOn'] = null;
        row['saleCents'] = null;
      }
      return _ok({'asset': row});
    }
    if (method == 'POST' && seg.length == 3 && seg[2] == 'sell') {
      if (row['status'] == 'sold') return _error(409, 'already_sold', '这件已经卖出了');
      final sale = body['saleCents'] as int;
      row
        ..['status'] = 'sold'
        ..['endedOn'] = body['endedOn']
        ..['saleCents'] = sale
        ..['saleTransactionId'] =
            body['recordTransaction'] != null && sale > 0 ? 'tx-sale' : null;
      return _ok({'asset': row});
    }
    if (method == 'DELETE') {
      assets.remove(seg[1]);
      final gone = {...row, 'deletedAt': testNow.toUtc().toIso8601String(), 'kind': 'asset'};
      _tombstones.add(gone);
      return _ok({'asset': gone});
    }
    return _error(404, 'not_found', '没有这个接口');
  }

  http.Response _holdings(String method, List<String> seg, Map<String, dynamic> body) {
    if (method == 'POST' && seg.length == 2 && seg[1] == 'refresh') {
      return _ok(refreshResult);
    }
    if (method == 'POST' && seg.length == 1) {
      final row = holdingJson(
        _id('h'),
        name: body['name'] as String? ?? '',
        code: body['code'] as String?,
        market: body['market'] as String? ?? 'other',
        qty: body['quantityE4'] as int,
        cost: body['costCents'] as int,
        price: body['priceE4'] as int?,
        prev: null,
        source: body['priceSource'] as String? ?? 'manual',
        openedOn: body['openedOn'] as String,
        accountId: body['accountId'] as String?,
        sort: holdings.length,
      );
      holdings[row['id'] as String] = row;
      return _ok({'holding': row}, 201);
    }
    final row = holdings[seg[1]];
    if (row == null) return _error(404, 'not_found', '持仓不存在');
    if (method == 'PATCH') {
      row.addAll(body);
      if (body.containsKey('priceE4')) {
        row['prevCloseE4'] = null;
        row['priceAt'] = testNow.toUtc().toIso8601String();
      }
      return _ok({'holding': row});
    }
    if (method == 'POST' && seg.length == 3 && seg[2] == 'trade') {
      final q = body['quantityE4'] as int;
      final amount = body['amountCents'] as int;
      var qty = row['quantityE4'] as int;
      var cost = row['costCents'] as int;
      var realized = 0;
      if (body['side'] == 'buy') {
        qty += q;
        cost += amount;
      } else {
        if (q > qty) {
          return _error(400, 'insufficient_quantity', '卖出份额超过了持有份额');
        }
        final prop = q == qty ? cost : (cost * q * 2 + qty) ~/ (2 * qty);
        realized = amount - prop;
        qty -= q;
        cost -= prop;
      }
      row
        ..['quantityE4'] = qty
        ..['costCents'] = cost
        ..['realizedCents'] = (row['realizedCents'] as int) + realized;
      final txs = body['recordTransaction'] == null
          ? <Object>[]
          : [
              {
                'id': 'tx-trade',
                'clientId': 'tx-trade',
                'type': 'transfer',
                'amountCents': amount,
                'occurredAt': '${body['occurredOn']}T12:00:00+08:00',
              },
            ];
      return _ok({'holding': row, 'transactions': txs});
    }
    if (method == 'DELETE') {
      holdings.remove(seg[1]);
      final gone = {...row, 'deletedAt': testNow.toUtc().toIso8601String(), 'kind': 'holding'};
      _tombstones.add(gone);
      return _ok({'holding': gone});
    }
    return _error(404, 'not_found', '没有这个接口');
  }

  static http.Response _ok(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  static http.Response _error(int status, String code, String message) =>
      http.Response(
        jsonEncode({
          'error': {'code': code, 'message': message},
        }),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
}

/// 已登录的会话：[role] 是 admin 还是 member（净资产开关只有管理员能动）。
Future<SessionRepo> sessionAs(String role) async {
  final secure = MemorySecureStore();
  secure.data[SessionRepo.sessionKey] = jsonEncode({
    'baseUrl': 'https://x.dev',
    'token': 'tok',
    'deviceId': 'dev',
    'me': {'id': 'm1', 'username': 'mama', 'displayName': '妈妈', 'role': role},
  });
  final repo = SessionRepo(secure: secure);
  await repo.restore();
  return repo;
}

/// [session] 不给 = 没登录（不是管理员）。[overrides] 追加在后面（比如换掉打开链接的函数）。
ProviderContainer bootAssets(
  AssetsBackend backend, {
  LocalStore? store,
  SessionRepo? session,
  List<Override> overrides = const [],
}) => ProviderContainer(
      overrides: [
        localStoreProvider.overrideWithValue(store ?? MemoryLocalStore()),
        secureStoreProvider.overrideWithValue(MemorySecureStore()),
        sessionRepoProvider.overrideWithValue(
          session ?? SessionRepo(secure: MemorySecureStore()),
        ),
        apiProvider.overrideWithValue(
          ApiClient(baseUrl: 'https://x.dev', token: 'tok', inner: backend.client),
        ),
        assetClockProvider.overrideWithValue(() => testNow),
        ...overrides,
      ],
    );

/// 从 [location] 打开资产路由（带父页，所以表单保存后能 pop 回列表）。
Future<void> pumpAssetsAt(
  WidgetTester tester,
  ProviderContainer container,
  String location, {
  Size size = const Size(400, 1600),
}) async {
  addTearDown(container.dispose);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    initialLocation: location,
    routes: [
      assetsRoute(),
      GoRoute(
        path: '/transactions/:id',
        builder: (context, state) =>
            Scaffold(body: Text('流水 ${state.pathParameters['id']}')),
      ),
      GoRoute(
        path: '/settings/accounts',
        builder: (context, state) => const Scaffold(body: Text('账户管理页')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light),
        routerConfig: router,
      ),
    ),
  );
  await settle(tester);
}

/// 推几帧等请求落地、弹层滑上来。骨架屏和按钮里的圈圈是永动动画，不能 pumpAndSettle。
Future<void> settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// 滚到能看见再点。
Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await settle(tester);
}
