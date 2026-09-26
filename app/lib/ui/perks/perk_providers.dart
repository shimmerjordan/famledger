import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/providers.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../../data/repos/perks_repo.dart';

final perksRepoProvider = Provider<PerksRepo>(
  (ref) => PerksRepo(
    api: ref.watch(apiProvider),
    ledger: ref.watch(ledgerRepoProvider),
  ),
);

/// 会员权益 tab 顶上的分段（spec §5）：本期（要处理、本期待领……）或全部。
enum PerkView { current, all }

/// 「我 / 全家」：我 = 我的加上全家共用的。
enum PerkScope { mine, family }

/// 「全部」视图怎么分组：按会员，或按领取平台（回答「什么会员要去哪个平台领」）。
enum PerkGrouping { byMembership, byClaimPlatform }

/// 会员权益 tab 上次的选择，记在本机（spec §5「上次的选择记在本机 prefs」），不同步。
class PerkViewPrefs {
  const PerkViewPrefs({this.view = PerkView.current, this.scope = PerkScope.family, this.grouping = PerkGrouping.byMembership});

  final PerkView view;
  final PerkScope scope;
  final PerkGrouping grouping;

  PerkViewPrefs copyWith({PerkView? view, PerkScope? scope, PerkGrouping? grouping}) =>
      PerkViewPrefs(view: view ?? this.view, scope: scope ?? this.scope, grouping: grouping ?? this.grouping);

  /// 不认识的值（以后的版本写的、手改坏的）按默认。
  factory PerkViewPrefs.fromJson(Map<String, dynamic> json) {
    T pick<T extends Enum>(List<T> values, Object? raw, T fallback) {
      for (final v in values) {
        if (v.name == raw) return v;
      }
      return fallback;
    }

    return PerkViewPrefs(
      view: pick(PerkView.values, json['view'], PerkView.current),
      scope: pick(PerkScope.values, json['scope'], PerkScope.family),
      grouping: pick(PerkGrouping.values, json['grouping'], PerkGrouping.byMembership),
    );
  }

  Map<String, dynamic> toJson() => {'view': view.name, 'scope': scope.name, 'grouping': grouping.name};
}

final perkViewPrefsProvider = NotifierProvider<PerkViewPrefsController, PerkViewPrefs>(PerkViewPrefsController.new);

class PerkViewPrefsController extends Notifier<PerkViewPrefs> {
  static const String storeKey = 'ui.perks.view';

  /// 读盘回来之前用户已经点过了：以用户点的为准，不拿旧值盖回去。
  bool _touched = false;

  @override
  PerkViewPrefs build() {
    // 读盘是异步的，但页面不能等：先给默认，读到了再刷一次。
    unawaited(_load());
    return const PerkViewPrefs();
  }

  Future<void> _load() async {
    try {
      final raw = await ref.read(localStoreProvider).read<Map<String, dynamic>>(storeKey);
      if (raw != null && !_touched) state = PerkViewPrefs.fromJson(raw);
    } catch (_) {
      // 读不出来（没有本地存储、坏数据）就用默认。
    }
  }

  Future<void> set(PerkViewPrefs next) async {
    _touched = true;
    state = next;
    try {
      await ref.read(localStoreProvider).write(storeKey, next.toJson());
    } catch (_) {
      // 存不下就下次回到默认，不值得打断用户。
    }
  }
}

/// 点过「知道了」的提醒（[PerkAlert.key]），只记在本机、不同步（spec §3）。
final perkDismissedProvider = NotifierProvider<PerkDismissedController, Set<String>>(PerkDismissedController.new);

class PerkDismissedController extends Notifier<Set<String>> {
  static const String storeKey = 'ui.perks.dismissed';

  /// 记了多久的键就扔掉：键里带着目标日，过去这么久的早就不会再出现。
  static const Duration keep = Duration(days: 90);

  Map<String, String> _saved = {};
  Future<void>? _loading;
  int _builds = 0;

  @override
  Set<String> build() {
    // 退出登录会清空本机缓存：跟着重新读盘，内存里不留上一个人点过的（P6 起它还决定通知里提不提某一项）。
    ref.watch(localStoreEpochProvider);
    _saved = {};
    _loading = _load(++_builds);
    return const {};
  }

  Future<void> _load(int build) async {
    try {
      final raw = await ref.read(localStoreProvider).read<Map<String, dynamic>>(storeKey);
      if (raw == null || build != _builds) return;
      _saved = {for (final e in raw.entries) e.key: '${e.value}', ..._saved};
      state = {...state, ..._saved.keys};
    } catch (_) {
      // 读不出来就当没点过。
    }
  }

  Future<void> dismiss(String key, DateTime now) async {
    // 先从界面上拿掉；等盘里的旧记录读回来再合并写回 —— 读盘前就点了的话，直接写会把以前点过的全盖掉。
    state = {...state, key};
    await _loading;
    final cutoff = now.subtract(keep).toIso8601String();
    _saved = {
      for (final e in _saved.entries)
        if (e.value.compareTo(cutoff) >= 0) e.key: e.value,
      key: now.toIso8601String(),
    };
    state = _saved.keys.toSet();
    try {
      await ref.read(localStoreProvider).write(storeKey, _saved);
    } catch (_) {
      // 存不下就下次再提醒一遍。
    }
  }
}

/// 扣费线索（spec §5「要处理」）：服务端现查流水（本地不缓存流水）。同步往前走了（seq 变了：续上了、新记了流水、
/// 别的设备改了卡）就重新取；取不到（离线、老服务端）当没有，不打扰。不用 autoDispose（和这一片别的 provider 一样）：
/// 列表很小，切走再回来不用重新转圈。
final chargeHintsProvider = FutureProvider<List<ChargeHint>>((ref) async {
  ref.watch(ledgerProvider.select((v) => v.valueOrNull?.seq));
  try {
    return await ref.watch(perksRepoProvider).chargeHints();
  } catch (_) {
    return const [];
  }
});

/// 当前登录的成员（「我」）；没登录是 null（按全家看）。
final perkMeProvider = Provider<String?>((ref) => ref.watch(sessionProvider)?.me.id);

/// 一键打卡、续费失败且不确定送到没有时记下这次的 clientId（键见 perk_actions.dart 各动作），[ttl] 之内再点沿用它：
/// 服务端认得出是同一次，不会记两条。成功后清掉；过了 [ttl] 也不再沿用 —— 那时同步早把第一次的结果带回来了，
/// 再点是新的一次（同一天又用了一张），不能被服务端当成重发吞掉。
class PerkRetryIds {
  static const Duration ttl = Duration(minutes: 10);

  final Map<String, (String, DateTime)> _ids = {};

  /// 这个键还能沿用的 clientId；没有或过了 [ttl] 是 null。
  String? of(String key, DateTime now) {
    final hit = _ids[key];
    if (hit == null) return null;
    if (now.difference(hit.$2) > ttl) {
      _ids.remove(key);
      return null;
    }
    return hit.$1;
  }

  void remember(String key, String clientId, DateTime now) => _ids[key] = (clientId, now);

  void forget(String key) => _ids.remove(key);
}

final perkRetryIdsProvider = Provider<PerkRetryIds>((ref) => PerkRetryIds());

/// 正在路上的一键动作：请求没回来之前按钮置灰，再点直接忽略 —— 网慢时点了没反应再点一下，不能换个新的 clientId
/// 续出两期、记出两条。键见 [perkEventBusyKey]、[perkCardBusyKey]。
final perkBusyProvider = NotifierProvider<PerkBusyController, Set<String>>(PerkBusyController.new);

class PerkBusyController extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  /// 占上 [key]；已经有人占着就返回 false，调用方什么都不做。
  bool start(String key) {
    if (state.contains(key)) return false;
    state = {...state, key};
    return true;
  }

  void done(String key) => state = {...state}..remove(key);
}

/// 打卡占的键：N 选 1 按父权益占（一期只挑一个，连点两个选项也只该记一个）。
String perkEventBusyKey(Benefit benefit, {Benefit? parent}) => 'event/${parent?.id ?? benefit.id}';

/// 「续了」「停了」占的键：一张卡同一时间只做一件。
String perkCardBusyKey(String membershipId) => 'card/$membershipId';

/// 宽屏（≥ 840）右栏正在看的那张卡；null = 默认看列表里第一张（PerksTab 画出来后会把它写回这里）。
final selectedMembershipProvider = StateProvider<String?>((ref) => null);

/// 打开权益的领取链接（外部浏览器 / 对应 App）；测试里换成假的。
final perkUrlOpenerProvider = Provider<Future<bool> Function(Uri)>(
  (ref) =>
      (uri) => launchUrl(uri, mode: LaunchMode.externalApplication),
);

/// 会员权益的派生数，直接从一份 [LedgerData] 上取（perk_math / perk_current / perk_agenda 的薄包装）。
extension PerkLedger on LedgerData {
  /// 此刻该提醒的事；[memberId] 为 null 看全家。
  List<PerkAlert> perkAlerts(DateTime today, {String? memberId}) =>
      perkAgenda(memberships: memberships, benefits: benefits, events: benefitEvents, today: today, memberId: memberId);

  /// 「本期」视图的分组。
  CurrentPerks currentPerksOf(DateTime today, {String? memberId}) => currentPerks(
    memberships: memberships,
    benefits: benefits,
    events: benefitEvents,
    platforms: platforms,
    today: today,
    memberId: memberId,
  );

  PerkPayback paybackOf(Membership m, DateTime today) =>
      perkPayback(membership: m, benefits: benefits, events: benefitEvents, today: today);

  /// 一项顶层权益此刻的状态（N 选 1 带上它的选项：看得见的，和归档了但选过的）。
  PerkStatus statusOf(BenefitNode node, Membership m, DateTime today) => perkStatus(
    benefit: node.benefit,
    membership: m,
    options: node.options,
    archivedOptions: node.archivedOptions,
    events: benefitEvents,
    today: today,
  );
}
