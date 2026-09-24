import '../api/api_client.dart';
import '../local/local_store.dart';
import '../models/models.dart';
import 'ledger_repo.dart';

/// 有没有要拉行情的持仓：开了自动行情、有代码、还没清仓。
bool wantsAutoQuotes(Iterable<Holding> holdings) => holdings.any(
  (h) => !h.archived && !h.isCleared && h.isAuto && (h.code?.isNotEmpty ?? false),
);

/// 一只没拉到行情的持仓。
class QuoteFailure {
  const QuoteFailure({required this.id, this.code, required this.message});

  final String id;
  final String? code;
  final String message;

  factory QuoteFailure.fromJson(Map<String, dynamic> json) => QuoteFailure(
    id: jsonString(json['id']),
    code: jsonStringOrNull(json['code']),
    message: jsonString(json['message'], '没拿到行情'),
  );
}

/// `POST /holdings/refresh` 的结果。节流中服务端原样回上次结果并带 `throttled: true`。
class QuoteRefresh {
  const QuoteRefresh({
    this.updated = 0,
    this.failed = const [],
    this.refreshedAt,
    this.throttled = false,
  });

  final int updated;
  final List<QuoteFailure> failed;
  final DateTime? refreshedAt;
  final bool throttled;

  factory QuoteRefresh.fromJson(Map<String, dynamic> json) => QuoteRefresh(
    updated: jsonInt(json['updated']),
    failed: jsonList(json['failed'], QuoteFailure.fromJson),
    refreshedAt: jsonDateOrNull(json['refreshedAt']),
    throttled: jsonBool(json['throttled']),
  );
}

/// 加仓/减仓的结果：持仓的新样子 + 同时记下的流水（转账、盈亏）。
class TradeResult {
  const TradeResult({
    required this.holding,
    this.transactions = const [],
    this.replayed = false,
  });

  final Holding holding;
  final List<Transaction> transactions;

  /// 服务端认出这是同一个 clientId 的重发：上次其实已经记上了，这次回的是那一次的结果。
  final bool replayed;
}

/// 持仓的增删改、加减仓、刷新行情（`server/src/modules/holdings.js`）。
///
/// 写成功后同 [AssetsRepo]：先落本地，再增量同步。
class HoldingsRepo {
  HoldingsRepo({
    required ApiClient api,
    required LedgerRepo ledger,
    required LocalStore store,
  }) : _api = api,
       _ledger = ledger,
       _store = store;

  /// 本机上次真正拉到行情的时刻（被节流的不算）。
  static const String lastRefreshKey = 'holdings_refreshed_at';

  /// 进投资页时距上次刷新超过这么久就自动刷一次。服务端还有 10 分钟的全局节流兜底。
  static const Duration autoRefreshEvery = Duration(hours: 1);

  final ApiClient _api;
  final LedgerRepo _ledger;
  final LocalStore _store;

  /// [fromAccountId] 非空 = 同时记一笔转账（从它转到 [accountId]），这时 [accountId] 必填。
  /// 有成本又挂了投资账户就必须给（服务端 400 `holding_needs_transfer`）：净资产只给挂账户的
  /// 持仓补浮盈，成本得先以转账的形式记进那个账户。
  ///
  /// [clientId] 是幂等键：同一张表单重试时沿用同一个，回应丢了再发也只开一次仓、只记一笔。
  Future<Holding> create({
    required String name,
    String? code,
    required String market,
    required int quantityE4,
    required int costCents,
    required String openedOn,
    bool autoPrice = false,
    int? priceE4,
    String? accountId,
    String? note,
    String? fromAccountId,
    String? clientId,
  }) async {
    final body = <String, dynamic>{
      'name': name,
      'market': market,
      'quantityE4': quantityE4,
      'costCents': costCents,
      'openedOn': openedOn,
      'priceSource': autoPrice ? Holding.sourceAuto : Holding.sourceManual,
    };
    if (code != null && code.isNotEmpty) body['code'] = code;
    putIfNotNull(body, 'priceE4', priceE4);
    putIfNotNull(body, 'accountId', accountId);
    if (note != null && note.isNotEmpty) body['note'] = note;
    if (fromAccountId != null) {
      body['recordTransaction'] = {'fromAccountId': fromAccountId};
    }
    putIfNotNull(body, 'clientId', clientId);
    return _apply(await _api.post('/holdings', body));
  }

  /// 改基础信息。份额与成本服务端只认加仓/减仓，这里不让传。
  ///
  /// 有成本的持仓换投资账户时服务端的规矩（成本必须一直记在挂的账户里）：
  /// 原来没挂 → 挂上要给 [fromAccountId]，补记一笔成本从它转进来的转账；
  /// 从一个投资账户换到另一个 → 服务端自动补一笔移仓转账；直接解绑 → 400 `holding_account_locked`。
  Future<Holding> edit(
    String id, {
    required String name,
    String? code,
    required String market,
    required bool autoPrice,
    required String openedOn,
    String? accountId,
    String? note,
    String? fromAccountId,
  }) => _patch(id, {
    'name': name,
    'code': code == null || code.isEmpty ? null : code,
    'market': market,
    'priceSource': autoPrice ? Holding.sourceAuto : Holding.sourceManual,
    'openedOn': openedOn,
    'accountId': accountId,
    'note': note == null || note.isEmpty ? null : note,
    if (fromAccountId != null) 'recordTransaction': {'fromAccountId': fromAccountId},
  });

  /// 手动改价。服务端会顺手清掉昨收（手填的价没有可比的昨收）。
  Future<Holding> setPrice(String id, int priceE4) =>
      _patch(id, {'priceE4': priceE4});

  Future<void> delete(String id) async {
    await _api.delete('/holdings/$id');
    await _ledger.dropHolding(id);
    await _syncQuietly();
  }

  /// [accountId] 非空 = 同时记一笔转账（加仓：它 → 投资账户；减仓：投资账户 → 它），
  /// 减仓还会按盈亏再记一笔收入/支出。
  ///
  /// [clientId] 是幂等键，弹层开着期间的每次重试都沿用同一个：份额、移动平均成本、已实现盈亏
  /// 只能经交易改，重复一次就没法手工改回来。
  Future<TradeResult> trade(
    String id, {
    required bool buy,
    required int quantityE4,
    required int amountCents,
    required String occurredOn,
    String? accountId,
    String? clientId,
  }) async {
    final body = <String, dynamic>{
      'side': buy ? 'buy' : 'sell',
      'quantityE4': quantityE4,
      'amountCents': amountCents,
      'occurredOn': occurredOn,
    };
    if (accountId != null) body['recordTransaction'] = {'accountId': accountId};
    putIfNotNull(body, 'clientId', clientId);
    final res = await _api.post('/holdings/$id/trade', body);
    final holding = await _apply(res);
    return TradeResult(
      holding: holding,
      transactions: jsonList(res['transactions'], Transaction.fromJson),
      replayed: jsonBool(res['replayed']),
    );
  }

  /// 刷新行情并记下时刻；有持仓价格变了就同步回来。
  ///
  /// 被节流时回的是上一次的结果，之后新加的持仓并没有拉到价，不能算刷过：
  /// 否则一小时内进投资页都不会再补。
  Future<QuoteRefresh> refresh({DateTime? now}) async {
    final result = QuoteRefresh.fromJson(await _api.post('/holdings/refresh', const {}));
    if (!result.throttled) {
      await _store.write(lastRefreshKey, (now ?? DateTime.now()).toIso8601String());
    }
    if (result.updated > 0) await _syncQuietly();
    return result;
  }

  Future<DateTime?> lastRefreshAt() async =>
      jsonDateOrNull(await _store.read<String>(lastRefreshKey));

  /// 进投资页时调：没有自动行情的持仓、或一小时内刷过，就不打扰服务端，返回 null。
  Future<QuoteRefresh?> refreshIfStale({DateTime? now}) async {
    final at = now ?? DateTime.now();
    if (!wantsAutoQuotes(_ledger.holdings)) return null;
    final last = await lastRefreshAt();
    if (last != null && at.difference(last) < autoRefreshEvery) return null;
    return refresh(now: at);
  }

  Future<Holding> _patch(String id, Map<String, dynamic> patch) async =>
      _apply(await _api.patch('/holdings/$id', patch));

  Future<Holding> _apply(Map<String, dynamic> res) async {
    final holding = Holding.fromJson(unwrap(res, 'holding'));
    await _ledger.putHolding(holding);
    await _syncQuietly();
    return holding;
  }

  Future<void> _syncQuietly() async {
    try {
      await _ledger.sync();
    } catch (_) {
      // 写已经成功了；同步失败等下拉刷新再补。
    }
  }
}
