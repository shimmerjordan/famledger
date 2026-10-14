import '../api/api_client.dart';
import '../models/models.dart';
import 'ledger_repo.dart';

/// 收回 / 追加之后：债务的新样子 + 同时记下的流水。
class DebtMoveResult {
  const DebtMoveResult({required this.debt, this.transactions = const [], this.replayed = false});

  final Debt debt;
  final List<Transaction> transactions;
  final bool replayed;
}

/// 债务的增删改、收回 / 追加（`server/src/modules/debts.js`）。
///
/// 新建会连带建一个内部账户，收回会记转账：写成功后先落本地，再增量同步把账户和流水拉回来。
class DebtsRepo {
  DebtsRepo({required ApiClient api, required LedgerRepo ledger}) : _api = api, _ledger = ledger;

  final ApiClient _api;
  final LedgerRepo _ledger;

  /// [accountId] 非空 = 钱经这个账户走：借款类记一笔转账，人情记一笔支出 / 收入（类别「人情」）。
  /// [settledCents]：记账前已经收回 / 还掉的部分，服务端同一个事务里按不记流水收回一次（不用建完再点「收回」）。
  /// [clientId] 是幂等键，同一张表单重试时沿用。
  Future<Debt> create({
    required String direction,
    required String kind,
    required String counterparty,
    required int amountCents,
    required String startedOn,
    String? dueOn,
    bool? counted,
    String? memberId,
    String? note,
    String? accountId,
    int? settledCents,
    String? currency,
    String? clientId,
  }) async {
    final body = <String, dynamic>{
      if (currency != null) 'currency': currency,
      'direction': direction,
      'kind': kind,
      'counterparty': counterparty,
      'amountCents': amountCents,
      'startedOn': startedOn,
    };
    putIfNotNull(body, 'dueOn', dueOn);
    putIfNotNull(body, 'counted', counted);
    putIfNotNull(body, 'memberId', memberId);
    if (note != null && note.isNotEmpty) body['note'] = note;
    if (accountId != null) body['recordTransaction'] = {'accountId': accountId};
    if (settledCents != null && settledCents > 0) body['settledCents'] = settledCents;
    putIfNotNull(body, 'clientId', clientId);
    return _apply(await _api.post('/debts', body));
  }

  /// 改债务。[memberId] 原样发（null = 家庭共用）——编辑表单一定要把选的人带上，不然会被清掉。
  /// 手动微调（只发给了的）：[amountCents] 总额；[remainingCents] 还剩多少（差额进内部账户期初、留一行「校准」）；
  /// [direction]、[currency] 只有还没有往来流水时能改（服务端 409 会说清楚）。
  Future<Debt> edit(
    String id, {
    required String kind,
    required String counterparty,
    required String startedOn,
    String? dueOn,
    required bool counted,
    String? memberId,
    String? note,
    int? amountCents,
    int? remainingCents,
    String? direction,
    String? currency,
  }) async => _apply(
    await _api.patch('/debts/$id', {
      'kind': kind,
      'counterparty': counterparty,
      'startedOn': startedOn,
      'dueOn': dueOn,
      'counted': counted,
      'memberId': memberId,
      'note': note == null || note.isEmpty ? null : note,
      if (amountCents != null) 'amountCents': amountCents,
      if (remainingCents != null) 'remainingCents': remainingCents,
      if (direction != null) 'direction': direction,
      if (currency != null) 'currency': currency,
    }),
  );

  /// 改一行备忘（不记流水的那几笔）：[index] 是 memoLog 里的下标。[amountCents] 是正数，方向跟着原来那行；
  /// 服务端会按差额改回内部账户的期初（起始、追加那几行连总额一起改）。
  Future<Debt> editMemo(String id, int index, {int? amountCents, String? on, String? note}) async => _apply(
    await _api.patch('/debts/$id/memo/$index', {
      if (amountCents != null) 'amountCents': amountCents,
      if (on != null) 'on': on,
      if (note != null) 'note': note,
    }),
  );

  /// 删一行备忘：它当初对还剩多少（和总额）的影响一起撤掉。
  Future<Debt> deleteMemo(String id, int index) async => _apply(await _api.delete('/debts/$id/memo/$index'));

  Future<Debt> setArchived(String id, bool archived) async =>
      _apply(await _api.patch('/debts/$id', {'archived': archived}));

  /// 收回 / 还钱（[add] 为假）或再借（[add] 为真）。[accountId] 为空 = 不记流水，只改账。
  Future<DebtMoveResult> move(
    String id, {
    required bool add,
    required int amountCents,
    required String occurredOn,
    String? accountId,
    String? note,
    String? clientId,
  }) async {
    final body = <String, dynamic>{
      'action': add ? 'add' : 'settle',
      'amountCents': amountCents,
      'occurredOn': occurredOn,
    };
    putIfNotNull(body, 'accountId', accountId);
    if (note != null && note.isNotEmpty) body['note'] = note;
    putIfNotNull(body, 'clientId', clientId);
    final res = await _api.post('/debts/$id/settle', body);
    final debt = await _apply(res);
    return DebtMoveResult(
      debt: debt,
      transactions: jsonList(res['transactions'], Transaction.fromJson),
      replayed: jsonBool(res['replayed']),
    );
  }

  Future<void> delete(String id) async {
    await _api.delete('/debts/$id');
    await _ledger.dropDebt(id);
    await _syncQuietly();
  }

  Future<Debt> _apply(Map<String, dynamic> res) async {
    final debt = Debt.fromJson(unwrap(res, 'debt'));
    await _ledger.putDebt(debt);
    await _syncQuietly();
    return debt;
  }

  Future<void> _syncQuietly() async {
    try {
      await _ledger.sync();
    } catch (_) {
      // 写已经成功了；同步失败等下拉刷新再补。
    }
  }
}
