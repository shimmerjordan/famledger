import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/money.dart';
import '../../data/models/models.dart';
import '../widgets/widgets.dart';

/// 候选分组的第二行：「每月 · 7 次 · 最近 2026-09-18」，只扣过一次的说按什么算，价格有高有低的写出区间；默认没勾的说清楚为什么：
/// 已经有卡在管（或者是买东西的那笔）、好像停了（该扣的那期没扣）、把握不大（分数低，或者只扣过一次又没写年费这类字）。
String candidateLine(SubscriptionCandidate c) {
  final period = Membership.feePeriodLabels[c.period] ?? c.period;
  final name = c.linkedName;
  return [
    '$period · ${c.count} 次 · 最近 ${c.lastOn}',
    if (c.count == 1) '只扣过一次，按$period算',
    if (c.minCents != c.maxCents) '${Money.format(c.minCents)}–${Money.format(c.maxCents)}',
    if (name != null) c.linkedAsset ? '已关联物品「$name」' : '已关联「$name」',
    if (c.stale) '好像停了（${c.nextOn ?? '上一期'} 该扣的没扣）'
    else if (!c.checked && name == null) '把握不大，默认没勾',
  ].join(' · ');
}

/// 导入页的「从流水」分段（spec §6「从流水」）：列出最近 13 个月里像订阅的扣费分组（纯规则，服务端算好的），默认勾分数 ≥4、
/// 还没关联的组（只扣过一次的要名字里有年费、包年这类字）；下面的两个按钮（直接生成 / AI 整理名称）在输入页的底栏。
/// 一组都没有时说清楚看的是哪些流水，给「改用粘贴」。状态在输入页，这里只画。
class TransactionsPane extends StatelessWidget {
  const TransactionsPane({
    super.key,
    required this.candidates,
    required this.loading,
    this.error,
    required this.picked,
    required this.onToggle,
    required this.onRetry,
    required this.onUsePaste,
  });

  final SubscriptionCandidates? candidates;
  final bool loading;
  final String? error;
  final Set<String> picked;
  final ValueChanged<String> onToggle;
  final VoidCallback onRetry;
  final VoidCallback onUsePaste;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const pad = EdgeInsets.fromLTRB(LedgerLayout.pagePadding, LedgerLayout.itemGap, LedgerLayout.pagePadding, 0);
    if (loading) {
      return Padding(
        key: const ValueKey('import-tx-loading'),
        padding: pad,
        child: Column(children: [for (var i = 0; i < 3; i++) const Padding(padding: EdgeInsets.only(bottom: 8), child: Skeleton(height: 56, radius: 8))]),
      );
    }
    if (error case final message?) {
      return InlineError(key: const ValueKey('import-tx-error'), message: message, onRetry: onRetry, padding: pad);
    }
    final c = candidates;
    if (c == null) return const SizedBox.shrink();
    if (c.items.isEmpty) {
      return Padding(
        padding: pad,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '最近 ${c.months} 个月确认过的支出里没看到像订阅的扣费（还在「待确认」的不算，先去核对）：要在 ¥1–¥5000 之间、'
              '按月 / 季 / 年重复出现，或者商户名、备注里带「会员」「VIP」「包月」这类字。',
              key: const ValueKey('import-tx-empty'),
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            FilledButton.tonal(key: const ValueKey('import-tx-empty-paste'), onPressed: onUsePaste, child: const Text('改用粘贴会员说明')),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: pad,
          child: Text(
            '最近 ${c.months} 个月里像订阅的扣费。默认勾了把握大、还没建卡的，勾好再生成会员卡，导入前还能逐条改。',
            style: theme.textTheme.bodyMedium,
          ),
        ),
        for (final item in c.items)
          CheckboxListTile(
            key: ValueKey('import-tx-${item.key}'),
            contentPadding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
            value: picked.contains(item.key),
            onChanged: (_) => onToggle(item.key),
            title: Text('${item.merchant} · ${Money.format(item.amountCents)}'),
            subtitle: Text(candidateLine(item)),
          ),
        if (c.total > c.items.length)
          Padding(padding: pad, child: Text('一共认出 ${c.total} 组，只列了最像的 ${c.items.length} 组。', style: theme.textTheme.bodySmall)),
        Padding(
          padding: pad,
          child: Text(
            '「直接生成」按商户名建卡，不用 AI。「AI 整理名称」会把商户名整理成平台和会员名（财付通-腾讯视频VIP → 平台「腾讯视频」、'
            '卡「腾讯视频VIP」），只把商户名、金额、周期和次数发给 AI，不发流水原文和备注；没填商户名的只发金额和周期。'
            '两种都是续费价按扣过的金额算，到期日是最近一次扣费再往后一个周期。',
            key: const ValueKey('import-tx-note'),
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}
