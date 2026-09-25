import 'dart:async';

import 'package:famledger/app/providers.dart';
import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/ui/perks/perk_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// 会员权益 tab 记在本机的两样：上次的视图（本期 / 全部、我 / 全家、分组方式）和点过「知道了」的提醒；
// 以及只在内存里的两样：一键动作的重发 clientId（有时效）和正在路上的动作。

/// 读盘要等 [gate] 放行才回来（看「读回来之前用户已经点过了」）。
class SlowStore extends MemoryLocalStore {
  final Completer<void> gate = Completer<void>();

  @override
  Future<T?> read<T>(String key) async {
    await gate.future;
    return super.read<T>(key);
  }
}

ProviderContainer boot(LocalStore store) {
  final c = ProviderContainer(overrides: [localStoreProvider.overrideWithValue(store)]);
  addTearDown(c.dispose);
  return c;
}

void main() {
  test('PerkViewPrefs：认得的值还原，不认识的按默认', () {
    expect(PerkViewPrefs.fromJson(const {'view': 'all', 'scope': 'mine', 'grouping': 'byClaimPlatform'}).toJson(), {
      'view': 'all',
      'scope': 'mine',
      'grouping': 'byClaimPlatform',
    });
    final junk = PerkViewPrefs.fromJson(const {'view': 'someday', 'scope': 3});
    expect((junk.view, junk.scope, junk.grouping), (PerkView.current, PerkScope.family, PerkGrouping.byMembership));
  });

  test('读盘回来之前用户已经切过了：以用户点的为准，不拿盘里的旧值盖回去', () async {
    final store = SlowStore();
    await store.write(PerkViewPrefsController.storeKey, {'view': 'current', 'scope': 'mine'});
    final c = boot(store);
    expect(c.read(perkViewPrefsProvider).view, PerkView.current, reason: '读回来之前先给默认');
    await c.read(perkViewPrefsProvider.notifier).set(const PerkViewPrefs(view: PerkView.all));
    store.gate.complete();
    await pumpEventQueue();
    expect(c.read(perkViewPrefsProvider).view, PerkView.all);
    expect(c.read(perkViewPrefsProvider).scope, PerkScope.family);
  });

  test('没点过就用盘里的', () async {
    final store = MemoryLocalStore();
    await store.write(PerkViewPrefsController.storeKey, {'view': 'all', 'scope': 'mine'});
    final c = boot(store);
    c.read(perkViewPrefsProvider);
    await pumpEventQueue();
    expect((c.read(perkViewPrefsProvider).view, c.read(perkViewPrefsProvider).scope), (PerkView.all, PerkScope.mine));
  });

  test('「知道了」：记下键和时间；超过 90 天的旧键顺手扔掉；读盘前点的和盘里的合在一起', () async {
    final store = SlowStore();
    await store.write(PerkDismissedController.storeKey, {'old:x:2026-01-01': '2026-01-02T10:00:00.000', 'kept:y:2026-09-01': '2026-09-01T10:00:00.000'});
    final c = boot(store);
    expect(c.read(perkDismissedProvider), isEmpty);
    final first = c.read(perkDismissedProvider.notifier).dismiss('expiry:plus:2026-10-03', DateTime(2026, 9, 23, 10));
    expect(c.read(perkDismissedProvider), {'expiry:plus:2026-10-03'}, reason: '界面上立刻拿掉，不等读盘');
    store.gate.complete();
    await first;
    expect(
      c.read(perkDismissedProvider),
      {'expiry:plus:2026-10-03', 'kept:y:2026-09-01'},
      reason: '盘里的并进来、没被这一下盖掉；1 月记的那条早过了 90 天，顺手扔了',
    );

    await c.read(perkDismissedProvider.notifier).dismiss('renewCharge:tv:2026-09-30', DateTime(2026, 9, 23, 11));
    expect(c.read(perkDismissedProvider), {'expiry:plus:2026-10-03', 'kept:y:2026-09-01', 'renewCharge:tv:2026-09-30'});
    final saved = await store.read<Map<String, dynamic>>(PerkDismissedController.storeKey);
    expect(saved!.keys.toSet(), {'expiry:plus:2026-10-03', 'kept:y:2026-09-01', 'renewCharge:tv:2026-09-30'});
  });

  test('PerkRetryIds：记下的 clientId 在时效内沿用，过了时效（同步早该带回第一次的结果）就当新的一次', () {
    final ids = PerkRetryIds();
    final t0 = DateTime(2026, 9, 23, 10);
    ids.remember('b4/claim/1/2026-09-23/', 'cid-1', t0);
    expect(ids.of('b4/claim/1/2026-09-23/', t0.add(const Duration(minutes: 3))), 'cid-1');
    expect(ids.of('b4/claim/1/2026-09-23/', t0.add(PerkRetryIds.ttl + const Duration(seconds: 1))), isNull);
    expect(ids.of('b4/claim/1/2026-09-23/', t0), isNull, reason: '过期的已经扔掉了');
    ids.remember('renew/tv/2026-10-20', 'cid-2', t0);
    ids.forget('renew/tv/2026-10-20');
    expect(ids.of('renew/tv/2026-10-20', t0), isNull);
  });

  test('PerkBusyController：同一个键占着时再占返回 false，做完放开', () {
    final c = boot(MemoryLocalStore());
    final busy = c.read(perkBusyProvider.notifier);
    expect(busy.start('card/tv'), isTrue);
    expect(busy.start('card/tv'), isFalse);
    expect(busy.start('event/b1'), isTrue, reason: '别的键不受影响');
    busy.done('card/tv');
    expect(c.read(perkBusyProvider), {'event/b1'});
    expect(busy.start('card/tv'), isTrue);
  });
}
