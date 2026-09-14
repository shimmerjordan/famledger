import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../data/repos/ai_repo.dart';

/// 对话/月报共用的月份芯片：点开选最近 12 个月。
class AiMonthChip extends StatelessWidget {
  const AiMonthChip({super.key, required this.month, required this.onChanged});

  final String month;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final now = Dates.currentMonth();
    return PopupMenuButton<String>(
      tooltip: '选择月份',
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (var i = 0; i < 12; i++)
          PopupMenuItem(
            value: Dates.shiftMonth(now, -i),
            child: Text(Dates.monthLabel(Dates.shiftMonth(now, -i))),
          ),
      ],
      child: _ChipSurface(
        icon: Icons.calendar_month_outlined,
        label: Dates.monthLabel(month),
      ),
    );
  }
}

/// AI 渠道选择：默认那个会标出来；一个都没配就引到设置页去配。
class AiProviderChip extends ConsumerWidget {
  const AiProviderChip({
    super.key,
    required this.providerId,
    required this.onChanged,
  });

  /// null = 用服务端的默认渠道。
  final String? providerId;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final providers = ref.watch(aiProvidersProvider);
    return providers.when(
      loading: () => const _ChipSurface(
        icon: Icons.smart_toy_outlined,
        label: '渠道加载中',
        muted: true,
      ),
      error: (error, _) => InkWell(
        onTap: () => context.push('/settings/ai'),
        borderRadius: BorderRadius.circular(LedgerShapes.chip),
        child: const _ChipSurface(
          icon: Icons.smart_toy_outlined,
          label: '渠道读不到',
          muted: true,
        ),
      ),
      data: (list) {
        final enabled = list.where((p) => p.enabled).toList();
        if (enabled.isEmpty) {
          return InkWell(
            onTap: () => context.push('/settings/ai'),
            borderRadius: BorderRadius.circular(LedgerShapes.chip),
            child: const _ChipSurface(
              icon: Icons.add,
              label: '先配一个 AI 渠道',
            ),
          );
        }
        final current = providerId == null
            ? defaultProviderOf(enabled)
            : enabled.where((p) => p.id == providerId).firstOrNull ??
                  defaultProviderOf(enabled);
        return PopupMenuButton<String>(
          tooltip: '选择 AI 渠道',
          onSelected: onChanged,
          itemBuilder: (context) => [
            for (final p in enabled)
              PopupMenuItem(
                value: p.id,
                child: Row(
                  children: [
                    Expanded(child: Text(p.isDefault ? '${p.name}（默认）' : p.name)),
                    if (p.id == current?.id)
                      const Icon(Icons.check, size: 18),
                  ],
                ),
              ),
          ],
          child: _ChipSurface(
            icon: Icons.smart_toy_outlined,
            label: current?.name ?? '默认渠道',
          ),
        );
      },
    );
  }
}

/// 芯片的外观（8 圆角 + 1px 边线），外面套 48dp 的点击区。
class _ChipSurface extends StatelessWidget {
  const _ChipSurface({required this.icon, required this.label, this.muted = false});

  final IconData icon;
  final String label;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = muted
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.onSurface;
    return Container(
      height: 48,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(LedgerShapes.chip),
          border: Border.all(color: theme.colorScheme.outline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            // 渠道名可能很长，宽度不够就省略号，别让整行溢出。
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(color: color),
              ),
            ),
            Icon(Icons.arrow_drop_down, size: 18, color: color),
          ],
        ),
      ),
    );
  }
}
