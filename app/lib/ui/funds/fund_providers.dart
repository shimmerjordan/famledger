import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/dates.dart';
import '../../data/models/models.dart';

/// 基金详情的「本月构成 + 余额 + 最近流水」。
final fundStatsProvider = FutureProvider.autoDispose.family<FundStats, String>(
  (ref, id) =>
      ref.watch(statsRepoProvider).fund(id, month: Dates.currentMonth()),
);

/// 基金详情的近 6 个月趋势。
final fundTrendProvider = FutureProvider.autoDispose
    .family<TrendSeries, String>(
      (ref, id) => ref.watch(statsRepoProvider).trend(months: 6, fundId: id),
    );

/// `GET /funds/templates`：新建基金时的起点。
final fundTemplatesProvider = FutureProvider.autoDispose<List<Fund>>(
  (ref) => ref.watch(ledgerRepoProvider).fundTemplates(),
);

/// 模板弹层挑好之后要交给表单页，但路由是 Task 8 定死的（`/funds/new`
/// 不带参数），所以借一个一次性的「传球」provider，表单页取完就清空。
final pendingFundTemplateProvider = StateProvider<Fund?>((ref) => null);
