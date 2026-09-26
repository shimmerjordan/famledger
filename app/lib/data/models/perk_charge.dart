import '../../core/money.dart';
import 'asset_math.dart';
import 'json_utils.dart';
import 'perk_math.dart';
import 'perks.dart';

// 扣费特征与扣费线索（spec §2 pay_pattern、§4 GET /memberships/charge-hints、§5「要处理」）。
// 服务端 lib/perks_schema.js payPatternOf 规整写入、lib/charge_hints.js 找线索；这里是 App 端的形状和说法。

/// 会员的扣费特征：商户或备注里含任一关键词、金额落在 [minCents, maxCents]（缺哪头哪头不设限）的确认支出，
/// 算这张卡的一次扣费。会员表单「更多」里手填，P7 的流水识别也写同一个形状。
class PerkPayPattern {
  const PerkPayPattern({required this.keywords, this.minCents, this.maxCents});

  final List<String> keywords;
  final int? minCents;
  final int? maxCents;

  /// 缓存里原样存着的 Map（Membership.payPattern）→ 这个；没有关键词的当没设（null）。
  static PerkPayPattern? tryParse(Map<String, dynamic>? raw) {
    if (raw == null) return null;
    final list = raw['keywords'];
    final keywords = [
      if (list is List)
        for (final k in list)
          if (k is String && k.trim().isNotEmpty) k.trim(),
    ];
    if (keywords.isEmpty) return null;
    return PerkPayPattern(keywords: keywords, minCents: jsonIntOrNull(raw['minCents']), maxCents: jsonIntOrNull(raw['maxCents']));
  }

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{'keywords': keywords};
    putIfNotNull(json, 'minCents', minCents);
    putIfNotNull(json, 'maxCents', maxCents);
    return json;
  }
}

/// 表单里填的商户关键词 → 列表（和服务端 perks_schema.payPatternOf 一个口径）：只按逗号、顿号、换行拆 ——
/// 「Apple Music」是一个词，空格留在词里（服务端比对时本来就不看空白）；去掉两头空白，按规范化名（[perkNameKey]，
/// 近似服务端的 normalizeName）去重，全是标点的丢掉。个数、长度的检查在表单里（错了行内说）。
List<String> splitPayKeywords(String text) {
  final out = <String>[];
  final seen = <String>{};
  for (final raw in text.split(_payKeywordSeparators)) {
    final k = raw.trim();
    final key = perkNameKey(k);
    if (key.isEmpty || !seen.add(key)) continue;
    out.add(k);
  }
  return out;
}

/// 拆开之前的每一项（去掉两头空白、丢掉空串）：表单按它查「每个最多 30 个字」（服务端也是先查长度再去重）。
List<String> rawPayKeywords(String text) => [
  for (final raw in text.split(_payKeywordSeparators))
    if (raw.trim().isNotEmpty) raw.trim(),
];

/// 「「腾讯视频」· ¥24.00–¥36.00」：AI 导入的预览（从流水识别的卡）、差异里说扣费特征。
String payPatternLabel(PerkPayPattern p) {
  final words = p.keywords.map((k) => '「$k」').join('');
  final min = p.minCents;
  final max = p.maxCents;
  final range = min != null && max != null
      ? '${Money.format(min)}–${Money.format(max)}'
      : min != null
          ? '${Money.format(min)} 以上'
          : max != null
              ? '${Money.format(max)} 以下'
              : '';
  return range.isEmpty ? words : '$words · $range';
}

/// 表单回显：用「，」连起来，再拆回去还是这几个。
String joinPayKeywords(List<String> keywords) => keywords.join('，');

final RegExp _payKeywordSeparators = RegExp(r'[,，、\r\n]+');

/// 服务端只给到期日在 [今天 − 15, 今天 + 7] 的卡找线索（server/src/modules/memberships.js 的 HINT_EXPIRED_DAYS / HINT_AHEAD_DAYS）。
const int chargeHintExpiredDays = 15;
const int chargeHintAheadDays = 7;

/// 这张卡可能有扣费线索：设了扣费特征、没归档、能续费、到期日在线索窗口里（服务端 chargeHints 的同一组条件）。
/// 线索第一次还没取回来时，「要处理」里这张卡的「续了 / 停了」先等一等，免得线索一到整行换掉、手快点错。
bool mayHaveChargeHint(Membership m, DateTime today) {
  final end = parseDay(m.expiresOn);
  if (m.archived || end == null || !renewPeriodMonths.containsKey(m.feePeriod)) return false;
  if (PerkPayPattern.tryParse(m.payPattern) == null) return false;
  return !end.isBefore(addDays(today, -chargeHintExpiredDays)) && !end.isAfter(addDays(today, chargeHintAheadDays));
}

/// 扣费线索：到期日前后看到的一笔对得上的扣费（GET /memberships/charge-hints 的一项）。
class ChargeHint {
  const ChargeHint({
    required this.membershipId,
    required this.transactionId,
    required this.occurredOn,
    required this.amountCents,
    this.merchant = '',
    required this.expiresOn,
    required this.renewTo,
  });

  final String membershipId;
  final String transactionId;

  /// 扣费那天 `YYYY-MM-DD`。
  final String occurredOn;
  final int amountCents;
  final String merchant;

  /// 卡现在的到期日。
  final String expiresOn;

  /// 续上之后的到期日（原到期日 + 一个周期，月末截断；服务端算好的）。
  final String renewTo;

  factory ChargeHint.fromJson(Map<String, dynamic> json) => ChargeHint(
    membershipId: jsonString(json['membershipId']),
    transactionId: jsonString(json['transactionId']),
    occurredOn: jsonString(json['occurredOn']),
    amountCents: jsonInt(json['amountCents']),
    merchant: jsonString(json['merchant']),
    expiresOn: jsonString(json['expiresOn']),
    renewTo: jsonString(json['renewTo']),
  );

  /// 「不是这笔」记在本机的键（和「知道了」同一个集合，perk_providers.dart 的 perkDismissedProvider）。
  String get key => 'charge:$membershipId:$transactionId';
}

/// 「9/3」；不是 [today] 那一年的写「2027/9/3」。
String perkSlashDay(String iso, DateTime today) {
  final d = parseDay(iso);
  if (d == null) return iso;
  return d.year == today.year ? '${d.month}/${d.day}' : '${d.year}/${d.month}/${d.day}';
}

/// 「已看到 9/3 扣 ¥30.00 → 续到 10/3」（spec §5「要处理」）。
String chargeHintLine(ChargeHint hint, DateTime today) =>
    '已看到 ${perkSlashDay(hint.occurredOn, today)} 扣 ${Money.format(hint.amountCents)} → 续到 ${perkSlashDay(hint.renewTo, today)}';
