import 'json_utils.dart';

// 会员权益的四种行（spec §2「006」）：平台 → 会员/卡 → 权益，外加打卡事件（接口在 P3）。
// 服务端只存事实和用户的选择；本期、剩余、回本这些派生数在 App 里现算（P3 的 perk_math.dart）。
// fromJson 一律宽容：缺字段、不认识的枚举（以后的版本写的）按默认值兜底，不让界面崩。

/// 缺字段或不认识的值按 [fallback]。
String _oneOf(Object? raw, List<String> allowed, String fallback) {
  final value = jsonString(raw, fallback);
  return allowed.contains(value) ? value : fallback;
}

/// 平台的「规范化名」，只在 App 里做搜索和「是不是同一个」的初判：全角 ASCII 折成半角 →
/// 小写 → 去掉空白和标点。服务端用 NFKC（lib/perks_schema.js normalizeName）说了算，
/// Dart 没有 NFKC，这里覆盖中文用户最常见的那部分（全角字母数字、全角空格）。
String perkNameKey(String s) {
  final half = StringBuffer();
  for (final rune in s.runes) {
    if (rune >= 0xFF01 && rune <= 0xFF5E) {
      half.writeCharCode(rune - 0xFEE0);
    } else if (rune == 0x3000) {
      half.write(' ');
    } else {
      half.writeCharCode(rune);
    }
  }
  return half.toString().toLowerCase().replaceAll(_blankOrPunct, '');
}

final RegExp _blankOrPunct = RegExp(r'[\s\p{P}]+', unicode: true);

/// 平台：会员挂在哪、权益去哪领。叫 PerkPlatform 是为了不和 `dart:io` 的 Platform 撞名。
class PerkPlatform {
  const PerkPlatform({
    required this.id,
    required this.name,
    this.aliases = const [],
    this.kind = 'other',
    this.icon,
    this.color,
    this.url,
    this.note,
    this.sortOrder = 0,
    this.archived = false,
  });

  static const List<String> kinds = [
    'shopping',
    'video',
    'music',
    'reading',
    'cloud',
    'food',
    'travel',
    'bank',
    'telecom',
    'game',
    'tool',
    'other',
  ];

  static const Map<String, String> kindLabels = {
    'shopping': '购物',
    'video': '视频',
    'music': '音乐',
    'reading': '阅读',
    'cloud': '网盘',
    'food': '外卖餐饮',
    'travel': '出行旅行',
    'bank': '银行',
    'telecom': '通信',
    'game': '游戏',
    'tool': '工具',
    'other': '其他',
  };

  final String id;
  final String name;
  final List<String> aliases;
  final String kind;
  final String? icon;
  final String? color;
  final String? url;
  final String? note;
  final int sortOrder;
  final bool archived;

  String get kindLabel => kindLabels[kind] ?? '其他';

  /// 名字或任一别名的规范化形式里含有 [query] 的规范化形式（空查询都算）。
  bool matches(String query) {
    final q = perkNameKey(query);
    if (q.isEmpty) return true;
    return [name, ...aliases].any((s) => perkNameKey(s).contains(q));
  }

  /// 名字或任一别名和 [query] 规范化后完全相同。
  bool sameName(String query) {
    final q = perkNameKey(query);
    return q.isNotEmpty && [name, ...aliases].any((s) => perkNameKey(s) == q);
  }

  factory PerkPlatform.fromJson(Map<String, dynamic> json) => PerkPlatform(
    id: jsonString(json['id']),
    name: jsonString(json['name']),
    aliases: jsonStringList(json['aliases']),
    kind: _oneOf(json['kind'], kinds, 'other'),
    icon: jsonStringOrNull(json['icon']),
    color: jsonStringOrNull(json['color']),
    url: jsonStringOrNull(json['url']),
    note: jsonStringOrNull(json['note']),
    sortOrder: jsonInt(json['sortOrder']),
    archived: jsonBool(json['archived']),
  );

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{'id': id, 'name': name, 'aliases': aliases, 'kind': kind};
    putIfNotNull(json, 'icon', icon);
    putIfNotNull(json, 'color', color);
    putIfNotNull(json, 'url', url);
    putIfNotNull(json, 'note', note);
    json['sortOrder'] = sortOrder;
    json['archived'] = archived;
    return json;
  }
}

/// 会员/卡：挂在某个平台下、带着一串权益。
class Membership {
  const Membership({
    required this.id,
    required this.platformId,
    this.sourceBenefitId,
    required this.name,
    this.tier,
    this.kind = 'membership',
    this.memberId,
    this.accountId,
    this.feeCents,
    this.feePeriod = 'year',
    this.termPaidCents,
    this.termStartOn,
    this.expiresOn,
    this.autoRenew = 'unknown',
    this.isTrial = false,
    this.remindDays,
    this.payPattern,
    this.lastChargeTxId,
    this.origin = const {},
    this.note,
    this.sortOrder = 0,
    this.archived = false,
  });

  static const List<String> kinds = ['membership', 'subscription', 'credit_card', 'bundle', 'other'];

  static const Map<String, String> kindLabels = {
    'membership': '会员',
    'subscription': '订阅',
    'credit_card': '信用卡',
    'bundle': '联合会员',
    'other': '其他',
  };

  static const List<String> feePeriods = ['month', 'quarter', 'year', 'once', 'none'];

  static const Map<String, String> feePeriodLabels = {
    'month': '每月',
    'quarter': '每季',
    'year': '每年',
    'once': '一次性',
    'none': '不收费',
  };

  static const List<String> autoRenewModes = ['yes', 'no', 'unknown'];

  static const Map<String, String> autoRenewLabels = {
    'yes': '自动续费',
    'no': '不续费',
    'unknown': '不确定',
  };

  final String id;
  final String platformId;

  /// 派生会员：是哪条权益带出来的（88VIP 的「优酷年卡」→ 这张优酷会员）。
  final String? sourceBenefitId;
  final String name;
  final String? tier;

  /// membership | subscription | credit_card | bundle | other
  final String kind;

  /// 持有人；null = 全家共用。
  final String? memberId;

  /// 只有信用卡用。
  final String? accountId;

  /// 续费价（分）。
  final int? feeCents;

  /// month | quarter | year | once | none
  final String feePeriod;

  /// 本期实付；null = 按续费价算，0 = 免年费/试用。
  final int? termPaidCents;

  /// `YYYY-MM-DD`，都可以在将来。
  final String? termStartOn;

  /// `YYYY-MM-DD`；null = 长期有效。
  final String? expiresOn;

  /// yes | no | unknown
  final String autoRenew;
  final bool isTrial;

  /// 第一次提醒提前几天；null = 默认，0 = 关掉。
  final int? remindDays;

  /// 扣费特征（P6/P7 用），这里原样存着，老缓存不丢。
  final Map<String, dynamic>? payPattern;
  final String? lastChargeTxId;

  /// `{src, importId, ev, unverified}`（P4 的 AI 导入写）。
  final Map<String, dynamic> origin;
  final String? note;
  final int sortOrder;
  final bool archived;

  String get kindLabel => kindLabels[kind] ?? '其他';

  /// 「88VIP」「经典白 · 金卡」。
  String get title => tier == null || tier!.isEmpty ? name : '$name · $tier';

  factory Membership.fromJson(Map<String, dynamic> json) => Membership(
    id: jsonString(json['id']),
    platformId: jsonString(json['platformId']),
    sourceBenefitId: jsonStringOrNull(json['sourceBenefitId']),
    name: jsonString(json['name']),
    tier: jsonStringOrNull(json['tier']),
    kind: _oneOf(json['kind'], kinds, 'membership'),
    memberId: jsonStringOrNull(json['memberId']),
    accountId: jsonStringOrNull(json['accountId']),
    feeCents: jsonIntOrNull(json['feeCents']),
    feePeriod: _oneOf(json['feePeriod'], feePeriods, 'year'),
    termPaidCents: jsonIntOrNull(json['termPaidCents']),
    termStartOn: jsonStringOrNull(json['termStartOn']),
    expiresOn: jsonStringOrNull(json['expiresOn']),
    autoRenew: _oneOf(json['autoRenew'], autoRenewModes, 'unknown'),
    isTrial: jsonBool(json['isTrial']),
    remindDays: jsonIntOrNull(json['remindDays']),
    payPattern: json['payPattern'] is Map ? jsonMap(json['payPattern']) : null,
    lastChargeTxId: jsonStringOrNull(json['lastChargeTxId']),
    origin: jsonMap(json['origin']),
    note: jsonStringOrNull(json['note']),
    sortOrder: jsonInt(json['sortOrder']),
    archived: jsonBool(json['archived']),
  );

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'id': id,
      'platformId': platformId,
      'name': name,
      'kind': kind,
      'feePeriod': feePeriod,
      'autoRenew': autoRenew,
      'isTrial': isTrial,
    };
    putIfNotNull(json, 'sourceBenefitId', sourceBenefitId);
    putIfNotNull(json, 'tier', tier);
    putIfNotNull(json, 'memberId', memberId);
    putIfNotNull(json, 'accountId', accountId);
    putIfNotNull(json, 'feeCents', feeCents);
    putIfNotNull(json, 'termPaidCents', termPaidCents);
    putIfNotNull(json, 'termStartOn', termStartOn);
    putIfNotNull(json, 'expiresOn', expiresOn);
    putIfNotNull(json, 'remindDays', remindDays);
    putIfNotNull(json, 'payPattern', payPattern);
    putIfNotNull(json, 'lastChargeTxId', lastChargeTxId);
    if (origin.isNotEmpty) json['origin'] = origin;
    putIfNotNull(json, 'note', note);
    json['sortOrder'] = sortOrder;
    json['archived'] = archived;
    return json;
  }
}

/// 额度的一条上限：每 [p] 最多 [n] 次。
class PerkQuota {
  const PerkQuota(this.p, this.n);

  static const List<String> periods = ['day', 'week', 'month', 'quarter', 'year', 'term', 'total'];

  /// 「另外每 [年] 最多 [6] 次」下拉里的说法。
  static const Map<String, String> periodLabels = {
    'day': '每天',
    'week': '每周',
    'month': '每月',
    'quarter': '每季',
    'year': '每年',
    'term': '会籍期内',
    'total': '总共',
  };

  /// day | week | month | quarter | year | term | total
  final String p;
  final int n;

  /// 周期不认识、次数不是正数的丢掉（服务端守着，这里只防老数据/怪数据）。
  static List<PerkQuota> listFrom(Object? raw) => [
    for (final m in jsonMapList(raw))
      if (periods.contains(m['p']) && jsonInt(m['n']) > 0) PerkQuota(m['p'] as String, jsonInt(m['n'])),
  ];

  Map<String, dynamic> toJson() => {'p': p, 'n': n};

  @override
  bool operator ==(Object other) => other is PerkQuota && other.p == p && other.n == n;

  @override
  int get hashCode => Object.hash(p, n);

  @override
  String toString() => 'PerkQuota($p, $n)';
}

/// 一条限制条件：类型 + 原话。
class PerkLimit {
  const PerkLimit(this.type, this.text);

  static const List<String> types = ['min_spend', 'scope', 'channel', 'holder', 'device', 'time', 'region', 'stacking', 'other'];

  static const Map<String, String> typeLabels = {
    'min_spend': '门槛',
    'scope': '范围',
    'channel': '渠道',
    'holder': '持有人',
    'device': '设备',
    'time': '时间',
    'region': '地区',
    'stacking': '叠加',
    'other': '其他',
  };

  final String type;
  final String text;

  String get typeLabel => typeLabels[type] ?? '其他';

  /// 不认识的类型按「其他」，空文字的丢掉。
  static List<PerkLimit> listFrom(Object? raw) => [
    for (final m in jsonMapList(raw))
      if (jsonString(m['text']).trim().isNotEmpty)
        PerkLimit(_oneOf(m['type'], types, 'other'), jsonString(m['text']).trim()),
  ];

  Map<String, dynamic> toJson() => {'type': type, 'text': text};

  @override
  bool operator ==(Object other) => other is PerkLimit && other.type == type && other.text == text;

  @override
  int get hashCode => Object.hash(type, text);
}

/// 权益：一张卡能兑现的一样东西。
class Benefit {
  const Benefit({
    required this.id,
    required this.membershipId,
    this.parentId,
    required this.name,
    this.kind = 'other',
    this.claimPlatformId,
    this.claimHow,
    this.claimUrl,
    this.flow = flowClaim,
    this.quota = const [],
    this.anchor = anchorCalendar,
    this.validFrom,
    this.validUntil,
    this.faceValueCents,
    this.myValueCents,
    this.limits = const [],
    this.remind = true,
    this.origin = const {},
    this.note,
    this.sortOrder = 0,
    this.archived = false,
  });

  static const List<String> kinds = [
    'subscription',
    'coupon',
    'discount',
    'cashback',
    'points',
    'service',
    'lounge',
    'shipping',
    'insurance',
    'choice',
    'other',
  ];

  static const Map<String, String> kindLabels = {
    'subscription': '会员/年卡',
    'coupon': '券',
    'discount': '折扣',
    'cashback': '返现',
    'points': '积分',
    'service': '服务',
    'lounge': '贵宾厅',
    'shipping': '运费',
    'insurance': '保险',
    'choice': 'N 选 1',
    'other': '其他',
  };

  static const String kindChoice = 'choice';

  // flow：额度按什么算（spec §2）。
  static const String flowClaim = 'claim';
  static const String flowUse = 'use';
  static const String flowClaimUse = 'claim_use';
  static const List<String> flows = [flowClaim, flowUse, flowClaimUse];

  /// 表单里三个直白的选项。
  static const Map<String, String> flowLabels = {
    flowClaim: '领到手就算',
    flowUse: '用一次算',
    flowClaimUse: '先领再用',
  };

  static const String anchorCalendar = 'calendar';
  static const String anchorTerm = 'term';
  static const List<String> anchors = [anchorCalendar, anchorTerm];

  final String id;
  final String membershipId;

  /// 只给 N 选 1 的选项用：指向同卡下 kind=choice 的父权益。
  final String? parentId;
  final String name;
  final String kind;

  /// 在哪领；null = 会员本平台。
  final String? claimPlatformId;
  final String? claimHow;
  final String? claimUrl;

  /// claim | use | claim_use
  final String flow;

  /// `[]` = 不限次；多条是叠加上限。
  final List<PerkQuota> quota;

  /// calendar | term
  final String anchor;

  /// `YYYY-MM-DD`，权益自身的有效窗口。
  final String? validFrom;
  final String? validUntil;
  final int? faceValueCents;
  final int? myValueCents;
  final List<PerkLimit> limits;

  /// false = 不进「本期没领完」的汇总提醒（P3）。
  final bool remind;
  final Map<String, dynamic> origin;
  final String? note;
  final int sortOrder;
  final bool archived;

  bool get isChoice => kind == kindChoice;
  bool get isOption => parentId != null;
  String get kindLabel => kindLabels[kind] ?? '其他';

  factory Benefit.fromJson(Map<String, dynamic> json) => Benefit(
    id: jsonString(json['id']),
    membershipId: jsonString(json['membershipId']),
    parentId: jsonStringOrNull(json['parentId']),
    name: jsonString(json['name']),
    kind: _oneOf(json['kind'], kinds, 'other'),
    claimPlatformId: jsonStringOrNull(json['claimPlatformId']),
    claimHow: jsonStringOrNull(json['claimHow']),
    claimUrl: jsonStringOrNull(json['claimUrl']),
    flow: _oneOf(json['flow'], flows, flowClaim),
    quota: PerkQuota.listFrom(json['quota']),
    anchor: _oneOf(json['anchor'], anchors, anchorCalendar),
    validFrom: jsonStringOrNull(json['validFrom']),
    validUntil: jsonStringOrNull(json['validUntil']),
    faceValueCents: jsonIntOrNull(json['faceValueCents']),
    myValueCents: jsonIntOrNull(json['myValueCents']),
    limits: PerkLimit.listFrom(json['limits']),
    remind: jsonBool(json['remind'], true),
    origin: jsonMap(json['origin']),
    note: jsonStringOrNull(json['note']),
    sortOrder: jsonInt(json['sortOrder']),
    archived: jsonBool(json['archived']),
  );

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'id': id,
      'membershipId': membershipId,
      'name': name,
      'kind': kind,
      'flow': flow,
      'quota': [for (final q in quota) q.toJson()],
      'anchor': anchor,
      'limits': [for (final l in limits) l.toJson()],
      'remind': remind,
    };
    putIfNotNull(json, 'parentId', parentId);
    putIfNotNull(json, 'claimPlatformId', claimPlatformId);
    putIfNotNull(json, 'claimHow', claimHow);
    putIfNotNull(json, 'claimUrl', claimUrl);
    putIfNotNull(json, 'validFrom', validFrom);
    putIfNotNull(json, 'validUntil', validUntil);
    putIfNotNull(json, 'faceValueCents', faceValueCents);
    putIfNotNull(json, 'myValueCents', myValueCents);
    if (origin.isNotEmpty) json['origin'] = origin;
    putIfNotNull(json, 'note', note);
    json['sortOrder'] = sortOrder;
    json['archived'] = archived;
    return json;
  }
}

/// 一次打卡：领了 / 用了 / 本期跳过。接口和界面在 P3；这里先能同步、能落缓存。
class BenefitEvent {
  const BenefitEvent({
    required this.id,
    required this.benefitId,
    this.kind = 'claim',
    required this.occurredOn,
    this.count = 1,
    this.valueCents,
    this.memberId,
    this.note,
  });

  static const List<String> kinds = ['claim', 'use', 'skip'];

  final String id;
  final String benefitId;

  /// claim | use | skip
  final String kind;

  /// `YYYY-MM-DD`
  final String occurredOn;
  final int count;

  /// 覆盖这次的价值；null = 按权益的估值/面值。
  final int? valueCents;
  final String? memberId;
  final String? note;

  factory BenefitEvent.fromJson(Map<String, dynamic> json) => BenefitEvent(
    id: jsonString(json['id']),
    benefitId: jsonString(json['benefitId']),
    kind: _oneOf(json['kind'], kinds, 'claim'),
    occurredOn: jsonString(json['occurredOn']),
    count: jsonInt(json['count'], 1),
    valueCents: jsonIntOrNull(json['valueCents']),
    memberId: jsonStringOrNull(json['memberId']),
    note: jsonStringOrNull(json['note']),
  );

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'id': id,
      'benefitId': benefitId,
      'kind': kind,
      'occurredOn': occurredOn,
      'count': count,
    };
    putIfNotNull(json, 'valueCents', valueCents);
    putIfNotNull(json, 'memberId', memberId);
    putIfNotNull(json, 'note', note);
    return json;
  }
}
