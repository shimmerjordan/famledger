import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/shell.dart';
import '../../app/theme.dart';
import '../../app/theme_mode.dart';
import '../../core/colors.dart';
import '../assets/asset_widgets.dart' show DetailPane;
import '../widgets/widgets.dart';
import 'about_page.dart';
import 'ai_providers_page.dart';
import 'backup_page.dart';
import 'budgets_page.dart';
import 'capture_page.dart';
import 'categories_page.dart';
import 'members_page.dart';
import '../funds/funds_page.dart';
import 'rules_page.dart';
import 'server_page.dart';

/// 「我的」：一组一组的入口。手机上点进子页；≥ 840 宽时左边是入口列表、右边直接嵌着选中的子页
/// （[selectedSettingsProvider]），右半屏不再空着。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final me = ref.watch(sessionProvider)?.me;
    final household = ref.watch(settingsProvider).valueOrNull?.name;
    final wide = widthClassOf(context) == WidthClass.expanded;
    final selected = wide ? ref.watch(selectedSettingsProvider) : null;

    final children = <Widget>[
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
        // 账户、会员提醒挪进了资产 tab（净资产明细里的「管理账户」、会员权益的「更多」菜单），
        // 导入账单只留账单页右上角那一个入口。
        _Group('家庭', [
          _Entry(Icons.people_outline, '成员', '/settings/members', selected: selected),
          _Entry(Icons.savings_outlined, '基金', '/funds', selected: selected),
          _Entry(Icons.local_offer_outlined, '类别', '/settings/categories', selected: selected),
          _Entry(Icons.pie_chart_outline, '预算', '/settings/budgets', selected: selected),
        ]),
        _Group('自动记账', [
          _Entry(Icons.auto_awesome_outlined, '自动记账', '/settings/capture', selected: selected),
          _Entry(Icons.rule_outlined, '识别规则', '/settings/rules', selected: selected),
        ]),
        _Group('智能与数据', [
          _Entry(Icons.smart_toy_outlined, 'AI 渠道', '/settings/ai', selected: selected),
          _Entry(Icons.backup_outlined, '备份与恢复', '/settings/backup', selected: selected),
        ]),
        const _Group('外观', [_ThemeRow()]),
        _Group('其他', [
          _Entry(Icons.dns_outlined, '服务器与账号', '/settings/server', selected: selected),
          _Entry(Icons.info_outline, '关于', '/settings/about', selected: selected),
        ]),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('我的'), actions: const [ThemeModeButton()]),
      body: wide
          ? Row(
              children: [
                SizedBox(
                  width: 320,
                  child: ListView(padding: const EdgeInsets.only(bottom: 32, left: 8), children: children),
                ),
                VerticalDivider(width: 1, color: theme.colorScheme.outlineVariant),
                Expanded(
                  key: const ValueKey('settings-pane'),
                  child: DetailPane(child: settingsPageFor(selected!)),
                ),
              ],
            )
          : ReadableListView(padding: const EdgeInsets.only(bottom: 32), children: children),
    );
  }
}

/// 宽屏右栏正在看的子页（路由路径）。默认「成员」。
final selectedSettingsProvider = StateProvider<String>((ref) => '/settings/members');

/// 路由路径 → 子页（和 app/router.dart 里的一一对应，这里只是不经路由直接嵌进右栏）。
Widget settingsPageFor(String path) => switch (path) {
  '/funds' => const FundsPage(),
  '/settings/categories' => const CategoriesPage(),
  '/settings/budgets' => const BudgetsPage(),
  '/settings/capture' => const CapturePage(),
  '/settings/rules' => const RulesPage(),
  '/settings/ai' => const AiProvidersPage(),
  '/settings/backup' => const BackupPage(),
  '/settings/server' => const ServerPage(),
  '/settings/about' => const AboutPage(),
  _ => const MembersPage(),
};

/// 外观：跟随系统 / 浅色 / 深色。手机顶栏放不下那个按钮，这一行所有宽度都有。
class _ThemeRow extends ConsumerWidget {
  const _ThemeRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final theme = Theme.of(context);
    // 分段按钮单独占一行、撑满：宽屏左栏只有 320，和图标挤一行「跟随系统」会折行。
    return Padding(
      padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 4, LedgerLayout.pagePadding, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.contrast_outlined, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 16),
              Text('外观', style: theme.textTheme.bodyLarge),
            ],
          ),
          const SizedBox(height: 8),
          SegmentedButton<ThemeMode>(
            key: const ValueKey('theme-mode-row'),
            showSelectedIcon: false,
            expandedInsets: EdgeInsets.zero,
            segments: [
              for (final m in ThemeMode.values) ButtonSegment(value: m, label: Text(themeModeLabel(m))),
            ],
            selected: {mode},
            onSelectionChanged: (s) => ref.read(themeModeProvider.notifier).set(s.first),
          ),
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
  final List<Widget> entries;

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

class _Entry extends ConsumerWidget {
  const _Entry(this.icon, this.label, this.path, {this.selected});

  final IconData icon;
  final String label;
  final String path;

  /// 宽屏：右栏当前嵌着哪个子页（null = 手机，点了整页打开）。
  final String? selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wide = selected != null;
    return ListTile(
      key: ValueKey('settings-entry-$path'),
      leading: Icon(icon),
      title: Text(label),
      selected: wide && selected == path,
      trailing: wide ? null : const Icon(Icons.chevron_right, size: 20),
      onTap: wide
          ? () => ref.read(selectedSettingsProvider.notifier).state = path
          : () => context.push(path),
    );
  }
}
