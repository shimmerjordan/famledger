import 'dart:async';

import 'package:flutter/services.dart';

/// `com.famledger/capture` —— 与 `android/.../capture/CapturePlugin.kt` 一一对应。
const String kCaptureChannelName = 'com.famledger/capture';

/// Android 13+ 的 POST_NOTIFICATIONS 状态；更早的系统不需要申请。
enum NotificationPermission { granted, denied, notRequired }

/// 可启动的应用（设置页「允许的应用」多选用）。
class InstalledApp {
  const InstalledApp({required this.package, required this.label});

  final String package;
  final String label;

  factory InstalledApp.fromMap(Map<dynamic, dynamic> map) => InstalledApp(
    package: '${map['package'] ?? ''}',
    label: '${map['label'] ?? map['package'] ?? ''}',
  );
}

class DeviceInfo {
  const DeviceInfo({
    this.manufacturer = '',
    this.brand = '',
    this.sdkInt = 0,
    this.debug = false,
  });

  final String manufacturer;
  final String brand;
  final int sdkInt;

  /// 原生是否 debug 构建（决定「发送测试通知」是否真的会发）。
  final bool debug;

  factory DeviceInfo.fromMap(Map<dynamic, dynamic> map) => DeviceInfo(
    manufacturer: '${map['manufacturer'] ?? ''}',
    brand: '${map['brand'] ?? ''}',
    sdkInt: (map['sdkInt'] as num?)?.toInt() ?? 0,
    debug: map['debug'] == true,
  );

  /// 小米 / Redmi / POCO：需要额外引导自启动与省电策略。
  bool get isMiui {
    final m = manufacturer.toLowerCase();
    final b = brand.toLowerCase();
    return m.contains('xiaomi') || b == 'xiaomi' || b == 'redmi' || b == 'poco';
  }
}

/// 自动记账的原生能力。Android 走 [MethodChannelCapturePlatform]，
/// 其余平台是 [UnsupportedCapturePlatform]；测试里随便换一个假的。
abstract class CapturePlatform {
  /// 这台设备能不能读其他应用的通知（只有 Android 能）。
  bool get isSupported;

  Future<bool> isListenerEnabled();
  Future<void> openListenerSettings();

  /// MIUI 自启动/省电页；跳不过去回落到应用详情。返回实际打开的页面名。
  Future<String> openAutoStartSettings();
  Future<List<String>> getAllowedPackages();
  Future<void> setAllowedPackages(List<String> packages);
  Future<List<InstalledApp>> getInstalledApps();

  /// 仅调试构建有效：从自家渠道发一条假支付通知给监听器。返回是否真的发了。
  Future<bool> postTestNotification(String title, String text);
  Future<NotificationPermission> notificationPermission();
  Future<void> requestNotificationPermission();
  Future<DeviceInfo> deviceInfo();

  /// 用户点了结果通知：原生把 captureId 递过来。
  Stream<String> get openCapture;
}

/// Android 实现。
class MethodChannelCapturePlatform implements CapturePlatform {
  MethodChannelCapturePlatform({
    MethodChannel channel = const MethodChannel(kCaptureChannelName),
    this.onOpenCapture,
  }) : _channel = channel {
    _channel.setMethodCallHandler(_handle);
  }

  final MethodChannel _channel;

  /// 收到 `onOpenCapture` 时的处理（一般是导航）。返回 true 表示 Dart 已处理，
  /// 原生就不再自己推路由。
  final Future<bool> Function(String captureId)? onOpenCapture;

  final StreamController<String> _openCapture = StreamController<String>.broadcast();

  @override
  bool get isSupported => true;

  @override
  Stream<String> get openCapture => _openCapture.stream;

  Future<dynamic> _handle(MethodCall call) async {
    switch (call.method) {
      case 'onOpenCapture':
        final captureId = '${call.arguments ?? ''}';
        if (captureId.isEmpty) return false;
        _openCapture.add(captureId);
        final handler = onOpenCapture;
        if (handler == null) return false;
        return handler(captureId);
      default:
        throw MissingPluginException('${call.method} 不在主引擎契约里');
    }
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
    _openCapture.close();
  }

  @override
  Future<bool> isListenerEnabled() async =>
      await _channel.invokeMethod<bool>('isListenerEnabled') ?? false;

  @override
  Future<void> openListenerSettings() => _channel.invokeMethod<void>('openListenerSettings');

  @override
  Future<String> openAutoStartSettings() async =>
      await _channel.invokeMethod<String>('openAutoStartSettings') ?? '';

  @override
  Future<List<String>> getAllowedPackages() async {
    final raw = await _channel.invokeMethod<List<dynamic>>('getAllowedPackages');
    return raw == null ? const <String>[] : raw.map((e) => '$e').toList();
  }

  @override
  Future<void> setAllowedPackages(List<String> packages) =>
      _channel.invokeMethod<void>('setAllowedPackages', packages);

  @override
  Future<List<InstalledApp>> getInstalledApps() async {
    final raw = await _channel.invokeMethod<List<dynamic>>('getInstalledApps');
    return raw == null
        ? const <InstalledApp>[]
        : raw.whereType<Map<dynamic, dynamic>>().map(InstalledApp.fromMap).toList();
  }

  @override
  Future<bool> postTestNotification(String title, String text) async =>
      await _channel.invokeMethod<bool>('postTestNotification', {'title': title, 'text': text}) ?? false;

  @override
  Future<NotificationPermission> notificationPermission() async {
    final raw = await _channel.invokeMethod<String>('notificationPermission');
    return switch (raw) {
      'granted' => NotificationPermission.granted,
      'denied' => NotificationPermission.denied,
      _ => NotificationPermission.notRequired,
    };
  }

  @override
  Future<void> requestNotificationPermission() =>
      _channel.invokeMethod<void>('requestNotificationPermission');

  @override
  Future<DeviceInfo> deviceInfo() async {
    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>('deviceInfo');
    return raw == null ? const DeviceInfo() : DeviceInfo.fromMap(raw);
  }
}

/// iOS / Web / 桌面：系统不允许读其他应用的通知，全部按「不支持」回答。
class UnsupportedCapturePlatform implements CapturePlatform {
  const UnsupportedCapturePlatform();

  @override
  bool get isSupported => false;

  @override
  Stream<String> get openCapture => const Stream<String>.empty();

  @override
  Future<bool> isListenerEnabled() async => false;

  @override
  Future<void> openListenerSettings() async {}

  @override
  Future<String> openAutoStartSettings() async => '';

  @override
  Future<List<String>> getAllowedPackages() async => const <String>[];

  @override
  Future<void> setAllowedPackages(List<String> packages) async {}

  @override
  Future<List<InstalledApp>> getInstalledApps() async => const <InstalledApp>[];

  @override
  Future<bool> postTestNotification(String title, String text) async => false;

  @override
  Future<NotificationPermission> notificationPermission() async =>
      NotificationPermission.notRequired;

  @override
  Future<void> requestNotificationPermission() async {}

  @override
  Future<DeviceInfo> deviceInfo() async => const DeviceInfo();
}
