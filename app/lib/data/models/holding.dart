import 'json_utils.dart';

/// 投资持仓。份额与价格都是 ×10000 的整数（基金份额常见 2 位小数、净值 4 位）。
///
/// 份额与成本只能经加仓/减仓接口改；市值、收益这些派生数在 `asset_math.dart` 里算。
class Holding {
  const Holding({
    required this.id,
    this.name = '',
    this.code,
    this.market = 'other',
    this.quantityE4 = 0,
    this.costCents = 0,
    this.priceE4,
    this.prevCloseE4,
    this.priceSource = sourceManual,
    this.priceAt,
    required this.openedOn,
    this.accountId,
    this.realizedCents = 0,
    this.note,
    this.sortOrder = 0,
    this.archived = false,
  });

  static const List<String> markets = ['fund', 'sh', 'sz', 'bj', 'other'];

  static const Map<String, String> marketLabels = {
    'fund': '场外基金',
    'sh': '沪市',
    'sz': '深市',
    'bj': '北交所',
    'other': '其他',
  };

  /// 这几个市场有行情源，能开自动行情。
  static const Set<String> autoMarkets = {'fund', 'sh', 'sz', 'bj'};

  static const String sourceAuto = 'auto';
  static const String sourceManual = 'manual';

  final String id;
  final String name;
  final String? code;

  /// fund | sh | sz | bj | other
  final String market;
  final int quantityE4;

  /// 当前持仓总成本（移动平均）。
  final int costCents;
  final int? priceE4;

  /// 昨收 / 上一个净值；手动改价后为 null。
  final int? prevCloseE4;

  /// auto | manual
  final String priceSource;
  final DateTime? priceAt;

  /// `YYYY-MM-DD`
  final String openedOn;

  /// 挂的投资账户（kind=invest）。
  final String? accountId;
  final int realizedCents;
  final String? note;
  final int sortOrder;
  final bool archived;

  bool get isAuto => priceSource == sourceAuto;
  bool get isCleared => quantityE4 <= 0;
  String get marketLabel => marketLabels[market] ?? '其他';

  /// 名称和代码服务端要求至少有一个。
  String get label {
    if (name.isNotEmpty) return name;
    final c = code;
    return c == null || c.isEmpty ? '持仓' : c;
  }

  factory Holding.fromJson(Map<String, dynamic> json) => Holding(
    id: jsonString(json['id']),
    name: jsonString(json['name']),
    code: jsonStringOrNull(json['code']),
    market: jsonString(json['market'], 'other'),
    quantityE4: jsonInt(json['quantityE4']),
    costCents: jsonInt(json['costCents']),
    priceE4: jsonIntOrNull(json['priceE4']),
    prevCloseE4: jsonIntOrNull(json['prevCloseE4']),
    priceSource: jsonString(json['priceSource'], sourceManual),
    priceAt: jsonDateOrNull(json['priceAt']),
    openedOn: jsonString(json['openedOn']),
    accountId: jsonStringOrNull(json['accountId']),
    realizedCents: jsonInt(json['realizedCents']),
    note: jsonStringOrNull(json['note']),
    sortOrder: jsonInt(json['sortOrder']),
    archived: jsonBool(json['archived']),
  );

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'id': id,
      'name': name,
      'market': market,
      'quantityE4': quantityE4,
      'costCents': costCents,
      'priceSource': priceSource,
      'openedOn': openedOn,
      'realizedCents': realizedCents,
    };
    putIfNotNull(json, 'code', code);
    putIfNotNull(json, 'priceE4', priceE4);
    putIfNotNull(json, 'prevCloseE4', prevCloseE4);
    putIfNotNull(json, 'priceAt', priceAt?.toIso8601String());
    putIfNotNull(json, 'accountId', accountId);
    putIfNotNull(json, 'note', note);
    json['sortOrder'] = sortOrder;
    json['archived'] = archived;
    return json;
  }
}
