import '../api/api_client.dart';
import '../local/local_store.dart';
import '../local/outbox.dart';
import '../models/models.dart';

/// 一条服务端明确拒收的离线记录（校验不过、引用的基金被删了……）。
///
/// 这类错误重发多少次都还是错，队列里留着只会挡住后面的，所以直接出队，
/// 记在这里让 UI 有话可说：「N 条没能上传」。
class OutboxFailure {
  const OutboxFailure({
    required this.clientId,
    required this.code,
    required this.message,
    required this.at,
    this.payload = const {},
  });

  final String clientId;
  final String code;
  final String message;
  final DateTime at;

  /// 原始请求体：用户想重记的话还能照着填回去。
  final Map<String, dynamic> payload;

  factory OutboxFailure.fromJson(Map<String, dynamic> json) => OutboxFailure(
    clientId: jsonString(json['clientId']),
    code: jsonString(json['code'], 'error'),
    message: jsonString(json['message']),
    at: jsonDate(json['at']),
    payload: jsonMap(json['payload']),
  );

  Map<String, dynamic> toJson() => {
    'clientId': clientId,
    'code': code,
    'message': message,
    'at': at.toIso8601String(),
    'payload': payload,
  };
}

/// 流水的读写。断网时写操作进 [Outbox]，联网后 `flushOutbox()` 补发。
class TransactionsRepo {
  TransactionsRepo({
    required ApiClient api,
    required Outbox outbox,
    LocalStore? store,
  }) : _api = api,
       _outbox = outbox,
       _store = store;

  /// 服务端一次最多收 200 条（`server/src/modules/transactions.js` 的 MAX_BATCH），
  /// 留一半余量，也免得单个请求体太大被网关拦下。
  static const int batchChunk = 100;

  /// 被拒记录只留最近这些条，别让它无限长。
  static const int maxFailed = 100;

  /// `POST /transactions/bulk` 一次最多收这么多 id（服务端 MAX_BULK）。
  /// 不替调用方分批：分了批就不再是「全成或全败」。
  static const int maxBulk = 500;

  /// 「服务端就是不收」的状态码：重发多少次都一样，出队记账。
  ///
  /// 其余一律当暂时性问题**留在队列里**：401/403（令牌过期，重登后还要发）、
  /// 408/425/429（限流）、5xx（反代在重启）、以及断网。用户的账不能因为
  /// 服务器抖一下就从队列里悄悄消失。
  static const Set<int> definitiveStatuses = {400, 409, 413, 422};

  /// 逐条补发时额外认这两个：目标行已经没了，补丁/删除再发也没意义。
  static const Set<int> goneStatuses = {404, 410};

  static bool _isDefinitive(ApiException e, {bool allowGone = false}) =>
      definitiveStatuses.contains(e.status) ||
      (allowGone && goneStatuses.contains(e.status));

  static const String failedKey = 'outbox_failed';

  final ApiClient _api;
  final Outbox _outbox;
  final LocalStore? _store;
  final List<OutboxFailure> _failed = [];

  bool _flushing = false;

  Outbox get outbox => _outbox;

  /// 补发时被服务端拒收的那些（UI 可以提示并让用户重记）。
  List<OutboxFailure> get failedItems => List.unmodifiable(_failed);

  /// 重启后把上次的拒收记录读回来（内存里没有就从 [LocalStore] 取）。
  Future<List<OutboxFailure>> loadFailed() async {
    final raw = await _store?.read<List<dynamic>>(failedKey);
    if (raw != null) {
      _failed
        ..clear()
        ..addAll(
          raw.whereType<Map>().map((e) => OutboxFailure.fromJson(jsonMap(e))),
        );
    }
    return failedItems;
  }

  /// 用户「知道了」之后清掉（内存 + 本地都清）。
  Future<void> clearFailed() async {
    _failed.clear();
    await _store?.remove(failedKey);
  }

  /// 旧名，保留给已经写好的调用方。
  Future<void> clearFailedItems() => clearFailed();

  Future<TxPage> list(TxFilter filter, {String? cursor}) async {
    final query = filter.toQuery();
    if (cursor != null && cursor.isNotEmpty) query['cursor'] = cursor;
    return TxPage.fromJson(await _api.get('/transactions', query: query));
  }

  Future<Transaction> get(String id) async =>
      _parse(await _api.get('/transactions/$id'));

  /// 记一笔。断网时返回一条本地乐观流水（`pendingSync: true`）。
  ///
  /// 服务端判定疑似重复时，返回的流水带 `serverDuplicate: true`（顶层
  /// `duplicate` 标志），调用方据此只提示、不再弹通知。
  Future<Transaction> create(TransactionDraft draft) async {
    try {
      final res = await _api.post('/transactions', draft.toJson());
      final tx = _parse(res);
      await _flushQuietly();
      return jsonBool(res['duplicate'])
          ? tx.copyWith(serverDuplicate: true)
          : tx;
    } on ApiException catch (e) {
      if (!e.isNetwork) rethrow;
      // 超时 = 请求可能已经到服务端了：标成「发过一次」，之后要删得先确认，
      // 免得留下孤儿行。连都没连上才是干净的「没发过」。
      await _enqueue(
        draft.clientId,
        OutboxItem.opCreate,
        draft.toJson(),
        attempted: e.maybeSent,
      );
      return draft.toOptimisticTransaction();
    }
  }

  /// 改一笔。断网时入队并返回本地乐观结果（不抛），和 [create] 一个政策。
  ///
  /// [current] 给了就以它为底打补丁，返回的流水字段才是完整的；没给就只能
  /// 用补丁里的字段拼一条。
  Future<Transaction> update(
    String id,
    Map<String, dynamic> patch, {
    Transaction? current,
  }) async {
    try {
      final tx = _parse(await _api.patch('/transactions/$id', patch));
      await _flushQuietly();
      return tx;
    } on ApiException catch (e) {
      if (!e.isNetwork) rethrow;
      await _enqueue(id, OutboxItem.opPatch, {...patch, 'id': id}, attempted: e.maybeSent);
      return _optimisticPatch(id, patch, current);
    }
  }

  Future<void> delete(String id) async {
    try {
      await _api.delete('/transactions/$id');
      await _flushQuietly();
    } on ApiException catch (e) {
      if (!e.isNetwork) rethrow;
      await _enqueue(id, OutboxItem.opDelete, {'id': id}, attempted: e.maybeSent);
    }
  }

  Future<void> confirm(String id) async {
    try {
      await _api.post('/transactions/$id/confirm', null);
      await _flushQuietly();
    } on ApiException catch (e) {
      if (!e.isNetwork) rethrow;
      await _enqueue(id, OutboxItem.opConfirm, {'id': id}, attempted: e.maybeSent);
    }
  }

  Future<void> voidTx(String id) async {
    await _api.post('/transactions/$id/void', null);
  }

  /// 多选后一起改（[patch]）或一起删（[delete]），二者恰好给一个。返回服务端
  /// 说的改了/删了几笔。
  ///
  /// 服务端一个事务里全成或全败，所以断网不入队：半截排在队列里、之后又撞上
  /// 404 整批作废，还不如当场告诉用户没改成。
  Future<int> bulk(
    List<String> ids, {
    Map<String, dynamic>? patch,
    bool delete = false,
  }) async {
    if ((patch == null) == !delete) {
      throw ArgumentError('patch 和 delete 要恰好给一个');
    }
    final res = await _api.post('/transactions/bulk', {
      'ids': ids,
      if (delete) 'delete': true else 'patch': patch,
    });
    return jsonInt(res[delete ? 'deleted' : 'updated']);
  }

  /// 自动记账被人工改正后，把样本送去训练全家共享的模型。
  Future<void> learn(List<Map<String, dynamic>> samples) async {
    if (samples.isEmpty) return;
    try {
      await _api.post('/model/learn', {'samples': samples});
    } on ApiException catch (e) {
      if (!e.isNetwork) rethrow;
      await _enqueue('learn-${DateTime.now().microsecondsSinceEpoch}',
          OutboxItem.opLearn, {'samples': samples});
    }
  }

  /// 队列里还没发出去的新建流水，UI 可以先显示出来（发过之后又改的字段也
  /// 合进去，显示的是用户最后看到的那一版）。
  Future<List<Transaction>> pendingLocal() async {
    final items = await _outbox.pending();
    return items
        .where((e) => e.op == OutboxItem.opCreate)
        .map(
          (e) => TransactionDraft.fromJson({
            ...e.payload,
            ...e.pendingPatch,
          }).toOptimisticTransaction(),
        )
        .toList();
  }

  Future<int> pendingCount() => _outbox.count();

  /// 把队列发出去：create 走 `POST /transactions/batch`，其余逐条发。
  ///
  /// 还是断网就原样留着；服务端明确拒绝（error / 4xx）就出队并记进
  /// [failedItems]，免得一条坏数据把整条队列堵死。
  ///
  /// 开头读到的只是「有哪些 clientId 要发」；每条真正发出去的是
  /// [Outbox.markAttempted] 那一刻队列里的内容，发完再拿这份快照去
  /// [Outbox.markDone] —— 用户在补发期间又改/删了同一条的话，落下的部分会
  /// 留在队列里等下一次，而不是被一起删掉。
  Future<void> flushOutbox() async {
    if (_flushing) return;
    _flushing = true;
    try {
      final items = await _outbox.pending();
      if (items.isEmpty) return;

      final creates = items.where((e) => e.op == OutboxItem.opCreate).toList();
      for (var i = 0; i < creates.length; i += batchChunk) {
        final chunk = creates.sublist(
          i,
          i + batchChunk > creates.length ? creates.length : i + batchChunk,
        );
        if (!await _flushChunk(chunk.map((e) => e.clientId))) return;
      }

      for (final queued in items.where((e) => e.op != OutboxItem.opCreate)) {
        // 轮到它了才取快照：从 flush 开头到现在，用户可能又往这条里并了字段。
        final fresh = await _outbox.markAttempted([queued.clientId]);
        if (fresh.isEmpty) continue; // 已经被合并掉了
        final item = fresh.first;
        if (item.op == OutboxItem.opCreate) continue; // 变成 create 了，下次走 batch
        try {
          final serverId = await _apply(item);
          // 在途中这条又被改/删的话，markDone 会把没做完的部分留下来。
          await _outbox.markDone(item.clientId, sent: item, serverId: serverId);
        } on ApiException catch (e) {
          // 同样的政策：只有明确的客户端错误才丢，暂时性的留着。
          if (!_isDefinitive(e, allowGone: true)) return;
          await _recordFailure(
            item.clientId,
            {'error': e.code, 'message': e.message},
            {...item.payload, ...item.pendingPatch},
          );
          // 这份请求体是死了；在途中攒下的新改动 / 删除还得留着下次发。
          await _outbox.markDone(
            item.clientId,
            sent: item,
            serverId: _targetId(item),
          );
        }
      }
    } on ApiException catch (e) {
      if (!e.isNetwork) rethrow;
    } finally {
      _flushing = false;
    }
  }

  /// 发一块 create。返回 false = 断网了，整个 flush 该停下来等下次。
  Future<bool> _flushChunk(Iterable<String> clientIds) async {
    // 先记「试过了」再发（响应丢了也知道服务端可能已经有这行），拿回来的是
    // 此刻队列里的那份：开头读的快照之后用户可能又并了字段进去，或者已经把它
    // 改成了 delete（那就不该再建一次）。
    final chunk = (await _outbox.markAttempted(clientIds))
        .where((e) => e.op == OutboxItem.opCreate)
        .toList();
    if (chunk.isEmpty) return true;
    final Map<String, dynamic> res;
    try {
      res = await _api.post('/transactions/batch', {
        'items': chunk.map((e) => e.payload).toList(),
      });
    } on ApiException catch (e) {
      // 只有「服务端明确说这批数据不对」才丢；502/401/429 这些留着下次再发。
      if (!_isDefinitive(e)) return false;
      // 整块被拒（体太大、字段不合法…）：逐条记账出队，别让一块坏数据
      // 把后面所有人都堵死。这条 create 本身就没建成，在途中针对它的改/删
      // 也就没有对象了，所以这里不传快照、整行删掉。
      for (final item in chunk) {
        await _recordFailure(
          item.clientId,
          {'error': e.code, 'message': e.message},
          item.payload,
        );
        await _outbox.markDone(item.clientId);
      }
      return true;
    }

    final byClientId = {for (final item in chunk) item.clientId: item};
    for (final row in jsonMapList(res['results'])) {
      final status = jsonString(row['status']);
      final clientId = jsonString(row['clientId']);
      if (clientId.isEmpty) continue;
      if (status == 'created' || status == 'exists') {
        final queued = byClientId[clientId];
        final serverId = jsonString(row['id'], clientId);
        try {
          // 发出去之后又改过的字段，这时才知道服务端 id，补打一次。
          if (queued != null && queued.pendingPatch.isNotEmpty) {
            await _api.patch('/transactions/$serverId', queued.pendingPatch);
          }
        } on ApiException catch (e) {
          if (!_isDefinitive(e, allowGone: true)) return false;
          await _recordFailure(
            clientId,
            {'error': e.code, 'message': e.message},
            queued?.pendingPatch ?? const {},
          );
        }
        // 发送期间这条又被改/删的话，markDone 会把没做完的部分留下来。
        await _outbox.markDone(clientId, sent: queued, serverId: serverId);
      } else if (status == 'error') {
        await _recordFailure(clientId, row, byClientId[clientId]?.payload);
        await _outbox.markDone(clientId);
      }
    }
    return true;
  }

  /// 发一条非 create 的操作，返回它作用到的服务端 id。
  Future<String> _apply(OutboxItem item) async {
    var id = _targetId(item);
    if (item.op == OutboxItem.opPatch) {
      // 冻结的 payload + 发过之后攒下的字段，一个请求带走。
      final body = {...item.payload, ...item.pendingPatch}..remove('id');
      if (body.isNotEmpty) await _api.patch('/transactions/$id', body);
    } else if (item.op == OutboxItem.opDelete) {
      final draft = item.payload['create'];
      if (draft is Map) {
        // 这条 create 发出去过但没等到回应：clientId 幂等重发一次拿到服务端
        // id（已落库就直接回那行），再删，免得留下一条孤儿。
        final res = await _api.post('/transactions', jsonMap(draft));
        final created = unwrap(res, 'transaction');
        id = jsonString(created['id'], id);
      }
      await _api.delete('/transactions/$id');
    } else if (item.op == OutboxItem.opConfirm) {
      await _api.post('/transactions/$id/confirm', null);
    } else if (item.op == OutboxItem.opLearn) {
      await _api.post('/model/learn', item.payload);
    }
    return id;
  }

  /// 这条操作的目标：payload 里的服务端 id，没有就是 clientId 本身。
  static String _targetId(OutboxItem item) =>
      jsonString(item.payload['id'], item.clientId);

  /// 服务端把单条流水包在 `{transaction: {...}}` 里。
  Transaction _parse(Map<String, dynamic> res) =>
      Transaction.fromJson(unwrap(res, 'transaction'));

  Transaction _optimisticPatch(
    String id,
    Map<String, dynamic> patch,
    Transaction? current,
  ) {
    final base = current?.toJson() ??
        <String, dynamic>{'id': id, 'clientId': id, 'occurredAt': ''};
    return Transaction.fromJson({...base, ...patch, 'id': id})
        .copyWith(pendingSync: true);
  }

  Future<void> _recordFailure(
    String clientId,
    Map<String, dynamic> row, [
    Map<String, dynamic>? payload,
  ]) async {
    _failed.add(
      OutboxFailure(
        clientId: clientId,
        code: jsonString(row['error'], 'error'),
        message: jsonString(row['message'], '服务端没有收下这条记录'),
        at: DateTime.now(),
        payload: payload ?? const {},
      ),
    );
    if (_failed.length > maxFailed) {
      _failed.removeRange(0, _failed.length - maxFailed);
    }
    await _store?.write(failedKey, _failed.map((e) => e.toJson()).toList());
  }

  Future<void> _enqueue(
    String key,
    String op,
    Map<String, dynamic> payload, {
    bool attempted = false,
  }) => _outbox.enqueue(
    OutboxItem(
      clientId: key,
      op: op,
      payload: payload,
      queuedAt: DateTime.now(),
      attempted: attempted,
    ),
  );

  /// 每次联网成功后顺手补发，失败不影响本次操作。
  Future<void> _flushQuietly() async {
    try {
      await flushOutbox();
    } catch (_) {
      // 补发失败就下次再说。
    }
  }
}
