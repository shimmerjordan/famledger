import 'package:famledger/core/dates.dart';
import 'package:famledger/data/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

// Android 每日摘要（spec §5）：未来 30 天每天调一次 perkAgenda，挑 remindToday 的拼成一条；成员过滤、「知道了」、
// 多项合并；通知 id = yyyymmdd；提醒时刻从「下一个还没到的钟点」起排 30 个。固定「今天」= 2026-09-23。

DateTime d(String s) => parseDay(s)!;
final DateTime today = d('2026-09-23');

Membership card(String id, {required String expires, String period = 'year', String? memberId}) =>
    Membership(id: id, platformId: 'tb', name: id, feePeriod: period, expiresOn: expires, memberId: memberId);

List<PerkDigest> digests(List<Membership> ms, {String? memberId, Set<String> dismissed = const {}}) =>
    reminderDigests(memberships: ms, benefits: const [], events: const [], firstDay: today, memberId: memberId, dismissed: dismissed);

void main() {
  test('30 天窗口：只在提醒日出现（年付 T−30、T−7；T−1 落在窗口外就不排）', () {
    final out = digests([card('88VIP', expires: '2026-10-28')]);
    expect(out.map((x) => Dates.isoDate(x.day)), ['2026-09-28', '2026-10-21']);
    expect((out.first.title, out.first.body), ('会员权益 · 88VIP 快到期', '10月28日到期 · 还有 30 天'), reason: '通知栏里只剩「家账」，标题说清楚是会员权益');
    expect(out.last.body, '10月28日到期 · 还有 7 天');
    expect(out.first.keys, ['expiry:88VIP:2026-10-28']);
  });

  test('同一天几项合成一条：标题写件数，正文一行一项（和页面一个顺序）；只剩一项的那天用它自己的话（带「会员权益 · 」）；过期次日问一次', () {
    final out = digests([card('腾讯视频', expires: '2026-09-26', period: 'month'), card('京东PLUS', expires: '2026-09-24')]);
    expect(out.map((x) => Dates.isoDate(x.day)), ['2026-09-23', '2026-09-25', '2026-09-27']);
    expect(out[0].title, '会员权益 · 2 件事');
    expect(out[0].body, '京东PLUS 快到期\n腾讯视频 快到期');
    expect(out[0].keys, ['expiry:京东PLUS:2026-09-24', 'expiry:腾讯视频:2026-09-26']);
    expect(out[1].body, '京东PLUS 已过期 1 天\n腾讯视频 快到期', reason: '过期后待确认排最前');
    expect((out[2].title, out[2].body), ('会员权益 · 腾讯视频 已过期 1 天', '9月26日到期 · 续了还是停了？'));
  });

  test('默认提前天数能被 remind_days 覆盖；本期没领完合并成一句（摘要里只占一行）', () {
    const m = Membership(id: 'vip', platformId: 'tb', name: '88VIP', expiresOn: '2026-10-28', remindDays: 15);
    const benefits = [
      Benefit(id: 'b1', membershipId: 'vip', name: '红包', quota: [PerkQuota('month', 4)]),
      Benefit(id: 'b2', membershipId: 'vip', name: '运费券', quota: [PerkQuota('month', 2)]),
    ];
    final out = reminderDigests(memberships: const [m], benefits: benefits, events: const [], firstDay: today);
    expect(out.map((x) => Dates.isoDate(x.day)), ['2026-09-27', '2026-10-13', '2026-10-21'], reason: '9/27 是月末前 3 天；T−15、T−7');
    expect((out.first.title, out.first.body), ('会员权益 · 本月还有 2 项没领', '9月30日前 · 红包、运费券'), reason: '单看「本月还有 2 项没领」像记账提醒');
    expect(out[1].body, '10月28日到期 · 还有 15 天');
  });

  test('正文最多 4 行：多于 4 项列前 3 项，第 4 行写「还有 N 项」；不多于 4 项全列', () {
    List<String> lines(int n) => digests([for (var i = 1; i <= n; i++) card('卡$i', expires: '2026-09-24')]).first.body.split('\n');
    final six = digests([for (var i = 1; i <= 6; i++) card('卡$i', expires: '2026-09-24')]).first;
    expect(six.title, '会员权益 · 6 件事');
    expect(six.body.split('\n'), ['卡1 快到期', '卡2 快到期', '卡3 快到期', '还有 3 项']);
    expect(lines(5), ['卡1 快到期', '卡2 快到期', '卡3 快到期', '还有 2 项']);
    expect(lines(4), ['卡1 快到期', '卡2 快到期', '卡3 快到期', '卡4 快到期'], reason: '正好 4 项不用「还有 1 项」');
    expect(lines(2), ['卡1 快到期', '卡2 快到期']);
  });

  test('成员过滤：只看我的和全家共用的；点过「知道了」的通知里也不提', () {
    // 10/24 到期的年卡：窗口（9/23–10/22）里是 T−30（9/24）和 T−7（10/17）两天。
    final ms = [
      card('妈妈的', expires: '2026-10-24', memberId: 'm1'),
      card('爸爸的', expires: '2026-10-24', memberId: 'u2'),
      card('全家的', expires: '2026-10-24'),
    ];
    final mine = digests(ms, memberId: 'm1');
    expect(mine.map((x) => Dates.isoDate(x.day)), ['2026-09-24', '2026-10-17']);
    expect(mine.first.keys, ['expiry:全家的:2026-10-24', 'expiry:妈妈的:2026-10-24']);
    expect(digests(ms).first.keys, hasLength(3), reason: '不给 memberId 看全家');
    final left = digests(ms, memberId: 'm1', dismissed: {'expiry:全家的:2026-10-24'});
    expect(left.map((x) => x.title), ['会员权益 · 妈妈的 快到期', '会员权益 · 妈妈的 快到期'], reason: '「知道了」的键带着目标日，这张卡这一期的几次提醒都不再发');
    expect(digests(ms, memberId: 'm1', dismissed: {'expiry:全家的:2026-10-24', 'expiry:妈妈的:2026-10-24'}), isEmpty);
  });

  test('通知 id = yyyymmdd；只认这个形状的 id', () {
    expect(perkNotificationId(d('2026-09-24')), 20260924);
    expect(perkNotificationId(DateTime(2027, 1, 5, 9)), 20270105);
    expect(isPerkNotificationId(20260924), isTrue);
    expect(isPerkNotificationId(7001), isFalse, reason: '自动记账的测试通知');
    expect(isPerkNotificationId(20261301), isFalse);
    expect(isPerkNotificationId(20260900), isFalse);
  });

  test('提醒时刻：今天的钟点还没到从今天起，到了、过了从明天起；一共 30 个、每天同一个钟点', () {
    final before = perkReminderSlots(DateTime(2026, 9, 23, 8, 59), hour: 9, minute: 0);
    expect(before.first, DateTime(2026, 9, 23, 9));
    expect(before, hasLength(30));
    expect(before.last, DateTime(2026, 10, 22, 9));
    expect(perkReminderSlots(DateTime(2026, 9, 23, 9), hour: 9, minute: 0).first, DateTime(2026, 9, 24, 9));
    final after = perkReminderSlots(DateTime(2026, 9, 23, 10), hour: 20, minute: 30);
    expect(after.first, DateTime(2026, 9, 23, 20, 30));
    expect(after.map((s) => (s.hour, s.minute)).toSet(), {(20, 30)});
    final skipped = perkReminderSlots(DateTime(2026, 9, 23, 10), hour: 20, minute: 30, skipToday: true);
    expect((skipped.first, skipped.length), (DateTime(2026, 9, 24, 20, 30), 30), reason: '今天那条已经到过点：改晚了钟点也从明天起');
  });
}
