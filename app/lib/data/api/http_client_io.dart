import 'package:http/http.dart' as http;

/// 原生平台：`http` 自带的实现就够了（dart:io 的 socket 本来就是流式的）。
http.Client defaultHttpClient() => http.Client();
