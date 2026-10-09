import 'package:famledger/app/providers.dart';
import 'package:famledger/app/theme_mode.dart';
import 'package:famledger/data/local/local_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('外观默认跟随系统；点一下按 跟随系统 → 浅色 → 深色 → 跟随系统 轮换，并记在本机', () async {
    final store = MemoryLocalStore();
    final container = ProviderContainer(overrides: [localStoreProvider.overrideWithValue(store)]);
    addTearDown(container.dispose);

    expect(container.read(themeModeProvider), ThemeMode.system);
    final controller = container.read(themeModeProvider.notifier);
    await controller.cycle();
    expect(container.read(themeModeProvider), ThemeMode.light);
    await controller.cycle();
    expect(container.read(themeModeProvider), ThemeMode.dark);
    expect(await readThemeMode(store), ThemeMode.dark, reason: '写进了本机');
    await controller.cycle();
    expect(container.read(themeModeProvider), ThemeMode.system);
  });

  test('启动时把本机记的值带进来，不先画一帧浅色；认不出的值当跟随系统', () async {
    final store = MemoryLocalStore();
    await store.write(ThemeModeController.storeKey, {'mode': 'dark'});
    expect(await readThemeMode(store), ThemeMode.dark);
    final container = ProviderContainer(overrides: [
      localStoreProvider.overrideWithValue(store),
      themeModeProvider.overrideWith(() => ThemeModeController(ThemeMode.dark)),
    ]);
    addTearDown(container.dispose);
    expect(container.read(themeModeProvider), ThemeMode.dark);

    await store.write(ThemeModeController.storeKey, {'mode': 'neon'});
    expect(await readThemeMode(store), ThemeMode.system);
  });
}
