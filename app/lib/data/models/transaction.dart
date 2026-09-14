import '../../core/dates.dart';
import 'json_utils.dart';

/// 一笔流水。金额永远是正数，方向由 [type] 决定。
class Transaction {
  const Transaction({
    required this.id,
    required this.clientId,
    required this.type,
    required this.amountCents,
    required this.occurredAt,
    this.currency = 'CNY',
    this.accountId,
    this.toAccountId,
    this.fundId,
    this.toFundId,
    this.categoryId,
    this.memberId,
    this.merchant,
    this.note,
    this.tags = const [],
    this.source = 'manual',
    this.status = 'confirmed',
    this.confidence,
    this.rawText,
    this.sourceApp,
    this.captureId,
    this.duplicateOfId,
    this.createdBy,
    this.createdAt,
    this.updatedAt,
    this.deletedAt,
    this.seq,
    this.pendingSync = false,
    this.serverDuplicate = false,
  });

  static const String typeExpense = 'expense';
  static const String typeIncome = 'income';
  static const String typeTransfer = 'transfer';

  static const Map<String, String> typeLabels = {
    typeExpense: '支出',
    typeIncome: '收入',
    typeTransfer: '转账',
  };

  static const Map<String, String> sourceLabels = {
    'manual': '手动',
    'notification': '通知',
    'share': '分享',
    'import': '导入',
    'recurring': '周期',
  };

  static const Map<String, String> statusLabels = {
    'confirmed': '已确认',
    'pending': '待确认',
    'duplicate': '疑似重复',
    'void': '已作废',
  };

  final String id;
  final String clientId;

  /// expense | income | transfer
  final String type;
  final int amountCents;
  final String currency;
  final DateTime occurredAt;
  final String? accountId;
  final String? toAccountId;
  final String? fundId;
  final String? toFundId;
  final String? categoryId;
  final String? memberId;
  final String? merchant;
  final String? note;
  final List<String> tags;

  /// manual | notification | share | import | recurring
  final String source;

  /// confirmed | pending | duplicate | void
  final String status;
  final double? confidence;
  final String? rawText;
  final String? sourceApp;
  final String? captureId;
  final String? duplicateOfId;
  final String? createdBy;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? deletedAt;
  final int? seq;

  /// 仅客户端：还在 outbox 里等着发给服务端。
  final bool pendingSync;

  /// 仅本次响应：服务端判定这笔疑似重复（`POST /transactions` 顶层
  /// `duplicate: true`）。不入 JSON —— 它是一次性的提示，不是行的属性；
  /// 需要持久判断重复看 `status == 'duplicate'`。
  final bool serverDuplicate;

  bool get isExpense => type == typeExpense;
  bool get isIncome => type == typeIncome;
  bool get isTransfer => type == typeTransfer;
  bool get isDeleted => deletedAt != null;
  bool get isPending => status == 'pending';
  bool get isDuplicate => status == 'duplicate';

  /// 支出为负、收入为正；转账不带方向（由两侧账户/基金自己决定）。
  int get signedAmountCents => isExpense ? -amountCents : amountCents;

  String get typeLabel => typeLabels[type] ?? type;
  String get sourceLabel => sourceLabels[source] ?? source;
  String get statusLabel => statusLabels[status] ?? status;

  /// 归到哪一天（分组用）。
  String get dayKey => Dates.isoDate(occurredAt);

  factory Transaction.fromJson(Map<String, dynamic> json) => Transaction(
    id: jsonString(json['id']),
    clientId: jsonString(json['clientId']),
    type: jsonString(json['type'], typeExpense),
    amountCents: jsonInt(json['amountCents']),
    currency: jsonString(json['currency'], 'CNY'),
    occurredAt: jsonDate(json['occurredAt']),
    accountId: jsonStringOrNull(json['accountId']),
    toAccountId: jsonStringOrNull(json['toAccountId']),
    fundId: jsonStringOrNull(json['fundId']),
    toFundId: jsonStringOrNull(json['toFundId']),
    categoryId: jsonStringOrNull(json['categoryId']),
    memberId: jsonStringOrNull(json['memberId']),
    merchant: jsonStringOrNull(json['merchant']),
    note: jsonStringOrNull(json['note']),
    tags: jsonStringList(json['tags']),
    source: jsonString(json['source'], 'manual'),
    status: jsonString(json['status'], 'confirmed'),
    confidence: jsonDoubleOrNull(json['confidence']),
    rawText: jsonStringOrNull(json['rawText']),
    sourceApp: jsonStringOrNull(json['sourceApp']),
    captureId: jsonStringOrNull(json['captureId']),
    duplicateOfId: jsonStringOrNull(json['duplicateOfId']),
    createdBy: jsonStringOrNull(json['createdBy']),
    createdAt: jsonDateOrNull(json['createdAt']),
    updatedAt: jsonDateOrNull(json['updatedAt']),
    deletedAt: jsonDateOrNull(json['deletedAt']),
    seq: jsonIntOrNull(json['seq']),
    pendingSync: jsonBool(json['pendingSync']),
  );

  /// 只用于**本地缓存**（发给服务端的请求体来自 [TransactionDraft.toJson]）。
  /// 时间写成带偏移的本地串，精度到秒 —— 毫秒对账本没有意义，换来的是
  /// 「换台设备/换个时区读缓存也不会偏一天」。
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'id': id,
      'clientId': clientId,
      'type': type,
      'amountCents': amountCents,
      'currency': currency,
      'occurredAt': Dates.isoLocal(occurredAt),
    };
    putIfNotNull(json, 'accountId', accountId);
    putIfNotNull(json, 'toAccountId', toAccountId);
    putIfNotNull(json, 'fundId', fundId);
    putIfNotNull(json, 'toFundId', toFundId);
    putIfNotNull(json, 'categoryId', categoryId);
    putIfNotNull(json, 'memberId', memberId);
    putIfNotNull(json, 'merchant', merchant);
    putIfNotNull(json, 'note', note);
    json['tags'] = tags;
    json['source'] = source;
    json['status'] = status;
    putIfNotNull(json, 'confidence', confidence);
    putIfNotNull(json, 'rawText', rawText);
    putIfNotNull(json, 'sourceApp', sourceApp);
    putIfNotNull(json, 'captureId', captureId);
    putIfNotNull(json, 'duplicateOfId', duplicateOfId);
    putIfNotNull(json, 'createdBy', createdBy);
    putIfNotNull(json, 'createdAt', createdAt == null ? null : Dates.isoLocal(createdAt!));
    putIfNotNull(json, 'updatedAt', updatedAt == null ? null : Dates.isoLocal(updatedAt!));
    putIfNotNull(json, 'deletedAt', deletedAt == null ? null : Dates.isoLocal(deletedAt!));
    putIfNotNull(json, 'seq', seq);
    if (pendingSync) json['pendingSync'] = true;
    return json;
  }

  Transaction copyWith({
    String? id,
    String? type,
    int? amountCents,
    DateTime? occurredAt,
    String? accountId,
    String? toAccountId,
    String? fundId,
    String? toFundId,
    String? categoryId,
    String? memberId,
    String? merchant,
    String? note,
    List<String>? tags,
    String? source,
    String? status,
    double? confidence,
    DateTime? deletedAt,
    bool? pendingSync,
    bool? serverDuplicate,
  }) => Transaction(
    id: id ?? this.id,
    clientId: clientId,
    type: type ?? this.type,
    amountCents: amountCents ?? this.amountCents,
    currency: currency,
    occurredAt: occurredAt ?? this.occurredAt,
    accountId: accountId ?? this.accountId,
    toAccountId: toAccountId ?? this.toAccountId,
    fundId: fundId ?? this.fundId,
    toFundId: toFundId ?? this.toFundId,
    categoryId: categoryId ?? this.categoryId,
    memberId: memberId ?? this.memberId,
    merchant: merchant ?? this.merchant,
    note: note ?? this.note,
    tags: tags ?? this.tags,
    source: source ?? this.source,
    status: status ?? this.status,
    confidence: confidence ?? this.confidence,
    rawText: rawText,
    sourceApp: sourceApp,
    captureId: captureId,
    duplicateOfId: duplicateOfId,
    createdBy: createdBy,
    createdAt: createdAt,
    updatedAt: updatedAt,
    deletedAt: deletedAt ?? this.deletedAt,
    seq: seq,
    pendingSync: pendingSync ?? this.pendingSync,
    serverDuplicate: serverDuplicate ?? this.serverDuplicate,
  );
}

/// 记一笔的请求体（`POST /transactions`，带 clientId 幂等）。
class TransactionDraft {
  const TransactionDraft({
    required this.clientId,
    required this.type,
    required this.amountCents,
    required this.occurredAt,
    this.currency = 'CNY',
    this.accountId,
    this.toAccountId,
    this.fundId,
    this.toFundId,
    this.categoryId,
    this.memberId,
    this.merchant,
    this.note,
    this.tags = const [],
    this.source = 'manual',
    this.status = 'confirmed',
    this.confidence,
    this.rawText,
    this.sourceApp,
    this.captureId,
  });

  final String clientId;
  final String type;
  final int amountCents;
  final DateTime occurredAt;
  final String currency;
  final String? accountId;
  final String? toAccountId;
  final String? fundId;
  final String? toFundId;
  final String? categoryId;
  final String? memberId;
  final String? merchant;
  final String? note;
  final List<String> tags;
  final String source;
  final String status;
  final double? confidence;
  final String? rawText;
  final String? sourceApp;
  final String? captureId;

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'clientId': clientId,
      'type': type,
      'amountCents': amountCents,
      'currency': currency,
      // 本地墙上时间 + 偏移：服务端按字符串前缀算月/日归属。
      'occurredAt': Dates.isoLocal(occurredAt),
    };
    putIfNotNull(json, 'accountId', accountId);
    putIfNotNull(json, 'toAccountId', toAccountId);
    putIfNotNull(json, 'fundId', fundId);
    putIfNotNull(json, 'toFundId', toFundId);
    putIfNotNull(json, 'categoryId', categoryId);
    putIfNotNull(json, 'memberId', memberId);
    putIfNotNull(json, 'merchant', merchant);
    putIfNotNull(json, 'note', note);
    json['source'] = source;
    json['status'] = status;
    putIfNotNull(json, 'confidence', confidence);
    putIfNotNull(json, 'rawText', rawText);
    putIfNotNull(json, 'sourceApp', sourceApp);
    putIfNotNull(json, 'captureId', captureId);
    json['tags'] = tags;
    return json;
  }

  factory TransactionDraft.fromJson(Map<String, dynamic> json) => TransactionDraft(
    clientId: jsonString(json['clientId']),
    type: jsonString(json['type'], Transaction.typeExpense),
    amountCents: jsonInt(json['amountCents']),
    occurredAt: jsonDate(json['occurredAt']),
    currency: jsonString(json['currency'], 'CNY'),
    accountId: jsonStringOrNull(json['accountId']),
    toAccountId: jsonStringOrNull(json['toAccountId']),
    fundId: jsonStringOrNull(json['fundId']),
    toFundId: jsonStringOrNull(json['toFundId']),
    categoryId: jsonStringOrNull(json['categoryId']),
    memberId: jsonStringOrNull(json['memberId']),
    merchant: jsonStringOrNull(json['merchant']),
    note: jsonStringOrNull(json['note']),
    tags: jsonStringList(json['tags']),
    source: jsonString(json['source'], 'manual'),
    status: jsonString(json['status'], 'confirmed'),
    confidence: jsonDoubleOrNull(json['confidence']),
    rawText: jsonStringOrNull(json['rawText']),
    sourceApp: jsonStringOrNull(json['sourceApp']),
    captureId: jsonStringOrNull(json['captureId']),
  );

  /// 离线记账时先给 UI 一条「本地存在」的流水，id 借用 clientId。
  Transaction toOptimisticTransaction() => Transaction(
    id: clientId,
    clientId: clientId,
    type: type,
    amountCents: amountCents,
    currency: currency,
    occurredAt: occurredAt,
    accountId: accountId,
    toAccountId: toAccountId,
    fundId: fundId,
    toFundId: toFundId,
    categoryId: categoryId,
    memberId: memberId,
    merchant: merchant,
    note: note,
    tags: tags,
    source: source,
    status: status,
    confidence: confidence,
    rawText: rawText,
    sourceApp: sourceApp,
    captureId: captureId,
    createdAt: DateTime.now(),
    pendingSync: true,
  );
}

/// 账单页筛选条件。
class TxFilter {
  const TxFilter({
    this.from,
    this.to,
    this.type,
    this.fundId,
    this.accountId,
    this.categoryId,
    this.memberId,
    this.status,
    this.source,
    this.q,
    this.limit,
  });

  final DateTime? from;
  final DateTime? to;
  final String? type;
  final String? fundId;
  final String? accountId;
  final String? categoryId;
  final String? memberId;
  final String? status;
  final String? source;
  final String? q;
  final int? limit;

  bool get isEmpty =>
      from == null &&
      to == null &&
      type == null &&
      fundId == null &&
      accountId == null &&
      categoryId == null &&
      memberId == null &&
      status == null &&
      source == null &&
      (q == null || q!.isEmpty);

  /// 除时间范围外还剩几个筛选项（UI 上显示「筛选 · 2」）。
  int get activeCount => [
    type,
    fundId,
    accountId,
    categoryId,
    memberId,
    status,
    source,
    (q?.isEmpty ?? true) ? null : q,
  ].where((e) => e != null).length;

  Map<String, String> toQuery() {
    final q0 = <String, String>{};
    if (from != null) q0['from'] = Dates.isoDate(from!);
    if (to != null) q0['to'] = Dates.isoDate(to!);
    if (type != null) q0['type'] = type!;
    if (fundId != null) q0['fundId'] = fundId!;
    if (accountId != null) q0['accountId'] = accountId!;
    if (categoryId != null) q0['categoryId'] = categoryId!;
    if (memberId != null) q0['memberId'] = memberId!;
    if (status != null) q0['status'] = status!;
    if (source != null) q0['source'] = source!;
    if (q != null && q!.isNotEmpty) q0['q'] = q!;
    if (limit != null) q0['limit'] = '$limit';
    return q0;
  }

  TxFilter copyWith({
    DateTime? from,
    DateTime? to,
    String? type,
    String? fundId,
    String? accountId,
    String? categoryId,
    String? memberId,
    String? status,
    String? source,
    String? q,
    int? limit,
    bool clearRange = false,
    bool clearFacets = false,
  }) => TxFilter(
    from: clearRange ? null : (from ?? this.from),
    to: clearRange ? null : (to ?? this.to),
    type: clearFacets ? null : (type ?? this.type),
    fundId: clearFacets ? null : (fundId ?? this.fundId),
    accountId: clearFacets ? null : (accountId ?? this.accountId),
    categoryId: clearFacets ? null : (categoryId ?? this.categoryId),
    memberId: clearFacets ? null : (memberId ?? this.memberId),
    status: clearFacets ? null : (status ?? this.status),
    source: clearFacets ? null : (source ?? this.source),
    q: clearFacets ? null : (q ?? this.q),
    limit: limit ?? this.limit,
  );
}

/// 一页流水 + 下一页游标。
class TxPage {
  const TxPage({required this.items, this.nextCursor});

  final List<Transaction> items;
  final String? nextCursor;

  bool get hasMore => nextCursor != null && nextCursor!.isNotEmpty;
  bool get isEmpty => items.isEmpty;

  static const TxPage empty = TxPage(items: []);

  factory TxPage.fromJson(Map<String, dynamic> json) => TxPage(
    items: jsonList(json['items'], Transaction.fromJson),
    nextCursor: jsonStringOrNull(json['nextCursor']),
  );

  TxPage append(TxPage next) =>
      TxPage(items: [...items, ...next.items], nextCursor: next.nextCursor);
}
