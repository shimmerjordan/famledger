import 'package:famledger/data/repos/session_repo.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
