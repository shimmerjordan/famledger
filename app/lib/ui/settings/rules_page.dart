import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../widgets/widgets.dart';
import 'rule_form.dart';

/// 识别规则：自动记账命中关键字就把类别/基金/账户/成员填好。按优先级从高到低。
class RulesPage extends ConsumerStatefulWidget {
  const RulesPage({super.key});

  @override
  ConsumerState<RulesPage> createState() => _RulesPageState();
}

class _RulesPageState extends ConsumerState<RulesPage> {
  String? _error;

  Future<void> _toggle(Rule rule, bool enabled) async {
    setState(() => _error = null);
    try {
      await ref.read(ledgerRepoProvider).updateRule(rule.id, {
        'enabled': enabled,
      });
    } catch (e) {
      if (mounted) setState(() => _error = '没改成：${describeError(e)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final ledger = ref.watch(ledgerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('识别规则')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showRuleForm(context),
        icon: const Icon(Icons.add),
        label: const Text('添加规则'),
      ),
      body: AsyncValueView<LedgerData>(
        value: ledger,
        onRetry: () => ref.read(ledgerProvider.notifier).sync(),
        data: (data) {
          if (data.rules.isEmpty) {
            return EmptyState(
              title: '还没有识别规则',
              message: '比如「商户 包含 星巴克 → 餐饮 · 我的零花」，以后这类通知就自动归好类。',
              icon: Icons.rule_outlined,
              actionLabel: '添加规则',
              onAction: () => showRuleForm(context),
            );
          }
          final error = _error;
          return ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              if (error != null) InlineError(message: error),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  LedgerLayout.pagePadding,
                  8,
                  LedgerLayout.pagePadding,
                  8,
                ),
                child: Text(
                  '从上往下比，先命中的说了算。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              for (final rule in data.rules)
                _RuleTile(
                  rule: rule,
                  targets: _targets(data, rule),
                  onToggle: (value) => _toggle(rule, value),
                  onTap: () => showRuleForm(context, rule: rule),
                ),
            ],
          );
        },
      ),
    );
  }

  /// 「→ 餐饮 · 家庭公共 · 妈妈」
  String _targets(LedgerData data, Rule rule) {
    final parts = [
      data.category(rule.categoryId)?.name,
      data.fund(rule.fundId)?.name,
      data.account(rule.accountId)?.name,
      data.member(rule.memberId)?.label,
    ].whereType<String>().toList();
    return parts.isEmpty ? '没指定要填什么' : parts.join(' · ');
  }
}

class _RuleTile extends StatelessWidget {
  const _RuleTile({
    required this.rule,
    required this.targets,
    required this.onToggle,
    required this.onTap,
  });

  final Rule rule;
  final String targets;
  final ValueChanged<bool> onToggle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      onTap: onTap,
      title: Opacity(
        opacity: rule.enabled ? 1 : 0.5,
        child: Text(
          '${rule.fieldLabel} ${rule.opLabel} ${rule.pattern}',
          overflow: TextOverflow.ellipsis,
        ),
      ),
      subtitle: Opacity(
        opacity: rule.enabled ? 1 : 0.5,
        child: Text(
          '→ $targets　·　优先级 ${rule.priority}',
          style: theme.textTheme.bodySmall,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      trailing: Switch(
        value: rule.enabled,
        onChanged: onToggle,
      ),
    );
  }
}
