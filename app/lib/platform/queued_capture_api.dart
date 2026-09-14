import '../capture/pipeline.dart';
import 'file_capture_store.dart';
import 'http_capture_api.dart';

/// 给管线用的 [CaptureApi]：在 [HttpCaptureApi] 外面包一层离线底账。
///
/// - **先排空、再直写**：对某条流水直写（patch / confirm / delete）之前，先把这条流水
///   积压在队列里的动作按入队顺序推完，服务端看到的顺序永远等于用户操作顺序 ——
///   离线回复「宠物」、在线又回复「旅行」，最终一定是旅行，旧的 patch 不会在事后
///   把新结果盖回去；排空时遇到临时故障就把新动作也排到后面并原样抛出（管线照旧
///   记 `synced=false`），遇到 4xx 就把那条丢掉继续。
/// - **学习样本按特征键取代**：同一条捕获再纠正一次会产生同特征、不同标签的样本，
///   新样本来了先把队列里同键的旧样本删掉，再发 / 再排队。
/// - 建流水不排队：记录本身的草稿 + clientId 幂等就是它的重放依据（`pendingUploads`）；
/// - 4xx（429 除外）是「请求本身有问题」，不排队，管线会记 `syncError` 交给用户处理；
/// - 成功一次就说明网络回来了，通过 [onSuccess] 通知运行时去重放别的积压。
class QueuedCaptureApi implements CaptureApi {
  QueuedCaptureApi(
    this.inner,
    this.store, {
    this.onSuccess,
    DateTime Function()? now,
    String Function()? idGenerator,
  }) : _now = now ?? DateTime.now,
       _newId = idGenerator ?? newCaptureId;

  final HttpCaptureApi inner;
  final LocalCaptureStore store;
  final void Function()? onSuccess;
  final DateTime Function() _now;
  final String Function() _newId;

  /// 值得重试的失败：请求根本没到 / 没等到，或服务端暂时不行。
  static bool isTransient(Object e) =>
      e is CaptureNetworkException || (e is CaptureApiException && e.isTransient);

  /// 把一条排队的动作原样推给服务端；类型不认识抛 [UnsupportedError]（老版本留下的）。
  static Future<void> sendQueuedOp(HttpCaptureApi api, CaptureOp op) => switch (op.type) {
    'patch' => api.patchTransaction(op.transactionId, op.payload ?? const <String, dynamic>{}),
    'confirm' => api.confirmTransaction(op.transactionId),
    'delete' => api.deleteTransaction(op.transactionId),
    _ => Future<void>.error(UnsupportedError('unknown op type ${op.type}')),
  };

  @override
  Future<CaptureApiResult> createTransaction(Map<String, dynamic> body) =>
      _plain(() => inner.createTransaction(body));

  @override
  Future<void> patchTransaction(String id, Map<String, dynamic> patch) =>
      _queued('patch', id, patch, () => inner.patchTransaction(id, patch));

  @override
  Future<void> confirmTransaction(String id) =>
      _queued('confirm', id, null, () => inner.confirmTransaction(id));

  @override
  Future<void> deleteTransaction(String id) =>
      _queued('delete', id, null, () => inner.deleteTransaction(id));

  @override
  Future<void> learn(List<LearnSample> samples) async {
    final payload = samples.where((s) => !s.isEmpty).map((s) => s.toJson()).toList();
    if (payload.isEmpty) return;
    // 同一条捕获的旧样本（同特征、旧标签）作废：不管这次成不成功，它都不该再进共享模型。
    final keys = payload.map(QueuedLearnSample.featureKeyOf).toSet();
    final stale = (await store.pendingLearn()).where((e) => keys.contains(e.featureKey)).map((e) => e.id).toList();
    if (stale.isNotEmpty) await store.removeLearn(stale);
    try {
      await inner.learnJson(payload);
      onSuccess?.call();
    } catch (e) {
      if (isTransient(e)) await store.enqueueLearn(payload);
      rethrow;
    }
  }

  @override
  Future<Map<String, dynamic>?> aiClassify(Map<String, dynamic> input) =>
      _plain(() => inner.aiClassify(input));

  Future<T> _plain<T>(Future<T> Function() run) async {
    final out = await run();
    onSuccess?.call();
    return out;
  }

  Future<void> _queued(
    String type,
    String transactionId,
    Map<String, dynamic>? payload,
    Future<void> Function() run,
  ) async {
    try {
      await _drain(transactionId);
      await run();
      onSuccess?.call();
    } catch (e) {
      if (isTransient(e)) {
        await store.enqueueOp(
          CaptureOp(
            id: _newId(),
            at: _now(),
            type: type,
            captureId: await store.captureIdForTransaction(transactionId) ?? '',
            transactionId: transactionId,
            payload: payload,
          ),
        );
      }
      rethrow;
    }
  }

  /// 把这条流水积压的动作按序推完。临时故障原样抛出（新动作随后排到它们后面）；
  /// 4xx 与不认识的类型直接丢掉，继续下一条。
  Future<void> _drain(String transactionId) async {
    final queued = (await store.pendingOps()).where((o) => o.transactionId == transactionId).toList();
    for (final op in queued) {
      try {
        await sendQueuedOp(inner, op);
        await store.removeOp(op.id);
      } on CaptureApiException catch (e) {
        if (!e.isClientError) rethrow;
        await store.removeOp(op.id);
      } on UnsupportedError {
        await store.removeOp(op.id);
      }
    }
  }
}
