import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/money.dart';
import '../../data/models/models.dart';

// 回本条（spec §3「回本」、§5「会员行上带到期进度和回本条（叠加时间进度刻度）」）：会员行和会员详情共用。

/// 「已回本 62% · ¥55.00 / ¥88.00」；免费的卡是「免费 · 已享 ¥55.00」。
String paybackHeadline(PerkPayback p) => p.free
    ? '免费 · 已享 ${Money.format(p.realizedCents)}'
    : '已回本 ${(p.ratioBp! / 100).round()}% · ${Money.format(p.realizedCents)} / ${Money.format(p.costCents)}';

/// 「时间已过 70%」；缺本期开始或到期日时没有。
String? paybackTimeLabel(PerkPayback p) {
  final t = p.timeProgress;
  return t == null ? null : '时间已过 ${(t * 100).round()}%';
}

/// 值得画出来：花了钱，或者免费但已经享受到了。
bool paybackWorthShowing(PerkPayback p) => p.costCents > 0 || p.realizedCents > 0;

/// 会员行上要不要画这根条：回本值得画，或者至少知道本期过了几成（免费、没填费用的卡也有到期进度）。
bool paybackBarShown(PerkPayback p) => paybackWorthShowing(p) || p.timeProgress != null;

/// 一行字 + 一根条：填充 = 已回本几成（超过 100% 画满），竖刻度 = 时间过了几成。
/// 免费的卡没有回本比例，条是空的、只画时间刻度；没花钱也还没享受到（多半是没填费用）的只写「时间已过 N%」。
class PaybackBar extends StatelessWidget {
  const PaybackBar(this.payback, {super.key});

  final PerkPayback payback;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = LedgerColors.of(context);
    final head = paybackWorthShowing(payback) ? paybackHeadline(payback) : null;
    final time = paybackTimeLabel(payback);
    final ratio = payback.ratioBp == null ? null : (payback.ratioBp! / 10000).clamp(0.0, 1.0);
    final t = payback.timeProgress;
    final small = theme.textTheme.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    return Semantics(
      label: [?head, ?time].join('，'),
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: 8,
            children: [
              if (head != null) Text(head, style: small),
              if (time != null) Text(time, style: small?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
          if (ratio != null || t != null) ...[
            const SizedBox(height: 4),
            SizedBox(
              height: 10,
              child: LayoutBuilder(
                builder: (context, box) => Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 2,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: ratio ?? 0,
                          minHeight: 6,
                          backgroundColor: colors.surface3,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                    if (t != null)
                      Positioned(
                        key: const ValueKey('payback-time-tick'),
                        left: (box.maxWidth * t - 1).clamp(0.0, box.maxWidth - 2),
                        top: 0,
                        bottom: 0,
                        child: Container(width: 2, color: theme.colorScheme.onSurface),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
