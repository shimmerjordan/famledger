import 'dart:async';
import 'dart:convert';

import 'package:famledger/app/providers.dart';
import 'package:famledger/core/dates.dart';
import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/data/local/secure_store.dart';
import 'package:famledger/data/models/models.dart';
import 'package:famledger/data/repos/ledger_repo.dart';
import 'package:famledger/data/repos/session_repo.dart';
import 'package:famledger/platform/perk_notifications.dart';
import 'package:famledger/platform/perk_reminders.dart';
import 'package:famledger/ui/assets/asset_providers.dart';
import 'package:famledger/ui/perks/perk_alert_tile.dart';
import 'package:famledger/ui/perks/perk_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'perk_fake_scheduler.dart';

// 会员提醒的排程（spec §5「Android 通知」）：假调度器断言「先取消再排」、id = yyyymmdd、30 天窗口、防抖 2 秒、
// 同一份计划不重排、关掉只取消、退出登录全撤、冷启动点通知直接跳；今天那条到过点了不撤不重弹；排失败下次重来、
// 排着的时候再来一次排完再排；退出登录停下正在排的、换人登录只排新登录的人的。「现在」= 本地 2026-09-23 上午十点。

Membership card(String id, {required String expires, String period = 'year', String? memberId}) =>
    Membership(id: id, platformId: 'tb', name: id, feePeriod: period, expiresOn: expires, memberId: memberId);

/// 88VIP 10/28 到期（年付）：窗口里 9/28（T−30）、10/21（T−7）各一条。
final LedgerData vipData = LedgerData(memberships: [card('88VIP', expires: '2026-10-28')]);

/// 京东PLUS 9/24 到期（月付）：今天 9/23 是 T−1，9/25 过期次日问一次。
final LedgerData plusData = LedgerData(memberships: [card('京东PLUS', expires: '2026-09-24', period: 'month')]);

class Rig {
  Rig({LedgerData? data, List<int>? pending, String? launch, LocalStore? store, DateTime? now})
    : data = data ?? vipData,
      store = store ?? MemoryLocalStore(),
      now = now ?? DateTime(2026, 9, 23, 10),
      scheduler = FakePerkScheduler(pending: pending, launch: launch) {
    controller = PerkReminderController(
      scheduler: scheduler,
      clock: () => this.now,
      onOpen: opened.add,
      store: this.store,
      inputs: () => loaded ? PerkReminderInputs(data: this.data, prefs: prefs, memberId: 'm1', dismissed: dismissed) : null,
    );
    // start() 会挂一个 2 秒的防抖计时器；用完收掉，不让它在别的用例里响。
    addTearDown(controller.dispose);
  }

  final LocalStore store;
  final FakePerkScheduler scheduler;
  late final PerkReminderController controller;
  LedgerData data;
  PerkReminderPrefs prefs = const PerkReminderPrefs();
  Set<String> dismissed = {};
  DateTime now;
  bool loaded = true;
  final List<String> opened = [];
}

/// 可以从外面换数据的 ledger（像同步带回了新的一版）。
class FakeLedger extends LedgerController {
  FakeLedger(this.initial);

  final LedgerData initial;

  @override
  Future<LedgerData> build() async => initial;

  void put(LedgerData data) => state = AsyncData(data);
}

List<int> ids(DateTime from, int days) => [for (var i = 0; i < days; i++) perkNotificationId(DateTime(from.year, from.month, from.day + i))];

/// 让还在路上的异步（读盘、假调度器）走几步。
Future<void> flush() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// 妈妈（m1）登录着：会话在安全存储里。[http] 给登录、退出登录接口回话。
Future<({ProviderContainer container, FakePerkScheduler scheduler, FakeLedger ledger, MemoryLocalStore store})> bootProviders(
  LedgerData data, {
  http.Client? http,
}) async {
  final secure = MemorySecureStore()
    ..data[SessionRepo.baseUrlKey] = 'https://x.dev'
    ..data[SessionRepo.sessionKey] = jsonEncode({
      'baseUrl': 'https://x.dev',
      'token': 'tok',
      'deviceId': 'dev',
      'me': {'id': 'm1', 'username': 'mama', 'displayName': '妈妈', 'role': 'admin'},
    });
  final session = SessionRepo(secure: secure, httpClient: http);
  await session.restore();
  final scheduler = FakePerkScheduler();
  final ledger = FakeLedger(data);
  final store = MemoryLocalStore();
  final container = ProviderContainer(
    overrides: [
      localStoreProvider.overrideWithValue(store),
      secureStoreProvider.overrideWithValue(secure),
      sessionRepoProvider.overrideWithValue(session),
      perkNotificationSchedulerProvider.overrideWithValue(scheduler),
      assetClockProvider.overrideWithValue(() => DateTime(2026, 9, 23, 10)),
      ledgerProvider.overrideWith(() => ledger),
    ],
  );
  addTearDown(container.dispose);
  await container.read(ledgerProvider.future);
  return (container: container, scheduler: scheduler, ledger: ledger, store: store);
}

/// 假服务端：登录回爸爸（u2），退出登录回空。
http.Client authApi() => MockClient((req) async {
  final body = req.url.path == '/api/v1/auth/login'
      ? {
          'token': 'tok2',
          'deviceId': 'dev',
          'member': {'id': 'u2', 'username': 'baba', 'displayName': '爸爸', 'role': 'member'},
        }
      : const <String, dynamic>{};
  return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
});

void main() {
  test('排一次：先取消窗口里的 30 个 id 和系统里还排着的旧会员提醒，再排有摘要的那几天（09:00，点开去本期 · 我）', () async {
    final rig = Rig(pending: [20260801, 7001, 20260930]);
    await rig.controller.start();
    await rig.controller.runNow();
    final s = rig.scheduler;
    expect(s.cancels, ['cancel 20260801', for (final id in ids(DateTime(2026, 9, 24), 30)) 'cancel $id'],
        reason: '10 点已过今天的 09:00：窗口 9/24–10/23；7001 不是会员提醒，不动');
    expect(s.schedules, [
      'schedule 20260928 ${Dates.isoLocal(DateTime(2026, 9, 28, 9))} 会员权益 · 88VIP 快到期',
      'schedule 20261021 ${Dates.isoLocal(DateTime(2026, 10, 21, 9))} 会员权益 · 88VIP 快到期',
    ]);
    expect(s.calls.indexOf(s.schedules.first), greaterThan(s.calls.lastIndexOf(s.cancels.last)), reason: '先取消整段再排');
    expect(s.scheduled.map((n) => (n.body, n.payload)), [
      ('10月28日到期 · 还有 30 天', perkAgendaLocation),
      ('10月28日到期 · 还有 7 天', perkAgendaLocation),
    ]);
  });

  test('今天的钟点还没到：窗口从今天起；改了时间换新钟点；关掉只取消不排', () async {
    final rig = Rig()..now = DateTime(2026, 9, 23, 8);
    await rig.controller.start();
    await rig.controller.runNow();
    expect(rig.scheduler.cancels, [for (final id in ids(DateTime(2026, 9, 23), 30)) 'cancel $id']);

    rig.scheduler.reset();
    rig.prefs = const PerkReminderPrefs(hour: 20, minute: 30);
    await rig.controller.runNow();
    expect(rig.scheduler.scheduled.map((n) => n.at), [DateTime(2026, 9, 28, 20, 30), DateTime(2026, 10, 21, 20, 30)]);

    rig.scheduler.reset();
    rig.prefs = const PerkReminderPrefs(enabled: false, hour: 20, minute: 30);
    await rig.controller.runNow();
    expect(rig.scheduler.cancels, hasLength(30));
    expect(rig.scheduler.schedules, isEmpty);
  });

  test('算出来和上次排的一样就不动；数据变了、点了「知道了」、过了一天才重排', () async {
    final rig = Rig();
    await rig.controller.start();
    await rig.controller.runNow();
    rig.scheduler.reset();
    await rig.controller.runNow();
    expect(rig.scheduler.calls, isEmpty, reason: '同步回来的是无关的变化（比如记了一笔流水）');

    rig.data = LedgerData(memberships: [card('88VIP', expires: '2026-10-28'), card('京东PLUS', expires: '2026-09-26', period: 'month')]);
    await rig.controller.runNow();
    expect(rig.scheduler.schedules.map((c) => c.split(' ')[1]), ['20260925', '20260927', '20260928', '20261021'],
        reason: '京东PLUS：T−1（9/25）和过期次日（9/27）；T−3 是今天，09:00 已过不排');

    rig.scheduler.reset();
    rig.dismissed = {'expiry:88VIP:2026-10-28'};
    await rig.controller.runNow();
    expect(rig.scheduler.schedules.map((c) => c.split(' ')[1]), ['20260925', '20260927']);

    rig.scheduler.reset();
    rig.now = DateTime(2026, 9, 24, 10);
    await rig.controller.runNow();
    expect(rig.scheduler.cancels.last, 'cancel 20261024', reason: '窗口往后挪了一天');
  });

  test('ledger 还没加载出来不排；不支持的平台（网页、iOS）start、request、runNow 都什么也不做', () async {
    final rig = Rig()..loaded = false;
    await rig.controller.start();
    await rig.controller.runNow();
    expect(rig.scheduler.calls, isEmpty);

    final web = Rig()..scheduler.supported = false;
    await web.controller.start();
    web.controller.request();
    await web.controller.runNow();
    expect(web.scheduler.calls, isEmpty);
  });

  test('冷启动是点通知进来的：start 时先跳过去；之后点通知走同一个回调', () async {
    final rig = Rig(launch: perkAgendaLocation);
    await rig.controller.start();
    expect(rig.opened, [perkAgendaLocation]);
    rig.scheduler.tap!(perkAgendaLocation);
    expect(rig.opened, [perkAgendaLocation, perkAgendaLocation]);
    await rig.controller.start();
    expect(rig.scheduler.inits, 1, reason: '外壳重挂（退出再登录）不再初始化一次');
  });

  test('退出登录：撤掉系统里排着的会员提醒和今天起 31 天的 id；撤过一遍不再撤；下次排不当成「和上次一样」', () async {
    final rig = Rig(pending: [20261021, 7001]);
    await rig.controller.start();
    await rig.controller.runNow();
    rig.scheduler.reset();
    rig.scheduler.pending.add(20261130); // 窗口外、系统里还排着的（比如别的进程排的）也撤
    await rig.controller.clear();
    expect(rig.scheduler.cancels.toSet(), {for (final id in ids(DateTime(2026, 9, 23), 31)) 'cancel $id', 'cancel 20261130'});
    expect(rig.scheduler.pending, [7001], reason: '自动记账的不动');
    expect(rig.scheduler.schedules, isEmpty);
    rig.scheduler.reset();
    await rig.controller.clear();
    expect(rig.scheduler.calls, isEmpty, reason: '退出登录时先撤过了，会话变空时不再撤第二遍');
    await rig.controller.runNow();
    expect(rig.scheduler.schedules, hasLength(2), reason: '重新登录后照样排回来');
  });

  test('没 start 也能撤（没登录时冷启动）：插件查、撤不用初始化', () async {
    final scheduler = FakePerkScheduler(pending: [20260801, 20261021, 7001]);
    expect(await clearPerkNotifications(scheduler, DateTime(2026, 9, 23, 10)), isTrue);
    expect(scheduler.inits, 0);
    expect(scheduler.pending, [7001]);
    expect(scheduler.cancels, contains('cancel 20260923'), reason: '今天弹出来的那条也从通知栏撤掉');
    expect(await clearPerkNotifications(const UnsupportedPerkNotificationScheduler(), DateTime(2026, 9, 23)), isTrue);
  });

  test('今天那条弹过了、10 点把时间改到 21:00：不重弹、通知栏里那条不撤，窗口从明天起', () async {
    final rig = Rig(data: plusData, now: DateTime(2026, 9, 23, 8));
    await rig.controller.start();
    await rig.controller.runNow();
    expect(rig.scheduler.schedules.first, startsWith('schedule 20260923 ${Dates.isoLocal(DateTime(2026, 9, 23, 9))}'));

    rig.scheduler.deliver(20260923);
    rig.scheduler.reset();
    rig.now = DateTime(2026, 9, 23, 10);
    rig.prefs = const PerkReminderPrefs(hour: 21, minute: 0);
    expect(rig.controller.todaySpent, isTrue);
    await rig.controller.runNow();
    expect(rig.scheduler.calls, isNot(contains('cancel 20260923')), reason: '撤掉的话通知栏里那条也没了');
    expect(rig.scheduler.schedules.where((c) => c.contains(' 20260923 ')), isEmpty, reason: '每天最多一条');
    expect(rig.scheduler.scheduled.map((n) => n.at), [DateTime(2026, 9, 25, 21)]);
    expect(rig.scheduler.cancels.first, 'cancel 20260924');
    expect(rig.scheduler.shown, {20260923});
  });

  test('非精确闹钟晚了：9:05 今天那条还排着没弹，这时重排不撤它（撤了又不补，这一天就没了）；更早的照旧清掉', () async {
    final rig = Rig(data: plusData, now: DateTime(2026, 9, 23, 8), pending: [20260920]);
    await rig.controller.start();
    await rig.controller.runNow();
    rig.scheduler.reset();
    rig.now = DateTime(2026, 9, 23, 9, 5);
    await rig.controller.runNow();
    expect(rig.scheduler.calls, isNot(contains('cancel 20260923')));
    expect(rig.scheduler.pending, contains(20260923), reason: '系统一放行就弹');
    expect(rig.scheduler.pending, isNot(contains(20260920)), reason: '早于今天、一直没弹的清掉');
    expect(rig.scheduler.schedules.map((c) => c.split(' ')[1]), ['20260925']);
  });

  test('进程重启后也认得今天那条到过点了：排过的时刻记在本机', () async {
    final store = MemoryLocalStore();
    final before = Rig(data: plusData, now: DateTime(2026, 9, 23, 8), store: store);
    await before.controller.start();
    await before.controller.runNow();
    expect(await store.read<Map<String, dynamic>>(PerkReminderController.logKey), {
      '20260923': DateTime(2026, 9, 23, 9).millisecondsSinceEpoch,
      '20260925': DateTime(2026, 9, 25, 9).millisecondsSinceEpoch,
    });

    // 9 点弹过；10 点重新打开家账（新进程、新的控制器），把时间改到 21:00。
    final after = Rig(data: plusData, now: DateTime(2026, 9, 23, 10), store: store, pending: [20260925]);
    after.scheduler.shown.add(20260923);
    after.prefs = const PerkReminderPrefs(hour: 21, minute: 0);
    await after.controller.start();
    await after.controller.runNow();
    expect(after.scheduler.calls.where((c) => c.contains(' 20260923')), isEmpty);
    expect(after.scheduler.scheduled.map((n) => n.at), [DateTime(2026, 9, 25, 21)]);
  });

  test('今天那条还没到点：改早、改晚都照常撤掉按新钟点重排', () async {
    final rig = Rig(data: plusData, now: DateTime(2026, 9, 23, 8));
    await rig.controller.start();
    await rig.controller.runNow();
    rig.scheduler.reset();
    rig.now = DateTime(2026, 9, 23, 8, 10);
    rig.prefs = const PerkReminderPrefs(hour: 8, minute: 30);
    await rig.controller.runNow();
    expect(rig.scheduler.cancels.first, 'cancel 20260923');
    expect(rig.scheduler.scheduled.first.at, DateTime(2026, 9, 23, 8, 30));

    rig.scheduler.reset();
    rig.now = DateTime(2026, 9, 23, 8, 20);
    rig.prefs = const PerkReminderPrefs(hour: 21, minute: 0);
    await rig.controller.runNow();
    expect(rig.scheduler.scheduled.first.at, DateTime(2026, 9, 23, 21), reason: '8:30 那条还没到点，今天没发过');
  });

  test('排失败（系统拒了、插件出错）：不记成已排，下次 runNow 从头再排一遍', () async {
    final rig = Rig();
    await rig.controller.start();
    rig.scheduler.failNextSchedule = true;
    await rig.controller.runNow();
    expect(rig.scheduler.schedules, isEmpty);
    rig.scheduler.reset();
    await rig.controller.runNow();
    expect(rig.scheduler.cancels, hasLength(30), reason: '先取消整段再排，不当成「和上次一样」');
    expect(rig.scheduler.schedules, hasLength(2));
  });

  test('正在排的时候又来一次：不并发，排完再按最新的数据排一次', () async {
    final rig = Rig();
    await rig.controller.start();
    rig.scheduler.gate = Completer<void>();
    final first = rig.controller.runNow();
    await flush();
    rig.data = LedgerData(memberships: [card('88VIP', expires: '2026-10-28'), card('京东PLUS', expires: '2026-09-26', period: 'month')]);
    final second = rig.controller.runNow();
    await flush();
    expect(rig.scheduler.calls, isEmpty, reason: '第一次还卡在查系统里排着的');
    rig.scheduler.gate!.complete();
    await Future.wait([first, second]);
    final calls = rig.scheduler.calls;
    expect(calls, hasLength(30 + 2 + 30 + 4));
    expect(calls.sublist(30, 32).map((c) => c.split(' ')[1]), ['20260928', '20261021'], reason: '第一次按旧数据排完');
    expect(calls.sublist(32, 62).every((c) => c.startsWith('cancel ')), isTrue, reason: '第二次在第一次排完之后才开始');
    expect(calls.sublist(62).map((c) => c.split(' ')[1]), ['20260925', '20260927', '20260928', '20261021']);
  });

  test('排到一半退出登录：正在排的那次停下，不把上一家的提醒排回去', () async {
    final rig = Rig();
    await rig.controller.start();
    rig.scheduler.gate = Completer<void>();
    final run = rig.controller.runNow();
    await flush();
    final cleared = rig.controller.clear();
    rig.scheduler.gate!.complete();
    await Future.wait([run, cleared]);
    expect(rig.scheduler.schedules, isEmpty);
    expect(rig.scheduler.pending, isEmpty);
  });

  test('计划签名按 UTC 那一刻比：进程活着时换了时区，本地「09:00」字面没变也要重排', () {
    final at = DateTime(2026, 9, 24, 9);
    final plan = PerkReminderPlan(
      windowIds: const [20260924],
      notifications: [PerkNotification(id: 20260924, at: at, title: 't', body: 'b', payload: '/')],
    );
    expect(plan.signature, contains('20260924@${at.toUtc().toIso8601String()}|'));
    // 带上分隔符比：机器时区是 UTC 时，本地串恰好是 UTC 串去掉末尾的 Z，光比子串会误报。
    expect(plan.signature, isNot(contains('20260924@${at.toIso8601String()}|')));
  });

  testWidgets('防抖 2 秒：连着来几次只排一次；卸掉外壳时收起没到点的', (tester) async {
    final rig = Rig();
    await rig.controller.start();
    for (var i = 0; i < 3; i++) {
      rig.controller.request();
      await tester.pump(const Duration(milliseconds: 500));
    }
    await tester.pump(const Duration(milliseconds: 1499));
    expect(rig.scheduler.calls, isEmpty, reason: '最后一次请求之后还没满 2 秒');
    await tester.pump(const Duration(milliseconds: 1));
    expect(rig.scheduler.schedules, hasLength(2));
    expect(rig.scheduler.cancels, hasLength(30), reason: '只排了一次');

    rig.scheduler.reset();
    rig.data = LedgerData(memberships: [card('京东PLUS', expires: '2026-09-26', period: 'month')]);
    rig.controller.request();
    rig.controller.cancelPending();
    await tester.pump(const Duration(seconds: 3));
    expect(rig.scheduler.calls, isEmpty);
  });

  test('PerkReminderPrefs：坏值按默认（09:00、开着）', () {
    expect(PerkReminderPrefs.fromJson(const {}).toJson(), {'enabled': true, 'hour': 9, 'minute': 0});
    expect(PerkReminderPrefs.fromJson(const {'enabled': false, 'hour': 20, 'minute': 30}).timeLabel, '20:30');
    expect(PerkReminderPrefs.fromJson(const {'enabled': 'no', 'hour': 24, 'minute': -1}).toJson(), {'enabled': true, 'hour': 9, 'minute': 0});
  });

  testWidgets('provider 接线：同步带回相关变化、改了本机设置、点了「知道了」都会（防抖后）重排；退出登录全撤', (tester) async {
    final boot = await bootProviders(vipData, http: authApi());
    final (container: container, scheduler: scheduler, ledger: ledger, store: _) = boot;
    await container.read(perkReminderControllerProvider).start();
    await tester.pump(const Duration(seconds: 2));
    expect(scheduler.schedules, hasLength(2));

    scheduler.reset();
    ledger.put(LedgerData(memberships: [card('88VIP', expires: '2026-10-28'), card('爸爸的', expires: '2026-09-24', memberId: 'u2')]));
    await tester.pump(const Duration(seconds: 2));
    expect(scheduler.calls, isEmpty, reason: '别人的卡：通知只看我的和全家共用的，计划没变');
    ledger.put(LedgerData(memberships: [card('88VIP', expires: '2026-10-28'), card('全家的', expires: '2026-09-25')]));
    await tester.pump(const Duration(seconds: 2));
    expect(scheduler.schedules.map((c) => c.split(' ')[1]), ['20260924', '20260926', '20260928', '20261021']);

    scheduler.reset();
    await container.read(perkReminderPrefsProvider.notifier).set(const PerkReminderPrefs(hour: 21, minute: 0));
    await tester.pump(const Duration(seconds: 2));
    expect(scheduler.cancels.first, 'cancel 20260923', reason: '今天 21:00 还没到，窗口从今天起');
    expect(scheduler.scheduled.first.at, DateTime(2026, 9, 24, 21));

    scheduler.reset();
    await container.read(perkDismissedProvider.notifier).dismiss('expiry:88VIP:2026-10-28', DateTime(2026, 9, 23, 10));
    await tester.pump(const Duration(seconds: 2));
    expect(scheduler.scheduled.map((n) => n.title), isNot(contains('会员权益 · 88VIP 快到期')));
    expect(scheduler.scheduled, isNotEmpty);

    scheduler.reset();
    await container.read(sessionProvider.notifier).logout();
    // 退出登录让依赖会话的 provider 重建（Riverpod 用 0 秒计时器排）：推一下让它跑完。
    await tester.pump(const Duration(milliseconds: 10));
    expect(scheduler.cancels, hasLength(31), reason: '退出时撤一遍；会话变空时不再撤第二遍');
    expect(scheduler.schedules, isEmpty);
    expect(scheduler.pending, isEmpty);

    // 没登录：数据、设置再变也不排（上一家的数据还在 ledger 里，「我」已经空了）。
    scheduler.reset();
    ledger.put(LedgerData(memberships: [card('全家的', expires: '2026-09-24')]));
    container.read(perkReminderControllerProvider).request();
    await container.read(perkReminderControllerProvider).runNow();
    await tester.pump(const Duration(seconds: 3));
    expect(scheduler.calls, isEmpty);
  });

  testWidgets('退出后换爸爸登录：只排爸爸的卡和全家共用的，没有妈妈的卡名；提醒设置回到默认（内存和本机一致）', (tester) async {
    final data = LedgerData(
      memberships: [
        card('妈妈的', expires: '2026-10-24', memberId: 'm1'),
        card('爸爸的', expires: '2026-10-24', memberId: 'u2'),
        card('全家的', expires: '2026-10-24'),
      ],
    );
    final (container: container, scheduler: scheduler, ledger: _, store: store) = await bootProviders(data, http: authApi());
    await container.read(perkReminderControllerProvider).start();
    await container.read(perkReminderPrefsProvider.notifier).set(const PerkReminderPrefs(hour: 21, minute: 30));
    await tester.pump(const Duration(seconds: 2));
    expect(scheduler.scheduled.map((n) => n.body).toSet(), {'全家的 快到期\n妈妈的 快到期'}, reason: '妈妈登录：她的和全家的');
    expect(scheduler.scheduled.every((n) => n.at.hour == 21), isTrue);

    await container.read(sessionProvider.notifier).logout();
    await tester.pump(const Duration(milliseconds: 10));
    expect(container.read(perkReminderPrefsProvider).timeLabel, '09:00', reason: '本机缓存清空了，内存里也回到默认');
    expect(await store.read<Map<String, dynamic>>(PerkReminderPrefsController.storeKey), isNull);

    scheduler.reset();
    await container.read(sessionProvider.notifier).login('baba', 'hunter22');
    await tester.pump(const Duration(seconds: 2));
    expect(scheduler.scheduled.map((n) => n.body).toSet(), {'全家的 快到期\n爸爸的 快到期'}, reason: '只有爸爸的和全家的，没有妈妈的卡名');
    expect(scheduler.scheduled.every((n) => n.at.hour == 9 && n.at.minute == 0), isTrue, reason: '设置回到默认 09:00');
  });
}
