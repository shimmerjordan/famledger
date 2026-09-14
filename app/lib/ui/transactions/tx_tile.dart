import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../widgets/widgets.dart';

/// 一行流水：类别图标（染基金色）+ 商户/类别 + 基金·时间 + 金额。
///
/// 故意不是 `ConsumerWidget`：名字由调用方从 [LedgerData] 里解出来传进来，
/// 长列表里每行都去 watch 一次 provider 不划算，测试也能直接构造。
class TxTile extends StatelessWidget {
  const TxTile({
    super.key,
    required this.tx,
    this.ledger,
    this.onTap,
    this.showTime = true,
    this.trailingBelow,
  });

  final Transaction tx;

  /// 用来把 fundId/categoryId 翻成名字与颜色；为 null 就只显示金额与时间。
  final LedgerData? ledger;

  final VoidCallback? onTap;

  /// 首页「最近流水」里显示时间，基金详情里也一样；关掉可省一行信息。
  final bool showTime;

  /// 金额下面再挂一行（例如「92% 可信 · 来自支付宝」）。
  final Widget? trailingBelow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final data = ledger;
    final fund = data?.fund(tx.fundId);
    final toFund = data?.fund(tx.toFundId);
    final category = data?.category(tx.categoryId);
    final account = data?.account(tx.accountId);
    final toAccount = data?.account(tx.toAccountId);
    // 没有基金的流水不借用别人的身份色，用中性色。
    final index = fund == null ? -1 : (data?.fundIndex(fund.id) ?? 0);
    final color = fund == null
        ? theme.colorScheme.onSurfaceVariant
        : fundColorOf(context, fund, index < 0 ? 0 : index);

    return ListTile(
      onTap: onTap,
      // 48dp 触控目标（ListTile 默认高度已经够，这里只保证紧凑模式也不缩）。
      minVerticalPadding: 12,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: LedgerLayout.pagePadding,
        vertical: 4,
      ),
      leading: CategoryIcon(
        tx.isTransfer ? 'swap_horiz' : category?.icon,
        background: true,
        color: color,
      ),
      title: Text(
        _title(category, toFund, toAccount),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyLarge,
      ),
      subtitle: _Subtitle(
        tx: tx,
        fundName: fund?.name,
        fundColor: color,
        accountName: account?.name,
        showTime: showTime,
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          MoneyText(
            tx.isExpense ? -tx.amountCents : tx.amountCents,
            signed: tx.isIncome,
            color: tx.status == 'void' ? theme.colorScheme.onSurfaceVariant : null,
          ),
          if (trailingBelow != null) ...[const SizedBox(height: 2), trailingBelow!],
        ],
      ),
    );
  }

  /// 标题优先说「谁收了钱」，没有商户就退回类别名，再退回类型。
  String _title(TxCategory? category, Fund? toFund, Account? toAccount) {
    final merchant = tx.merchant;
    if (merchant != null && merchant.isNotEmpty) return merchant;
    if (tx.isTransfer) {
      final to = toFund?.name ?? toAccount?.name;
      return to == null ? '转账' : '转入 $to';
    }
    if (category != null) return category.name;
    final note = tx.note;
    if (note != null && note.isNotEmpty) return note;
    return tx.typeLabel;
  }
}

class _Subtitle extends StatelessWidget {
  const _Subtitle({
    required this.tx,
    required this.fundColor,
    required this.showTime,
    this.fundName,
    this.accountName,
  });

  final Transaction tx;
  final String? fundName;
  final Color fundColor;
  final String? accountName;
  final bool showTime;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parts = <String>[
      if (accountName != null) accountName!,
      if (showTime) Dates.timeLabel(tx.occurredAt),
      if (tx.source != 'manual') tx.sourceLabel,
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: [
          if (fundName != null) ...[
            FundDot(color: fundColor),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                fundName!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
            if (parts.isNotEmpty)
              Text(' · ', style: theme.textTheme.bodySmall),
          ],
          Flexible(
            child: Text(
              parts.join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (tx.pendingSync) ...[
            const SizedBox(width: 6),
            TxStatusBadge.offline(),
          ] else if (tx.status != 'confirmed') ...[
            const SizedBox(width: 6),
            TxStatusBadge(status: tx.status),
          ],
        ],
      ),
    );
  }
}

/// 状态小标：待确认 / 疑似重复 / 已作废 / 待上传。
class TxStatusBadge extends StatelessWidget {
  const TxStatusBadge({super.key, required this.status});

  factory TxStatusBadge.offline({Key? key}) =>
      TxStatusBadge(key: key, status: 'offline');

  final String status;

  static const Map<String, String> _labels = {
    'pending': '待确认',
    'duplicate': '疑似重复',
    'void': '已作废',
    'offline': '待上传',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ledger = LedgerColors.of(context);
    final (bg, fg) = switch (status) {
      'pending' || 'offline' => (ledger.warningContainer, theme.colorScheme.onSurface),
      'duplicate' => (theme.colorScheme.errorContainer, theme.colorScheme.onErrorContainer),
      _ => (ledger.surface3, theme.colorScheme.onSurfaceVariant),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(LedgerShapes.chip),
      ),
      child: Text(
        _labels[status] ?? status,
        style: theme.textTheme.labelSmall?.copyWith(color: fg),
      ),
    );
  }
}
