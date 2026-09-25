import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'http_client_io.dart'
    if (dart.library.js_interop) 'http_client_web.dart';

/// 后端返回的一个错误；网络层错误用 `status: 0, code: 'network'`。
class ApiException implements Exception {
  const ApiException(
    this.status,
    this.code,
    this.message, {
    this.maybeSent = false,
    this.details = const {},
  });

  /// HTTP 状态码；0 表示请求根本没到服务端。
  final int status;

  /// 服务端 `{error:{code}}`，没有就退回 `http_<status>`。
  final String code;

  /// 直接给用户看的中文说明。
  final String message;

  /// 请求**有可能已经送到服务端**（发出去了但没等到回应，例如超时）。
  ///
  /// 只有「连都没连上」（拒绝连接、DNS 解析不了）才是 false。离线入队时靠它
  /// 决定这条记录能不能就地丢弃 —— 可能已落库的，删之前得先确认一次。
  final bool maybeSent;

  /// 服务端 `{error:{details}}`：比如重名时已有那行的 id（`name_taken`）、删不掉时的引用数。没有就是空 Map。
  final Map<String, dynamic> details;

  bool get isNetwork => code == 'network';
  bool get isUnauthorized => status == 401;
  bool get isNotFound => status == 404;

  @override
  String toString() => 'ApiException($status/$code): $message';
}

/// SSE 的一个事件（`event:` + `data:`）。
class SseEvent {
  const SseEvent(this.event, this.data);

  final String event;
  final String data;

  /// `data` 是 JSON 对象时解析出来；不是就给空 Map。
  Map<String, dynamic> get json {
    try {
      final value = jsonDecode(data);
      return value is Map<String, dynamic> ? value : const {};
    } catch (_) {
      return const {};
    }
  }

  @override
  String toString() => 'SseEvent($event, $data)';
}

/// 薄薄一层 http 封装：拼地址、带令牌、收发 JSON、把错误翻译成中文。
class ApiClient {
  ApiClient({
    required String baseUrl,
    this.token,
    http.Client? inner,
    String prefix = '/api/v1',
    Duration? timeout,
  }) : baseUrl = normalizeBaseUrl(baseUrl),
       _prefix = prefix,
       _inner = inner ?? defaultHttpClient(),
       _ownsInner = inner == null,
       timeout = timeout ?? defaultTimeout;

  /// 普通请求的超时；SSE 不限时。
  static const Duration defaultTimeout = Duration(seconds: 20);

  /// 本客户端的超时（测试里可以调短）。
  final Duration timeout;

  /// 已去掉末尾斜杠的服务器地址。
  final String baseUrl;

  /// 登录后设上；为 null 时不发 Authorization 头。
  String? token;

  final String _prefix;
  final http.Client _inner;
  final bool _ownsInner;

  /// `https://host/` → `https://host`
  static String normalizeBaseUrl(String raw) {
    var s = raw.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  Uri uri(String path, [Map<String, String>? query]) {
    final u = Uri.parse('$baseUrl$_prefix$path');
    if (query == null || query.isEmpty) return u;
    return u.replace(queryParameters: {...u.queryParameters, ...query});
  }

  Future<Map<String, dynamic>> get(String path, {Map<String, String>? query}) =>
      _send('GET', path, query: query);

  Future<Map<String, dynamic>> post(String path, Object? body) =>
      _send('POST', path, body: body, hasBody: true);

  Future<Map<String, dynamic>> patch(String path, Object? body) =>
      _send('PATCH', path, body: body, hasBody: true);

  Future<Map<String, dynamic>> put(String path, Object? body) =>
      _send('PUT', path, body: body, hasBody: true);

  Future<void> delete(String path) => _send('DELETE', path);

  /// `POST` 一个流式接口（AI 对话/月报），逐个吐出 SSE 事件。
  Stream<SseEvent> sse(String path, Object? body) async* {
    final request = http.Request('POST', uri(path));
    request.headers['accept'] = 'text/event-stream';
    request.headers['content-type'] = 'application/json; charset=utf-8';
    final t = token;
    if (t != null && t.isNotEmpty) request.headers['authorization'] = 'Bearer $t';
    request.body = jsonEncode(body ?? const <String, dynamic>{});

    final http.StreamedResponse response;
    try {
      response = await _inner.send(request);
    } catch (e) {
      throw _networkError(e);
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final text = utf8.decode(await response.stream.toBytes(), allowMalformed: true);
      throw _errorFrom(response.statusCode, _tryJson(text));
    }

    var buffer = '';
    String? event;
    final data = <String>[];

    SseEvent? flush() {
      if (data.isEmpty && event == null) return null;
      final out = SseEvent(event ?? 'message', data.join('\n'));
      event = null;
      data.clear();
      return out;
    }

    await for (final chunk in response.stream.transform(utf8.decoder)) {
      buffer += chunk;
      var cut = buffer.indexOf('\n');
      while (cut >= 0) {
        final line = buffer.substring(0, cut).replaceAll('\r', '');
        buffer = buffer.substring(cut + 1);
        if (line.isEmpty) {
          final out = flush();
          if (out != null) yield out;
        } else if (!line.startsWith(':')) {
          final colon = line.indexOf(':');
          final field = colon < 0 ? line : line.substring(0, colon);
          var value = colon < 0 ? '' : line.substring(colon + 1);
          if (value.startsWith(' ')) value = value.substring(1);
          if (field == 'event') {
            event = value;
          } else if (field == 'data') {
            data.add(value);
          }
        }
        cut = buffer.indexOf('\n');
      }
    }
    // 服务端没发最后一个空行也认。
    final tail = flush();
    if (tail != null) yield tail;
  }

  void close() {
    if (_ownsInner) _inner.close();
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    bool hasBody = false,
  }) async {
    final request = http.Request(method, uri(path, query));
    request.headers['accept'] = 'application/json';
    final t = token;
    if (t != null && t.isNotEmpty) request.headers['authorization'] = 'Bearer $t';
    if (hasBody) {
      request.headers['content-type'] = 'application/json; charset=utf-8';
      request.body = jsonEncode(body ?? const <String, dynamic>{});
    }

    final http.Response response;
    try {
      // 超时要盖住「连上 + 读完响应体」整段：只掐 send() 的话，
      // 服务端把头发过来却不发 body 就会永远挂着。
      response = await _inner
          .send(request)
          .then(http.Response.fromStream)
          .timeout(timeout);
    } catch (e) {
      throw _networkError(e);
    }

    // 服务端不一定带 charset，自己按 UTF-8 解，别让中文变乱码。
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    final decoded = _tryJson(text);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is List) return {'items': decoded};
      return <String, dynamic>{};
    }
    throw _errorFrom(response.statusCode, decoded);
  }

  static Object? _tryJson(String text) {
    if (text.trim().isEmpty) return null;
    try {
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }

  static ApiException _networkError(Object e) {
    if (e is ApiException) return e;
    if (e is TimeoutException) {
      return const ApiException(
        0,
        'network',
        '请求超时，请检查网络或服务器是否还在。',
        maybeSent: true,
      );
    }
    return ApiException(
      0,
      'network',
      '连不上服务器：${_short(e)}',
      maybeSent: maybeSent(e),
    );
  }

  /// 连接阶段就失败 = 肯定没送到；连上之后才断的（reset / broken pipe）当作可能送到了。
  ///
  /// 判据以**消息**为主、类型为辅：`http` 的 IOClient 会把 `SocketException`
  /// 包成同时实现两者的 `_ClientSocketException`，而同一个 `SocketException`
  /// 既可能是「连不上」也可能是「连上了写到一半断了」，只看类型分不出来。
  static bool maybeSent(Object e) {
    if (e is TimeoutException) return true;
    final message = (e is http.ClientException ? e.message : e.toString())
        .toLowerCase();

    // 已经在跟服务端说话了才断的 —— 请求可能已经完整发出去。
    const afterSending = [
      'reset by peer',
      'broken pipe',
      'write failed',
      'connection closed',
      'closed before full header',
    ];
    if (afterSending.any(message.contains)) return true;

    // 连都没连上。
    const beforeSending = [
      'connection refused',
      'failed host lookup',
      'network is unreachable',
      'no route to host',
      'connection timed out',
      'name resolution',
      'cannot connect',
      'handshake',
    ];
    if (beforeSending.any(message.contains)) return false;
    if (e.runtimeType.toString().contains('HandshakeException')) return false;

    // 说不清的一律保守：宁可多确认一次，也不要在服务端留下孤儿行。
    return true;
  }

  static ApiException _errorFrom(int status, Object? decoded) {
    if (decoded is Map && decoded['error'] is Map) {
      final error = decoded['error'] as Map;
      final details = error['details'];
      return ApiException(
        status,
        error['code']?.toString() ?? 'http_$status',
        error['message']?.toString() ?? _statusMessage(status),
        details: details is Map ? details.map((k, v) => MapEntry(k.toString(), v)) : const {},
      );
    }
    return ApiException(status, 'http_$status', _statusMessage(status));
  }

  static String _statusMessage(int status) => switch (status) {
    400 => '请求有问题，服务端没收下。',
    401 => '登录已过期，请重新登录。',
    403 => '没有权限做这件事。',
    404 => '没找到这条数据。',
    429 => '操作太频繁，等一会儿再试。',
    >= 500 => '服务器出错了（$status），稍后再试。',
    _ => '请求失败（$status）。',
  };

  static String _short(Object e) {
    final s = e.toString();
    return s.length > 120 ? '${s.substring(0, 120)}…' : s;
  }
}
