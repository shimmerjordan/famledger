import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/data/local/outbox.dart';
import 'package:flutter_test/flutter_test.dart';

OutboxItem item(
  String clientId,
  String op, [
  Map<String, dynamic>? payload,
  bool attempted = false,
]) => OutboxItem(
  clientId: clientId,
  op: op,
  payload: payload ?? {'amountCents': 100},
  queuedAt: DateTime.utc(2026, 9, 12, 10),
  attempted: attempted,
);

/// 每次读写都让出一次事件循环，把「读—改—写」之间的窗口撑开，
/// 没有锁的话交叉执行必丢数据。
class SlowStore implements LocalStore {
  final MemoryLocalStore inner = MemoryLocalStore();

  @override
  Future<T?> read<T>(String key) async {
    await Future<void>.delayed(Duration.zero);
    return inner.read<T>(key);
  }

  @override
  Future<void> write(String key, Object json) async {
    await Future<void>.delayed(Duration.zero);
    return inner.write(key, json);
  }

  @override
  Future<void> remove(String key) async {
    await Future<void>.delayed(Duration.zero);
    return inner.remove(key);
  }

  @override
  Future<void> clear() => inner.clear();
}

void main() {
  late MemoryLocalStore store;
  late Outbox outbox;

  setUp(() {
    store = MemoryLocalStore();
    outbox = Outbox(store);
  });

  test('OutboxItem 往返', () {
    final json = item('c1', 'create').toJson();
    final back = OutboxItem.fromJson(json);
    expect(back.clientId, 'c1');
    expect(back.op, 'create');
    expect(back.payload['amountCents'], 100);
    expect(back.queuedAt.isAtSameMomentAs(DateTime.utc(2026, 9, 12, 10)), isTrue);
    expect(back.queuedAt.isUtc, isFalse);
  });

  test('入队后可读出', () async {
    await outbox.enqueue(item('c1', 'create'));
    final pending = await outbox.pending();
    expect(pending, hasLength(1));
    expect(pending.single.clientId, 'c1');
    expect(pending.single.payload['amountCents'], 100);
  });

  test('同 clientId 同 op 入队两次只剩一条', () async {
    await outbox.enqueue(item('c1', 'create', {'amountCents': 100}));
    await outbox.enqueue(item('c1', 'create', {'amountCents': 250}));
    final pending = await outbox.pending();
    expect(pending, hasLength(1));
    expect(pending.single.payload['amountCents'], 250);
  });

  test('create 后 patch 合并进 create，不产生第二条', () async {
    await outbox.enqueue(item('c1', 'create', {'amountCents': 100, 'note': 'a'}));
    await outbox.enqueue(item('c1', 'patch', {'note': 'b'}));
    final pending = await outbox.pending();
    expect(pending, hasLength(1));
    expect(pending.single.op, 'create');
    expect(pending.single.payload, {'amountCents': 100, 'note': 'b'});
  });

  test('未同步的 create 被 delete 时整条丢弃', () async {
    await outbox.enqueue(item('c1', 'create'));
    await outbox.enqueue(item('c1', 'delete', {'id': 'c1'}));
    expect(await outbox.pending(), isEmpty);
  });

  test('不同 clientId 各自入队并保持先后顺序', () async {
    await outbox.enqueue(item('c1', 'create'));
    await outbox.enqueue(item('c2', 'confirm', {'id': 'c2'}));
    await outbox.enqueue(item('c3', 'patch', {'id': 'c3'}));
    expect(
      (await outbox.pending()).map((e) => e.clientId).toList(),
      ['c1', 'c2', 'c3'],
    );
  });

  test('markDone 移除指定条目，未知 clientId 无副作用', () async {
    await outbox.enqueue(item('c1', 'create'));
    await outbox.enqueue(item('c2', 'create'));
    await outbox.markDone('c1');
    expect((await outbox.pending()).map((e) => e.clientId), ['c2']);
    await outbox.markDone('nope');
    expect((await outbox.pending()).map((e) => e.clientId), ['c2']);
  });

  test('落盘后新实例仍能读到', () async {
    await outbox.enqueue(item('c1', 'create'));
    final reopened = Outbox(store);
    expect((await reopened.pending()).single.clientId, 'c1');
  });

  test('clear 清空队列', () async {
    await outbox.enqueue(item('c1', 'create'));
    await outbox.clear();
    expect(await outbox.pending(), isEmpty);
  });

  group('并发', () {
    test('enqueue 与 markDone 交叉执行不会互相覆盖', () async {
      final slow = Outbox(SlowStore());
      await slow.enqueue(item('old', 'create'));

      // 补发正在出队，用户同时又记了一笔：两个读—改—写必须排队。
      final done = slow.markDone('old');
      final added = slow.enqueue(item('new', 'create'));
      await Future.wait([done, added]);

      final pending = await slow.pending();
      expect(pending.map((e) => e.clientId), ['new']);
    });

    test('并发入队多条一条都不丢', () async {
      final slow = Outbox(SlowStore());
      await Future.wait([
        for (var i = 0; i < 8; i++) slow.enqueue(item('c$i', 'create')),
      ]);
      expect(await slow.pending(), hasLength(8));
    });
  });

  group('markDone 的在途保护', () {
    test('没变过就正常删掉', () async {
      await outbox.enqueue(item('c1', 'create'));
      final sent = (await outbox.pending()).single;
      await outbox.markDone('c1', sent: sent, serverId: 't1');
      expect(await outbox.pending(), isEmpty);
    });

    test('发送期间又改了字段：不删行，转成 patch 接着排队', () async {
      await outbox.enqueue(item('c1', 'create', {'amountCents': 100}));
      await outbox.markAttempted(['c1']);
      // 快照 = 刚发出去的那一份（pendingPatch 还是空的）
      final sent = (await outbox.pending()).single;

      // batch 还在路上，用户改了备注
      await outbox.enqueue(item('c1', 'patch', {'id': 'c1', 'note': '晚到的改动'}));
      await outbox.markDone('c1', sent: sent, serverId: 't-server');

      final rest = await outbox.pending();
      expect(rest.single.op, 'patch');
      expect(rest.single.payload, {'id': 't-server', 'note': '晚到的改动'});
      expect(rest.single.pendingPatch, isEmpty);
    });

    test('发送期间被删：保留 delete 并填上刚拿到的服务端 id', () async {
      await outbox.enqueue(item('c1', 'create', {'amountCents': 100}));
      await outbox.markAttempted(['c1']);
      final sent = (await outbox.pending()).single;

      await outbox.enqueue(item('c1', 'delete', {'id': 'c1'}));
      await outbox.markDone('c1', sent: sent, serverId: 't-server');

      final rest = await outbox.pending();
      expect(rest.single.op, 'delete');
      expect(rest.single.payload['id'], 't-server');
      // 已经知道服务端 id 了，不用再幂等重建一次。
      expect(rest.single.payload.containsKey('create'), isFalse);
    });

    test('不给快照时照旧无条件删除', () async {
      await outbox.enqueue(item('c1', 'create'));
      await outbox.markDone('c1');
      expect(await outbox.pending(), isEmpty);
    });

    test('patch 在途中又改：不删行，留下一条只含新字段的 patch', () async {
      await outbox.enqueue(item('t1', 'patch', {'id': 't1', 'amountCents': 500}));
      // 发出去的快照：markAttempted 返回的就是它
      final sent = (await outbox.markAttempted(['t1'])).single;
      expect(sent.attempted, isTrue);

      // PATCH 还在路上，用户又改了备注
      await outbox.enqueue(item('t1', 'patch', {'id': 't1', 'note': '晚到的'}));
      await outbox.markDone('t1', sent: sent, serverId: 't1');

      final rest = await outbox.pending();
      expect(rest.single.op, 'patch');
      expect(rest.single.payload, {'id': 't1', 'note': '晚到的'});
      expect(rest.single.pendingPatch, isEmpty);
    });

    test('patch 在途中被删：保留 delete', () async {
      await outbox.enqueue(item('t1', 'patch', {'id': 't1', 'note': 'x'}));
      final sent = (await outbox.markAttempted(['t1'])).single;

      await outbox.enqueue(item('t1', 'delete', {'id': 't1'}));
      await outbox.markDone('t1', sent: sent, serverId: 't1');

      final rest = await outbox.pending();
      expect(rest.single.op, 'delete');
      expect(rest.single.payload, {'id': 't1'});
    });

    test('pendingPatch 里已经随这次请求发出去的部分不再重发，只留差量', () async {
      await outbox.enqueue(item('c1', 'create', {'amountCents': 100}));
      await outbox.markAttempted(['c1']);
      await outbox.enqueue(item('c1', 'patch', {'id': 'c1', 'note': 'a'}));
      // 这次补发把 pendingPatch = {note: a} 一起发了出去
      final sent = (await outbox.markAttempted(['c1'])).single;
      expect(sent.pendingPatch, {'note': 'a'});

      // 在途中又改了金额
      await outbox.enqueue(item('c1', 'patch', {'id': 'c1', 'amountCents': 5}));
      await outbox.markDone('c1', sent: sent, serverId: 't-server');

      final rest = await outbox.pending();
      expect(rest.single.op, 'patch');
      expect(rest.single.payload, {'id': 't-server', 'amountCents': 5});
    });

    test('markAttempted 返回此刻队列里的行（含刚合并进来的字段），未知 id 忽略', () async {
      await outbox.enqueue(item('t1', 'patch', {'id': 't1', 'amountCents': 500}));
      await outbox.enqueue(item('t1', 'patch', {'id': 't1', 'note': '两件事'}));
      final fresh = await outbox.markAttempted(['t1', 'nope']);
      expect(fresh.single.clientId, 't1');
      expect(fresh.single.attempted, isTrue);
      expect(fresh.single.payload, {'id': 't1', 'amountCents': 500, 'note': '两件事'});
      expect(await outbox.markAttempted([]), isEmpty);
    });
  });

  group('发过的 patch 再被改：payload 冻结，新字段进 pendingPatch', () {
    test('发过的 patch 再被 patch：payload 不动，新字段记到 pendingPatch', () async {
      await outbox.enqueue(item('t1', 'patch', {'id': 't1', 'amountCents': 500}));
      await outbox.markAttempted(['t1']);
      await outbox.enqueue(item('t1', 'patch', {'id': 't1', 'note': '晚到的'}));

      final row = (await outbox.pending()).single;
      expect(row.op, 'patch');
      expect(row.payload, {'id': 't1', 'amountCents': 500});
      expect(row.pendingPatch, {'note': '晚到的'});
      expect(row.attempted, isTrue);
    });

    test('发过的 patch 连改两次：pendingPatch 累积，后写的键赢', () async {
      await outbox.enqueue(item('t1', 'patch', {'id': 't1', 'amountCents': 500}));
      await outbox.markAttempted(['t1']);
      await outbox.enqueue(item('t1', 'patch', {'id': 't1', 'note': 'a'}));
      await outbox.enqueue(item('t1', 'patch', {'id': 't1', 'note': 'b', 'merchant': 'm'}));

      final row = (await outbox.pending()).single;
      expect(row.payload, {'id': 't1', 'amountCents': 500});
      expect(row.pendingPatch, {'note': 'b', 'merchant': 'm'});
    });
  });

  group('patch 与 confirm 叠加：合成一条带 status 的 patch', () {
    test('先改再确认', () async {
      await outbox.enqueue(item('t1', 'patch', {'id': 't1', 'note': 'x'}));
      await outbox.enqueue(item('t1', 'confirm', {'id': 't1'}));
      final row = (await outbox.pending()).single;
      expect(row.op, 'patch');
      expect(row.payload, {'id': 't1', 'note': 'x', 'status': 'confirmed'});
    });

    test('先确认再改', () async {
      await outbox.enqueue(item('t1', 'confirm', {'id': 't1'}));
      await outbox.enqueue(item('t1', 'patch', {'id': 't1', 'note': 'x'}));
      final row = (await outbox.pending()).single;
      expect(row.op, 'patch');
      expect(row.payload, {'id': 't1', 'status': 'confirmed', 'note': 'x'});
    });

    test('发过的 patch 再确认：status 进 pendingPatch', () async {
      await outbox.enqueue(item('t1', 'patch', {'id': 't1', 'note': 'x'}));
      await outbox.markAttempted(['t1']);
      await outbox.enqueue(item('t1', 'confirm', {'id': 't1'}));
      final row = (await outbox.pending()).single;
      expect(row.op, 'patch');
      expect(row.payload, {'id': 't1', 'note': 'x'});
      expect(row.pendingPatch, {'status': 'confirmed'});
    });

    test('发过的 confirm 再改：转成 patch，字段进 pendingPatch', () async {
      await outbox.enqueue(item('t1', 'confirm', {'id': 't1'}));
      await outbox.markAttempted(['t1']);
      await outbox.enqueue(item('t1', 'patch', {'id': 't1', 'note': 'x'}));
      final row = (await outbox.pending()).single;
      expect(row.op, 'patch');
      expect(row.payload, {'id': 't1'});
      expect(row.pendingPatch, {'status': 'confirmed', 'note': 'x'});
      expect(row.attempted, isTrue);
    });
  });

  group('attempted（发过一次了）', () {
    test('markAttempted 落盘且只改指定的几条', () async {
      await outbox.enqueue(item('c1', 'create'));
      await outbox.enqueue(item('c2', 'create'));
      await outbox.markAttempted(['c1']);
      final pending = await outbox.pending();
      expect(pending.firstWhere((e) => e.clientId == 'c1').attempted, isTrue);
      expect(pending.firstWhere((e) => e.clientId == 'c2').attempted, isFalse);
    });

    test('发过的 create 再被 delete：不丢弃，转成带 create 的 delete', () async {
      await outbox.enqueue(item('c1', 'create', {'amountCents': 100}));
      await outbox.markAttempted(['c1']);
      await outbox.enqueue(item('c1', 'delete', {'id': 'c1'}));

      final pending = await outbox.pending();
      expect(pending, hasLength(1));
      expect(pending.single.op, 'delete');
      expect(pending.single.payload['id'], 'c1');
      expect(pending.single.payload['create'], {'amountCents': 100});
      expect(pending.single.attempted, isTrue);
    });

    test('没发过的 create 再被 delete 仍然整条丢弃', () async {
      await outbox.enqueue(item('c1', 'create'));
      await outbox.enqueue(item('c1', 'delete', {'id': 'c1'}));
      expect(await outbox.pending(), isEmpty);
    });

    test('连着改两次：补丁浅合并，前一次不会被盖掉', () async {
      await outbox.enqueue(item('t1', 'patch', {'id': 't1', 'amountCents': 500}));
      await outbox.enqueue(item('t1', 'patch', {'id': 't1', 'note': '两件事'}));
      final pending = await outbox.pending();
      expect(pending, hasLength(1));
      expect(pending.single.payload, {
        'id': 't1',
        'amountCents': 500,
        'note': '两件事',
      });
    });

    test('覆盖同 op 时保留 attempted 标记', () async {
      await outbox.enqueue(item('c1', 'create', {'amountCents': 100}));
      await outbox.markAttempted(['c1']);
      await outbox.enqueue(item('c1', 'create', {'amountCents': 250}));
      final pending = await outbox.pending();
      expect(pending.single.payload['amountCents'], 250);
      expect(pending.single.attempted, isTrue);
    });
  });
}
