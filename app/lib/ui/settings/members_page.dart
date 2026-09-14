import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../widgets/widgets.dart';
import 'manage_widgets.dart';
import 'member_form.dart';

/// 成员管理：谁在这本账里、谁是管理员。写操作只有管理员看得见。
class MembersPage extends ConsumerWidget {
  const MembersPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final me = ref.watch(sessionProvider)?.me;
    final isAdmin = me?.isAdmin ?? false;
    final ledger = ref.watch(ledgerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('成员')),
      floatingActionButton: isAdmin
          ? FloatingActionButton.extended(
              onPressed: () => showMemberForm(context),
              icon: const Icon(Icons.person_add_alt),
              label: const Text('添加成员'),
            )
          : null,
      body: AsyncValueView<LedgerData>(
        value: ledger,
        onRetry: () => ref.read(ledgerProvider.notifier).sync(),
        data: (data) {
          final active = data.members.where((m) => !m.archived).toList();
          final archived = data.members.where((m) => m.archived).toList();
          if (data.members.isEmpty) {
            return EmptyState(
              title: '还没有成员',
              message: isAdmin ? '把家人加进来，每笔账才知道是谁记的。' : '等管理员把家人加进来。',
              icon: Icons.people_outline,
              actionLabel: isAdmin ? '添加成员' : null,
              onAction: isAdmin ? () => showMemberForm(context) : null,
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              for (final member in active)
                _MemberTile(
                  member: member,
                  isSelf: member.id == me?.id,
                  canEdit: isAdmin,
                ),
              if (archived.isNotEmpty) ...[
                const SizedBox(height: LedgerLayout.groupGap),
                const SectionHeader('已归档'),
                for (final member in archived)
                  _MemberTile(
                    member: member,
                    isSelf: member.id == me?.id,
                    canEdit: isAdmin,
                  ),
              ],
              const SizedBox(height: LedgerLayout.groupGap),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: LedgerLayout.pagePadding,
                ),
                child: Text(
                  isAdmin
                      ? '归档的成员不能再登录，TA 名下的流水与统计都保留。'
                      : '只有管理员能添加成员、改角色或重置密码。',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({
    required this.member,
    required this.isSelf,
    required this.canEdit,
  });

  final Member member;
  final bool isSelf;
  final bool canEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: memberAvatar(member),
      title: Row(
        children: [
          Flexible(child: Text(member.label, overflow: TextOverflow.ellipsis)),
          if (isSelf) ...[const SizedBox(width: 8), const ManageTag('你')],
          if (member.archived) ...[
            const SizedBox(width: 8),
            const ManageTag('已归档'),
          ],
        ],
      ),
      subtitle: Text(
        '@${member.username} · ${member.isAdmin ? '管理员' : '成员'}',
        style: theme.textTheme.bodySmall,
      ),
      trailing: canEdit ? const Icon(Icons.chevron_right, size: 20) : null,
      onTap: canEdit ? () => showMemberForm(context, member: member) : null,
    );
  }
}
