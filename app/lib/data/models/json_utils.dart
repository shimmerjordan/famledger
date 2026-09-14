/// 宽容的 JSON 取值：服务端少给字段、类型漂移都不应该让客户端崩。
String jsonString(Object? v, [String fallback = '']) =>
    v == null ? fallback : v.toString();

String? jsonStringOrNull(Object? v) {
  if (v == null) return null;
  final s = v.toString();
  return s.isEmpty ? null : s;
}

int jsonInt(Object? v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is num) return v.round();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

int? jsonIntOrNull(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.round();
  if (v is String) return int.tryParse(v);
  return null;
}

double jsonDouble(Object? v, [double fallback = 0]) {
  if (v is double) return v;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? fallback;
  return fallback;
}

double? jsonDoubleOrNull(Object? v) {
  if (v == null) return null;
  if (v is double) return v;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

bool jsonBool(Object? v, [bool fallback = false]) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v == 'true' || v == '1';
  return fallback;
}

DateTime jsonDate(Object? v, [DateTime? fallback]) =>
    jsonDateOrNull(v) ?? fallback ?? DateTime.fromMillisecondsSinceEpoch(0);

/// 一律落到**本地时间**：`DateTime.parse('…+08:00')` 给的是 `isUtc = true` 的
/// 实例，直接 `.hour` 会显示成 UTC 的钟点（晚上 9 点的账变成下午 1 点）。
/// 在解析边界上转一次，UI 就不用记得处处 `toLocal()`。
DateTime? jsonDateOrNull(Object? v) {
  if (v == null) return null;
  if (v is DateTime) return v.toLocal();
  if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
  return DateTime.tryParse(v.toString())?.toLocal();
}

List<String> jsonStringList(Object? v) {
  if (v is List) return v.map((e) => e.toString()).toList();
  return const [];
}

Map<String, dynamic> jsonMap(Object? v) {
  if (v is Map) return v.map((k, value) => MapEntry(k.toString(), value));
  return <String, dynamic>{};
}

List<Map<String, dynamic>> jsonMapList(Object? v) {
  if (v is List) return v.whereType<Map>().map(jsonMap).toList();
  return const [];
}

/// 列表字段统一解析：`[{...}]` → `[T]`。
List<T> jsonList<T>(Object? v, T Function(Map<String, dynamic>) parse) =>
    jsonMapList(v).map(parse).toList();

/// 只在值非空时写入，避免把一堆 null 发给服务端。
void putIfNotNull(Map<String, dynamic> target, String key, Object? value) {
  if (value != null) target[key] = value;
}

/// 服务端把「单个实体」包一层再返回：`{fund: {...}}`、`{transaction: {...}}`
/// （见 `server/src/lib/crud.js` 与 `server/src/modules/transactions.js`）。
///
/// 容忍三种情况：包了（取里面）、没包但本身就是实体（有 `id`，直接用）、
/// 两者都不是（返回空 Map，调用方自己判断 `isEmpty`，例如预算被删掉时
/// 服务端回的是 `{budget: null}`）。
Map<String, dynamic> unwrap(Map<String, dynamic> res, String key) {
  final inner = res[key];
  if (inner is Map) return jsonMap(inner);
  if (res['id'] != null) return res;
  return const <String, dynamic>{};
}
