import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/colors.dart';
import '../../data/models/models.dart';
import '../widgets/widgets.dart';
import 'fund_providers.dart';

/// 新建基金先挑个模板：家庭公共、养老储备、育儿……
///
/// 返回选中的模板；「从空白开始」返回一个只有名字为空的 [Fund]。
Future<Fund?> showFundTemplateSheet(BuildContext context) =>
    showModalBottomSheet<Fund>(
      context: context,
      isScrollControlled: true,
      builder: (context) => const _FundTemplateSheet(),
    );

class _FundTemplateSheet extends ConsumerWidget {
  const _FundTemplateSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final templates = ref.watch(fundTemplatesProvider);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SectionHeader('从模板新建'),
            Flexible(
              child: AsyncValueView<List<Fund>>(
                value: templates,
                loading: const SkeletonList(rows: 4),
                onRetry: () => ref.invalidate(fundTemplatesProvider),
                data: (items) => ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: [
                    for (final template in items)
                      _TemplateTile(template: template),
                    const Divider(height: 24),
                    ListTile(
                      leading: const CategoryIcon('more_horiz', background: true),
                      title: const Text('从空白开始'),
                      subtitle: const Text('自己起名字、挑颜色'),
                      onTap: () => Navigator.of(context).pop(
                        const Fund(id: '', name: ''),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: LedgerLayout.itemGap),
          ],
        ),
      ),
    );
  }
}

class _TemplateTile extends StatelessWidget {
  const _TemplateTile({required this.template});

  final Fund template;

  @override
  Widget build(BuildContext context) {
    final color = hexColor(template.color) ?? Theme.of(context).colorScheme.primary;
    return ListTile(
      leading: CategoryIcon(template.icon, background: true, color: color),
      title: Text(template.name),
      subtitle: template.description == null
          ? null
          : Text(
              template.description!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
      onTap: () => Navigator.of(context).pop(template),
    );
  }
}
