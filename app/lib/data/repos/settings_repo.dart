import '../api/api_client.dart';
import '../local/local_store.dart';
import '../models/models.dart';

/// 家庭级设置：拉下来缓存一份，离线也能看。
class SettingsRepo {
  SettingsRepo({required ApiClient api, required LocalStore store})
    : _api = api,
      _store = store;

  static const String cacheKey = 'settings';

  final ApiClient _api;
  final LocalStore _store;

  Future<Settings?> cached() async {
    final raw = await _store.read<Map<String, dynamic>>(cacheKey);
    return raw == null ? null : Settings.fromJson(raw);
  }

  Future<Settings> fetch() async {
    try {
      final settings = Settings.fromJson(await _api.get('/settings'));
      await _store.write(cacheKey, settings.toJson());
      return settings;
    } on ApiException catch (e) {
      final fallback = await cached();
      if (e.isNetwork && fallback != null) return fallback;
      rethrow;
    }
  }

  Future<Settings> patch(Map<String, dynamic> body) async {
    final settings = Settings.fromJson(await _api.patch('/settings', body));
    await _store.write(cacheKey, settings.toJson());
    return settings;
  }
}
