import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/repos/import_repo.dart';
import '../../data/repos/ledger_repo.dart';
import '../widgets/widgets.dart';
import 'import_draft.dart';
import 'import_layout.dart';
import 'import_providers.dart';
import 'import_sheets.dart';

/// 网页刷新后传球的那份预览就没了，只能请人回去重选文件。
class ImportPreviewRoute extends ConsumerStatefulWidget {
  const ImportPreviewRoute({super.key});

  @override
  ConsumerState<ImportPreviewRoute> createState() => _ImportPreviewRouteState();
}

class _ImportPreviewRouteState extends ConsumerState<ImportPreviewRoute> {
  ImportPreview? _preview;

  @override
  Widget build(BuildContext context) {
    // 接到手就自己拿着：导完会把传球的那份清掉，这一页的结果不能跟着变空。
    final handed = ref.watch(pendingImportPreviewProvider);
    final preview = _preview ??= handed;
    if (preview == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('核对导入')),
        body: EmptyState(
          icon: Icons.upload_file_outlined,
          title: '没有要核对的账单',
          message: '页面刷新过的话，要重新选一次文件',
          actionLabel: '去选文件',
          onAction: () => context.go('/import'),
        ),
      );
    }
    return ImportPreviewPage(key: ObjectKey(preview), preview: preview);
  }
}

enum _Stage { review, submitting, done }

enum _Filter { all, attention, uncategorized, skipped }

const double _maxWidth = 960;

class ImportPreviewPage extends ConsumerStatefulWidget {
  const ImportPreviewPage({super.key, required this.preview});

  final ImportPreview preview;

  @override
  ConsumerState<ImportPreviewPage> createState() => _ImportPreviewPageState();
}

class _ImportPreviewPageState extends ConsumerState<ImportPreviewPage> {
  late final ImportDraft _draft = ImportDraft(widget.preview);
  _Stage _stage = _Stage.review;
  _Filter _filter = _Filter.all;
  bool _selecting = false;
  final Set<int> _selected = {};
  bool _learn = true;
  bool _touched = false;
  int _done = 0;
  int _total = 0;
  ImportResult? _result;

  /// 整批都没送到时留在核对页，把原因写在底栏上方（改过的类别、勾选都还在）。
  String? _submitError;

  @override
  void initState() {
    super.initState();
    _draft.addListener(_onDraftChanged);
  }

  @override
  void dispose() {
    _draft.removeListener(_onDraftChanged);
    _draft.dispose();
    super.dispose();
  }

  void _onDraftChanged() {
    _touched = true;
    // 改完类别，行可能掉出当前筛选（比如「没类别」）；看不见的还选着，
    // 下一次批量改就会连它们一起改掉。页面随后由 ListenableBuilder 重画。
    _dropHiddenSelection();
  }

  void _dropHiddenSelection() =>
      _selected.removeWhere((i) => !_matches(i, _filter));

  bool _matches(int i, _Filter filter) {
    final row = _draft.rows[i];
    return switch (filter) {
      _Filter.all => true,
      _Filter.attention =>
        row.importable && (row.exists || row.isDuplicate || row.hint != null),
      _Filter.uncategorized => row.importable && _draft.categoryId(i) == null,
      _Filter.skipped => !row.importable,
    };
  }

  int _countOf(_Filter filter) {
    var n = 0;
    for (var i = 0; i < _draft.rows.length; i++) {
      if (_matches(i, filter)) n++;
    }
    return n;
  }

  List<int> get _visible => [
    for (var i = 0; i < _draft.rows.length; i++)
      if (_matches(i, _filter)) i,
  ];

  void _startSelecting([int? first]) => setState(() {
    _selecting = true;
    if (first != null && _draft.selectable(first)) _selected.add(first);
  });

  void _stopSelecting() => setState(() {
    _selecting = false;
    _selected.clear();
  });

  void _toggleSelected(int i) {
    if (!_draft.selectable(i)) return;
    setState(
      () => _selected.contains(i) ? _selected.remove(i) : _selected.add(i),
    );
  }

  void _selectAllVisible() => setState(() {
    _selected.addAll(_visible.where(_draft.selectable));
  });

  List<int> get _selectedSorted => _selected.toList()..sort();

  void _setFilter(_Filter filter) => setState(() {
    _filter = filter;
    _dropHiddenSelection();
  });

  void _onRowTap(int i, LedgerData ledger) {
    if (!_draft.selectable(i)) return;
    if (_selecting) {
      _toggleSelected(i);
    } else {
      showRowEditSheet(context, draft: _draft, index: i, ledger: ledger);
    }
  }

  Future<void> _submit() => _send(_draft.items());

  /// 结果页上的「重试没导进去的 N 笔」：草稿还在，照当初核对好的样子原样重发。
  Future<void> _retryFailed() {
    final previous = _result!;
    final failed = {for (final f in previous.failures) f.clientId};
    return _send(
      [
        for (final item in _draft.items())
          if (failed.contains(item.row.clientId)) item,
      ],
      previous: previous,
    );
  }

  Future<void> _send(List<ImportItem> items, {ImportResult? previous}) async {
    if (items.isEmpty) return;
    setState(() {
      _stage = _Stage.submitting;
      _done = 0;
      _total = items.length;
      _submitError = null;
    });
    final memberId = ref.read(sessionProvider)?.me.id ?? '';
    ImportResult result;
    try {
      result = await ref
          .read(importRepoProvider)
          .submit(
            items,
            channel: widget.preview.channel,
            memberId: memberId,
            learn: _learn,
            onProgress: (done, total) {
              if (mounted) setState(() => _done = done);
            },
          );
    } catch (e) {
      result = ImportResult(
        failures: [
          for (final item in items)
            ImportFailure(
              row: item.row.row,
              clientId: item.row.clientId,
              code: 'error',
              message: describeError(e),
              unsent: true,
            ),
        ],
      );
    }
    if (!mounted) return;
    if (result.created > 0) refreshAfterImport(ref);

    // 第一次提交就一笔没落地、而且全是整批没送到：别把人甩到结果页让他重选文件、重改一遍，
    // 留在核对页说清原因、给重试。
    final unsentOnly =
        result.created == 0 &&
        result.exists == 0 &&
        result.failures.isNotEmpty &&
        result.failures.every((f) => f.unsent);
    if (previous == null && unsentOnly) {
      setState(() {
        _stage = _Stage.review;
        _submitError =
            '${result.failures.first.message}，一笔都没导进去。刚才改的都还在，可以直接重试。';
      });
      return;
    }

    // 导完就把传球的那份清掉：否则回到选文件页后浏览器前进，这批会原样再摆出来、还能再点一次导入。
    // 结果页的重试用的是本页自己拿着的草稿，不靠它。
    ref.read(pendingImportPreviewProvider.notifier).state = null;
    setState(() {
      _result = previous == null
          ? result
          : ImportResult(
              created: previous.created + result.created,
              exists: previous.exists + result.exists,
              failures: result.failures,
              learned: previous.learned + result.learned,
              learnError: result.learnError ?? previous.learnError,
            );
      _stage = _Stage.done;
    });
  }

  Future<void> _onPopBlocked() async {
    if (_stage == _Stage.submitting) return;
    if (_selecting) {
      _stopSelecting();
      return;
    }
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('不导了？'),
        content: const Text('刚才改的类别和勾选都会丢掉。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('接着核对'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('不导了'),
          ),
        ],
      ),
    );
    if (leave == true && mounted) {
      _touched = false;
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ledger = ref.watch(ledgerProvider).valueOrNull ?? const LedgerData();
    return ListenableBuilder(
      listenable: _draft,
      builder: (context, _) => PopScope(
        canPop: switch (_stage) {
          _Stage.submitting => false,
          _Stage.done => true,
          _Stage.review => !_selecting && !_touched,
        },
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _onPopBlocked();
        },
        child: Scaffold(
          appBar: _appBar(),
          body: switch (_stage) {
            _Stage.review => _review(ledger),
            _Stage.submitting => _Progress(done: _done, total: _total),
            _Stage.done => _ResultView(
              result: _result!,
              learn: _learn,
              onRetry: _result!.failed > 0 ? _retryFailed : null,
            ),
          },
          bottomNavigationBar: _stage == _Stage.review
              ? (_selecting ? _selectionBar(ledger) : _submitBar())
              : null,
        ),
      ),
    );
  }

  PreferredSizeWidget _appBar() {
    if (_stage == _Stage.done) return AppBar(title: const Text('导入结果'));
    if (_selecting) {
      return AppBar(
        leading: IconButton(
          tooltip: '退出多选',
          icon: const Icon(Icons.close),
          onPressed: _stopSelecting,
        ),
        title: Text('选了 ${_selected.length} 笔'),
        actions: [
          TextButton(onPressed: _selectAllVisible, child: const Text('全选')),
        ],
      );
    }
    return AppBar(
      title: const Text('核对导入'),
      actions: [
        if (_stage == _Stage.review)
          IconButton(
            tooltip: '多选',
            icon: const Icon(Icons.checklist),
            onPressed: _startSelecting,
          ),
      ],
    );
  }

  Widget _review(LedgerData ledger) {
    final visible = _visible;
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        final pad = importPagePad(c.maxWidth);
        final gutter = importGutter(c.maxWidth, _maxWidth);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: gutter),
              child: _Summary(preview: widget.preview, draft: _draft, pad: pad),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.fromLTRB(gutter + pad, 4, gutter + pad, 8),
              child: Row(
                children: [
                  for (final f in _Filter.values)
                    if (f == _Filter.all || f == _filter || _countOf(f) > 0)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          key: ValueKey('import-filter-${f.name}'),
                          label: Text('${_filterLabel(f)} ${_countOf(f)}'),
                          selected: _filter == f,
                          onSelected: (_) => _setFilter(f),
                        ),
                      ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: gutter),
              child: Divider(
                height: 1,
                color: theme.colorScheme.outlineVariant,
              ),
            ),
            Expanded(
              child: visible.isEmpty
                  ? const EmptyState(compact: true, title: '这一类没有了')
                  : ListView.builder(
                      padding: EdgeInsets.fromLTRB(gutter, 0, gutter, 16),
                      itemCount: visible.length,
                      itemBuilder: (context, k) {
                        final i = visible[k];
                        return _RowTile(
                          key: ValueKey('import-row-$i'),
                          index: i,
                          draft: _draft,
                          ledger: ledger,
                          pad: pad,
                          selecting: _selecting,
                          selected: _selected.contains(i),
                          onTap: () => _onRowTap(i, ledger),
                          onLongPress: _selecting || !_draft.selectable(i)
                              ? null
                              : () => _startSelecting(i),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  static String _filterLabel(_Filter f) => switch (f) {
    _Filter.all => '全部',
    _Filter.attention => '要看一眼',
    _Filter.uncategorized => '没类别',
    _Filter.skipped => '跳过',
  };

  Widget _submitBar() {
    final theme = Theme.of(context);
    final n = _draft.includedCount;
    final taught = _draft.includedIndices
        .where((i) => _draft.categoryChanged(i) || _draft.fundChanged(i))
        .length;
    final learnRow = Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('用这批账单训练自动识别', style: theme.textTheme.bodyMedium),
              Text(
                taught > 0 ? '你改过类别或基金的 $taught 笔会拿去学' : '只学你改过类别或基金的那些',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        Switch(
          key: const ValueKey('import-learn'),
          value: _learn,
          onChanged: (v) => setState(() => _learn = v),
        ),
      ],
    );
    final button = FilledButton(
      key: const ValueKey('import-submit'),
      onPressed: n > 0 ? _submit : null,
      child: Text(n > 0 ? '导入 $n 笔' : '一笔都没勾'),
    );
    final error = _submitError;
    return _BottomBar(
      child: LayoutBuilder(
        builder: (context, c) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (error != null)
              InlineError(
                key: const ValueKey('import-submit-error'),
                message: error,
                onRetry: n > 0 ? _submit : null,
                padding: const EdgeInsets.only(bottom: 8),
              ),
            if (c.maxWidth < 560) ...[
              learnRow,
              const SizedBox(height: 8),
              button,
            ] else
              Row(
                children: [
                  Expanded(child: learnRow),
                  const SizedBox(width: LedgerLayout.groupGap),
                  button,
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _selectionBar(LedgerData ledger) {
    final any = _selected.isNotEmpty;
    return _BottomBar(
      child: Row(
        children: [
          _BarAction(
            icon: Icons.local_offer_outlined,
            label: '改类别',
            onTap: any
                ? () => showBatchCategorySheet(
                    context,
                    draft: _draft,
                    indices: _selectedSorted,
                    ledger: ledger,
                  )
                : null,
          ),
          _BarAction(
            icon: Icons.savings_outlined,
            label: '改基金',
            onTap: any
                ? () => showBatchFundSheet(
                    context,
                    draft: _draft,
                    indices: _selectedSorted,
                    ledger: ledger,
                  )
                : null,
          ),
          _BarAction(
            icon: Icons.check_box_outlined,
            label: '导入',
            onTap: any ? () => _draft.setIncluded(_selectedSorted, true) : null,
          ),
          _BarAction(
            icon: Icons.check_box_outline_blank,
            label: '不导入',
            onTap: any
                ? () => _draft.setIncluded(_selectedSorted, false)
                : null,
          ),
        ],
      ),
    );
  }
}

class _Constrained extends StatelessWidget {
  const _Constrained({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _maxWidth),
      child: child,
    ),
  );
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pad = importPagePad(MediaQuery.sizeOf(context).width);
    // 颜色给 Material 而不是 DecoratedBox：底栏按钮的水波纹画在 Material 上，被盖住就看不见了。
    return Material(
      color: LedgerColors.of(context).surface2,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: SafeArea(
          top: false,
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _maxWidth),
              child: Padding(
                padding: EdgeInsets.fromLTRB(pad, 8, pad, 12),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BarAction extends StatelessWidget {
  const _BarAction({required this.icon, required this.label, this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = onTap == null
        ? theme.colorScheme.onSurface.withValues(alpha: 0.38)
        : theme.colorScheme.onSurface;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(LedgerShapes.control),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({
    required this.preview,
    required this.draft,
    required this.pad,
  });

  final ImportPreview preview;
  final ImportDraft draft;
  final double pad;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final existed = draft.count((r) => r.importable && r.exists);
    final duplicated = draft.count(
      (r) => r.importable && !r.exists && r.isDuplicate,
    );
    final sentence = StringBuffer('${preview.sourceLabel}共 ${preview.total} 笔');
    if (preview.skipped == 0) {
      sentence.write('，都能导');
    } else {
      sentence.write('：${preview.importable} 笔能导，${preview.skipped} 笔跳过');
    }
    final held = [
      if (existed > 0) '$existed 笔导入过',
      if (duplicated > 0) '$duplicated 笔可能重复',
    ];
    if (held.isNotEmpty) sentence.write('；其中 ${held.join('、')}，先没勾');
    sentence.write('。');

    final muted = theme.textTheme.bodySmall;
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, 12, pad, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            sentence.toString(),
            key: const ValueKey('import-summary'),
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '已勾 ${draft.includedCount} 笔',
                style: theme.textTheme.titleSmall,
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('支出 ', style: muted),
                  MoneyText(
                    -draft.expenseCents,
                    size: MoneySize.small,
                    color: theme.colorScheme.onSurface,
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('收入 ', style: muted),
                  MoneyText(
                    draft.incomeCents,
                    size: MoneySize.small,
                    signed: true,
                    color: draft.incomeCents > 0
                        ? LedgerColors.of(context).income
                        : null,
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RowTile extends StatelessWidget {
  const _RowTile({
    super.key,
    required this.index,
    required this.draft,
    required this.ledger,
    required this.pad,
    required this.selecting,
    required this.selected,
    required this.onTap,
    this.onLongPress,
  });

  final int index;
  final ImportDraft draft;
  final LedgerData ledger;
  final double pad;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = LedgerColors.of(context);
    final row = draft.rows[index];
    final selectable = draft.selectable(index);
    final included = draft.included(index);
    final amount = row.amountCents;

    final Widget leading;
    if (selecting) {
      leading = selectable
          ? Icon(
              selected ? Icons.check_circle : Icons.radio_button_unchecked,
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            )
          : const SizedBox.shrink();
    } else {
      leading = Checkbox(
        key: ValueKey('import-check-$index'),
        value: included,
        onChanged: selectable ? (_) => draft.toggle(index) : null,
      );
    }

    final category = ledger.category(draft.categoryId(index));
    final fund = ledger.fund(draft.fundId(index));
    final guessed =
        !draft.categoryChanged(index) &&
        row.confidence != null &&
        category != null;
    final tags = <Widget>[
      if (selectable) ...[
        _Tag(
          icon: CategoryIcon(category?.icon, size: 14),
          label: category == null
              ? '没类别'
              : (guessed
                    ? '${category.name} · 猜的 ${(row.confidence! * 100).round()}%'
                    : category.name),
          color: draft.categoryChanged(index)
              ? theme.colorScheme.primary
              : null,
        ),
        _Tag(
          icon: fund == null
              ? null
              : FundDot.of(
                  context,
                  fund: fund,
                  index: ledger.fundIndex(fund.id),
                ),
          label: fund?.name ?? '默认基金',
          color: draft.fundChanged(index) ? theme.colorScheme.primary : null,
        ),
      ],
      if (row.exists) _Tag(label: '已导入过', background: colors.surface3),
      if (row.isDuplicate && !row.exists)
        _Tag(label: '可能重复', background: colors.warningContainer),
      if (selecting && selectable && !included)
        _Tag(label: '不导入', background: colors.surface3),
    ];

    final detail = [
      importRowWhen(row),
      if (row.rawCategory != null) row.rawCategory!,
      if (row.merchant.isNotEmpty && row.note.isNotEmpty)
        row.note.replaceAll('\n', ' '),
    ].join(' · ');

    // 跳过的行只把标题和金额压成次要色，不整行调透明度：跳过原因是这一行最要紧的字，得看得清。
    return Material(
      color: selected
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: EdgeInsets.fromLTRB(4, 6, pad, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 48, height: 48, child: Center(child: leading)),
              const SizedBox(width: 4),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              importRowTitle(row),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: selectable
                                  ? theme.textTheme.bodyLarge
                                  : theme.textTheme.bodyLarge?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (amount != null)
                            MoneyText(
                              row.isIncome ? amount : -amount,
                              signed: row.isIncome,
                              muted: !selectable,
                            )
                          else
                            Text('—', style: theme.textTheme.bodyLarge),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                      if (tags.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Wrap(spacing: 6, runSpacing: 4, children: tags),
                      ],
                      if (row.skip != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          row.skip!.message,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                      if (row.hint != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          row.hint!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.warning,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label, this.icon, this.color, this.background});

  final String label;
  final Widget? icon;
  final Color? color;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: background ?? LedgerColors.of(context).surface2,
        borderRadius: BorderRadius.circular(LedgerShapes.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[icon!, const SizedBox(width: 4)],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                color: color ?? theme.colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.done, required this.total});

  final int done;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _Constrained(
      child: Padding(
        padding: const EdgeInsets.all(LedgerLayout.widePagePadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('正在导入 $done / $total 笔…', style: theme.textTheme.titleMedium),
            const SizedBox(height: LedgerLayout.itemGap),
            LinearProgressIndicator(value: total == 0 ? null : done / total),
            const SizedBox(height: LedgerLayout.itemGap),
            Text('别关这个页面，导完会告诉你结果。', style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _ResultView extends StatelessWidget {
  const _ResultView({required this.result, required this.learn, this.onRetry});

  final ImportResult result;
  final bool learn;

  /// 有没导进去的才给：用这一页还拿着的草稿原样重发那几笔。
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final byMessage = <String, List<int>>{};
    for (final f in result.failures) {
      byMessage.putIfAbsent(f.message, () => []).add(f.row);
    }

    String rowsLabel(List<int> rows) {
      const shown = 8;
      final head = rows.take(shown).join('、');
      return rows.length > shown ? '第 $head 等 ${rows.length} 笔' : '第 $head 笔';
    }

    final width = MediaQuery.sizeOf(context).width;
    final side = importPagePad(width) + importGutter(width, _maxWidth);
    return ListView(
      padding: EdgeInsets.fromLTRB(side, 16, side, 16),
      children: [
        Text(
          result.failed == 0 ? '导入好了' : '有 ${result.failed} 笔没导进去',
          key: const ValueKey('import-result-title'),
          style: theme.textTheme.titleLarge,
        ),
        const SizedBox(height: LedgerLayout.itemGap),
        _CountLine(label: '新增', count: result.created),
        _CountLine(label: '以前导过', count: result.exists),
        if (result.failed > 0)
          _CountLine(
            label: '没导进去',
            count: result.failed,
            color: theme.colorScheme.error,
          ),
        // 服务端按 clientId 认「导过没有」，连导进去后又删掉的也算。
        if (result.exists > 0)
          Text('以前导过的不会再记一遍，导进去后又删掉的也不会补回来。', style: theme.textTheme.bodySmall),
        if (byMessage.isNotEmpty) ...[
          const SizedBox(height: LedgerLayout.itemGap),
          for (final e in byMessage.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '${e.key}（${rowsLabel(e.value)}）',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          Text(
            '点「重试」照刚才核对好的样子再发一次，已经导进去的不会重复记。',
            style: theme.textTheme.bodySmall,
          ),
        ],
        if (learn && (result.learned > 0 || result.learnError != null)) ...[
          const SizedBox(height: LedgerLayout.itemGap),
          Text(
            result.learnError == null
                ? '拿你改过的 ${result.learned} 笔教了自动识别。'
                : '训练没成功：${result.learnError}（账已经导进去了）',
            style: theme.textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: LedgerLayout.groupGap),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            if (onRetry != null)
              FilledButton.icon(
                key: const ValueKey('import-retry-failed'),
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: Text('重试没导进去的 ${result.failed} 笔'),
              ),
            if (onRetry == null)
              FilledButton(
                onPressed: () => context.go('/transactions'),
                child: const Text('去看账单'),
              )
            else
              OutlinedButton(
                onPressed: () => context.go('/transactions'),
                child: const Text('去看账单'),
              ),
            OutlinedButton(
              onPressed: () =>
                  context.canPop() ? context.pop() : context.go('/import'),
              child: const Text('再导一个'),
            ),
          ],
        ),
      ],
    );
  }
}

class _CountLine extends StatelessWidget {
  const _CountLine({required this.label, required this.count, this.color});

  final String label;
  final int count;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label, style: theme.textTheme.bodyLarge)),
          Text(
            '$count 笔',
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w600,
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
