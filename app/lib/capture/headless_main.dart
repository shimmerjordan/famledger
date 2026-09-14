import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../data/local/local_store.dart';
import '../data/local/secure_store.dart';
import '../platform/capture_channel.dart';
import '../platform/capture_runtime.dart';
import '../platform/file_capture_store.dart';

/// headless 引擎的 Dart 入口（`HeadlessEngine.kt` 用 `DartEntrypoint(..., "captureMain")` 启动）。
///
/// 没有界面：只在 `com.famledger/capture` 上应答原生的
/// `onNotification` / `onAction` / `onModelSync`（调试构建另有 `onE2eLogin`），
/// 准备好后调一次 `headlessReady`，原生那头排队的事件才会放进来。
@pragma('vm:entry-point')
Future<void> captureMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(kCaptureChannelName);

  CaptureRuntime? runtime;
  Object? bootError;
  try {
    runtime = CaptureRuntime(
      secure: await SecureStore.open(),
      cache: await LocalStore.open(),
      store: await FileCaptureStore.open(),
    );
  } catch (e, st) {
    bootError = e;
    debugPrint('captureMain: 初始化失败 $e\n$st');
  }

  channel.setMethodCallHandler((call) async {
    final rt = runtime;
    if (rt == null) {
      return CaptureRuntime.errorResponse('自动记账初始化失败', '$bootError');
    }
    switch (call.method) {
      case 'onNotification':
        return rt.handleNotification(call.arguments);
      case 'onAction':
        return rt.handleAction(call.arguments);
      case 'onModelSync':
        return rt.syncModel();
      case 'onE2eLogin':
        return rt.e2eLogin(call.arguments);
      default:
        throw MissingPluginException('${call.method} 不在 headless 契约里');
    }
  });

  await channel.invokeMethod<void>('headlessReady');

  // 引擎一起来就把上次离线攒下的动作 / 学习样本补发出去（没登录或没积压就什么都不做）。
  final rt = runtime;
  if (rt != null) unawaited(rt.replayPending());
}
