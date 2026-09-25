import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../core/money.dart';
import '../../data/api/api_client.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../add_tx/account_picker.dart';
import '../add_tx/category_grid.dart';
import '../add_tx/fund_picker.dart';
import '../add_tx/picker_field.dart';
import '../widgets/widgets.dart';

const Map<String, IconData> kAssetCategoryIcons = {
  'digital': Icons.devices_other_outlined,
  'appliance': Icons.kitchen_outlined,
  'furniture': Icons.chair_outlined,
  'clothing': Icons.checkroom_outlined,
  'vehicle': Icons.directions_car_outlined,
  'luxury': Icons.shopping_bag_outlined,
  'jewelry': Icons.diamond_outlined,
  'sports': Icons.sports_basketball_outlined,
  'other': Icons.inventory_2_outlined,
};

IconData assetCategoryIcon(String category) =>
    kAssetCategoryIcons[category] ?? Icons.inventory_2_outlined;

/// 圆底图标，和流水行的类别图标一个样子。
class AssetAvatar extends StatelessWidget {
  const AssetAvatar(this.icon, {super.key, this.muted = false});

  final IconData icon;

  /// 退役/卖出/清仓的，退到背景里。
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = muted ? scheme.onSurfaceVariant : scheme.primary;
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 20, color: color),
    );
  }
}

enum TagTone { neutral, warning }

/// 行内小标签：「闲置」「手动价」「行情过期」。
class TagLabel extends StatelessWidget {
  const TagLabel(this.text, {super.key, this.tone = TagTone.neutral});

  final String text;
  final TagTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ledger = LedgerColors.of(context);
    final warning = tone == TagTone.warning;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: warning ? ledger.warningContainer : ledger.surface3,
        borderRadius: BorderRadius.circular(LedgerShapes.chip - 2),
      ),
      child: Text(
        text,
        maxLines: 1,
        style: theme.textTheme.labelSmall?.copyWith(
          color: warning
              ? theme.colorScheme.onSurface
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 「¥16.43/天」。分以下四舍五入，只在展示时做。
class DailyMoney extends StatelessWidget {
  const DailyMoney(
    this.cents, {
    super.key,
    this.size = MoneySize.body,
    this.signed = false,
    this.muted = false,
  });

  final double cents;
  final MoneySize size;
  final bool signed;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final whole = cents.round();
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: Money.format(whole, signed: signed),
            style: MoneyText.styleFor(context, whole, signed: signed, size: size, muted: muted),
          ),
          TextSpan(text: '/天', style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

String dailyLabel(double cents, {bool signed = false}) =>
    '${Money.format(cents.round(), signed: signed)}/天';

/// 列表行第二行：「估值 ¥5,895.88 · −2%」；较原价不到 1%（或原价 0）只写估值。
String assetValueLine(Asset asset, DateTime now) {
  final value = currentValue(asset, now);
  final change = valueChangeLabel(value, asset.priceCents);
  final head = '估值 ${Money.format(value)}';
  return change == null ? head : '$head · $change';
}

/// 详情页里的一行「名目 …… 数」。
class InfoRow extends StatelessWidget {
  const InfoRow(this.label, this.value, {super.key});

  final String label;
  final Widget value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: LedgerLayout.pagePadding,
      vertical: 8,
    ),
    child: Row(
      children: [
        Text(label, style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        )),
        const SizedBox(width: LedgerLayout.pagePadding),
        Expanded(
          child: Align(alignment: Alignment.centerRight, child: value),
        ),
      ],
    ),
  );
}

/// 纯文字的值（右对齐、一行）。
class InfoText extends StatelessWidget {
  const InfoText(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    textAlign: TextAlign.right,
    style: Theme.of(context).textTheme.bodyMedium,
  );
}

/// `YYYY-MM-DD` → 本地那天 0 点（给日期选择器用）。
DateTime? localDate(String? day) {
  final d = parseDay(day);
  return d == null ? null : DateTime(d.year, d.month, d.day);
}

/// 选一天，最晚到今天：还没发生的事不记账（服务端也拦）。
Future<DateTime?> pickPastDay(
  BuildContext context, {
  required DateTime initial,
  DateTime? first,
  String? help,
}) {
  final now = DateTime.now();
  final last = DateTime(now.year, now.month, now.day);
  final firstDate = first ?? DateTime(2000);
  var start = initial.isAfter(last) ? last : initial;
  if (start.isBefore(firstDate)) start = firstDate;
  return showDatePicker(
    context: context,
    initialDate: start,
    firstDate: firstDate,
    lastDate: last,
    helpText: help,
  );
}

/// 日期按钮：显示「今天 / 9月12日 周五」，点开日历。
class DayButton extends StatelessWidget {
  const DayButton({super.key, required this.day, required this.onPressed});

  final DateTime day;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: OutlinedButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.today_outlined, size: 18),
      label: Text(Dates.dayLabel(day)),
    ),
  );
}

/// 表单底部：行内错误 + 主按钮。
class FormSubmit extends StatelessWidget {
  const FormSubmit({
    super.key,
    required this.label,
    required this.busy,
    required this.onPressed,
    this.error,
  });

  final String label;
  final bool busy;
  final VoidCallback onPressed;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LedgerLayout.pagePadding,
        LedgerLayout.itemGap,
        LedgerLayout.pagePadding,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (error != null) ...[
            Text(
              error!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
            const SizedBox(height: LedgerLayout.itemGap),
          ],
          FilledButton(
            onPressed: busy ? null : onPressed,
            child: busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(label),
          ),
        ],
      ),
    );
  }
}

/// 「同时记一笔」的去向：账户、基金、类别。都能不选 —— 基金缺省走默认基金，类别留空也记得进去。
class RecordTargetFields extends StatelessWidget {
  const RecordTargetFields({
    super.key,
    required this.ledger,
    required this.income,
    required this.accountId,
    required this.fundId,
    required this.categoryId,
    required this.onAccount,
    required this.onFund,
    required this.onCategory,
  });

  final LedgerData ledger;
  final bool income;
  final String? accountId;
  final String? fundId;
  final String? categoryId;
  final ValueChanged<String?> onAccount;
  final ValueChanged<String?> onFund;
  final ValueChanged<String?> onCategory;

  @override
  Widget build(BuildContext context) {
    final categories = income
        ? ledger.incomeCategories()
        : ledger.expenseCategories();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PickerField(
          label: income ? '收到哪个账户' : '从哪个账户付的',
          topGap: LedgerLayout.itemGap,
          child: AccountPicker(
            accounts: ledger.activeAccounts,
            selectedId: accountId,
            onSelected: onAccount,
          ),
        ),
        PickerField(
          label: '基金',
          contentPadding: EdgeInsets.zero,
          trailing: Text(
            '不选就记到默认基金',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          child: FundPicker(
            funds: ledger.activeFunds,
            selectedId: fundId,
            onSelected: onFund,
          ),
        ),
        PickerField(
          label: '类别',
          child: CategoryGrid(
            categories: categories,
            selectedId: categoryId,
            onSelected: (id) => onCategory(id == categoryId ? null : id),
          ),
        ),
      ],
    );
  }
}

/// 宽屏上把内容收窄到 [maxWidth]：名字和数字别隔着半个屏幕。
EdgeInsets readableInsets(double width, {double maxWidth = 880}) =>
    EdgeInsets.symmetric(
      horizontal: width > maxWidth ? (width - maxWidth) / 2 : 0,
    );

/// 同步失败的横幅（同基金页：下拉失败要看得见，不能只让圈圈转完）。
class SyncErrorBanner extends StatelessWidget {
  const SyncErrorBanner({super.key, required this.error, required this.onRetry});

  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => error == null
      ? const SizedBox.shrink()
      : InlineError(
          message: '同步失败：${describeError(error!)}',
          onRetry: onRetry,
          padding: const EdgeInsets.fromLTRB(
            LedgerLayout.pagePadding,
            LedgerLayout.itemGap,
            LedgerLayout.pagePadding,
            0,
          ),
        );
}

/// 默认基金（没有就 null，交给服务端兜底）。
String? defaultFundId(LedgerData ledger) {
  for (final fund in ledger.activeFunds) {
    if (fund.isDefault) return fund.id;
  }
  return null;
}

/// 表单里的金额输入：空 = null，填错 = -1（调用方据此给行内提示）。
int? parseMoneyField(String text) {
  final t = text.trim();
  if (t.isEmpty) return null;
  final cents = Money.tryParse(t);
  return cents == null || cents < 0 ? -1 : cents;
}

/// 表单里的百分数：空 = null（跟随类别），填错或超出 0~[maxBp] 基点 = -1。`12.5`、`12.5%` 都认。
int? parsePercentBp(String text, {required int maxBp}) {
  final t = text.replaceAll('%', '').replaceAll('％', '').trim();
  if (t.isEmpty) return null;
  final pct = double.tryParse(t);
  if (pct == null || !pct.isFinite || pct < 0) return -1;
  final bp = (pct * 100).round();
  return bp > maxBp ? -1 : bp;
}

/// 开仓、加减仓、记物品、卖物品失败时给用户的话。
///
/// 这几个请求都带 clientId，服务端认得出重发（`server/src/lib/idempotency.js`）。
/// 请求可能已经送到（超时、半路断线）时要说清楚：不确定记上没有，但再点一次不会重复记 ——
/// 否则用户对着「请求超时」只能猜，猜错了就是一笔记两遍。
String describeWriteError(Object error) {
  if (error is ApiException && error.maybeSent) {
    return '没等到服务器回应，不确定记上没有。再点一次也不会重复记。';
  }
  return describeError(error);
}
