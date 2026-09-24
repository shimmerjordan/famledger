import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../widgets/widgets.dart';
import 'tx_tile.dart';

/// 宽屏（≥ 840）账单表格：一行一笔，行首复选框，点行进详情。
///
/// 选中任意一笔后，表头那一行换成 [selectionBar]（全选框留在原位），
/// 高度不变，下面的行不会被顶一下。
class TxTable extends StatelessWidget {
  const TxTable({
    super.key,
    required this.items,
    required this.selected,
    required this.onToggle,
    required this.onToggleAll,
    required this.onOpen,
    required this.selectionBar,
    required this.footer,
    this.ledger,
    this.scroll,
  });

  final List<Transaction> items;
  final LedgerData? ledger;

  /// 选中的流水 id（只认 [items] 里有的）。
  final Set<String> selected;
  final void Function(Transaction tx, bool on) onToggle;

  /// true = 全选已加载的，false = 全不选。
  final ValueChanged<bool> onToggleAll;
  final ValueChanged<Transaction> onOpen;
  final Widget selectionBar;
  final Widget footer;
  final ScrollController? scroll;

  /// 表格窄于这个宽度就不显示「成员」列、列间距也收紧：840 宽的窗口去掉
  /// 导航轨只剩六百多，七列挤在一起每列只剩两三个字，成员是最能让位的那列。
  static const double roomyMinWidth = 760;

  @override
  Widget build(BuildContext context) {
    final count = items.where((tx) => selected.contains(tx.id)).length;
    return LayoutBuilder(
      builder: (context, constraints) {
        final roomy = constraints.maxWidth >= roomyMinWidth;
        return Column(
          children: [
            _Header(
              roomy: roomy,
              count: count,
              total: items.length,
              onToggleAll: onToggleAll,
              selectionBar: selectionBar,
            ),
            Expanded(
              child: ListView.builder(
                controller: scroll,
                padding: const EdgeInsets.only(bottom: 96),
                itemCount: items.length + 1,
                itemBuilder: (context, index) {
                  if (index == items.length) return footer;
                  final tx = items[index];
                  return _Row(
                    key: ValueKey('tx-row-${tx.id}'),
                    tx: tx,
                    ledger: ledger,
                    roomy: roomy,
                    selected: selected.contains(tx.id),
                    onToggle: (on) => onToggle(tx, on),
                    onOpen: () => onOpen(tx),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 表头与每一行共用的列宽：日期、金额定宽，其余按比例分。
class _Columns extends StatelessWidget {
  const _Columns({
    required this.roomy,
    required this.check,
    required this.date,
    required this.category,
    required this.merchant,
    required this.fund,
    required this.account,
    required this.member,
    required this.amount,
  });

  /// 宽裕时多一列「成员」、列间距也大一点。
  final bool roomy;
  final Widget check;
  final Widget date;
  final Widget category;
  final Widget merchant;
  final Widget fund;
  final Widget account;
  final Widget member;
  final Widget amount;

  static const double checkWidth = 48;
  static const double dateWidth = 112;
  static const double amountWidth = 120;

  /// 复选框自带 48dp 触控区，左边只再留一点；右边对齐宽屏页边距。
  static const EdgeInsets padding = EdgeInsets.only(
    left: 8,
    right: LedgerLayout.widePagePadding,
  );

  @override
  Widget build(BuildContext context) {
    final gap = SizedBox(width: roomy ? 12 : 8);
    return Padding(
      padding: padding,
      child: Row(
        children: [
          SizedBox(
            width: checkWidth,
            child: Center(child: check),
          ),
          const SizedBox(width: 4),
          SizedBox(width: dateWidth, child: date),
          gap,
          Expanded(flex: 3, child: category),
          gap,
          Expanded(flex: 5, child: merchant),
          gap,
          Expanded(flex: 3, child: fund),
          gap,
          Expanded(flex: 3, child: account),
          if (roomy) ...[gap, Expanded(flex: 2, child: member)],
          gap,
          SizedBox(
            width: amountWidth,
            child: Align(alignment: Alignment.centerRight, child: amount),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.roomy,
    required this.count,
    required this.total,
    required this.onToggleAll,
    required this.selectionBar,
  });

  final bool roomy;
  final int count;
  final int total;
  final ValueChanged<bool> onToggleAll;
  final Widget selectionBar;

  static const double height = 52;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ledger = LedgerColors.of(context);
    final selecting = count > 0;
    final all = total > 0 && count == total;
    final checkbox = Checkbox(
      key: const ValueKey('tx-check-all'),
      tristate: true,
      value: all ? true : (selecting ? null : false),
      semanticLabel: all ? '取消全选' : '全选',
      // 半选时点一下是「全选」，不是 Checkbox 默认的「清空」：
      // 多数人点它就是想把剩下的也勾上。
      onChanged: total == 0 ? null : (_) => onToggleAll(!all),
    );
    final label = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    Widget text(String s) =>
        Text(s, style: label, maxLines: 1, overflow: TextOverflow.clip);

    return Container(
      height: height,
      decoration: BoxDecoration(
        color: selecting ? ledger.surface2 : null,
        border: Border(bottom: BorderSide(color: theme.colorScheme.outline)),
      ),
      child: selecting
          ? Padding(
              padding: _Columns.padding,
              child: Row(
                children: [
                  SizedBox(
                    width: _Columns.checkWidth,
                    child: Center(child: checkbox),
                  ),
                  const SizedBox(width: 4),
                  Expanded(child: selectionBar),
                ],
              ),
            )
          : _Columns(
              roomy: roomy,
              check: checkbox,
              date: text('日期'),
              category: text('类别'),
              merchant: text('商户 / 备注'),
              fund: text('基金'),
              account: text('账户'),
              member: text('成员'),
              amount: text('金额'),
            ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.tx,
    required this.ledger,
    required this.roomy,
    required this.selected,
    required this.onToggle,
    required this.onOpen,
  });

  final Transaction tx;
  final LedgerData? ledger;
  final bool roomy;
  final bool selected;
  final ValueChanged<bool> onToggle;
  final VoidCallback onOpen;

  static const double minHeight = 52;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final body = theme.textTheme.bodyMedium;
    final small = theme.textTheme.bodySmall?.copyWith(color: muted);
    final data = ledger;
    final fund = data?.fund(tx.fundId);
    final toFund = data?.fund(tx.toFundId);
    final category = data?.category(tx.categoryId);
    final account = data?.account(tx.accountId);
    final toAccount = data?.account(tx.toAccountId);
    final member = data?.member(tx.memberId);

    Widget cell(String? value) => value == null || value.isEmpty
        ? Text('—', style: body?.copyWith(color: muted))
        : Text(
            value,
            style: body,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );

    String? pair(String? from, String? to) =>
        from == null && to == null ? null : '${from ?? '—'} → ${to ?? '—'}';

    final fundColor = fund == null
        ? muted
        : fundColorOf(context, fund, _index(data, fund));
    final fundName = tx.isTransfer
        ? pair(fund?.name, toFund?.name)
        : fund?.name;

    return Material(
      color: selected
          ? theme.colorScheme.secondaryContainer
          : Colors.transparent,
      child: InkWell(
        onTap: onOpen,
        child: Container(
          constraints: const BoxConstraints(minHeight: minHeight),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: theme.colorScheme.outlineVariant),
            ),
          ),
          child: _Columns(
            roomy: roomy,
            check: Checkbox(
              key: ValueKey('tx-check-${tx.id}'),
              value: selected,
              semanticLabel: '选中这笔',
              onChanged: (on) => onToggle(on ?? false),
            ),
            date: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: _dayLabel(tx.occurredAt)),
                  TextSpan(
                    text: ' ${Dates.timeLabel(tx.occurredAt)}',
                    style: small,
                  ),
                ],
              ),
              style: body,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            category: Row(
              children: [
                CategoryIcon(
                  tx.isTransfer ? 'swap_horiz' : category?.icon,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: category == null && !tx.isTransfer
                      ? Text('未分类', style: body?.copyWith(color: muted))
                      : cell(tx.isTransfer ? '转账' : category?.name),
                ),
              ],
            ),
            merchant: _Merchant(tx: tx, body: body, small: small),
            fund: fundName == null
                ? cell(null)
                : Row(
                    children: [
                      if (fund != null) ...[
                        FundDot(color: fundColor),
                        const SizedBox(width: 6),
                      ],
                      Flexible(child: cell(fundName)),
                    ],
                  ),
            account: cell(
              tx.isTransfer
                  ? pair(account?.name, toAccount?.name)
                  : account?.name,
            ),
            member: cell(member?.label),
            // 金额列定宽，千万级的数放不下时宁可缩小也不能被省略号吃掉尾数。
            amount: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: MoneyText(
                tx.isExpense ? -tx.amountCents : tx.amountCents,
                signed: tx.isIncome,
                color: tx.status == 'void' ? muted : null,
              ),
            ),
          ),
        ),
      ),
    );
  }

  static int _index(LedgerData? data, Fund fund) {
    final index = data?.fundIndex(fund.id) ?? 0;
    return index < 0 ? 0 : index;
  }
}

/// 商户在前、备注跟在后面淡一点；状态小标（待确认/疑似重复/待上传）贴在最后。
class _Merchant extends StatelessWidget {
  const _Merchant({required this.tx, this.body, this.small});

  final Transaction tx;
  final TextStyle? body;
  final TextStyle? small;

  @override
  Widget build(BuildContext context) {
    final merchant = tx.merchant ?? '';
    final note = tx.note ?? '';
    final primary = merchant.isNotEmpty ? merchant : note;
    final secondary = merchant.isNotEmpty && note.isNotEmpty ? note : '';
    final Widget? badge = tx.pendingSync
        ? TxStatusBadge.offline()
        : (tx.status != 'confirmed' ? TxStatusBadge(status: tx.status) : null);

    return Row(
      children: [
        Flexible(
          child: primary.isEmpty
              ? Text('—', style: body?.copyWith(color: small?.color))
              : Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: primary),
                      if (secondary.isNotEmpty)
                        TextSpan(text: ' · $secondary', style: small),
                    ],
                  ),
                  style: body,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
        ),
        if (badge != null) ...[const SizedBox(width: 6), badge],
      ],
    );
  }
}

/// 选中之后表头换成的这一条：已选几笔 + 批量操作。
///
/// 某个操作对当前选中的不适用时（例如全是转账、或者支出收入混着）按钮置灰，
/// 悬停说明原因，而不是点了才报错。
class TxSelectionBar extends StatelessWidget {
  const TxSelectionBar({
    super.key,
    required this.count,
    required this.onCancel,
    this.onCategory,
    this.onFund,
    this.onDelete,
    this.categoryHint,
    this.fundHint,
  });

  final int count;
  final VoidCallback? onCategory;
  final VoidCallback? onFund;
  final VoidCallback? onDelete;
  final VoidCallback onCancel;

  /// [onCategory] 为 null 时悬停显示的原因。
  final String? categoryHint;
  final String? fundHint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget hinted(String? hint, Widget child) =>
        hint == null ? child : Tooltip(message: hint, child: child);

    return Row(
      children: [
        Text('已选 $count 笔', style: theme.textTheme.titleSmall, maxLines: 1),
        const SizedBox(width: LedgerLayout.itemGap),
        hinted(
          onCategory == null ? categoryHint : null,
          TextButton.icon(
            onPressed: onCategory,
            icon: const Icon(Icons.category_outlined, size: 18),
            label: const Text('改类别'),
          ),
        ),
        hinted(
          onFund == null ? fundHint : null,
          TextButton.icon(
            onPressed: onFund,
            icon: const Icon(Icons.savings_outlined, size: 18),
            label: const Text('改基金'),
          ),
        ),
        Tooltip(
          message: '删除（Delete）',
          child: TextButton.icon(
            onPressed: onDelete,
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('删除'),
          ),
        ),
        const Spacer(),
        Tooltip(
          message: 'Esc',
          child: TextButton(onPressed: onCancel, child: const Text('取消')),
        ),
      ],
    );
  }
}

/// 批量操作失败的那一句：贴在表头下面，关掉或者下次操作就消失。
class TxBulkError extends StatelessWidget {
  const TxBulkError({
    super.key,
    required this.message,
    required this.onClose,
    this.onRetry,
  });

  final String message;
  final VoidCallback onClose;

  /// 为 null 时不给「重试」（例如选太多，原样再来一次也没用）。
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.errorContainer,
      padding: const EdgeInsets.only(
        left: LedgerLayout.widePagePadding,
        right: 8,
      ),
      child: Row(
        children: [
          Icon(
            Icons.error_outline,
            size: 18,
            color: theme.colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
          if (onRetry != null)
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.onErrorContainer,
              ),
              child: const Text('重试'),
            ),
          IconButton(
            tooltip: '知道了',
            onPressed: onClose,
            icon: const Icon(Icons.close, size: 18),
            color: theme.colorScheme.onErrorContainer,
          ),
        ],
      ),
    );
  }
}

/// 表格里的日期要短而整齐：今天 / 昨天 / 9月12日 / 2025-09-12。
String _dayLabel(DateTime d, {DateTime? now}) {
  final today = DateUtils.dateOnly(now ?? DateTime.now());
  final diff = today.difference(DateUtils.dateOnly(d)).inDays;
  if (diff == 0) return '今天';
  if (diff == 1) return '昨天';
  if (d.year == today.year) return '${d.month}月${d.day}日';
  return Dates.isoDate(d);
}
