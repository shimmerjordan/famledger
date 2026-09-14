import 'dart:convert';

import 'package:famledger/data/api/api_client.dart';
import 'package:famledger/data/models/models.dart';
import 'package:famledger/data/repos/backup_repo.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response jsonResponse(Object body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

const Map<String, dynamic> serverConfig = {
  'webdav': {
    'url': 'https://dav.jianguoyun.com/dav',
    'username': 'mama@example.com',
    'hasPassword': true,
    'remoteDir': '/famledger',
  },
  'schedule': {'enabled': true, 'hour': 3, 'keep': 14},
  'encryption': {'enabled': true, 'hasPassphrase': true},
  'lastRun': {
    'id': 'run1',
    'startedAt': '2026-09-12T19:00:00.000Z',
    'finishedAt': '2026-09-12T19:00:04.000Z',
    'ok': true,
    'name': 'famledger-20260913-030000.db.gz.enc',
    'bytes': 1258291,
    'message': null,
  },
  'nextRun': '2026-09-13T19:00:00.000Z',
};

BackupRepo repoWith(MockClient client) =>
    BackupRepo(ApiClient(baseUrl: 'https://x.dev', token: 'tok', inner: client), client: client);

void main() {
  group('配置', () {
    test('读回来的 lastRun 是一次运行记录，不是一个时间串', () async {
      final repo = repoWith(MockClient((request) async => jsonResponse(serverConfig)));

      final config = await repo.config();

      expect(config.webdav.url, 'https://dav.jianguoyun.com/dav');
      expect(config.webdav.hasPassword, isTrue);
      expect(config.webdav.remoteDir, '/famledger');
      expect(config.schedule.enabled, isTrue);
      expect(config.schedule.hour, 3);
      expect(config.schedule.keep, 14);
      expect(config.encryption.hasPassphrase, isTrue);
      expect(config.lastRunInfo?.ok, isTrue);
      expect(config.lastRunInfo?.bytes, 1258291);
      // 解析边界统一 toLocal()，比时刻而不是比 isUtc 标记。
      expect(
        config.lastRun!.isAtSameMomentAs(DateTime.parse('2026-09-12T19:00:04.000Z')),
        isTrue,
      );
      expect(config.nextRun, isNotNull);
      expect(config.isConfigured, isTrue);
    });

    test('保存时空口令/空密语不进请求体（= 不修改）', () async {
      late http.Request seen;
      final repo = repoWith(
        MockClient((request) async {
          seen = request;
          return jsonResponse(serverConfig);
        }),
      );

      final saved = await repo.saveConfig(
        url: 'https://dav.jianguoyun.com/dav',
        username: 'mama@example.com',
        password: '',
        remoteDir: '/famledger',
        scheduleEnabled: true,
        hour: 5,
        keep: 30,
        encryptionEnabled: true,
        passphrase: '',
      );

      expect(seen.method, 'PUT');
      expect(seen.url.path, '/api/v1/backup/config');
      final body = jsonDecode(seen.body) as Map<String, dynamic>;
      expect(body['webdav'], {
        'url': 'https://dav.jianguoyun.com/dav',
        'username': 'mama@example.com',
        'remoteDir': '/famledger',
      });
      expect(body['schedule'], {'enabled': true, 'hour': 5, 'keep': 30});
      expect(body['encryption'], {'enabled': true});
      // PUT 的响应就是最新配置，直接拿来回填表单。
      expect(saved.schedule.hour, 3);
    });

    test('填了口令和密语就发上去', () async {
      late http.Request seen;
      final repo = repoWith(
        MockClient((request) async {
          seen = request;
          return jsonResponse(serverConfig);
        }),
      );

      await repo.saveConfig(
        url: 'https://dav.example.com',
        username: 'u',
        password: 'app-pass',
        remoteDir: '/famledger',
        scheduleEnabled: false,
        hour: 3,
        keep: 14,
        encryptionEnabled: true,
        passphrase: '一串足够长的密语',
      );

      final body = jsonDecode(seen.body) as Map<String, dynamic>;
      expect((body['webdav'] as Map)['password'], 'app-pass');
      expect((body['encryption'] as Map)['passphrase'], '一串足够长的密语');
    });
  });

  group('远端列表与运行', () {
    test('列表带大小、时间与加密标记', () async {
      final repo = repoWith(
        MockClient(
          (request) async => jsonResponse({
            'items': [
              {
                'name': 'famledger-20260913-030000.db.gz.enc',
                'bytes': 1258291,
                'modifiedAt': '2026-09-13T03:00:04.000Z',
                'encrypted': true,
              },
              {
                'name': 'famledger-20260912-030000.db.gz',
                'bytes': 1048576,
                'modifiedAt': '2026-09-12T03:00:03.000Z',
                'encrypted': false,
              },
            ],
          }),
        ),
      );

      final items = await repo.list();

      expect(items, hasLength(2));
      expect(items.first.encrypted, isTrue);
      expect(items.first.bytes, 1258291);
      expect(
        items.last.modifiedAt!.isAtSameMomentAs(
          DateTime.parse('2026-09-12T03:00:03.000Z'),
        ),
        isTrue,
      );
    });

    test('立即备份返回文件名、大小与耗时', () async {
      late Uri url;
      final repo = repoWith(
        MockClient((request) async {
          url = request.url;
          return jsonResponse({
            'name': 'famledger-20260913-101500.db.gz',
            'bytes': 2097152,
            'tookMs': 4120,
          });
        }),
      );

      final result = await repo.run();

      expect(url.path, '/api/v1/backup/run');
      expect(result.name, 'famledger-20260913-101500.db.gz');
      expect(formatBytes(result.bytes), '2.0 MB');
      expect(result.tookMs, 4120);
    });

    test('测试连接把服务端的说明原样带回来', () async {
      final repo = repoWith(
        MockClient(
          (request) async => jsonResponse({'ok': false, 'message': '401：用户名或应用密码不对'}),
        ),
      );

      final result = await repo.test();

      expect(result.ok, isFalse);
      expect(result.message, '401：用户名或应用密码不对');
    });

    test('备份进行中时恢复会拿到服务端的 409 说明', () async {
      final repo = repoWith(
        MockClient(
          (request) async => jsonResponse({
            'error': {'code': 'backup_running', 'message': '备份正在进行，等它结束再恢复'},
          }, status: 409),
        ),
      );

      await expectLater(
        repo.restore('famledger-20260913-030000.db.gz'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'backup_running')
              .having((e) => e.message, 'message', '备份正在进行，等它结束再恢复'),
        ),
      );
    });

    test('恢复只发文件名，回来带上恢复前的本地副本名', () async {
      late http.Request seen;
      final repo = repoWith(
        MockClient((request) async {
          seen = request;
          return jsonResponse({
            'ok': true,
            'restoredFrom': 'famledger-20260913-030000.db.gz',
            'preRestoreCopy': 'pre-restore-20260913-101500.db',
          });
        }),
      );

      final result = await repo.restore('famledger-20260913-030000.db.gz');

      expect(seen.method, 'POST');
      expect(seen.url.path, '/api/v1/backup/restore');
      expect(jsonDecode(seen.body), {'name': 'famledger-20260913-030000.db.gz'});
      expect(result.ok, isTrue);
      expect(result.preRestoreCopy, 'pre-restore-20260913-101500.db');
    });

    test('状态里的历史逐条解析，失败那次带原因', () async {
      final repo = repoWith(
        MockClient(
          (request) async => jsonResponse({
            'lastRun': {
              'id': 'r2',
              'startedAt': '2026-09-13T03:00:00.000Z',
              'finishedAt': '2026-09-13T03:00:02.000Z',
              'ok': false,
              'message': 'WebDAV 507：空间不够',
            },
            'nextRun': '2026-09-14T03:00:00.000Z',
            'running': false,
            'history': [
              {'id': 'r2', 'ok': false, 'message': 'WebDAV 507：空间不够'},
              {'id': 'r1', 'ok': true, 'name': 'famledger-20260912-030000.db.gz', 'bytes': 1024},
            ],
          }),
        ),
      );

      final status = await repo.status();

      expect(status.running, isFalse);
      expect(status.lastRun?.ok, isFalse);
      expect(status.lastRun?.message, 'WebDAV 507：空间不够');
      expect(status.history, hasLength(2));
      expect(status.history.last.bytes, 1024);
    });
  });

  group('导出到本机', () {
    test('带鉴权取二进制，文件名从 content-disposition 来', () async {
      late http.BaseRequest seen;
      final repo = repoWith(
        MockClient((request) async {
          seen = request;
          return http.Response.bytes(
            [31, 139, 8, 0, 1, 2, 3, 4],
            200,
            headers: {
              'content-type': 'application/gzip',
              'content-disposition':
                  'attachment; filename="famledger-20260913-101500.db.gz"',
            },
          );
        }),
      );

      final snapshot = await repo.export();

      expect(seen.url.path, '/api/v1/backup/export');
      expect(seen.headers['authorization'], 'Bearer tok');
      expect(snapshot.filename, 'famledger-20260913-101500.db.gz');
      expect(snapshot.size, 8);
    });

    test('服务端没给文件名就自己编一个 .db.gz', () async {
      final repo = repoWith(
        MockClient((request) async => http.Response.bytes([1, 2], 200)),
      );

      final snapshot = await repo.export();

      expect(snapshot.filename, startsWith('famledger-'));
      expect(snapshot.filename, endsWith('.db.gz'));
    });

    test('导出失败时把错误体翻成 ApiException', () async {
      final repo = repoWith(
        MockClient(
          (request) async => jsonResponse({
            'error': {'code': 'forbidden', 'message': '只有管理员能导出'},
          }, status: 403),
        ),
      );

      await expectLater(
        repo.export(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'forbidden')
              .having((e) => e.message, 'message', '只有管理员能导出'),
        ),
      );
    });
  });

  group('文件大小', () {
    test('按 1024 进位，小于 1KB 显示字节', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(1023), '1023 B');
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(1048576), '1.0 MB');
      expect(formatBytes(157286400), '150 MB');
      expect(formatBytes(3221225472), '3.0 GB');
    });
  });
}
