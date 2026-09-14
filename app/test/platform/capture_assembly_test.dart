import 'dart:convert';
import 'dart:io';

import 'package:famledger/capture/pipeline.dart';
import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/data/local/secure_store.dart';
import 'package:famledger/data/repos/session_repo.dart';
import 'package:famledger/platform/capture_runtime.dart';
import 'package:famledger/platform/file_capture_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_server.dart';

/// 第一次读缓存就炸（模拟坏掉的缓存文件 / 磁盘抽风），之后正常。
class FlakyLocalStore extends MemoryLocalStore {
  int failuresLeft = 1;
  int reads = 0;

  @override
  Future<T?> read<T>(String key) async {
    reads++;
    if (failuresLeft > 0) {
      failuresLeft--;
      throw const FileSystemException('read failed', 'cache/ledger.json');
    }
    return super.read<T>(key);
  }
}

Map<String, Object> notification(String text) => {
  'id': 'key-${text.hashCode}',
  'package': 'com.eg.android.AlipayGphone',
  'title': '支付宝',
  'text': text,
  'bigText': '',
  'postedAt': DateTime(2026, 9, 12, 12, 30).millisecondsSinceEpoch,
};

void main() {
  late Directory dir;
  late FakeServer server;
  late MemorySecureStore secure;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('fl-capture-assembly-');
    server = FakeServer();
    secure = MemorySecureStore();
    secure.data[SessionRepo.baseUrlKey] = 'https://x.dev';
    secure.data[SessionRepo.sessionKey] = jsonEncode({
      'baseUrl': 'https://x.dev',
      'token': 'tok',
      'deviceId': 'dev',
      'me': {'id': 'm1', 'username': 'mama', 'displayName': '妈妈', 'role': 'admin'},
    });
  });

  tearDown(() => dir.deleteSync(recursive: true));

  CaptureRuntime build(LocalStore cache) => CaptureRuntime(
    secure: secure,
    cache: cache,
    store: FileCaptureStore(dir),
    httpClient: server.client,
    autoReplay: false,
    now: () => DateTime(2026, 9, 12, 12, 31),
  );

  test('冷启动时两条通知同时到：都记上，装配与主数据同步只做一遍', () async {
    final runtime = build(MemoryLocalStore());
    final results = await Future.wait([
      runtime.handleNotification(notification('你有一笔35.00元的支出，来自美团')),
      runtime.handleNotification(notification('你有一笔42.00元的支出，来自滴滴出行')),
    ]);
    for (final out in results) {
      expect(out['decision'], anyOf('recorded', 'pending'), reason: '$out');
      expect(out['transactionId'], isNotNull, reason: '$out');
    }
    expect(server.transactions.length, 2);
    expect(server.calls.where((c) => c == 'GET /api/v1/changes').length, 1, reason: '并发调用共用同一次装配');
    expect(server.calls.where((c) => c == 'GET /api/v1/settings').length, 1);
  });

  test('第一次装配失败（读缓存炸了）不留半成品：报错而不是「未登录」，下一条重新装配成功', () async {
    final cache = FlakyLocalStore();
    final runtime = build(cache);

    final first = await runtime.handleNotification(notification('你有一笔35.00元的支出，来自美团'));
    expect(first['decision'], 'error');
    expect(first['title'], '自动记账出错');
    expect(server.calls.where((c) => c.startsWith('POST /api/v1/transactions')), isEmpty);

    final second = await runtime.handleNotification(notification('你有一笔42.00元的支出，来自滴滴出行'));
    expect(second['decision'], anyOf('recorded', 'pending'), reason: '$second');
    expect(second['transactionId'], isNotNull);
    expect(server.transactions.length, 1);
  });

  test('拉模型：版本涨了但内容没变 → 不重写、不算更新；内容变了才算', () async {
    final runtime = build(MemoryLocalStore());
    server.modelVersion = 9;
    final first = await runtime.syncModel();
    expect(first['updated'], isTrue);
    final store = FileCaptureStore(dir);
    final saved = await store.loadModel(kCategoryModelKey);
    expect(saved!['version'], 9);
    final fundStamp = File('${dir.path}/model_fund.json').lastModifiedSync();
    final categoryStamp = File('${dir.path}/model_category.json').lastModifiedSync();

    await Future<void>.delayed(const Duration(milliseconds: 20));
    server.modelVersion = 10; // 只是版本动了
    final second = await runtime.syncModel();
    expect(second['ok'], isTrue);
    expect(second['updated'], isFalse);
    expect((await store.loadModel(kCategoryModelKey))!['version'], 9, reason: '没重写');
    expect(File('${dir.path}/model_fund.json').lastModifiedSync(), fundStamp, reason: '基金模型也没重写');
    expect(File('${dir.path}/model_category.json').lastModifiedSync(), categoryStamp);

    server.categoryClasses = {
      ...server.categoryClasses,
      'c1': {'docs': 1, 'tokens': 2, 'counts': {'美': 1, '美团': 1}},
    };
    server.modelVersion = 11;
    final third = await runtime.syncModel();
    expect(third['updated'], isTrue);
    final latest = await store.loadModel(kCategoryModelKey);
    expect(latest!['version'], 11);
    expect((latest['classes'] as Map).keys, containsAll(['c1', 'c2']));
  });

  test('拉模型：服务端类别模型是空的就跳过，本地种子与版本号都不动', () async {
    final runtime = build(MemoryLocalStore());
    await runtime.handleNotification(notification('你有一笔35.00元的支出，来自美团')); // 先有本地种子
    final store = FileCaptureStore(dir);
    final seed = (await store.loadModel(kCategoryModelKey))!;
    server.categoryClasses = {};
    server.modelVersion = 9;
    final out = await runtime.syncModel();
    expect(out['ok'], isTrue);
    final after = (await store.loadModel(kCategoryModelKey))!;
    expect(after['version'], seed['version']);
    expect(after['totalDocs'], seed['totalDocs']);
  });
}
