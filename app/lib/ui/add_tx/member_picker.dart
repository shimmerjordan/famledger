import 'package:flutter/material.dart';

import '../../core/colors.dart';
import '../../data/models/models.dart';

/// 成员芯片：这笔是「谁的行为」。
class MemberPicker extends StatelessWidget {
  const MemberPicker({
    super.key,
    required this.members,
    required this.selectedId,
    required this.onSelected,
  });

  final List<Member> members;
  final String? selectedId;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (members.isEmpty) {
      return Text('还没有成员', style: theme.textTheme.bodySmall);
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final member in members)
          ChoiceChip(
            key: ValueKey('member-${member.id}'),
            selected: member.id == selectedId,
            onSelected: (_) => onSelected(member.id),
            label: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (member.avatarEmoji != null) ...[
                  Text(member.avatarEmoji!, style: theme.textTheme.bodySmall),
                  const SizedBox(width: 6),
                ] else ...[
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: hexColor(member.color) ?? theme.colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Text(member.label),
              ],
            ),
          ),
      ],
    );
  }
}
