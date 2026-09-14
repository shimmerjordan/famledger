import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../capture/capture_types.dart';
import '../../data/models/models.dart';
import '../widgets/widgets.dart';
import 'manage_widgets.dart';

/// 新建/编辑识别规则。
Future<void> showRuleForm(BuildContext context, {Rule? rule}) =>
    showManageSheet<void>(context, (context) => RuleFormSheet(rule: rule));

class RuleFormSheet extends ConsumerStatefulWidget {
  const RuleFormSheet({super.key, this.rule});

  final Rule? rule;

  @override
  ConsumerState<RuleFormSheet> createState() => _RuleFormSheetState();
}

class _RuleFormSheetState extends ConsumerState<RuleFormSheet> {
  late final TextEditingController _pattern = TextEditingController(
    text: widget.rule?.pattern ?? '',
  );
  late final TextEditingController _priority = TextEditingController(
    text: '${widget.rule?.priority ?? 0}',
  );
  final TextEditingController _sample = TextEditingController();

  late String _field = widget.rule?.field ?? 'merchant';
  late String _op = widget.rule?.op ?? 'contains';
  late String? _categoryId = widget.rule?.categoryId;
  late String? _fundId = widget.rule?.fundId;
  late String? _accountId = widget.rule?.accountId;
  late String? _memberId = widget.rule?.memberId;
  late bool _enabled = widget.rule?.enabled ?? true;

  bool _busy = false;
  String? _error;

  bool get _isNew => widget.rule == null;

  @override
  void dispose() {
    _pattern.dispose();
    _priority.dispose();
    _sample.dispose();
    super.dispose();
  }

  /// 正则写错了要当场说，别等到半夜通知来了才静悄悄地不匹配。
  String? get _patternError {
    final pattern = _pattern.text;
    if (pattern.isEmpty || _op != 'regex') return null;
    try {
      RegExp(pattern);
    } on FormatException catch (e) {
      return '正则不对：${e.message}';
    }
    return null;
  }

  /// 用的就是自动记账管线那一份匹配逻辑，所见即所得。
  bool? get _sampleHit {
    if (_pattern.text.isEmpty || _sample.text.isEmpty) return null;
    if (_patternError != null) return null;
    final probe = CaptureRule(
      id: 'preview',
      priority: 0,
      field: _field,
      op: _op,
      pattern: _pattern.text,
    );
    return probe.matches(
      merchant: _sample.text,
      text: _sample.text,
      app: _sample.text,
    );
  }

  Future<void> _submit() async {
    final pattern = _pattern.text.trim();
    if (pattern.isEmpty) {
      setState(() => _error = '要匹配什么？先填上关键字或正则。');
      return;
    }
    if (_patternError != null) {
      setState(() => _error = _patternError);
      return;
    }
    if (_categoryId == null &&
        _fundId == null &&
        _accountId == null &&
        _memberId == null) {
      setState(() => _error = '命中之后要填什么？至少选一个类别、基金、账户或成员。');
      return;
    }

    final body = <String, dynamic>{
      'priority': int.tryParse(_priority.text.trim()) ?? 0,
      'field': _field,
      'op': _op,
      'pattern': pattern,
      'categoryId': _categoryId,
      'fundId': _fundId,
      'accountId': _accountId,
      'memberId': _memberId,
      'enabled': _enabled,
    };

    setState(() {
      _busy = true;
      _error = null;
    });
    final navigator = Navigator.of(context);
    final repo = ref.read(ledgerRepoProvider);
    try {
      if (_isNew) {
        await repo.createRule(body);
      } else {
        await repo.updateRule(widget.rule!.id, body);
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

  Future<void> _delete() async {
    final rule = widget.rule;
    if (rule == null) return;
    final ok = await confirmDestructive(
      context,
      title: '删除这条规则？',
      message: '以后收到「${rule.pattern}」这类通知就不会自动归类了，已记的流水不动。',
      confirmLabel: '删除',
    );
    if (!ok || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final navigator = Navigator.of(context);
    try {
      await ref.read(ledgerRepoProvider).deleteRule(rule.id);
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
    final ledger = LedgerColors.of(context);
    final data = ref.watch(ledgerProvider).valueOrNull;
    final categories = data?.categories.where((c) => !c.archived).toList() ?? [];
    final funds = data?.activeFunds ?? [];
    final accounts = data?.activeAccounts ?? [];
    final members = data?.activeMembers ?? [];
    final hit = _sampleHit;

    return ManageSheet(
      title: _isNew ? '添加规则' : '编辑规则',
      busy: _busy,
      error: _error,
      onSubmit: _submit,
      secondaryLabel: _isNew ? null : '删除',
      onSecondary: _isNew ? null : _delete,
      children: [
        ManageField(
          label: '看哪里',
          child: SegmentedButton<String>(
            segments: [
              for (final field in Rule.fields)
                ButtonSegment(
                  value: field,
                  label: Text(Rule.fieldLabels[field] ?? field),
                ),
            ],
            selected: {_field},
            onSelectionChanged: (value) => setState(() => _field = value.first),
          ),
        ),
        ManageField(
          label: '怎么比',
          child: SegmentedButton<String>(
            segments: [
              for (final op in Rule.ops)
                ButtonSegment(
                  value: op,
                  label: Text(Rule.opLabels[op] ?? op),
                ),
            ],
            selected: {_op},
            onSelectionChanged: (value) => setState(() => _op = value.first),
          ),
        ),
        ManageField(
          label: _op == 'regex' ? '正则' : '关键字',
          child: TextField(
            controller: _pattern,
            autofocus: _isNew,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: _op == 'regex' ? r'星巴克|Starbucks' : '星巴克',
              errorText: _patternError,
            ),
          ),
        ),
        ManageField(
          label: '测试匹配',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _sample,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  hintText: '粘一条真实的通知文字试试',
                ),
              ),
              if (hit != null) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      hit ? Icons.check_circle_outline : Icons.remove_circle_outline,
                      size: 16,
                      color: hit ? ledger.income : theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      hit ? '命中，会按下面的设置填' : '没命中',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: hit ? ledger.income : null,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text('命中之后填什么', style: theme.textTheme.titleMedium),
        ),
        ManagePicker<String>(
          label: '类别',
          value: _categoryId,
          options: [
            (null, '不改'),
            for (final c in categories)
              (c.id, '${c.name}${c.isIncome ? '（收入）' : ''}'),
          ],
          onChanged: (value) => setState(() => _categoryId = value),
        ),
        ManagePicker<String>(
          label: '基金',
          value: _fundId,
          options: [
            (null, '不改'),
            for (final f in funds) (f.id, f.name),
          ],
          onChanged: (value) => setState(() => _fundId = value),
        ),
        ManagePicker<String>(
          label: '账户',
          value: _accountId,
          options: [
            (null, '不改'),
            for (final a in accounts) (a.id, a.name),
          ],
          onChanged: (value) => setState(() => _accountId = value),
        ),
        ManagePicker<String>(
          label: '成员',
          value: _memberId,
          options: [
            (null, '不改'),
            for (final m in members) (m.id, m.label),
          ],
          onChanged: (value) => setState(() => _memberId = value),
        ),
        ManageField(
          label: '优先级',
          child: TextField(
            controller: _priority,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              hintText: '0',
              helperText: '数字大的先命中，一样大就看谁先建',
            ),
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _enabled,
          title: const Text('启用'),
          subtitle: const Text('关掉后先留着，不参与自动识别'),
          onChanged: (value) => setState(() => _enabled = value),
        ),
      ],
    );
  }
}
