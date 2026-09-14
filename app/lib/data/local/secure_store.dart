import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 会话令牌的存放处。移动端用系统钥匙串/Keystore，Web 落 localStorage。
abstract class SecureStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);

  static Future<SecureStore> open() async {
    if (kIsWeb) return PrefsSecureStore(await SharedPreferences.getInstance());
    return const KeychainSecureStore();
  }
}

class KeychainSecureStore implements SecureStore {
  const KeychainSecureStore();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (_) {
      // 某些 ROM 上 Keystore 会抽风；读不出来就当没登录，不要崩在启动路径上。
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    await _storage.write(key: key, value: value);
  }

  @override
  Future<void> delete(String key) async {
    await _storage.delete(key: key);
  }
}

/// Web 实现：浏览器里没有真正的安全存储，令牌就放 localStorage。
class PrefsSecureStore implements SecureStore {
  PrefsSecureStore(this._prefs);

  final SharedPreferences _prefs;

  @override
  Future<String?> read(String key) async => _prefs.getString(key);

  @override
  Future<void> write(String key, String value) async =>
      _prefs.setString(key, value);

  @override
  Future<void> delete(String key) async => _prefs.remove(key);
}

/// 测试用。
class MemorySecureStore implements SecureStore {
  final Map<String, String> data = {};

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async => data[key] = value;

  @override
  Future<void> delete(String key) async => data.remove(key);
}
