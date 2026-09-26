import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/models/models.dart';
import '../assets/asset_widgets.dart' show readableInsets;
import '../widgets/widgets.dart';
import 'import_undo.dart';
import 'perk_import_providers.dart';

/// 7 天内导入了、还没撤销的（`GET /asset-import/recent`）：本人的；管理员看全家的。
final recentImportsProvider = FutureProvider.autoDispose<List<RecentImport>>(
  (ref) => ref.watch(assetImportRepoProvider).recent(),
);

/// 「最近的 AI 导入」（`/assets/import/recent`，会员权益 tab 和物品 tab 的溢出菜单进来）：spec §1「7 天内可以整批撤销」
/// 的入口 —— 离开导入结果页之后也撤得了。一次导入一段：什么时候、截图还是粘贴、新建和更新了什么、还能撤几天
/// （管理员看到家里人的，写明是谁导的）；「撤销这次导入」确认后原地换成撤了什么、哪些没动（和结果页同一套，import_undo.dart）。
class RecentImportsPage extends ConsumerStatefulWidget {
  const RecentImportsPage({super.key});

  @override
  ConsumerState<RecentImportsPage> createState() => _RecentImportsPageState();
}

class _RecentImportsPageState extends ConsumerState<RecentImportsPage> {
  /// 这一页里撤过的（结果留在原地，不重新拉列表）、正在撤的、撤失败的原因。
  final Map<String, PerkImportUndoResult> _undone = {};
  final Set<String> _busy = {};
  final Map<String, String> _errors = {};

  Future<void> _undo(RecentImport item) async {
    if (!await confirmImportUndo(context) || !mounted) return;
    setState(() {
      _busy.add(item.importId);
      _errors.remove(item.importId);
    });
    try {
      final undone = await ref.read(assetImportRepoProvider).undo(item.importId);
      if (!mounted) return;
      setState(() {
        _busy.remove(item.importId);
        _undone[item.importId] = undone;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy.remove(item.importId);
        _errors[item.importId] = describeUndoError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final imports = ref.watch(recentImportsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('最近的 AI 导入')),
      body: LayoutBuilder(
        builder: (context, box) => AsyncValueView<List<RecentImport>>(
          value: imports,
          onRetry: () => ref.invalidate(recentImportsProvider),
          data: (items) => items.isEmpty ? _empty(context) : _list(context, items, box.maxWidth),
        ),
      ),
    );
  }

  Widget _empty(BuildContext context) => EmptyState(
    key: const ValueKey('recent-imports-empty'),
    icon: Icons.history,
    title: '7 天内没有能撤销的导入',
    message: '用智能导入导进来的，7 天内都能在这里整批撤销',
    actionLabel: '去智能导入',
    onAction: () => context.push('/assets/import'),
  );

  Widget _list(BuildContext context, List<RecentImport> items, double width) {
    final theme = Theme.of(context);
    final isAdmin = ref.watch(sessionProvider)?.me.isAdmin ?? false;
    return ListView(
      padding: readableInsets(width, maxWidth: 720).copyWith(bottom: 32),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, LedgerLayout.itemGap, LedgerLayout.pagePadding, 4),
          child: Text(
            isAdmin ? '家里 7 天内导进来的都在这。撤销一次：新建的删掉，更新过的改回导入前的样子。' : '你 7 天内导进来的都在这。撤销一次：新建的删掉，更新过的改回导入前的样子。',
            style: theme.textTheme.bodySmall,
          ),
        ),
        for (final item in items) ...[
          _row(context, item),
          Divider(height: 1, color: theme.colorScheme.outlineVariant),
        ],
      ],
    );
  }

  static String _when(DateTime? at) {
    if (at == null) return '';
    final t = at.toLocal();
    return '${t.month} 月 ${t.day} 日 ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  Widget _row(BuildContext context, RecentImport item) {
    final theme = Theme.of(context);
    final created = importCountLine(item.created);
    final updated = importCountLine(item.updated);
    final undone = _undone[item.importId];
    final busy = _busy.contains(item.importId);
    final error = _errors[item.importId];
    final meta = [
      if (undone == null) '还能撤 ${item.daysLeft} 天',
      if (!item.mine && item.memberName != null) '${item.memberName}导入的',
    ].join(' · ');
    return Padding(
      key: ValueKey('recent-import-${item.importId}'),
      padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, LedgerLayout.itemGap, LedgerLayout.pagePadding, LedgerLayout.itemGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_when(item.appliedAt)} · ${item.sourceKind == 'image' ? '截图' : '粘贴'}导入',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(created.isEmpty ? '没有新建的' : '新建：$created', style: theme.textTheme.bodyMedium),
          if (updated.isNotEmpty) Text('更新：$updated', style: theme.textTheme.bodyMedium),
          if ((item.created['transactions'] ?? 0) > 0)
            Text('同时记了 ${item.created['transactions']} 笔支出', style: theme.textTheme.bodyMedium),
          if (meta.isNotEmpty) Text(meta, style: theme.textTheme.bodySmall),
          if (undone != null) ...[
            const SizedBox(height: LedgerLayout.itemGap),
            Text('已撤销', key: ValueKey('recent-undone-${item.importId}'), style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            ImportUndoSummary(undone: undone),
          ] else ...[
            if (error != null)
              InlineError(key: ValueKey('recent-undo-error-${item.importId}'), message: error, padding: const EdgeInsets.only(top: 8)),
            const SizedBox(height: 4),
            TextButton(
              key: ValueKey('recent-undo-${item.importId}'),
              onPressed: busy ? null : () => _undo(item),
              style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error, padding: EdgeInsets.zero),
              child: Text(busy ? '正在撤销…' : '撤销这次导入'),
            ),
          ],
        ],
      ),
    );
  }
}
