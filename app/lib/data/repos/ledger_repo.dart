import 'dart:async';

import '../api/api_client.dart';
import '../local/local_store.dart';
import '../models/models.dart';

/// 主数据的一次快照，给 UI `ref.watch` 用。
///
/// 列表里每一行都要把 fundId/categoryId/accountId 翻成名字，一屏几十行、每行三四次查找；
/// [LedgerRepo.snapshot] 给出的快照带一份 [LedgerIndex]（id → 对象的 map，和过滤好的「在用」列表），
/// 查找就是一次哈希。测试里直接 `LedgerData(...)` 构造的没有索引，退回线性查找，行为一样。
class LedgerData {
  const LedgerData({
    this.members = const [],
    this.accounts = const [],
    this.funds = const [],
    this.categories = const [],
    this.rules = const [],
    this.budgets = const [],
    this.assets = const [],
    this.holdings = const [],
    this.platforms = const [],
    this.memberships = const [],
    this.benefits = const [],
    this.benefitEvents = const [],
    this.debts = const [],
    this.seq = 0,
    this.index,
  });

  final List<Member> members;
  final List<Account> accounts;
  final List<Fund> funds;
  final List<Category> categories;
  final List<Rule> rules;
  final List<Budget> budgets;
  final List<Asset> assets;
  final List<Holding> holdings;
  final List<PerkPlatform> platforms;
  final List<Membership> memberships;
  final List<Benefit> benefits;
  final List<BenefitEvent> benefitEvents;
  final List<Debt> debts;

  /// 已同步到的全局序号。
  final int seq;

  /// 见类注释；null = 没建索引，查找走线性。
  final LedgerIndex? index;

  bool get isEmpty => funds.isEmpty && accounts.isEmpty && categories.isEmpty;

  List<Fund> get activeFunds => index?.activeFunds ?? funds.where((f) => !f.archived).toList();
  /// 在用的账户，不含债务的内部账户（那些只在「资产 › 债务」里出现，记账、筛选、设置都不该挑到）。
  List<Account> get activeAccounts =>
      index?.activeAccounts ?? accounts.where((a) => !a.archived && !a.isDebt).toList();
  List<Member> get activeMembers => index?.activeMembers ?? members.where((m) => !m.archived).toList();
  List<Asset> get activeAssets => assets.where((a) => !a.archived).toList();
  List<Holding> get activeHoldings => holdings.where((h) => !h.archived).toList();
  List<PerkPlatform> get activePlatforms => platforms.where((p) => !p.archived).toList();
  List<Membership> get activeMemberships => memberships.where((m) => !m.archived).toList();
  List<Benefit> get activeBenefits => benefits.where((b) => !b.archived).toList();
  List<Debt> get activeDebts => debts.where((d) => !d.archived).toList();

  List<Category> expenseCategories() =>
      index?.expenseCategories ?? categories.where((c) => !c.archived && c.kind == 'expense').toList();

  List<Category> incomeCategories() =>
      index?.incomeCategories ?? categories.where((c) => !c.archived && c.kind == 'income').toList();

  Fund? fund(String? id) => _get(index?.funds, funds, id, (e) => e.id);
  Account? account(String? id) => _get(index?.accounts, accounts, id, (e) => e.id);
  Category? category(String? id) => _get(index?.categories, categories, id, (e) => e.id);
  Member? member(String? id) => _get(index?.members, members, id, (e) => e.id);
  Asset? asset(String? id) => _find(assets, id, (e) => e.id);
  Holding? holding(String? id) => _find(holdings, id, (e) => e.id);
  PerkPlatform? platform(String? id) => _get(index?.platforms, platforms, id, (e) => e.id);
  Membership? membership(String? id) => _get(index?.memberships, memberships, id, (e) => e.id);
  Benefit? benefit(String? id) => _get(index?.benefits, benefits, id, (e) => e.id);
  Debt? debt(String? id) => _find(debts, id, (e) => e.id);

  /// 基金在 12 色盘里的位置（没设颜色时按顺序取色）。
  int fundIndex(String id) => index?.fundOrder[id] ?? funds.indexWhere((f) => f.id == id);

  static T? _get<T>(Map<String, T>? map, List<T> list, String? id, String Function(T) idOf) {
    if (id == null) return null;
    if (map != null) return map[id];
    return _find(list, id, idOf);
  }

  static T? _find<T>(List<T> list, String? id, String Function(T) idOf) {
    if (id == null) return null;
    for (final item in list) {
      if (idOf(item) == id) return item;
    }
    return null;
  }
}

/// [LedgerData] 的查找索引：按 id 的 map + 过滤好的「在用」列表，一次快照建一次。
/// 只索引列表行里反复查的那几张表（基金、账户、类别、成员、平台、会员、权益）。
class LedgerIndex {
  LedgerIndex._({
    required this.funds,
    required this.accounts,
    required this.categories,
    required this.members,
    required this.platforms,
    required this.memberships,
    required this.benefits,
    required this.fundOrder,
    required this.activeFunds,
    required this.activeAccounts,
    required this.activeMembers,
    required this.expenseCategories,
    required this.incomeCategories,
  });

  factory LedgerIndex.of({
    required List<Fund> funds,
    required List<Account> accounts,
    required List<Category> categories,
    required List<Member> members,
    required List<PerkPlatform> platforms,
    required List<Membership> memberships,
    required List<Benefit> benefits,
  }) => LedgerIndex._(
    funds: {for (final e in funds) e.id: e},
    accounts: {for (final e in accounts) e.id: e},
    categories: {for (final e in categories) e.id: e},
    members: {for (final e in members) e.id: e},
    platforms: {for (final e in platforms) e.id: e},
    memberships: {for (final e in memberships) e.id: e},
    benefits: {for (final e in benefits) e.id: e},
    fundOrder: {for (var i = 0; i < funds.length; i++) funds[i].id: i},
    activeFunds: List.unmodifiable(funds.where((f) => !f.archived)),
    activeAccounts: List.unmodifiable(accounts.where((a) => !a.archived && !a.isDebt)),
    activeMembers: List.unmodifiable(members.where((m) => !m.archived)),
    expenseCategories: List.unmodifiable(categories.where((c) => !c.archived && c.kind == 'expense')),
    incomeCategories: List.unmodifiable(categories.where((c) => !c.archived && c.kind == 'income')),
  );

  final Map<String, Fund> funds;
  final Map<String, Account> accounts;
  final Map<String, Category> categories;
  final Map<String, Member> members;
  final Map<String, PerkPlatform> platforms;
  final Map<String, Membership> memberships;
  final Map<String, Benefit> benefits;

  /// 基金 id → 在列表里的位置（取色盘用）。
  final Map<String, int> fundOrder;
  final List<Fund> activeFunds;
  final List<Account> activeAccounts;
  final List<Member> activeMembers;
  final List<Category> expenseCategories;
  final List<Category> incomeCategories;
}

/// 主数据缓存 + `GET /changes` 增量同步 + 各实体的增删改。
///
/// 流水不在这里缓存（可能很多），只缓存成员/账户/基金/类别/规则/预算/物品/持仓，
/// 以及会员权益的平台/会员/权益/打卡事件。
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
  List<Asset> assets = [];
  List<Holding> holdings = [];
  List<PerkPlatform> platforms = [];
  List<Membership> memberships = [];
  List<Benefit> benefits = [];
  List<BenefitEvent> benefitEvents = [];
  List<Debt> debts = [];
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
    assets: List.unmodifiable(assets),
    holdings: List.unmodifiable(holdings),
    platforms: List.unmodifiable(platforms),
    memberships: List.unmodifiable(memberships),
    benefits: List.unmodifiable(benefits),
    benefitEvents: List.unmodifiable(benefitEvents),
    debts: List.unmodifiable(debts),
    seq: seq,
    index: LedgerIndex.of(
      funds: funds,
      accounts: accounts,
      categories: categories,
      members: members,
      platforms: platforms,
      memberships: memberships,
      benefits: benefits,
    ),
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
    assets = jsonList(cached['assets'], Asset.fromJson);
    holdings = jsonList(cached['holdings'], Holding.fromJson);
    platforms = jsonList(cached['platforms'], PerkPlatform.fromJson);
    memberships = jsonList(cached['memberships'], Membership.fromJson);
    benefits = jsonList(cached['benefits'], Benefit.fromJson);
    benefitEvents = jsonList(cached['benefit_events'], BenefitEvent.fromJson);
    debts = jsonList(cached['debts'], Debt.fromJson);
    // 老版本不认识的表，服务端早就把它们的行发过、游标也走过去了，接着拉永远补不回来。
    final missesTables = _tablesAddedLater.any((key) => !cached.containsKey(key));
    seq = missesTables ? 0 : jsonInt(cached['seq']);
    _notify();
  }

  /// 后来才加进同步的表：缓存里没有这个键 = 缓存是老版本写的。
  static const List<String> _tablesAddedLater = [
    'assets',
    'holdings',
    'platforms',
    'memberships',
    'benefits',
    'benefit_events',
    'debts',
  ];

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
      assets = [];
      holdings = [];
      platforms = [];
      memberships = [];
      benefits = [];
      benefitEvents = [];
      debts = [];
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
      assets = _merge(assets, res['assets'], Asset.fromJson, (e) => e.id);
      holdings = _merge(holdings, res['holdings'], Holding.fromJson, (e) => e.id);
      platforms = _merge(platforms, res['platforms'], PerkPlatform.fromJson, (e) => e.id);
      memberships = _merge(memberships, res['memberships'], Membership.fromJson, (e) => e.id);
      benefits = _merge(benefits, res['benefits'], Benefit.fromJson, (e) => e.id);
      benefitEvents = _merge(benefitEvents, res['benefit_events'], BenefitEvent.fromJson, (e) => e.id);
      debts = _merge(debts, res['debts'], Debt.fromJson, (e) => e.id);
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

  // —— 物品 / 持仓 ——
  // 增删改走 AssetsRepo / HoldingsRepo（接口不是纯 CRUD：卖出、加减仓、刷新行情），
  // 它们拿到服务端回的那一行后交给这里落本地，列表不用等下一次同步。

  Future<void> putAsset(Asset item) =>
      _put(assets, item, (e) => e.id);

  Future<void> dropAsset(String id) => _drop(assets, id, (e) => e.id);

  Future<void> putHolding(Holding item) =>
      _put(holdings, item, (e) => e.id);

  Future<void> dropHolding(String id) => _drop(holdings, id, (e) => e.id);

  // 债务走 DebtsRepo（新建会连带建内部账户、收回会记转账，不是纯 CRUD）。
  Future<void> putDebt(Debt item) => _put(debts, item, (e) => e.id);

  Future<void> dropDebt(String id) => _drop(debts, id, (e) => e.id);

  // —— 会员权益 ——
  // 增删改走 PerksRepo（删除有级联、平台能合并），拿到服务端回的那一行后交给这里落本地。

  Future<void> putPlatform(PerkPlatform item) => _put(platforms, item, (e) => e.id);

  Future<void> dropPlatform(String id) => _drop(platforms, id, (e) => e.id);

  Future<void> putMembership(Membership item) => _put(memberships, item, (e) => e.id);

  /// 级联删会员时连它名下的权益和这些权益的打卡事件一起从本地拿掉（服务端同一事务里删的）。
  Future<void> dropMembership(String id, {bool cascade = false}) async {
    memberships.removeWhere((e) => e.id == id);
    if (cascade) {
      final gone = {for (final b in benefits) if (b.membershipId == id) b.id};
      benefits.removeWhere((b) => gone.contains(b.id));
      benefitEvents.removeWhere((e) => gone.contains(e.benefitId));
    }
    await _persist();
    _notify();
  }

  Future<void> putBenefit(Benefit item) => _put(benefits, item, (e) => e.id);

  /// 一批权益（建卡时顺带的权益、建「N 选 1」时顺带的选项）：落一次盘、通知一次。
  Future<void> putBenefits(List<Benefit> items) async {
    if (items.isEmpty) return;
    for (final item in items) {
      final index = benefits.indexWhere((e) => e.id == item.id);
      if (index < 0) {
        benefits.add(item);
      } else {
        benefits[index] = item;
      }
    }
    _sort();
    await _persist();
    _notify();
  }

  /// 级联删权益时连它的选项和打卡事件一起拿掉。
  Future<void> dropBenefit(String id, {bool cascade = false}) async {
    final gone = {id, if (cascade) ...[for (final b in benefits) if (b.parentId == id) b.id]};
    benefits.removeWhere((b) => gone.contains(b.id));
    benefitEvents.removeWhere((e) => gone.contains(e.benefitId));
    await _persist();
    _notify();
  }

  Future<void> putBenefitEvent(BenefitEvent item) => _put(benefitEvents, item, (e) => e.id);

  Future<void> dropBenefitEvent(String id) => _drop(benefitEvents, id, (e) => e.id);

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

  Future<void> _put<T>(List<T> list, T item, String Function(T) idOf) async {
    final index = list.indexWhere((e) => idOf(e) == idOf(item));
    if (index < 0) {
      list.add(item);
    } else {
      list[index] = item;
    }
    _sort();
    await _persist();
    _notify();
  }

  Future<void> _drop<T>(List<T> list, String id, String Function(T) idOf) async {
    list.removeWhere((e) => idOf(e) == id);
    await _persist();
    _notify();
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
    assets.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    holdings.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    platforms.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    memberships.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    benefits.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    // 打卡事件新的在前（P3 的历史列表就这么画）。
    benefitEvents.sort((a, b) => b.occurredOn.compareTo(a.occurredOn));
    debts.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  }

  Future<void> _persist() async {
    await _store.write(cacheKey, {
      'members': members.map((e) => e.toJson()).toList(),
      'accounts': accounts.map((e) => e.toJson()).toList(),
      'funds': funds.map((e) => e.toJson()).toList(),
      'categories': categories.map((e) => e.toJson()).toList(),
      'rules': rules.map((e) => e.toJson()).toList(),
      'budgets': budgets.map((e) => e.toJson()).toList(),
      'assets': assets.map((e) => e.toJson()).toList(),
      'holdings': holdings.map((e) => e.toJson()).toList(),
      'platforms': platforms.map((e) => e.toJson()).toList(),
      'memberships': memberships.map((e) => e.toJson()).toList(),
      'benefits': benefits.map((e) => e.toJson()).toList(),
      'benefit_events': benefitEvents.map((e) => e.toJson()).toList(),
      'debts': debts.map((e) => e.toJson()).toList(),
      'seq': seq,
    });
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }
}
