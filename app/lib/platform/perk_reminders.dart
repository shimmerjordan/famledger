import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../app/router.dart';
import '../data/local/local_store.dart';
import '../data/models/models.dart';
import '../data/repos/ledger_repo.dart';
import '../ui/assets/asset_providers.dart';
import '../ui/perks/perk_alert_tile.dart';
import '../ui/perks/perk_providers.dart';
import 'perk_notifications.dart';

// 会员提醒的排程（spec §5「Android 通知」）：每天最多一条摘要，默认 09:00（本机设置可改）；预排未来 30 天，
// id = yyyymmdd；每次先取消整段（窗口里的 30 个 id + 系统里还排着的会员提醒）再排。启动、回到前台、数据变了
// （同步带来的、本地打卡续费的都走 ledgerProvider）、本机设置或「知道了」变了之后防抖 2 秒重排；算出来和上次
// 排的一模一样就不动。点通知去会员权益 tab 的「本期 · 我」（perkAgendaLocation）。
//
// 「今天那条」：交给系统的每条几点响记在本机（[PerkReminderController.logKey]）。今天那条的时刻已经过了 —— 弹过了，
// 或者非精确闹钟被系统推迟、还在路上 —— 就不撤它、窗口从明天起：改晚了钟点不会一天弹两条，迟到的那条也不会被撤掉又不补。
//
// 没登录不排；退出登录先撤掉排着的再删会话（app/providers.dart），没登录时冷启动也撤一遍（上次退出时进程被杀、没撤完）。

/// 本机的提醒设置（不同步：每台手机自己定几点响）。
class PerkReminderPrefs {
  const PerkReminderPrefs({this.enabled = true, this.hour = 9, this.minute = 0});

  final bool enabled;
  final int hour;
  final int minute;

  /// 「09:00」。
  String get timeLabel => '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  PerkReminderPrefs copyWith({bool? enabled, int? hour, int? minute}) =>
      PerkReminderPrefs(enabled: enabled ?? this.enabled, hour: hour ?? this.hour, minute: minute ?? this.minute);

  /// 坏值、缺的键按默认。
  factory PerkReminderPrefs.fromJson(Map<String, dynamic> json) {
    int pick(Object? raw, int max, int fallback) => raw is int && raw >= 0 && raw <= max ? raw : fallback;
    return PerkReminderPrefs(
      enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
      hour: pick(json['hour'], 23, 9),
      minute: pick(json['minute'], 59, 0),
    );
  }

  Map<String, dynamic> toJson() => {'enabled': enabled, 'hour': hour, 'minute': minute};
}

final perkReminderPrefsProvider = NotifierProvider<PerkReminderPrefsController, PerkReminderPrefs>(PerkReminderPrefsController.new);

class PerkReminderPrefsController extends Notifier<PerkReminderPrefs> {
  static const String storeKey = 'ui.perks.reminders';

  /// 读盘回来之前用户已经改过了：以用户改的为准。
  bool _touched = false;
  int _builds = 0;

  @override
  PerkReminderPrefs build() {
    // 退出登录会清空本机缓存：跟着重新读盘（读回来是空的，就是默认的开着、09:00），内存里不留上一个人的设置。
    ref.watch(localStoreEpochProvider);
    _touched = false;
    unawaited(_load(++_builds));
    return const PerkReminderPrefs();
  }

  Future<void> _load(int build) async {
    try {
      final raw = await ref.read(localStoreProvider).read<Map<String, dynamic>>(storeKey);
      if (raw != null && !_touched && build == _builds) state = PerkReminderPrefs.fromJson(raw);
    } catch (_) {
      // 读不出来就用默认。
    }
  }

  Future<void> set(PerkReminderPrefs next) async {
    _touched = true;
    state = next;
    try {
      await ref.read(localStoreProvider).write(storeKey, next.toJson());
    } catch (_) {
      // 存不下就下次回到默认。
    }
  }
}

/// 一次排程：窗口里的 30 个 id（都要先取消）和要排的那几条。
class PerkReminderPlan {
  const PerkReminderPlan({required this.windowIds, required this.notifications});

  final List<int> windowIds;
  final List<PerkNotification> notifications;

  /// 同一份计划不重排：窗口一样、每一条的 id、时刻、文案都一样。时刻按 UTC 比：进程活着时换了时区，
  /// 本地的「09:00」字面没变、对应的那一刻变了，也要重排。
  String get signature => [
    windowIds.join(','),
    for (final n in notifications) '${n.id}@${n.at.toUtc().toIso8601String()}|${n.title}|${n.body}|${n.payload}',
  ].join('\n');
}

/// 算一次排程（纯函数）：未来 30 个提醒时刻 × 当天的摘要；关掉了就只取消不排。
/// [skipToday]：今天那条已经到过点了，窗口从明天起（perkReminderSlots）。
PerkReminderPlan planPerkReminders({
  required LedgerData data,
  required DateTime now,
  required PerkReminderPrefs prefs,
  String? memberId,
  Set<String> dismissed = const {},
  bool skipToday = false,
}) {
  final slots = perkReminderSlots(now, hour: prefs.hour, minute: prefs.minute, skipToday: skipToday);
  final windowIds = [for (final s in slots) perkNotificationId(s)];
  if (!prefs.enabled) return PerkReminderPlan(windowIds: windowIds, notifications: const []);
  final digests = {
    for (final d in reminderDigests(
      memberships: data.memberships,
      benefits: data.benefits,
      events: data.benefitEvents,
      firstDay: DateTime.utc(slots.first.year, slots.first.month, slots.first.day),
      days: slots.length,
      memberId: memberId,
      dismissed: dismissed,
    ))
      perkNotificationId(d.day): d,
  };
  return PerkReminderPlan(
    windowIds: windowIds,
    notifications: [
      for (final s in slots)
        if (digests[perkNotificationId(s)] case final d?)
          PerkNotification(id: perkNotificationId(s), at: s, title: d.title, body: d.body, payload: perkAgendaLocation),
    ],
  );
}

/// 排程要读的几样，一次取齐；ledger 还没加载出来时是 null（先不排）。
class PerkReminderInputs {
  const PerkReminderInputs({required this.data, required this.prefs, this.memberId, this.dismissed = const {}});

  final LedgerData data;
  final PerkReminderPrefs prefs;
  final String? memberId;
  final Set<String> dismissed;
}

class PerkReminderController {
  PerkReminderController({
    required this.scheduler,
    required this.inputs,
    required this.clock,
    required this.onOpen,
    this.store,
    this.active,
    this.debounce = const Duration(seconds: 2),
  });

  /// 本机记着交给系统的每条提醒几点响：`{"20260923": 毫秒}`（UTC 那一刻）。退出登录清掉。
  static const String logKey = 'ui.perks.reminderLog';

  final PerkNotificationScheduler scheduler;

  /// 排程要读的几样；没登录、ledger 还没加载好时是 null（先不排）。
  final PerkReminderInputs? Function() inputs;
  final DateTime Function() clock;

  /// 点了通知：去这个路由。
  final void Function(String location) onOpen;

  /// 存 [logKey] 的地方；不给就只记在内存里（进程重启后按「今天的钟点过没过」判断）。
  final LocalStore? store;

  /// 能不能排（登录着）；false 时 [request] 直接忽略、不挂计时器。不给 = 一直能。
  final bool Function()? active;
  final Duration debounce;

  Timer? _timer;
  Future<void>? _running;
  bool _again = false;
  bool _started = false;
  bool _disposed = false;

  /// 上次真的交给系统的那份计划（[PerkReminderPlan.signature]）；null = 这个进程里还没排过。
  String? _applied;

  /// 退出登录（[clear]）加一：还在跑的那次排程每等一步都对一下，变了就停，不把上一家的提醒排回去。
  int _generation = 0;

  /// 撤干净之后还没再排过：退出登录时先撤了一遍，会话变空时就不再撤第二遍。
  bool _cleared = false;

  /// [logKey] 的内存副本（id → UTC 毫秒）；null = 还没读盘。
  Map<int, int>? _log;

  /// 登录后的外壳挂上时调：初始化插件；冷启动是点通知进来的就先跳过去；然后排一次（防抖）。重复调只当一次「请排一下」。
  Future<void> start() async {
    if (_started) return request();
    _started = true;
    final launch = await scheduler.init(onTap: onOpen);
    if (_disposed) return;
    if (launch != null) onOpen(launch);
    await _readLog();
    request();
  }

  /// 请排一下：2 秒内再来就重新计时，停下来 2 秒才真的排。
  void request() {
    if (!_started || _disposed || !scheduler.isSupported || !(active?.call() ?? true)) return;
    _timer?.cancel();
    _timer = Timer(debounce, () => unawaited(runNow()));
  }

  /// 外壳卸掉时收起还没到点的防抖（不留悬空的计时器）。
  void cancelPending() {
    _timer?.cancel();
    _timer = null;
  }

  /// 今天那条已经到过点了（弹过，或者还在路上）：设置页的「接下来」和排程用同一个判断。
  bool get todaySpent => _spentToday(_log ?? const {}, clock());

  /// 立刻排（跳过防抖）。正在排时再来：排完再排一次，不并发。
  Future<void> runNow() async {
    if (_disposed || !scheduler.isSupported) return;
    if (_running != null) {
      _again = true;
      return _running;
    }
    final run = _run();
    _running = run;
    try {
      await run;
    } finally {
      _running = null;
    }
    if (_again) {
      _again = false;
      await runNow();
    }
  }

  Future<void> _run() async {
    final generation = _generation;
    bool stale() => generation != _generation || _disposed;
    if (inputs() == null) return;
    final log = await _readLog();
    // 读盘途中可能退出登录了：数据现取，不用读盘之前拿的。
    final input = inputs();
    if (input == null || stale()) return;
    final now = clock();
    final local = now.isUtc ? now.toLocal() : now;
    final today = perkNotificationId(local);
    final spent = _spentToday(log, now);
    final plan = planPerkReminders(
      data: input.data,
      now: now,
      prefs: input.prefs,
      memberId: input.memberId,
      dismissed: input.dismissed,
      skipToday: spent,
    );
    if (plan.signature == _applied) return;
    try {
      final pending = await scheduler.pendingIds();
      if (stale()) return;
      // 先取消整段：窗口里的 id + 系统里还排着的会员提醒（早于今天没弹出来的、改了钟点留下的）。今天那条到过点了就不动：
      // 弹出来的不撤；非精确闹钟还在路上的也不撤（撤了它又不在窗口里，这一天就一条都没有了）。
      final cancel = {...plan.windowIds, ...pending.where(isPerkNotificationId)};
      if (spent) cancel.remove(today);
      _cleared = false;
      for (final id in cancel.toList()..sort()) {
        await scheduler.cancel(id);
        if (stale()) return;
      }
      await _writeLog({
        if (spent) today: log[today]!,
        for (final n in plan.notifications) n.id: n.at.millisecondsSinceEpoch,
      });
      for (final n in plan.notifications) {
        if (stale()) return;
        await scheduler.schedule(n);
      }
      _applied = plan.signature;
    } catch (error) {
      // 排失败了（系统拒了、插件出错）：不记成已排，下次触发再来。
      debugPrint('会员提醒：重排失败（$error）');
    }
  }

  /// 退出登录：撤掉排着的会员提醒和今天起 31 天的 id（下一个登录的人不该收到上一家的提醒）；还在跑的那次排程停下。
  /// 不需要先 [start]（插件查、撤不用初始化）。已经撤过、之后没再排过就不再撤一遍。
  Future<void> clear() async {
    _generation++;
    cancelPending();
    _applied = null;
    _log = {};
    try {
      await store?.remove(logKey);
    } catch (_) {
      // 删不掉也没关系：退出登录还会清空整个本机缓存。
    }
    if (_cleared) return;
    _cleared = await clearPerkNotifications(scheduler, clock());
  }

  void dispose() {
    _disposed = true;
    cancelPending();
  }

  bool _spentToday(Map<int, int> log, DateTime now) {
    final local = now.isUtc ? now.toLocal() : now;
    final at = log[perkNotificationId(local)];
    return at != null && at <= now.millisecondsSinceEpoch;
  }

  Future<Map<int, int>> _readLog() async {
    final cached = _log;
    if (cached != null) return cached;
    var loaded = <int, int>{};
    try {
      final raw = await store?.read<Map<String, dynamic>>(logKey);
      loaded = {
        for (final e in (raw ?? const <String, dynamic>{}).entries)
          if (int.tryParse(e.key) case final id? when e.value is int) id: e.value as int,
      };
    } catch (_) {
      // 读不出来：按「今天的钟点过没过」判断。
    }
    return _log ??= loaded;
  }

  Future<void> _writeLog(Map<int, int> next) async {
    _log = next;
    try {
      await store?.write(logKey, {for (final e in next.entries) '${e.key}': e.value});
    } catch (_) {
      // 存不下：这个进程里照样按内存里的算。
    }
  }
}

/// 全局一个：外壳（app/startup.dart）挂上时 start()、回到前台 request()、卸掉时 cancelPending()。
final perkReminderControllerProvider = Provider<PerkReminderController>((ref) {
  final controller = PerkReminderController(
    scheduler: ref.watch(perkNotificationSchedulerProvider),
    clock: ref.watch(assetClockProvider),
    store: ref.watch(localStoreProvider),
    active: () => ref.read(sessionProvider) != null,
    onOpen: (location) => ref.read(routerProvider).push(location),
    inputs: () {
      // 没登录不排：退出登录的那一下 ledger 还拿着上一家的数据、「我」已经是空的（会按全家排）。
      if (ref.read(sessionProvider) == null) return null;
      // 换人登录时 ledger 在重建，valueOrNull 还是上一个人的：等新数据回来（它一到 ledger 的监听会再请求一次）。
      final ledger = ref.read(ledgerProvider);
      final data = ledger.isLoading ? null : ledger.valueOrNull;
      if (data == null) return null;
      return PerkReminderInputs(
        data: data,
        prefs: ref.read(perkReminderPrefsProvider),
        memberId: ref.read(perkMeProvider),
        dismissed: ref.read(perkDismissedProvider),
      );
    },
  );
  ref.listen(ledgerProvider, (_, _) => controller.request());
  ref.listen(perkReminderPrefsProvider, (_, _) => controller.request());
  ref.listen(perkDismissedProvider, (_, _) => controller.request());
  ref.listen(sessionProvider, (previous, next) {
    if (next == null) {
      unawaited(controller.clear());
    } else if (previous?.me.id != next.me.id) {
      controller.request();
    }
  });
  // 退出登录时在删会话之前先撤（app/providers.dart 的 logout）；上面会话变空时那一下就不用再撤第二遍了。
  final hooks = ref.watch(logoutHooksProvider);
  Future<void> beforeLogout() => controller.clear();
  hooks.add(beforeLogout);
  ref.onDispose(() {
    hooks.remove(beforeLogout);
    controller.dispose();
  });
  return controller;
});
