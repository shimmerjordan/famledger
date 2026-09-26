import '../api/api_client.dart';
import '../models/models.dart';
import 'ledger_repo.dart';

/// 会员权益的增删改（`server/src/modules/platforms.js`、`memberships.js`、`benefits.js`、`benefit_events.js`）。
///
/// 和 `AssetsRepo`（assets_repo.dart）一个路数：写成功后先把服务端回的那行落进 [LedgerRepo]，再做一次增量同步 ——
/// 级联删除、平台合并会改到别的行（选项跟着搬、派生会员解开、引用改到目标平台），都得跟着过来。
/// 请求体由各表单自己拼（字段多、编辑时要带 null 清空），这里只管路径、信封和落本地。
class PerksRepo {
  PerksRepo({required ApiClient api, required LedgerRepo ledger})
    : _api = api,
      _ledger = ledger;

  final ApiClient _api;
  final LedgerRepo _ledger;

  // —— 平台 ——

  /// 重名时服务端回 409 `name_taken`，`ApiException.details['id']` 是已有那个平台，调用方可以直接改用它。
  Future<PerkPlatform> createPlatform(Map<String, dynamic> body) async =>
      _putPlatform(await _api.post('/platforms', body));

  Future<PerkPlatform> updatePlatform(String id, Map<String, dynamic> patch) async =>
      _putPlatform(await _api.patch('/platforms/$id', patch));

  /// 还有会员挂着或被当作领取平台时服务端回 409 `platform_in_use`（details 里是引用数），原样抛出。
  Future<void> deletePlatform(String id) async {
    await _api.delete('/platforms/$id');
    await _ledger.dropPlatform(id);
    await _syncQuietly();
  }

  /// 把 [id] 并入 [targetId]：服务端一个事务改掉所有引用、把名字记成目标的别名、软删 [id]。
  /// [clientId] 是幂等键：回应丢了重发只算一次。
  Future<PerkPlatform> mergePlatform(String id, {required String targetId, String? clientId}) async {
    final body = <String, dynamic>{'targetId': targetId};
    putIfNotNull(body, 'clientId', clientId);
    final target = PerkPlatform.fromJson(unwrap(await _api.post('/platforms/$id/merge', body), 'platform'));
    await _ledger.putPlatform(target);
    await _ledger.dropPlatform(id);
    await _syncQuietly();
    return target;
  }

  // —— 会员 ——

  /// [body] 里可以带 `clientId`（幂等）和 `recordTransaction`（同时记一笔支出）。
  Future<Membership> createMembership(Map<String, dynamic> body) async =>
      _putMembership(await _api.post('/memberships', body));

  Future<Membership> updateMembership(String id, Map<String, dynamic> patch) async =>
      _putMembership(await _api.patch('/memberships/$id', patch));

  /// [cascade] 为真时连名下的权益、选项、打卡事件一起删；为假而名下还有权益时服务端回 409 `has_children`。
  Future<void> deleteMembership(String id, {bool cascade = false}) async {
    await _api.delete(cascade ? '/memberships/$id?cascade=1' : '/memberships/$id');
    await _ledger.dropMembership(id, cascade: cascade);
    await _syncQuietly();
  }

  /// `POST /memberships/:id/renew`：续一期。[body] 里可以带 `clientId`（幂等）、`expiresOn`（不给按原到期日 + 一个周期）、
  /// `paidCents`、`chargeTransactionId`（只关联那笔流水、不另记账）、`recordTransaction`。
  /// once / none 的卡服务端回 409 `not_renewable`，原样抛出。
  Future<Membership> renewMembership(String id, Map<String, dynamic> body) async =>
      _putMembership(await _api.post('/memberships/$id/renew', body));

  /// `GET /memberships/charge-hints`：设了扣费特征的卡，到期日前后看到的对得上、没被关联过的扣费（服务端现查流水）。
  Future<List<ChargeHint>> chargeHints() async =>
      jsonList((await _api.get('/memberships/charge-hints'))['items'], ChargeHint.fromJson);

  // —— 权益 ——

  Future<Benefit> createBenefit(Map<String, dynamic> body) async =>
      _putBenefit(await _api.post('/benefits', body));

  Future<Benefit> updateBenefit(String id, Map<String, dynamic> patch) async =>
      _putBenefit(await _api.patch('/benefits/$id', patch));

  /// [cascade] 为真时连选项和打卡事件一起删；为假而还有子项时服务端回 409 `has_children`。
  Future<void> deleteBenefit(String id, {bool cascade = false}) async {
    await _api.delete(cascade ? '/benefits/$id?cascade=1' : '/benefits/$id');
    await _ledger.dropBenefit(id, cascade: cascade);
    await _syncQuietly();
  }

  // —— 打卡 ——

  /// 打一次卡（领了 / 用了 / 本期跳过）。[body] 带 `clientId`：回应丢了再点，服务端只记一条。
  /// N 选 1 的父权益服务端回 400（要打在选项上）。
  ///
  /// 重发时服务端原样回第一次记的那条；那条要是在这期间被删了（撤销、别的设备删的），回来的是墓碑：
  /// 不能当成活的放回本地（墓碑的 seq 已经同步过，之后不会再下发，本地就一直多一条），抛 409 `replayed_deleted`。
  Future<BenefitEvent> createBenefitEvent(Map<String, dynamic> body) async {
    final raw = unwrap(await _api.post('/benefit-events', body), 'event');
    if (raw['deletedAt'] != null) {
      throw const ApiException(409, 'replayed_deleted', '这一次其实之前已经记上了，后来又被删掉；要记就再点一次');
    }
    final item = BenefitEvent.fromJson(raw);
    await _ledger.putBenefitEvent(item);
    await _syncQuietly();
    return item;
  }

  /// 撤销打卡（软删）。
  Future<void> deleteBenefitEvent(String id) async {
    await _api.delete('/benefit-events/$id');
    await _ledger.dropBenefitEvent(id);
    await _syncQuietly();
  }

  Future<PerkPlatform> _putPlatform(Map<String, dynamic> res) async {
    final item = PerkPlatform.fromJson(unwrap(res, 'platform'));
    await _ledger.putPlatform(item);
    await _syncQuietly();
    return item;
  }

  Future<Membership> _putMembership(Map<String, dynamic> res) async {
    final item = Membership.fromJson(unwrap(res, 'membership'));
    await _ledger.putMembership(item);
    await _syncQuietly();
    return item;
  }

  Future<Benefit> _putBenefit(Map<String, dynamic> res) async {
    final item = Benefit.fromJson(unwrap(res, 'benefit'));
    await _ledger.putBenefit(item);
    await _syncQuietly();
    return item;
  }

  /// 拉一次增量、失败不抛：本地的样子过时了（「续了」撞上别的设备刚续过）时用。
  Future<void> refresh() => _syncQuietly();

  Future<void> _syncQuietly() async {
    try {
      await _ledger.sync();
    } catch (_) {
      // 写已经成功了；同步失败不该让调用方以为没存上，等下拉刷新再补。
    }
  }
}
