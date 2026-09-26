import 'dart:convert';

import 'package:famledger/core/dates.dart';
import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/data/models/models.dart';
import 'package:famledger/ui/perks/perk_providers.dart';
import 'package:http/http.dart' as http;

import 'assets_harness.dart';

// 会员权益的假服务端（挂在 AssetsBackend 上）：只实现 App 会碰到的接口，行为照
// server/src/modules/platforms.js、memberships.js、benefits.js、benefit_events.js —— 重名 409 带已有 id、删除前查引用、
// 合并、有子项 409 / ?cascade=1、选项的 flow 跟父权益、打卡（N 选 1 父权益 400）与撤销、续费（默认原到期日 + 一个周期，
// once / none 409）。规范化名用 App 的 perkNameKey 近似服务端的 NFKC。

/// 本机记着上次看的是「全部」：P3 起会员权益 tab 默认打开「本期」，测「全部」视图的用例从这里起。
MemoryLocalStore allViewStore() => MemoryLocalStore()..write(PerkViewPrefsController.storeKey, {'view': 'all'});

Map<String, dynamic> platformJson(String id, {String name = '淘宝', List<String> aliases = const [], int sort = 0, bool archived = false}) => {
  'id': id,
  'name': name,
  'aliases': aliases,
  'kind': 'other',
  'icon': null,
  'color': null,
  'url': null,
  'note': null,
  'sortOrder': sort,
  'archived': archived,
  'deletedAt': null,
};

Map<String, dynamic> membershipJson(
  String id, {
  String platformId = 'tb',
  String name = '88VIP',
  String? tier,
  String kind = 'membership',
  String? memberId,
  int? feeCents,
  String feePeriod = 'year',
  int? termPaidCents,
  String? termStartOn,
  String? expiresOn,
  String autoRenew = 'unknown',
  bool isTrial = false,
  String? sourceBenefitId,
  int sort = 0,
  bool archived = false,
}) => {
  'id': id,
  'platformId': platformId,
  'sourceBenefitId': sourceBenefitId,
  'name': name,
  'tier': tier,
  'kind': kind,
  'memberId': memberId,
  'accountId': null,
  'feeCents': feeCents,
  'feePeriod': feePeriod,
  'termPaidCents': termPaidCents,
  'termStartOn': termStartOn,
  'expiresOn': expiresOn,
  'autoRenew': autoRenew,
  'isTrial': isTrial,
  'remindDays': null,
  'payPattern': null,
  'lastChargeTxId': null,
  'origin': <String, dynamic>{},
  'note': null,
  'sortOrder': sort,
  'archived': archived,
  'deletedAt': null,
};

Map<String, dynamic> benefitJson(
  String id, {
  String membershipId = 'vip',
  String? parentId,
  String name = '券',
  String kind = 'other',
  String? claimPlatformId,
  String? claimHow,
  String? claimUrl,
  String flow = 'claim',
  List<Map<String, dynamic>> quota = const [],
  List<Map<String, dynamic>> limits = const [],
  String? validFrom,
  String? validUntil,
  int? faceValueCents,
  int? myValueCents,
  String anchor = 'calendar',
  bool remind = true,
  int sort = 0,
  bool archived = false,
}) => {
  'id': id,
  'membershipId': membershipId,
  'parentId': parentId,
  'name': name,
  'kind': kind,
  'claimPlatformId': claimPlatformId,
  'claimHow': claimHow,
  'claimUrl': claimUrl,
  'flow': flow,
  'quota': quota,
  'anchor': anchor,
  'validFrom': validFrom,
  'validUntil': validUntil,
  'faceValueCents': faceValueCents,
  'myValueCents': myValueCents,
  'limits': limits,
  'remind': remind,
  'origin': <String, dynamic>{},
  'note': null,
  'sortOrder': sort,
  'archived': archived,
  'deletedAt': null,
};

Map<String, dynamic> eventJson(String id, String benefitId, {String kind = 'claim', String occurredOn = '2026-09-20', int count = 1, int? valueCents}) => {
  'id': id,
  'benefitId': benefitId,
  'kind': kind,
  'occurredOn': occurredOn,
  'count': count,
  'valueCents': valueCents,
  'memberId': null,
  'note': null,
  'deletedAt': null,
};

class PerksFake {
  PerksFake({
    List<Map<String, dynamic>> platforms = const [],
    List<Map<String, dynamic>> memberships = const [],
    List<Map<String, dynamic>> benefits = const [],
    List<Map<String, dynamic>> events = const [],
  }) {
    for (final p in platforms) {
      this.platforms[p['id'] as String] = {...p};
    }
    for (final m in memberships) {
      this.memberships[m['id'] as String] = {...m};
    }
    for (final b in benefits) {
      this.benefits[b['id'] as String] = {...b};
    }
    for (final e in events) {
      this.events[e['id'] as String] = {...e};
    }
  }

  final Map<String, Map<String, dynamic>> platforms = {};
  final Map<String, Map<String, dynamic>> memberships = {};
  final Map<String, Map<String, dynamic>> benefits = {};

  /// 打卡事件（/changes 的 benefit_events）。
  final Map<String, Map<String, dynamic>> events = {};

  /// 服务端有、App 还没同步到的打卡记录数（按权益 id）：删权益时照 benefits.js 的 canDelete 算进 409。
  final Map<String, int> unsyncedEvents = {};
  final List<Map<String, dynamic>> _tombstones = [];
  int _ids = 0;

  static const Set<String> resources = {'platforms', 'memberships', 'benefits', 'benefit-events'};

  Map<String, dynamic> changes() => {
    'platforms': [...platforms.values, ..._gone('platform')],
    'memberships': [...memberships.values, ..._gone('membership')],
    'benefits': [...benefits.values, ..._gone('benefit')],
    'benefit_events': [...events.values, ..._gone('event')],
  };

  Iterable<Map<String, dynamic>> _gone(String kind) => _tombstones.where((t) => t['_kind'] == kind);

  void _bury(String kind, Map<String, dynamic> row) =>
      _tombstones.add({...row, 'deletedAt': testNow.toUtc().toIso8601String(), '_kind': kind});

  /// 撤销导入（test/ui/import_fake.dart）用：把 [kind]（platform / membership / benefit）那一行删掉并留墓碑，/changes 带出去。
  void bury(String kind, String id) {
    final table = switch (kind) {
      'platform' => platforms,
      'membership' => memberships,
      _ => benefits,
    };
    final row = table.remove(id);
    if (row != null) _bury(kind, row);
  }

  String _id(String prefix) => '$prefix-new${++_ids}';

  http.Response handle(String method, List<String> seg, Map<String, dynamic> body, Map<String, String> query) {
    final cascade = query['cascade'] == '1';
    switch (seg.first) {
      case 'platforms':
        return _platforms(method, seg, body);
      case 'memberships':
        return _memberships(method, seg, body, cascade);
      case 'benefit-events':
        return _events(method, seg, body);
      default:
        return _benefits(method, seg, body, cascade);
    }
  }

  Map<String, dynamic>? _clash(String name, {String? except}) {
    final key = perkNameKey(name);
    for (final p in platforms.values) {
      if (p['id'] != except && perkNameKey(p['name'] as String) == key) return p;
    }
    return null;
  }

  http.Response _platforms(String method, List<String> seg, Map<String, dynamic> body) {
    if (method == 'POST' && seg.length == 1) {
      final name = (body['name'] as String).trim();
      final clash = _clash(name);
      if (clash != null) {
        return error(409, 'name_taken', '已经有叫「${clash['name']}」的平台了', {'id': clash['id'], 'name': clash['name']});
      }
      final row = platformJson(_id('p'), name: name, aliases: [...?(body['aliases'] as List?)?.cast<String>()], sort: platforms.length)
        ..['kind'] = body['kind'] ?? 'other'
        ..['url'] = body['url']
        ..['note'] = body['note'];
      platforms[row['id'] as String] = row;
      return ok({'platform': row}, 201);
    }
    final row = platforms[seg[1]];
    if (row == null) return error(404, 'not_found', '平台不存在');
    if (method == 'POST' && seg.length == 3 && seg[2] == 'merge') {
      final target = platforms[body['targetId']];
      if (target == null || target == row) return error(400, 'invalid_targetId', '目标平台不对');
      var ms = 0;
      var bs = 0;
      for (final m in memberships.values.where((m) => m['platformId'] == row['id'])) {
        m['platformId'] = target['id'];
        ms++;
      }
      for (final b in benefits.values.where((b) => b['claimPlatformId'] == row['id'])) {
        b['claimPlatformId'] = target['id'];
        bs++;
      }
      target['aliases'] = [...(target['aliases'] as List), row['name'], ...(row['aliases'] as List)];
      platforms.remove(seg[1]);
      _bury('platform', row);
      return ok({
        'platform': target,
        'moved': {'memberships': ms, 'benefits': bs},
      });
    }
    if (method == 'PATCH') {
      if (body['name'] is String) {
        final clash = _clash(body['name'] as String, except: row['id'] as String);
        if (clash != null) {
          return error(409, 'name_taken', '已经有叫「${clash['name']}」的平台了', {'id': clash['id'], 'name': clash['name']});
        }
      }
      row.addAll(body);
      return ok({'platform': row});
    }
    if (method == 'DELETE') {
      final ms = memberships.values.where((m) => m['platformId'] == row['id']).length;
      final bs = benefits.values.where((b) => b['claimPlatformId'] == row['id']).length;
      if (ms > 0 || bs > 0) {
        return error(409, 'platform_in_use', '还有 $ms 张会员卡挂在它下面，不能删；可以归档，或并入别的平台', {'memberships': ms, 'benefits': bs});
      }
      platforms.remove(seg[1]);
      _bury('platform', row);
      return ok({'platform': row});
    }
    return error(404, 'not_found', '没有这个接口');
  }

  http.Response _memberships(String method, List<String> seg, Map<String, dynamic> body, bool cascade) {
    if (method == 'POST' && seg.length == 1) {
      final row = membershipJson(_id('m'), platformId: body['platformId'] as String, name: body['name'] as String, sort: memberships.length);
      for (final e in body.entries) {
        if (e.key != 'clientId' && e.key != 'recordTransaction') row[e.key] = e.value;
      }
      if (body['recordTransaction'] != null) row['lastChargeTxId'] = 'tx-perk';
      memberships[row['id'] as String] = row;
      return ok({'membership': row}, 201);
    }
    final row = memberships[seg[1]];
    if (row == null) return error(404, 'not_found', '会员不存在');
    if (method == 'POST' && seg.length == 3 && seg[2] == 'renew') {
      final months = const {'month': 1, 'quarter': 3, 'year': 12}[row['feePeriod']];
      if (months == null) return error(409, 'not_renewable', '一次性或不收费的卡没有下一期，不用续费');
      final base = parseDay(row['expiresOn'] as String?) ?? addDays(localDay(testNow), -1);
      final expires = body['expiresOn'] is String ? parseDay(body['expiresOn'] as String)! : addMonthsClamped(base, months);
      if (!expires.isAfter(base)) return error(400, 'invalid_expiresOn', '新的到期日要晚于原来的到期日');
      final oneBack = addDays(addMonthsClamped(expires, -months), 1);
      final afterBase = addDays(base, 1);
      row
        ..['expiresOn'] = Dates.isoDate(expires)
        ..['termStartOn'] = Dates.isoDate(oneBack.isAfter(afterBase) ? oneBack : afterBase)
        ..['termPaidCents'] = body['paidCents']
        ..['isTrial'] = false;
      return ok({'membership': row});
    }
    if (method == 'PATCH') {
      row.addAll(body);
      return ok({'membership': row});
    }
    if (method == 'DELETE') {
      final mine = benefits.values.where((b) => b['membershipId'] == row['id']).toList();
      if (mine.isNotEmpty && !cascade) {
        return error(409, 'has_children', '这张卡下还有 ${mine.length} 项权益，要一起删掉吗？', {'benefits': mine.length});
      }
      for (final b in mine) {
        benefits.remove(b['id']);
        _bury('benefit', b);
        _dropEventsOf(b['id'] as String);
      }
      for (final m in memberships.values) {
        if (mine.any((b) => b['id'] == m['sourceBenefitId'])) m['sourceBenefitId'] = null;
      }
      memberships.remove(seg[1]);
      _bury('membership', row);
      return ok({'membership': row});
    }
    return error(404, 'not_found', '没有这个接口');
  }

  http.Response _benefits(String method, List<String> seg, Map<String, dynamic> body, bool cascade) {
    if (method == 'POST' && seg.length == 1) {
      final row = benefitJson(_id('b'), membershipId: body['membershipId'] as String, name: body['name'] as String, sort: benefits.length);
      for (final e in body.entries) {
        if (e.key != 'clientId') row[e.key] = e.value;
      }
      final parent = benefits[body['parentId']];
      if (parent != null) row['flow'] = parent['flow'];
      benefits[row['id'] as String] = row;
      return ok({'benefit': row}, 201);
    }
    final row = benefits[seg[1]];
    if (row == null) return error(404, 'not_found', '权益不存在');
    if (method == 'PATCH') {
      row.addAll(body);
      return ok({'benefit': row});
    }
    if (method == 'DELETE') {
      final options = benefits.values.where((b) => b['parentId'] == row['id']).toList();
      final family = [row, ...options];
      final eventCount = family.fold<int>(
        0,
        (n, b) => n + (unsyncedEvents[b['id']] ?? 0) + events.values.where((e) => e['benefitId'] == b['id']).length,
      );
      if ((options.isNotEmpty || eventCount > 0) && !cascade) {
        final parts = [if (options.isNotEmpty) '${options.length} 个选项', if (eventCount > 0) '$eventCount 条打卡记录'];
        return error(409, 'has_children', '这条下面还有 ${parts.join('、')}，要一起删掉吗？', {'options': options.length, 'events': eventCount});
      }
      for (final o in family) {
        benefits.remove(o['id']);
        unsyncedEvents.remove(o['id']);
        _dropEventsOf(o['id'] as String);
        _bury('benefit', o);
      }
      // 带出过的派生会员解开（benefits.js removeBenefits）。
      for (final m in memberships.values) {
        if (family.any((b) => b['id'] == m['sourceBenefitId'])) m['sourceBenefitId'] = null;
      }
      return ok({'benefit': row});
    }
    return error(404, 'not_found', '没有这个接口');
  }

  /// 打卡：新建（权益要在、不能是 N 选 1 本身，照 benefit_events.js）、撤销（软删带墓碑）。
  http.Response _events(String method, List<String> seg, Map<String, dynamic> body) {
    if (method == 'POST' && seg.length == 1) {
      final benefit = benefits[body['benefitId']];
      if (benefit == null) return error(400, 'invalid_benefitId', '权益不存在');
      if (benefit['kind'] == 'choice') return error(400, 'invalid_benefitId', '「N 选 1」本身不能打卡，点它下面选中的那一项');
      final row = eventJson(
        _id('e'),
        body['benefitId'] as String,
        kind: body['kind'] as String? ?? 'claim',
        occurredOn: body['occurredOn'] as String? ?? Dates.isoDate(testNow),
        count: body['count'] as int? ?? 1,
        valueCents: body['valueCents'] as int?,
      );
      events[row['id'] as String] = row;
      return ok({'event': row}, 201);
    }
    final row = events[seg.length > 1 ? seg[1] : ''];
    if (row == null) return error(404, 'not_found', '打卡记录不存在');
    if (method == 'DELETE') {
      events.remove(row['id']);
      _bury('event', row);
      return ok({'event': row});
    }
    return error(404, 'not_found', '没有这个接口');
  }

  /// 幂等重发时照 crud.js 的 reread：回那一行现在的样子 —— 打卡在这期间被删了就是墓碑（带 deletedAt）。
  Map<String, dynamic> reread(String path, Map<String, dynamic> first) {
    if (path != '/benefit-events' || first['event'] is! Map) return first;
    final id = (first['event'] as Map)['id'];
    final gone = _tombstones.where((t) => t['_kind'] == 'event' && t['id'] == id).lastOrNull;
    final row = events[id] ?? (gone == null ? null : ({...gone}..remove('_kind')));
    return row == null ? first : {'event': row};
  }

  void _dropEventsOf(String benefitId) {
    for (final e in events.values.where((e) => e['benefitId'] == benefitId).toList()) {
      events.remove(e['id']);
      _bury('event', e);
    }
  }

  static http.Response ok(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  static http.Response error(int status, String code, String message, [Map<String, dynamic>? details]) => http.Response(
    jsonEncode({
      'error': {'code': code, 'message': message, 'details': ?details},
    }),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}
