import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/colors.dart';
import '../../data/models/models.dart';
import '../widgets/widgets.dart';
import 'manage_widgets.dart';

/// 新建/编辑类别。[kind] 是新建时所在的那个页签（支出/收入）。
Future<void> showCategoryForm(
  BuildContext context, {
  TxCategory? category,
  String kind = 'expense',
  String? parentId,
}) => showManageSheet<void>(
  context,
  (context) => CategoryFormSheet(
    category: category,
    kind: category?.kind ?? kind,
    parentId: category?.parentId ?? parentId,
  ),
);

class CategoryFormSheet extends ConsumerStatefulWidget {
  const CategoryFormSheet({
    super.key,
    this.category,
    required this.kind,
    this.parentId,
  });

  final TxCategory? category;
  final String kind;
  final String? parentId;

  @override
  ConsumerState<CategoryFormSheet> createState() => _CategoryFormSheetState();
}

class _CategoryFormSheetState extends ConsumerState<CategoryFormSheet> {
  late final TextEditingController _name = TextEditingController(
    text: widget.category?.name ?? '',
  );

  late String _kind = widget.kind;
  late String? _parentId = widget.parentId;
  late String? _icon = widget.category?.icon;
  late String? _color = widget.category?.color;

  bool _busy = false;
  String? _error;

  bool get _isNew => widget.category == null;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '类别得有个名字。');
      return;
    }
    final body = <String, dynamic>{
      'name': name,
      'kind': _kind,
      'parentId': _parentId,
      'icon': _icon,
      'color': _color,
    };

    setState(() {
      _busy = true;
      _error = null;
    });
    final navigator = Navigator.of(context);
    final repo = ref.read(ledgerRepoProvider);
    try {
      if (_isNew) {
        await repo.createCategory(body);
      } else {
        await repo.updateCategory(widget.category!.id, body);
      }
      navigator.pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = describeError(e);
        });
      }
    }
  }

  /// 归档 = `PATCH {archived}`，不是 `DELETE`。
  ///
  /// `DELETE /categories/:id` 是软删（打墓碑，行会从各设备上消失），而且类别
  /// 下有已确认流水时服务端 409。归档要的是「记账时别再出现，历史流水还挂着
  /// 这个类别」—— 那是 `archived` 字段的事。
  Future<void> _setArchived(bool archived, int childCount) async {
    final category = widget.category;
    if (category == null) return;
    if (archived) {
      final ok = await confirmDestructive(
        context,
        title: '归档「${category.name}」？',
        message: childCount > 0
            ? '它下面还有 $childCount 个子类别，会一起从记账时的选择里消失。'
                  '已有流水保留原类别，随时可以取消归档。'
            : '归档后记账时不再出现，已有流水保留原类别，随时可以取消归档。',
        confirmLabel: '归档',
      );
      if (!ok || !mounted) return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final navigator = Navigator.of(context);
    try {
      await ref.read(ledgerRepoProvider).updateCategory(category.id, {
        'archived': archived,
      });
      navigator.pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = describeError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final data = ref.watch(ledgerProvider).valueOrNull;
    final all = data?.categories ?? const <TxCategory>[];
    final id = widget.category?.id;
    final childCount = id == null
        ? 0
        : all.where((c) => c.parentId == id && !c.archived).length;
    // 只做两层：自己有子类别时就不能再挂到别人下面。
    final canNest = childCount == 0;
    final parents = all
        .where((c) => !c.archived && c.kind == _kind && c.parentId == null && c.id != id)
        .toList();

    return ManageSheet(
      title: _isNew ? '添加类别' : '编辑类别',
      busy: _busy,
      error: _error,
      onSubmit: _submit,
      secondaryLabel: _isNew
          ? null
          : (widget.category!.archived ? '取消归档' : '归档'),
      onSecondary: _isNew
          ? null
          : () => _setArchived(!widget.category!.archived, childCount),
      secondaryDestructive: !(widget.category?.archived ?? false),
      children: [
        ManageField(
          label: '名称',
          child: TextField(
            controller: _name,
            autofocus: _isNew,
            decoration: const InputDecoration(hintText: '早餐、打车、宠物粮…'),
          ),
        ),
        ManageField(
          label: '收支',
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'expense', label: Text('支出')),
              ButtonSegment(value: 'income', label: Text('收入')),
            ],
            selected: {_kind},
            onSelectionChanged: (value) => setState(() {
              _kind = value.first;
              _parentId = null; // 换了收支，原来的父类别就不成立了
            }),
          ),
        ),
        if (canNest)
          ManagePicker<String>(
            label: '父类别',
            value: _parentId,
            options: [
              (null, '顶级类别'),
              for (final c in parents) (c.id, c.name),
            ],
            onChanged: (value) => setState(() => _parentId = value),
          )
        else
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              '它下面有 $childCount 个子类别，只做两层，所以不能再挂到别的类别下。',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ManageIconPicker(
          value: _icon,
          color: hexColor(_color),
          onChanged: (value) => setState(() => _icon = value),
        ),
        ManageColorPicker(
          value: _color,
          onChanged: (value) => setState(() => _color = value),
        ),
      ],
    );
  }
}
