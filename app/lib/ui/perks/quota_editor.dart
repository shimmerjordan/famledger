import 'package:flutter/widgets.dart';

import '../../data/models/models.dart';

/// 额度预设（spec §5）：每月 N 次、每年 N 次、会籍期内 1 次、一次性、不限次；
/// 第一条上限不属于这五种时是「自定义」（比如以前存的「每周 2 次」）。
enum QuotaPreset { monthly, yearly, termOnce, once, unlimited, custom }

/// 额度里的一条上限：周期 + 次数输入框。
class QuotaRow {
  QuotaRow(this.period, String count) : count = TextEditingController(text: count);

  String period;
  final TextEditingController count;
}

/// 权益表单里「额度」这一段的状态：第一条由预设 chip 决定，「高级」里可以再叠加上限
/// （「另外每 [年] 最多 [6] 次」），合计最多 3 条、周期不重复。表单页持有它，活到页面销毁。
class QuotaEditor extends ChangeNotifier {
  QuotaEditor([List<PerkQuota> initial = const []]) {
    for (final q in initial.take(maxRows)) {
      rows.add(QuotaRow(q.p, '${q.n}'));
    }
  }

  static const int maxRows = 3;

  /// 「另外每 … 最多 … 次」下拉里的周期，按常用程度排。
  static const List<String> extraPeriods = ['year', 'month', 'week', 'quarter', 'day', 'term', 'total'];

  final List<QuotaRow> rows = [];

  QuotaPreset get preset {
    if (rows.isEmpty) return QuotaPreset.unlimited;
    final first = rows.first;
    final n = int.tryParse(first.count.text.trim());
    return switch (first.period) {
      'month' => QuotaPreset.monthly,
      'year' => QuotaPreset.yearly,
      'term' when n == 1 => QuotaPreset.termOnce,
      'total' when n == 1 => QuotaPreset.once,
      _ => QuotaPreset.custom,
    };
  }

  /// 「高级」里列出的行：预设管着第一条时从第二条起；自定义时全部。
  int get extraStart => preset == QuotaPreset.custom ? 0 : 1;

  bool get canAddExtra => rows.isNotEmpty && rows.length < maxRows;

  /// 点预设：改第一条（每月 / 每年保留原来填的次数），不动叠加的那几条；「不限次」清空全部。
  void applyPreset(QuotaPreset p) {
    if (p == QuotaPreset.custom) return;
    if (p == QuotaPreset.unlimited) {
      for (final r in rows) {
        r.count.dispose();
      }
      rows.clear();
      notifyListeners();
      return;
    }
    final period = switch (p) {
      QuotaPreset.monthly => 'month',
      QuotaPreset.yearly => 'year',
      QuotaPreset.termOnce => 'term',
      _ => 'total',
    };
    final keepCount = (p == QuotaPreset.monthly || p == QuotaPreset.yearly) && rows.isNotEmpty ? rows.first.count.text : '1';
    // 叠加的那几条里如果已经有这个周期，先拿掉，免得和第一条重复。
    for (var i = rows.length - 1; i >= 1; i--) {
      if (rows[i].period == period) rows.removeAt(i).count.dispose();
    }
    if (rows.isEmpty) {
      rows.add(QuotaRow(period, keepCount));
    } else {
      rows.first
        ..period = period
        ..count.text = keepCount;
    }
    notifyListeners();
  }

  /// 加一条叠加上限：周期取第一个还没用过的。
  void addExtra() {
    if (!canAddExtra) return;
    final used = {for (final r in rows) r.period};
    final period = extraPeriods.firstWhere((p) => !used.contains(p), orElse: () => 'year');
    rows.add(QuotaRow(period, ''));
    notifyListeners();
  }

  void removeAt(int index) {
    rows.removeAt(index).count.dispose();
    notifyListeners();
  }

  void setPeriod(int index, String period) {
    rows[index].period = period;
    notifyListeners();
  }

  void touched() => notifyListeners();

  /// 表单值 → 额度列表；填错给一句话。
  QuotaRead read() {
    final out = <PerkQuota>[];
    final seen = <String>{};
    for (final r in rows) {
      final n = int.tryParse(r.count.text.trim());
      if (n == null || n < 1 || n > 9999) return const QuotaRead.fail('次数填 1 到 9999 的整数');
      if (!seen.add(r.period)) return const QuotaRead.fail('同一个周期只能写一条上限');
      out.add(PerkQuota(r.period, n));
    }
    return QuotaRead.ok(out);
  }

  @override
  void dispose() {
    for (final r in rows) {
      r.count.dispose();
    }
    super.dispose();
  }
}

/// [QuotaEditor.read] 的结果：要么一份额度，要么一句错误。
class QuotaRead {
  const QuotaRead.ok(List<PerkQuota> this.quota) : error = null;
  const QuotaRead.fail(String this.error) : quota = null;

  final List<PerkQuota>? quota;
  final String? error;
}
