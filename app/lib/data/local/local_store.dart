import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'local_store_native.dart'
    if (dart.library.js_interop) 'local_store_web.dart' as platform;

/// 本地 JSON 缓存。移动端落 `getApplicationSupportDirectory()` 下的文件，
/// Web 落 `shared_preferences`（localStorage）。不用 drift/codegen。
abstract class LocalStore {
  /// 读一个 JSON 值；类型对不上或没有就返回 null。
  Future<T?> read<T>(String key);

  /// 写一个可 `jsonEncode` 的值。
  Future<void> write(String key, Object json);

  Future<void> remove(String key);

  /// 退出登录时清空本地缓存。
  Future<void> clear();

  /// 按平台打开默认实现。
  static Future<LocalStore> open() => platform.openDefaultStore();
}

/// 测试与降级用：只活在内存里，但照样走一遍 JSON 编解码，
/// 这样「写进去的东西不可序列化」在测试里就会暴露。
class MemoryLocalStore implements LocalStore {
  final Map<String, String> _data = {};

  @override
  Future<T?> read<T>(String key) async => _cast<T>(_data[key]);

  @override
  Future<void> write(String key, Object json) async {
    _data[key] = jsonEncode(json);
  }

  @override
  Future<void> remove(String key) async => _data.remove(key);

  @override
  Future<void> clear() async => _data.clear();
}

/// Web（以及没有可写目录时）的实现。
class PrefsLocalStore implements LocalStore {
  PrefsLocalStore(this._prefs);

  static const String prefix = 'fl.';

  final SharedPreferences _prefs;

  @override
  Future<T?> read<T>(String key) async => _cast<T>(_prefs.getString('$prefix$key'));

  @override
  Future<void> write(String key, Object json) async {
    await _prefs.setString('$prefix$key', jsonEncode(json));
  }

  @override
  Future<void> remove(String key) async => _prefs.remove('$prefix$key');

  @override
  Future<void> clear() async {
    for (final k in _prefs.getKeys().where((k) => k.startsWith(prefix)).toList()) {
      await _prefs.remove(k);
    }
  }
}

T? _cast<T>(String? raw) {
  if (raw == null) return null;
  try {
    final value = jsonDecode(raw);
    return value is T ? value : null;
  } on FormatException {
    return null;
  }
}
