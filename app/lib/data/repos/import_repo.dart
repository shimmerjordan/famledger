import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../capture/classifier.dart' show CaptureFeatures;
import '../../capture/pipeline.dart' show LearnSample;
import '../api/api_client.dart';
import '../models/models.dart';

class ImportSkip {
  const ImportSkip({required this.code, required this.message});

  final String code;
  final String message;

  static ImportSkip? fromJson(Object? json) {
    if (json is! Map) return null;
    final map = jsonMap(json);
    return ImportSkip(
      code: jsonString(map['code'], 'invalid'),
      message: jsonString(map['message']),
    );
  }
}

/// `POST /import/preview` 里的一行候选流水。
class ImportRow {
  const ImportRow({
    required this.row,
    required this.clientId,
    this.type = 'expense',
    this.amountCents,
    this.occurredAt,
    this.merchant = '',
    this.note = '',
    this.rawCategory,
    this.categoryId,
    this.fundId,
    this.accountId,
    this.confidence,
    this.skip,
    this.exists = false,
    this.duplicateOf,
    this.hint,
  });

  final int row;
  final String clientId;
  final String type;
  final int? amountCents;

  /// 原样保留服务端给的「带 +08:00 的本地时间」串，提交时一字不改地送回去。
  final String? occurredAt;
  final String merchant;
  final String note;
  final String? rawCategory;
  final String? categoryId;
  final String? fundId;
  final String? accountId;
  final double? confidence;
  final ImportSkip? skip;
  final bool exists;
  final String? duplicateOf;
  final String? hint;

  bool get isIncome => type == 'income';

  bool get importable =>
      skip == null && amountCents != null && occurredAt != null;

  bool get isDuplicate => duplicateOf != null;

  /// 按串里的墙上时间读，不换算成本机时区：账单里写的是几点就显示几点，
  /// 训练用的 hour/weekday 也要和服务端预览时算的一致。
  DateTime? get wallTime {
    final m = _wallRe.firstMatch(occurredAt ?? '');
    if (m == null) return null;
    int g(int i) => int.parse(m.group(i)!);
    return DateTime(g(1), g(2), g(3), g(4), g(5));
  }

  static final RegExp _wallRe = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})',
  );

  factory ImportRow.fromJson(Map<String, dynamic> json) => ImportRow(
    row: jsonInt(json['row']),
    clientId: jsonString(json['clientId']),
    type: jsonString(json['type'], 'expense'),
    amountCents: jsonIntOrNull(json['amountCents']),
    occurredAt: jsonStringOrNull(json['occurredAt']),
    merchant: jsonString(json['merchant']),
    note: jsonString(json['note']),
    rawCategory: jsonStringOrNull(json['rawCategory']),
    categoryId: jsonStringOrNull(json['categoryId']),
    fundId: jsonStringOrNull(json['fundId']),
    accountId: jsonStringOrNull(json['accountId']),
    confidence: jsonDoubleOrNull(json['confidence']),
    skip: ImportSkip.fromJson(json['skip']),
    exists: jsonBool(json['exists']),
    duplicateOf: jsonStringOrNull(json['duplicateOf']),
    hint: jsonStringOrNull(json['hint']),
  );
}

class ImportPreview {
  const ImportPreview({
    required this.source,
    required this.sourceLabel,
    required this.rows,
    this.total = 0,
    this.importable = 0,
    this.skipped = 0,
  });

  /// alipay | wechat | template
  final String source;
  final String sourceLabel;
  final int total;
  final int importable;
  final int skipped;
  final List<ImportRow> rows;

  /// 与服务端预览猜分类时用的 `ch:` 特征一致：模板没有渠道。
  String get channel => source == 'alipay' || source == 'wechat' ? source : '';

  factory ImportPreview.fromJson(Map<String, dynamic> json) {
    final rows = jsonList(json['rows'], ImportRow.fromJson);
    return ImportPreview(
      source: jsonString(json['source']),
      sourceLabel: jsonString(json['sourceLabel'], '表格'),
      total: jsonInt(json['total'], rows.length),
      importable: jsonInt(json['importable']),
      skipped: jsonInt(json['skipped']),
      rows: rows,
    );
  }
}

/// 用户核对过、要提交的一行。
class ImportItem {
  const ImportItem({
    required this.row,
    this.categoryId,
    this.fundId,
    this.categoryChanged = false,
    this.fundChanged = false,
  });

  final ImportRow row;
  final String? categoryId;
  final String? fundId;
  final bool categoryChanged;
  final bool fundChanged;

  /// 只有人手改过的标签才算「纠正」；机器猜的原样送回去训练只会自我强化。
  bool get teaches =>
      (categoryChanged && categoryId != null) ||
      (fundChanged && fundId != null);

  Map<String, dynamic> toBatchJson() {
    final json = <String, dynamic>{
      'clientId': row.clientId,
      'type': row.type,
      'amountCents': row.amountCents,
      'occurredAt': row.occurredAt,
      'merchant': row.merchant,
      'note': row.note,
      'source': 'import',
    };
    putIfNotNull(json, 'categoryId', categoryId);
    putIfNotNull(json, 'fundId', fundId);
    putIfNotNull(json, 'accountId', row.accountId);
    return json;
  }

  /// 文本与特征照服务端预览猜分类时的算法拼（商户优先，没有才用备注），
  /// 下次导入同一家店才猜得中。长度按 JS 的 UTF-16 计，超了服务端整批 400。
  LearnSample learnSample({required String channel, required String memberId}) {
    final when = row.wallTime ?? DateTime(2000);
    final merchant = _clip(row.merchant, 100);
    return LearnSample(
      text: _clip(
        row.merchant.isNotEmpty ? row.merchant : row.note,
        LearnSample.maxTextLength,
      ),
      features: CaptureFeatures(
        merchant: merchant,
        direction: row.type,
        channel: channel,
        amountCents: row.amountCents,
        hour: when.hour,
        weekday: when.weekday,
        memberId: memberId,
      ),
      categoryId: categoryChanged ? categoryId : null,
      fundId: fundChanged ? fundId : null,
    );
  }

  static String _clip(String s, int max) {
    if (s.length <= max) return s;
    var cut = s.substring(0, max);
    final last = cut.codeUnitAt(cut.length - 1);
    if (last >= 0xD800 && last <= 0xDBFF) {
      cut = cut.substring(0, cut.length - 1);
    }
    return cut;
  }
}

class ImportFailure {
  const ImportFailure({
    required this.row,
    required this.clientId,
    required this.code,
    required this.message,
    this.unsent = false,
  });

  final int row;
  final String clientId;
  final String code;
  final String message;

  /// 整批请求就没成（断网、超时、服务器挂了），不是服务端看过这一笔后拒收。
  /// 这种原样重发就行 —— clientId 稳定，万一其实已经落库也只会回 exists。
  final bool unsent;
}

class ImportResult {
  const ImportResult({
    this.created = 0,
    this.exists = 0,
    this.failures = const [],
    this.learned = 0,
    this.learnError,
  });

  final int created;
  final int exists;
  final List<ImportFailure> failures;
  final int learned;
  final String? learnError;

  int get failed => failures.length;
}

class ImportRepo {
  ImportRepo(this._api, {ApiClient? uploadApi})
    : _uploadApi = uploadApi ?? _api;

  /// 与 `transactions.js` 的 MAX_BATCH 相同。
  static const int batchSize = 200;

  /// 与 `model.js` 的 MAX_SAMPLES 相同。
  static const int learnChunk = 500;

  /// 与 `imports.js` 的 MAX_BODY 相同。
  static const int maxBodyBytes = 8 * 1024 * 1024;

  /// 给人看的上限：base64 胀 4/3，原文件大约只能到 6MB。
  static const int maxFileBytes = 6 * 1024 * 1024;

  final ApiClient _api;
  final ApiClient _uploadApi;

  static Map<String, dynamic> _previewBody(String filename, String data) => {
    'filename': filename,
    'data': data,
  };

  /// 真正发出去的请求体有多少字节。恰好 6MB 的文件 base64 后就是 8MB，
  /// 再加 JSON 外壳和文件名就会吃服务端的 413，所以按整个请求体算。
  static int requestBytes(String filename, int fileBytes) =>
      utf8.encode(jsonEncode(_previewBody(filename, ''))).length +
      4 * ((fileBytes + 2) ~/ 3);

  static bool fits(String filename, int fileBytes) =>
      requestBytes(filename, fileBytes) <= maxBodyBytes;

  Future<ImportPreview> preview({
    required String filename,
    required Uint8List bytes,
  }) async {
    final res = await _uploadApi.post(
      '/import/preview',
      _previewBody(filename, base64Encode(bytes)),
    );
    return ImportPreview.fromJson(res);
  }

  /// 分批提交；一批整个失败（断网、服务器挂了）就停下，余下的都记成没发出去 ——
  /// clientId 是稳定的，用户再导一次同一个文件就能接着补上，不会重复入账。
  Future<ImportResult> submit(
    List<ImportItem> items, {
    required String channel,
    required String memberId,
    bool learn = true,
    void Function(int done, int total)? onProgress,
  }) async {
    var created = 0;
    var exists = 0;
    final failures = <ImportFailure>[];
    final landed = <ImportItem>[];
    onProgress?.call(0, items.length);

    for (var start = 0; start < items.length; start += batchSize) {
      final end = start + batchSize > items.length
          ? items.length
          : start + batchSize;
      final chunk = items.sublist(start, end);
      final Map<String, dynamic> res;
      try {
        res = await _api.post('/transactions/batch', {
          'items': [for (final item in chunk) item.toBatchJson()],
        });
      } on ApiException catch (e) {
        for (final item in items.sublist(start)) {
          failures.add(_failure(item, e.code, e.message, unsent: true));
        }
        break;
      }

      final byClientId = <String, Map<String, dynamic>>{
        for (final r in jsonMapList(res['results']))
          jsonString(r['clientId']): r,
      };
      for (final item in chunk) {
        final r = byClientId[item.row.clientId];
        switch (jsonString(r?['status'])) {
          case 'created':
            created++;
            landed.add(item);
          case 'exists':
            exists++;
            landed.add(item);
          case 'error':
            failures.add(
              _failure(
                item,
                jsonString(r?['error'], 'error'),
                jsonString(r?['message'], '服务端没收下这笔'),
              ),
            );
          default:
            failures.add(_failure(item, 'missing', '服务端没回这笔的结果'));
        }
      }
      onProgress?.call(end, items.length);
    }

    var learned = 0;
    String? learnError;
    if (learn) {
      final samples = [
        for (final item in landed)
          if (item.teaches)
            item.learnSample(channel: channel, memberId: memberId).toJson(),
      ];
      try {
        for (var i = 0; i < samples.length; i += learnChunk) {
          final end = i + learnChunk > samples.length
              ? samples.length
              : i + learnChunk;
          await _api.post('/model/learn', {'samples': samples.sublist(i, end)});
          learned = end;
        }
      } on ApiException catch (e) {
        learnError = e.message;
      }
    }

    return ImportResult(
      created: created,
      exists: exists,
      failures: failures,
      learned: learned,
      learnError: learnError,
    );
  }

  static ImportFailure _failure(
    ImportItem item,
    String code,
    String message, {
    bool unsent = false,
  }) => ImportFailure(
    row: item.row.row,
    clientId: item.row.clientId,
    code: code,
    message: message,
    unsent: unsent,
  );
}

final importRepoProvider = Provider<ImportRepo>((ref) {
  final api = ref.watch(apiProvider);
  // 几 MB 的 base64 走手机上行，默认 20 秒不够；只给上传这一个请求放宽。
  final upload = ApiClient(
    baseUrl: api.baseUrl,
    token: api.token,
    timeout: const Duration(minutes: 2),
  );
  ref.onDispose(upload.close);
  return ImportRepo(api, uploadApi: upload);
});
