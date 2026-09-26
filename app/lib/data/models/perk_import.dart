import 'json_utils.dart';

// AI 智能导入（spec §6）的数据形状：服务端 `POST /asset-import/extract` 流回来的事件、预览草稿里的节点、
// `POST /asset-import/apply` 的结果。草稿本身的编辑逻辑在 ui/perk_import/perk_import_draft.dart。

/// 识别范围：自动 / 只要会员权益 / 只要实物（请求体的 `want`）。
enum ImportWant {
  auto('auto', '自动'),
  virtual('virtual', '只要会员权益'),
  items('items', '只要实物');

  const ImportWant(this.wire, this.label);

  final String wire;
  final String label;

  /// 路由参数、草稿里的 `want`；不认识的按自动。
  static ImportWant parse(String? raw) => values.firstWhere((w) => w.wire == raw, orElse: () => auto);
}

/// 粘贴最多这么多字（服务端同一道闸）；超过 [importPickLimit] 时服务端按关键词挑段落。
const int importMaxChars = 20000;
const int importPickLimit = 12000;

/// 发送前的 token 估算（spec §6「发送前的 token 估算」）：提示词和示例约 1500，中日韩字符按 1 个、其余按 4 个字符 1 个。
/// 只是量级提示，不是计费依据。
int estimateImportTokens(String text) {
  final sent = text.length > importPickLimit ? text.substring(0, importPickLimit) : text;
  var cjk = 0;
  for (final r in sent.runes) {
    if (r >= 0x3000 && r <= 0x9FFF || r >= 0xFF00 && r <= 0xFFEF) cjk++;
  }
  return 1500 + cjk + ((sent.length - cjk) / 4).ceil();
}

/// 行的 `origin.unverified`（AI 推断、还没人确认的字段名）；没有就是空。
List<String> originUnverified(Map<String, dynamic> origin) => jsonStringList(origin['unverified']);

/// 更新时的一个字段差异：原来是什么、这次材料里是什么、导入时写不写（[take]）。
/// 预览里人工改了这个字段：[newValue] 换成改后的值、[take] 勾上；服务端没列差异的字段被改了，补一条，原来的值取节点的
/// [ImportNode.current]（库里那一行现在的值）；current 里也没有这个字段时 [hasOld] 为假，界面只写「改成 …」。
/// `field == 'archived'` 是「把归档的那行恢复」。
class ImportDiff {
  ImportDiff({required this.field, this.oldValue, this.newValue, this.take = false, this.hasOld = true});

  final String field;
  final Object? oldValue;
  Object? newValue;
  bool take;
  final bool hasOld;

  factory ImportDiff.fromJson(Map<String, dynamic> json) => ImportDiff(
    field: jsonString(json['field']),
    oldValue: json['old'],
    newValue: json['new'],
    take: jsonBool(json['take']),
  );
}

/// 物品的关联流水候选（同金额、日期 ±3 天的已确认支出）。
class ImportTxCandidate {
  const ImportTxCandidate({required this.id, required this.occurredAt, this.merchant = '', required this.amountCents});

  final String id;
  final String occurredAt;
  final String merchant;
  final int amountCents;

  /// 本地日期 `YYYY-MM-DD`（occurredAt 是带偏移的本地时间，前 10 位就是那天）。
  String get day => occurredAt.length >= 10 ? occurredAt.substring(0, 10) : occurredAt;

  factory ImportTxCandidate.fromJson(Map<String, dynamic> json) => ImportTxCandidate(
    id: jsonString(json['id']),
    occurredAt: jsonString(json['occurredAt']),
    merchant: jsonString(json['merchant']),
    amountCents: jsonInt(json['amountCents']),
  );
}

/// 物品落库时和流水的关系：关联一笔已有的 / 同时记一笔支出 / 不记账。
enum ItemLink { link, record, none }

/// 预览里的一个节点（平台 / 会员 / 权益 / 物品），形状照服务端 lib/perk_import_normalize.js + perk_import_match.js。
/// 预览里能改：字段、动作、勾选、差异勾选、关联方式都是可变的，改完由 PerkImportDraft 通知界面。
class ImportNode {
  ImportNode({
    required this.key,
    required this.t,
    required this.action,
    this.targetId,
    required this.fields,
    this.ev,
    this.span,
    this.conf = 0.5,
    required this.unverified,
    required this.badges,
    this.checked = true,
    this.implied = false,
    this.match = const {},
    List<ImportDiff> diff = const [],
    this.notMentioned = const [],
    this.txCandidates = const [],
    this.link = ItemLink.none,
    this.linkTransactionId,
    this.byCard = const {},
    Map<String, dynamic> current = const {},
  }) : diff = List.of(diff),
       current = Map.of(current);

  static const String platform = 'platform';
  static const String membership = 'membership';
  static const String benefit = 'benefit';
  static const String item = 'item';

  final String key;

  /// platform | membership | benefit | item
  final String t;

  /// create | merge（平台并入已有）| update（会员、权益更新已有）| pick（同名多张，等用户选）| skip（物品已存在）
  String action;
  String? targetId;

  /// API 形状的字段（camelCase，金额是分）。引用写成 'key:m1' / 'id:<已有 id>' / null。
  final Map<String, dynamic> fields;
  final String? ev;

  /// 依据在原文里的位置 [start, end)；原文里没找到是 null。
  final List<int>? span;
  final double conf;

  /// 推断出来、还没人确认的字段名（落库写进 origin.unverified）。
  final List<String> unverified;

  /// low_conf / claim_unsure / missing / ev_unverified / copied_example / maybe_dup / ambiguous / exists
  final Set<String> badges;
  bool checked;

  /// （平台）材料里没单独列、从会员或权益里补建出来的。
  final bool implied;

  /// {kind: exact|alias|maybe|none|update|ambiguous|exists|near, id?, name?, archived?, candidates?}
  /// 会员的 candidates（同名多张要选、或命中的是归档的那张）每张各带 {diff, current, notMentioned}，选定哪张换上哪份。
  Map<String, dynamic> match;
  List<ImportDiff> diff;

  /// （更新已有的会员、权益）库里那一行现在的值（API 字段名；领取平台写成 'id:…'）：预览里改了服务端没列差异的字段，
  /// 拿它当差异的旧值；改回和它一样就不算差异。新建的是空的。
  Map<String, dynamic> current;

  /// （会员）库里有、这次材料没提到的权益 `[{id, name}]`：只提示，永不删。
  List<Map<String, dynamic>> notMentioned;
  final List<ImportTxCandidate> txCandidates;
  ItemLink link;
  String? linkTransactionId;

  /// （权益）所属的卡要选（同名多张 / 归档的那张）时，按候选卡 id 各比一次的结果 {targetId, match, diff, current}；没有同名的不在里面。
  final Map<String, Map<String, dynamic>> byCard;

  /// 预览里人工改过的字段：更新已有的行时这些字段一定写（ImportDiff 里勾上）；新建的被服务端重新比对转成更新时也照写。
  final Set<String> edited = {};

  String get name => jsonString(fields['name']);
  String get matchKind => jsonString(match['kind'], 'none');
  List<Map<String, dynamic>> get candidates => jsonMapList(match['candidates']);

  factory ImportNode.fromJson(Map<String, dynamic> json) {
    final link = jsonMap(json['link']);
    final span = json['span'];
    return ImportNode(
      key: jsonString(json['key']),
      t: jsonString(json['t']),
      action: jsonString(json['action'], 'create'),
      targetId: jsonStringOrNull(json['targetId']),
      fields: Map<String, dynamic>.of(jsonMap(json['fields'])),
      ev: jsonStringOrNull(json['ev']),
      span: span is List && span.length == 2 ? [jsonInt(span[0]), jsonInt(span[1])] : null,
      conf: jsonDouble(json['conf'], 0.5),
      unverified: jsonStringList(json['unverified']).toList(),
      badges: jsonStringList(json['badges']).toSet(),
      checked: jsonBool(json['checked'], true),
      implied: jsonBool(json['implied']),
      match: jsonMap(json['match']),
      diff: jsonList(json['diff'], ImportDiff.fromJson),
      notMentioned: jsonMapList(json['notMentioned']),
      txCandidates: jsonList(json['txCandidates'], ImportTxCandidate.fromJson),
      link: switch (jsonString(link['mode'])) {
        'link' => ItemLink.link,
        'record' => ItemLink.record,
        _ => ItemLink.none,
      },
      linkTransactionId: jsonStringOrNull(link['transactionId']),
      byCard: jsonMap(json['byCard']).map((k, v) => MapEntry(k, jsonMap(v))),
      current: jsonMap(json['current']),
    );
  }
}

/// extract 流里的事件：`stage`（进行到哪一步的一句话）、`record`（已经识别出几条）、`done`（草稿）。
/// `error` 事件由仓库抛成 ApiException（code 是 ai_bad_output / ai_timeout / ai_upstream / ai_refusal）。
sealed class ImportEvent {
  const ImportEvent();
}

class ImportStage extends ImportEvent {
  const ImportStage(this.message);

  final String message;
}

class ImportProgress extends ImportEvent {
  const ImportProgress(this.count);

  final int count;
}

class ImportDone extends ImportEvent {
  const ImportDone(this.importId, this.draft);

  final String importId;

  /// 服务端的草稿原样（交给 PerkImportDraft.fromJson）。
  final Map<String, dynamic> draft;
}

/// `POST /asset-import/apply` 的结果。
class PerkImportResult {
  const PerkImportResult({
    this.created = const {},
    this.updated = const {},
    this.autoMerged = const [],
    this.ids = const {},
    this.replayed = false,
  });

  /// {platforms, memberships, benefits, items, transactions}
  final Map<String, int> created;

  /// {platforms, memberships, benefits}
  final Map<String, int> updated;

  /// 本来要新建、导入时发现库里已经有了、并进原来那条的：[{key, id, name, table}]
  /// （别人刚建了同名平台、同名多张卡选定之后卡里已有的权益、并入已有平台后那里已有的卡……）
  final List<Map<String, dynamic>> autoMerged;

  /// 草稿里的 key → 落库后的 id
  final Map<String, String> ids;
  final bool replayed;

  int createdOf(String kind) => created[kind] ?? 0;
  int updatedOf(String kind) => updated[kind] ?? 0;

  factory PerkImportResult.fromJson(Map<String, dynamic> json) => PerkImportResult(
    created: jsonMap(json['created']).map((k, v) => MapEntry(k, jsonInt(v))),
    updated: jsonMap(json['updated']).map((k, v) => MapEntry(k, jsonInt(v))),
    autoMerged: jsonMapList(json['autoMerged']),
    ids: jsonMap(json['ids']).map((k, v) => MapEntry(k, jsonString(v))),
    replayed: jsonBool(json['replayed']),
  );
}
