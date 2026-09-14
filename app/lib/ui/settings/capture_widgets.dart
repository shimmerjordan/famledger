import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../capture/parser.dart';
import '../../capture/pipeline.dart';
import '../../capture/source_profiles.dart';
import '../../core/dates.dart';
import '../../core/money.dart';
import '../../data/repos/ledger_repo.dart';
import '../../platform/capture_dry_run.dart';
import '../../platform/file_capture_store.dart';

/// 自动记账设置页的小零件（只服务 `capture_page.dart`）。

/// 权限/状态一行：图标表态度，右侧给一个动作。
class CaptureStatusTile extends StatelessWidget {
  const CaptureStatusTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.ok,
    this.actionLabel,
    this.onAction,
    this.pending = false,
  });

  final String title;
  final String subtitle;

  /// true = 一切正常（打勾）；false = 需要用户去处理（警示色）。
  final bool ok;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// 状态还没查回来。
  final bool pending;

  @override
  Widget build(BuildContext context) {
    final colors = LedgerColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: pending
          ? Icon(Icons.hourglass_empty, color: scheme.onSurfaceVariant)
          : ok
          ? Icon(Icons.check_circle, color: colors.income)
          : Icon(Icons.error_outline, color: colors.warning),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: !ok && actionLabel != null && onAction != null
          ? FilledButton.tonal(onPressed: onAction, child: Text(actionLabel!))
          : null,
    );
  }
}

/// recorded / pending / duplicate / ignored / error / undone → 中文。
String decisionLabel(String decision) => switch (decision) {
  'recorded' => '已入账',
  'pending' => '待确认',
  'duplicate' => '重复',
  'ignored' => '已忽略',
  'error' => '出错',
  'undone' => '已撤销',
  _ => decision,
};

/// 结论小芯片：待确认用 warning 容器，出错用 error 容器，其余中性。
class DecisionChip extends StatelessWidget {
  const DecisionChip(this.decision, {super.key});

  final String decision;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = LedgerColors.of(context);
    final (Color bg, Color fg) = switch (decision) {
      'recorded' => (colors.incomeContainer, colors.income),
      'pending' => (colors.warningContainer, theme.colorScheme.onSurface),
      'error' => (theme.colorScheme.errorContainer, theme.colorScheme.onErrorContainer),
      _ => (colors.surface3, theme.colorScheme.onSurfaceVariant),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(LedgerShapes.chip),
      ),
      child: Text(
        decisionLabel(decision),
        style: theme.textTheme.labelMedium?.copyWith(color: fg),
      ),
    );
  }
}

/// 「最近捕获」的一行。
class CaptureRecentTile extends StatelessWidget {
  const CaptureRecentTile({
    super.key,
    required this.entry,
    required this.appLabel,
    this.onTap,
  });

  final CaptureLogEntry entry;
  final String appLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    title: Text(entry.title, maxLines: 2, overflow: TextOverflow.ellipsis),
    subtitle: Text('${Dates.dateTimeLabel(entry.at)} · $appLabel'),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        DecisionChip(entry.decision),
        if (onTap != null) const Icon(Icons.chevron_right, size: 20),
      ],
    ),
    onTap: onTap,
  );
}

/// 「测试解析」的结果面板：结论 + 通知文案 + 抽取要素。
class DryRunResultPanel extends StatelessWidget {
  const DryRunResultPanel({super.key, required this.result, required this.ledger});

  final CaptureDryRun result;
  final LedgerData? ledger;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = LedgerColors.of(context);
    final payment = result.payment;
    final outcome = result.outcome;
    final draft = outcome.draft;

    final rows = <(String, String)>[
      if (payment.amountCents != null)
        ('金额', Money.format(payment.amountCents!)),
      ('方向', _directionLabel(payment.direction)),
      if (payment.merchant.isNotEmpty) ('商户', payment.merchant),
      ('渠道', SourceProfile.displayNameOfChannel(payment.channel)),
      if (payment.cardTail != null) ('卡尾号', payment.cardTail!),
      if (draft != null) ('类别', ledger?.category(draft.categoryId)?.name ?? '未分类'),
      if (draft != null) ('基金', ledger?.fund(draft.fundId)?.name ?? '未指定'),
      if (draft != null) ('账户', ledger?.account(draft.accountId)?.name ?? '未指定'),
      if (draft != null) ('置信度', '${(draft.confidence * 100).round()}%'),
    ];

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
      padding: const EdgeInsets.all(LedgerLayout.pagePadding),
      decoration: BoxDecoration(
        color: colors.surface2,
        borderRadius: BorderRadius.circular(LedgerShapes.card),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              DecisionChip(outcome.decision.name),
              const SizedBox(width: 8),
              Expanded(child: Text(outcome.title, style: theme.textTheme.titleMedium)),
            ],
          ),
          const SizedBox(height: 4),
          Text(outcome.body, style: theme.textTheme.bodySmall),
          if (payment.isPayment) ...[
            const SizedBox(height: LedgerLayout.itemGap),
            Wrap(
              spacing: LedgerLayout.groupGap,
              runSpacing: 8,
              children: [
                for (final (label, value) in rows)
                  SizedBox(
                    width: 140,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label, style: theme.textTheme.bodySmall),
                        Text(value, style: theme.textTheme.bodyMedium),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static String _directionLabel(PayDirection d) => switch (d) {
    PayDirection.expense => '支出',
    PayDirection.income => '收入',
    PayDirection.transfer => '转账（需确认）',
    PayDirection.unknown => '不确定（按支出）',
  };
}

/// 默认允许列表里那些包名的中文名（设备上没装、拿不到系统标签时用）。
/// 与 `lib/capture/source_profiles.dart` 的 `kDefaultAllowedPackages` 对应。
const Map<String, String> kKnownAppLabels = {
  'com.eg.android.AlipayGphone': '支付宝',
  'com.tencent.mm': '微信',
  'com.unionpay': '云闪付',
  'com.miui.mms': '小米短信',
  'com.android.mms': '短信',
  'com.google.android.apps.messaging': 'Google 信息',
  'com.samsung.android.messaging': '三星短信',
  'cmb.pb': '招商银行',
  'com.chinamworld.main': '建设银行',
  'com.icbc': '工商银行',
  'com.chinamworld.bocmbci': '中国银行',
  'com.android.bankabc': '农业银行',
  'com.bankcomm.Bankcomm': '交通银行',
  'com.yitong.mbank.psbc': '邮储银行',
  'cn.com.spdb.mobilebank.per': '浦发银行',
  'com.chinamworld.bocmbci.cmbc': '民生银行',
  'com.pingan.paces.ccms': '平安口袋银行',
  'com.android.shell': 'adb 调试',
};

/// 包名 → 给人看的名字：系统里装了就用系统标签，否则用内置对照表，再不然按渠道兜底。
String appLabelFor(String package, Map<String, String> installedLabels) =>
    installedLabels[package] ??
    kKnownAppLabels[package] ??
    (SourceProfile.forPackage(package).packages.isNotEmpty
        ? SourceProfile.forPackage(package).displayName
        : package.split('.').last);

/// 非 Android 平台的说明。
class CapturePlatformNotice extends StatelessWidget {
  const CapturePlatformNotice({super.key, required this.isWeb});

  final bool isWeb;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.info_outline),
    title: Text(isWeb ? '网页版没有自动记账' : 'iOS 不能读取其他应用的通知'),
    subtitle: Text(
      isWeb
          ? '自动记账在手机上进行；这里只能改识别设置。'
          : '系统不允许读取支付 App 的通知。请在支付 App 里用「分享到家账」，或用快捷指令「记一笔」。',
    ),
  );
}

/// 结论 → 通知里那种一句话摘要（给 SnackBar 用）。
String outcomeSummary(CaptureOutcome outcome) => '${decisionLabel(outcome.decision.name)} · ${outcome.title}';
