import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../platform/capture_channel.dart';
import '../../platform/capture_providers.dart';
import '../../platform/perk_notifications.dart';
import '../../platform/perk_reminders.dart';
import '../assets/asset_providers.dart';
import '../assets/asset_widgets.dart';
import '../perks/perk_providers.dart';
import 'capture_widgets.dart';

/// 「我的 › 会员提醒」（spec §5「Android 通知」）：本机的每日摘要开关和时间、通知权限（复用自动记账那套申请与状态）、
/// MIUI 自启动引导（手机重启后要靠它把提醒排回去）、接下来几条的预览。不能推送时照实说一句为什么：网页版、iOS 版
/// 本期不推送，Android 上通知组件没起来是另一回事（perkPushBlockOf）。
class PerkReminderPage extends ConsumerStatefulWidget {
  const PerkReminderPage({super.key});

  @override
  ConsumerState<PerkReminderPage> createState() => _PerkReminderPageState();
}

class _PerkReminderPageState extends ConsumerState<PerkReminderPage> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 从系统设置页（通知权限、自启动）回来要重新查一遍。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) ref.invalidate(notificationPermissionProvider);
  }

  Future<void> _pickTime(PerkReminderPrefs prefs) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: prefs.hour, minute: prefs.minute),
      helpText: '每天几点提醒',
      // 一律 24 小时制，和页面上写的「09:00」一个样子。
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (picked == null) return;
    await ref.read(perkReminderPrefsProvider.notifier).set(prefs.copyWith(hour: picked.hour, minute: picked.minute));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final scheduler = ref.watch(perkNotificationSchedulerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('会员提醒')),
      body: LayoutBuilder(
        builder: (context, box) => ListView(
          padding: readableInsets(box.maxWidth, maxWidth: 720).copyWith(bottom: LedgerLayout.groupGap),
          children: scheduler.isSupported ? _android(context, muted) : [_unsupported(perkPushBlockOf(scheduler))],
        ),
      ),
    );
  }

  Widget _unsupported(PerkPushBlock block) {
    const inApp = '打开家账时，首页和会员权益 tab 的「要处理」照样会提醒。';
    final (title, why) = switch (block) {
      PerkPushBlock.web => ('网页版不能推送', '网页版不发系统通知。'),
      PerkPushBlock.ios => ('iOS 版暂不推送', 'iOS 版这一期还不发系统通知。'),
      PerkPushBlock.desktop => ('这个版本不能推送', '只有 Android 版发系统通知。'),
      PerkPushBlock.unavailable => ('这台手机上用不了系统通知', '家账的通知组件没能启动（系统精简过、或者被限制了）。'),
    };
    return ListTile(
      key: const ValueKey('perk-reminder-unsupported'),
      leading: const Icon(Icons.notifications_off_outlined),
      title: Text(title),
      subtitle: Text('$why$inApp'),
    );
  }

  List<Widget> _android(BuildContext context, TextStyle? muted) {
    final prefs = ref.watch(perkReminderPrefsProvider);
    final platform = ref.watch(capturePlatformProvider);
    final permission = ref.watch(notificationPermissionProvider).valueOrNull;
    final device = ref.watch(deviceInfoProvider).valueOrNull;
    final ledger = ref.watch(ledgerProvider).valueOrNull;
    final now = ref.watch(assetClockProvider)();
    // 和排程同一个判断：今天那条已经到过点了，改晚了钟点也不再写「今天」（一天不发两条）。
    final upcoming = ledger == null
        ? const <PerkNotification>[]
        : planPerkReminders(
            data: ledger,
            now: now,
            prefs: prefs,
            memberId: ref.watch(perkMeProvider),
            dismissed: ref.watch(perkDismissedProvider),
            skipToday: ref.read(perkReminderControllerProvider).todaySpent,
          ).notifications.take(3).toList();
    final notify = ref.read(perkReminderPrefsProvider.notifier);
    final String empty;
    if (!prefs.enabled) {
      empty = '已关闭：不发通知（首页和「要处理」照常提醒）';
    } else if (ledger == null) {
      empty = '正在读取…';
    } else {
      empty = '未来 30 天没有要提醒的';
    }
    return [
      SwitchListTile(
        key: const ValueKey('perk-reminder-enabled'),
        value: prefs.enabled,
        onChanged: (v) => notify.set(prefs.copyWith(enabled: v)),
        title: const Text('每日摘要通知'),
        subtitle: const Text('每天最多一条，和「要处理」同一套：续费、到期、试用结束、权益快到期、本期没领完的'),
      ),
      ListTile(
        key: const ValueKey('perk-reminder-time'),
        enabled: prefs.enabled,
        leading: const Icon(Icons.schedule),
        title: const Text('提醒时间'),
        trailing: Text(prefs.timeLabel, style: Theme.of(context).textTheme.titleMedium),
        onTap: () => _pickTime(prefs),
      ),
      if (permission != null && permission != NotificationPermission.notRequired)
        CaptureStatusTile(
          title: '通知权限',
          ok: permission == NotificationPermission.granted,
          subtitle: permission == NotificationPermission.granted
              ? '已允许'
              : '未允许 · 收不到会员提醒（自动记账的结果通知也要它）。拒绝过的话，点「允许」会打开系统的通知设置，在那里打开',
          actionLabel: '允许',
          onAction: platform.requestNotificationPermission,
        ),
      if (device != null && device.isMiui)
        ListTile(
          leading: const Icon(Icons.restart_alt),
          title: const Text('允许自启动（MIUI）'),
          subtitle: const Text('手机重启后，家账要靠它把排好的提醒重新交给系统'),
          trailing: FilledButton.tonal(onPressed: platform.openAutoStartSettings, child: const Text('去设置')),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 16, LedgerLayout.pagePadding, 8),
        child: Text('接下来', style: Theme.of(context).textTheme.titleSmall),
      ),
      if (upcoming.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
          child: Text(empty, key: const ValueKey('perk-reminder-empty'), style: muted),
        )
      else
        for (final n in upcoming)
          ListTile(
            key: ValueKey('perk-reminder-next-${n.id}'),
            dense: true,
            title: Text(n.title, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text('${Dates.dayLabel(n.at, now: now)} ${Dates.timeLabel(n.at)}'),
          ),
      Padding(
        padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 16, LedgerLayout.pagePadding, 0),
        child: Text(
          '只提醒「我的」和全家共用的卡。设置只存在这台手机上，退出登录后回到默认。通知内容在排的那一刻算好：别的设备改了数据、'
          '这台手机又一直没打开家账时，要等下次打开同步后才更新。网页版不能推送。',
          style: muted,
        ),
      ),
    ];
  }
}
