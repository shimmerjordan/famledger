import 'package:famledger/platform/perk_notifications.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// 通知调度器（spec §5「Android 通知」）：没有原生插件时（widget 测试、没注册上的平台）不抛、当不支持；
// 非 Android 平台一律「不支持」（网页只做页面内提醒）。

void main() {
  test('没有原生插件：init 不抛、回 null，之后当不支持；取消、排、查都是空操作', () async {
    final scheduler = LocalPerkNotificationScheduler();
    expect(scheduler.isSupported, isTrue, reason: '初始化之前按 Android 算');
    final opened = <String>[];
    expect(await scheduler.init(onTap: opened.add), isNull);
    expect(scheduler.isSupported, isFalse);
    expect(await scheduler.pendingIds(), isEmpty);
    await scheduler.cancel(20260924);
    await scheduler.schedule(
      PerkNotification(id: 20260924, at: DateTime(2026, 9, 24, 9), title: '88VIP 快到期', body: '10月28日到期 · 还有 30 天', payload: '/assets'),
    );
    expect(opened, isEmpty);
  });

  test('没 init 就查、撤（没登录时冷启动撤上一家的提醒）：没有插件时不抛，当不支持', () async {
    final scheduler = LocalPerkNotificationScheduler();
    expect(await scheduler.pendingIds(), isEmpty);
    await scheduler.cancel(20260924);
    expect(scheduler.isSupported, isFalse);
    expect(perkPushBlockOf(scheduler), PerkPushBlock.unavailable, reason: '设置页说「这台手机上用不了」，不说「网页版」');
  });

  test('provider：Android 用真的；iOS、桌面（和网页）一律不支持，各有各的说法', () {
    for (final (platform, supported, block) in [
      (TargetPlatform.android, true, PerkPushBlock.unavailable),
      (TargetPlatform.iOS, false, PerkPushBlock.ios),
      (TargetPlatform.linux, false, PerkPushBlock.desktop),
    ]) {
      debugDefaultTargetPlatformOverride = platform;
      final container = ProviderContainer();
      final scheduler = container.read(perkNotificationSchedulerProvider);
      expect(scheduler is LocalPerkNotificationScheduler, supported, reason: '$platform');
      expect(scheduler.isSupported, supported, reason: '$platform');
      if (!supported) expect(perkPushBlockOf(scheduler), block, reason: '$platform');
      container.dispose();
    }
    debugDefaultTargetPlatformOverride = null;
  });
}
