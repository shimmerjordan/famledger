import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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

  /// 识别：给了 [images]（截图切好的 PNG）就是 `kind: 'image'`，否则是粘贴文字 `kind: 'text'`。取消订阅 = 断开连接，服务端随即中止上游。
  /// `error` 事件抛成 [ApiException]（status 0，code 是服务端给的 ai_bad_output / ai_timeout / ai_upstream / ai_refusal）；
  /// 没等到 done 流就断了，抛「可能已经送到」的网络错误。
  Stream<ImportEvent> extract({
    String text = '',
    List<Uint8List> images = const [],
    ImportWant want = ImportWant.auto,
    String? targetMembershipId,
    String? providerId,
  }) {
    final body = images.isEmpty
        ? <String, dynamic>{'kind': 'text', 'text': text, 'want': want.wire}
        : <String, dynamic>{
            'kind': 'image',
            'images': [
              for (final png in images) {'mediaType': 'image/png', 'data': base64Encode(png)},
            ],
            'want': want.wire,
          };
    putIfNotNull(body, 'targetMembershipId', targetMembershipId);
    putIfNotNull(body, 'providerId', providerId);
    return _extract(body);
  }

  /// 网址：[text] 是先抓下来（[fetchPage]）、给人改过的正文，[sourceUrl] 是抓到的地址（跟完跳转之后的）。服务端当粘贴文字识别。
  Stream<ImportEvent> extractUrl({
    required String text,
    required String sourceUrl,
    ImportWant want = ImportWant.auto,
    String? targetMembershipId,
    String? providerId,
  }) {
    final body = <String, dynamic>{'kind': 'url', 'text': text, 'sourceUrl': sourceUrl, 'want': want.wire};
    putIfNotNull(body, 'targetMembershipId', targetMembershipId);
    putIfNotNull(body, 'providerId', providerId);
    return _extract(body);
  }

  /// 从流水：[groups] 是勾选的候选分组 key（[candidates] 给的），[months] 要和取候选时一样。[useAi] 为假是「直接生成」（不调模型、
  /// 不带渠道）；为真是「AI 整理名称」。
  Stream<ImportEvent> extractTransactions({required List<String> groups, bool useAi = false, int months = 13, String? providerId}) {
    final body = <String, dynamic>{'kind': 'transactions', 'groups': groups, 'months': months, 'useAi': useAi};
    if (useAi) putIfNotNull(body, 'providerId', providerId);
    return _extract(body);
  }

  /// 从流水识别的候选分组（纯规则，不花 token）。
  Future<SubscriptionCandidates> candidates({int months = 13}) async =>
      SubscriptionCandidates.fromJson(await _api.get('/asset-import/candidates', query: {'months': '$months'}));

  /// 抓一个网页的正文（服务端抓、防 SSRF）。被拦、超时、打不开抛 [ApiException]（message 是给人看的说明）；
  /// PDF、登录墙、正文太短不算失败，看 [FetchedPage.hint]。
  Future<FetchedPage> fetchPage(String url) async => FetchedPage.fromJson(await _api.post('/asset-import/fetch', {'url': url}));

  /// 用转换器而不是在 async* 的 await for 里 throw：那样要先等底下的 SSE 连接收尾才把错误交出去，收尾慢（长连接、代理）
  /// 时界面就一直停在「正在识别」。
  Stream<ImportEvent> _extract(Map<String, dynamic> body) {
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

  /// 7 天内导入了、还没撤销的（本人的；管理员看全家的），新的在前。
  Future<List<RecentImport>> recent() async {
    final json = await _api.get('/asset-import/recent');
    return jsonList(json['items'], RecentImport.fromJson);
  }

  /// 撤销一次导入（7 天内、本人或管理员）。撤完同步一次，删掉的、改回去的跟着过来；撤过的再来服务端原样回（replayed）。
  Future<PerkImportUndoResult> undo(String importId) async {
    final result = PerkImportUndoResult.fromJson(await _api.post('/asset-import/$importId/undo', const {}));
    try {
      await _ledger.sync();
    } catch (_) {
      // 撤掉了，只是这次没同步下来；下拉刷新或下次打开会补上。
    }
    return result;
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
