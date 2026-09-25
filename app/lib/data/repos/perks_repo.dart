import '../api/api_client.dart';
import '../models/models.dart';
import 'ledger_repo.dart';

/// 会员权益的增删改（`server/src/modules/platforms.js`、`memberships.js`、`benefits.js`）。
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

  Future<void> _syncQuietly() async {
    try {
      await _ledger.sync();
    } catch (_) {
      // 写已经成功了；同步失败不该让调用方以为没存上，等下拉刷新再补。
    }
  }
}
