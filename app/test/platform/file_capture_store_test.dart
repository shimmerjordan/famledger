import 'dart:convert';
import 'dart:io';

import 'package:famledger/capture/capture_types.dart';
import 'package:famledger/capture/classifier.dart';
import 'package:famledger/capture/pipeline.dart';
import 'package:famledger/platform/file_capture_store.dart';
import 'package:flutter_test/flutter_test.dart';

CaptureRecord record(
  String id, {
  DateTime? createdAt,
  String? transactionId,
  bool synced = false,
  String? syncError,
  CaptureDecision decision = CaptureDecision.recorded,
}) => CaptureRecord(
  captureId: id,
  decision: decision,
  draft: CaptureDraft(
    clientId: id,
    type: 'expense',
    amountCents: 3500,
    occurredAt: DateTime(2026, 9, 12, 12, 30),
    memberId: 'm1',
    merchant: '美团',
    status: 'confirmed',
    confidence: 0.9,
    rawText: '你有一笔35.00元的支出，来自美团',
    sourceApp: 'com.eg.android.AlipayGphone',
    captureId: id,
  ),
  dedupeHash: 'hash-$id',
  learnText: '美团',
  features: const CaptureFeatures(hour: 12, weekday: 5),
  createdAt: createdAt ?? DateTime(2026, 9, 12, 12, 30),
  transactionId: transactionId,
  synced: synced,
  syncError: syncError,
);

CaptureLogEntry entry(String title, {String decision = 'recorded', String? captureId}) => CaptureLogEntry(
  at: DateTime(2026, 9, 12, 12, 30),
  package: 'com.eg.android.AlipayGphone',
  title: title,
  body: '92% 可信',
  decision: decision,
  captureId: captureId,
);

void main() {
  late Directory dir;
  late FileCaptureStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('fl-capture-store-');
    store = FileCaptureStore(dir);
  });

  tearDown(() => dir.deleteSync(recursive: true));

  group('去重哈希', () {
    test('没见过是 null，标记后能读回同一时刻', () async {
      expect(await store.lastSeen('h1'), isNull);
      final at = DateTime(2026, 9, 12, 12, 30, 15);
      await store.markSeen('h1', at);
      expect(await store.lastSeen('h1'), at);
    });

    test('超过一天的哈希在下一次写入时被清掉', () async {
      await store.markSeen('old', DateTime.now().subtract(const Duration(days: 2)));
      await store.markSeen('fresh', DateTime.now());
      expect(await store.lastSeen('old'), isNull);
      expect(await store.lastSeen('fresh'), isNotNull);
    });
  });

  group('捕获记录', () {
    test('保存 / 读取 / 删除，跨实例可见', () async {
      await store.saveCapture(record('cap-1', transactionId: 't1', synced: true));
      final again = FileCaptureStore(dir);
      final loaded = await again.loadCapture('cap-1');
      expect(loaded, isNotNull);
      expect(loaded!.transactionId, 't1');
      expect(loaded.draft.amountCents, 3500);
      expect(loaded.draft.merchant, '美团');
      expect(loaded.synced, isTrue);

      await again.deleteCapture('cap-1');
      expect(await store.loadCapture('cap-1'), isNull);
    });

    test('超过上限按创建时间淘汰最老的', () async {
      for (var i = 0; i < FileCaptureStore.maxCaptures + 5; i++) {
        await store.saveCapture(record('cap-$i', createdAt: DateTime(2026, 1, 1).add(Duration(minutes: i))));
      }
      expect(await store.loadCapture('cap-0'), isNull);
      expect(await store.loadCapture('cap-4'), isNull);
      expect(await store.loadCapture('cap-5'), isNotNull);
      expect(await store.loadCapture('cap-${FileCaptureStore.maxCaptures + 4}'), isNotNull);
    });

    test('pendingUploads 只挑「没送到、没被拒、没作废」的', () async {
      await store.saveCapture(record('offline'));
      await store.saveCapture(record('synced', transactionId: 't1', synced: true));
      await store.saveCapture(record('rejected', syncError: '类别不存在'));
      await store.saveCapture(record('void', decision: CaptureDecision.ignored));
      final pending = await store.pendingUploads();
      expect(pending.map((r) => r.captureId), ['offline']);
    });

    test('坏掉的文件当作空，不影响后续写入', () async {
      File('${dir.path}/captures.json').writeAsStringSync('{not json');
      expect(await store.loadCapture('x'), isNull);
      await store.saveCapture(record('cap-1'));
      expect(await store.loadCapture('cap-1'), isNotNull);
    });
  });

  group('模型', () {
    test('没有就是 null，保存后原样读回', () async {
      expect(await store.loadModel(kCategoryModelKey), isNull);
      final json = {
        'version': 3,
        'classes': {
          'c1': {'docs': 1, 'tokens': 2, 'counts': {'美': 1, '团': 1}},
        },
        'vocab': 2,
        'totalDocs': 1,
      };
      await store.saveModel(kCategoryModelKey, json);
      expect(await store.loadModel(kCategoryModelKey), json);
      expect(File('${dir.path}/model_category.json').existsSync(), isTrue);
    });
  });

  group('最近捕获', () {
    test('新的在前，最多 50 条', () async {
      for (var i = 0; i < 60; i++) {
        await store.appendLog(entry('第 $i 条'));
      }
      final recent = await store.recent();
      expect(recent.length, FileCaptureStore.maxRecent);
      expect(recent.first.title, '第 59 条');
      expect(recent.last.title, '第 10 条');
    });

    test('忽略类最多留 10 条，不把真正的记账挤出去', () async {
      await store.appendLog(entry('真记账', captureId: 'cap-1'));
      for (var i = 0; i < 30; i++) {
        await store.appendLog(entry('聊天 $i', decision: 'ignored'));
      }
      final recent = await store.recent();
      expect(recent.where((e) => e.decision == 'ignored').length, FileCaptureStore.maxIgnoredInRecent);
      expect(recent.any((e) => e.title == '真记账'), isTrue);
    });

    test('updateLog 按 captureId 改结论，clearRecent 清空', () async {
      await store.appendLog(entry('待确认的一笔', decision: 'pending', captureId: 'cap-9'));
      await store.updateLog('cap-9', (e) => e.copyWith(decision: 'recorded', transactionId: 't9'));
      final recent = await store.recent();
      expect(recent.single.decision, 'recorded');
      expect(recent.single.transactionId, 't9');
      expect(jsonDecode(File('${dir.path}/recent.json').readAsStringSync()), isA<List<dynamic>>());

      await store.clearRecent();
      expect(await store.recent(), isEmpty);
    });

    test('日志往返保留时间与金额', () async {
      final e = CaptureLogEntry(
        at: DateTime(2026, 9, 12, 12, 30, 5),
        package: 'com.tencent.mm',
        title: '微信 −¥12.00 · 餐饮',
        body: '待确认',
        decision: 'pending',
        captureId: 'cap-2',
        amountCents: 1200,
        type: 'expense',
      );
      final back = CaptureLogEntry.fromJson(jsonDecode(jsonEncode(e.toJson())) as Map<String, dynamic>);
      expect(back.at, e.at);
      expect(back.amountCents, 1200);
      expect(back.type, 'expense');
      expect(back.captureId, 'cap-2');
    });
  });

  group('离线队列', () {
    CaptureOp op(String id, String type, {String tx = 't1', Map<String, dynamic>? payload}) => CaptureOp(
      id: id,
      at: DateTime(2026, 9, 12, 12, 30, 5),
      type: type,
      captureId: 'cap-1',
      transactionId: tx,
      payload: payload,
    );

    test('动作按入队顺序读回，字段往返，删掉后不在', () async {
      await store.enqueueOp(op('op-1', 'patch', payload: {'fundId': 'f2', 'status': 'confirmed'}));
      await store.enqueueOp(op('op-2', 'confirm'));
      final ops = await FileCaptureStore(dir).pendingOps();
      expect(ops.map((o) => o.id), ['op-1', 'op-2']);
      expect(ops.first.type, 'patch');
      expect(ops.first.payload, {'fundId': 'f2', 'status': 'confirmed'});
      expect(ops.first.at, DateTime(2026, 9, 12, 12, 30, 5));
      expect(ops.last.payload, isNull);
      await store.removeOp('op-1');
      expect((await store.pendingOps()).map((o) => o.id), ['op-2']);
    });

    test('动作队列超过上限丢最老的', () async {
      for (var i = 0; i < LocalCaptureStore.maxOps + 3; i++) {
        await store.enqueueOp(op('op-$i', 'confirm'));
      }
      final ops = await store.pendingOps();
      expect(ops.length, LocalCaptureStore.maxOps);
      expect(ops.first.id, 'op-3');
    });

    test('学习样本：带 id 入队、按 id 删、上限 200，重放期间新入队的不丢', () async {
      final a = await store.enqueueLearn([{'text': 'a', 'categoryId': 'c1'}]);
      final b = await store.enqueueLearn([{'text': 'b', 'categoryId': 'c1'}]);
      expect(await store.enqueueLearn(const []), isEmpty);
      expect(a.single, isNot(b.single));
      expect((await store.pendingLearn()).map((s) => s.sample['text']), ['a', 'b']);

      // 模拟：重放拿到快照 [a, b]，期间又入队 c，然后按 id 删 a、b → c 还在
      final snapshot = await store.pendingLearn();
      await store.enqueueLearn([{'text': 'c', 'categoryId': 'c1'}]);
      await store.removeLearn(snapshot.map((e) => e.id));
      expect((await store.pendingLearn()).map((s) => s.sample['text']), ['c']);

      await store.enqueueLearn([for (var i = 0; i < 205; i++) {'text': 's$i'}]);
      final queue = await store.pendingLearn();
      expect(queue.length, LocalCaptureStore.maxLearnQueue);
      expect(queue.first.sample['text'], 's5', reason: '206 条留最新 200 条：c 与 s0–s4 被挤掉');
      expect(queue.map((e) => e.id).toSet().length, queue.length, reason: 'id 唯一');
    });

    test('特征键：同一条捕获的不同标签同键，不同捕获不同键', () {
      const base = {'text': '美团', 'merchant': '美团', 'hour': 12, 'weekday': 5};
      final k1 = QueuedLearnSample.featureKeyOf({...base, 'fundId': 'f2', 'categoryId': 'c1'});
      final k2 = QueuedLearnSample.featureKeyOf({...base, 'fundId': 'f3'});
      final k3 = QueuedLearnSample.featureKeyOf({...base, 'text': '滴滴出行', 'fundId': 'f2'});
      expect(k1, k2);
      expect(k1, isNot(k3));
    });

    test('按流水 id 反查捕获记录', () async {
      await store.saveCapture(record('cap-1', transactionId: 't1', synced: true));
      expect(await store.captureIdForTransaction('t1'), 'cap-1');
      expect(await store.captureIdForTransaction('nope'), isNull);
    });
  });

  test('并发读改写不丢数据', () async {
    await Future.wait([
      for (var i = 0; i < 20; i++) store.appendLog(entry('并发 $i')),
      for (var i = 0; i < 20; i++) store.markSeen('h$i', DateTime.now()),
    ]);
    expect((await store.recent()).length, 20);
    for (var i = 0; i < 20; i++) {
      expect(await store.lastSeen('h$i'), isNotNull, reason: 'h$i');
    }
  });
}
