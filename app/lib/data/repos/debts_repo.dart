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
    String? clientId,
  }) async {
    final body = <String, dynamic>{
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
    putIfNotNull(body, 'clientId', clientId);
    return _apply(await _api.post('/debts', body));
  }

  /// 改基本信息。方向、金额服务端不让改（金额经 [move]）。
  Future<Debt> edit(
    String id, {
    required String kind,
    required String counterparty,
    required String startedOn,
    String? dueOn,
    required bool counted,
    String? memberId,
    String? note,
  }) async => _apply(
    await _api.patch('/debts/$id', {
      'kind': kind,
      'counterparty': counterparty,
      'startedOn': startedOn,
      'dueOn': dueOn,
      'counted': counted,
      'memberId': memberId,
      'note': note == null || note.isEmpty ? null : note,
    }),
  );

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
