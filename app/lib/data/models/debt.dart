import 'json_utils.dart';

/// 债务：借出（别人欠我）、借入（我欠别人）、人情（server/src/modules/debts.js）。
///
/// 还剩多少不在这里：每笔债务背后有一个 kind = 'debt' 的内部账户（[accountId]），余额就是还剩多少，
/// 借出为正、借入为负，从 `/stats/overview` 的账户余额里拿（见 [Debt.outstandingOf]）。
class Debt {
  const Debt({
    required this.id,
    this.accountId,
    required this.direction,
    this.kind = kindLoan,
    required this.counterparty,
    this.amountCents = 0,
    required this.startedOn,
    this.dueOn,
    this.counted = true,
    this.memberId,
    this.note,
    this.memoLog = const [],
    this.sortOrder = 0,
    this.archived = false,
  });

  static const String lend = 'lend';
  static const String borrow = 'borrow';

  static const String kindLoan = 'loan';
  static const String kindCredit = 'credit';
  static const String kindFavor = 'favor';
  static const String kindOther = 'other';

  static const List<String> kinds = [kindLoan, kindCredit, kindFavor, kindOther];

  static const Map<String, String> kindLabels = {
    kindLoan: '借款',
    kindCredit: '欠款',
    kindFavor: '人情',
    kindOther: '其他',
  };

  final String id;

  /// 内部账户；服务端新建时一并建好，老数据或刚同步了一半时可能还没有。
  final String? accountId;

  /// [lend] | [borrow]
  final String direction;
  final String kind;
  final String counterparty;

  /// 原始金额（借出去 / 借进来多少，追加时累加），不是还剩多少。
  final int amountCents;

  /// `YYYY-MM-DD`
  final String startedOn;
  final String? dueOn;

  /// 计入净资产（人情默认否）。
  final bool counted;
  final String? memberId;
  final String? note;

  /// 不经账户的收回 / 追加（改期初的那几笔），老的在前。
  final List<DebtMemo> memoLog;
  final int sortOrder;
  final bool archived;

  bool get isLend => direction == lend;
  bool get isFavor => kind == kindFavor;
  String get kindLabel => kindLabels[kind] ?? '其他';

  /// 「借给 张三」「欠 李四」「人情 王五」—— 和内部账户同名，流水里也这么显示。
  String get title {
    if (isFavor) return '人情 $counterparty';
    return isLend ? '借给 $counterparty' : '欠 $counterparty';
  }

  /// 内部账户余额 → 还剩多少（正数）。拿不到余额时是 null。
  int? outstandingOf(int? accountBalanceCents) {
    if (accountBalanceCents == null) return null;
    return isLend ? accountBalanceCents : -accountBalanceCents;
  }

  factory Debt.fromJson(Map<String, dynamic> json) => Debt(
    id: jsonString(json['id']),
    accountId: jsonStringOrNull(json['accountId']),
    direction: jsonString(json['direction'], lend),
    kind: jsonString(json['kind'], kindLoan),
    counterparty: jsonString(json['counterparty']),
    amountCents: jsonInt(json['amountCents']),
    startedOn: jsonString(json['startedOn']),
    dueOn: jsonStringOrNull(json['dueOn']),
    counted: jsonBool(json['counted'], true),
    memberId: jsonStringOrNull(json['memberId']),
    note: jsonStringOrNull(json['note']),
    memoLog: json['memoLog'] is List
        ? [
            for (final e in json['memoLog'] as List)
              if (e is Map) DebtMemo.fromJson(Map<String, dynamic>.from(e)),
          ]
        : const [],
    sortOrder: jsonInt(json['sortOrder']),
    archived: jsonBool(json['archived']),
  );

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'id': id,
      'direction': direction,
      'kind': kind,
      'counterparty': counterparty,
      'amountCents': amountCents,
      'startedOn': startedOn,
      'counted': counted,
      'memoLog': memoLog.map((e) => e.toJson()).toList(),
      'sortOrder': sortOrder,
      'archived': archived,
    };
    putIfNotNull(json, 'accountId', accountId);
    putIfNotNull(json, 'dueOn', dueOn);
    putIfNotNull(json, 'memberId', memberId);
    putIfNotNull(json, 'note', note);
    return json;
  }
}

/// 一行不经账户的变动：[amountCents] 是对内部账户余额的影响（借出时 + 是又借出去了）。
class DebtMemo {
  const DebtMemo({
    required this.on,
    required this.amountCents,
    this.note = '',
    this.recorded = false,
    this.action,
  });

  final String on;
  final int amountCents;
  final String note;

  /// 人情：钱那一边另记了一笔支出 / 收入。
  final bool recorded;

  /// settle | add；起始那一行没有。
  final String? action;

  factory DebtMemo.fromJson(Map<String, dynamic> json) => DebtMemo(
    on: jsonString(json['on']),
    amountCents: jsonInt(json['amountCents']),
    note: jsonString(json['note']),
    recorded: jsonBool(json['recorded']),
    action: jsonStringOrNull(json['action']),
  );

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{'on': on, 'amountCents': amountCents, 'note': note, 'recorded': recorded};
    putIfNotNull(json, 'action', action);
    return json;
  }
}
