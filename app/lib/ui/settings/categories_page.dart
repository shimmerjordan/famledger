import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/colors.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../widgets/widgets.dart';
import 'category_form.dart';
import 'manage_widgets.dart';

/// 类别管理：支出/收入两个页签，父类别下挂子类别（只做两层）。
class CategoriesPage extends ConsumerStatefulWidget {
  const CategoriesPage({super.key});

  @override
  ConsumerState<CategoriesPage> createState() => _CategoriesPageState();
}

class _CategoriesPageState extends ConsumerState<CategoriesPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this)
    ..addListener(_onTabChanged);

  bool _reordering = false;
  String? _error;

  /// 当前页签顶级类别的本地顺序（乐观更新）。null = 用 ledger 里的顺序。
  List<String>? _order;

  void _onTabChanged() {
    if (!mounted) return;
    // 换页签时退出排序，免得把「支出」的顺序拖到「收入」上。
    setState(() {
      _reordering = false;
      _order = null;
      _error = null;
    });
  }

  @override
  void dispose() {
    _tabs
      ..removeListener(_onTabChanged)
      ..dispose();
    super.dispose();
  }

  String get _kind => _tabs.index == 0 ? 'expense' : 'income';

  /// 某个收支下在用的类别。
  static List<TxCategory> _activeOf(LedgerData data, String kind) =>
      data.categories.where((c) => c.kind == kind && !c.archived).toList();

  /// 顶级类别（父类别被归档的子类别升上来，别让它们消失）。
  static List<TxCategory> _parentsOf(List<TxCategory> active) {
    final ids = {for (final c in active) c.id};
    return active
        .where((c) => c.parentId == null || !ids.contains(c.parentId))
        .toList();
  }

  /// 当前页签要显示的顶级类别，套上本地拖动顺序。
  List<TxCategory> _orderedParents(LedgerData data, String kind) {
    final parents = _parentsOf(_activeOf(data, kind));
    final order = kind == _kind ? _order : null;
    if (order == null) return parents;
    final byId = {for (final c in parents) c.id: c};
    final out = <TxCategory>[];
    for (final id in order) {
      final category = byId.remove(id);
      if (category != null) out.add(category);
    }
    return out..addAll(byId.values);
  }

  void _onReorder(LedgerData data, int from, int to) {
    final next = [..._orderedParents(data, _kind)];
    final item = next.removeAt(from);
    next.insert(from < to ? to - 1 : to, item);
    final previous = _order;
    setState(() {
      _order = [for (final c in next) c.id];
      _error = null;
    });
    _saveOrder(data, previous);
  }

  Future<void> _saveOrder(LedgerData data, List<String>? previous) async {
    try {
      await ref.read(ledgerRepoProvider).reorder('categories', _globalOrder(data));
      if (mounted) setState(() => _order = null);
    } catch (e) {
      // repo.reorder 内部还会 sync() 一次，离线时它自己也抛 —— 一起兜住。
      if (!mounted) return;
      setState(() {
        _order = previous;
        _error = '顺序没存上：${describeError(e)}';
      });
    }
  }

  /// 全量 id，按「显示顺序」排：两个收支各自「父类别 + 它的子类别」，归档的垫底。
  ///
  /// 服务端按下标写 `sort_order`，只发当前页签的顶级 id 会和没提交的行撞号 ——
  /// 记账页那种打平的列表就会乱掉。
  List<String> _globalOrder(LedgerData data) {
    final ids = <String>[];
    final seen = <String>{};
    void add(TxCategory category) {
      if (seen.add(category.id)) ids.add(category.id);
    }

    for (final kind in const ['expense', 'income']) {
      final active = _activeOf(data, kind);
      for (final parent in _orderedParents(data, kind)) {
        add(parent);
        for (final child in active.where((c) => c.parentId == parent.id)) {
          add(child);
        }
      }
      // 兜底：任何没被上面兜到的在用类别（理论上没有）也得占个位置。
      for (final category in active) {
        add(category);
      }
    }
    for (final category in data.categories) {
      if (category.archived) add(category);
    }
    return ids;
  }

  @override
  Widget build(BuildContext context) {
    final ledger = ref.watch(ledgerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('类别'),
        actions: [
          TextButton(
            onPressed: () => setState(() => _reordering = !_reordering),
            child: Text(_reordering ? '完成' : '排序'),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [Tab(text: '支出'), Tab(text: '收入')],
        ),
      ),
      floatingActionButton: _reordering
          ? null
          : FloatingActionButton.extended(
              onPressed: () => showCategoryForm(context, kind: _kind),
              icon: const Icon(Icons.add),
              label: const Text('添加类别'),
            ),
      body: AsyncValueView<LedgerData>(
        value: ledger,
        onRetry: () => ref.read(ledgerProvider.notifier).sync(),
        data: (data) => TabBarView(
          controller: _tabs,
          children: [
            for (final kind in const ['expense', 'income'])
              _CategoryList(
                data: data,
                kind: kind,
                parents: _orderedParents(data, kind),
                reordering: _reordering && kind == _kind,
                error: _error,
                onReorder: (from, to) => _onReorder(data, from, to),
              ),
          ],
        ),
      ),
    );
  }
}

class _CategoryList extends StatelessWidget {
  const _CategoryList({
    required this.data,
    required this.kind,
    required this.parents,
    required this.reordering,
    required this.error,
    required this.onReorder,
  });

  final LedgerData data;
  final String kind;

  /// 已经排好序的顶级类别。
  final List<TxCategory> parents;
  final bool reordering;
  final String? error;
  final void Function(int from, int to) onReorder;

  @override
  Widget build(BuildContext context) {
    final all = data.categories.where((c) => c.kind == kind).toList();
    final active = all.where((c) => !c.archived).toList();
    final archived = all.where((c) => c.archived).toList();
    final indexOf = {
      for (var i = 0; i < data.categories.length; i++) data.categories[i].id: i,
    };

    if (all.isEmpty) {
      return EmptyState(
        title: kind == 'expense' ? '还没有支出类别' : '还没有收入类别',
        message: '类别决定了分析页上「钱花在什么事上」，先加一个常用的。',
        icon: Icons.local_offer_outlined,
        actionLabel: '添加类别',
        onAction: () => showCategoryForm(context, kind: kind),
      );
    }

    if (reordering) {
      return Column(
        children: [
          if (error != null) InlineError(message: error!),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              LedgerLayout.pagePadding,
              8,
              LedgerLayout.pagePadding,
              8,
            ),
            child: Text(
              '拖动调整顺序，子类别跟着父类别走。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              padding: const EdgeInsets.only(bottom: 32),
              buildDefaultDragHandles: false,
              itemCount: parents.length,
              onReorder: onReorder,
              itemBuilder: (context, index) {
                final category = parents[index];
                final children = active
                    .where((c) => c.parentId == category.id)
                    .length;
                return ListTile(
                  key: ValueKey(category.id),
                  leading: _categoryIcon(
                    context,
                    category,
                    indexOf[category.id] ?? 0,
                  ),
                  title: Text(category.name),
                  subtitle: children == 0 ? null : Text('$children 个子类别'),
                  trailing: ReorderableDragStartListener(
                    index: index,
                    child: const Padding(
                      padding: EdgeInsets.all(12),
                      child: Icon(Icons.drag_handle),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        if (error != null) InlineError(message: error!),
        for (final parent in parents) ...[
          _CategoryTile(category: parent, index: indexOf[parent.id] ?? 0),
          for (final child in active.where((c) => c.parentId == parent.id))
            _CategoryTile(
              category: child,
              index: indexOf[child.id] ?? 0,
              nested: true,
            ),
        ],
        if (archived.isNotEmpty) ...[
          const SizedBox(height: LedgerLayout.groupGap),
          const SectionHeader('已归档'),
          for (final category in archived)
            _CategoryTile(
              category: category,
              index: indexOf[category.id] ?? 0,
            ),
        ],
      ],
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.category,
    required this.index,
    this.nested = false,
  });

  final TxCategory category;
  final int index;
  final bool nested;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsetsDirectional.only(
      start: nested ? 40 : LedgerLayout.pagePadding,
      end: LedgerLayout.pagePadding,
    ),
    leading: _categoryIcon(context, category, index, size: nested ? 16 : 20),
    title: Row(
      children: [
        Flexible(child: Text(category.name, overflow: TextOverflow.ellipsis)),
        if (category.archived) ...[
          const SizedBox(width: 8),
          const ManageTag('已归档'),
        ],
      ],
    ),
    trailing: const Icon(Icons.chevron_right, size: 20),
    onTap: () => showCategoryForm(context, category: category),
  );
}

Widget _categoryIcon(
  BuildContext context,
  TxCategory category,
  int index, {
  double size = 20,
}) {
  final color =
      hexColor(category.color) ?? LedgerColors.of(context).fundColor(index);
  return CategoryIcon(
    category.icon,
    background: true,
    color: color,
    size: size,
  );
}
