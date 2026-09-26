import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/data/models/models.dart';
import 'package:famledger/ui/perk_import/draft_store.dart';
import 'package:famledger/ui/perk_import/perk_import_draft.dart';
import 'package:flutter_test/flutter_test.dart';

import 'perk_import_fixtures.dart';

// 预览草稿的本机副本（spec §6「草稿同时存一份到本机（键 fl.perkImportDraft，≤200KB，读写都包 try/catch），意外关闭后可以恢复」）。
// 存回来的得是「改过之后」的样子：动作、勾选、映射、差异勾选、关联方式、edited、clientId 都在，也不能再套一遍默认勾选。

/// 读写都抛异常的存储（隐私模式、盘满）。
class BrokenStore implements LocalStore {
  @override
  Future<T?> read<T>(String key) => throw StateError('storage unavailable');

  @override
  Future<void> write(String key, Object json) => throw StateError('quota exceeded');

  @override
  Future<void> remove(String key) => throw StateError('storage unavailable');

  @override
  Future<void> clear() async {}
}

/// 写要花时间的存储（像手机上先写临时文件再改名）：[gate] 放行之前写不完。
class SlowStore extends MemoryLocalStore {
  Completer<void>? gate;

  @override
  Future<void> write(String key, Object json) async {
    final g = gate;
    if (g != null) await g.future;
    await super.write(key, json);
  }
}

void main() {
  final now = DateTime(2026, 9, 23, 14, 5);

  test('存和清排队：正在写的那次在「导完清掉」之后才写完，也不会把用完的草稿写回来', () async {
    final store = SlowStore();
    final repo = PerkImportDraftStore(store, clock: () => now);
    store.gate = Completer<void>();
    final saving = repo.save(PerkImportDraft.fromJson(vip88Draft(), clientId: 'cid-race'));
    final clearing = repo.clear();
    await Future<void>.delayed(Duration.zero);
    store.gate!.complete();
    expect(await saving, isTrue);
    await clearing;
    expect(await store.read<Map<String, dynamic>>(kPerkImportDraftKey), isNull, reason: '清在存之后排着，最后是空的');
    expect(await repo.load(), isNull);
  });

  test('存的时候就把草稿定下来：排队等写的时候再改，改动留给下一次存', () async {
    final store = SlowStore();
    final repo = PerkImportDraftStore(store, clock: () => now);
    final d = PerkImportDraft.fromJson(vip88Draft(), clientId: 'cid-snap');
    store.gate = Completer<void>();
    final first = repo.save(d);
    d.setChecked('b2', false);
    store.gate!.complete();
    await first;
    final saved = (await repo.load())!;
    expect(saved.draft.node('b2')!.checked, isTrue);
  });

  test('续写失败标记、截图的叫法跟着草稿存本机，读回来原样', () async {
    final store = MemoryLocalStore();
    final repo = PerkImportDraftStore(store, clock: () => now);
    final json = orderImageDraft()
      ..['truncated'] = true
      ..['continued'] = true
      ..['continueFailed'] = true;
    await repo.save(PerkImportDraft.fromJson(json, imageLabels: const ['图 1 的第 1/2 片', '图 1 的第 2/2 片']));
    final back = (await repo.load())!.draft;
    expect([back.truncated, back.continued, back.continueFailed], [true, true, true]);
    expect(back.imageLabels, ['图 1 的第 1/2 片', '图 1 的第 2/2 片']);
    expect(back.imageLabelOf(back.items.single), '图 1 的第 2/2 片');
    expect(back.items.single.unverified, ['priceCents', 'purchasedOn'], reason: '截图来源的关键字段推断标记跟着走');
  });

  test('存了再读：改过的动作、勾选、领取平台映射、物品关联、edited、clientId 原样回来；不再套默认勾选', () async {
    final store = MemoryLocalStore();
    final repo = PerkImportDraftStore(store, clock: () => now);
    final d = PerkImportDraft.fromJson(vip88Draft(), clientId: 'cid-1');
    d.mapClaim('p2', ClaimMode.mergeInto, targetId: 'yk');
    d.setChecked('b2', false); // 饿了么（p3）跟着不导
    d.setChecked('p3', true); // 用户在筛选列表里又亲手勾上了 p3
    d.setField('b3', 'faceValueCents', 500);
    expect(await repo.save(d), isTrue);

    final saved = (await repo.load())!;
    expect(saved.savedAt, now);
    final back = saved.draft;
    expect([back.importId, back.clientId, back.want, back.sourceText], ['imp-vip', 'cid-1', ImportWant.virtual, vip88Source]);
    expect(back.claimModeOf(back.node('p2')!), ClaimMode.mergeInto);
    expect([back.node('p2')!.action, back.node('p2')!.targetId], ['merge', 'yk']);
    expect([back.node('b2')!.checked, back.node('p3')!.checked], [false, true], reason: '亲手勾上的 p3 恢复后还勾着：不再套一遍默认勾选');
    expect(back.node('b3')!.fields['faceValueCents'], 500);
    expect(back.node('b3')!.edited, {'faceValueCents'});
    expect(jsonEncode(back.toApplyBody()), jsonEncode(d.toApplyBody()), reason: '恢复出来的提交体和关掉之前一模一样（同一个 clientId）');

    final o = PerkImportDraft.fromJson(orderDraft(), clientId: 'cid-2');
    o.setLink('i1', ItemLink.record);
    await repo.save(o);
    final order = (await repo.load())!.draft;
    expect(order.node('i1')!.link, ItemLink.record);
    expect(order.node('i1')!.txCandidates.single.id, 'tx-phone');
  });

  test('截图来源：存块数不存图；恢复出来的草稿知道是截图、没有图（依据块说明一下）', () async {
    final repo = PerkImportDraftStore(MemoryLocalStore(), clock: () => now);
    final d = PerkImportDraft.fromJson(orderImageDraft(), images: [Uint8List(10), Uint8List(20)]);
    expect(d.imageOf(d.node('i1')!)!.length, 20, reason: '第 2 块');
    await repo.save(d);
    final back = (await repo.load())!.draft;
    expect([back.fromImages, back.imageCount, back.images.length], [true, 2, 0]);
    expect(back.node('i1')!.img, 2);
    expect(back.imageOf(back.node('i1')!), isNull);
  });

  test('上限 200KB：放不下先丢原文（改动都在），还放不下就不存、并删掉旧的那份', () async {
    final store = MemoryLocalStore();
    final repo = PerkImportDraftStore(store, clock: () => now);
    final json = vip88Draft();
    json['source'] = {'kind': 'text', 'text': '长' * 80000}; // 约 240KB
    expect(await repo.save(PerkImportDraft.fromJson(json)), isTrue);
    final slim = (await repo.load())!.draft;
    expect(slim.sourceText, '', reason: '原文丢了');
    expect(slim.benefits.length, 7, reason: '节点都在');

    final huge = vip88Draft();
    huge['benefits'] = [
      for (var i = 0; i < 400; i++)
        {...((huge['benefits'] as List).first as Map<String, dynamic>), 'key': 'x$i', 'ev': '依' * 200},
    ];
    expect(await repo.save(PerkImportDraft.fromJson(huge)), isFalse);
    expect(await repo.load(), isNull, reason: '旧的那份也删了，免得恢复出过时的');
  });

  test('读写出错都不抛：存储坏了 save 回 false、load 回 null、clear 静默；坏数据、不认识的版本当没有', () async {
    final broken = PerkImportDraftStore(BrokenStore(), clock: () => now);
    expect(await broken.save(PerkImportDraft.fromJson(vip88Draft())), isFalse);
    expect(await broken.load(), isNull);
    await broken.clear();

    final store = MemoryLocalStore();
    final repo = PerkImportDraftStore(store, clock: () => now);
    await store.write(kPerkImportDraftKey, {'version': 2, 'importId': 'x'});
    expect(await repo.load(), isNull);
    await store.write(kPerkImportDraftKey, {'version': 1, 'importId': '', 'platforms': 'oops'});
    expect(await repo.load(), isNull);
    await store.write(kPerkImportDraftKey, ['not', 'a', 'map']);
    expect(await repo.load(), isNull);
  });
}
