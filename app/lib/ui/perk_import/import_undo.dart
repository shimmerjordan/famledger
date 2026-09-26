import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../data/api/api_client.dart';
import '../../data/models/models.dart';
import '../widgets/widgets.dart';

// 整批撤销一次 AI 导入（spec §4 `POST /asset-import/:id/undo`）的公共部分：确认框、撤完之后的说明、出错时的一句话。
// 两个入口共用：导入结果页的「撤销本次导入」（perk_import_preview_page.dart）和「最近的 AI 导入」（recent_imports_page.dart）。

const Map<String, (String, String)> _units = {
  'platforms': ('平台', '个'),
  'memberships': ('会员卡', '张'),
  'benefits': ('权益', '项'),
  'items': ('物品', '件'),
};

/// 「平台 5 个、会员卡 1 张、权益 7 项」这种一行（0 的不写）；都是 0 回空串。
String importCountLine(Map<String, int> counts) => [
  for (final e in _units.entries)
    if ((counts[e.key] ?? 0) > 0) '${e.value.$1} ${counts[e.key]} ${e.value.$2}',
].join('、');

/// 先问一句再撤（确认按钮是 error 色）。点「撤销」回 true。
Future<bool> confirmImportUndo(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('撤销这次导入？'),
      content: const Text('这次新建的会删掉（随物品记的支出一起），更新过的改回导入前的样子。导入之后你又改过的、还在用的不动。'),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('不撤了')),
        FilledButton(
          key: const ValueKey('perk-import-undo-confirm'),
          style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('撤销'),
        ),
      ],
    ),
  );
  return ok == true;
}

/// 撤销失败时的一句话（过期、回应丢了各有说法）。
String describeUndoError(Object e) => switch (e) {
  ApiException(code: 'undo_expired') => '导入超过 7 天了，不能整批撤销；去对应的卡、物品里逐条改。',
  ApiException(isNetwork: true, maybeSent: true) => '没等到服务器回应，不确定撤掉没有。再点一次也不会多撤。',
  _ => describeError(e),
};

/// 撤完之后：删了什么、随物品记的支出、打过的卡、改回了什么、去掉的别名；没动的（导入后改过或删了的、还被别的数据用着的）
/// 逐条说原因。标题和按钮由调用方放。
class ImportUndoSummary extends StatelessWidget {
  const ImportUndoSummary({super.key, required this.undone});

  final PerkImportUndoResult undone;

  static const Map<String, String> _inUseReason = {
    'sold': '卖出时记过收入，留着了（买它时记的那笔支出也留着）',
    'has_options': '下面还有你后来加的选项，留着了',
    'has_benefits': '下面还有你后来加的权益，留着了',
    'in_use': '还有卡挂在它下面，或者有权益要去它那领，留着了',
    'choice_in_use': '下面还有你后来加的选项，还是「N 选 1」，没改回去',
  };

  static String _names(Iterable<Map<String, dynamic>> rows) => rows.map((r) => '「${jsonString(r['name'], '一项')}」').join('');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final removed = importCountLine(undone.undone);
    final restored = importCountLine(undone.restored);
    final changed = [
      for (final r in undone.skippedChanged)
        if (!jsonBool(r['deleted'])) r,
    ];
    final deleted = [
      for (final r in undone.skippedChanged)
        if (jsonBool(r['deleted'])) r,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(removed.isEmpty ? '没有要删的' : '删掉：$removed', key: const ValueKey('perk-import-undone-removed'), style: theme.textTheme.bodyLarge),
        if (undone.undoneOf('transactions') > 0) Text('随物品记的 ${undone.undoneOf('transactions')} 笔支出一起删了', style: theme.textTheme.bodyMedium),
        if (undone.undoneOf('events') > 0) Text('导入的权益上打过的 ${undone.undoneOf('events')} 次卡也一起删了', style: theme.textTheme.bodyMedium),
        if (restored.isNotEmpty) Text('改回导入前：$restored', style: theme.textTheme.bodyLarge),
        if (undone.aliasesRemoved > 0) Text('去掉了导入时加的 ${undone.aliasesRemoved} 个平台别名', style: theme.textTheme.bodyMedium),
        if (changed.isNotEmpty)
          ImportNote(
            '${_names(changed)}导入之后又改过，没动${changed.length > 1 ? '这几项' : '它'}；要改回去请自己改。',
            key: const ValueKey('perk-import-undone-changed'),
          ),
        if (deleted.isNotEmpty)
          ImportNote(
            '${_names(deleted)}导入之后已经被删了，没法改回去。',
            key: const ValueKey('perk-import-undone-deleted'),
          ),
        for (final row in undone.skippedInUse)
          ImportNote('「${jsonString(row['name'])}」${_inUseReason[jsonString(row['reason'])] ?? '还在用，留着了'}。'),
      ],
    );
  }
}

/// 要人留意的一句话：警告色的小图标 + 正文色的字（警告色当字色对比度不够，长辈看不清）。
class ImportNote extends StatelessWidget {
  const ImportNote(this.text, {super.key, this.icon = Icons.info_outline, this.padding = const EdgeInsets.only(top: 8)});

  final String text;
  final IconData icon;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 18, color: LedgerColors.of(context).warning),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
