import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';

import '../../app/providers.dart';
import '../api/api_client.dart';
import '../models/models.dart';

/// WebDAV 备份：配置、手动备份、远端列表、恢复、导出到本机。
class BackupRepo {
  BackupRepo(this._api, {http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final ApiClient _api;

  /// `/backup/export` 是二进制，不走 ApiClient 的 JSON 通道。
  final http.Client _client;
  final bool _ownsClient;

  Future<BackupConfig> config() async =>
      BackupConfig.fromJson(await _api.get('/backup/config'));

  /// 口令与密语留空 = 不修改（不往请求体里放），这样表单不用回填明文。
  Future<BackupConfig> saveConfig({
    required String url,
    required String username,
    required String password,
    required String remoteDir,
    required bool scheduleEnabled,
    required int hour,
    required int keep,
    required bool encryptionEnabled,
    required String passphrase,
  }) async {
    final webdav = <String, dynamic>{
      'url': url,
      'username': username,
      'remoteDir': remoteDir,
    };
    if (password.isNotEmpty) webdav['password'] = password;
    final encryption = <String, dynamic>{'enabled': encryptionEnabled};
    if (passphrase.isNotEmpty) encryption['passphrase'] = passphrase;
    final res = await _api.put('/backup/config', {
      'webdav': webdav,
      'schedule': {'enabled': scheduleEnabled, 'hour': hour, 'keep': keep},
      'encryption': encryption,
    });
    return BackupConfig.fromJson(res);
  }

  Future<BackupTestResult> test() async =>
      BackupTestResult.fromJson(await _api.post('/backup/test', const {}));

  Future<BackupRunResult> run() async =>
      BackupRunResult.fromJson(await _api.post('/backup/run', const {}));

  Future<List<BackupItem>> list() async =>
      jsonList((await _api.get('/backup/list'))['items'], BackupItem.fromJson);

  Future<BackupStatus> status() async =>
      BackupStatus.fromJson(await _api.get('/backup/status'));

  Future<BackupRestoreResult> restore(String name) async =>
      BackupRestoreResult.fromJson(await _api.post('/backup/restore', {'name': name}));

  /// 拉一份完整快照的字节（`application/gzip`）。
  Future<BackupExport> export() async {
    final request = http.Request('GET', _api.uri('/backup/export'));
    request.headers['accept'] = 'application/gzip';
    final token = _api.token;
    if (token != null && token.isNotEmpty) {
      request.headers['authorization'] = 'Bearer $token';
    }

    final http.Response response;
    try {
      response = await http.Response.fromStream(await _client.send(request));
    } catch (_) {
      throw const ApiException(0, 'network', '连不上服务器，导出没成功。');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _errorFrom(response);
    }
    return BackupExport(
      bytes: response.bodyBytes,
      filename: _filenameOf(response.headers['content-disposition']),
    );
  }

  /// 把导出的快照交给系统：移动端弹分享面板，Web 直接下载。
  ///
  /// 用 `XFile.fromData` 而不是自己写临时文件：share_plus 在原生端本来就会
  /// 把内存里的文件落到临时目录再分享，而 `dart:io` 在 Web 编译不过。
  Future<void> shareExport(BackupExport snapshot) async {
    final bytes = Uint8List.fromList(snapshot.bytes);
    await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile.fromData(
            bytes,
            name: snapshot.filename,
            mimeType: 'application/gzip',
            length: bytes.length,
          ),
        ],
        fileNameOverrides: [snapshot.filename],
      ),
    );
  }

  void close() {
    if (_ownsClient) _client.close();
  }

  /// `attachment; filename="famledger-20260913-030000.db.gz"`
  static String _filenameOf(String? disposition) {
    final match = RegExp('filename="?([^";]+)"?').firstMatch(disposition ?? '');
    final name = match?.group(1)?.trim();
    if (name != null && name.isNotEmpty) return name;
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'famledger-${now.year}${two(now.month)}${two(now.day)}'
        '-${two(now.hour)}${two(now.minute)}${two(now.second)}.db.gz';
  }

  static ApiException _errorFrom(http.Response response) {
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map && decoded['error'] is Map) {
        final error = decoded['error'] as Map;
        return ApiException(
          response.statusCode,
          error['code']?.toString() ?? 'http_${response.statusCode}',
          error['message']?.toString() ?? '导出失败。',
        );
      }
    } catch (_) {
      // 不是 JSON 错误体就退回状态码。
    }
    return ApiException(
      response.statusCode,
      'http_${response.statusCode}',
      '导出失败（${response.statusCode}）。',
    );
  }
}

final backupRepoProvider = Provider<BackupRepo>((ref) {
  final repo = BackupRepo(ref.watch(apiProvider));
  ref.onDispose(repo.close);
  return repo;
});

/// 备份配置；保存后用 `ref.invalidate(backupConfigProvider)` 刷新。
final backupConfigProvider = FutureProvider<BackupConfig>(
  (ref) => ref.watch(backupRepoProvider).config(),
);

/// 远端已有的备份文件。
final backupListProvider = FutureProvider<List<BackupItem>>(
  (ref) => ref.watch(backupRepoProvider).list(),
);

/// 最近几次备份的运行记录。
final backupStatusProvider = FutureProvider<BackupStatus>(
  (ref) => ref.watch(backupRepoProvider).status(),
);
