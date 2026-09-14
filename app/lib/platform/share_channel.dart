import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// `com.famledger/share` —— 与 `ios/Runner/AppDelegate.swift` 里的 `PendingShareStore` 一一对应
/// （契约见 `docs/ios.md` §2、§8.2）。只有 iOS 注册了这个通道。
const String kShareChannelName = 'com.famledger/share';

/// App Group 里攒着的一条待导入文本。
///
/// 写入方是分享扩展（`ios/ShareExtension/ShareViewController.swift`）和快捷指令
/// （`ios/Runner/ShortcutIntents.swift`）；读取方只有 Dart。
class PendingShare {
  const PendingShare({
    required this.text,
    required this.source,
    required this.receivedAt,
  });

  /// 分享 / 快捷指令传来的原文。
  final String text;

  /// `share` | `shortcut`（剪贴板不走 App Group，直接在 Dart 侧读）。
  final String source;

  /// 原生写入的时间（ISO8601 UTC），这里统一转成本地时间。
  final DateTime receivedAt;

  /// 通道返回的是**已经解析好的** `List<Map>`，不需要再 jsonDecode。
  /// 文本为空的条目直接丢掉（原生不该写，但别让它污染管线）。
  static PendingShare? fromMap(Map<dynamic, dynamic> map, {DateTime Function()? now}) {
    final text = '${map['text'] ?? ''}';
    if (text.trim().isEmpty) return null;
    final raw = '${map['receivedAt'] ?? ''}';
    final parsed = DateTime.tryParse(raw);
    return PendingShare(
      text: text,
      source: '${map['source'] ?? 'share'}',
      receivedAt: parsed?.toLocal() ?? (now ?? DateTime.now)(),
    );
  }

  @override
  String toString() => 'PendingShare($source, ${text.length} 字, $receivedAt)';
}

/// iOS 的「待处理分享」通道。
///
/// 其它平台（Android / Web / 桌面 / 测试）根本没有这个通道：`isSupported` 为 false 时
/// 一次 `invokeMethod` 都不发，返回空。即便被强制打开，`MissingPluginException`
/// （原生没注册）和 `PlatformException`（原生报错）也都吞掉 —— 导入是锦上添花，
/// 不能因为通道不在就把分享流程整个炸掉。
class SharePendingChannel {
  const SharePendingChannel({
    MethodChannel channel = const MethodChannel(kShareChannelName),
    bool? supported,
    DateTime Function()? now,
  }) : _channel = channel,
       _supported = supported,
       _now = now;

  final MethodChannel _channel;
  final bool? _supported;
  final DateTime Function()? _now;

  /// 只有 iOS 有 App Group 与分享扩展；`supported` 显式给值时以它为准（测试用）。
  bool get isSupported =>
      _supported ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS);

  /// `takePending`：读完即清。每次触发导入都必须先调它（docs 8.3 第 1 步）。
  Future<List<PendingShare>> take() => _list('takePending');

  /// `peekPending`：只看不清，设置页排查 App Group 有没有打通时用。
  Future<List<PendingShare>> peek() => _list('peekPending');

  /// `clearPending`：把攒着的全丢掉（用户手动清）。
  Future<void> clear() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('clearPending');
    } on MissingPluginException {
      // 原生没注册（还没在 Xcode 里接上 target）：当作没有待处理内容。
    } on PlatformException catch (e) {
      debugPrint('clearPending failed: ${e.message}');
    }
  }

  Future<List<PendingShare>> _list(String method) async {
    if (!isSupported) return const <PendingShare>[];
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>(method);
      if (raw == null) return const <PendingShare>[];
      final shares = <PendingShare>[];
      for (final item in raw) {
        if (item is! Map) continue;
        final share = PendingShare.fromMap(item, now: _now);
        if (share != null) shares.add(share);
      }
      return shares;
    } on MissingPluginException {
      return const <PendingShare>[];
    } on PlatformException catch (e) {
      debugPrint('$method failed: ${e.message}');
      return const <PendingShare>[];
    }
  }
}
