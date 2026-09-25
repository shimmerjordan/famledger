import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../core/money.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../assets/asset_widgets.dart';
import 'perk_providers.dart';

// 会员权益各页共用的小零件：平台头像、金额文字、「去优酷领」徽章、领取链接按钮、可以留空的日期按钮、权益行。

/// 持有人：成员名；null = 全家共用。成员删掉了也说清楚，不冒充「全家」。
String holderLabel(LedgerData data, Membership m) {
  final id = m.memberId;
  if (id == null) return '全家共用';
  return data.member(id)?.label ?? '成员已删除';
}

/// 「去优酷领」：领取平台不是会员本平台时才有，返回平台名；是本平台返回 null。
String? claimElsewhere(LedgerData data, Benefit b, Membership m, [Benefit? parent]) {
  final id = effectiveClaimPlatformId(b, m, parent);
  if (id == m.platformId) return null;
  return platformLabel(data.platform(id));
}

/// 平台的圆底首字头像（和物品、流水的圆底图标一个样子）。
class PlatformAvatar extends StatelessWidget {
  const PlatformAvatar(this.platform, {super.key, this.muted = false, this.size = 40});

  final PerkPlatform? platform;

  /// 归档的卡退到背景里。
  final bool muted;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = muted ? theme.colorScheme.onSurfaceVariant : theme.colorScheme.primary;
    final name = platformLabel(platform);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), shape: BoxShape.circle),
      child: Text(
        // 缓存里的怪行可能没有名字：空串取 first 会抛，退成一个问号。
        name.isEmpty ? '?' : name.characters.first,
        style: theme.textTheme.titleSmall?.copyWith(color: color),
      ),
    );
  }
}

/// 金额写成的一句话（「¥88.00/年」「免费」）：正文字号，等宽数字（DESIGN.md「金额全部等宽」）。
class PerkMoneyText extends StatelessWidget {
  const PerkMoneyText(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    maxLines: 1,
    textAlign: TextAlign.right,
    style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
  );
}

/// 「去优酷领」徽章。平台名最长 40 字：放不下时省略号收尾，不撑破一行。
class ClaimBadge extends StatelessWidget {
  const ClaimBadge(this.platformName, {super.key});

  final String platformName;

  @override
  Widget build(BuildContext context) => TagLabel('去$platformName领');
}

/// 「打开领取链接」：权益填了 claimUrl 才有，点了交给外部浏览器 / 对应的 App。
class ClaimLinkButton extends ConsumerWidget {
  const ClaimLinkButton(this.url, {super.key});

  final String url;

  @override
  Widget build(BuildContext context, WidgetRef ref) => IconButton(
    tooltip: '打开领取链接',
    icon: const Icon(Icons.open_in_new),
    onPressed: () async {
      final messenger = ScaffoldMessenger.of(context);
      var opened = false;
      try {
        final uri = Uri.tryParse(url);
        if (uri != null) opened = await ref.read(perkUrlOpenerProvider)(uri);
      } catch (_) {
        opened = false;
      }
      if (!opened) messenger.showSnackBar(const SnackBar(content: Text('打不开这个链接，可以复制到浏览器里试试')));
    },
  );
}

/// 可以留空的日期：显示「不设」或日期，点开日历（允许将来），右边一个「清掉」。
class OptionalDayButton extends StatelessWidget {
  const OptionalDayButton({
    super.key,
    required this.day,
    required this.emptyLabel,
    required this.onPressed,
    required this.onClear,
  });

  final DateTime? day;
  final String emptyLabel;
  final VoidCallback onPressed;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final d = day;
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: onPressed,
            icon: const Icon(Icons.event_outlined, size: 18),
            label: Text(d == null ? emptyLabel : Dates.isoDate(d)),
          ),
        ),
        if (d != null) ...[
          const SizedBox(width: 8),
          IconButton(
            tooltip: '清掉',
            onPressed: onClear,
            icon: const Icon(Icons.close),
          ),
        ],
      ],
    );
  }
}

/// 一项权益：名字、「去优酷领」、类型 · 额度；N 选 1 下面一排选项。点开编辑。
///
/// [detailed] 为真（会员详情）时再写领取路径、有效期、面值、限制条件、它带出的派生会员和备注，
/// 填了领取链接的右边有「打开领取链接」。
class BenefitTile extends StatelessWidget {
  const BenefitTile({
    super.key,
    required this.data,
    required this.node,
    required this.membership,
    this.detailed = false,
    this.indent = LedgerLayout.pagePadding,
  });

  final LedgerData data;
  final BenefitNode node;
  final Membership membership;
  final bool detailed;
  final double indent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = node.benefit;
    final elsewhere = b.isChoice ? null : claimElsewhere(data, b, membership);
    final lines = <String>[
      b.isChoice ? 'N 选 1 · ${quotaLabel(b.quota)}' : '${b.kindLabel} · ${quotaLabel(b.quota)}',
      if (detailed) ..._details(b),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          key: ValueKey('benefit-${b.id}'),
          // 权益行挂在卡下面，比卡那一行紧一点；两行字的高度仍然 ≥ 48dp。
          visualDensity: VisualDensity.compact,
          contentPadding: EdgeInsets.only(left: indent, right: LedgerLayout.pagePadding),
          onTap: () => context.push('/assets/benefits/${b.id}/edit'),
          // 名字和徽章排不下一行时徽章折到下一行（平台名长、长辈调大字号），两样都不会被挤没。
          title: Wrap(
            spacing: 6,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(b.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyLarge),
              if (elsewhere != null) ClaimBadge(elsewhere, key: ValueKey('claim-badge-${b.id}')),
            ],
          ),
          subtitle: Text(lines.join('\n'), style: theme.textTheme.bodySmall),
          trailing: detailed && b.claimUrl != null ? ClaimLinkButton(b.claimUrl!, key: ValueKey('claim-link-${b.id}')) : null,
        ),
        if (detailed && b.limits.isNotEmpty)
          Padding(
            padding: EdgeInsets.fromLTRB(indent, 0, LedgerLayout.pagePadding, 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [for (final l in b.limits) TagLabel('${l.typeLabel} ${l.text}')],
            ),
          ),
        if (b.isChoice)
          Padding(
            padding: EdgeInsets.fromLTRB(indent, 0, LedgerLayout.pagePadding, 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final o in node.options)
                  ActionChip(
                    key: ValueKey('benefit-option-${o.id}'),
                    onPressed: () => context.push('/assets/benefits/${o.id}/edit'),
                    label: Text(_optionLabel(o, b)),
                  ),
                if (node.options.isEmpty) Text('还没有选项', style: theme.textTheme.bodySmall),
              ],
            ),
          ),
      ],
    );
  }

  String _optionLabel(Benefit o, Benefit parent) {
    final where = claimElsewhere(data, o, membership, parent);
    return where == null ? o.name : '${o.name} · 去$where领';
  }

  List<String> _details(Benefit b) {
    final value = [
      if (b.faceValueCents != null) '面值 ${Money.format(b.faceValueCents!)}',
      if (b.myValueCents != null) '我估 ${Money.format(b.myValueCents!)}',
    ];
    final window = switch ((b.validFrom, b.validUntil)) {
      (null, null) => null,
      (final from?, null) => '有效期 $from 起',
      (null, final until?) => '有效期至 $until',
      (final from?, final until?) => '有效期 $from 至 $until',
    };
    final derived = [
      for (final m in data.memberships)
        if (m.sourceBenefitId == b.id) '${platformLabel(data.platform(m.platformId))} · ${m.title}',
    ];
    return [
      if (b.claimHow != null) '领取：${b.claimHow}',
      ?window,
      if (value.isNotEmpty) value.join(' · '),
      if (derived.isNotEmpty) '已带出：${derived.join('、')}',
      if (b.note != null) b.note!,
    ];
  }
}
