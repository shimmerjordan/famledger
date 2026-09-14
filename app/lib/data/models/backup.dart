import 'json_utils.dart';

/// WebDAV 备份配置（`GET /backup/config`）。口令类字段只写不读。
class BackupConfig {
  const BackupConfig({
    this.webdav = const WebdavConfig(),
    this.schedule = const BackupSchedule(),
    this.encryption = const BackupEncryption(),
    this.lastRun,
    this.nextRun,
    this.lastRunInfo,
  });

  final WebdavConfig webdav;
  final BackupSchedule schedule;
  final BackupEncryption encryption;

  /// 上次备份的时间点（服务端给对象时取 finishedAt，给时间串时直接解析）。
  final DateTime? lastRun;
  final DateTime? nextRun;

  /// 上次备份的完整记录（成功与否、文件名、大小）；服务端只给时间串时为 null。
  final BackupRun? lastRunInfo;

  bool get isConfigured => webdav.url.isNotEmpty && webdav.hasPassword;

  factory BackupConfig.fromJson(Map<String, dynamic> json) {
    final raw = json['lastRun'];
    final info = raw is Map ? BackupRun.fromJson(jsonMap(raw)) : null;
    return BackupConfig(
      webdav: WebdavConfig.fromJson(jsonMap(json['webdav'])),
      schedule: BackupSchedule.fromJson(jsonMap(json['schedule'])),
      encryption: BackupEncryption.fromJson(jsonMap(json['encryption'])),
      lastRun: info?.at ?? jsonDateOrNull(raw),
      nextRun: jsonDateOrNull(json['nextRun']),
      lastRunInfo: info,
    );
  }

  Map<String, dynamic> toJson() => {
    'webdav': webdav.toJson(),
    'schedule': schedule.toJson(),
    'encryption': encryption.toJson(),
    'lastRun': lastRun?.toIso8601String(),
    'nextRun': nextRun?.toIso8601String(),
  };
}

class WebdavConfig {
  const WebdavConfig({
    this.url = '',
    this.username = '',
    this.hasPassword = false,
    this.remoteDir = '',
  });

  final String url;
  final String username;
  final bool hasPassword;
  final String remoteDir;

  factory WebdavConfig.fromJson(Map<String, dynamic> json) => WebdavConfig(
    url: jsonString(json['url']),
    username: jsonString(json['username']),
    hasPassword: jsonBool(json['hasPassword']),
    remoteDir: jsonString(json['remoteDir']),
  );

  Map<String, dynamic> toJson() => {
    'url': url,
    'username': username,
    'hasPassword': hasPassword,
    'remoteDir': remoteDir,
  };
}

class BackupSchedule {
  const BackupSchedule({this.enabled = false, this.hour = 3, this.keep = 14});

  final bool enabled;
  final int hour;
  final int keep;

  factory BackupSchedule.fromJson(Map<String, dynamic> json) => BackupSchedule(
    enabled: jsonBool(json['enabled']),
    hour: jsonInt(json['hour'], 3),
    keep: jsonInt(json['keep'], 14),
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'hour': hour,
    'keep': keep,
  };
}

class BackupEncryption {
  const BackupEncryption({this.enabled = false, this.hasPassphrase = false});

  final bool enabled;
  final bool hasPassphrase;

  factory BackupEncryption.fromJson(Map<String, dynamic> json) => BackupEncryption(
    enabled: jsonBool(json['enabled']),
    hasPassphrase: jsonBool(json['hasPassphrase']),
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'hasPassphrase': hasPassphrase,
  };
}

/// 远端已有的一个备份文件。
class BackupItem {
  const BackupItem({
    required this.name,
    this.bytes = 0,
    this.modifiedAt,
    this.encrypted = false,
  });

  final String name;
  final int bytes;
  final DateTime? modifiedAt;
  final bool encrypted;

  factory BackupItem.fromJson(Map<String, dynamic> json) => BackupItem(
    name: jsonString(json['name']),
    bytes: jsonInt(json['bytes']),
    modifiedAt: jsonDateOrNull(json['modifiedAt']),
    encrypted: jsonBool(json['encrypted']),
  );
}

/// 一次备份的记录（`lastRun` / `GET /backup/status` 的 history 行）。
class BackupRun {
  const BackupRun({
    this.id = '',
    this.startedAt,
    this.finishedAt,
    this.ok,
    this.name,
    this.bytes,
    this.message,
  });

  final String id;
  final DateTime? startedAt;
  final DateTime? finishedAt;

  /// null = 还在跑（或中断没落盘）。
  final bool? ok;
  final String? name;
  final int? bytes;
  final String? message;

  bool get running => ok == null && finishedAt == null;

  /// 用来排序/显示的时间点。
  DateTime? get at => finishedAt ?? startedAt;

  factory BackupRun.fromJson(Map<String, dynamic> json) => BackupRun(
    id: jsonString(json['id']),
    startedAt: jsonDateOrNull(json['startedAt']),
    finishedAt: jsonDateOrNull(json['finishedAt']),
    ok: json['ok'] == null ? null : jsonBool(json['ok']),
    name: jsonStringOrNull(json['name']),
    bytes: jsonIntOrNull(json['bytes']),
    message: jsonStringOrNull(json['message']),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'startedAt': startedAt?.toIso8601String(),
    'finishedAt': finishedAt?.toIso8601String(),
    'ok': ok,
    'name': name,
    'bytes': bytes,
    'message': message,
  };
}

/// `GET /backup/status`
class BackupStatus {
  const BackupStatus({
    this.lastRun,
    this.nextRun,
    this.running = false,
    this.history = const [],
  });

  final BackupRun? lastRun;
  final DateTime? nextRun;
  final bool running;
  final List<BackupRun> history;

  factory BackupStatus.fromJson(Map<String, dynamic> json) => BackupStatus(
    lastRun: json['lastRun'] is Map
        ? BackupRun.fromJson(jsonMap(json['lastRun']))
        : null,
    nextRun: jsonDateOrNull(json['nextRun']),
    running: jsonBool(json['running']),
    history: jsonList(json['history'], BackupRun.fromJson),
  );
}

/// `POST /backup/run`
class BackupRunResult {
  const BackupRunResult({this.name = '', this.bytes = 0, this.tookMs = 0});

  final String name;
  final int bytes;
  final int tookMs;

  factory BackupRunResult.fromJson(Map<String, dynamic> json) => BackupRunResult(
    name: jsonString(json['name']),
    bytes: jsonInt(json['bytes']),
    tookMs: jsonInt(json['tookMs']),
  );
}

/// `POST /backup/test`
class BackupTestResult {
  const BackupTestResult({required this.ok, this.message = ''});

  final bool ok;
  final String message;

  factory BackupTestResult.fromJson(Map<String, dynamic> json) =>
      BackupTestResult(ok: jsonBool(json['ok']), message: jsonString(json['message']));
}

/// `POST /backup/restore`：恢复前那份本地副本的文件名也带回来。
class BackupRestoreResult {
  const BackupRestoreResult({
    required this.ok,
    this.restoredFrom = '',
    this.preRestoreCopy = '',
  });

  final bool ok;
  final String restoredFrom;
  final String preRestoreCopy;

  factory BackupRestoreResult.fromJson(Map<String, dynamic> json) =>
      BackupRestoreResult(
        ok: jsonBool(json['ok']),
        restoredFrom: jsonString(json['restoredFrom']),
        preRestoreCopy: jsonString(json['preRestoreCopy']),
      );
}

/// `GET /backup/export` 拿回来的字节 + 建议文件名。
class BackupExport {
  const BackupExport({required this.bytes, required this.filename});

  final List<int> bytes;
  final String filename;

  int get size => bytes.length;
}

/// `1.2 MB` —— 备份文件大小都用它显示。
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = value >= 100 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}
