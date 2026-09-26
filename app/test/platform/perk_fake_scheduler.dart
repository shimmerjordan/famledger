import 'dart:async';

import 'package:famledger/core/dates.dart';
import 'package:famledger/platform/perk_notifications.dart';

/// 假的通知调度器：按顺序记下每一次取消和排（`cancel 20260924`、`schedule 20260928 2026-09-28T09:00:00+08:00 标题`）。
/// 和插件一样：排了的进 [pending]，取消的从 [pending] 和 [shown] 里拿掉；[deliver] = 系统到点把它弹出来了。
class FakePerkScheduler implements PerkNotificationScheduler {
  FakePerkScheduler({this.launch, List<int>? pending}) : pending = pending ?? [];

  /// 冷启动时「是点这条通知进来的」。
  final String? launch;

  /// 系统里还排着的 id。
  List<int> pending;

  /// 已经弹出来、还在通知栏里的 id。
  final Set<int> shown = {};
  bool supported = true;
  int inits = 0;
  final List<String> calls = [];
  final List<PerkNotification> scheduled = [];

  /// 下一次 schedule 抛错（系统拒了、插件出错）。
  bool failNextSchedule = false;

  /// 不为 null 时 pendingIds 等它完成才回（看「排到一半」那一刻）。
  Completer<void>? gate;

  /// init 时拿到的点击回调（测试里调它 = 用户点了通知）。
  void Function(String payload)? tap;

  @override
  bool get isSupported => supported;

  @override
  Future<String?> init({required void Function(String payload) onTap}) async {
    inits++;
    tap = onTap;
    return launch;
  }

  @override
  Future<List<int>> pendingIds() async {
    final wait = gate;
    if (wait != null) await wait.future;
    return [...pending];
  }

  @override
  Future<void> cancel(int id) async {
    calls.add('cancel $id');
    pending.remove(id);
    shown.remove(id);
  }

  @override
  Future<void> schedule(PerkNotification n) async {
    if (failNextSchedule) {
      failNextSchedule = false;
      throw StateError('系统拒了');
    }
    calls.add('schedule ${n.id} ${Dates.isoLocal(n.at)} ${n.title}');
    scheduled.add(n);
    if (!pending.contains(n.id)) pending.add(n.id);
  }

  /// 系统到点把 [id] 弹出来了：不再算排着的，留在通知栏里。
  void deliver(int id) {
    pending.remove(id);
    shown.add(id);
  }

  List<String> get cancels => calls.where((c) => c.startsWith('cancel ')).toList();
  List<String> get schedules => calls.where((c) => c.startsWith('schedule ')).toList();

  void reset() {
    calls.clear();
    scheduled.clear();
  }
}
