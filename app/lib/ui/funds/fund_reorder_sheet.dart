import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../widgets/widgets.dart';

/// 板块排序：拖动换位置，松手就存（首页卡片、记账时的板块芯片都按这个顺序）。
Future<void> showFundReorderSheet(BuildContext context) => showModalBottomSheet<void>(
  useRootNavigator: true,
  context: context,
  isScrollControlled: true,
  builder: (context) => const _FundReorderSheet(),
);

class _FundReorderSheet extends ConsumerStatefulWidget {
  const _FundReorderSheet();

  @override
  ConsumerState<_FundReorderSheet> createState() => _FundReorderSheetState();
}

class _FundReorderSheetState extends ConsumerState<_FundReorderSheet> {
  /// 拖过之后、服务端还没回来时的顺序（先按它画，免得列表跳回去）。
  List<String>? _order;
  String? _error;

  List<Fund> _ordered(LedgerData data) {
    final active = data.activeFunds;
    final order = _order;
    if (order == null) return active;
    final byId = {for (final f in active) f.id: f};
    return [
      for (final id in order)
        if (byId.remove(id) case final f?) f,
      ...byId.values,
    ];
  }

  Future<void> _onReorder(LedgerData data, int from, int to) async {
    final next = [..._ordered(data)];
    final item = next.removeAt(from);
    next.insert(from < to ? to - 1 : to, item);
    final previous = _order;
    setState(() {
      _order = [for (final f in next) f.id];
      _error = null;
    });
    // 发全量（归档的接在后面）：只发一部分会和没动过的行撞号。
    final ids = [
      for (final f in next) f.id,
      for (final f in data.funds)
        if (f.archived) f.id,
    ];
    try {
      await ref.read(ledgerRepoProvider).reorder('funds', ids);
      if (mounted) setState(() => _order = null);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _order = previous;
        _error = '顺序没存上：${describeError(e)}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final data = ref.watch(ledgerProvider).valueOrNull;
    final funds = data == null ? const <Fund>[] : _ordered(data);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SectionHeader('板块排序'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
              child: Text('按住右边的把手拖动，松手就存。', style: theme.textTheme.bodySmall),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 8, LedgerLayout.pagePadding, 0),
                child: Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
              ),
            Flexible(
              child: ReorderableListView.builder(
                shrinkWrap: true,
                buildDefaultDragHandles: false,
                itemCount: funds.length,
                onReorder: (from, to) => _onReorder(data!, from, to),
                itemBuilder: (context, i) {
                  final f = funds[i];
                  return ListTile(
                    key: ValueKey('fund-order-${f.id}'),
                    leading: FundDot(color: fundColorOf(context, f, i), size: 10),
                    title: Text(f.name),
                    trailing: ReorderableDragStartListener(
                      index: i,
                      child: const Icon(Icons.drag_handle),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: LedgerLayout.itemGap),
          ],
        ),
      ),
    );
  }
}
