import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/colors.dart';

/// 「我的」：一组一组的入口，真正的内容在各子页里。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final me = ref.watch(sessionProvider)?.me;
    final household = ref.watch(settingsProvider).valueOrNull?.name;

    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _Profile(
            name: me?.label ?? '未登录',
            subtitle: [
              if (household != null && household.isNotEmpty) household,
              if (me != null) '@${me.username}',
              if (me?.isAdmin ?? false) '管理员',
            ].join(' · '),
            emoji: me?.avatarEmoji,
            color: hexColor(me?.color) ?? theme.colorScheme.primary,
          ),
          const _Group('家庭', [
            _Entry(Icons.people_outline, '成员', '/settings/members'),
            _Entry(Icons.account_balance_wallet_outlined, '账户', '/settings/accounts'),
            _Entry(Icons.local_offer_outlined, '类别', '/settings/categories'),
            _Entry(Icons.pie_chart_outline, '预算', '/settings/budgets'),
          ]),
          const _Group('自动记账', [
            _Entry(Icons.auto_awesome_outlined, '自动记账', '/settings/capture'),
            _Entry(Icons.rule_outlined, '识别规则', '/settings/rules'),
          ]),
          const _Group('智能与数据', [
            _Entry(Icons.smart_toy_outlined, 'AI 渠道', '/settings/ai'),
            _Entry(Icons.backup_outlined, '备份与恢复', '/settings/backup'),
          ]),
          const _Group('其他', [
            _Entry(Icons.dns_outlined, '服务器与账号', '/settings/server'),
            _Entry(Icons.info_outline, '关于', '/settings/about'),
          ]),
        ],
      ),
    );
  }
}

class _Profile extends StatelessWidget {
  const _Profile({
    required this.name,
    required this.subtitle,
    required this.color,
    this.emoji,
  });

  final String name;
  final String subtitle;
  final Color color;
  final String? emoji;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LedgerLayout.pagePadding,
        8,
        LedgerLayout.pagePadding,
        LedgerLayout.groupGap,
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.16),
              shape: BoxShape.circle,
            ),
            child: Text(
              emoji ?? (name.isEmpty ? '?' : name.characters.first),
              style: theme.textTheme.titleMedium,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: theme.textTheme.titleMedium),
                if (subtitle.isNotEmpty)
                  Text(subtitle, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group(this.title, this.entries);

  final String title;
  final List<_Entry> entries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 0, 16, 8),
          child: Text(
            title,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        ...entries,
        const SizedBox(height: LedgerLayout.groupGap),
      ],
    );
  }
}

class _Entry extends StatelessWidget {
  const _Entry(this.icon, this.label, this.path);

  final IconData icon;
  final String label;
  final String path;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon),
    title: Text(label),
    trailing: const Icon(Icons.chevron_right, size: 20),
    onTap: () => context.push(path),
  );
}
