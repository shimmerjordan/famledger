import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../capture/parser.dart';
import '../capture/pipeline.dart';
import '../data/api/api_client.dart';
import '../data/local/local_store.dart';
import '../data/local/secure_store.dart';
import '../data/models/models.dart';
import '../data/repos/ledger_repo.dart';
import '../data/repos/session_repo.dart';
import '../data/repos/settings_repo.dart';
import 'capture_adapters.dart';
import 'file_capture_store.dart';
import 'http_capture_api.dart';
import 'queued_capture_api.dart';

/// headless 引擎里的总装：会话（安全存储）+ 主数据缓存 + 家庭设置 → [CapturePipeline]，
/// 再把原生递过来的通知 / 动作翻译成管线调用，把结果整理成通知能用的 map。
///
/// 没有 UI，不依赖 Riverpod；主引擎在不在都能跑。所有对外方法都不抛异常 ——
/// 原生那头等的是一个 map，抛出去只会让通知永远停在「处理中」。
class CaptureRuntime {
  CaptureRuntime({
    required SecureStore secure,
    required LocalStore cache,
    required LocalCaptureStore store,
    http.Client? httpClient,
    this.apiTimeout = const Duration(seconds: 10),
    this.syncInterval = const Duration(minutes: 5),
    this.autoReplay = true,
    DateTime Function()? now,
  }) : _secure = secure,
       _cache = cache,
       _store = store,
       _httpClient = httpClient,
       _now = now ?? DateTime.now;

  final SecureStore _secure;
  final LocalStore _cache;
  final LocalCaptureStore _store;
  final http.Client? _httpClient;
  final DateTime Function() _now;

  /// 后台里每个请求的上限：断网时别让一条通知卡 20 秒。
  final Duration apiTimeout;

  /// 主数据 / 设置多久重新拉一次。
  final Duration syncInterval;

  /// 每次成功的接口调用之后自动重放离线队列（测试里关掉，改为显式调 [replayPending]）。
  final bool autoReplay;

  /// 一次 `POST /model/learn` 最多带多少条（服务端上限 500）。
  static const int learnBatchSize = 50;

  bool _replaying = false;

  /// 装配好的一整套（会话 / 客户端 / 主数据 / 设置 / 管线）。要么全有、要么没有 ——
  /// 中间状态从不发布，并发到达的事件不会撞见「客户端有了、主数据还没有」。
  _Assembly? _assembly;

  /// 在途的装配 / 备管线：同一时刻只做一份，其他调用者等同一个 Future。
  Future<_Assembly?>? _assembling;
  Future<CapturePipeline?>? _preparing;
  int _modelStamp = 0;

  LocalCaptureStore get store => _store;

  /// 结果通知上该给哪几个按钮。
  ///
  /// 刚记下时一律「正确 / 修改… / 撤销」（自动入账的那笔点「正确」= 显式认可，也要学）；
  /// 用户操作过一次之后只剩「修改… / 撤销」，撤销掉的什么都不剩。
  static List<String> actionsFor(CaptureDecision? decision, {bool afterAction = false}) =>
      switch (decision) {
        CaptureDecision.pending => const ['confirm', 'edit', 'undo'],
        CaptureDecision.recorded => afterAction ? const ['edit', 'undo'] : const ['confirm', 'edit', 'undo'],
        _ => const <String>[],
      };

  /// 给原生的「出错」回应（形状与正常回应一致）。
  static Map<String, dynamic> errorResponse(String title, String body) => {
    'decision': 'error',
    'title': title,
    'body': body,
    'actions': const <String>[],
  };

  // ------------------------------------------------------------ Native → Dart

  /// `onNotification({id, package, title, text, bigText, postedAt})`
  Future<Map<String, dynamic>> handleNotification(Object? args) async {
    RawNotification raw;
    try {
      raw = RawNotification.fromMap((args as Map).cast<dynamic, dynamic>());
    } catch (e) {
      return errorResponse('通知格式不对', '$e');
    }
    try {
      final pipeline = await _ensurePipeline();
      if (pipeline == null) {
        await _log(raw.packageName, '家账还没登录', '打开家账登录后才能自动记账', 'error');
        return errorResponse('家账还没登录', '打开家账登录后，才能自动记账');
      }
      final outcome = await pipeline.handle(raw);
      final record = outcome.captureId == null ? null : await _store.loadCapture(outcome.captureId!);
      await _store.appendLog(
        CaptureLogEntry(
          at: _now(),
          package: raw.packageName,
          title: outcome.title,
          body: outcome.body,
          decision: outcome.decision.name,
          captureId: outcome.captureId,
          transactionId: record?.transactionId,
          amountCents: outcome.draft?.amountCents,
          type: outcome.draft?.type,
        ),
      );
      return {
        'decision': outcome.decision.name,
        'title': outcome.title,
        'body': outcome.body,
        if (outcome.captureId != null) 'captureId': outcome.captureId,
        if (record?.transactionId != null) 'transactionId': record!.transactionId,
        'actions': outcome.captureId == null ? const <String>[] : actionsFor(record?.decision ?? outcome.decision),
      };
    } catch (e, st) {
      debugPrint('handleNotification failed: $e\n$st');
      await _log(raw.packageName, '自动记账出错', _short(e), 'error');
      return errorResponse('自动记账出错', _short(e));
    }
  }

  /// `onAction({captureId, action: confirm|undo|reply, text?})`
  Future<Map<String, dynamic>> handleAction(Object? args) async {
    final map = args is Map ? args : const <dynamic, dynamic>{};
    final captureId = '${map['captureId'] ?? ''}';
    final action = '${map['action'] ?? ''}';
    final text = map['text']?.toString() ?? '';
    if (captureId.isEmpty) return _actionResponse('缺少 captureId', '', const <String>[]);
    try {
      final pipeline = await _ensurePipeline();
      if (pipeline == null) {
        return _actionResponse('家账还没登录', '打开家账登录后再试', const ['confirm', 'edit', 'undo']);
      }
      final CaptureActionResult result;
      switch (action) {
        case 'confirm':
          result = await pipeline.confirm(captureId);
        case 'undo':
          result = await pipeline.undo(captureId);
        case 'reply':
          if (text.trim().isEmpty) {
            return _actionResponse('没有收到修改内容', '回复基金名、类别名、金额或备注', const ['confirm', 'edit', 'undo']);
          }
          result = await pipeline.applyQuickReply(captureId, text.trim());
        default:
          return _actionResponse('未知动作', action, const <String>[]);
      }
      final after = await _store.loadCapture(captureId);
      final decision = after?.decision;
      final actions = after == null ? const <String>[] : actionsFor(decision, afterAction: true);
      await _store.updateLog(
        captureId,
        (e) => e.copyWith(
          title: result.title,
          body: result.body,
          decision: action == 'undo' ? 'undone' : (decision?.name ?? e.decision),
          transactionId: after?.transactionId,
        ),
      );
      return _actionResponse(result.title, result.body, actions, transactionId: after?.transactionId);
    } catch (e, st) {
      debugPrint('handleAction failed: $e\n$st');
      return _actionResponse('操作失败', _short(e), const ['confirm', 'edit', 'undo']);
    }
  }

  /// `onModelSync`：拉共享模型（版本更新才替换本地），顺便补传没送出去的捕获。
  Future<Map<String, dynamic>> syncModel() async {
    try {
      final assembly = await _ensureAssembly();
      if (assembly == null) return {'ok': false, 'reason': 'no_session'};
      final api = HttpCaptureApi(assembly.client);
      final remote = await api.fetchModel();
      final remoteVersion = (remote['version'] as num?)?.toInt() ?? 0;
      final localCategory = await _store.loadModel(kCategoryModelKey);
      final localVersion = (localCategory?['version'] as num?)?.toInt() ?? -1;
      var updated = false;
      if (remoteVersion > localVersion) {
        for (final key in const [kCategoryModelKey, kFundModelKey]) {
          final model = remote[key];
          if (model is! Map) continue;
          final json = Map<String, dynamic>.from(model);
          // 服务端的类别模型还没训出来（种子对不上这家的类别名）就别拿空模型盖掉本地种子，
          // 本地版本号也不动 —— 下次再比。
          if (key == kCategoryModelKey && ((json['totalDocs'] as num?)?.toInt() ?? 0) == 0) continue;
          final local = key == kCategoryModelKey ? localCategory : await _store.loadModel(key);
          // 内容没变（只是别的模型动了版本）就不重写，也不算「更新了」。
          if (local != null && _sameModel(local, json)) continue;
          json['version'] = remoteVersion;
          await _store.saveModel(key, json);
          updated = true;
        }
        if (updated) {
          _modelStamp++;
          _assembly?.pipeline = null;
        }
      }
      final replayed = await replayPending();
      return {'ok': true, 'version': remoteVersion, 'updated': updated, 'replayed': replayed};
    } catch (e) {
      debugPrint('syncModel failed: $e');
      return {'ok': false, 'reason': _short(e)};
    }
  }

  /// 仅调试：`onE2eLogin({baseUrl, username, password})` —— 用和登录页同一套
  /// [SessionRepo] 落会话，adb 端到端脚本不必在屏幕上打字。
  Future<Map<String, dynamic>> e2eLogin(Object? args) async {
    if (!kDebugMode) return {'ok': false, 'reason': 'release build'};
    final map = args is Map ? args : const <dynamic, dynamic>{};
    try {
      final repo = SessionRepo(secure: _secure, httpClient: _httpClient);
      await repo.connect('${map['baseUrl'] ?? ''}');
      final session = await repo.login('${map['username'] ?? ''}', '${map['password'] ?? ''}');
      _reset();
      return {'ok': true, 'member': session.me.username, 'baseUrl': session.baseUrl};
    } catch (e) {
      return {'ok': false, 'reason': _short(e)};
    }
  }

  /// 网络回来了（某次接口调用成功）：下一轮事件循环里重放一次积压队列。
  void _scheduleReplay() {
    if (!autoReplay || _replaying) return;
    unawaited(Future<void>(() async {
      await replayPending();
    }));
  }

  /// 重放所有离线积压：
  ///
  /// 1. 建流水没送到的记录 → 用最新草稿 + clientId 幂等重发（[retryPending]）；
  /// 2. `ops.json` 里的 patch / confirm / delete → 按入队顺序逐条推；
  /// 3. `learn_queue.json` → 分批 `POST /model/learn`。
  ///
  /// 策略与管线一致：4xx（429 除外）是定论 —— 丢掉这条、给记录记 `syncError`；
  /// 断网 / 5xx / 429 是临时故障 —— 停在这条，下次再来。同一时刻只跑一份。
  Future<Map<String, dynamic>> replayPending() async {
    if (_replaying) return {'ok': false, 'reason': 'busy'};
    _replaying = true;
    try {
      final assembly = await _ensureAssembly();
      if (assembly == null) return {'ok': false, 'reason': 'no_session'};
      final api = HttpCaptureApi(assembly.client);

      final created = await retryPending();

      var opsDone = 0;
      var opsDropped = 0;
      var stopped = false;
      for (final op in await _store.pendingOps()) {
        try {
          await QueuedCaptureApi.sendQueuedOp(api, op);
          await _store.removeOp(op.id);
          opsDone++;
          await _markSynced(op);
        } on UnsupportedError {
          // 不认识的类型：老版本留下的，丢掉就好，别把记录标成已同步
          debugPrint('replayPending: dropping unknown op type ${op.type}');
          await _store.removeOp(op.id);
          opsDropped++;
        } on CaptureApiException catch (e) {
          if (!e.isClientError) {
            stopped = true;
            break;
          }
          // 定论：这条不会再成功。删除撞上 404 说明早就删掉了，算成功。
          await _store.removeOp(op.id);
          opsDropped++;
          if (op.type == 'delete' && e.status == 404) {
            await _markSynced(op);
          } else {
            await _markSyncError(op, e.message);
          }
        } catch (_) {
          stopped = true;
          break;
        }
      }

      var learned = 0;
      var learnDropped = 0;
      if (!stopped) {
        final r = await _replayLearn(api);
        learned = r.$1;
        learnDropped = r.$2;
        stopped = r.$3;
      }
      return {
        'ok': true,
        'created': created,
        'ops': opsDone,
        'opsDropped': opsDropped,
        'learned': learned,
        'learnDropped': learnDropped,
        'stopped': stopped,
      };
    } catch (e) {
      debugPrint('replayPending failed: $e');
      return {'ok': false, 'reason': _short(e)};
    } finally {
      _replaying = false;
    }
  }

  /// 学习样本分批补发。每发成功一批（或一条）就立刻按 id 出队，临时故障中断后再来
  /// 不会重发已经学过的；一批里有一条坏样本服务端会整批 400，这时逐条重发，只丢坏的那条。
  /// 返回 (补发条数, 丢弃条数, 是否因临时故障停下)。
  Future<(int, int, bool)> _replayLearn(HttpCaptureApi api) async {
    var learned = 0;
    var dropped = 0;
    while (true) {
      final queue = await _store.pendingLearn();
      if (queue.isEmpty) break;
      final batch = queue.take(learnBatchSize).toList();
      try {
        await api.learnJson(batch.map((e) => e.sample).toList());
        await _store.removeLearn(batch.map((e) => e.id));
        learned += batch.length;
      } on CaptureApiException catch (e) {
        if (!e.isClientError) return (learned, dropped, true);
        if (batch.length == 1) {
          await _store.removeLearn([batch.single.id]);
          dropped++;
          continue;
        }
        for (final entry in batch) {
          try {
            await api.learnJson([entry.sample]);
            await _store.removeLearn([entry.id]);
            learned++;
          } on CaptureApiException catch (e2) {
            if (!e2.isClientError) return (learned, dropped, true);
            await _store.removeLearn([entry.id]);
            dropped++;
          } catch (_) {
            return (learned, dropped, true);
          }
        }
      } catch (_) {
        return (learned, dropped, true);
      }
      // 保险：这一批的 id 按理都已出队；底账被并发改写导致没删掉时，交给下一次重放，别原地打转。
      final left = (await _store.pendingLearn()).map((e) => e.id).toSet();
      if (batch.any((e) => left.contains(e.id))) return (learned, dropped, true);
    }
    return (learned, dropped, false);
  }

  Future<CaptureRecord?> _recordOf(CaptureOp op) async {
    final captureId = op.captureId.isNotEmpty
        ? op.captureId
        : await _store.captureIdForTransaction(op.transactionId);
    return captureId == null ? null : _store.loadCapture(captureId);
  }

  /// 这条记录的动作都推完了才算同步。
  Future<void> _markSynced(CaptureOp op) async {
    final record = await _recordOf(op);
    if (record == null) return;
    final remaining = await _store.pendingOps();
    if (remaining.any((o) => o.transactionId == op.transactionId)) return;
    await _store.saveCapture(record.copyWith(synced: true, clearSyncError: true));
  }

  Future<void> _markSyncError(CaptureOp op, String message) async {
    final record = await _recordOf(op);
    if (record == null) return;
    await _store.saveCapture(record.copyWith(synced: false, syncError: message));
  }

  /// 把「建流水时没送到」的记录重发一遍（clientId 幂等）。返回补上的条数。
  Future<int> retryPending() async {
    final client = _assembly?.client;
    if (client == null) return 0;
    final api = HttpCaptureApi(client);
    var n = 0;
    for (final record in await _store.pendingUploads()) {
      try {
        final res = await api.createTransaction(record.draft.toJson());
        await _store.saveCapture(
          record.copyWith(
            transactionId: res.id,
            synced: true,
            clearSyncError: true,
            decision: res.duplicate ? CaptureDecision.duplicate : null,
          ),
        );
        await _store.updateLog(record.captureId, (e) => e.copyWith(transactionId: res.id));
        n++;
      } on CaptureApiException catch (e) {
        if (e.isClientError) {
          await _store.saveCapture(record.copyWith(syncError: e.message));
        } else {
          break; // 服务端暂时不行，下次再来
        }
      } catch (_) {
        break; // 断网
      }
    }
    return n;
  }

  // ------------------------------------------------------------ 装配

  /// 取装配好的一套；没登录返回 null。并发调用共用同一个在途 Future。
  Future<_Assembly?> _ensureAssembly() {
    final inFlight = _assembling;
    if (inFlight != null) return inFlight;
    final future = _assemble();
    _assembling = future;
    return future.whenComplete(() {
      if (identical(_assembling, future)) _assembling = null;
    });
  }

  Future<_Assembly?> _assemble() async {
    final session = await SessionRepo(secure: _secure, httpClient: _httpClient).restore();
    if (session == null) {
      _reset();
      return null;
    }
    final current = _assembly;
    if (current != null &&
        current.session.token == session.token &&
        current.session.baseUrl == session.baseUrl) {
      current.session = session; // 成员资料可能变了，令牌没变就不用重建
      return current;
    }

    // 全部就位再发布；中途任何一步失败都不留半成品。
    final client = ApiClient(
      baseUrl: session.baseUrl,
      token: session.token,
      inner: _httpClient,
      timeout: apiTimeout,
    );
    LedgerRepo? ledger;
    try {
      final overlay = _OverlayLocalStore(_cache);
      ledger = LedgerRepo(api: client, store: overlay);
      await ledger.load();
      final settingsRepo = SettingsRepo(api: client, store: overlay);
      final settings = await settingsRepo.cached() ?? const Settings();
      final next = _Assembly(
        session: session,
        client: client,
        ledger: ledger,
        settingsRepo: settingsRepo,
        settings: settings,
      );
      _reset();
      _assembly = next;
      return next;
    } catch (_) {
      ledger?.dispose();
      if (_httpClient == null) client.close();
      _reset();
      rethrow;
    }
  }

  /// 取可用的管线；并发调用共用同一个在途 Future（主数据同步、种子训练都只做一遍）。
  Future<CapturePipeline?> _ensurePipeline() {
    final inFlight = _preparing;
    if (inFlight != null) return inFlight;
    final future = _preparePipeline();
    _preparing = future;
    return future.whenComplete(() {
      if (identical(_preparing, future)) _preparing = null;
    });
  }

  Future<CapturePipeline?> _preparePipeline() async {
    final a = await _ensureAssembly();
    if (a == null) return null;

    final now = _now();
    final stale = a.lastSync == null || now.difference(a.lastSync!) > syncInterval;
    if (stale || a.ledger.snapshot.isEmpty) {
      try {
        await a.ledger.sync();
        a.lastSync = now;
      } catch (_) {
        // 离线：用缓存
      }
      try {
        a.settings = await a.settingsRepo.fetch();
      } catch (_) {
        a.settings = await a.settingsRepo.cached() ?? a.settings;
      }
    }

    final snapshot = a.ledger.snapshot;
    final fingerprint = [
      a.session.token.hashCode,
      a.session.me.id,
      snapshot.seq,
      jsonEncode(a.settings.capture.toJson()),
      _modelStamp,
    ].join('|');
    if (a.pipeline == null || fingerprint != a.fingerprint) {
      a.pipeline = await buildPipeline(
        store: _store,
        api: QueuedCaptureApi(
          HttpCaptureApi(
            a.client,
            aiEnabled: a.settings.capture.aiTrigger != 'off',
            providerId: a.settings.capture.aiProviderId,
          ),
          _store,
          onSuccess: _scheduleReplay,
          now: _now,
        ),
        ledger: snapshot,
        settings: a.settings.capture,
        memberId: a.session.me.id,
        now: _now,
      );
      a.fingerprint = fingerprint;
    }
    return a.pipeline;
  }

  void _reset() {
    final old = _assembly;
    _assembly = null;
    if (old == null) return;
    old.ledger.dispose();
    if (_httpClient == null) old.client.close();
  }

  /// 两份模型内容是否一样（版本号不算）。
  static bool _sameModel(Map<String, dynamic> a, Map<String, dynamic> b) =>
      a['totalDocs'] == b['totalDocs'] &&
      a['vocab'] == b['vocab'] &&
      jsonEncode(a['classes'] ?? const {}) == jsonEncode(b['classes'] ?? const {});

  Future<void> _log(String package, String title, String body, String decision) =>
      _store.appendLog(
        CaptureLogEntry(at: _now(), package: package, title: title, body: body, decision: decision),
      );

  static Map<String, dynamic> _actionResponse(
    String title,
    String body,
    List<String> actions, {
    String? transactionId,
  }) => {
    'title': title,
    'body': body,
    'actions': actions,
    if (transactionId != null) 'transactionId': transactionId,
  };

  static String _short(Object e) {
    final s = e is CaptureNetworkException
        ? e.message
        : e is CaptureApiException
        ? e.message
        : e is ApiException
        ? e.message
        : '$e';
    return s.length > 120 ? '${s.substring(0, 120)}…' : s;
  }
}

/// 一次登录对应的一整套运行时对象。字段可变，但整个对象只在全部就位后才挂到运行时上。
class _Assembly {
  _Assembly({
    required this.session,
    required this.client,
    required this.ledger,
    required this.settingsRepo,
    required this.settings,
  });

  Session session;
  final ApiClient client;
  final LedgerRepo ledger;
  final SettingsRepo settingsRepo;
  Settings settings;
  DateTime? lastSync;
  CapturePipeline? pipeline;
  String? fingerprint;
}

/// 读走主引擎写好的缓存文件，写只落在内存：headless 与主引擎各写同一份 JSON
/// 会互相覆盖，后台这边索性不写盘。
class _OverlayLocalStore implements LocalStore {
  _OverlayLocalStore(this._base);

  final LocalStore _base;
  final Map<String, String> _memory = {};

  @override
  Future<T?> read<T>(String key) async {
    final raw = _memory[key];
    if (raw != null) {
      final value = jsonDecode(raw);
      return value is T ? value : null;
    }
    return _base.read<T>(key);
  }

  @override
  Future<void> write(String key, Object json) async {
    _memory[key] = jsonEncode(json);
  }

  @override
  Future<void> remove(String key) async => _memory.remove(key);

  @override
  Future<void> clear() async => _memory.clear();
}
