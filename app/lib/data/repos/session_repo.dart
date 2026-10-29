import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/ids.dart';
import '../api/api_client.dart';
import '../local/secure_store.dart';
import '../models/models.dart';

/// 一次登录的全部身份信息。存在安全存储里的就是它的 JSON。
class Session {
  const Session({
    required this.baseUrl,
    required this.token,
    required this.deviceId,
    required this.me,
  });

  final String baseUrl;
  final String token;
  final String deviceId;
  final Member me;

  factory Session.fromJson(Map<String, dynamic> json) => Session(
    baseUrl: jsonString(json['baseUrl']),
    token: jsonString(json['token']),
    deviceId: jsonString(json['deviceId']),
    me: Member.fromJson(jsonMap(json['me'])),
  );

  Map<String, dynamic> toJson() => {
    'baseUrl': baseUrl,
    'token': token,
    'deviceId': deviceId,
    'me': me.toJson(),
  };

  Session copyWith({Member? me}) => Session(
    baseUrl: baseUrl,
    token: token,
    deviceId: deviceId,
    me: me ?? this.me,
  );
}

/// 连接服务器 → 初始化家庭 / 登录 → 会话落盘。
class SessionRepo {
  SessionRepo({required SecureStore secure, http.Client? httpClient})
    : _secure = secure,
      _httpClient = httpClient;

  static const String sessionKey = 'famledger.session';
  static const String baseUrlKey = 'famledger.baseUrl';

  final SecureStore _secure;
  final http.Client? _httpClient;

  Session? _session;
  String? _baseUrl;
  bool _needsSetup = false;
  String? _householdName;

  /// 令牌过期时登录页要显示的那句话。
  static const String expiredNotice = '登录已过期，请重新登录';

  /// 启动时判「令牌已过期」留的余量（毫秒）：10 分钟，容设备时钟快一点。
  static const int expiryLeewayMs = 10 * 60 * 1000;

  /// [restore] 没恢复会话的原因（目前只有「令牌已过期」），给登录页顶上显示一句；
  /// `SessionController.build()` 搬走后清掉。没话说就是 null。
  String? lastNotice;

  Session? get current => _session;

  /// 上次连过的服务器地址（登出后还留着，方便直接回登录页）。
  String? get storedBaseUrl => _session?.baseUrl ?? _baseUrl;

  /// `connect()` 的结果：这台服务器还没初始化家庭。
  bool get needsSetup => _needsSetup;

  String? get householdName => _householdName;

  /// 启动时读回会话。任何异常都当作「没登录」，不能崩在启动路径上。
  ///
  /// 令牌自带过期时刻（[tokenExpiresAt]）：到点的不恢复，删掉会话、留下 [lastNotice]，
  /// 直接停在登录页，不用等第一个请求撞 401。服务器地址留着，登录页直接用。
  Future<Session?> restore() async {
    _baseUrl = await _secure.read(baseUrlKey);
    final raw = await _secure.read(sessionKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final session = Session.fromJson(jsonMap(jsonDecode(raw)));
      if (session.token.isEmpty || session.baseUrl.isEmpty) return null;
      _baseUrl = session.baseUrl;
      final expiresAt = tokenExpiresAt(session.token);
      // 留 [expiryLeewayMs] 的余量：设备时钟快几分钟不至于每次启动都被登出（登得上、一重启就掉）；
      // 真过期了，第一个请求撞 401 一样会回登录页。
      if (expiresAt != null && expiresAt + expiryLeewayMs <= DateTime.now().millisecondsSinceEpoch) {
        lastNotice = expiredNotice;
        await _secure.delete(sessionKey);
        return null;
      }
      _session = session;
      return session;
    } catch (_) {
      await _secure.delete(sessionKey);
      return null;
    }
  }

  /// 令牌第一段（base64url 的 JSON `{sub,tid,exp,iat}`，`exp` 单位秒）里的过期时刻，毫秒。
  /// 格式看不懂、没有 `exp` 都返回 null —— 老令牌当作不会过期，交给服务端判。
  static int? tokenExpiresAt(String token) {
    final dot = token.indexOf('.');
    if (dot <= 0) return null;
    try {
      final head = base64Url.decode(base64Url.normalize(token.substring(0, dot)));
      final payload = jsonDecode(utf8.decode(head));
      if (payload is! Map) return null;
      final exp = payload['exp'];
      final seconds = exp is num ? exp : (exp is String ? num.tryParse(exp) : null);
      if (seconds == null || !seconds.isFinite) return null;
      return (seconds * 1000).toInt();
    } catch (_) {
      return null;
    }
  }

  /// 令牌被服务端打回（过期 / 吊销）：只把会话从内存和安全存储里拿掉，服务器地址留着，
  /// 本地缓存也不动 —— 同一个人待会儿还要登回来，排着的账要留着。不通知服务端（令牌本来就不认了）。
  Future<void> dropSession() async {
    _session = null;
    await _secure.delete(sessionKey);
  }

  /// 校验服务器地址：`GET /healthz` + `GET /api/v1/setup/status`。
  ///
  /// 成功后地址落盘，并更新 [needsSetup]。
  Future<void> connect(String rawUrl) async {
    final url = normalizeUrl(rawUrl);
    if (url.isEmpty) {
      throw const ApiException(0, 'bad_url', '请填服务器地址，例如 https://ledger.example.com');
    }
    final health = ApiClient(baseUrl: url, prefix: '', inner: _httpClient);
    try {
      final res = await health.get('/healthz');
      final ok = res['ok'];
      if (ok == false) {
        throw const ApiException(0, 'not_ready', '服务器还没准备好，稍后再试。');
      }
    } finally {
      if (_httpClient == null) health.close();
    }

    final api = ApiClient(baseUrl: url, inner: _httpClient);
    try {
      final status = await api.get('/setup/status');
      _needsSetup = jsonBool(status['needsSetup']);
      _householdName = jsonStringOrNull(status['householdName']);
    } finally {
      if (_httpClient == null) api.close();
    }

    _baseUrl = url;
    await _secure.write(baseUrlKey, url);
  }

  /// 只问一句记住的那台服务器初始化了没有（登录页用）：不落盘、不改地址。问的途中地址换了
  /// （用户点了「换个服务器」连上别的），这次的结果作废，返回 null；没记住地址也是 null。连不上照样抛。
  Future<bool?> probeSetup() async {
    final url = storedBaseUrl;
    if (url == null || url.isEmpty) return null;
    final api = ApiClient(baseUrl: url, inner: _httpClient);
    try {
      final status = await api.get('/setup/status');
      if (storedBaseUrl != url) return null;
      _needsSetup = jsonBool(status['needsSetup']);
      _householdName = jsonStringOrNull(status['householdName']);
      return _needsSetup;
    } finally {
      if (_httpClient == null) api.close();
    }
  }

  /// 首次初始化家庭（服务端没有任何用户时才开放）。
  Future<Session> setup({
    required String householdName,
    required String username,
    required String password,
    required String displayName,
    String? setupToken,
  }) async {
    final body = {
      'householdName': householdName,
      'username': username,
      'password': password,
      'displayName': displayName,
    };
    if (setupToken != null && setupToken.isNotEmpty) body['setupToken'] = setupToken;
    final res = await _call((api) => api.post('/setup', body));
    _needsSetup = false;
    _householdName = householdName;
    return _persist(res);
  }

  Future<Session> login(String username, String password) async {
    final res = await _call(
      (api) => api.post('/auth/login', {
        'username': username,
        'password': password,
        'deviceName': deviceName,
        'platform': platformName,
      }),
    );
    return _persist(res);
  }

  /// 登出：尽力通知服务端吊销令牌，本地一定清干净。
  Future<void> logout() async {
    final session = _session;
    if (session != null) {
      try {
        await _call((api) => api.post('/auth/logout', null));
      } catch (_) {
        // 断网也要能退出登录。
      }
    }
    _session = null;
    await _secure.delete(sessionKey);
  }

  Future<void> changePassword({
    required String oldPassword,
    required String newPassword,
  }) async {
    await _call(
      (api) => api.post('/auth/password', {
        'oldPassword': oldPassword,
        'newPassword': newPassword,
      }),
    );
  }

  /// 拉一次 `/auth/me`，顺便验证令牌还有效。
  Future<Member?> refreshMe() async {
    final session = _session;
    if (session == null) return null;
    final res = await _call((api) => api.get('/auth/me'));
    final me = Member.fromJson(jsonMap(res['member']));
    _session = session.copyWith(me: me);
    await _secure.write(sessionKey, jsonEncode(_session!.toJson()));
    return me;
  }

  /// 服务端自己的默认端口（`deploy/Dockerfile`、`scripts/dev.sh` 都是这个值）。
  /// 局域网直连没有反代替你把 443/80 转发过去，用户只填了 IP/主机名、没写端口
  /// 时，不补的话会去敲 80 端口——famledger 根本不监听那，连不上还不容易看出
  /// 是「忘写端口」，只会看到一个笼统的连接失败。
  static const int defaultPort = 48090;

  /// 用户可能只输了 `nas.lan`；私网/本地地址（含 Tailscale 等跑在
  /// 100.64.0.0/10 共享地址空间里的 overlay 网络）默认 http 且补默认端口，
  /// 其余（公网域名，通常走 Cloudflare Tunnel 之类反代到 443）默认 https、
  /// 端口不动。
  static String normalizeUrl(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return '';
    if (!s.contains('://')) {
      final slash = s.indexOf('/');
      final authority = slash < 0 ? s : s.substring(0, slash);
      final rest = slash < 0 ? '' : s.substring(slash);
      final host = authority.split(':').first.toLowerCase();
      final isLocal =
          host == 'localhost' ||
          host == '127.0.0.1' ||
          host.endsWith('.local') ||
          host.endsWith('.lan') ||
          host.startsWith('192.168.') ||
          host.startsWith('10.') ||
          RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(host) ||
          // RFC 6598 CGNAT 共享地址空间（100.64.0.0/10）：Tailscale 等
          // overlay 网络的节点地址都落在这段里，不是公网 IP。
          RegExp(r'^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.').hasMatch(host);
      final hasPort = authority.contains(':');
      final withPort = (isLocal && !hasPort) ? '$authority:$defaultPort' : authority;
      s = '${isLocal ? 'http' : 'https'}://$withPort$rest';
    }
    return ApiClient.normalizeBaseUrl(s);
  }

  static String get platformName {
    if (kIsWeb) return 'web';
    return defaultTargetPlatform.name;
  }

  static String get deviceName => '家账 · $platformName';

  Future<Map<String, dynamic>> _call(
    Future<Map<String, dynamic>> Function(ApiClient api) run,
  ) async {
    final url = storedBaseUrl;
    if (url == null || url.isEmpty) {
      throw const ApiException(0, 'no_server', '还没连上服务器。');
    }
    final api = ApiClient(baseUrl: url, token: _session?.token, inner: _httpClient);
    try {
      return await run(api);
    } finally {
      if (_httpClient == null) api.close();
    }
  }

  Future<Session> _persist(Map<String, dynamic> res) async {
    final url = storedBaseUrl ?? '';
    final session = Session(
      baseUrl: url,
      token: jsonString(res['token']),
      deviceId: jsonStringOrNull(res['deviceId']) ?? newId(),
      me: Member.fromJson(jsonMap(res['member'])),
    );
    _session = session;
    _baseUrl = url;
    await _secure.write(sessionKey, jsonEncode(session.toJson()));
    await _secure.write(baseUrlKey, url);
    return session;
  }
}
