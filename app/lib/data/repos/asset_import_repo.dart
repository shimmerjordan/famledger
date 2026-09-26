import 'dart:async';

import '../api/api_client.dart';
import '../models/models.dart';
import 'ledger_repo.dart';

/// AI 智能导入（`server/src/modules/asset_import.js`）：识别走 SSE，一边收一边吐进度；导入成功后做一次增量同步，
/// 新建、更新的平台 / 会员 / 权益 / 物品（和随物品记的流水）跟着过来。
class AssetImportRepo {
  AssetImportRepo({required ApiClient api, required LedgerRepo ledger})
    : _api = api,
      _ledger = ledger;

  final ApiClient _api;
  final LedgerRepo _ledger;

  /// 粘贴文字识别（本阶段只有 `kind: 'text'`）。取消订阅 = 断开连接，服务端随即中止上游。
  /// `error` 事件抛成 [ApiException]（status 0，code 是服务端给的 ai_bad_output / ai_timeout / ai_upstream / ai_refusal）；
  /// 没等到 done 流就断了，抛「可能已经送到」的网络错误。
  ///
  /// 用转换器而不是在 async* 的 await for 里 throw：那样要先等底下的 SSE 连接收尾才把错误交出去，收尾慢（长连接、代理）
  /// 时界面就一直停在「正在识别」。
  Stream<ImportEvent> extract({
    required String text,
    ImportWant want = ImportWant.auto,
    String? targetMembershipId,
    String? providerId,
  }) {
    final body = <String, dynamic>{'kind': 'text', 'text': text, 'want': want.wire};
    putIfNotNull(body, 'targetMembershipId', targetMembershipId);
    putIfNotNull(body, 'providerId', providerId);
    var finished = false;
    void finish(EventSink<ImportEvent> sink) {
      if (finished) return;
      finished = true;
      sink.close();
    }

    return _api.sse('/asset-import/extract', body).transform(
      StreamTransformer<SseEvent, ImportEvent>.fromHandlers(
        handleData: (e, sink) {
          if (finished) return;
          final json = e.json;
          switch (e.event) {
            case 'stage':
              sink.add(ImportStage(jsonString(json['message'])));
            case 'record':
              sink.add(ImportProgress(jsonInt(json['n'])));
            case 'done':
              sink.add(ImportDone(jsonString(json['importId']), jsonMap(json['draft'])));
              finish(sink);
            case 'error':
              final message = jsonString(json['message']);
              sink.addError(ApiException(
                0,
                jsonString(json['code'], 'ai_error'),
                message.isEmpty ? 'AI 渠道出错了，去「设置 → AI 渠道」测一下。' : message,
              ));
              finish(sink);
          }
        },
        handleError: (error, stack, sink) {
          if (finished) return;
          sink.addError(error, stack);
          finish(sink);
        },
        handleDone: (sink) {
          // 流断了却没等到 done / error：多半是网络或代理掐了长连接。
          if (!finished) {
            sink.addError(const ApiException(0, 'network', '识别到一半连接断了，再试一次；已经识别的不会记账。', maybeSent: true));
          }
          finish(sink);
        },
      ),
    );
  }

  /// 导入。[body] 由 PerkImportDraft.toApplyBody 生成（带 clientId：回应丢了重发只导一次）。
  /// 400 `import_invalid` 时 `ApiException.details['errors']` 是 `[{key, field, message}]`，原样抛出。
  Future<PerkImportResult> apply(Map<String, dynamic> body) async {
    final result = PerkImportResult.fromJson(await _api.post('/asset-import/apply', body));
    try {
      await _ledger.sync();
    } catch (_) {
      // 导进去了，只是这次没同步下来；下拉刷新或下次打开会补上。
    }
    return result;
  }
}
