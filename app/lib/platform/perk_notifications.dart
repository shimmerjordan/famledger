import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;

import '../data/models/perk_digest.dart';

// 会员提醒的通知调度器（spec §5「Android 通知」）：只有 Android 真的排（flutter_local_notifications，inexactAllowWhileIdle，
// 不申请精确闹钟）；网页、iOS、桌面一律「不支持」（页面内提醒照常）。抽成接口，测试注入假的。
// 排什么、先取消哪些在 perk_reminders.dart；这里只管和插件打交道。

/// 通知渠道 id（系统设置里用户能单独关掉这一类）。
const String kPerkChannelId = 'perk_reminders';
const String kPerkChannelName = '会员提醒';
const String kPerkChannelDescription = '会员到期、续费、本期没领完的每日摘要';

/// 状态栏小图标：android/app/src/main/res/drawable/ic_stat_perk.xml（res/raw/keep.xml 保住它不被资源压缩删掉）。
const String kPerkNotificationIcon = 'ic_stat_perk';

/// 排给系统的一条每日摘要。
class PerkNotification {
  const PerkNotification({required this.id, required this.at, required this.title, required this.body, required this.payload});

  /// yyyymmdd（perk_digest.dart 的 perkNotificationId）。
  final int id;

  /// 本地时间。
  final DateTime at;
  final String title;
  final String body;

  /// 点开去哪（go_router 路径）。
  final String payload;
}

abstract class PerkNotificationScheduler {
  /// 这个平台能不能排系统通知；初始化失败（没有原生插件）后也会变成 false。
  bool get isSupported;

  /// 初始化插件、建渠道；之后用户点通知时把 payload 交给 [onTap]。
  /// 返回「这次冷启动就是点通知进来的」那条的 payload（一个进程只回一次），不是就 null。
  Future<String?> init({required void Function(String payload) onTap});

  /// 系统里还排着、没到点的通知 id。
  Future<List<int>> pendingIds();

  Future<void> cancel(int id);

  Future<void> schedule(PerkNotification notification);
}

/// 为什么不能推送：设置页照实说（网页版、iOS 版本期不做，和「这台 Android 手机上的通知组件用不了」是两回事）。
enum PerkPushBlock { web, ios, desktop, unavailable }

/// 这个调度器为什么不能推送；能推送时没有意义。插件初始化失败的 Android（[LocalPerkNotificationScheduler]）
/// 和测试里的假调度器算 [PerkPushBlock.unavailable]。
PerkPushBlock perkPushBlockOf(PerkNotificationScheduler scheduler) =>
    scheduler is UnsupportedPerkNotificationScheduler ? scheduler.block : PerkPushBlock.unavailable;

/// 网页、iOS、桌面：不能推送。
class UnsupportedPerkNotificationScheduler implements PerkNotificationScheduler {
  const UnsupportedPerkNotificationScheduler([this.block = PerkPushBlock.web]);

  final PerkPushBlock block;

  @override
  bool get isSupported => false;

  @override
  Future<String?> init({required void Function(String payload) onTap}) async => null;

  @override
  Future<List<int>> pendingIds() async => const [];

  @override
  Future<void> cancel(int id) async {}

  @override
  Future<void> schedule(PerkNotification notification) async {}
}

/// Android：flutter_local_notifications。
///
/// 时区：不取设备的时区名（不另加插件）。每一天的提醒时刻已经按 Dart 的本地时间算好（perk_digest.dart
/// perkReminderSlots），这里换成同一瞬间的 UTC [tz.TZDateTime] 交给插件 —— 逐日单排、不用 matchDateTimeComponents，
/// 所以跨夏令时也对；手机改了时区，下次打开 App 重排就跟上了。
class LocalPerkNotificationScheduler implements PerkNotificationScheduler {
  LocalPerkNotificationScheduler([FlutterLocalNotificationsPlugin? plugin]) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  bool _ok = true;

  /// 插件只初始化一次；之后再调 init 只换点击回调。
  Future<void>? _ready;
  void Function(String payload)? _onTap;

  /// 冷启动的那次点击只交出去一次：退出再登录时外壳重新挂上，不能又跳一回。
  static bool _launchTaken = false;

  @override
  bool get isSupported => _ok;

  @override
  Future<String?> init({required void Function(String payload) onTap}) async {
    _onTap = onTap;
    try {
      await (_ready ??= _initialize());
      if (_launchTaken) return null;
      _launchTaken = true;
      final launch = await _plugin.getNotificationAppLaunchDetails();
      final payload = launch != null && launch.didNotificationLaunchApp ? launch.notificationResponse?.payload : null;
      return payload != null && payload.startsWith('/') ? payload : null;
    } catch (error) {
      // 没有原生插件（widget 测试、没注册上的平台）：当作不支持，之后什么都不排。
      debugPrint('会员提醒：通知插件不可用（$error）');
      _ok = false;
      return null;
    }
  }

  Future<void> _initialize() async {
    await _plugin.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings(kPerkNotificationIcon)),
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload != null && payload.startsWith('/')) _onTap?.call(payload);
      },
    );
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(kPerkChannelId, kPerkChannelName, description: kPerkChannelDescription),
        );
  }

  // 查、撤不需要先 init（原生直接操作 AlarmManager 和通知栏）：没登录时冷启动也能把上一家的提醒撤干净。
  // 原生那边出的错（PlatformException）照常抛出去，排程那边不记成已排、下次再来；插件根本不在（widget 测试里
  // 没注册、ROM 阉割：MissingPluginException、插件实例没初始化）就当不支持，之后都是空操作，和 init 失败一样。

  @override
  Future<List<int>> pendingIds() async {
    if (!_ok) return const [];
    try {
      return [for (final r in await _plugin.pendingNotificationRequests()) r.id];
    } on PlatformException {
      rethrow;
    } catch (_) {
      _ok = false;
      return const [];
    }
  }

  @override
  Future<void> cancel(int id) async {
    if (!_ok) return;
    try {
      await _plugin.cancel(id: id);
    } on PlatformException {
      rethrow;
    } catch (_) {
      _ok = false;
    }
  }

  @override
  Future<void> schedule(PerkNotification n) async {
    if (!_ok) return;
    try {
      await _plugin.zonedSchedule(
        id: n.id,
        title: n.title,
        body: n.body,
        payload: n.payload,
        scheduledDate: tz.TZDateTime.from(n.at, tz.UTC),
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            kPerkChannelId,
            kPerkChannelName,
            channelDescription: kPerkChannelDescription,
            category: AndroidNotificationCategory.reminder,
            styleInformation: BigTextStyleInformation(n.body),
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
    } on ArgumentError {
      // 算好到交给插件之间刚好过了点（插件拒收过去的时刻）：这一天就不排了。
    }
  }
}

/// Android 用真的，其余平台不支持；测试里换成假的。
final perkNotificationSchedulerProvider = Provider<PerkNotificationScheduler>((ref) {
  if (kIsWeb) return const UnsupportedPerkNotificationScheduler(PerkPushBlock.web);
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => LocalPerkNotificationScheduler(),
    TargetPlatform.iOS => const UnsupportedPerkNotificationScheduler(PerkPushBlock.ios),
    _ => const UnsupportedPerkNotificationScheduler(PerkPushBlock.desktop),
  };
});

/// 把会员提醒撤干净（退出登录、没登录时冷启动）：系统里还排着的会员提醒（yyyymmdd 形状）加上今天起 31 天的 id ——
/// 已经弹出来的也一起从通知栏撤掉（上一家的卡名不该留着）。自动记账的通知 id 不是这个形状、又带 tag，碰不到。
/// 查、撤都不需要先初始化插件。撤不掉（插件出错）返回 false，不抛。
Future<bool> clearPerkNotifications(PerkNotificationScheduler scheduler, DateTime now) async {
  if (!scheduler.isSupported) return true;
  try {
    final local = now.isUtc ? now.toLocal() : now;
    final pending = await scheduler.pendingIds();
    final ids = {
      for (var i = 0; i <= perkDigestDays; i++) perkNotificationId(DateTime(local.year, local.month, local.day + i)),
      ...pending.where(isPerkNotificationId),
    };
    for (final id in ids) {
      await scheduler.cancel(id);
    }
    return true;
  } catch (error) {
    debugPrint('会员提醒：撤销失败（$error）');
    return false;
  }
}
