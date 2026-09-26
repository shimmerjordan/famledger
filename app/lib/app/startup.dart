import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../capture/pipeline.dart' show CaptureOutcome;
import '../platform/capture_providers.dart';
import '../platform/perk_reminders.dart';
import '../platform/share_import.dart';
import '../ui/widgets/widgets.dart';
import 'router.dart';

/// 外壳挂上时，把两条「没人拉一下就不会活」的平台接线接通：
///
/// - [capturePlatformProvider]：读一次就够 —— 它在构造时注册 MethodChannel 处理器，
///   原生的 `onOpenCapture(captureId)` 从此由 Dart 接手（查本地捕获记录 →
///   `/transactions/:id`），不必等用户打开「自动记账」设置页；随容器一起释放。
/// - [shareImportProvider]：`start()`（幂等）订阅深链 / 读冷启动链接 / drain 一次
///   App Group，并自己挂了生命周期观察者（回到前台再 drain）；`outcomes` 每出一条
///   结论就弹一条 SnackBar，有本地捕获记录的可点「查看」跳到对应流水。
///
/// - [perkReminderControllerProvider]：会员提醒（spec §5「Android 通知」）。挂上时 `start()`：初始化通知插件，
///   冷启动是点通知进来的就跳到会员权益 tab，然后排一次；回到前台 `request()` 重排（防抖 2 秒）；卸掉时收起
///   还没到点的防抖。数据变了的重排由 provider 自己听 ledger。
///
/// 两个服务在没有原生通道的平台（Web、桌面、测试）都自己吞 `MissingPluginException`
/// 且一次 `invokeMethod` 都不发，这里不再判平台（通知调度器同样：插件初始化失败就当不支持）。
/// 只包在登录后的外壳外面：没登录本来也导不进去，认证页不需要这些。
class StartupWiring extends ConsumerStatefulWidget {
  const StartupWiring({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<StartupWiring> createState() => _StartupWiringState();
}

class _StartupWiringState extends ConsumerState<StartupWiring> with WidgetsBindingObserver {
  StreamSubscription<CaptureOutcome>? _outcomes;
  late final PerkReminderController _reminders;

  @override
  void initState() {
    super.initState();
    // 读一下就完成了注册；返回值不需要。
    ref.read(capturePlatformProvider);

    final share = ref.read(shareImportProvider);
    unawaited(share.start());
    _outcomes = share.outcomes.listen(_showOutcome);

    _reminders = ref.read(perkReminderControllerProvider);
    unawaited(_reminders.start());
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 回到前台：可能已经过了一天（窗口要往后挪），也可能别的设备改过数据。
    if (state == AppLifecycleState.resumed) _reminders.request();
  }

  @override
  void dispose() {
    // 只取消自己的订阅；服务本身归 provider 管，登出再登入时 start() 是幂等的。
    unawaited(_outcomes?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    _reminders.cancelPending();
    super.dispose();
  }

  void _showOutcome(CaptureOutcome outcome) {
    if (!mounted) return;
    final captureId = outcome.captureId;
    showActionSnackBar(
      ScaffoldMessenger.of(context),
      SnackBar(
        content: Text(outcome.title),
        action: captureId == null
            ? null
            : SnackBarAction(label: '查看', onPressed: () => _open(captureId)),
      ),
    );
  }

  /// captureId → 详情页：本地捕获记录里已经有流水 id 就去 `/transactions/:id`，
  /// 还没同步出 id 就回首页看「待确认」（与 `openCaptureRoute` 同一条规则）。
  Future<void> _open(String captureId) async {
    try {
      final store = await ref.read(captureStoreProvider.future);
      final txId = (await store.loadCapture(captureId))?.transactionId;
      ref.read(routerProvider).push(txId == null ? '/home' : '/transactions/$txId');
    } catch (_) {
      // 本地记录读不到就算了：SnackBar 只是个提示，别为它抛错。
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
