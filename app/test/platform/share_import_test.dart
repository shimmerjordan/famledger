import 'dart:async';

import 'package:famledger/capture/capture_types.dart';
import 'package:famledger/capture/classifier.dart';
import 'package:famledger/capture/naive_bayes.dart';
import 'package:famledger/capture/parser.dart';
import 'package:famledger/capture/pipeline.dart';
import 'package:famledger/platform/file_capture_store.dart';
import 'package:famledger/platform/share_channel.dart';
import 'package:famledger/platform/share_import.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(kShareChannelName);
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// 原生 App Group 里攒着的条目（`takePending` 读完即清）。
  var pending = <Map<String, Object?>>[];
  var calls = <String>[];
  var channelThrowsMissingPlugin = false;
  var clock = DateTime(2026, 9, 13, 20);

  setUp(() {
    pending = <Map<String, Object?>>[];
    calls = <String>[];
    channelThrowsMissingPlugin = false;
    clock = DateTime(2026, 9, 13, 20);
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (channelThrowsMissingPlugin) {
        throw MissingPluginException('${call.method} 没注册');
      }
      switch (call.method) {
        case 'takePending':
          final out = List<Map<String, Object?>>.from(pending);
          pending = <Map<String, Object?>>[];
          return out;
        case 'peekPending':
          return List<Map<String, Object?>>.from(pending);
        default:
          return null;
      }
    });
    // 剪贴板默认是空的；单条测试自己覆盖。
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Map<String, Object?> share(String text, {String source = 'share', DateTime? at}) => {
    'text': text,
    'source': source,
    'receivedAt': (at ?? clock).toUtc().toIso8601String(),
  };

  Uri captureUri(String? text, {String source = 'share'}) => Uri.parse(
    'famledger://capture?source=$source'
    '${text == null ? '' : '&text=${Uri.encodeComponent(text)}'}',
  );

  ({ShareImportService service, _RecordingPipeline pipeline, StreamController<Uri> links}) build({
    bool channelSupported = true,
    Uri? initialLink,
    bool observeLifecycle = false,
  }) {
    final pipeline = _RecordingPipeline();
    final links = StreamController<Uri>.broadcast();
    final service = ShareImportService(
      pipeline: () async => pipeline,
      channel: SharePendingChannel(
        channel: channel,
        supported: channelSupported ? true : null,
        now: () => clock,
      ),
      linkStream: links.stream,
      initialLink: () async => initialLink,
      now: () => clock,
      observeLifecycle: observeLifecycle,
    );
    addTearDown(() {
      service.dispose();
      links.close();
    });
    return (service: service, pipeline: pipeline, links: links);
  }

  test('(a) 深链带 text=：按 ios.share 喂管线，文本逐字还原', () async {
    final it = build();
    final outcomes = <CaptureOutcome>[];
    it.service.outcomes.listen(outcomes.add);

    // `+` `&` `=` `?` `#` 与中文都必须原样回来（原生把 `+` 也转义了，不能按 `+`=空格 解）。
    const text = '星巴克 A+B & C=1 ?#￥35.00 已支付';
    await it.service.handleLink(captureUri(text));

    expect(it.pipeline.seen, hasLength(1));
    final raw = it.pipeline.seen.single;
    expect(raw.packageName, 'ios.share');
    expect(raw.text, text);
    expect(raw.title, '');
    expect(raw.bigText, '');
    // 深链带了 text 也要先 drain App Group，否则那份副本会一直留着。
    expect(calls, ['takePending']);

    await pumpEventQueue();
    expect(outcomes.map((o) => o.decision), [CaptureDecision.recorded]);
  });

  test('(a2) source=shortcut → ios.shortcut；packageName 只有这三种', () async {
    final it = build();
    await it.service.handleLink(captureUri('麦当劳 支付 23 元', source: 'shortcut'));
    expect(it.pipeline.seen.single.packageName, 'ios.shortcut');
    expect(capturePackageForSource('clipboard'), 'ios.clipboard');
    expect(capturePackageForSource('乱七八糟'), 'ios.share');
  });

  test('(a3) text= 里的 `+` 是加号不是空格（%2B 与裸 + 都要还原成 +）', () async {
    // 原生转义时特意把 `+` 也转成了 `%2B`；但深链是用户/系统递过来的，
    // 裸 `+` 也可能出现。两种写法都必须还原成加号 —— 用 `Uri.queryParameters`
    // 解（`+` = 空格）的话，下面这条会变成 'A B'。
    final bare = build();
    await bare.service.handleLink(Uri.parse('famledger://capture?source=share&text=A+B'));
    expect(bare.pipeline.seen.single.text, 'A+B');

    final escaped = build();
    await escaped.service.handleLink(Uri.parse('famledger://capture?source=share&text=A%2BB'));
    expect(escaped.pipeline.seen.single.text, 'A+B');

    // 真正的空格仍然是 %20（原生就是这么转的）。
    final spaced = build();
    await spaced.service.handleLink(
      Uri.parse('famledger://capture?source=share&text=%E7%BE%8E%E5%9B%A2%20A+B%20%EF%BF%A535'),
    );
    expect(spaced.pipeline.seen.single.text, '美团 A+B ￥35');
  });

  test('(b) store 里同文本的副本丢掉，不同文本照常导入', () async {
    final it = build();
    const text = '美团 已支付 ￥35.00';
    pending = [share(text), share('滴滴 已支付 ￥18.00', source: 'shortcut')];

    await it.service.handleLink(captureUri(text));

    expect(it.pipeline.seen.map((r) => r.text), [text, '滴滴 已支付 ￥18.00']);
    expect(it.pipeline.seen.map((r) => r.packageName), ['ios.share', 'ios.shortcut']);
  });

  test('(b2) 深链不带 text（超长）→ store 里的全部导入', () async {
    final it = build();
    pending = [share('一号'), share('二号', source: 'shortcut')];

    await it.service.handleLink(captureUri(null));

    expect(it.pipeline.seen.map((r) => r.text), ['一号', '二号']);
    expect(it.pipeline.seen.first.postedAt, clock.toUtc().toLocal());
  });

  test('(c) 迟到的同一份副本：10 分钟内丢掉，超窗口照常导入', () async {
    final it = build();
    const text = '盒马 已支付 ￥88.50';
    await it.service.handleLink(captureUri(text));
    expect(it.pipeline.seen, hasLength(1));

    // 扩展写盘比深链慢：下一次恢复前台才被 takePending 带出来。
    clock = clock.add(const Duration(minutes: 5));
    pending = [share(text)];
    await it.service.onResumed();
    expect(it.pipeline.seen, hasLength(1), reason: '10 分钟内的副本要丢掉');
    expect(pending, isEmpty, reason: 'takePending 读完即清');

    // 超过记忆窗口就不再认为是副本（真去重交给管线自己那层）。
    clock = clock.add(const Duration(minutes: 6));
    pending = [share(text)];
    await it.service.onResumed();
    expect(it.pipeline.seen, hasLength(2));
  });

  test('(d) 剪贴板是空的 → 返回 null，不碰管线', () async {
    final it = build();
    expect(await it.service.importFromClipboard(), isNull);
    expect(it.pipeline.seen, isEmpty);

    // 只有空白字符也算空。
    messenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData' ? {'text': '  \n '} : null,
    );
    expect(await it.service.importFromClipboard(), isNull);
    expect(it.pipeline.seen, isEmpty);

    // 有内容 → 走 ios.clipboard。
    messenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData' ? {'text': '肯德基 已支付 ￥42.00'} : null,
    );
    final outcome = await it.service.importFromClipboard();
    expect(outcome?.decision, CaptureDecision.recorded);
    expect(it.pipeline.seen.single.packageName, 'ios.clipboard');
    expect(it.pipeline.seen.single.text, '肯德基 已支付 ￥42.00');
  });

  test('(e) 不是 famledger://capture 的链接一律不管', () async {
    final it = build();
    final ignored = [
      Uri.parse('https://example.com/capture?text=%E5%92%96%E5%95%A1'),
      Uri.parse('famledger://settings?text=%E5%92%96%E5%95%A1'),
      Uri.parse('otherapp://capture?text=%E5%92%96%E5%95%A1'),
      Uri.parse('famledger://'),
    ];
    for (final uri in ignored) {
      await it.service.handleLink(uri);
      it.links.add(uri);
    }
    await pumpEventQueue();

    expect(it.pipeline.seen, isEmpty);
    expect(calls, isEmpty, reason: '连 takePending 都不该发');
    expect(ShareImportService.isCaptureUri(Uri.parse('famledger://capture?source=share')), isTrue);
  });

  test('(e2) famledger://capture/<captureId> 是打开详情，不是待导入文本', () async {
    final opened = <String>[];
    final pipeline = _RecordingPipeline();
    final service = ShareImportService(
      pipeline: () async => pipeline,
      channel: SharePendingChannel(channel: channel, supported: true),
      linkStream: const Stream<Uri>.empty(),
      initialLink: () async => null,
      onOpenCapture: (id) async {
        opened.add(id);
        return true;
      },
      observeLifecycle: false,
    );
    addTearDown(service.dispose);

    await service.handleLink(Uri.parse('famledger://capture/cap-1?tx=tx-9'));
    expect(opened, ['cap-1']);
    expect(pipeline.seen, isEmpty);
    expect(calls, isEmpty);
  });

  test('(f) 通道不在：非 iOS 一次都不调，MissingPluginException 也吞掉', () async {
    // 非 iOS：isSupported=false，一个 invokeMethod 都不发。
    final off = build(channelSupported: false);
    pending = [share('不该被读到')];
    await off.service.handleLink(captureUri('星巴克 已支付 ￥35.00'));
    expect(off.pipeline.seen.map((r) => r.text), ['星巴克 已支付 ￥35.00']);
    expect(await off.service.peekPending(), isEmpty);
    expect(calls, isEmpty, reason: 'takePending / peekPending 都不该发出去');

    // 强制打开但原生没注册（Xcode 里还没接上 target）：吞掉异常，URL 那条照常导入。
    channelThrowsMissingPlugin = true;
    final on = build();
    await on.service.handleLink(captureUri('麦当劳 已支付 ￥23.00'));
    expect(calls, ['takePending']);
    expect(on.pipeline.seen.map((r) => r.text), ['麦当劳 已支付 ￥23.00']);
    expect(await on.service.peekPending(), isEmpty);
    await on.service.importPending();
    expect(on.pipeline.seen, hasLength(1));
  });

  test('(g) start()：冷启动链接只认一次（app_links 的流会再发一遍）', () async {
    const text = '京东 已支付 ￥199.00';
    final initial = captureUri(text);
    final it = build(initialLink: initial, observeLifecycle: true);

    await it.service.start();
    expect(it.pipeline.seen, hasLength(1));

    it.links.add(initial); // app_links 6.x：冷启动那条也会从流里出来
    await pumpEventQueue();
    expect(it.pipeline.seen, hasLength(1), reason: '同一条链接只认一次');

    // 之后来的新链接照常处理。
    it.links.add(captureUri('天猫 已支付 ￥66.00'));
    await pumpEventQueue();
    expect(it.pipeline.seen, hasLength(2));

    await it.service.start(); // 幂等
    expect(it.pipeline.seen, hasLength(2));
  });

  test('(g2) 没有冷启动链接也要 drain 一次（快捷指令只是把 App 打开）', () async {
    final it = build();
    pending = [share('叮咚买菜 已支付 ￥52.00', source: 'shortcut')];

    await it.service.start();

    expect(calls, ['takePending']);
    expect(it.pipeline.seen.single.packageName, 'ios.shortcut');
  });

  test('(g3) 冷启动那条在 start() 还没跑完时就被流回放 → 仍然只认一次', () async {
    const text = '顺丰 已支付 ￥12.00';
    final initial = captureUri(text);
    final pipeline = _RecordingPipeline();
    final links = StreamController<Uri>.broadcast();
    addTearDown(links.close);

    var readCount = 0;
    var handleCount = 0;
    final service = ShareImportService(
      pipeline: () async {
        // 订阅已经建好、正在处理冷启动那条时，流把同一条又推了一遍。
        if (handleCount++ == 0) {
          links.add(initial);
          await pumpEventQueue();
        }
        return pipeline;
      },
      channel: SharePendingChannel(channel: channel, supported: true, now: () => clock),
      linkStream: links.stream,
      initialLink: () async {
        // 读冷启动链接还没返回时就回放（这时还没订阅，广播流直接丢掉）。
        readCount++;
        links.add(initial);
        await pumpEventQueue();
        return initial;
      },
      now: () => clock,
      observeLifecycle: false,
    );
    addTearDown(service.dispose);

    await service.start();
    await pumpEventQueue();

    expect(readCount, 1);
    expect(handleCount, 1);
    expect(pipeline.seen.map((r) => r.text), [text], reason: '同一条冷启动链接只能记一次');
    expect(calls, ['takePending']);

    // 守卫用掉之后，真正的新链接照常处理。
    links.add(captureUri('德邦 已支付 ￥30.00'));
    await pumpEventQueue();
    expect(pipeline.seen, hasLength(2));
  });

  test('(g4) 守卫超过 replayWindow 就作废，不会吃掉后来的同一条链接', () async {
    const text = '菜鸟 已支付 ￥9.90';
    final initial = captureUri(text);
    final pipeline = _RecordingPipeline();
    final links = StreamController<Uri>.broadcast();
    addTearDown(links.close);

    final service = ShareImportService(
      pipeline: () async => pipeline,
      channel: SharePendingChannel(channel: channel, supported: true, now: () => clock),
      linkStream: links.stream,
      initialLink: () async => initial,
      now: () => clock,
      observeLifecycle: false,
      replayWindow: const Duration(seconds: 10),
    );
    addTearDown(service.dispose);

    await service.start();
    expect(pipeline.seen, hasLength(1));

    // 半分钟后用户又分享了同一段文本：这不是回放，得照常走管线（重不重复由管线判）。
    clock = clock.add(const Duration(seconds: 30));
    links.add(initial);
    await pumpEventQueue();
    expect(pipeline.seen, hasLength(2));
  });

  test('(h) 没登录 / 管线抛异常：给一条结论，不把流程炸掉', () async {
    var mode = 0;
    final service = ShareImportService(
      pipeline: () async => switch (mode) {
        0 => null,
        _ => throw StateError('装配失败'),
      },
      channel: SharePendingChannel(channel: channel, supported: true),
      linkStream: const Stream<Uri>.empty(),
      initialLink: () async => null,
      observeLifecycle: false,
    );
    addTearDown(service.dispose);
    final outcomes = <CaptureOutcome>[];
    service.outcomes.listen(outcomes.add);

    expect((await service.importText('随便', source: 'share'))?.title, '家账还没登录');
    mode = 1;
    expect((await service.importText('随便', source: 'share'))?.title, '导入失败');
    expect(await service.importText('   ', source: 'share'), isNull);

    await pumpEventQueue();
    expect(outcomes.map((o) => o.decision), [
      CaptureDecision.ignored,
      CaptureDecision.ignored,
    ]);
  });

  test('(i) PendingShare.fromMap：空文本丢掉，时间解析不了用当下', () {
    expect(PendingShare.fromMap({'text': '  ', 'source': 'share'}), isNull);
    final ok = PendingShare.fromMap({
      'text': '喜茶 ￥19',
      'source': 'shortcut',
      'receivedAt': '2026-09-13T12:00:00Z',
    });
    expect(ok!.source, 'shortcut');
    expect(ok.receivedAt.toUtc(), DateTime.utc(2026, 9, 13, 12));
    final fallback = PendingShare.fromMap(
      {'text': '喜茶 ￥19', 'receivedAt': '不是时间'},
      now: () => clock,
    );
    expect(fallback!.source, 'share');
    expect(fallback.receivedAt, clock);
  });
}

/// 只记下收到什么、不真的记账的管线。
class _RecordingPipeline extends CapturePipeline {
  _RecordingPipeline()
    : super(
        store: MemoryCaptureStore(),
        api: const _NoopApi(),
        classifier: Classifier(
          categoryModel: NaiveBayes.empty(),
          fundModel: NaiveBayes.empty(),
          rules: const <CaptureRule>[],
          categories: const <ClassifierCandidate>[],
          funds: const <ClassifierCandidate>[],
          accounts: const <CaptureAccount>[],
        ),
        config: const CapturePipelineConfig(memberId: 'm1'),
      );

  final List<RawNotification> seen = <RawNotification>[];

  @override
  Future<CaptureOutcome> handle(RawNotification notification) async {
    seen.add(notification);
    return const CaptureOutcome(
      decision: CaptureDecision.recorded,
      title: '已记一笔',
      body: '',
      captureId: 'cap-1',
    );
  }
}

class _NoopApi implements CaptureApi {
  const _NoopApi();

  @override
  Future<CaptureApiResult> createTransaction(Map<String, dynamic> body) async =>
      const CaptureApiResult(id: 'tx-1');

  @override
  Future<void> patchTransaction(String id, Map<String, dynamic> patch) async {}

  @override
  Future<void> confirmTransaction(String id) async {}

  @override
  Future<void> deleteTransaction(String id) async {}

  @override
  Future<void> learn(List<LearnSample> samples) async {}

  @override
  Future<Map<String, dynamic>?> aiClassify(Map<String, dynamic> input) async => null;
}
