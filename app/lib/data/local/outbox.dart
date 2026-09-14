import 'dart:async';

import '../models/json_utils.dart';
import 'local_store.dart';

/// 离线待发队列里的一条。[clientId] 同时是幂等键：
/// 新建流水用它的 clientId，改/删/确认用服务端 id。
class OutboxItem {
  const OutboxItem({
    required this.clientId,
    required this.op,
    required this.payload,
    required this.queuedAt,
    this.attempted = false,
    this.pendingPatch = const {},
  });

  static const String opCreate = 'create';
  static const String opPatch = 'patch';
  static const String opDelete = 'delete';
  static const String opConfirm = 'confirm';
  static const String opLearn = 'learn';

  final String clientId;

  /// create | patch | delete | confirm | learn
  final String op;
  final Map<String, dynamic> payload;
  final DateTime queuedAt;

  /// 已经真的往服务端发过一次（可能发出去了但没收到回应）。
  ///
  /// 两个用处：
  /// - 「离线新建后又删掉」能不能就地丢弃：没发过 = 服务端根本不知道这笔，
  ///   直接扔；发过 = 可能已经落库了，得补一次删除，别留孤儿。
  /// - 发过之后 [payload] 就**冻结**了（那一份可能已经到了服务端，或者正在
  ///   路上），后来的字段改动一律记到 [pendingPatch]；补发完拿它跟发出去时的
  ///   快照一比，就知道在途中有没有新改动要留下来。
  final bool attempted;

  /// 发过一次之后又改了的字段（create 和 patch 都适用）。
  ///
  /// create 重放会被服务端按 clientId 判成 `exists` 并原样返回旧行，合并进
  /// payload 等于白改 —— 所以单独存着，拿到服务端 id 再补一个 PATCH。
  /// patch 补发时则把它和 payload 合成一个请求体一起发。
  final Map<String, dynamic> pendingPatch;

  OutboxItem copyWith({
    String? op,
    Map<String, dynamic>? payload,
    bool? attempted,
    Map<String, dynamic>? pendingPatch,
  }) => OutboxItem(
    clientId: clientId,
    op: op ?? this.op,
    payload: payload ?? this.payload,
    queuedAt: queuedAt,
    attempted: attempted ?? this.attempted,
    pendingPatch: pendingPatch ?? this.pendingPatch,
  );

  factory OutboxItem.fromJson(Map<String, dynamic> json) => OutboxItem(
    clientId: jsonString(json['clientId']),
    op: jsonString(json['op'], opCreate),
    payload: jsonMap(json['payload']),
    queuedAt: jsonDate(json['queuedAt']),
    attempted: jsonBool(json['attempted']),
    pendingPatch: jsonMap(json['pendingPatch']),
  );

  Map<String, dynamic> toJson() => {
    'clientId': clientId,
    'op': op,
    'payload': payload,
    'queuedAt': queuedAt.toIso8601String(),
    if (attempted) 'attempted': true,
    if (pendingPatch.isNotEmpty) 'pendingPatch': pendingPatch,
  };
}

/// 断网时记的账先进这里，联网后 `TransactionsRepo.flushOutbox()` 统一补发。
///
/// 同一个 [OutboxItem.clientId] 在队列里最多一条，再来一条时这么合：
/// - 同 op = 覆盖（重试/改主意）；
/// - create / patch 之后又 patch = 字段合并：还没发出去过的直接并进 payload；
///   发出去过的 payload 冻结、新字段记进 `pendingPatch`（create 重放只会拿回
///   `exists`；正在路上的 patch 用的是发出去那一刻的快照，合进 payload 也
///   不会被这次请求带走）；
/// - patch 与 confirm 互相叠加 = 合成一条带 `status: confirmed` 的 patch
///   （服务端 PATCH 认 status），改动和确认两件事都不丢；
/// - 还没发出去（`attempted == false`）的 create 又被 delete = 整条丢掉；
///   已经发出去过的，转成 delete 并带上原 create，补发时先幂等重建拿到
///   服务端 id 再删。
///
/// 所有「读—改—写」都排在同一条 Future 链上：flush 一边 markDone、用户一边
/// 记账，交叉执行不会把对方的写覆盖掉。
class Outbox {
  Outbox(this._store);

  static const String storeKey = 'outbox';

  final LocalStore _store;

  /// 串行锁：保证任何时刻只有一个读—改—写在跑。
  Future<void> _lock = Future<void>.value();

  Future<List<OutboxItem>> pending() => _locked(_read);

  Future<void> enqueue(OutboxItem item) => _locked(() async {
    final items = await _read();
    final index = items.indexWhere((e) => e.clientId == item.clientId);
    if (index < 0) {
      items.add(item);
    } else {
      final merged = _merge(items[index], item);
      if (merged == null) {
        items.removeAt(index);
      } else {
        items[index] = merged;
      }
    }
    await _save(items);
  });

  /// 同 clientId 已经有一条时怎么合；返回 null = 整条丢掉。
  static OutboxItem? _merge(OutboxItem existing, OutboxItem item) {
    // 「发过一次」是单向的：一旦为真就不能被后来的入队抹掉。
    final attempted = existing.attempted || item.attempted;
    final wasCreate = existing.op == OutboxItem.opCreate;
    final wasPatch = existing.op == OutboxItem.opPatch;

    if (wasCreate && item.op == OutboxItem.opDelete) {
      // 没发过：服务端根本不知道这笔，就地丢掉。
      if (!existing.attempted) return null;
      // 可能已经落到服务端了：补发时先重建再删。
      return existing.copyWith(
        op: OutboxItem.opDelete,
        payload: {...item.payload, 'create': existing.payload},
      );
    }
    if ((wasCreate || wasPatch) && item.op == OutboxItem.opPatch) {
      return _withFields(existing, _fields(item.payload), attempted: attempted);
    }
    if (wasPatch && item.op == OutboxItem.opConfirm) {
      // 先改再确认：服务端 PATCH 认 status，合成一条就够了。
      return _withFields(
        existing,
        const {'status': 'confirmed'},
        attempted: attempted,
      );
    }
    if (existing.op == OutboxItem.opConfirm && item.op == OutboxItem.opPatch) {
      // 先确认再改：同样合成一条 patch，「确认」这件事不能被后来的改动顶掉。
      return _withFields(
        existing.copyWith(op: OutboxItem.opPatch),
        {'status': 'confirmed', ..._fields(item.payload)},
        attempted: attempted,
      );
    }
    return item.copyWith(
      attempted: attempted,
      pendingPatch:
          item.pendingPatch.isEmpty ? existing.pendingPatch : item.pendingPatch,
    );
  }

  /// 往已有的一条里并字段。发过的行 payload 冻结（那一份可能已经到服务端了），
  /// 新字段记到 pendingPatch；没发过的直接并进 payload，一个请求就够。
  static OutboxItem _withFields(
    OutboxItem row,
    Map<String, dynamic> fields, {
    required bool attempted,
  }) => row.attempted
      ? row.copyWith(
          pendingPatch: {...row.pendingPatch, ...fields},
          attempted: attempted,
        )
      : row.copyWith(payload: {...row.payload, ...fields}, attempted: attempted);

  /// patch 体里除 id 之外的字段。
  static Map<String, dynamic> _fields(Map<String, dynamic> payload) =>
      Map<String, dynamic>.from(payload)..remove('id');

  /// 一条补发成功了（或者被服务端明确拒了、不会再发）。
  ///
  /// [sent] 给的是**发出去时的那份快照**（[markAttempted] 返回的那条）：如果在
  /// 途中这条又被人改过（补了字段、或者干脆被删了），就不能无脑删行，得把
  /// 「还没做完的那部分」留下来。[serverId] 是这次作用到的服务端 id，留下来的
  /// 那部分要用它当目标。不给 [sent] 就是老行为：无条件删掉。
  Future<void> markDone(String clientId, {OutboxItem? sent, String? serverId}) =>
      _locked(() async {
        final items = await _read();
        final index = items.indexWhere((e) => e.clientId == clientId);
        if (index < 0) return;
        final leftover = sent == null ? null : _leftover(items[index], sent, serverId);
        if (leftover == null) {
          items.removeAt(index);
        } else {
          items[index] = leftover;
        }
        await _save(items);
      });

  /// 在途中变过的部分；没变过返回 null（可以安心删掉这行）。
  static OutboxItem? _leftover(OutboxItem row, OutboxItem sent, String? serverId) {
    if (row.op != sent.op) {
      // 发出去之后又被删了：删除这件事还得做。
      if (row.op == OutboxItem.opDelete &&
          serverId != null &&
          serverId.isNotEmpty) {
        // 服务端 id 已经知道了，不用再幂等重建一次。
        return row.copyWith(
          payload: Map<String, dynamic>.from(row.payload)
            ..['id'] = serverId
            ..remove('create'),
        );
      }
      return row;
    }
    // 发出去之后又攒下的字段（pendingPatch 里比快照多出来、或者值变了的那部分）
    // 转成一条 patch 接着排队；已经随这次请求发出去的那部分不再重发。
    final extra = _newEntries(row.pendingPatch, since: sent.pendingPatch);
    if (extra.isEmpty) return null;
    return row.copyWith(
      op: OutboxItem.opPatch,
      payload: {'id': serverId ?? row.clientId, ...extra},
      pendingPatch: const {},
    );
  }

  /// [now] 里比 [since] 多出来、或者值变了的键。
  static Map<String, dynamic> _newEntries(
    Map<String, dynamic> now, {
    required Map<String, dynamic> since,
  }) => {
    for (final entry in now.entries)
      if (!since.containsKey(entry.key) ||
          '${since[entry.key]}' != '${entry.value}')
        entry.key: entry.value,
  };

  /// 发出去之前先记一笔「试过了」，并返回**此刻**队列里的这几条（没有的 id 跳过）。
  ///
  /// 要发的必须是这份快照，而不是 flush 开头读到的那份：中间用户可能又往里
  /// 合并了字段、或者把它改成了 delete。「标记 attempted」和「取快照」在同一把
  /// 锁里完成，从这一刻起再来的改动都会进 pendingPatch，补发完 [markDone]
  /// 拿快照一比就知道有没有落下的。
  Future<List<OutboxItem>> markAttempted(Iterable<String> clientIds) =>
      _locked(() async {
        final ids = clientIds.toSet();
        if (ids.isEmpty) return const <OutboxItem>[];
        final items = await _read();
        var changed = false;
        for (var i = 0; i < items.length; i++) {
          if (ids.contains(items[i].clientId) && !items[i].attempted) {
            items[i] = items[i].copyWith(attempted: true);
            changed = true;
          }
        }
        if (changed) await _save(items);
        return items.where((e) => ids.contains(e.clientId)).toList();
      });

  Future<int> count() async => (await pending()).length;

  Future<void> clear() => _locked(() => _store.remove(storeKey));

  Future<List<OutboxItem>> _read() async {
    final raw = await _store.read<List<dynamic>>(storeKey);
    if (raw == null) return [];
    return raw.whereType<Map>().map((e) => OutboxItem.fromJson(jsonMap(e))).toList();
  }

  Future<void> _save(List<OutboxItem> items) async {
    if (items.isEmpty) {
      await _store.remove(storeKey);
    } else {
      await _store.write(storeKey, items.map((e) => e.toJson()).toList());
    }
  }

  /// 把 [run] 接到锁链尾巴上；前一个失败不影响后一个继续。
  Future<T> _locked<T>(Future<T> Function() run) {
    final result = _lock.then((_) => run());
    _lock = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}
