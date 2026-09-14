import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../capture/capture_types.dart';
import '../capture/pipeline.dart';

/// 「最近捕获」日志的一条（设置页展示用，与 [CaptureRecord] 分开存：
/// 忽略/重复的通知没有记录，但也该让用户看见「我看到了，没记」）。
class CaptureLogEntry {
  const CaptureLogEntry({
    required this.at,
    required this.package,
    required this.title,
    required this.body,
    required this.decision,
    this.captureId,
    this.transactionId,
    this.amountCents,
    this.type,
  });

  final DateTime at;
  final String package;
  final String title;
  final String body;

  /// recorded | pending | duplicate | ignored | error | undone
  final String decision;
  final String? captureId;
  final String? transactionId;
  final int? amountCents;

  /// expense | income
  final String? type;

  CaptureLogEntry copyWith({
    String? title,
    String? body,
    String? decision,
    String? transactionId,
    bool clearTransactionId = false,
  }) => CaptureLogEntry(
    at: at,
    package: package,
    title: title ?? this.title,
    body: body ?? this.body,
    decision: decision ?? this.decision,
    captureId: captureId,
    transactionId: clearTransactionId ? null : (transactionId ?? this.transactionId),
    amountCents: amountCents,
    type: type,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'at': isoLocal(at),
    'package': package,
    'title': title,
    'body': body,
    'decision': decision,
    if (captureId != null) 'captureId': captureId,
    if (transactionId != null) 'transactionId': transactionId,
    if (amountCents != null) 'amountCents': amountCents,
    if (type != null) 'type': type,
  };

  factory CaptureLogEntry.fromJson(Map<String, dynamic> json) => CaptureLogEntry(
    at: DateTime.tryParse('${json['at']}')?.toLocal() ?? DateTime.fromMillisecondsSinceEpoch(0),
    package: '${json['package'] ?? ''}',
    title: '${json['title'] ?? ''}',
    body: '${json['body'] ?? ''}',
    decision: '${json['decision'] ?? 'ignored'}',
    captureId: json['captureId'] as String?,
    transactionId: json['transactionId'] as String?,
    amountCents: (json['amountCents'] as num?)?.toInt(),
    type: json['type'] as String?,
  );
}

/// 离线时没推出去的一次通知动作（patch / confirm / delete），按入队顺序重放。
///
/// 建流水不在这里：建流水靠记录本身的草稿 + clientId 幂等重发（[LocalCaptureStore.pendingUploads]）。
class CaptureOp {
  const CaptureOp({
    required this.id,
    required this.at,
    required this.type,
    required this.captureId,
    required this.transactionId,
    this.payload,
  });

  final String id;
  final DateTime at;

  /// patch | confirm | delete
  final String type;

  /// 入队时可能还查不到（撤销会先删记录再推删除），重放时再按流水 id 反查一次。
  final String captureId;
  final String transactionId;

  /// patch 的请求体。
  final Map<String, dynamic>? payload;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'at': isoLocal(at),
    'type': type,
    'captureId': captureId,
    'transactionId': transactionId,
    if (payload != null) 'payload': payload,
  };

  factory CaptureOp.fromJson(Map<String, dynamic> json) => CaptureOp(
    id: '${json['id'] ?? ''}',
    at: DateTime.tryParse('${json['at']}')?.toLocal() ?? DateTime.fromMillisecondsSinceEpoch(0),
    type: '${json['type'] ?? ''}',
    captureId: '${json['captureId'] ?? ''}',
    transactionId: '${json['transactionId'] ?? ''}',
    payload: (json['payload'] as Map?)?.cast<String, dynamic>(),
  );
}

/// 学习队列里的一条：带 id，重放成功后按 id 删，重放期间新入队的不会被整体快照覆盖掉。
class QueuedLearnSample {
  const QueuedLearnSample({required this.id, required this.sample});

  final String id;

  /// `LearnSample.toJson()` 的形状（服务端直接吃）。
  final Map<String, dynamic> sample;

  /// 去掉标签后的特征键：同一条捕获再次纠正会产生同键样本，新的取代旧的。
  String get featureKey => featureKeyOf(sample);

  static String featureKeyOf(Map<String, dynamic> sample) {
    final keys = sample.keys.where((k) => k != 'categoryId' && k != 'fundId').toList()..sort();
    return jsonEncode({for (final k in keys) k: sample[k]});
  }

  Map<String, dynamic> toJson() => {'id': id, 'sample': sample};

  static QueuedLearnSample? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final sample = json['sample'];
    if (id is! String || id.isEmpty || sample is! Map) return null;
    return QueuedLearnSample(id: id, sample: sample.cast<String, dynamic>());
  }
}

/// 管线的 [CaptureStore] 再加上设置页与重试要用的几样：最近捕获日志、待补传记录、
/// 离线动作队列、待补发的学习样本。
abstract class LocalCaptureStore implements CaptureStore {
  /// 队列上限：动作 500 条、学习样本 200 条，超了丢最老的。
  static const int maxOps = 500;
  static const int maxLearnQueue = 200;

  /// 按流水 id 反查捕获记录（撤销的墓碑也算）。
  Future<String?> captureIdForTransaction(String transactionId);

  /// 离线动作队列（入队顺序）。
  Future<List<CaptureOp>> pendingOps();
  Future<void> enqueueOp(CaptureOp op);
  Future<void> removeOp(String id);

  /// 没送到服务端的 `POST /model/learn` 样本（入队顺序）。
  Future<List<QueuedLearnSample>> pendingLearn();

  /// 入队（自动分配 id），返回分配到的 id。
  Future<List<String>> enqueueLearn(List<Map<String, dynamic>> samples);

  /// 按 id 删（发成功的、被新样本取代的）。
  Future<void> removeLearn(Iterable<String> ids);

  /// 建流水时没送到服务端、也没被明确拒绝的记录（clientId 幂等，可以放心重发）。
  Future<List<CaptureRecord>> pendingUploads();

  /// 最近捕获，新的在前，≤ [FileCaptureStore.maxRecent] 条。
  Future<List<CaptureLogEntry>> recent();
  Future<void> appendLog(CaptureLogEntry entry);

  /// 通知动作之后把对应那条日志改一下（已确认 / 已撤销 / 已更新）。
  Future<void> updateLog(String captureId, CaptureLogEntry Function(CaptureLogEntry entry) change);
  Future<void> clearRecent();
}

/// 全在内存里：测试、设置页的「测试解析」（不落盘）用。
class MemoryCaptureStore implements LocalCaptureStore {
  final Map<String, DateTime> seen = {};
  final Map<String, CaptureRecord> captures = {};
  final Map<String, Map<String, dynamic>> models = {};
  final List<CaptureLogEntry> log = [];

  @override
  Future<DateTime?> lastSeen(String hash) async => seen[hash];

  @override
  Future<void> markSeen(String hash, DateTime at) async => seen[hash] = at;

  @override
  Future<void> saveCapture(CaptureRecord record) async => captures[record.captureId] = record;

  @override
  Future<CaptureRecord?> loadCapture(String captureId) async => captures[captureId];

  @override
  Future<void> deleteCapture(String captureId) async => captures.remove(captureId);

  @override
  Future<Map<String, dynamic>?> loadModel(String key) async => models[key];

  @override
  Future<void> saveModel(String key, Map<String, dynamic> json) async => models[key] = json;

  @override
  Future<List<CaptureRecord>> pendingUploads() async => captures.values
      .where((r) => r.needsRetry && r.transactionId == null && r.decision != CaptureDecision.ignored)
      .toList()
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  @override
  Future<List<CaptureLogEntry>> recent() async => List.unmodifiable(log);

  @override
  Future<void> appendLog(CaptureLogEntry entry) async {
    log.insert(0, entry);
    if (log.length > FileCaptureStore.maxRecent) log.removeRange(FileCaptureStore.maxRecent, log.length);
  }

  @override
  Future<void> updateLog(String captureId, CaptureLogEntry Function(CaptureLogEntry entry) change) async {
    for (var i = 0; i < log.length; i++) {
      if (log[i].captureId == captureId) log[i] = change(log[i]);
    }
  }

  @override
  Future<void> clearRecent() async => log.clear();

  final List<CaptureOp> ops = [];
  final List<QueuedLearnSample> learnQueue = [];
  int _learnSeq = 0;

  @override
  Future<String?> captureIdForTransaction(String transactionId) async {
    for (final r in captures.values) {
      if (r.transactionId == transactionId) return r.captureId;
    }
    return null;
  }

  @override
  Future<List<CaptureOp>> pendingOps() async => List.unmodifiable(ops);

  @override
  Future<void> enqueueOp(CaptureOp op) async {
    ops.add(op);
    if (ops.length > LocalCaptureStore.maxOps) ops.removeRange(0, ops.length - LocalCaptureStore.maxOps);
  }

  @override
  Future<void> removeOp(String id) async => ops.removeWhere((o) => o.id == id);

  @override
  Future<List<QueuedLearnSample>> pendingLearn() async => List.unmodifiable(learnQueue);

  @override
  Future<List<String>> enqueueLearn(List<Map<String, dynamic>> samples) async {
    final ids = <String>[];
    for (final sample in samples) {
      final id = 'learn-${++_learnSeq}';
      ids.add(id);
      learnQueue.add(QueuedLearnSample(id: id, sample: sample));
    }
    if (learnQueue.length > LocalCaptureStore.maxLearnQueue) {
      learnQueue.removeRange(0, learnQueue.length - LocalCaptureStore.maxLearnQueue);
    }
    return ids;
  }

  @override
  Future<void> removeLearn(Iterable<String> ids) async {
    final gone = ids.toSet();
    learnQueue.removeWhere((e) => gone.contains(e.id));
  }
}

/// [CaptureStore] 的文件实现：`<应用支持目录>/capture/` 下几个 JSON 文件。
///
/// - `seen.json`      去重哈希 → 最后一次见到的毫秒时间（超过一天的自动清掉）
/// - `captures.json`  captureId → [CaptureRecord]（最多 [maxCaptures] 条，按时间淘汰）
/// - `model_<key>.json` 朴素贝叶斯模型（category / fund）
/// - `recent.json`    最近捕获日志，最多 [maxRecent] 条
/// - `ops.json`       离线没推出去的 patch / confirm / delete，按序重放（≤ 500）
/// - `learn_queue.json` 没送到的 `/model/learn` 样本（≤ 200）
///
/// 主引擎与 headless 引擎会同时打开同一目录：写入一律「临时文件 + rename」，
/// 同一实例内的读改写用一条串行链排队。
class FileCaptureStore implements LocalCaptureStore {
  FileCaptureStore(this.dir);

  final Directory dir;

  static const int maxRecent = 50;
  static const int maxCaptures = 300;

  /// 忽略类日志最多留这么多条，别让微信聊天把真正的记账挤出列表。
  static const int maxIgnoredInRecent = 10;
  static const Duration seenTtl = Duration(hours: 24);

  Future<void> _chain = Future<void>.value();

  /// 打开默认目录（Android：`/data/user/0/<包名>/files/capture`）。
  static Future<FileCaptureStore> open() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/capture');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return FileCaptureStore(dir);
  }

  File get _seenFile => File('${dir.path}/seen.json');
  File get _capturesFile => File('${dir.path}/captures.json');
  File get _recentFile => File('${dir.path}/recent.json');
  File get _opsFile => File('${dir.path}/ops.json');
  File get _learnFile => File('${dir.path}/learn_queue.json');
  File _modelFile(String key) =>
      File('${dir.path}/model_${key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.json');

  // ------------------------------------------------------------ CaptureStore

  @override
  Future<DateTime?> lastSeen(String hash) => _locked(() async {
    final ms = (await _readMap(_seenFile))[hash];
    return ms is num ? DateTime.fromMillisecondsSinceEpoch(ms.toInt()) : null;
  });

  @override
  Future<void> markSeen(String hash, DateTime at) => _locked(() async {
    final seen = await _readMap(_seenFile);
    final cutoff = DateTime.now().subtract(seenTtl).millisecondsSinceEpoch;
    seen.removeWhere((_, v) => v is! num || v.toInt() < cutoff);
    seen[hash] = at.millisecondsSinceEpoch;
    await _write(_seenFile, seen);
  });

  @override
  Future<void> saveCapture(CaptureRecord record) => _locked(() async {
    final all = await _readMap(_capturesFile);
    all[record.captureId] = record.toJson();
    if (all.length > maxCaptures) {
      final ids = all.keys.toList()
        ..sort((a, b) => _createdAt(all[a]).compareTo(_createdAt(all[b])));
      for (final id in ids.take(all.length - maxCaptures)) {
        all.remove(id);
      }
    }
    await _write(_capturesFile, all);
  });

  @override
  Future<CaptureRecord?> loadCapture(String captureId) => _locked(() async {
    final raw = (await _readMap(_capturesFile))[captureId];
    if (raw is! Map) return null;
    try {
      return CaptureRecord.fromJson(raw.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  });

  @override
  Future<void> deleteCapture(String captureId) => _locked(() async {
    final all = await _readMap(_capturesFile);
    if (all.remove(captureId) != null) await _write(_capturesFile, all);
  });

  @override
  Future<Map<String, dynamic>?> loadModel(String key) => _locked(() async {
    final file = _modelFile(key);
    if (!file.existsSync()) return null;
    final map = await _readMap(file);
    return map.isEmpty ? null : map;
  });

  @override
  Future<void> saveModel(String key, Map<String, dynamic> json) =>
      _locked(() => _write(_modelFile(key), json));

  // ------------------------------------------------------------ 额外

  @override
  Future<List<CaptureRecord>> pendingUploads() => _locked(() async {
    final all = await _readMap(_capturesFile);
    final out = <CaptureRecord>[];
    for (final raw in all.values) {
      if (raw is! Map) continue;
      try {
        final record = CaptureRecord.fromJson(raw.cast<String, dynamic>());
        if (record.needsRetry &&
            record.transactionId == null &&
            record.decision != CaptureDecision.ignored) {
          out.add(record);
        }
      } catch (_) {
        // 坏掉的一条不影响别的
      }
    }
    out.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return out;
  });

  @override
  Future<List<CaptureLogEntry>> recent() => _locked(() async {
    final list = await _readList(_recentFile);
    return list
        .whereType<Map>()
        .map((e) => CaptureLogEntry.fromJson(e.cast<String, dynamic>()))
        .toList();
  });

  @override
  Future<void> appendLog(CaptureLogEntry entry) => _locked(() async {
    final list = <Map<String, dynamic>>[
      entry.toJson(),
      ...(await _readList(_recentFile)).whereType<Map>().map((e) => e.cast<String, dynamic>()),
    ];
    var ignored = 0;
    list.removeWhere((e) {
      if (e['decision'] != 'ignored') return false;
      return ++ignored > maxIgnoredInRecent;
    });
    await _write(_recentFile, list.take(maxRecent).toList());
  });

  @override
  Future<void> updateLog(
    String captureId,
    CaptureLogEntry Function(CaptureLogEntry entry) change,
  ) => _locked(() async {
    final list = (await _readList(_recentFile))
        .whereType<Map>()
        .map((e) => CaptureLogEntry.fromJson(e.cast<String, dynamic>()))
        .toList();
    var touched = false;
    for (var i = 0; i < list.length; i++) {
      if (list[i].captureId == captureId) {
        list[i] = change(list[i]);
        touched = true;
      }
    }
    if (touched) await _write(_recentFile, list.map((e) => e.toJson()).toList());
  });

  @override
  Future<void> clearRecent() => _locked(() => _write(_recentFile, const <Object>[]));

  // ------------------------------------------------------------ 离线队列

  @override
  Future<String?> captureIdForTransaction(String transactionId) => _locked(() async {
    for (final raw in (await _readMap(_capturesFile)).values) {
      if (raw is Map && raw['transactionId'] == transactionId) return raw['captureId']?.toString();
    }
    return null;
  });

  @override
  Future<List<CaptureOp>> pendingOps() => _locked(() async => _ops(await _readList(_opsFile)));

  @override
  Future<void> enqueueOp(CaptureOp op) => _locked(() async {
    final list = <Map<String, dynamic>>[
      ...(await _readList(_opsFile)).whereType<Map>().map((e) => e.cast<String, dynamic>()),
      op.toJson(),
    ];
    final trimmed = list.length > LocalCaptureStore.maxOps
        ? list.sublist(list.length - LocalCaptureStore.maxOps)
        : list;
    await _write(_opsFile, trimmed);
  });

  @override
  Future<void> removeOp(String id) => _locked(() async {
    final list = (await _readList(_opsFile)).whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    final before = list.length;
    list.removeWhere((e) => e['id'] == id);
    if (list.length != before) await _write(_opsFile, list);
  });

  @override
  Future<List<QueuedLearnSample>> pendingLearn() =>
      _locked(() async => _learnEntries(await _readList(_learnFile)));

  @override
  Future<List<String>> enqueueLearn(List<Map<String, dynamic>> samples) => _locked(() async {
    if (samples.isEmpty) return const <String>[];
    final list = _learnEntries(await _readList(_learnFile));
    final ids = <String>[];
    var seq = 0;
    final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    for (final sample in samples) {
      final id = 'learn-$stamp-${seq++}';
      ids.add(id);
      list.add(QueuedLearnSample(id: id, sample: sample));
    }
    final trimmed = list.length > LocalCaptureStore.maxLearnQueue
        ? list.sublist(list.length - LocalCaptureStore.maxLearnQueue)
        : list;
    await _write(_learnFile, trimmed.map((e) => e.toJson()).toList());
    return ids;
  });

  @override
  Future<void> removeLearn(Iterable<String> ids) => _locked(() async {
    final gone = ids.toSet();
    if (gone.isEmpty) return;
    final list = _learnEntries(await _readList(_learnFile));
    final before = list.length;
    list.removeWhere((e) => gone.contains(e.id));
    if (list.length != before) await _write(_learnFile, list.map((e) => e.toJson()).toList());
  });

  static List<QueuedLearnSample> _learnEntries(List<dynamic> raw) {
    final out = <QueuedLearnSample>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final entry = QueuedLearnSample.fromJson(e.cast<String, dynamic>());
      if (entry != null) out.add(entry);
    }
    return out;
  }

  static List<CaptureOp> _ops(List<dynamic> raw) {
    final out = <CaptureOp>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final op = CaptureOp.fromJson(e.cast<String, dynamic>());
      if (op.id.isNotEmpty && op.transactionId.isNotEmpty) out.add(op);
    }
    return out;
  }

  // ------------------------------------------------------------ 文件

  Future<T> _locked<T>(Future<T> Function() run) {
    final next = _chain.then((_) => run());
    _chain = next.then((_) {}, onError: (_) {});
    return next;
  }

  Future<Map<String, dynamic>> _readMap(File file) async {
    final value = await _readJson(file);
    return value is Map ? value.cast<String, dynamic>() : <String, dynamic>{};
  }

  Future<List<dynamic>> _readList(File file) async {
    final value = await _readJson(file);
    return value is List ? value : <dynamic>[];
  }

  Future<Object?> _readJson(File file) async {
    if (!file.existsSync()) return null;
    try {
      return jsonDecode(await file.readAsString());
    } catch (_) {
      return null; // 坏文件当作空，下一次写会覆盖掉
    }
  }

  Future<void> _write(File file, Object json) async {
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final tmp = File('${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
    await tmp.writeAsString(jsonEncode(json), flush: true);
    await tmp.rename(file.path);
  }

  static DateTime _createdAt(Object? raw) {
    if (raw is Map) {
      final parsed = DateTime.tryParse('${raw['createdAt']}');
      if (parsed != null) return parsed;
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }
}
