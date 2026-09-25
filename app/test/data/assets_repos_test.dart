import 'dart:convert';

import 'package:famledger/data/api/api_client.dart';
import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/data/models/models.dart';
import 'package:famledger/data/repos/assets_repo.dart';
import 'package:famledger/data/repos/holdings_repo.dart';
import 'package:famledger/data/repos/ledger_repo.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 按 method+path 给脚本化响应（队列里最后一个一直复用），并记下每个请求。
class ScriptedServer {
  ScriptedServer(this.handlers);

  final Map<String, List<Object>> handlers;
  final List<http.Request> seen = [];

  http.Client get client => MockClient((req) async {
    seen.add(req);
    final key = '${req.method} ${req.url.path}';
    final queue = handlers[key];
    if (queue == null || queue.isEmpty) {
      return http.Response(
        jsonEncode({
          'error': {'code': 'no_stub', 'message': key},
        }),
        500,
      );
    }
    final next = queue.length == 1 ? queue.first : queue.removeAt(0);
    if (next is http.Response) return next;
    return http.Response(
      jsonEncode(next),
      req.method == 'POST' && !req.url.path.contains('/sell') ? 201 : 200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });

  List<http.Request> all(String method, String path) => [
    for (final r in seen)
      if (r.method == method && r.url.path == path) r,
  ];

  Map<String, dynamic> bodyOf(String method, String path) =>
      jsonDecode(all(method, path).last.body) as Map<String, dynamic>;

  int countOf(String method, String path) => all(method, path).length;
}

const String api = '/api/v1';

Map<String, dynamic> assetRow(
  String id, {
  String name = 'iPhone',
  int price = 599900,
  String status = 'in_use',
  String? endedOn,
  int? saleCents,
  int sort = 0,
  String? deletedAt,
  String? transactionId,
}) => {
  'id': id,
  'name': name,
  'category': 'digital',
  'priceCents': price,
  'purchasedOn': '2026-09-01',
  'status': status,
  'endedOn': endedOn,
  'saleCents': saleCents,
  'expectedDays': null,
  'note': null,
  'memberId': null,
  'transactionId': transactionId,
  'saleTransactionId': null,
  'sortOrder': sort,
  'archived': false,
  'createdAt': '2026-09-01T04:00:00.000Z',
  'updatedAt': '2026-09-01T04:00:00.000Z',
  'deletedAt': deletedAt,
  'seq': 1,
};

Map<String, dynamic> holdingRow(
  String id, {
  String name = '招商白酒',
  int qty = 10000000,
  int cost = 100000,
  int? price = 12000,
  int? prev = 11000,
  String source = 'auto',
  String? priceAt = '2026-09-23T02:00:00.000Z',
  int sort = 0,
  String? deletedAt,
}) => {
  'id': id,
  'name': name,
  'code': '161725',
  'market': 'fund',
  'quantityE4': qty,
  'costCents': cost,
  'priceE4': price,
  'prevCloseE4': prev,
  'priceSource': source,
  'priceAt': priceAt,
  'openedOn': '2026-09-14',
  'accountId': 'inv',
  'realizedCents': 0,
  'note': null,
  'sortOrder': sort,
  'archived': false,
  'deletedAt': deletedAt,
  'seq': 2,
};

Map<String, dynamic> changes({
  int next = 1,
  List<Map<String, dynamic>> assets = const [],
  List<Map<String, dynamic>> holdings = const [],
}) => {
  'since': 0,
  'next': next,
  'more': false,
  'assets': assets,
  'holdings': holdings,
};

class Rig {
  Rig(Map<String, List<Object>> handlers) : server = ScriptedServer(handlers) {
    final client = ApiClient(baseUrl: 'https://x.dev', inner: server.client);
    ledger = LedgerRepo(api: client, store: store);
    assets = AssetsRepo(api: client, ledger: ledger);
    holdings = HoldingsRepo(api: client, ledger: ledger, store: store);
  }

  final ScriptedServer server;
  final MemoryLocalStore store = MemoryLocalStore();
  late final LedgerRepo ledger;
  late final AssetsRepo assets;
  late final HoldingsRepo holdings;
}

void main() {
  group('LedgerRepo 同步物品与持仓', () {
    test('/changes 里的 assets / holdings 合并进来并落本地缓存', () async {
      final rig = Rig({
        'GET $api/changes': [
          changes(
            next: 5,
            assets: [assetRow('a2', name: '洗衣机', sort: 1), assetRow('a1')],
            holdings: [holdingRow('h1')],
          ),
        ],
      });
      await rig.ledger.sync();

      expect(rig.ledger.assets.map((a) => a.id), ['a1', 'a2']);
      expect(rig.ledger.holdings.single.quantityE4, 10000000);
      expect(rig.ledger.snapshot.asset('a2')!.name, '洗衣机');
      expect(rig.ledger.snapshot.holding('h1')!.isAuto, isTrue);

      final reopened = LedgerRepo(
        api: ApiClient(baseUrl: 'https://x.dev', inner: rig.server.client),
        store: rig.store,
      );
      await reopened.load();
      expect(reopened.assets.map((a) => a.id), ['a1', 'a2']);
      final h = reopened.holdings.single;
      expect(h.priceE4, 12000);
      expect(h.prevCloseE4, 11000);
      expect(h.priceAt!.isAtSameMomentAs(DateTime.utc(2026, 9, 23, 2)), isTrue);
      expect(reopened.seq, 5);
    });

    test('墓碑行把本地的物品/持仓删掉，改过的行按 id 覆盖', () async {
      final rig = Rig({
        'GET $api/changes': [
          changes(
            next: 3,
            assets: [assetRow('a1'), assetRow('a2', sort: 1)],
            holdings: [holdingRow('h1'), holdingRow('h2', sort: 1)],
          ),
          changes(
            next: 8,
            assets: [
              assetRow('a1', deletedAt: '2026-09-23T03:00:00.000Z'),
              assetRow('a2', status: 'sold', endedOn: '2026-09-20', saleCents: 1),
            ],
            holdings: [
              holdingRow('h2', deletedAt: '2026-09-23T03:00:00.000Z'),
              holdingRow('h1', qty: 0, cost: 0),
            ],
          ),
        ],
      });
      await rig.ledger.sync();
      expect(rig.ledger.assets, hasLength(2));
      expect(rig.ledger.holdings, hasLength(2));

      await rig.ledger.sync();
      expect(rig.ledger.assets.single.id, 'a2');
      expect(rig.ledger.assets.single.status, Asset.statusSold);
      expect(rig.ledger.holdings.single.id, 'h1');
      expect(rig.ledger.holdings.single.isCleared, isTrue);
      expect(rig.server.all('GET', '$api/changes').last.url.queryParameters['since'], '3');
    });

    test('老版本留下的缓存没有 assets / holdings：游标归零，从头拉一遍', () async {
      final rig = Rig({
        'GET $api/changes': [
          {
            ...changes(next: 60, assets: [assetRow('a1')], holdings: [holdingRow('h1')]),
            'funds': [
              {'id': 'f1', 'name': '家庭公共', 'kind': 'shared', 'sortOrder': 0},
            ],
          },
        ],
      });
      await rig.store.write(LedgerRepo.cacheKey, {
        'members': <Object>[],
        'accounts': <Object>[],
        'funds': [
          {'id': 'f1', 'name': '家庭公共', 'kind': 'shared', 'sortOrder': 0},
        ],
        'categories': <Object>[],
        'rules': <Object>[],
        'budgets': <Object>[],
        'seq': 42,
      });

      await rig.ledger.load();
      expect(rig.ledger.funds.single.id, 'f1');
      await rig.ledger.sync();

      expect(
        rig.server.all('GET', '$api/changes').first.url.queryParameters['since'],
        '0',
      );
      expect(rig.ledger.assets.single.id, 'a1');
      expect(rig.ledger.holdings.single.id, 'h1');
      expect(rig.ledger.funds.single.id, 'f1');
      expect(rig.ledger.seq, 60);
    });

    test('新缓存照常从上次的游标接着拉', () async {
      final rig = Rig({
        'GET $api/changes': [changes(next: 43)],
      });
      await rig.store.write(LedgerRepo.cacheKey, {
        'assets': [assetRow('a1')],
        'holdings': <Object>[],
        'seq': 42,
      });

      await rig.ledger.load();
      await rig.ledger.sync();

      expect(
        rig.server.all('GET', '$api/changes').single.url.queryParameters['since'],
        '42',
      );
      expect(rig.ledger.assets.single.id, 'a1');
    });

    test('full=true 连物品和持仓一起清掉重来', () async {
      final rig = Rig({
        'GET $api/changes': [
          changes(next: 2, assets: [assetRow('old')], holdings: [holdingRow('old')]),
          changes(next: 2, assets: [assetRow('new')]),
        ],
      });
      await rig.ledger.sync();
      await rig.ledger.sync(full: true);
      expect(rig.ledger.assets.single.id, 'new');
      expect(rig.ledger.holdings, isEmpty);
    });
  });

  group('AssetsRepo 请求体', () {
    test('新建带「同时记一笔支出」：recordTransaction 只带选了的字段，回来的行先落本地再同步', () async {
      final rig = Rig({
        'POST $api/assets': [
          {'asset': assetRow('a1', transactionId: 't1')},
        ],
        'GET $api/changes': [changes(next: 4)],
      });
      final asset = await rig.assets.create(
        name: 'iPhone',
        category: 'digital',
        priceCents: 599900,
        purchasedOn: '2026-09-01',
        expectedDays: 1095,
        note: '',
        record: const AssetRecord(accountId: 'acc', fundId: 'f1'),
      );

      expect(rig.server.bodyOf('POST', '$api/assets'), {
        'name': 'iPhone',
        'category': 'digital',
        'priceCents': 599900,
        'purchasedOn': '2026-09-01',
        'expectedDays': 1095,
        'recordTransaction': {'accountId': 'acc', 'fundId': 'f1'},
      });
      expect(asset.transactionId, 't1');
      expect(rig.ledger.assets.single.id, 'a1');
      expect(rig.server.countOf('GET', '$api/changes'), 1);
    });

    test('不记账就不带 recordTransaction；同步失败不算写失败', () async {
      final rig = Rig({
        'POST $api/assets': [
          {'asset': assetRow('a1')},
        ],
        'GET $api/changes': [
          http.Response.bytes(
            utf8.encode('{"error":{"code":"boom","message":"挂了"}}'),
            500,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ],
      });
      await rig.assets.create(
        name: '沙发',
        category: 'furniture',
        priceCents: 0,
        purchasedOn: '2026-09-01',
        note: '二手',
      );
      final body = rig.server.bodyOf('POST', '$api/assets');
      expect(body.containsKey('recordTransaction'), isFalse);
      expect(body.containsKey('expectedDays'), isFalse);
      expect(body['note'], '二手');
      expect(rig.ledger.assets.single.id, 'a1');
    });

    test('编辑：清掉预期天数和备注要显式传 null', () async {
      final rig = Rig({
        'PATCH $api/assets/a1': [
          {'asset': assetRow('a1', name: '新名字')},
        ],
        'GET $api/changes': [changes()],
      });
      await rig.assets.edit(
        'a1',
        name: '新名字',
        category: 'digital',
        priceCents: 100,
        purchasedOn: '2026-09-02',
        note: '',
      );
      expect(rig.server.bodyOf('PATCH', '$api/assets/a1'), {
        'name': '新名字',
        'category': 'digital',
        'priceCents': 100,
        'purchasedOn': '2026-09-02',
        'expectedDays': null,
        'note': null,
      });
    });

    test('估值：新建只带改过的键；编辑带上全部六个（null 就是清掉）；不给 valuation 的编辑照旧', () async {
      final rig = Rig({
        'POST $api/assets': [
          {'asset': assetRow('a1')},
        ],
        'PATCH $api/assets/a1': [
          {'asset': assetRow('a1')},
        ],
        'GET $api/changes': [changes()],
      });
      await rig.assets.create(
        name: '镯子',
        category: 'jewelry',
        priceCents: 1000000,
        purchasedOn: '2020-05-01',
        valuation: const ValuationInput(
          method: Asset.methodLocked,
          manualValueCents: 1200000,
          manualValueOn: '2025-08-01',
        ),
      );
      expect(rig.server.bodyOf('POST', '$api/assets'), {
        'name': '镯子',
        'category': 'jewelry',
        'priceCents': 1000000,
        'purchasedOn': '2020-05-01',
        'valuationMethod': 'locked',
        'manualValueCents': 1200000,
        'manualValueOn': '2025-08-01',
      });

      await rig.assets.edit(
        'a1',
        name: '镯子',
        category: 'jewelry',
        priceCents: 1000000,
        purchasedOn: '2020-05-01',
        valuation: const ValuationInput(netWorth: Asset.netWorthExclude),
      );
      expect(rig.server.bodyOf('PATCH', '$api/assets/a1'), {
        'name': '镯子',
        'category': 'jewelry',
        'priceCents': 1000000,
        'purchasedOn': '2020-05-01',
        'expectedDays': null,
        'note': null,
        'valuationMethod': 'auto',
        'rateBp': null,
        'residualBp': null,
        'manualValueCents': null,
        'manualValueOn': null,
        'netWorth': 'exclude',
      });
    });

    test('闲置 / 退役 / 卖出各自的请求体', () async {
      final rig = Rig({
        'PATCH $api/assets/a1': [
          {'asset': assetRow('a1', status: 'idle')},
          {'asset': assetRow('a1', status: 'retired', endedOn: '2026-09-20')},
        ],
        'POST $api/assets/a1/sell': [
          {'asset': assetRow('a1', status: 'sold', endedOn: '2026-09-21', saleCents: 80000)},
        ],
        'GET $api/changes': [changes()],
      });

      await rig.assets.setStatus('a1', Asset.statusIdle);
      expect(rig.server.bodyOf('PATCH', '$api/assets/a1'), {'status': 'idle'});

      await rig.assets.retire('a1', endedOn: '2026-09-20');
      expect(rig.server.bodyOf('PATCH', '$api/assets/a1'), {
        'status': 'retired',
        'endedOn': '2026-09-20',
      });

      final sold = await rig.assets.sell(
        'a1',
        saleCents: 80000,
        endedOn: '2026-09-21',
        record: const AssetRecord(accountId: 'acc', categoryId: 'c9'),
      );
      expect(rig.server.bodyOf('POST', '$api/assets/a1/sell'), {
        'saleCents': 80000,
        'endedOn': '2026-09-21',
        'recordTransaction': {'accountId': 'acc', 'categoryId': 'c9'},
      });
      expect(sold.status, Asset.statusSold);
      expect(rig.ledger.assets.single.saleCents, 80000);
    });

    test('服务端 409（卖出记过收入）原样抛出，本地不动', () async {
      final rig = Rig({
        'GET $api/changes': [changes(assets: [assetRow('a1', status: 'sold')])],
        'PATCH $api/assets/a1': [
          http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'error': {'code': 'sale_recorded', 'message': '卖出时记过一笔收入，先把那笔删掉再改回来'},
              }),
            ),
            409,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ],
      });
      await rig.ledger.sync();
      await expectLater(
        rig.assets.setStatus('a1', Asset.statusInUse),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'sale_recorded')
              .having((e) => e.status, 'status', 409),
        ),
      );
      expect(rig.ledger.assets.single.status, Asset.statusSold);
    });

    test('删除：本地立刻拿掉并同步', () async {
      final rig = Rig({
        'GET $api/changes': [
          changes(assets: [assetRow('a1')]),
          changes(next: 2, assets: [assetRow('a1', deletedAt: '2026-09-23T03:00:00.000Z')]),
        ],
        'DELETE $api/assets/a1': [
          {'asset': assetRow('a1', deletedAt: '2026-09-23T03:00:00.000Z')},
        ],
      });
      await rig.ledger.sync();
      await rig.assets.delete('a1');
      expect(rig.ledger.assets, isEmpty);
      expect(rig.server.countOf('GET', '$api/changes'), 2);
    });
  });

  group('HoldingsRepo 请求体', () {
    test('新建：自动行情 + 同时记一笔转账', () async {
      final rig = Rig({
        'POST $api/holdings': [
          {'holding': holdingRow('h1', price: null, prev: null, priceAt: null)},
        ],
        'GET $api/changes': [changes()],
      });
      final h = await rig.holdings.create(
        name: '',
        code: '161725',
        market: 'fund',
        quantityE4: 10000000,
        costCents: 100000,
        openedOn: '2026-09-14',
        autoPrice: true,
        accountId: 'inv',
        fromAccountId: 'bank',
      );
      expect(rig.server.bodyOf('POST', '$api/holdings'), {
        'name': '',
        'market': 'fund',
        'quantityE4': 10000000,
        'costCents': 100000,
        'openedOn': '2026-09-14',
        'priceSource': 'auto',
        'code': '161725',
        'accountId': 'inv',
        'recordTransaction': {'fromAccountId': 'bank'},
      });
      expect(h.priceE4, isNull);
      expect(rig.ledger.holdings.single.id, 'h1');
    });

    test('新建：手动价、不记账、没挂账户', () async {
      final rig = Rig({
        'POST $api/holdings': [
          {'holding': holdingRow('h1', source: 'manual')},
        ],
        'GET $api/changes': [changes()],
      });
      await rig.holdings.create(
        name: '银行理财',
        market: 'other',
        quantityE4: 10000,
        costCents: 5000000,
        openedOn: '2026-09-01',
        priceE4: 51000000,
        note: '三个月',
      );
      expect(rig.server.bodyOf('POST', '$api/holdings'), {
        'name': '银行理财',
        'market': 'other',
        'quantityE4': 10000,
        'costCents': 5000000,
        'openedOn': '2026-09-01',
        'priceSource': 'manual',
        'priceE4': 51000000,
        'note': '三个月',
      });
    });

    test('编辑不带份额和成本；空代码、空备注传 null', () async {
      final rig = Rig({
        'PATCH $api/holdings/h1': [
          {'holding': holdingRow('h1')},
        ],
        'GET $api/changes': [changes()],
      });
      await rig.holdings.edit(
        'h1',
        name: '白酒',
        code: '',
        market: 'other',
        autoPrice: false,
        openedOn: '2026-09-10',
        note: '',
      );
      final body = rig.server.bodyOf('PATCH', '$api/holdings/h1');
      expect(body, {
        'name': '白酒',
        'code': null,
        'market': 'other',
        'priceSource': 'manual',
        'openedOn': '2026-09-10',
        'accountId': null,
        'note': null,
      });
      expect(body.containsKey('quantityE4'), isFalse);
      expect(body.containsKey('costCents'), isFalse);
    });

    test('编辑时挂上投资账户：带 recordTransaction 说清成本从哪转进来', () async {
      final rig = Rig({
        'PATCH $api/holdings/h1': [
          {'holding': holdingRow('h1')},
        ],
        'GET $api/changes': [changes()],
      });
      await rig.holdings.edit(
        'h1',
        name: '白酒',
        market: 'fund',
        autoPrice: false,
        openedOn: '2026-09-10',
        accountId: 'inv',
        fromAccountId: 'bank',
      );
      final body = rig.server.bodyOf('PATCH', '$api/holdings/h1');
      expect(body['accountId'], 'inv');
      expect(body['recordTransaction'], {'fromAccountId': 'bank'});
    });

    test('开仓、加减仓、记物品、卖物品都带上调用方给的 clientId；回放的交易标出来', () async {
      final rig = Rig({
        'POST $api/holdings': [
          {'holding': holdingRow('h1')},
        ],
        'POST $api/holdings/h1/trade': [
          {'holding': holdingRow('h1'), 'transactions': <Object>[], 'replayed': true},
        ],
        'POST $api/assets': [
          {'asset': assetRow('a1')},
        ],
        'POST $api/assets/a1/sell': [
          {'asset': assetRow('a1', status: 'sold')},
        ],
        'GET $api/changes': [changes()],
      });
      await rig.holdings.create(
        name: '白酒',
        market: 'fund',
        quantityE4: 10000,
        costCents: 100,
        openedOn: '2026-09-10',
        clientId: 'k-open',
      );
      final trade = await rig.holdings.trade(
        'h1',
        buy: true,
        quantityE4: 10000,
        amountCents: 100,
        occurredOn: '2026-09-10',
        clientId: 'k-trade',
      );
      await rig.assets.create(
        name: 'iPhone',
        category: 'digital',
        priceCents: 100,
        purchasedOn: '2026-09-10',
        clientId: 'k-asset',
      );
      await rig.assets.sell('a1', saleCents: 1, endedOn: '2026-09-11', clientId: 'k-sell');
      expect(rig.server.bodyOf('POST', '$api/holdings')['clientId'], 'k-open');
      expect(rig.server.bodyOf('POST', '$api/holdings/h1/trade')['clientId'], 'k-trade');
      expect(rig.server.bodyOf('POST', '$api/assets')['clientId'], 'k-asset');
      expect(rig.server.bodyOf('POST', '$api/assets/a1/sell')['clientId'], 'k-sell');
      expect(trade.replayed, isTrue);
    });

    test('手动改价只发 priceE4', () async {
      final rig = Rig({
        'PATCH $api/holdings/h1': [
          {'holding': holdingRow('h1', price: 13000, prev: null)},
        ],
        'GET $api/changes': [changes()],
      });
      final h = await rig.holdings.setPrice('h1', 13000);
      expect(rig.server.bodyOf('PATCH', '$api/holdings/h1'), {'priceE4': 13000});
      expect(h.prevCloseE4, isNull);
    });

    test('减仓：请求体 + 返回的流水', () async {
      final rig = Rig({
        'POST $api/holdings/h1/trade': [
          {
            'holding': holdingRow('h1', qty: 5000000, cost: 50000),
            'transactions': [
              {
                'id': 't1',
                'clientId': 'c1',
                'type': 'transfer',
                'amountCents': 60000,
                'occurredAt': '2026-09-23T12:00:00+08:00',
              },
              {
                'id': 't2',
                'clientId': 'c2',
                'type': 'income',
                'amountCents': 10000,
                'occurredAt': '2026-09-23T12:00:00+08:00',
              },
            ],
          },
        ],
        'GET $api/changes': [changes()],
      });
      final result = await rig.holdings.trade(
        'h1',
        buy: false,
        quantityE4: 5000000,
        amountCents: 60000,
        occurredOn: '2026-09-23',
        accountId: 'bank',
      );
      expect(rig.server.bodyOf('POST', '$api/holdings/h1/trade'), {
        'side': 'sell',
        'quantityE4': 5000000,
        'amountCents': 60000,
        'occurredOn': '2026-09-23',
        'recordTransaction': {'accountId': 'bank'},
      });
      expect(result.holding.quantityE4, 5000000);
      expect(result.transactions.map((t) => t.id), ['t1', 't2']);
      expect(rig.ledger.holdings.single.costCents, 50000);
    });

    test('加仓不记账就不带 recordTransaction', () async {
      final rig = Rig({
        'POST $api/holdings/h1/trade': [
          {'holding': holdingRow('h1'), 'transactions': <Object>[]},
        ],
        'GET $api/changes': [changes()],
      });
      final result = await rig.holdings.trade(
        'h1',
        buy: true,
        quantityE4: 1,
        amountCents: 0,
        occurredOn: '2026-09-23',
      );
      expect(rig.server.bodyOf('POST', '$api/holdings/h1/trade'), {
        'side': 'buy',
        'quantityE4': 1,
        'amountCents': 0,
        'occurredOn': '2026-09-23',
      });
      expect(result.transactions, isEmpty);
    });

    test('刷新行情：解析结果、记下本机时间；有更新才同步', () async {
      final rig = Rig({
        'POST $api/holdings/refresh': [
          {
            'updated': 1,
            'failed': [
              {'id': 'h2', 'code': '600000', 'message': '行情里没有这个代码'},
            ],
            'refreshedAt': '2026-09-23T02:00:00.000Z',
            'throttled': false,
          },
          {'updated': 0, 'failed': <Object>[], 'refreshedAt': '2026-09-23T02:00:00.000Z', 'throttled': true},
        ],
        'GET $api/changes': [changes()],
      });
      final at = DateTime(2026, 9, 23, 10);
      final first = await rig.holdings.refresh(now: at);
      expect(first.updated, 1);
      expect(first.failed.single.code, '600000');
      expect(first.failed.single.message, '行情里没有这个代码');
      expect(first.refreshedAt!.isAtSameMomentAs(DateTime.utc(2026, 9, 23, 2)), isTrue);
      expect(first.throttled, isFalse);
      expect(await rig.holdings.lastRefreshAt(), at);
      expect(rig.server.countOf('GET', '$api/changes'), 1);

      final second = await rig.holdings.refresh(now: at);
      expect(second.throttled, isTrue);
      expect(rig.server.countOf('GET', '$api/changes'), 1);
    });

    test('被节流不算刷过：不记本机时刻，下次进投资页照样再问', () async {
      final rig = Rig({
        'GET $api/changes': [changes(holdings: [holdingRow('h1')])],
        'POST $api/holdings/refresh': [
          {'updated': 0, 'failed': <Object>[], 'refreshedAt': '2026-09-23T01:55:00.000Z', 'throttled': true},
          {'updated': 1, 'failed': <Object>[], 'refreshedAt': '2026-09-23T02:06:00.000Z', 'throttled': false},
        ],
      });
      await rig.ledger.sync();
      final t0 = DateTime(2026, 9, 23, 10);

      final first = await rig.holdings.refresh(now: t0);
      expect(first.throttled, isTrue);
      expect(await rig.holdings.lastRefreshAt(), isNull);

      final later = t0.add(const Duration(minutes: 11));
      final second = await rig.holdings.refreshIfStale(now: later);
      expect(second, isNotNull);
      expect(second!.throttled, isFalse);
      expect(rig.server.countOf('POST', '$api/holdings/refresh'), 2);
      expect(await rig.holdings.lastRefreshAt(), later);
    });

    group('进投资页自动刷新', () {
      Rig rigWith(List<Map<String, dynamic>> holdings) => Rig({
        'GET $api/changes': [changes(holdings: holdings)],
        'POST $api/holdings/refresh': [
          {'updated': 0, 'failed': <Object>[], 'refreshedAt': '2026-09-23T02:00:00.000Z', 'throttled': false},
        ],
      });

      test('从没刷过：刷一次', () async {
        final rig = rigWith([holdingRow('h1')]);
        await rig.ledger.sync();
        final result = await rig.holdings.refreshIfStale(now: DateTime(2026, 9, 23, 10));
        expect(result, isNotNull);
        expect(rig.server.countOf('POST', '$api/holdings/refresh'), 1);
      });

      test('一小时内刷过：不打扰；过了一小时：再刷', () async {
        final rig = rigWith([holdingRow('h1')]);
        await rig.ledger.sync();
        final t0 = DateTime(2026, 9, 23, 10);
        await rig.holdings.refresh(now: t0);

        final soon = await rig.holdings.refreshIfStale(
          now: t0.add(const Duration(minutes: 59)),
        );
        expect(soon, isNull);
        expect(rig.server.countOf('POST', '$api/holdings/refresh'), 1);

        final later = await rig.holdings.refreshIfStale(
          now: t0.add(const Duration(minutes: 61)),
        );
        expect(later, isNotNull);
        expect(rig.server.countOf('POST', '$api/holdings/refresh'), 2);
      });

      test('没有开自动行情的持仓（手动价、清仓的）：不刷', () async {
        final rig = rigWith([
          holdingRow('h1', source: 'manual'),
          holdingRow('h2', qty: 0, cost: 0),
        ]);
        await rig.ledger.sync();
        final result = await rig.holdings.refreshIfStale(now: DateTime(2026, 9, 23, 10));
        expect(result, isNull);
        expect(rig.server.countOf('POST', '$api/holdings/refresh'), 0);
      });
    });
  });
}
