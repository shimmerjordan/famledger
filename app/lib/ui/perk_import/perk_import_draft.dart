import 'package:flutter/foundation.dart';

import '../../core/ids.dart';
import '../../data/models/models.dart';
import '../../data/repos/assets_repo.dart' show ValuationInput;

/// 预览列表的筛选 chip（spec §6）：全部 / 需确认 / 新建 / 更新 / 未勾选。
enum ImportFilter { all, attention, create, update, unchecked }

/// 「领取平台」映射视图里一行的四个选项：已有平台（比对命中的那个）/ 新建 / 并入…（另选一个已有平台）/ 就是会员本平台。
enum ClaimMode { existing, create, mergeInto, self }

/// 挡住导入的一处：哪个节点、为什么。
class ImportBlocker {
  const ImportBlocker(this.node, this.reason);

  final ImportNode node;
  final String reason;
}

/// 「领取平台」映射视图的一行：一个被权益当作领取平台的平台节点。
class ClaimRow {
  const ClaimRow({required this.node, required this.mode, required this.benefits});

  final ImportNode node;
  final ClaimMode mode;

  /// 引用它的权益（勾着的和没勾的都算）。
  final List<ImportNode> benefits;
}

/// 这些字段在预览里改过就算人工确认过：从 unverified 里拿掉（草稿字段名 → origin 里的 API 字段名）。
const Map<String, String> _apiField = {'claimPlatform': 'claimPlatformId'};

/// 各类节点勾着导入时必须有的字段（spec §6「导入按钮只被两类情况拦住」）。
const Map<String, List<String>> _required = {
  ImportNode.platform: ['name'],
  ImportNode.membership: ['name', 'platform'],
  ImportNode.benefit: ['name', 'membership'],
  ImportNode.item: ['name', 'priceCents', 'purchasedOn'],
};

const Map<String, String> _requiredLabel = {
  'name': '名称',
  'platform': '平台',
  'membership': '归到哪张卡',
  'priceCents': '价格',
  'purchasedOn': '购买日期',
};

/// 更新已有的行时能写的字段（和服务端 lib/perk_import_apply.js 的 MEMBERSHIP_TAKE / BENEFIT_TAKE 一致；
/// 恢复归档的 archived 只在差异里勾，不算「改字段」）。预览里改了这些字段，导入时就要写进去。
const Map<String, List<String>> _takeable = {
  ImportNode.membership: ['name', 'tier', 'kind', 'feeCents', 'feePeriod', 'termStartOn', 'expiresOn', 'autoRenew', 'isTrial'],
  ImportNode.benefit: ['name', 'kind', 'claimPlatform', 'claimHow', 'claimUrl', 'flow', 'quota', 'anchor', 'validFrom', 'validUntil', 'faceValueCents', 'limits'],
};

/// 一次最多导入多少（服务端同一道闸，只数勾着的）：类型 → (上限, 名称, 量词)。
const Map<String, (int, String, String)> _limits = {
  ImportNode.platform: (50, '平台', '个'),
  ImportNode.membership: (50, '会员卡', '张'),
  ImportNode.benefit: (200, '权益', '项'),
  ImportNode.item: (50, '物品', '件'),
};

/// 两个 JSON 值是不是一样（列表逐项、对象逐键，不看键的先后）：额度 `[{p, n}]` 这种从库里来的和表单里拼的键序可能不同。
bool _sameValue(Object? a, Object? b) {
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_sameValue(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) return a.length == b.length && a.keys.every((k) => b.containsKey(k) && _sameValue(a[k], b[k]));
  return a == b;
}

/// 两个 `YYYY-MM-DD` 差几天（认不出的回 null）。
int? _daysBetween(String? a, String? b) {
  final x = a == null ? null : DateTime.tryParse('${a.length >= 10 ? a.substring(0, 10) : a}T00:00:00Z');
  final y = b == null ? null : DateTime.tryParse('${b.length >= 10 ? b.substring(0, 10) : b}T00:00:00Z');
  return x == null || y == null ? null : x.difference(y).inDays.abs();
}

/// AI 导入的预览草稿（spec §6「预览」）：四张节点表、勾选联动、映射视图、批量操作、拦截规则和 apply 请求体。
///
/// 草稿用 autoDispose 的 StateProvider 从识别页交给预览页（ui/perk_import/perk_import_providers.dart），不走路由 extra。
/// [clientId] 在草稿活着的时候不变：导入的回应丢在路上再点一次，服务端认得出是同一次（只导一次）。
class PerkImportDraft extends ChangeNotifier {
  PerkImportDraft({
    required this.importId,
    required this.want,
    required this.platforms,
    required this.memberships,
    required this.benefits,
    required this.items,
    this.truncated = false,
    this.notices = const [],
    this.sourceText = '',
    this.targetMembershipId,
    String? clientId,
  }) : clientId = clientId ?? newClientId() {
    // 服务端给的默认勾选里，没归属、疑似照抄示例的权益不勾；只被它们当领取平台的补建平台也别导。
    _releaseClaimPlatforms();
    // 单独的平台（下面没挂卡、也没有权益去它那领）默认不导：导了只是多一个空平台，或者悄悄给已有平台加个别名。
    for (final p in platforms) {
      if (!_hosts(p) && !_claimed(p)) p.checked = false;
    }
  }

  factory PerkImportDraft.fromJson(Map<String, dynamic> json, {String? clientId}) => PerkImportDraft(
    importId: jsonString(json['importId']),
    want: ImportWant.parse(jsonStringOrNull(json['want'])),
    platforms: jsonList(json['platforms'], ImportNode.fromJson),
    memberships: jsonList(json['memberships'], ImportNode.fromJson),
    benefits: jsonList(json['benefits'], ImportNode.fromJson),
    items: jsonList(json['items'], ImportNode.fromJson),
    truncated: jsonBool(json['truncated']),
    notices: jsonStringList(json['notices']),
    sourceText: jsonString(jsonMap(json['source'])['text']),
    targetMembershipId: jsonStringOrNull(json['targetMembershipId']),
    clientId: clientId,
  );

  final String importId;
  final ImportWant want;
  final List<ImportNode> platforms;
  final List<ImportNode> memberships;
  final List<ImportNode> benefits;
  final List<ImportNode> items;

  /// 模型没写完（截断）：预览顶部横幅提示分段导入。
  final bool truncated;
  final List<String> notices;

  /// 发给模型的原文（打过码、可能挑过段落）：依据的 span 是它的下标。
  final String sourceText;
  final String? targetMembershipId;
  final String clientId;

  /// 「并入…」「就是会员本平台」这两种映射要记住（action 只分得出 merge / create）。
  final Map<String, ClaimMode> _claimModes = {};

  /// 上一次导入失败时服务端报回来的：key → 原因、key → 字段。
  final Map<String, String> _errors = {};
  final Map<String, String?> _errorFields = {};

  Iterable<ImportNode> get all => [...platforms, ...memberships, ...benefits, ...items];

  ImportNode? node(String key) {
    for (final n in all) {
      if (n.key == key) return n;
    }
    return null;
  }

  /// 'key:m1' → 那个节点；'id:…' 或 null → null。
  ImportNode? refNode(Object? ref) =>
      ref is String && ref.startsWith('key:') ? node(ref.substring(4)) : null;

  // —— 树 ——

  bool _hosts(ImportNode p) => memberships.any((m) => m.fields['platform'] == 'key:${p.key}');
  bool _claimed(ImportNode p) => benefits.any((b) => b.fields['claimPlatform'] == 'key:${p.key}');

  /// 树的第一层：下面挂着会员的平台节点（只被当作领取平台的在映射视图里，单独的在 [standalonePlatforms]）。
  List<ImportNode> get rootPlatforms => [
    for (final p in platforms)
      if (_hosts(p)) p,
  ];

  /// 「单独的平台」：下面没挂卡、也没有权益去它那领（材料里单列了一个平台名）。默认不导，放在树末尾让人看得见、想导再勾。
  /// 补建出来又没人用了的（改去别处领之后）不列 —— 它自己跟着不导。
  List<ImportNode> get standalonePlatforms => [
    for (final p in platforms)
      if (!_hosts(p) && !_claimed(p) && (!p.implied || p.checked)) p,
  ];

  /// 挂到账本里已有平台（'id:…'）下的卡引用了哪些平台（没写平台的卡在预览里选了一个已有的）。
  List<String> get existingPlatformRefs => [
    for (final ref in {
      for (final m in memberships)
        if (m.fields['platform'] is String && (m.fields['platform'] as String).startsWith('id:')) m.fields['platform'] as String,
    })
      ref,
  ];

  List<ImportNode> membershipsOfRef(String ref) => [
    for (final m in memberships)
      if (m.fields['platform'] == ref) m,
  ];

  List<ImportNode> membershipsOf(ImportNode platform) => [
    for (final m in memberships)
      if (m.fields['platform'] == 'key:${platform.key}') m,
  ];

  /// 没写平台的会员（缺字段，挡导入）。
  List<ImportNode> get homelessMemberships => [
    for (final m in memberships)
      if (m.fields['platform'] == null) m,
  ];

  /// 挂在某张卡下的顶层权益（[ref] 是 'key:m1' 或 'id:…'）。
  List<ImportNode> benefitsOf(String ref) => [
    for (final b in benefits)
      if (b.fields['membership'] == ref && b.fields['parent'] == null) b,
  ];

  List<ImportNode> optionsOf(ImportNode parent) => [
    for (final b in benefits)
      if (b.fields['parent'] == 'key:${parent.key}') b,
  ];

  /// 归到已有卡（'id:…'）下的权益引用了哪些卡（会员详情的「AI 补充权益」、移到已有卡下）。
  List<String> get existingCardRefs => [
    for (final ref in {
      for (final b in benefits)
        if (b.fields['membership'] is String && (b.fields['membership'] as String).startsWith('id:')) b.fields['membership'] as String,
    })
      ref,
  ];

  /// 「未归属」：找不到所属会员的权益。
  List<ImportNode> get unowned => [
    for (final b in benefits)
      if (b.fields['membership'] == null && b.fields['parent'] == null) b,
  ];

  // —— 勾选联动 ——

  /// 取消父节点时子节点跟着取消；勾子节点时，父节点是新建的就一起勾上（spec §6）。
  void setChecked(String key, bool value) {
    final n = node(key);
    if (n == null) return;
    if (value) {
      _check(n);
    } else {
      _uncheck(n);
      _releaseClaimPlatforms();
    }
    notifyListeners();
  }

  void _uncheck(ImportNode n) {
    n.checked = false;
    if (n.t == ImportNode.item && n.matchKind == 'exists') n.action = 'skip';
    for (final child in _children(n)) {
      _uncheck(child);
    }
  }

  void _check(ImportNode n) {
    n.checked = true;
    // 「已存在」的物品勾上 = 照样新建一件（同款又买了一件）；取消勾选再回到跳过。
    if (n.t == ImportNode.item && n.action == 'skip') n.action = 'create';
    for (final ref in _parents(n)) {
      final p = refNode(ref);
      // 父节点是新建的一起勾上；同名多张还没选的也勾上 —— 让它以「要选」挡住导入，而不是发出去被服务端报「没有导入」。
      if (p != null && !p.checked && (p.action == 'create' || p.action == 'pick')) _check(p);
    }
  }

  Iterable<ImportNode> _children(ImportNode n) sync* {
    final ref = 'key:${n.key}';
    switch (n.t) {
      case ImportNode.platform:
        yield* memberships.where((m) => m.fields['platform'] == ref);
      case ImportNode.membership:
        yield* benefits.where((b) => b.fields['membership'] == ref);
      case ImportNode.benefit:
        yield* benefits.where((b) => b.fields['parent'] == ref);
    }
  }

  /// 只当领取平台用的平台（下面没挂卡）跟着引用它的权益走：勾着的权益里没人再引用它了（都取消了、改去别处领了），
  /// 它也不导。它不在树里（只在映射视图和筛选列表里），不这样的话会导进去一个用户看不见的空平台。
  /// 只在「取消 / 改引用」之后跑：用户在筛选列表里亲手勾上的不去动它。
  void _releaseClaimPlatforms() {
    for (final p in platforms) {
      final ref = 'key:${p.key}';
      if (!p.checked || memberships.any((m) => m.fields['platform'] == ref)) continue;
      final claimedBy = benefits.where((b) => b.fields['claimPlatform'] == ref);
      if (claimedBy.isEmpty ? p.implied : !claimedBy.any((b) => b.checked)) p.checked = false;
    }
  }

  /// 往上的引用：会员 → 平台；权益 → 会员、父权益、领取平台（映射成「会员本平台」的不算）。
  List<Object?> _parents(ImportNode n) => switch (n.t) {
    ImportNode.membership => [n.fields['platform']],
    ImportNode.benefit => [
      n.fields['membership'],
      n.fields['parent'],
      if (_claimModeOf(refNode(n.fields['claimPlatform'])) != ClaimMode.self) n.fields['claimPlatform'],
    ],
    _ => const [],
  };

  // —— 编辑 ——

  /// 改一个字段：改过就算确认过（unverified 拿掉、「领取平台待确认」消失）。更新已有的行时，改了的字段导入时一定写进去。
  void setField(String key, String field, Object? value) {
    final n = node(key);
    if (n == null) return;
    final before = n.fields[field];
    n.fields[field] = value;
    n.unverified.remove(_apiField[field] ?? field);
    _touch(n, field);
    if (field == 'claimPlatform') {
      n.badges.remove('claim_unsure');
      if (n.checked) _check(n);
      _releaseClaimPlatforms();
    }
    if (field == 'platform' && n.t == ImportNode.membership) {
      if (n.checked) _check(n);
      // 换了挂的平台：原来那个下面没卡了、也没人去它那领，就跟着不导（不然导进去一个空平台）。
      final old = refNode(before);
      if (old != null && !_hosts(old) && !_claimed(old)) old.checked = false;
    }
    if (n.t == ImportNode.item && (field == 'priceCents' || field == 'purchasedOn')) _dropStaleLink(n);
    _errors.remove(key);
    notifyListeners();
  }

  /// 预览里人工改了 [field]：记进 edited；更新已有的行时它就要写进去 —— 差异里有就换成新值并勾上，没有就补一条勾上的
  /// （原来的值取服务端给的 current）。改回了和库里现在一样的值，就不算差异，这一条拿掉。
  void _touch(ImportNode n, String field) {
    if (!(_takeable[n.t]?.contains(field) ?? false)) return;
    n.edited.add(field);
    _syncEdit(n, field);
  }

  void _syncEdit(ImportNode n, String field) {
    if (n.action != 'update') return;
    final d = n.diff.where((x) => x.field == field).firstOrNull;
    final hasOld = n.current.containsKey(field);
    if (hasOld && _sameValue(_effective(n, field), n.current[field])) {
      if (d != null) n.diff.remove(d);
      return;
    }
    if (d != null) {
      d
        ..newValue = n.fields[field]
        ..take = true;
    } else {
      n.diff.add(ImportDiff(field: field, oldValue: n.current[field], newValue: n.fields[field], take: true, hasOld: hasOld));
    }
  }

  /// 导入时这个字段实际会写成什么，好和 current 比：领取平台按映射算（会员本平台 / 不导的新建平台 → null，
  /// 并入已有平台的 → 'id:那个平台'），别的就是字段本身。
  Object? _effective(ImportNode n, String field) {
    if (field != 'claimPlatform') return n.fields[field];
    final ref = claimRefOf(n);
    final p = refNode(ref);
    return p != null && p.action == 'merge' && p.targetId != null ? 'id:${p.targetId}' : ref;
  }

  /// 差异整份换过（选定了另一张卡）之后，把人工改过的字段重新盖上去。
  void _syncEdits(ImportNode n) {
    for (final f in n.edited) {
      _syncEdit(n, f);
    }
  }

  /// 物品改了价格或日期：挂着的那笔流水对不上了（金额不同、日期差 3 天以上）就不再关联，免得挂到一笔不是买它花的钱上。
  void _dropStaleLink(ImportNode n) {
    if (n.link != ItemLink.link) return;
    final tx = n.txCandidates.where((c) => c.id == n.linkTransactionId).firstOrNull;
    if (tx == null || !txFits(n, tx)) {
      n.link = ItemLink.none;
      n.linkTransactionId = null;
    }
  }

  /// 这笔候选和物品现在的价格、日期还对得上吗（同金额、日期 ±3 天，和服务端列候选的口径一样）。
  bool txFits(ImportNode n, ImportTxCandidate c) {
    final days = _daysBetween(c.day, jsonStringOrNull(n.fields['purchasedOn']));
    return jsonIntOrNull(n.fields['priceCents']) == c.amountCents && days != null && days <= 3;
  }

  /// 物品现在还能关联的流水候选（改了价格或日期，对不上的就不列了）。
  List<ImportTxCandidate> txCandidatesOf(ImportNode n) => [
    for (final c in n.txCandidates)
      if (txFits(n, c)) c,
  ];

  /// 同名多张卡（pick）、或命中的是归档的那张：选定更新 [targetId] 那张，或者 null = 新建一张。
  /// 换上服务端给那张候选算好的差异、库里现在的值和「未提及」，卡下的权益也换上按那张卡比对的结果（库里有同名的就是更新它）。
  void pickMembership(String key, String? targetId) {
    final n = node(key);
    if (n == null) return;
    final candidate = targetId == null ? null : n.candidates.where((c) => c['id'] == targetId).firstOrNull;
    n.action = targetId == null ? 'create' : 'update';
    n.targetId = targetId;
    n.badges.remove('ambiguous');
    n.diff = candidate == null ? [] : jsonList(candidate['diff'], ImportDiff.fromJson);
    n.current = candidate == null ? {} : jsonMap(candidate['current']);
    n.notMentioned = candidate == null ? [] : jsonMapList(candidate['notMentioned']);
    _syncEdits(n);
    for (final b in benefits.where((b) => b.fields['membership'] == 'key:$key')) {
      final hit = targetId == null ? null : b.byCard[targetId];
      if (hit == null) {
        b
          ..action = 'create'
          ..targetId = null
          ..match = const {'kind': 'none'}
          ..diff = []
          ..current = {};
      } else {
        b
          ..action = 'update'
          ..targetId = jsonStringOrNull(hit['targetId'])
          ..match = jsonMap(hit['match'])
          ..diff = jsonList(hit['diff'], ImportDiff.fromJson)
          ..current = jsonMap(hit['current']);
        _syncEdits(b);
      }
    }
    notifyListeners();
  }

  /// 「不是同一件」之类：用户看过了，去掉这个提醒徽章。
  void dismissBadge(String key, String badge) {
    node(key)?.badges.remove(badge);
    notifyListeners();
  }

  void setDiffTake(String key, String field, bool take) {
    final d = node(key)?.diff.where((x) => x.field == field).firstOrNull;
    if (d == null) return;
    d.take = take;
    notifyListeners();
  }

  /// 物品和流水的关系：关联 [transactionId] 那笔 / 同时记一笔 / 不记账。
  void setLink(String key, ItemLink link, {String? transactionId}) {
    final n = node(key);
    if (n == null) return;
    n.link = link;
    n.linkTransactionId = link == ItemLink.link ? transactionId : null;
    notifyListeners();
  }

  // —— 领取平台映射视图 ——

  ClaimMode _claimModeOf(ImportNode? p) {
    if (p == null) return ClaimMode.create;
    final remembered = _claimModes[p.key];
    if (remembered != null) return remembered;
    return p.action == 'merge' ? ClaimMode.existing : ClaimMode.create;
  }

  /// 每个被权益当作领取平台的平台节点一行（按草稿里的先后）。
  List<ClaimRow> get claimRows => [
    for (final p in platforms)
      if (benefits.any((b) => b.fields['claimPlatform'] == 'key:${p.key}'))
        ClaimRow(
          node: p,
          mode: _claimModeOf(p),
          benefits: [
            for (final b in benefits)
              if (b.fields['claimPlatform'] == 'key:${p.key}') b,
          ],
        ),
  ];

  /// 选一种映射。existing = 并入比对命中的那个；mergeInto = 并入 [targetId]（名字写进它的别名）；self = 就是会员本平台。
  /// 选了就算确认过：这些权益的「领取平台待确认」消失。
  void mapClaim(String platformKey, ClaimMode mode, {String? targetId}) {
    final p = node(platformKey);
    if (p == null) return;
    switch (mode) {
      case ClaimMode.existing:
        final id = jsonStringOrNull(p.match['id']);
        if (id == null) return;
        p.action = 'merge';
        p.targetId = id;
        _claimModes.remove(p.key);
      case ClaimMode.mergeInto:
        if (targetId == null) return;
        p.action = 'merge';
        p.targetId = targetId;
        _claimModes[p.key] = ClaimMode.mergeInto;
      case ClaimMode.create:
        p.action = 'create';
        p.targetId = null;
        _claimModes.remove(p.key);
      case ClaimMode.self:
        _claimModes[p.key] = ClaimMode.self;
    }
    // 选过就算确认过：「可能重复」消失。
    p.badges.remove('maybe_dup');
    // 只当领取平台用、又映射成「会员本平台」的节点不用导；否则跟着引用它的权益勾上（单独的平台选了也就是要导它）。
    if (!_hosts(p)) {
      p.checked = _claimed(p) ? mode != ClaimMode.self && benefits.any((b) => b.checked && b.fields['claimPlatform'] == 'key:${p.key}') : true;
    }
    for (final b in benefits.where((b) => b.fields['claimPlatform'] == 'key:${p.key}')) {
      b.badges.remove('claim_unsure');
      b.unverified.remove('claimPlatformId');
      // 库里已有的权益：用户刚定了它去哪领，导入时写进去。
      _touch(b, 'claimPlatform');
    }
    notifyListeners();
  }

  /// 映射视图的「全部确认」：照现在的选择，所有「领取平台待确认」「可能重复」一起消失。
  void confirmAllClaims() {
    for (final b in benefits) {
      b.badges.remove('claim_unsure');
      b.unverified.remove('claimPlatformId');
    }
    for (final row in claimRows) {
      row.node.badges.remove('maybe_dup');
    }
    notifyListeners();
  }

  /// 权益实际的领取平台引用：映射成「会员本平台」的、没勾的新建平台（它不导）都当会员本平台（null）。
  Object? claimRefOf(ImportNode b) {
    final raw = b.fields['claimPlatform'];
    final p = refNode(raw);
    if (p == null) return raw;
    if (_claimModeOf(p) == ClaimMode.self) return null;
    if (!p.checked && !(p.action == 'merge' && p.targetId != null)) return null;
    return raw;
  }

  ClaimMode claimModeOf(ImportNode platform) => _claimModeOf(platform);

  // —— 批量（长按进入多选；[keys] 是选中的权益）——

  /// 设领取平台：'key:pX' / 'id:…' / null（会员本平台）。
  void batchClaimPlatform(Iterable<String> keys, String? ref) {
    for (final k in keys) {
      final b = node(k);
      if (b == null || b.t != ImportNode.benefit) continue;
      b.fields['claimPlatform'] = ref;
      b.badges.remove('claim_unsure');
      b.unverified.remove('claimPlatformId');
      _touch(b, 'claimPlatform');
      if (b.checked) _check(b);
    }
    _releaseClaimPlatforms();
    notifyListeners();
  }

  /// 设周期：选项不单独设额度（跟着它的「N 选 1」），跳过。
  void batchQuota(Iterable<String> keys, List<PerkQuota> quota) {
    for (final k in keys) {
      final b = node(k);
      if (b == null || b.t != ImportNode.benefit || b.fields['parent'] != null) continue;
      b.fields['quota'] = [for (final q in quota) q.toJson()];
      b.unverified.remove('quota');
      _touch(b, 'quota');
    }
    notifyListeners();
  }

  /// 设价值（单次面值，分）。
  void batchFaceValue(Iterable<String> keys, int? cents) {
    for (final k in keys) {
      final b = node(k);
      if (b == null || b.t != ImportNode.benefit) continue;
      b.fields['faceValueCents'] = cents;
      b.unverified.remove('faceValueCents');
      _touch(b, 'faceValueCents');
    }
    notifyListeners();
  }

  /// 移到另一张卡下（'key:m1' 或 'id:…'）：选项跟着它的「N 选 1」走；移过去的勾上（从「未归属」挪出来的也是）。
  /// 库里已有的权益（更新）不在这里换卡 —— 导入只改字段不搬家，要搬去会员详情里改；回跳过了几项，界面据此提示。
  int batchMoveTo(Iterable<String> keys, String membershipRef) {
    var skipped = 0;
    for (final k in keys) {
      final b = node(k);
      if (b == null || b.t != ImportNode.benefit || b.fields['parent'] != null) continue;
      if (b.action == 'update') {
        skipped++;
        continue;
      }
      b.fields['membership'] = membershipRef;
      b.badges.remove('missing');
      for (final o in optionsOf(b)) {
        o.fields['membership'] = membershipRef;
      }
      _check(b);
    }
    notifyListeners();
    return skipped;
  }

  void batchUncheck(Iterable<String> keys) {
    for (final k in keys) {
      final n = node(k);
      if (n != null) _uncheck(n);
    }
    _releaseClaimPlatforms();
    notifyListeners();
  }

  // —— 筛选、拦截 ——

  static const Set<String> _attentionBadges = {'maybe_dup', 'low_conf', 'claim_unsure', 'ev_unverified', 'copied_example', 'ambiguous'};

  /// 这一项现在缺的必填字段（照当前的字段现算，预览里补上就不缺了）。
  List<String> missingOf(ImportNode n) => [
    for (final f in _required[n.t] ?? const <String>[])
      if (n.fields[f] == null || n.fields[f] == '') f,
  ];

  bool needsAttention(ImportNode n) =>
      n.badges.any(_attentionBadges.contains) || missingOf(n).isNotEmpty || n.action == 'pick' || _errors.containsKey(n.key);

  bool matches(ImportNode n, ImportFilter f) => switch (f) {
    ImportFilter.all => true,
    ImportFilter.attention => needsAttention(n),
    ImportFilter.create => n.checked && n.action == 'create',
    ImportFilter.update => n.checked && (n.action == 'update' || n.action == 'merge'),
    ImportFilter.unchecked => !n.checked,
  };

  int countOf(ImportFilter f) => all.where((n) => matches(n, f)).length;

  /// 勾着导入的项数（只当领取平台、映射成「会员本平台」的平台不算）。
  int get includedCount => all.where(_included).length;

  bool _included(ImportNode n) => n.checked && n.action != 'skip' && !(n.t == ImportNode.platform && _claimModeOf(n) == ClaimMode.self && !memberships.any((m) => m.fields['platform'] == 'key:${n.key}'));

  /// 挡住导入的：同名多张卡还没选、勾着却缺必填项（含物品缺名称、价格或购买日期），外加超过一次导入的上限（服务端同一道闸，
  /// 在这里先说清楚，免得点了才被拒）。
  List<ImportBlocker> get blockers => [
    for (final n in all)
      if (_included(n)) ...[
        if (n.action == 'pick') ImportBlocker(n, '「${n.name}」有同名的好几张，选一张更新或新建'),
        for (final f in missingOf(n)) ImportBlocker(n, '「${n.name.isEmpty ? '未命名' : n.name}」缺${_requiredLabel[f] ?? f}'),
      ],
    for (final MapEntry(key: t, value: (max, label, unit)) in _limits.entries)
      if (all.where((n) => n.t == t && _included(n)).length case final count when count > max)
        ImportBlocker(all.firstWhere((n) => n.t == t && _included(n)), '一次最多导入$label $max $unit，这次勾了 $count $unit，先取消一些或分两次导'),
  ];

  bool get canSubmit => includedCount > 0 && blockers.isEmpty;

  // —— 导入失败时标到节点上 ——

  void setErrors(List<Map<String, dynamic>> errors) {
    _errors.clear();
    _errorFields.clear();
    for (final e in errors) {
      final key = jsonStringOrNull(e['key']);
      if (key == null) continue;
      _errors[key] = jsonString(e['message']);
      _errorFields[key] = jsonStringOrNull(e['field']);
    }
    notifyListeners();
  }

  String? errorOf(String key) => _errors[key];
  String? errorFieldOf(String key) => _errorFields[key];

  // —— apply 请求体 ——

  /// `POST /asset-import/apply` 的请求体（spec §4）。没勾的项 skip；映射成「会员本平台」的领取平台写 null；
  /// update 只带勾了的差异字段（take，预览里改过的字段已经勾在里面）；新建的带上改过的字段（edited，服务端重新比对转成更新时用）；
  /// 平台带上预览时的比对结果（match：别名命中还选了新建的，服务端照建）；物品的预设换成估值字段（[ValuationInput.toCreateJson] 那一套）。
  Map<String, dynamic> toApplyBody() => {
    'clientId': clientId,
    'importId': importId,
    'platforms': [for (final p in platforms) _platformItem(p)],
    'memberships': [for (final m in memberships) _item(m)],
    'benefits': [for (final b in benefits) _benefitItem(b)],
    'items': [for (final i in items) _itemItem(i)],
  };

  Map<String, dynamic> _base(ImportNode n, String action) => {
    'key': n.key,
    'action': action,
    'fields': Map<String, dynamic>.of(n.fields),
    'ev': ?n.ev,
    'unverified': List<String>.of(n.unverified),
  };

  Map<String, dynamic> _platformItem(ImportNode p) {
    if (!_included(p)) return _base(p, 'skip');
    return {..._base(p, p.action), if (p.action == 'merge') 'targetId': p.targetId, 'match': p.matchKind};
  }

  /// 引用一个没勾的节点：它是并入 / 更新已有的，就直接引用那个已有的（'id:…'）；别的原样（服务端会报「没有导入」）。
  Object? _resolve(Object? ref) {
    final n = refNode(ref);
    if (n == null || n.checked || n.targetId == null) return ref;
    return n.action == 'merge' || n.action == 'update' ? 'id:${n.targetId}' : ref;
  }

  Map<String, dynamic> _item(ImportNode n) {
    if (!n.checked || n.action == 'skip') return _base(n, 'skip');
    final out = _base(n, n.action);
    if (n.action == 'update') {
      out['targetId'] = n.targetId;
      out['take'] = [for (final d in n.diff) if (d.take) d.field];
    } else if (n.edited.isNotEmpty) {
      out['edited'] = [...n.edited];
    }
    final fields = out['fields'] as Map<String, dynamic>;
    for (final f in const ['platform', 'membership', 'parent']) {
      if (fields.containsKey(f)) fields[f] = _resolve(fields[f]);
    }
    return out;
  }

  Map<String, dynamic> _benefitItem(ImportNode b) {
    final out = _item(b);
    final fields = out['fields'] as Map<String, dynamic>;
    fields['claimPlatform'] = _resolve(claimRefOf(b));
    return out;
  }

  Map<String, dynamic> _itemItem(ImportNode i) {
    final out = _item(i);
    if (out['action'] == 'skip') return out;
    final fields = out['fields'] as Map<String, dynamic>;
    final preset = presetByKey(jsonString(fields.remove('preset')));
    if (preset != null) {
      fields.addAll(ValuationInput(method: preset.method, rateBp: preset.rateBp, residualBp: preset.residualBp).toCreateJson());
    }
    final netWorth = fields['netWorth'];
    if (netWorth == null || netWorth == Asset.netWorthAuto) fields.remove('netWorth');
    switch (i.link) {
      case ItemLink.link:
        out['linkTransactionId'] = i.linkTransactionId;
      case ItemLink.record:
        out['recordTransaction'] = <String, dynamic>{};
      case ItemLink.none:
        break;
    }
    return out;
  }
}
