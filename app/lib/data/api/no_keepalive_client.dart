import 'package:http/http.dart' as http;

/// 把每个请求的 `persistentConnection` 关掉再交给里面的客户端。
///
/// 网页端的 `FetchClient` 会把它翻译成 fetch 的 `keepalive`（请求体小于 63KB 时，GET 也算）。
/// 页面由 Flutter 的 service worker 接管、而 service worker 恰好在换版本时，
/// Chrome 会把 keepalive 请求一直扣着不发（到不了 TCP 层）：首页停在骨架屏、
/// 账单表格出不来、登录和导入预览一直转圈，看上去像随机卡死。
/// 普通请求本来就用不着 keepalive（那是给「页面关了还要发完」的场景用的）。
class NoKeepaliveClient extends http.BaseClient {
  NoKeepaliveClient(this._inner);

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.persistentConnection = false;
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
