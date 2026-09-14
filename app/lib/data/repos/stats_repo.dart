import '../api/api_client.dart';
import '../models/models.dart';

/// 统计只读，不做本地缓存（每次进页面拉一次，失败有重试按钮）。
class StatsRepo {
  const StatsRepo(this._api);

  final ApiClient _api;

  Future<StatsOverview> overview(String month) async =>
      StatsOverview.fromJson(await _api.get('/stats/overview', query: {'month': month}));

  /// [endMonth]（`YYYY-MM`，含）往前数 [months] 个月；不传就是截至当月。
  Future<TrendSeries> trend({
    int months = 12,
    String? endMonth,
    String? fundId,
    String? categoryId,
  }) async {
    final query = {'months': '$months'};
    if (endMonth != null) query['endMonth'] = endMonth;
    if (fundId != null) query['fundId'] = fundId;
    if (categoryId != null) query['categoryId'] = categoryId;
    return TrendSeries.fromJson(await _api.get('/stats/trend', query: query));
  }

  Future<FundStats> fund(String id, {String? month}) async => FundStats.fromJson(
    await _api.get('/stats/fund/$id', query: month == null ? null : {'month': month}),
  );

  Future<List<CalendarDay>> calendar(String month) async {
    final res = await _api.get('/stats/calendar', query: {'month': month});
    return jsonList(res['days'], CalendarDay.fromJson);
  }
}
