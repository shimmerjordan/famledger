import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/router.dart';
import '../capture/accuracy_stats.dart';
import '../capture/headless_main.dart';
import '../capture/pipeline.dart' show kAccuracyModelKey;
import 'capture_channel.dart';
import 'file_capture_store.dart';

/// headless 引擎的入口必须落在主程序的 import 闭包里：`main.dart` 不引它的话，
/// AOT 会把整个库裁掉、JIT 也找不到（`Could not resolve main entrypoint function`）。
/// 这里引用一下就够了，`@pragma('vm:entry-point')` 负责不让它被裁。
const Function headlessEntrypoint = captureMain;

/// 原生能力。Android 上是 MethodChannel；其他平台一律「不支持」。
///
/// 收到 `onOpenCapture(captureId)` 时：查本地捕获记录拿到流水 id → 打开详情页；
/// 还没同步出流水 id 就回首页看「待确认」。
final capturePlatformProvider = Provider<CapturePlatform>((ref) {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
    return const UnsupportedCapturePlatform();
  }
  final platform = MethodChannelCapturePlatform(
    onOpenCapture: (captureId) => openCaptureRoute(ref, captureId),
  );
  ref.onDispose(platform.dispose);
  return platform;
});

/// captureId → 详情页路由；返回 true 表示已导航（原生就不再自己推路由）。
Future<bool> openCaptureRoute(Ref ref, String captureId) async {
  try {
    final store = await ref.read(captureStoreProvider.future);
    final record = await store.loadCapture(captureId);
    final txId = record?.transactionId;
    ref.read(routerProvider).push(txId == null ? '/home' : '/transactions/$txId');
    return true;
  } catch (_) {
    return false;
  }
}

/// 本地捕获存储（与 headless 引擎共用同一目录）。
final captureStoreProvider = FutureProvider<LocalCaptureStore>((ref) => FileCaptureStore.open());

/// 最近捕获日志（新的在前，≤ 50 条）。
final recentCapturesProvider = FutureProvider.autoDispose<List<CaptureLogEntry>>((ref) async {
  final store = await ref.watch(captureStoreProvider.future);
  return store.recent();
});

/// 「本地规则/本地模型/AI 兜底」最近谁准——设置页那块只读面板用。
final accuracyStatsProvider = FutureProvider.autoDispose<AccuracyStats>((ref) async {
  final store = await ref.watch(captureStoreProvider.future);
  final json = await store.loadModel(kAccuracyModelKey);
  return json == null ? AccuracyStats.empty() : AccuracyStats.fromJson(json);
});

final listenerEnabledProvider = FutureProvider.autoDispose<bool>(
  (ref) => ref.watch(capturePlatformProvider).isListenerEnabled(),
);

final notificationPermissionProvider = FutureProvider.autoDispose<NotificationPermission>(
  (ref) => ref.watch(capturePlatformProvider).notificationPermission(),
);

final deviceInfoProvider = FutureProvider<DeviceInfo>(
  (ref) => ref.watch(capturePlatformProvider).deviceInfo(),
);

final allowedPackagesProvider = FutureProvider.autoDispose<List<String>>(
  (ref) => ref.watch(capturePlatformProvider).getAllowedPackages(),
);

/// 可启动的应用列表（查一次就够，几百个应用的图标标签读起来不算快）。
final installedAppsProvider = FutureProvider<List<InstalledApp>>(
  (ref) => ref.watch(capturePlatformProvider).getInstalledApps(),
);
