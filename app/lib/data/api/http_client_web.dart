import 'package:fetch_client/fetch_client.dart';
import 'package:http/http.dart' as http;

/// 浏览器里必须用 fetch：`package:http` 的 `BrowserClient` 走 XHR，
/// 会把整个响应缓冲完才交给你 —— AI 回答就变成「转半天，然后一次性全出」。
/// `FetchClient` 直接给 `ReadableStream`，SSE 才是真的一个字一个字来。
http.Client defaultHttpClient() => FetchClient(mode: RequestMode.cors);
