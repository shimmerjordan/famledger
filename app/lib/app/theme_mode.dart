import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local/local_store.dart';
import 'providers.dart';

/// 外观：跟随系统 / 浅色 / 深色。记在本机（每台设备各自选），不是家庭设置。
final themeModeProvider = NotifierProvider<ThemeModeController, ThemeMode>(ThemeModeController.new);

class ThemeModeController extends Notifier<ThemeMode> {
  ThemeModeController([this._initial]);

  /// main() 启动时已经从本机读到的值：有它就不会先画一帧浅色再切深色。
  final ThemeMode? _initial;

  /// 用户已经点过了：后台那次读盘回来晚了也不能把用户刚选的盖掉。
  bool _touched = false;

  static const String storeKey = 'ui.themeMode';

  @override
  ThemeMode build() {
    // 退出登录会清本机缓存：清完跟着重读，不留上一个人的选择。
    ref.watch(localStoreEpochProvider);
    final store = ref.watch(localStoreProvider);
    if (_initial != null && ref.read(localStoreEpochProvider) == 0) return _initial;
    unawaited(_load(store));
    return ThemeMode.system;
  }

  Future<void> _load(LocalStore store) async {
    final mode = await readThemeMode(store);
    if (!_touched && mode != state) state = mode;
  }

  Future<void> set(ThemeMode mode) async {
    _touched = true;
    state = mode;
    await ref.read(localStoreProvider).write(storeKey, {'mode': mode.name});
  }

  /// 右上角那个按钮：跟随系统 → 浅色 → 深色 → 跟随系统。
  Future<void> cycle() => set(switch (state) {
    ThemeMode.system => ThemeMode.light,
    ThemeMode.light => ThemeMode.dark,
    ThemeMode.dark => ThemeMode.system,
  });
}

/// 本机记的外观；没记过或认不出就是跟随系统。
Future<ThemeMode> readThemeMode(LocalStore store) async {
  try {
    final raw = await store.read<Map<String, dynamic>>(ThemeModeController.storeKey);
    final name = raw?['mode'];
    return ThemeMode.values.where((m) => m.name == name).firstOrNull ?? ThemeMode.system;
  } catch (_) {
    return ThemeMode.system;
  }
}

String themeModeLabel(ThemeMode mode) => switch (mode) {
  ThemeMode.system => '跟随系统',
  ThemeMode.light => '浅色',
  ThemeMode.dark => '深色',
};
