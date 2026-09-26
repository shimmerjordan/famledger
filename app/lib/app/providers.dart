import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api/api_client.dart';
import '../data/local/local_store.dart';
import '../data/local/outbox.dart';
import '../data/local/secure_store.dart';
import '../data/models/models.dart';
import '../data/repos/ledger_repo.dart';
import '../data/repos/session_repo.dart';
import '../data/repos/settings_repo.dart';
import '../data/repos/stats_repo.dart';
import '../data/repos/transactions_repo.dart';
import '../platform/perk_notifications.dart';

// —— 启动时在 main() 里 override 的三个「外设」 ——

final localStoreProvider = Provider<LocalStore>(
  (ref) => throw UnimplementedError('localStoreProvider 必须在 main() 里 override'),
);

final secureStoreProvider = Provider<SecureStore>(
  (ref) => throw UnimplementedError('secureStoreProvider 必须在 main() 里 override'),
);

/// 会话仓库在 main() 里就建好并 `restore()` 过，路由跳转才能是同步的。
final sessionRepoProvider = Provider<SessionRepo>(
  (ref) => throw UnimplementedError('sessionRepoProvider 必须在 main() 里 override'),
);

/// 退出登录时、删会话之前要先做完的事：撤掉排着的会员提醒（platform/perk_reminders.dart 登记）。
/// 单独一个 provider，是因为登记的一方自己也听会话，不能反过来让会话去读它（Riverpod 不许循环依赖）。
class LogoutHooks {
  final List<Future<void> Function()> _hooks = [];

  void add(Future<void> Function() hook) => _hooks.add(hook);

  void remove(Future<void> Function() hook) => _hooks.remove(hook);

  /// 挨个做完；哪个出错都不拦着退出登录。
  Future<void> run() async {
    for (final hook in [..._hooks]) {
      try {
        await hook();
      } catch (_) {
        // 退出登录一定要退得出去。
      }
    }
  }
}

final logoutHooksProvider = Provider<LogoutHooks>((ref) => LogoutHooks());

/// 本机缓存被清空的次数（退出登录会清）。读本机设置的 provider watch 它：清空之后跟着重新读盘，
/// 内存里不留上一个人的设置（会员提醒的时间、「知道了」）。
final localStoreEpochProvider = StateProvider<int>((ref) => 0);

/// 当前会话；null = 没登录。
final sessionProvider = NotifierProvider<SessionController, Session?>(
  SessionController.new,
);

class SessionController extends Notifier<Session?> {
  @override
  Session? build() {
    final current = ref.read(sessionRepoProvider).current;
    // 没登录就启动了（停在登录页）：把系统里排着的会员提醒撤干净 —— 上次退出登录时进程可能在撤到一半时被杀了，
    // 上一家的卡名不该再弹 30 天。登录着的由外壳里的排程接手（platform/perk_reminders.dart）。
    if (current == null) unawaited(clearPerkNotifications(ref.read(perkNotificationSchedulerProvider), DateTime.now()));
    return current;
  }

  SessionRepo get _repo => ref.read(sessionRepoProvider);

  bool get needsSetup => _repo.needsSetup;
  String? get storedBaseUrl => _repo.storedBaseUrl;
  String? get householdName => _repo.householdName;

  Future<void> connect(String baseUrl) => _repo.connect(baseUrl);

  Future<void> setup({
    required String householdName,
    required String username,
    required String password,
    required String displayName,
    String? setupToken,
  }) async {
    state = await _repo.setup(
      householdName: householdName,
      username: username,
      password: password,
      displayName: displayName,
      setupToken: setupToken,
    );
  }

  Future<void> login(String username, String password) async {
    state = await _repo.login(username, password);
  }

  /// 退出登录顺手清掉本地缓存，换个人登录不会看到上一家的数据。
  ///
  /// 先撤掉排着的会员提醒再删会话：撤到一半进程被杀的话，下次打开还登录着，外壳会接着排（或再退一次）；
  /// 反过来先删了会话，那些提醒就没人管了。
  Future<void> logout() async {
    await ref.read(logoutHooksProvider).run();
    await _repo.logout();
    await ref.read(localStoreProvider).clear();
    state = null;
    ref.read(localStoreEpochProvider.notifier).state++;
  }

  Future<void> changePassword({
    required String oldPassword,
    required String newPassword,
  }) => _repo.changePassword(oldPassword: oldPassword, newPassword: newPassword);

  Future<void> refreshMe() async {
    await _repo.refreshMe();
    state = _repo.current;
  }
}

/// 带着当前会话令牌的 API 客户端；换账号会自动重建。
final apiProvider = Provider<ApiClient>((ref) {
  final session = ref.watch(sessionProvider);
  final baseUrl = session?.baseUrl ?? ref.read(sessionRepoProvider).storedBaseUrl ?? '';
  final client = ApiClient(baseUrl: baseUrl, token: session?.token);
  ref.onDispose(client.close);
  return client;
});

final outboxProvider = Provider<Outbox>(
  (ref) => Outbox(ref.watch(localStoreProvider)),
);

final ledgerRepoProvider = Provider<LedgerRepo>((ref) {
  final repo = LedgerRepo(
    api: ref.watch(apiProvider),
    store: ref.watch(localStoreProvider),
  );
  ref.onDispose(repo.dispose);
  return repo;
});

/// 主数据（成员/账户/基金/类别/规则/预算）。先给本地缓存，再后台增量同步。
final ledgerProvider = AsyncNotifierProvider<LedgerController, LedgerData>(
  LedgerController.new,
);

class LedgerController extends AsyncNotifier<LedgerData> {
  @override
  Future<LedgerData> build() async {
    final repo = ref.watch(ledgerRepoProvider);
    final sub = repo.changes.listen((_) => state = AsyncData(repo.snapshot));
    ref.onDispose(sub.cancel);
    await repo.load();
    unawaited(_syncQuietly(repo));
    return repo.snapshot;
  }

  LedgerRepo get repo => ref.read(ledgerRepoProvider);

  /// 下拉刷新：失败要让用户看见。
  Future<void> sync({bool full = false}) async {
    await repo.sync(full: full);
    state = AsyncData(repo.snapshot);
  }

  Future<void> _syncQuietly(LedgerRepo repo) async {
    try {
      await repo.sync();
    } catch (_) {
      // 首屏用缓存也能看，同步失败等下拉刷新时再报。
    }
  }
}

final transactionsRepoProvider = Provider<TransactionsRepo>(
  (ref) => TransactionsRepo(
    api: ref.watch(apiProvider),
    outbox: ref.watch(outboxProvider),
    store: ref.watch(localStoreProvider),
  ),
);

final statsRepoProvider = Provider<StatsRepo>(
  (ref) => StatsRepo(ref.watch(apiProvider)),
);

/// 某个月（`YYYY-MM`）的统计总览。
final statsProvider =
    AsyncNotifierProvider.family<StatsController, StatsOverview, String>(
      StatsController.new,
    );

class StatsController extends FamilyAsyncNotifier<StatsOverview, String> {
  @override
  Future<StatsOverview> build(String month) =>
      ref.watch(statsRepoProvider).overview(month);

  Future<void> refresh() async {
    state = const AsyncLoading<StatsOverview>().copyWithPrevious(state);
    state = await AsyncValue.guard(
      () => ref.read(statsRepoProvider).overview(arg),
    );
  }
}

final settingsRepoProvider = Provider<SettingsRepo>(
  (ref) => SettingsRepo(
    api: ref.watch(apiProvider),
    store: ref.watch(localStoreProvider),
  ),
);

/// 家庭级设置。
final settingsProvider = AsyncNotifierProvider<SettingsController, Settings>(
  SettingsController.new,
);

class SettingsController extends AsyncNotifier<Settings> {
  @override
  Future<Settings> build() => ref.watch(settingsRepoProvider).fetch();

  Future<void> patch(Map<String, dynamic> body) async {
    final updated = await ref.read(settingsRepoProvider).patch(body);
    state = AsyncData(updated);
  }
}
