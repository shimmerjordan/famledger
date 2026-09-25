import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/api/api_client.dart';
import '../../data/models/models.dart';
import '../widgets/widgets.dart';
import 'perk_providers.dart';

/// 平台选择的结果；[id] 为 null 表示选了「不选」那一项（权益的领取平台 = 会员本平台）。
/// 弹层被划掉时整个结果是 null，和「不选」分得开。
class PlatformPick {
  const PlatformPick(this.id);

  final String? id;
}

/// 表单里的「平台」一栏：显示选中的平台，点开能搜名字和别名，搜不到就地新建。
class PlatformPickerField extends ConsumerWidget {
  const PlatformPickerField({
    super.key,
    required this.selectedId,
    required this.onChanged,
    this.noneLabel,
    this.buttonKey,
  });

  final String? selectedId;
  final ValueChanged<String?> onChanged;

  /// 非空 = 允许不选（权益的领取平台：不选就是会员本平台），这是那一项的说法。
  final String? noneLabel;
  final Key? buttonKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(ledgerProvider).valueOrNull;
    final selected = data?.platform(selectedId);
    final label = selected?.name ?? (selectedId != null ? '平台已删除' : (noneLabel ?? '选一个平台'));
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        key: buttonKey,
        onPressed: () async {
          final pick = await showPlatformPicker(context, noneLabel: noneLabel);
          if (pick != null) onChanged(pick.id);
        },
        icon: const Icon(Icons.storefront_outlined, size: 18),
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

/// 弹出平台选择：搜名字和别名（全角、大小写、空格不计较）；输入的名字没有同名平台时给「新建「…」」。
/// 新建撞上已有的同名平台（服务端 409 name_taken）时直接改用那一个。
Future<PlatformPick?> showPlatformPicker(BuildContext context, {String? noneLabel}) =>
    showModalBottomSheet<PlatformPick>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => _PlatformPickerSheet(noneLabel: noneLabel),
    );

class _PlatformPickerSheet extends ConsumerStatefulWidget {
  const _PlatformPickerSheet({this.noneLabel});

  final String? noneLabel;

  @override
  ConsumerState<_PlatformPickerSheet> createState() => _PlatformPickerSheetState();
}

class _PlatformPickerSheetState extends ConsumerState<_PlatformPickerSheet> {
  final TextEditingController _query = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _create(String name) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      final p = await ref.read(perksRepoProvider).createPlatform({'name': name});
      if (mounted) Navigator.of(context).pop(PlatformPick(p.id));
    } on ApiException catch (e) {
      final existing = e.details['id'];
      if (e.code == 'name_taken' && existing is String) {
        // 「优酷 」「YOUKU」和已有的「优酷」是同一个：直接用它，不让人卡在报错上。
        // 那个平台可能是别的设备刚建的、本地还没有：先同步一下，表单上才写得出它的名字。
        if (ref.read(ledgerProvider).valueOrNull?.platform(existing) == null) {
          try {
            await ref.read(ledgerProvider.notifier).sync();
          } catch (_) {
            // 同步不上也照样用它；名字等下次同步再补。
          }
        }
        messenger.showSnackBar(SnackBar(content: Text('已有「${e.details['name'] ?? name}」，直接用它了')));
        if (mounted) Navigator.of(context).pop(PlatformPick(existing));
        return;
      }
      if (mounted) setState(() => _error = describeError(e));
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final platforms = ref.watch(ledgerProvider).valueOrNull?.platforms ?? const <PerkPlatform>[];
    final q = _query.text.trim();
    // 只按规范化名看（和服务端一样）：输入全是标点、空格时等于没输入 —— 不给「新建」，归档的也不翻出来。
    final searching = perkNameKey(q).isNotEmpty;
    final punctOnly = q.isNotEmpty && !searching;
    // 归档的平台平时藏起来；搜到了才给（点它就是接着用）。
    final shown = [
      for (final p in platforms)
        if (p.matches(q) && (!p.archived || searching)) p,
    ];
    final canCreate = searching && !platforms.any((p) => p.sameName(q));
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
            child: TextField(
              key: const ValueKey('platform-search'),
              controller: _query,
              autofocus: platforms.isEmpty,
              onChanged: (_) => setState(() {}),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) {
                if (canCreate && !_busy) _create(q);
              },
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '搜平台，或输入新平台的名字',
              ),
            ),
          ),
          if (_error != null || punctOnly)
            Padding(
              padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 8, LedgerLayout.pagePadding, 0),
              child: Text(
                _error ?? '名称里至少要有一个字或字母',
                key: const ValueKey('platform-search-hint'),
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
              ),
            ),
          const SizedBox(height: 8),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                if (widget.noneLabel != null && q.isEmpty)
                  ListTile(
                    key: const ValueKey('platform-none'),
                    leading: const Icon(Icons.subdirectory_arrow_left),
                    title: Text(widget.noneLabel!),
                    onTap: () => Navigator.of(context).pop(const PlatformPick(null)),
                  ),
                if (canCreate)
                  ListTile(
                    key: const ValueKey('platform-create'),
                    enabled: !_busy,
                    leading: _busy
                        ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.add),
                    title: Text('新建「$q」'),
                    onTap: () => _create(q),
                  ),
                for (final p in shown)
                  ListTile(
                    key: ValueKey('platform-pick-${p.id}'),
                    title: Text(p.name),
                    subtitle: p.aliases.isEmpty ? null : Text('也叫 ${p.aliases.join('、')}', maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: p.archived ? Text('已归档', style: theme.textTheme.bodySmall) : null,
                    onTap: () => Navigator.of(context).pop(PlatformPick(p.id)),
                  ),
                if (shown.isEmpty && !canCreate)
                  Padding(
                    padding: const EdgeInsets.all(LedgerLayout.pagePadding),
                    child: Text('还没有平台，输入名字就能新建。', style: theme.textTheme.bodySmall),
                  ),
              ],
            ),
          ),
          const SizedBox(height: LedgerLayout.itemGap),
        ],
      ),
    );
  }
}
