import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/dates.dart';
import '../../data/models/models.dart';

/// 债务的余额都从总览（`/stats/overview`）里拿：内部账户的余额就是还剩多少。
/// 只看当月的总览：余额不分月，哪个月的总览给的都是此刻的余额。
final debtBalancesProvider = Provider<StatsOverview?>(
  (ref) => ref.watch(statsProvider(Dates.currentMonth())).valueOrNull,
);

/// 这笔债务还剩多少（正数）；总览还没取到是 null。
int? outstandingOf(Debt debt, StatsOverview? overview) => debt.outstandingOf(overview?.balanceOf(debt.accountId));

/// 还清了（总览取到了、而且剩 0）。
bool isSettled(Debt debt, StatsOverview? overview) => outstandingOf(debt, overview) == 0;

IconData debtIcon(Debt d) => switch (d.kind) {
  Debt.kindFavor => Icons.redeem_outlined,
  Debt.kindCredit => Icons.receipt_long_outlined,
  _ => d.isLend ? Icons.call_made : Icons.call_received,
};

/// 「12月31日到期」「今天到期」「逾期 3 天」；没约定日子是 null。
String? dueLabel(Debt d, DateTime now) {
  final due = parseDay(d.dueOn);
  if (due == null) return null;
  final days = due.difference(localDay(now)).inDays;
  if (days > 0) return '${due.month}月${due.day}日到期';
  if (days == 0) return '今天到期';
  return '逾期 ${-days} 天';
}

/// 按方向和类型说「收回 / 还钱 / 再借」这些动作。
String debtMoveLabel(Debt d, {required bool add}) {
  if (d.isFavor) {
    if (d.isLend) return add ? '又随了礼' : '对方回礼了';
    return add ? '又收了礼' : '还了人情';
  }
  if (d.isLend) return add ? '再借出' : '收回';
  return add ? '再借入' : '还钱';
}

/// 方向的说法：别人欠我 / 我欠别人；人情是「我送出的 / 我收下的」。
String directionLabel(String direction, {bool favor = false}) {
  if (favor) return direction == Debt.lend ? '我随出去的' : '我收下的';
  return direction == Debt.lend ? '别人欠我' : '我欠别人';
}
