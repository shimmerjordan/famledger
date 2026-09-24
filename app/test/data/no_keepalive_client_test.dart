import 'package:famledger/data/api/no_keepalive_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('转发前关掉 persistentConnection（网页端 = 不带 keepalive）', () async {
    final seen = <bool>[];
    final client = NoKeepaliveClient(MockClient((req) async {
      seen.add(req.persistentConnection);
      return http.Response('{}', 200);
    }));
    await client.post(Uri.parse('https://ledger.example.com/api/v1/import/preview'), body: '{"data":"x"}');
    await client.get(Uri.parse('https://ledger.example.com/api/v1/stats/overview'));
    expect(seen, [false, false]);
  });
}
