import 'dart:convert';

import 'package:http/http.dart' as http;

import 'assets_harness.dart';
import 'perks_fake.dart';

// AI 导入的假服务端（挂在 AssetsBackend 上）：`GET /ai/providers`、`POST /asset-import/extract`（SSE，回测试给的草稿）、
// `GET /asset-import/candidates`（回 [candidates]）、`POST /asset-import/fetch`（回 [page] 或 [fetchError]）、
// `POST /asset-import/apply`（照 server/src/lib/perk_import_apply.js 把平台 / 会员 / 权益 / 物品写进 PerksFake 和物品表，
// 写完 /changes 就能拿到）、`POST /asset-import/:id/undo`（把那次 apply 新建的删掉、留墓碑；撤过的再来原样回上次的结果并标
// replayed，照服务端）、`GET /asset-import/recent`（回 [recent]）。
// 幂等重放、failNext、dropResponseNext 都走 AssetsBackend 那一套。

class ImportFake {
  ImportFake({List<Map<String, dynamic>>? providers})
    : providers = providers ??
          [
            {'id': 'ai-1', 'name': '家里的 cc-trans', 'kind': 'anthropic', 'model': 'claude-sonnet-5', 'isDefault': true, 'enabled': true, 'hasKey': true},
          ];

  /// `GET /ai/providers` 回它。
  final List<Map<String, dynamic>> providers;

  /// 下一次识别回这份草稿（服务端 done 事件里的 draft）；[extractError] 非空时回 error 事件。
  Map<String, dynamic>? draft;
  (String, String)? extractError;

  /// 为真时流只吐进度、不给 done（像代理掐了长连接）；用一次就恢复。
  bool cutNextStream = false;

  /// 收到的识别 / 导入请求体。
  final List<Map<String, dynamic>> extractBodies = [];
  final List<Map<String, dynamic>> applyBodies = [];

  /// apply 时「同时记一笔」记了几笔（验「没有重复记账」）。
  int recordedTransactions = 0;

  /// 下一次导入回 400 这个错误体（{code, message, details}），用一次就恢复。
  Map<String, dynamic>? applyError;

  /// 每次 apply 新建了什么（importId → [(kind, id)]），撤销时照着删。
  final Map<String, List<(String, String)>> createdBy = {};

  /// 撤销请求的 importId。
  final List<String> undoCalls = [];

  /// 撤销回应里额外盖上的键（比如 skippedChanged / skippedInUse），不给就只报删了什么。
  Map<String, dynamic> undoExtra = const {};

  /// 撤过的：importId → 第一次的回应（再撤原样回、带 replayed）。
  final Map<String, Map<String, dynamic>> _undoReplies = {};

  /// `GET /asset-import/recent` 回的 items（服务端的形状）；撤过的自动不再列。
  List<Map<String, dynamic>> recent = [];

  /// `GET /asset-import/candidates` 回它（服务端的形状 {months, from, today, total, items}）；[candidatesError] 非空时回这个错误。
  Map<String, dynamic> candidates = const {'months': 13, 'total': 0, 'items': <Object>[]};
  (int, String, String)? candidatesError;

  /// `POST /asset-import/fetch` 回它（{url, finalUrl, title, text, chars, truncated, hint, message}）；[fetchError] 非空时回错误
  /// （[fetchErrorDetails] 是错误体的 details，比如被当成 fake-ip 拦下时的 {fakeIp: true}）。
  Map<String, dynamic>? page;
  (int, String, String)? fetchError;
  Map<String, dynamic>? fetchErrorDetails;

  /// 收到的抓取请求体。
  final List<Map<String, dynamic>> fetchBodies = [];

  static const Set<String> resources = {'ai', 'asset-import'};

  http.Response handle(String method, List<String> seg, Map<String, dynamic> body, AssetsBackend backend) {
    if (method == 'GET' && seg.join('/') == 'ai/providers') return PerksFake.ok({'items': providers});
    if (method == 'GET' && seg.join('/') == 'asset-import/recent') {
      return PerksFake.ok({
        'items': [
          for (final r in recent)
            if (!_undoReplies.containsKey(r['importId'])) r,
        ],
      });
    }
    if (method == 'GET' && seg.join('/') == 'asset-import/candidates') {
      final failure = candidatesError;
      return failure == null ? PerksFake.ok(candidates) : PerksFake.error(failure.$1, failure.$2, failure.$3);
    }
    if (method == 'POST' && seg.join('/') == 'asset-import/fetch') {
      fetchBodies.add(body);
      final failure = fetchError;
      if (failure != null) return PerksFake.error(failure.$1, failure.$2, failure.$3, fetchErrorDetails);
      return PerksFake.ok(page ?? const {'url': '', 'finalUrl': '', 'title': '', 'text': '', 'chars': 0, 'truncated': false});
    }
    if (method == 'POST' && seg.join('/') == 'asset-import/extract') return _extract(body);
    if (method == 'POST' && seg.join('/') == 'asset-import/apply') return _apply(body, backend);
    if (method == 'POST' && seg.length == 3 && seg[0] == 'asset-import' && seg[2] == 'undo') return _undo(seg[1], backend);
    return PerksFake.error(404, 'not_found', '没有这个接口');
  }

  http.Response _extract(Map<String, dynamic> body) {
    extractBodies.add(body);
    final out = StringBuffer(': open\n\n')..write('event: stage\ndata: ${jsonEncode({'stage': 'asking', 'message': '正在请模型识别…'})}\n\n');
    final error = extractError;
    final d = draft;
    if (error != null) {
      out.write('event: error\ndata: ${jsonEncode({'code': error.$1, 'message': error.$2})}\n\n');
    } else if (d != null) {
      final n = [for (final k in const ['platforms', 'memberships', 'benefits', 'items']) ...(d[k] as List)].length;
      out.write('event: record\ndata: ${jsonEncode({'n': n})}\n\n');
      if (cutNextStream) {
        cutNextStream = false;
      } else {
        out.write('event: done\ndata: ${jsonEncode({'importId': d['importId'], 'draft': d})}\n\n');
      }
    }
    return http.Response.bytes(utf8.encode(out.toString()), 200, headers: {'content-type': 'text/event-stream; charset=utf-8'});
  }

  http.Response _apply(Map<String, dynamic> body, AssetsBackend backend) {
    final failure = applyError;
    if (failure != null) {
      applyError = null;
      return PerksFake.error(400, failure['code'] as String, failure['message'] as String, failure['details'] as Map<String, dynamic>?);
    }
    applyBodies.add(body);
    final perks = backend.perks;
    final ids = <String, String>{};
    final created = {'platforms': 0, 'memberships': 0, 'benefits': 0, 'items': 0, 'transactions': 0};
    final updated = {'platforms': 0, 'memberships': 0, 'benefits': 0};
    String? ref(Object? raw) {
      if (raw is! String) return null;
      return raw.startsWith('key:') ? ids[raw.substring(4)] : raw.substring(3);
    }

    List<Map<String, dynamic>> list(String name) => (body[name] as List).cast<Map<String, dynamic>>();
    for (final p in list('platforms')) {
      final f = p['fields'] as Map<String, dynamic>;
      if (p['action'] == 'merge') {
        final target = perks.platforms[p['targetId']]!;
        if (target['name'] != f['name']) {
          target['aliases'] = [...(target['aliases'] as List), f['name']];
          updated['platforms'] = updated['platforms']! + 1;
        }
        ids[p['key'] as String] = target['id'] as String;
      } else if (p['action'] == 'create') {
        final id = 'p-imp-${p['key']}';
        perks.platforms[id] = platformJson(id, name: f['name'] as String, sort: perks.platforms.length);
        (createdBy[body['importId'] as String] ??= []).add(('platform', id));
        ids[p['key'] as String] = id;
        created['platforms'] = created['platforms']! + 1;
      }
    }
    for (final m in list('memberships')) {
      final f = m['fields'] as Map<String, dynamic>;
      if (m['action'] == 'create') {
        final id = 'm-imp-${m['key']}';
        perks.memberships[id] = membershipJson(
          id,
          platformId: ref(f['platform'])!,
          name: f['name'] as String,
          feeCents: f['feeCents'] as int?,
          feePeriod: f['feePeriod'] as String? ?? 'year',
          expiresOn: f['expiresOn'] as String?,
          autoRenew: f['autoRenew'] as String? ?? 'unknown',
          sort: perks.memberships.length,
        )..['origin'] = {'src': 'ai_text', 'importId': body['importId'], 'unverified': m['unverified']};
        (createdBy[body['importId'] as String] ??= []).add(('membership', id));
        ids[m['key'] as String] = id;
        created['memberships'] = created['memberships']! + 1;
      } else if (m['action'] == 'update') {
        // 假库里没有那一行（测试只关心提交体）就只记 id，不改。
        final row = perks.memberships[m['targetId']] ?? <String, dynamic>{};
        final take = (m['take'] as List).cast<String>();
        for (final k in take) {
          row[k] = k == 'archived' ? false : f[k];
        }
        ids[m['key'] as String] = m['targetId'] as String;
        // 和服务端一样：真改了才算「更新了」（同一段材料导两次时 take 是空的）。
        if (take.isNotEmpty) updated['memberships'] = updated['memberships']! + 1;
      }
    }
    final benefits = list('benefits');
    bool isOption(Map<String, dynamic> b) => (b['fields'] as Map)['parent'] is String && ((b['fields'] as Map)['parent'] as String).startsWith('key:');
    for (final b in [...benefits.where((b) => !isOption(b)), ...benefits.where(isOption)]) {
      if (b['action'] == 'update') {
        final row = perks.benefits[b['targetId']] ?? <String, dynamic>{};
        final take = (b['take'] as List).cast<String>();
        final f = b['fields'] as Map<String, dynamic>;
        for (final k in take) {
          if (k == 'archived') {
            row['archived'] = false;
          } else if (k == 'claimPlatform') {
            row['claimPlatformId'] = ref(f['claimPlatform']);
          } else {
            row[k] = f[k];
          }
        }
        ids[b['key'] as String] = b['targetId'] as String;
        if (take.isNotEmpty) updated['benefits'] = updated['benefits']! + 1;
        continue;
      }
      if (b['action'] != 'create') continue;
      final f = b['fields'] as Map<String, dynamic>;
      final id = 'b-imp-${b['key']}';
      perks.benefits[id] = benefitJson(
        id,
        membershipId: ref(f['membership'])!,
        parentId: ref(f['parent']),
        name: f['name'] as String,
        kind: f['kind'] as String? ?? 'other',
        claimPlatformId: ref(f['claimPlatform']),
        claimHow: f['claimHow'] as String?,
        flow: f['flow'] as String? ?? 'claim',
        quota: ((f['quota'] as List?) ?? const []).cast<Map<String, dynamic>>(),
        anchor: f['anchor'] as String? ?? 'calendar',
        limits: ((f['limits'] as List?) ?? const []).cast<Map<String, dynamic>>(),
        faceValueCents: f['faceValueCents'] as int?,
        sort: perks.benefits.length,
      );
      (createdBy[body['importId'] as String] ??= []).add(('benefit', id));
      ids[b['key'] as String] = id;
      created['benefits'] = created['benefits']! + 1;
    }
    for (final i in list('items')) {
      if (i['action'] != 'create') continue;
      final f = i['fields'] as Map<String, dynamic>;
      final id = 'a-imp-${i['key']}';
      final record = i['recordTransaction'] != null;
      if (record) recordedTransactions++;
      backend.assets[id] = assetJson(
        id,
        name: f['name'] as String,
        category: f['category'] as String? ?? 'other',
        price: f['priceCents'] as int,
        purchasedOn: f['purchasedOn'] as String,
        transactionId: i['linkTransactionId'] as String? ?? (record ? 'tx-imp-${i['key']}' : null),
        valuationMethod: f['valuationMethod'] as String?,
        rateBp: f['rateBp'] as int?,
        residualBp: f['residualBp'] as int?,
        netWorth: f['netWorth'] as String?,
      )..['origin'] = {'src': 'ai_text', 'importId': body['importId'], 'unverified': i['unverified']};
      (createdBy[body['importId'] as String] ??= []).add(('asset', id));
      if (record) (createdBy[body['importId'] as String] ??= []).add(('transaction', 'tx-imp-${i['key']}'));
      ids[i['key'] as String] = id;
      created['items'] = created['items']! + 1;
      if (record) created['transactions'] = created['transactions']! + 1;
    }
    return PerksFake.ok({'importId': body['importId'], 'created': created, 'updated': updated, 'autoMerged': <Object>[], 'ids': ids});
  }

  http.Response _undo(String importId, AssetsBackend backend) {
    undoCalls.add(importId);
    final first = _undoReplies[importId];
    if (first != null) return PerksFake.ok({...first, 'replayed': true});
    final undone = {'platforms': 0, 'memberships': 0, 'benefits': 0, 'items': 0, 'transactions': 0, 'events': 0};
    for (final (kind, id) in (createdBy.remove(importId) ?? const <(String, String)>[]).reversed) {
      switch (kind) {
        case 'asset':
          backend.buryAsset(id);
          undone['items'] = undone['items']! + 1;
        case 'transaction':
          undone['transactions'] = undone['transactions']! + 1;
        default:
          backend.perks.bury(kind, id);
          undone['${kind}s'] = undone['${kind}s']! + 1;
      }
    }
    final reply = {
      'importId': importId,
      'undone': undone,
      'restored': {'memberships': 0, 'benefits': 0},
      'aliasesRemoved': 0,
      'skippedChanged': <Object>[],
      'skippedInUse': <Object>[],
      ...undoExtra,
    };
    _undoReplies[importId] = reply;
    return PerksFake.ok(reply);
  }
}
