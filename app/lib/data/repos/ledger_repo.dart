import 'dart:async';

import '../api/api_client.dart';
import '../local/local_store.dart';
import '../models/models.dart';

/// 主数据的一次快照，给 UI `ref.watch` 用。
class LedgerData {
  const LedgerData({
    this.members = const [],
    this.accounts = const [],
    this.funds = const [],
    this.categories = const [],
    this.rules = const [],
    this.budgets = const [],
    this.seq = 0,
  });

  final List<Member> members;
  final List<Account> accounts;
  final List<Fund> funds;
  final List<Category> categories;
  final List<Rule> rules;
  final List<Budget> budgets;

  /// 已同步到的全局序号。
  final int seq;

  bool get isEmpty => funds.isEmpty && accounts.isEmpty && categories.isEmpty;

  List<Fund> get activeFunds => funds.where((f) => !f.archived).toList();
  List<Account> get activeAccounts => accounts.where((a) => !a.archived).toList();
  List<Member> get activeMembers => members.where((m) => !m.archived).toList();

  List<Category> expenseCategories() =>
      categories.where((c) => !c.archived && c.kind == 'expense').toList();

  List<Category> incomeCategories() =>
      categories.where((c) => !c.archived && c.kind == 'income').toList();

  Fund? fund(String? id) => _find(funds, id, (e) => e.id);
  Account? account(String? id) => _find(accounts, id, (e) => e.id);
  Category? category(String? id) => _find(categories, id, (e) => e.id);
  Member? member(String? id) => _find(members, id, (e) => e.id);

  /// 基金在 12 色盘里的位置（没设颜色时按顺序取色）。
  int fundIndex(String id) => funds.indexWhere((f) => f.id == id);

  static T? _find<T>(List<T> list, String? id, String Function(T) idOf) {
    if (id == null) return null;
    for (final item in list) {
      if (idOf(item) == id) return item;
    }
    return null;
  }
}

/// 主数据缓存 + `GET /changes` 增量同步 + 各实体的增删改。
///
/// 流水不在这里缓存（可能很多），只缓存成员/账户/基金/类别/规则/预算。
class LedgerRepo {
  LedgerRepo({required ApiClient api, required LocalStore store})
    : _api = api,
      _store = store;

  static const String cacheKey = 'ledger';
  static const int pageLimit = 500;

  final ApiClient _api;
  final LocalStore _store;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  List<Member> members = [];
  List<Account> accounts = [];
  List<Fund> funds = [];
  List<Category> categories = [];
  List<Rule> rules = [];
  List<Budget> budgets = [];
  int seq = 0;

  /// 任何一次本地数据变化都会打一下（UI 重新取 [snapshot]）。
  Stream<void> get changes => _changes.stream;

  LedgerData get snapshot => LedgerData(
    members: List.unmodifiable(members),
    accounts: List.unmodifiable(accounts),
    funds: List.unmodifiable(funds),
    categories: List.unmodifiable(categories),
    rules: List.unmodifiable(rules),
    budgets: List.unmodifiable(budgets),
    seq: seq,
  );

  /// 读本地缓存（离线也能先把界面画出来）。
  Future<void> load() async {
    final cached = await _store.read<Map<String, dynamic>>(cacheKey);
    if (cached == null) return;
    members = jsonList(cached['members'], Member.fromJson);
    accounts = jsonList(cached['accounts'], Account.fromJson);
    funds = jsonList(cached['funds'], Fund.fromJson);
    categories = jsonList(cached['categories'], Category.fromJson);
    rules = jsonList(cached['rules'], Rule.fromJson);
    budgets = jsonList(cached['budgets'], Budget.fromJson);
    seq = jsonInt(cached['seq']);
    _notify();
  }

  /// 增量同步：`GET /changes?since=`，按 id 合并，软删的直接删掉。
  ///
  /// [full] 为真时从 0 开始重来（换服务器/数据对不上时用）。
  Future<void> sync({bool full = false}) async {
    if (full) {
      seq = 0;
      members = [];
      accounts = [];
      funds = [];
      categories = [];
      rules = [];
      budgets = [];
    }
    var more = true;
    var guard = 0;
    while (more && guard++ < 100) {
      final res = await _api.get(
        '/changes',
        query: {'since': '$seq', 'limit': '$pageLimit'},
      );
      members = _merge(members, res['members'], Member.fromJson, (e) => e.id);
      accounts = _merge(accounts, res['accounts'], Account.fromJson, (e) => e.id);
      funds = _merge(funds, res['funds'], Fund.fromJson, (e) => e.id);
      categories = _merge(categories, res['categories'], Category.fromJson, (e) => e.id);
      rules = _merge(rules, res['rules'], Rule.fromJson, (e) => e.id);
      budgets = _merge(budgets, res['budgets'], Budget.fromJson, budgetKey);
      seq = jsonInt(res['next'], seq);
      more = jsonBool(res['more']);
    }
    _sort();
    await _persist();
    _notify();
  }

  // —— 基金 ——
  Future<Fund> createFund(Map<String, dynamic> body) =>
      _create('/funds', 'fund', body, Fund.fromJson, funds, (e) => e.id);

  Future<Fund> updateFund(String id, Map<String, dynamic> patch) =>
      _update('/funds', 'fund', id, patch, Fund.fromJson, funds, (e) => e.id);

  Future<void> deleteFund(String id) =>
      _delete('/funds', id, funds, (e) => e.id);

  /// `GET /funds/templates` —— 新建基金时的内置模板。
  Future<List<Fund>> fundTemplates() async {
    final res = await _api.get('/funds/templates');
    return jsonList(res['items'], Fund.fromJson);
  }

  // —— 账户 ——
  Future<Account> createAccount(Map<String, dynamic> body) =>
      _create('/accounts', 'account', body, Account.fromJson, accounts, (e) => e.id);

  Future<Account> updateAccount(String id, Map<String, dynamic> patch) => _update(
    '/accounts',
    'account',
    id,
    patch,
    Account.fromJson,
    accounts,
    (e) => e.id,
  );

  Future<void> deleteAccount(String id) =>
      _delete('/accounts', id, accounts, (e) => e.id);

  // —— 类别 ——
  Future<Category> createCategory(Map<String, dynamic> body) => _create(
    '/categories',
    'category',
    body,
    Category.fromJson,
    categories,
    (e) => e.id,
  );

  Future<Category> updateCategory(String id, Map<String, dynamic> patch) => _update(
    '/categories',
    'category',
    id,
    patch,
    Category.fromJson,
    categories,
    (e) => e.id,
  );

  Future<void> deleteCategory(String id) =>
      _delete('/categories', id, categories, (e) => e.id);

  // —— 成员 ——
  Future<Member> createMember(Map<String, dynamic> body) =>
      _create('/members', 'member', body, Member.fromJson, members, (e) => e.id);

  Future<Member> updateMember(String id, Map<String, dynamic> patch) =>
      _update('/members', 'member', id, patch, Member.fromJson, members, (e) => e.id);

  Future<void> deleteMember(String id) =>
      _delete('/members', id, members, (e) => e.id);

  Future<void> resetMemberPassword(String id, String password) async {
    await _api.post('/members/$id/reset-password', {'password': password});
  }

  // —— 规则 ——
  Future<Rule> createRule(Map<String, dynamic> body) =>
      _create('/rules', 'rule', body, Rule.fromJson, rules, (e) => e.id);

  Future<Rule> updateRule(String id, Map<String, dynamic> patch) =>
      _update('/rules', 'rule', id, patch, Rule.fromJson, rules, (e) => e.id);

  Future<void> deleteRule(String id) => _delete('/rules', id, rules, (e) => e.id);

  // —— 预算 ——
  /// `PUT /budgets`，`amountCents` 传 null = 取消这条预算。
  ///
  /// 用服务端回的那一行（带真 id）落本地，别自己造无 id 的行 —— 否则下次
  /// `/changes` 带 id 的同一条会变成第二条。
  Future<void> setBudget({
    required String scope,
    required String refId,
    required String month,
    int? amountCents,
  }) async {
    final res = await _api.put('/budgets', {
      'scope': scope,
      'refId': refId,
      'month': month,
      'amountCents': amountCents,
    });
    budgets.removeWhere(
      (b) => b.scope == scope && b.refId == refId && b.month == month,
    );
    final row = unwrap(res, 'budget');
    if (amountCents != null) {
      budgets.add(
        row.isEmpty
            ? Budget(scope: scope, refId: refId, month: month, amountCents: amountCents)
            : Budget.fromJson(row),
      );
    }
    await _persist();
    _notify();
  }

  /// 某月生效的预算（精确月优先，否则用 `'*'` 默认）。
  Future<List<Budget>> budgetsForMonth(String month) async {
    final res = await _api.get('/budgets', query: {'month': month});
    return jsonList(res['items'], Budget.fromJson);
  }

  /// 拖动排序后写回顺序。
  Future<void> reorder(String entity, List<String> ids) async {
    await _api.put('/$entity/reorder', {'ids': ids});
    await sync();
  }

  void dispose() {
    _changes.close();
  }

  /// [envelope] 是服务端包实体用的键（`{fund: {...}}`，见 server/src/lib/crud.js）。
  Future<T> _create<T>(
    String path,
    String envelope,
    Map<String, dynamic> body,
    T Function(Map<String, dynamic>) parse,
    List<T> list,
    String Function(T) idOf,
  ) async {
    final item = parse(unwrap(await _api.post(path, body), envelope));
    list.removeWhere((e) => idOf(e) == idOf(item));
    list.add(item);
    _sort();
    await _persist();
    _notify();
    return item;
  }

  Future<T> _update<T>(
    String path,
    String envelope,
    String id,
    Map<String, dynamic> patch,
    T Function(Map<String, dynamic>) parse,
    List<T> list,
    String Function(T) idOf,
  ) async {
    final item = parse(unwrap(await _api.patch('$path/$id', patch), envelope));
    final index = list.indexWhere((e) => idOf(e) == id);
    if (index < 0) {
      list.add(item);
    } else {
      list[index] = item;
    }
    _sort();
    await _persist();
    _notify();
    return item;
  }

  Future<void> _delete<T>(
    String path,
    String id,
    List<T> list,
    String Function(T) idOf,
  ) async {
    await _api.delete('$path/$id');
    list.removeWhere((e) => idOf(e) == id);
    await _persist();
    _notify();
  }

  /// 预算的身份是 `(scope, refId, month)`（服务端的 UNIQUE 约束），不是 id ——
  /// 本地先写、服务端后给 id 的那一瞬间也不会重复。
  static String budgetKey(Budget b) => '${b.scope}/${b.refId}/${b.month}';

  /// 按 id 合并一页 changes：软删（`deletedAt` 非空）的从本地移除。
  List<T> _merge<T>(
    List<T> current,
    Object? raw,
    T Function(Map<String, dynamic>) parse,
    String Function(T) idOf,
  ) {
    final rows = jsonMapList(raw);
    if (rows.isEmpty) return current;
    final byId = {for (final item in current) idOf(item): item};
    for (final row in rows) {
      final item = parse(row);
      final id = idOf(item);
      if (id.isEmpty) continue;
      if (row['deletedAt'] != null) {
        byId.remove(id);
      } else {
        byId[id] = item;
      }
    }
    return byId.values.toList();
  }

  void _sort() {
    members.sort((a, b) => a.label.compareTo(b.label));
    accounts.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    funds.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    categories.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    rules.sort((a, b) => b.priority.compareTo(a.priority));
  }

  Future<void> _persist() async {
    await _store.write(cacheKey, {
      'members': members.map((e) => e.toJson()).toList(),
      'accounts': accounts.map((e) => e.toJson()).toList(),
      'funds': funds.map((e) => e.toJson()).toList(),
      'categories': categories.map((e) => e.toJson()).toList(),
      'rules': rules.map((e) => e.toJson()).toList(),
      'budgets': budgets.map((e) => e.toJson()).toList(),
      'seq': seq,
    });
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }
}
