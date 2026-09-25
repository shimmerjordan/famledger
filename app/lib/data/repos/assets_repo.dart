import '../api/api_client.dart';
import '../models/models.dart';
import 'ledger_repo.dart';

/// 「同时记一笔」时要落到哪：账户 / 基金 / 类别都可以不填（基金缺省走默认基金）。
class AssetRecord {
  const AssetRecord({this.accountId, this.fundId, this.categoryId, this.memberId});

  final String? accountId;
  final String? fundId;
  final String? categoryId;
  final String? memberId;

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
    putIfNotNull(json, 'accountId', accountId);
    putIfNotNull(json, 'fundId', fundId);
    putIfNotNull(json, 'categoryId', categoryId);
    putIfNotNull(json, 'memberId', memberId);
    return json;
  }
}

/// 物品的估值设置（spec §2 那几个字段）。折率、残值为 null = 跟随类别；手动估值的金额和日期
/// 服务端要求成对，清也要一起清。
class ValuationInput {
  const ValuationInput({
    this.method = Asset.methodAuto,
    this.rateBp,
    this.residualBp,
    this.manualValueCents,
    this.manualValueOn,
    this.netWorth = Asset.netWorthAuto,
  });

  final String method;
  final int? rateBp;
  final int? residualBp;
  final int? manualValueCents;

  /// `YYYY-MM-DD`
  final String? manualValueOn;
  final String netWorth;

  /// 新建：只带改过的，没改的交给服务端默认（请求体和以前一样干净）。
  Map<String, dynamic> toCreateJson() {
    final json = <String, dynamic>{};
    if (method != Asset.methodAuto) json['valuationMethod'] = method;
    putIfNotNull(json, 'rateBp', rateBp);
    putIfNotNull(json, 'residualBp', residualBp);
    putIfNotNull(json, 'manualValueCents', manualValueCents);
    putIfNotNull(json, 'manualValueOn', manualValueOn);
    if (netWorth != Asset.netWorthAuto) json['netWorth'] = netWorth;
    return json;
  }

  /// 编辑：六个键都带上，null 就是清掉。
  Map<String, dynamic> toPatchJson() => {
    'valuationMethod': method,
    'rateBp': rateBp,
    'residualBp': residualBp,
    'manualValueCents': manualValueCents,
    'manualValueOn': manualValueOn,
    'netWorth': netWorth,
  };
}

/// 物品的增删改、状态流转与卖出（`server/src/modules/assets.js`）。
///
/// 写成功后先把服务端回的那行落进 [LedgerRepo]，再做一次增量同步：
/// 「同时记一笔」建出来的流水、别的设备的改动都要跟着过来。
class AssetsRepo {
  AssetsRepo({required ApiClient api, required LedgerRepo ledger})
    : _api = api,
      _ledger = ledger;

  final ApiClient _api;
  final LedgerRepo _ledger;

  /// [record] 非空 = 同时记一笔支出（买价为 0 时服务端会忽略）。
  ///
  /// [clientId] 是幂等键：同一张表单重试时沿用同一个，回应丢了再发也只建一件、只记一笔。
  /// [valuation] 只带改过的估值字段（[ValuationInput.toCreateJson]）。
  Future<Asset> create({
    required String name,
    required String category,
    required int priceCents,
    required String purchasedOn,
    int? expectedDays,
    String? note,
    ValuationInput? valuation,
    AssetRecord? record,
    String? clientId,
  }) async {
    final body = <String, dynamic>{
      'name': name,
      'category': category,
      'priceCents': priceCents,
      'purchasedOn': purchasedOn,
    };
    putIfNotNull(body, 'expectedDays', expectedDays);
    if (note != null && note.isNotEmpty) body['note'] = note;
    if (valuation != null) body.addAll(valuation.toCreateJson());
    if (record != null) body['recordTransaction'] = record.toJson();
    putIfNotNull(body, 'clientId', clientId);
    return _apply(await _api.post('/assets', body));
  }

  /// 编辑基本信息。预期天数、备注传 null 就是清掉；给了 [valuation] 就把六个估值字段全带上。
  Future<Asset> edit(
    String id, {
    required String name,
    required String category,
    required int priceCents,
    required String purchasedOn,
    int? expectedDays,
    String? note,
    ValuationInput? valuation,
  }) => update(id, {
    'name': name,
    'category': category,
    'priceCents': priceCents,
    'purchasedOn': purchasedOn,
    'expectedDays': expectedDays,
    'note': note == null || note.isEmpty ? null : note,
    ...?valuation?.toPatchJson(),
  });

  Future<Asset> update(String id, Map<String, dynamic> patch) async =>
      _apply(await _api.patch('/assets/$id', patch));

  /// 闲置 / 恢复在用。改回在用时服务端会清掉结束日期与卖出价；
  /// 卖出时记过收入的会被 409 `sale_recorded` 拦下。
  Future<Asset> setStatus(String id, String status) =>
      update(id, {'status': status});

  Future<Asset> retire(String id, {required String endedOn}) =>
      update(id, {'status': Asset.statusRetired, 'endedOn': endedOn});

  /// [record] 非空且卖出价 > 0 时同时记一笔收入。[clientId] 同 [create]。
  Future<Asset> sell(
    String id, {
    required int saleCents,
    required String endedOn,
    AssetRecord? record,
    String? clientId,
  }) async {
    final body = <String, dynamic>{'saleCents': saleCents, 'endedOn': endedOn};
    if (record != null) body['recordTransaction'] = record.toJson();
    putIfNotNull(body, 'clientId', clientId);
    return _apply(await _api.post('/assets/$id/sell', body));
  }

  /// 删物品不删它关联的流水：那笔钱是真花出去了。
  Future<void> delete(String id) async {
    await _api.delete('/assets/$id');
    await _ledger.dropAsset(id);
    await _syncQuietly();
  }

  Future<Asset> _apply(Map<String, dynamic> res) async {
    final asset = Asset.fromJson(unwrap(res, 'asset'));
    await _ledger.putAsset(asset);
    await _syncQuietly();
    return asset;
  }

  Future<void> _syncQuietly() async {
    try {
      await _ledger.sync();
    } catch (_) {
      // 写已经成功了；同步失败不该让调用方以为没存上，等下拉刷新再补。
    }
  }
}
