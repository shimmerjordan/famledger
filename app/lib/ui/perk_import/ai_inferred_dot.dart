import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/models/models.dart';
import '../widgets/widgets.dart';

// 「AI 推断」小点（spec §5、§6）：AI 导入写进 origin.unverified 的字段，在详情页字段旁边点一个小点。
// 点一下说清楚是推断的、依据是什么，「没错」就把它从 unverified 里拿掉（PATCH origin），「去改」打开编辑页 ——
// 在表单里改了值，服务端也会把它拿掉（lib/perks_schema.js pruneUnverified），小点跟着消失。

/// origin.unverified 里的字段名 → 给人看的名字。
const Map<String, String> inferredFieldLabels = {
  'name': '名称',
  'tier': '档位',
  'feeCents': '续费价',
  'feePeriod': '续费周期',
  'termStartOn': '本期开始',
  'expiresOn': '到期日',
  'autoRenew': '续费方式',
  'claimPlatformId': '领取平台',
  'quota': '额度',
  'validFrom': '有效期开始',
  'validUntil': '有效期到',
  'faceValueCents': '面值',
  'priceCents': '买价',
  'purchasedOn': '买入日期',
  'category': '类别',
};

/// [origin] 去掉 [fields] 之后的样子（「没错」时整个 origin 发回去）。
Map<String, dynamic> confirmedOrigin(Map<String, dynamic> origin, Iterable<String> fields) => {
  ...origin,
  'unverified': [
    for (final f in originUnverified(origin))
      if (!fields.contains(f)) f,
  ],
};

/// [origin] 里 [fields] 哪些还没确认（顺序照 [fields]）。
List<String> inferredOf(Map<String, dynamic> origin, List<String> fields) {
  final pending = originUnverified(origin).toSet();
  return [
    for (final f in fields)
      if (pending.contains(f)) f,
  ];
}

/// 字段旁边的小点：8dp 的赭红点，触控区 48dp。
class AiInferredDot extends ConsumerWidget {
  const AiInferredDot({
    super.key,
    required this.fields,
    required this.origin,
    required this.onConfirm,
    required this.onEdit,
  });

  /// 这个点代表的字段（会员详情一行一个；权益一行可能好几个）。
  final List<String> fields;
  final Map<String, dynamic> origin;

  /// 「没错」：调用方把 confirmedOrigin(origin, fields) PATCH 回去。
  final Future<void> Function(WidgetRef ref, Map<String, dynamic> origin) onConfirm;
  final VoidCallback onEdit;

  String get _label => fields.map((f) => inferredFieldLabels[f] ?? f).join('、');

  @override
  Widget build(BuildContext context, WidgetRef ref) => Semantics(
    button: true,
    label: 'AI 推断：$_label，点一下确认或修改',
    child: InkResponse(
      radius: 24,
      onTap: () => _open(context, ref),
      child: SizedBox(
        width: 48,
        height: 48,
        child: Center(
          child: Tooltip(
            message: 'AI 推断',
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, shape: BoxShape.circle),
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> _open(BuildContext context, WidgetRef ref) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    builder: (sheet) => _DotSheet(label: _label, ev: jsonStringOrNull(origin['ev']), onConfirm: () => onConfirm(ref, confirmedOrigin(origin, fields)), onEdit: onEdit),
  );
}

class _DotSheet extends StatefulWidget {
  const _DotSheet({required this.label, required this.ev, required this.onConfirm, required this.onEdit});

  final String label;
  final String? ev;
  final Future<void> Function() onConfirm;
  final VoidCallback onEdit;

  @override
  State<_DotSheet> createState() => _DotSheetState();
}

class _DotSheetState extends State<_DotSheet> {
  bool _busy = false;
  String? _error;

  Future<void> _confirm() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final navigator = Navigator.of(context);
    try {
      await widget.onConfirm();
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 0, LedgerLayout.pagePadding, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('「${widget.label}」是 AI 推断的', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            widget.ev == null ? '导入时材料里没找到明确的依据，核对一下。' : '依据：「${widget.ev}」',
            key: const ValueKey('ai-dot-ev'),
            style: theme.textTheme.bodyMedium,
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
          ],
          const SizedBox(height: LedgerLayout.itemGap),
          Row(
            children: [
              OutlinedButton(
                key: const ValueKey('ai-dot-edit'),
                onPressed: _busy
                    ? null
                    : () {
                        Navigator.of(context).pop();
                        widget.onEdit();
                      },
                child: const Text('去改'),
              ),
              const SizedBox(width: LedgerLayout.itemGap),
              FilledButton(key: const ValueKey('ai-dot-confirm'), onPressed: _busy ? null : _confirm, child: const Text('没错')),
            ],
          ),
        ],
      ),
    );
  }
}
