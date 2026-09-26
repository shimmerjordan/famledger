// AI 导入的 App 测试共用：两份草稿 fixture，形状照服务端真实回的（server/test/asset_import_extract.test.js 的
// 88VIP、订单两个用例：库里已有「淘宝」「优酷」、有一笔 9/21 的 ¥8,999 支出），只把 id 换成好认的。

const String vip88Source =
    '88VIP 会员说明\n'
    '年费 88 元（淘气值 1000 分以上），到期日 2026-12-31，到期自动续费。\n'
    '权益一：优酷视频年卡，开通后去优酷 App「我的-会员中心」领取。\n'
    '权益二：饿了么超级会员年卡，每年 1 次。\n'
    '权益三：每月 4 张 88 折购物券，单笔满 200 元可用，不与其他优惠同享。\n'
    '权益四：以下三选一：网易云音乐黑胶年卡、QQ 音乐豪华绿钻年卡、芒果 TV 年卡。\n';

const String orderSource =
    '订单详情\n'
    '商品：Apple iPhone 16 Pro 256GB 沙漠色钛金属 × 1\n'
    '实付款：¥8,999.00\n'
    '下单时间：2026-09-20 21:14:05\n'
    '收货人：王小明 139****5678\n'
    '订单编号：**** 2345\n';

/// 一个草稿节点（服务端 normalize + match 之后的形状）。
Map<String, dynamic> importNode(
  String key,
  String t,
  Map<String, dynamic> fields, {
  String action = 'create',
  String? targetId,
  String? ev,
  List<int>? span,
  double conf = 0.9,
  List<String> unverified = const [],
  List<String> badges = const [],
  bool checked = true,
  bool implied = false,
  Map<String, dynamic> match = const {'kind': 'none'},
  List<Map<String, dynamic>> diff = const [],
  List<Map<String, dynamic>> notMentioned = const [],
  List<Map<String, dynamic>> txCandidates = const [],
  Map<String, dynamic>? link,
}) => {
  'key': key,
  't': t,
  'fields': fields,
  'action': action,
  'targetId': targetId,
  'ev': ev,
  'span': span,
  'conf': conf,
  'unverified': unverified,
  'badges': badges,
  'missing': <String>[],
  'checked': checked,
  'implied': implied,
  'fieldConf': <String, dynamic>{},
  'match': match,
  'diff': diff,
  'notMentioned': notMentioned,
  'txCandidates': txCandidates,
  'link': ?link,
};

Map<String, dynamic> _benefit(
  String key,
  String name, {
  String? parent,
  String kind = 'subscription',
  String? claim,
  String? claimHow,
  String flow = 'claim',
  List<Map<String, dynamic>> quota = const [],
  String anchor = 'term',
  List<Map<String, dynamic>> limits = const [],
  String? ev,
  List<int>? span,
  double conf = 0.9,
}) => importNode(
  key,
  'benefit',
  {
    'membership': 'key:m1',
    'parent': parent,
    'name': name,
    'kind': kind,
    'claimPlatform': claim,
    'claimHow': claimHow,
    'claimUrl': null,
    'flow': flow,
    'quota': quota,
    'anchor': anchor,
    'validFrom': null,
    'validUntil': null,
    'faceValueCents': null,
    'limits': limits,
  },
  ev: ev,
  span: span,
  conf: conf,
);

Map<String, dynamic> _claimPlatform(String key, String name, {List<String> badges = const [], Map<String, dynamic> match = const {'kind': 'none'}}) =>
    importNode(key, 'platform', {'name': name, 'kind': 'other'}, implied: true, badges: badges, match: match, conf: 0.8);

/// 88VIP 权益说明的草稿：淘宝并入已有的（tb）；五个领取平台都是补建的，其中「优酷视频」和已有的「优酷」（yk）只是 maybe。
Map<String, dynamic> vip88Draft({String importId = 'imp-vip', String tbId = 'tb', String ykId = 'yk'}) => {
  'importId': importId,
  'want': 'virtual',
  'truncated': false,
  'salvaged': false,
  'notices': <String>[],
  'targetMembershipId': null,
  'source': {'kind': 'text', 'text': vip88Source},
  'dropped': 0,
  'platforms': [
    importNode(
      'p1',
      'platform',
      {'name': '淘宝', 'kind': 'shopping'},
      action: 'merge',
      targetId: tbId,
      ev: '88VIP 会员说明',
      span: const [0, 10],
      conf: 0.8,
      match: {'kind': 'exact', 'id': tbId, 'name': '淘宝'},
    ),
    _claimPlatform('p2', '优酷视频', badges: const ['maybe_dup'], match: {
      'kind': 'maybe',
      'candidates': [
        {'id': ykId, 'name': '优酷'},
      ],
    }),
    _claimPlatform('p3', '饿了么'),
    _claimPlatform('p4', '网易云音乐'),
    _claimPlatform('p5', 'QQ音乐'),
    _claimPlatform('p6', '芒果TV'),
  ],
  'memberships': [
    importNode(
      'm1',
      'membership',
      {
        'platform': 'key:p1',
        'name': '88VIP',
        'tier': null,
        'kind': 'membership',
        'feeCents': 8800,
        'feePeriod': 'year',
        'termStartOn': null,
        'expiresOn': '2026-12-31',
        'autoRenew': 'yes',
        'isTrial': false,
      },
      ev: '年费 88 元（淘气值 1000 分以上），到期日 2026-12-31',
      span: const [11, 47],
    ),
  ],
  'benefits': [
    _benefit('b1', '优酷视频年卡', claim: 'key:p2', claimHow: '优酷 App「我的-会员中心」', quota: const [{'p': 'term', 'n': 1}],
        ev: '优酷视频年卡，开通后去优酷 App「我的-会员中心」领取', span: const [60, 88]),
    _benefit('b2', '饿了么超级会员年卡', claim: 'key:p3', quota: const [{'p': 'year', 'n': 1}], anchor: 'calendar',
        ev: '饿了么超级会员年卡，每年 1 次', span: const [94, 110]),
    _benefit('b3', '88 折购物券', kind: 'coupon', flow: 'claim_use', quota: const [{'p': 'month', 'n': 4}], anchor: 'calendar',
        limits: const [{'type': 'min_spend', 'text': '单笔满 200 元可用'}, {'type': 'stacking', 'text': '不与其他优惠同享'}],
        ev: '每月 4 张 88 折购物券', span: const [116, 130], conf: 0.85),
    _benefit('b7', '三选一', kind: 'choice', quota: const [{'p': 'term', 'n': 1}], ev: '三选一：网易云音乐黑胶年卡', span: const [159, 172], conf: 0.8),
    _benefit('b4', '网易云音乐黑胶年卡', parent: 'key:b7', claim: 'key:p4', ev: '三选一：网易云音乐黑胶年卡', span: const [159, 172], conf: 0.8),
    _benefit('b5', 'QQ 音乐豪华绿钻年卡', parent: 'key:b7', claim: 'key:p5', ev: 'QQ 音乐豪华绿钻年卡', span: const [173, 184], conf: 0.8),
    _benefit('b6', '芒果 TV 年卡', parent: 'key:b7', claim: 'key:p6', ev: '芒果 TV 年卡', span: const [185, 193], conf: 0.8),
  ],
  'items': <Object>[],
};

/// 订单文字的草稿：一件 iPhone，预设 apple，唯一一笔同金额、日期 ±3 天的支出（txId）默认关联。
Map<String, dynamic> orderDraft({String importId = 'imp-order', String txId = 'tx-phone'}) => {
  'importId': importId,
  'want': 'items',
  'truncated': false,
  'salvaged': false,
  'notices': <String>[],
  'targetMembershipId': null,
  'source': {'kind': 'text', 'text': orderSource},
  'dropped': 0,
  'platforms': <Object>[],
  'memberships': <Object>[],
  'benefits': <Object>[],
  'items': [
    importNode(
      'i1',
      'item',
      {'name': 'iPhone 16 Pro 256GB', 'category': 'digital', 'preset': 'apple', 'priceCents': 899900, 'purchasedOn': '2026-09-20'},
      ev: 'Apple iPhone 16 Pro 256GB 沙漠色钛金属 × 1',
      span: const [8, 44],
      conf: 0.92,
      txCandidates: [
        {'id': txId, 'occurredAt': '2026-09-21T09:00:00+08:00', 'merchant': 'Apple Store', 'amountCents': 899900, 'accountId': null},
      ],
      link: {'mode': 'link', 'transactionId': txId},
    ),
  ],
};

/// 服务端给 update 节点带的 current（库里那张卡现在的值，照 perk_import_match.js 的 membershipCurrent）：
/// 名称 + 差异那一套字段，和草稿字段一样的底子，[overrides] 改几项。
Map<String, dynamic> membershipCurrentOf(Map<String, dynamic> fields, [Map<String, dynamic> overrides = const {}]) => {
  for (final k in const ['name', 'tier', 'kind', 'feeCents', 'feePeriod', 'termStartOn', 'expiresOn', 'autoRenew']) k: fields[k],
  ...overrides,
};

/// 权益的 current（照 benefitCurrent）：名称 + 差异那一套字段 + 领取平台（'id:…'；这里默认会员本平台 null）。
Map<String, dynamic> benefitCurrentOf(Map<String, dynamic> fields, [Map<String, dynamic> overrides = const {}]) => {
  for (final k in const ['name', 'kind', 'claimHow', 'claimUrl', 'flow', 'quota', 'anchor', 'validFrom', 'validUntil', 'faceValueCents', 'limits']) k: fields[k],
  'claimPlatform': null,
  ...overrides,
};

/// 同一段材料导第二次的样子：卡和权益都是更新账本里已有的那行，而且没有差异（current 和草稿一样，只是领取平台
/// 在库里是会员本平台）。
Map<String, dynamic> vipAgainJson() {
  final json = vip88Draft();
  final m = (json['memberships'] as List).first as Map<String, dynamic>;
  m
    ..['action'] = 'update'
    ..['targetId'] = 'old-vip'
    ..['match'] = {'kind': 'update', 'id': 'old-vip', 'name': '88VIP'}
    ..['current'] = membershipCurrentOf(m['fields'] as Map<String, dynamic>);
  for (final b in (json['benefits'] as List).cast<Map<String, dynamic>>()) {
    b
      ..['action'] = 'update'
      ..['targetId'] = 'old-${b['key']}'
      ..['match'] = {'kind': 'update', 'id': 'old-${b['key']}', 'name': (b['fields'] as Map)['name']}
      ..['current'] = benefitCurrentOf(b['fields'] as Map<String, dynamic>);
  }
  return json;
}

/// 88VIP 在库里有同名的两张（爸爸的 c1、妈妈的 c2），各带一份差异；妈妈那张下面已经有「88 折购物券」。
Map<String, dynamic> vipPickJson() {
  final json = vip88Draft();
  final m = (json['memberships'] as List).first as Map<String, dynamic>;
  final fields = m['fields'] as Map<String, dynamic>;
  m
    ..['action'] = 'pick'
    ..['badges'] = ['ambiguous']
    ..['match'] = {
      'kind': 'ambiguous',
      'candidates': [
        {
          'id': 'c1', 'name': '88VIP', 'memberId': 'dad', 'expiresOn': '2026-10-01', 'archived': false,
          'diff': [{'field': 'expiresOn', 'old': '2026-10-01', 'new': '2026-12-31', 'take': true}],
          'current': membershipCurrentOf(fields, {'expiresOn': '2026-10-01'}),
          'notMentioned': <Object>[],
        },
        {
          'id': 'c2', 'name': '88VIP', 'memberId': 'mom', 'expiresOn': '2027-03-01', 'archived': false,
          'diff': [{'field': 'expiresOn', 'old': '2027-03-01', 'new': '2026-12-31', 'take': false}],
          'current': membershipCurrentOf(fields, {'expiresOn': '2027-03-01'}),
          'notMentioned': [{'id': 'c2-old', 'name': '淘票票观影券'}],
        },
      ],
    };
  final b3 = (json['benefits'] as List).cast<Map<String, dynamic>>().firstWhere((b) => b['key'] == 'b3');
  b3['byCard'] = {
    'c2': {
      'targetId': 'c2-b3',
      'match': {'kind': 'update', 'id': 'c2-b3', 'name': '88 折购物券'},
      'diff': [{'field': 'faceValueCents', 'old': null, 'new': 500, 'take': true}],
      'current': benefitCurrentOf(b3['fields'] as Map<String, dynamic>, {'faceValueCents': null, 'claimHow': '券中心'}),
    },
  };
  return json;
}

/// 订单截图的草稿（服务端 kind=image 回的形状）：两块截图，iPhone 出自第 2 块、依据「未核实」、没有 span；照样默认关联唯一那笔流水。
Map<String, dynamic> orderImageDraft({String importId = 'imp-shot', String txId = 'tx-phone'}) {
  final json = orderDraft(importId: importId, txId: txId);
  json['source'] = {'kind': 'image', 'count': 2};
  final item = (json['items'] as List).first as Map<String, dynamic>;
  // 截图来源（服务端 perk_import_normalize.js）：不逐条标「依据未核实」，关键字段进 unverified（落库后是「AI 推断」小点）。
  item
    ..['img'] = 2
    ..['span'] = null
    ..['badges'] = <String>[]
    ..['unverified'] = ['priceCents', 'purchasedOn'];
  return json;
}

const String txEvidenceTv = '腾讯视频 ¥30.00 × 7 次（2026-03-22 至 2026-09-18）';

/// 从流水「直接生成」的草稿（服务端 kind=transactions 回的形状）：两个平台、两张卡，卡带扣费特征和上次扣费那笔。
Map<String, dynamic> txDraft({String importId = 'imp-tx'}) => {
  'importId': importId,
  'want': 'virtual',
  'truncated': false,
  'continued': false,
  'continueFailed': false,
  'salvaged': false,
  'notices': <String>[],
  'source': {'kind': 'transactions', 'groups': 2},
  'platforms': [
    importNode('p1', 'platform', {'name': '腾讯视频', 'kind': 'other'}, ev: txEvidenceTv, conf: 0.95),
    importNode('p2', 'platform', {'name': '88VIP', 'kind': 'other'}, ev: '88VIP ¥88.00 × 1 次（2026-08-14）', conf: 0.8),
  ],
  'memberships': [
    importNode('m1', 'membership', {
      'platform': 'key:p1', 'name': '腾讯视频', 'tier': null, 'kind': 'subscription', 'feeCents': 3000, 'feePeriod': 'month',
      'termStartOn': '2026-09-18', 'expiresOn': '2026-10-18', 'autoRenew': 'yes', 'isTrial': false,
      'payPattern': {'keywords': ['腾讯视频'], 'minCents': 2400, 'maxCents': 3600}, 'lastChargeTxId': 'tx-g_tv',
    }, ev: txEvidenceTv, conf: 0.95),
    importNode('m2', 'membership', {
      'platform': 'key:p2', 'name': '88VIP', 'tier': null, 'kind': 'subscription', 'feeCents': 8800, 'feePeriod': 'year',
      'termStartOn': '2026-08-14', 'expiresOn': '2027-08-14', 'autoRenew': 'unknown', 'isTrial': false,
      'payPattern': {'keywords': ['88VIP'], 'minCents': 7040, 'maxCents': 10560}, 'lastChargeTxId': 'tx-g_vip',
    }, ev: '88VIP ¥88.00 × 1 次（2026-08-14）', conf: 0.8),
  ],
  'benefits': <Object>[],
  'items': <Object>[],
};

/// 库里已经有一张没设扣费特征的「腾讯视频」（old-tv，到期 2026-09-01）：这次转成更新，扣费特征、到期日默认勾，费用不同不勾。
Map<String, dynamic> txUpdateDraft() {
  final json = txDraft();
  final p = (json['platforms'] as List).first as Map<String, dynamic>;
  p
    ..['action'] = 'merge'
    ..['targetId'] = 'tv-platform'
    ..['match'] = {'kind': 'exact', 'id': 'tv-platform', 'name': '腾讯视频'};
  final m = (json['memberships'] as List).first as Map<String, dynamic>;
  final fields = m['fields'] as Map<String, dynamic>;
  m
    ..['action'] = 'update'
    ..['targetId'] = 'old-tv'
    ..['match'] = {'kind': 'update', 'id': 'old-tv', 'name': '腾讯视频'}
    ..['current'] = membershipCurrentOf(fields, {'feeCents': 2500, 'expiresOn': '2026-09-01', 'termStartOn': null, 'autoRenew': 'unknown'})
    ..['diff'] = [
      {'field': 'feeCents', 'old': 2500, 'new': 3000, 'take': false},
      {'field': 'termStartOn', 'old': null, 'new': '2026-09-18', 'take': true},
      {'field': 'expiresOn', 'old': '2026-09-01', 'new': '2026-10-18', 'take': true},
      {'field': 'autoRenew', 'old': 'unknown', 'new': 'yes', 'take': true},
      {'field': 'payPattern', 'old': null, 'new': fields['payPattern'], 'take': true},
    ];
  return json;
}

/// 从流水识别的候选（服务端 GET /asset-import/candidates 的形状，照 server/test/asset_import_transactions.test.js 的验收流水）：
/// 腾讯视频 28–30 × 7（默认勾）、88VIP 88 × 1（默认勾）、爱奇艺停了的（分数低、不勾）、京东PLUS 已经有卡在管（不勾）、
/// Apple Store 那笔是买东西的（关联着物品、不勾）、WPS 只扣过一次又没写年费（把握不大、不勾）。一共认出 8 组，只列前 6 组。
Map<String, dynamic> candidatesJson() => {
  'months': 13,
  'from': '2025-08-23',
  'today': '2026-09-23',
  'total': 8,
  'items': [
    _candidate('g_tv', '腾讯视频', 3000, minCents: 2800, count: 7, period: 'month', firstOn: '2026-03-22', lastOn: '2026-09-18', nextOn: '2026-10-18', score: 7, checked: true),
    _candidate('g_vip', '88VIP', 8800, count: 1, period: 'year', periodSource: 'keyword', firstOn: '2026-08-14', lastOn: '2026-08-14', nextOn: '2027-08-14', score: 5, checked: true),
    _candidate('g_iq', '爱奇艺', 2500, count: 4, period: 'month', firstOn: '2025-12-02', lastOn: '2026-03-02', nextOn: '2026-04-02', score: 3, checked: false, reasons: ['period', 'count', 'stale']),
    _candidate('g_jd', '京东PLUS', 19800, count: 2, period: 'year', firstOn: '2025-09-01', lastOn: '2026-09-01', nextOn: '2027-09-01', score: 8, checked: false, linked: {'membershipId': 'm-jd', 'name': '京东PLUS'}),
    _candidate('g_ap', 'Apple Store', 59900, count: 1, period: 'year', periodSource: 'guess', firstOn: '2026-09-01', lastOn: '2026-09-01', nextOn: '2027-09-01', score: 5, checked: false, reasons: ['keyword', 'round', 'active', 'once'], linked: {'assetId': 'a-case', 'name': 'iPhone 16 Plus 保护壳'}),
    _candidate('g_wps', 'WPS会员', 9900, count: 1, period: 'year', periodSource: 'guess', firstOn: '2026-07-01', lastOn: '2026-07-01', nextOn: '2027-07-01', score: 5, checked: false, reasons: ['keyword', 'round', 'active', 'once']),
  ],
};

Map<String, dynamic> _candidate(
  String key,
  String merchant,
  int cents, {
  int? minCents,
  List<String> reasons = const [],
  required int count,
  required String period,
  String periodSource = 'observed',
  required String firstOn,
  required String lastOn,
  required String nextOn,
  required int score,
  required bool checked,
  Map<String, dynamic>? linked,
}) => {
  'key': key,
  'merchant': merchant,
  'amountCents': cents,
  'minCents': minCents ?? cents,
  'maxCents': cents,
  'count': count,
  'period': period,
  'periodSource': periodSource,
  'firstOn': firstOn,
  'lastOn': lastOn,
  'nextOn': nextOn,
  'score': score,
  'reasons': reasons,
  'checked': checked,
  'linked': linked,
  'lastTransactionId': 'tx-$key',
};
