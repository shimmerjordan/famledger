import 'dart:convert';

import 'package:famledger/data/local/secure_store.dart';
import 'package:famledger/data/repos/session_repo.dart';
import 'package:flutter_test/flutter_test.dart';

/// 服务端那种令牌：`base64url(JSON{sub,tid,exp,iat})`（无填充）+ `.` + 签名；签名这里随便写。
String token({int? exp}) {
  final payload = {'sub': 'm1', 'tid': 't1', 'iat': 1700000000, if (exp != null) 'exp': exp};
  final head = base64Url.encode(utf8.encode(jsonEncode(payload))).replaceAll('=', '');
  return '$head.c2ln';
}

MemorySecureStore storedSession(String tok) => MemorySecureStore()
  ..data[SessionRepo.baseUrlKey] = 'https://ledger.example.com'
  ..data[SessionRepo.sessionKey] = jsonEncode({
    'baseUrl': 'https://ledger.example.com',
    'token': tok,
    'deviceId': 'dev',
    'me': {'id': 'm1', 'username': 'mama', 'displayName': '妈妈', 'role': 'admin'},
  });

void main() {
  group('SessionRepo.tokenExpiresAt', () {
    test('解析第一段 base64url JSON 里的 exp（秒 → 毫秒），没有填充也能解', () {
      expect(SessionRepo.tokenExpiresAt(token(exp: 1700000000)), 1700000000 * 1000);
      expect(SessionRepo.tokenExpiresAt(token(exp: 1)), 1000);
    });

    test('没有 exp、不是这种格式、第一段不是 JSON：都返回 null，当作不会过期', () {
      expect(SessionRepo.tokenExpiresAt(token()), isNull);
      expect(SessionRepo.tokenExpiresAt('tok'), isNull);
      expect(SessionRepo.tokenExpiresAt(''), isNull);
      expect(SessionRepo.tokenExpiresAt('.sig'), isNull);
      expect(SessionRepo.tokenExpiresAt('!!!.sig'), isNull);
      expect(SessionRepo.tokenExpiresAt('${base64Url.encode(utf8.encode('not json'))}.sig'), isNull);
      expect(SessionRepo.tokenExpiresAt('${base64Url.encode(utf8.encode('[1,2]'))}.sig'), isNull);
    });
  });

  group('SessionRepo.restore 与令牌过期', () {
    test('令牌已过期：不恢复，删掉会话、留下提示，服务器地址还在', () async {
      final secure = storedSession(token(exp: 1700000000)); // 2023-11-14，早过了
      final repo = SessionRepo(secure: secure);
      expect(await repo.restore(), isNull);
      expect(repo.current, isNull);
      expect(repo.lastNotice, '登录已过期，请重新登录');
      expect(secure.data.containsKey(SessionRepo.sessionKey), isFalse);
      expect(secure.data[SessionRepo.baseUrlKey], 'https://ledger.example.com');
      expect(repo.storedBaseUrl, 'https://ledger.example.com', reason: '登录页要直接用这个地址');
    });

    test('令牌还没过期：照常恢复，没有提示', () async {
      final future = DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch ~/ 1000;
      final secure = storedSession(token(exp: future));
      final repo = SessionRepo(secure: secure);
      expect((await repo.restore())?.me.username, 'mama');
      expect(repo.lastNotice, isNull);
      expect(secure.data.containsKey(SessionRepo.sessionKey), isTrue);
    });

    test('过期不到 10 分钟的还恢复（容设备时钟快一点；真过期了第一个请求会撞 401 回登录页）', () async {
      final fiveMinAgo = DateTime.now().subtract(const Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000;
      final repo = SessionRepo(secure: storedSession(token(exp: fiveMinAgo)));
      expect((await repo.restore())?.me.username, 'mama');
      expect(repo.lastNotice, isNull);
    });

    test('过期超过 10 分钟的不恢复', () async {
      final longAgo = DateTime.now().subtract(const Duration(minutes: 15)).millisecondsSinceEpoch ~/ 1000;
      final secure = storedSession(token(exp: longAgo));
      final repo = SessionRepo(secure: secure);
      expect(await repo.restore(), isNull);
      expect(repo.lastNotice, '登录已过期，请重新登录');
      expect(secure.data.containsKey(SessionRepo.sessionKey), isFalse);
    });

    test('没有 exp 的老令牌照常恢复（交给服务端判）', () async {
      final secure = storedSession('tok');
      final repo = SessionRepo(secure: secure);
      expect((await repo.restore())?.token, 'tok');
      expect(repo.lastNotice, isNull);
      expect(secure.data.containsKey(SessionRepo.sessionKey), isTrue);
    });

    test('dropSession：只删会话，服务器地址留着', () async {
      final secure = storedSession('tok');
      final repo = SessionRepo(secure: secure);
      await repo.restore();
      await repo.dropSession();
      expect(repo.current, isNull);
      expect(secure.data.containsKey(SessionRepo.sessionKey), isFalse);
      expect(secure.data[SessionRepo.baseUrlKey], 'https://ledger.example.com');
      expect(repo.storedBaseUrl, 'https://ledger.example.com');
    });
  });

  group('SessionRepo.normalizeUrl', () {
    test('局域网裸 IP，没写端口 → 自动补 http:// 与默认端口', () {
      expect(SessionRepo.normalizeUrl('192.168.1.10'), 'http://192.168.1.10:48090');
      expect(SessionRepo.normalizeUrl('10.0.0.5'), 'http://10.0.0.5:48090');
      expect(SessionRepo.normalizeUrl('172.16.0.1'), 'http://172.16.0.1:48090');
      expect(SessionRepo.normalizeUrl('172.31.255.254'), 'http://172.31.255.254:48090');
      expect(SessionRepo.normalizeUrl('nas.lan'), 'http://nas.lan:48090');
      expect(SessionRepo.normalizeUrl('nas.local'), 'http://nas.local:48090');
      expect(SessionRepo.normalizeUrl('localhost'), 'http://localhost:48090');
      expect(SessionRepo.normalizeUrl('127.0.0.1'), 'http://127.0.0.1:48090');
    });

    test('172.x 只有 16~31 这一段算私网，172.32/172.15 不算', () {
      expect(SessionRepo.normalizeUrl('172.32.0.1'), 'https://172.32.0.1');
      expect(SessionRepo.normalizeUrl('172.15.0.1'), 'https://172.15.0.1');
    });

    test('局域网地址自己写了端口 → 不覆盖', () {
      expect(SessionRepo.normalizeUrl('192.168.1.10:8080'), 'http://192.168.1.10:8080');
      expect(SessionRepo.normalizeUrl('nas.lan:9000'), 'http://nas.lan:9000');
    });

    test('公网域名 → https，不补端口', () {
      expect(SessionRepo.normalizeUrl('ledger.example.com'), 'https://ledger.example.com');
      expect(SessionRepo.normalizeUrl('ledger.example.com:8443'), 'https://ledger.example.com:8443');
    });

    test('带路径的地址：端口插在 host 后面，路径原样跟在后面', () {
      expect(SessionRepo.normalizeUrl('192.168.1.10/famledger'), 'http://192.168.1.10:48090/famledger');
      expect(SessionRepo.normalizeUrl('ledger.example.com/famledger'), 'https://ledger.example.com/famledger');
    });

    test('已经带 scheme 的地址原样透传（不重复处理、不乱补端口）', () {
      expect(SessionRepo.normalizeUrl('http://192.168.1.10'), 'http://192.168.1.10');
      expect(SessionRepo.normalizeUrl('https://ledger.example.com'), 'https://ledger.example.com');
      expect(SessionRepo.normalizeUrl('http://100.110.121.64:48090'), 'http://100.110.121.64:48090');
    });

    test('Tailscale 之类的 100.64.0.0/10 CGNAT 地址算「本地」，自动补端口', () {
      expect(SessionRepo.normalizeUrl('100.110.121.64'), 'http://100.110.121.64:48090');
      expect(SessionRepo.normalizeUrl('http://100.110.121.64:48090'), 'http://100.110.121.64:48090');
    });

    test('100.64.0.0/10 边界：100.63.x 和 100.128.x 不在这段里，不算本地', () {
      expect(SessionRepo.normalizeUrl('100.64.0.0'), 'http://100.64.0.0:48090');
      expect(SessionRepo.normalizeUrl('100.127.255.255'), 'http://100.127.255.255:48090');
      expect(SessionRepo.normalizeUrl('100.63.255.255'), 'https://100.63.255.255');
      expect(SessionRepo.normalizeUrl('100.128.0.0'), 'https://100.128.0.0');
    });

    test('空输入 → 空字符串', () {
      expect(SessionRepo.normalizeUrl(''), '');
      expect(SessionRepo.normalizeUrl('   '), '');
    });

    test('尾部斜杠会被 ApiClient.normalizeBaseUrl 去掉', () {
      expect(SessionRepo.normalizeUrl('192.168.1.10/'), 'http://192.168.1.10:48090');
    });
  });
}
