import 'dart:async';
import 'dart:convert';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../capture/parser.dart';
import '../capture/pipeline.dart';
import '../data/models/models.dart';
import 'capture_adapters.dart';
import 'capture_providers.dart';
import 'http_capture_api.dart';
import 'share_channel.dart';

/// iOS 的三条「手动喂一段文本」入口（docs/ios.md §8）：分享扩展 / 快捷指令 / 剪贴板。
///
/// iOS 读不到别的 App 的通知，所以自动记账在这里退化成：
/// 用户把支付页文本分享 / 复制过来 → 走**同一条** [CapturePipeline]，结果照常出通知。

const String kShareSourceShare = 'share';
const String kShareSourceShortcut = 'shortcut';
const String kShareSourceClipboard = 'clipboard';

/// 深链 scheme / host：`famledger://capture?source=…[&text=…]`。
const String kCaptureUriScheme = 'famledger';
const String kCaptureUriHost = 'capture';

/// 三条入口在管线里的固定 packageName。
///
/// 管线自带的 `captureHash(packageName, normalizedText)` + 10 分钟窗口是最后一道去重，
/// **每条入口的 packageName 必须固定**，换来换去这层就白做了。
/// 这三个名字没登记在 `SourceProfile.all` 里，会回落到 `generic` 档 —— 正是要的通用解析。
String capturePackageForSource(String source) => switch (source) {
  kShareSourceShortcut => 'ios.shortcut',
  kShareSourceClipboard => 'ios.clipboard',
  _ => 'ios.share',
};

/// 取管线：没登录（或装配不出来）返回 null。注入进来，不走全局单例。
typedef CapturePipelineGetter = Future<CapturePipeline?> Function();

/// 分享 / 快捷指令 / 剪贴板 → [CapturePipeline] 的接线。
///
/// 消费顺序严格按 docs/ios.md §8.3：
/// 1. 每次触发（深链到达 / 冷启动 / 从后台恢复）**先** `takePending()`（读完即清）；
/// 2. 本次是带 `text=` 的深链 → 以 URL 里的为准导入，并丢掉 store 里那条一模一样的副本
///    （扩展是「既写 App Group 又带 URL」的双保险，不丢就会重复记账）；
/// 3. 没带 `text=`（超长）或压根没有深链（快捷指令 `openAppWhenRun` 只是把 App 打开）
///    → store 里的全部导入。
///
/// 另外记住「最近一次从 URL 导入的文本 + 时间」（默认 10 分钟）：扩展写盘比深链慢的时候，
/// 那份副本会在下一次触发才被 `takePending()` 带出来，靠这份记忆丢掉。
class ShareImportService with WidgetsBindingObserver {
  ShareImportService({
    required CapturePipelineGetter pipeline,
    SharePendingChannel? channel,
    Stream<Uri>? linkStream,
    Future<Uri?> Function()? initialLink,
    Future<bool> Function(String captureId)? onOpenCapture,
    DateTime Function()? now,
    bool? deepLinksEnabled,
    this.observeLifecycle = true,
    this.urlMemory = const Duration(minutes: 10),
    this.replayWindow = const Duration(seconds: 10),
  }) : _pipeline = pipeline,
       _channel = channel ?? const SharePendingChannel(),
       _linkStream = linkStream,
       _initialLink = initialLink,
       _onOpenCapture = onOpenCapture,
       _now = now ?? DateTime.now,
       // Android 的 `famledger://` 由 `MainActivity` 原生翻译，Dart 再听一遍会重复；
       // 所以只有 iOS（和显式注入了流的测试）走这条腿。
       _deepLinksEnabled =
           deepLinksEnabled ??
           (linkStream != null ||
               initialLink != null ||
               (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS));

  final CapturePipelineGetter _pipeline;
  final SharePendingChannel _channel;
  final Stream<Uri>? _linkStream;
  final Future<Uri?> Function()? _initialLink;
  final Future<bool> Function(String captureId)? _onOpenCapture;
  final DateTime Function() _now;
  final bool _deepLinksEnabled;

  /// 自己注册 [WidgetsBindingObserver]：外面不额外接生命周期钩子也能在恢复前台时补一次。
  final bool observeLifecycle;

  /// 「最近一次 URL 导入」的记忆时长（与管线默认去重窗口一致）。
  final Duration urlMemory;

  /// 冷启动深链防回放守卫的有效期：流里迟迟不回放就别一直挡着。
  final Duration replayWindow;

  final StreamController<CaptureOutcome> _outcomes =
      StreamController<CaptureOutcome>.broadcast();

  AppLinks? _appLinks;
  StreamSubscription<Uri>? _sub;
  bool _started = false;
  bool _disposed = false;
  bool _observing = false;

  /// 冷启动那条深链：app_links 6.x 的流**也会**把它再发一次，认一次就够。
  /// 守卫在整个冷启动窗口内有效（[replayWindow]），直到流里真的回放了它、
  /// 或者来了别的链接为止。
  Uri? _replayGuard;
  DateTime? _replayGuardAt;

  String? _lastUrlText;
  DateTime? _lastUrlAt;

  /// 串行化：恢复前台与深链同时到达时，`takePending()`（读完即清）不能交叉。
  Future<void> _chain = Future<void>.value();

  /// 每条导入的结论，交给界面出本地通知 / SnackBar。
  Stream<CaptureOutcome> get outcomes => _outcomes.stream;

  /// 这台设备走不走 Dart 侧深链（只有 iOS；Android 由 `MainActivity` 原生翻译）。
  bool get deepLinksEnabled => _deepLinksEnabled;

  /// App 起来时调一次（幂等）：订阅深链 + 冷启动链接 + 先 drain 一次 App Group。
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;

    if (observeLifecycle && !_observing) {
      try {
        WidgetsBinding.instance.addObserver(this);
        _observing = true;
      } catch (e) {
        debugPrint('share import: 注册生命周期观察者失败 $e');
      }
    }

    if (_deepLinksEnabled) {
      // 顺序不能反：先把冷启动那条读回来、立起防回放的守卫，**再**订阅。
      // 反过来的话，`_readInitialLink()` 还没返回时流里回放的那条会被当成新链接，
      // 同一条就记两次。
      final initial = await _readInitialLink();
      final replay = initial != null && isCaptureUri(initial);
      if (replay) {
        _replayGuard = initial;
        _replayGuardAt = _now();
      }
      try {
        _sub = _links().listen(
          _onLink,
          onError: (Object e) => debugPrint('app_links 出错: $e'),
        );
      } on MissingPluginException {
        // 没装 app_links 的平台：深链这条腿直接不要。
      } catch (e) {
        debugPrint('app_links 订阅失败: $e');
      }
      if (replay) {
        await handleLink(initial);
        return; // handleLink 里已经 drain 过一次
      }
    }

    // 冷启动照样 drain：快捷指令 `openAppWhenRun` 不产生深链。
    await _serialized(() => _consume());
  }

  /// 从后台恢复前台时调（自己注册的观察者也会调，重复调没关系）。
  Future<void> onResumed() async {
    if (_disposed) return;
    await _serialized(() => _consume());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(onResumed());
  }

  /// 设置页「还有 N 条未消费」：只看不清。
  Future<List<PendingShare>> peekPending() => _channel.peek();

  /// 设置页「立即导入」：drain 一遍 App Group，返回导入条数。
  Future<int> importPending() => _serialized(() => _consume());

  /// 设置页「从剪贴板导入」。剪贴板是空的（或读不到）返回 null。
  Future<CaptureOutcome?> importFromClipboard() async {
    String? text;
    try {
      text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } on MissingPluginException {
      text = null;
    } on PlatformException catch (e) {
      debugPrint('读剪贴板失败: ${e.message}');
      text = null;
    }
    if (text == null || text.trim().isEmpty) return null;
    return importText(text, source: kShareSourceClipboard);
  }

  /// 把一段文本喂给管线。文本是空的返回 null，其余情况总有结论（失败也给一条）。
  Future<CaptureOutcome?> importText(
    String text, {
    required String source,
    DateTime? receivedAt,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    CaptureOutcome outcome;
    try {
      final pipeline = await _pipeline();
      if (pipeline == null) {
        outcome = _notLoggedIn;
      } else {
        outcome = await pipeline.handle(
          RawNotification(
            packageName: capturePackageForSource(source),
            title: '', // 这三条入口没有「通知标题」
            text: trimmed,
            bigText: '',
            postedAt: (receivedAt ?? _now()).toLocal(),
          ),
        );
      }
    } catch (e, st) {
      debugPrint('分享导入失败: $e\n$st');
      outcome = CaptureOutcome(
        decision: CaptureDecision.ignored,
        title: '导入失败',
        body: _short(e),
      );
    }
    if (!_outcomes.isClosed) _outcomes.add(outcome);
    return outcome;
  }

  /// 处理一条深链（只认 `famledger://capture…`，别的原样放过）。
  Future<void> handleLink(Uri uri) async {
    if (!isCaptureUri(uri)) return;
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isNotEmpty) {
      // `famledger://capture/<captureId>`：点结果通知打开详情，不是待导入文本。
      await _onOpenCapture?.call(segments.first);
      return;
    }
    final text = uri.queryParameters.containsKey('text') ? captureUriText(uri) : null;
    final source = uri.queryParameters['source']?.trim();
    await _serialized(
      () => _consume(
        urlText: text,
        source: source == null || source.isEmpty ? kShareSourceShare : source,
      ),
    );
  }

  /// 这条 URI 是不是我们的捕获深链。
  static bool isCaptureUri(Uri uri) =>
      uri.scheme.toLowerCase() == kCaptureUriScheme &&
      uri.host.toLowerCase() == kCaptureUriHost;

  /// 取 `text=` 的原文。
  ///
  /// 原生转义时**特意**把 `+` 也转成了 `%2B`，所以这里用 [Uri.decodeComponent]
  /// （不把 `+` 当空格）才是它的逆运算；解不开就退回 `queryParameters`。
  static String? captureUriText(Uri uri) {
    for (final pair in uri.query.split('&')) {
      final i = pair.indexOf('=');
      if (i <= 0 || pair.substring(0, i) != 'text') continue;
      final raw = pair.substring(i + 1);
      try {
        return Uri.decodeComponent(raw);
      } on ArgumentError {
        return uri.queryParameters['text'];
      } on FormatException {
        return uri.queryParameters['text'];
      }
    }
    return null;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_sub?.cancel());
    _sub = null;
    if (_observing) {
      try {
        WidgetsBinding.instance.removeObserver(this);
      } catch (_) {
        // 绑定已经没了，无所谓。
      }
      _observing = false;
    }
    unawaited(_outcomes.close());
  }

  // ------------------------------------------------------------ 内部

  void _onLink(Uri uri) {
    if (_isInitialReplay(uri)) return;
    unawaited(handleLink(uri));
  }

  /// app_links 的流会把冷启动那条再发一遍，`start()` 已经认过了。
  ///
  /// 只有「确实是同一条 + 还在冷启动窗口内」才跳过；不匹配（或超窗）说明冷启动那阵
  /// 已经过去，守卫作废后照常处理 —— 绝不能让守卫吃掉一条真正的新链接。
  bool _isInitialReplay(Uri uri) {
    final initial = _replayGuard;
    final at = _replayGuardAt;
    if (initial == null || at == null) return false;
    final matched = uri == initial && _now().difference(at) < replayWindow;
    _replayGuard = null;
    _replayGuardAt = null;
    return matched;
  }

  Stream<Uri> _links() => _linkStream ?? (_appLinks ??= AppLinks()).uriLinkStream;

  Future<Uri?> _readInitialLink() async {
    try {
      final reader = _initialLink;
      if (reader != null) return await reader();
      if (_linkStream != null) return null; // 注入了流就只认流
      return await (_appLinks ??= AppLinks()).getInitialLink();
    } on MissingPluginException {
      return null;
    } catch (e) {
      debugPrint('读冷启动深链失败: $e');
      return null;
    }
  }

  /// docs 8.3 的三步走。返回这次导入了几条。
  Future<int> _consume({String? urlText, String source = kShareSourceShare}) async {
    // 1. 先 drain（读完即清）。
    final pending = await _channel.take();
    var imported = 0;

    // 2. URL 带了 text 就以它为准，并记住，下面那份副本才丢得掉。
    // 整条链路只在这里把 URL 文本归一化一次：`_lastUrlText` 存的就是这份。
    final text = urlText?.trim() ?? '';
    if (text.isNotEmpty) {
      _lastUrlText = text;
      _lastUrlAt = _now();
      await importText(text, source: source);
      imported++;
    }

    // 3. 其余照常导入（跳过刚从 URL 进去的那份副本，含迟到的）。
    for (final item in pending) {
      if (_isRecentUrlCopy(item.text)) continue;
      await importText(item.text, source: item.source, receivedAt: item.receivedAt);
      imported++;
    }
    return imported;
  }

  bool _isRecentUrlCopy(String text) {
    final last = _lastUrlText;
    final at = _lastUrlAt;
    if (last == null || at == null) return false;
    if (_now().difference(at) >= urlMemory) return false;
    // `last` 存进来时已经归一化过，这里只归一化原生给的那份。
    return last == text.trim();
  }

  Future<T> _serialized<T>(Future<T> Function() task) {
    final result = _chain.then((_) => task());
    _chain = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  static const CaptureOutcome _notLoggedIn = CaptureOutcome(
    decision: CaptureDecision.ignored,
    title: '家账还没登录',
    body: '登录后才能把分享过来的内容记成流水',
  );

  static String _short(Object e) {
    final s = '$e';
    return s.length > 120 ? '${s.substring(0, 120)}…' : s;
  }
}

/// 分享导入服务。`main()` / 外壳起来后调一次 `ref.read(shareImportProvider).start()`。
final shareImportProvider = Provider<ShareImportService>((ref) {
  final pipeline = _UiPipeline(ref);
  final service = ShareImportService(
    pipeline: pipeline.get,
    onOpenCapture: (captureId) => openCaptureRoute(ref, captureId),
  );
  ref.onDispose(service.dispose);
  return service;
});

/// 主引擎里的管线（headless 那份在 `CaptureRuntime`，两边共用同一个 [LocalCaptureStore]）。
///
/// 会话 / 主数据 / 抓取设置任一变化就重建，其余时候复用 —— `bootstrap()` 要读模型、
/// 没有还要训一份种子，每导入一条都重来太浪费。
class _UiPipeline {
  _UiPipeline(this._ref);

  final Ref _ref;
  CapturePipeline? _pipeline;
  String? _stamp;

  Future<CapturePipeline?> get() async {
    final session = _ref.read(sessionProvider);
    if (session == null) return null;
    final store = await _ref.read(captureStoreProvider.future);
    final ledger = await _ref.read(ledgerProvider.future);
    final settings = (await _settings()).capture;
    final stamp = <Object>[
      session.token.hashCode,
      session.me.id,
      ledger.seq,
      jsonEncode(settings.toJson()),
    ].join('|');
    final cached = _pipeline;
    if (cached != null && stamp == _stamp) return cached;
    final pipeline = await buildPipeline(
      store: store,
      api: HttpCaptureApi(
        _ref.read(apiProvider),
        aiEnabled: settings.aiTrigger != 'off',
        providerId: settings.aiProviderId,
      ),
      ledger: ledger,
      settings: settings,
      memberId: session.me.id,
    );
    _pipeline = pipeline;
    _stamp = stamp;
    return pipeline;
  }

  /// 设置拉不到（离线且没缓存过）就用默认值：本地记账不该被网络卡住。
  Future<Settings> _settings() async {
    try {
      return await _ref.read(settingsProvider.future);
    } catch (_) {
      try {
        return await _ref.read(settingsRepoProvider).cached() ?? const Settings();
      } catch (_) {
        return const Settings();
      }
    }
  }
}
