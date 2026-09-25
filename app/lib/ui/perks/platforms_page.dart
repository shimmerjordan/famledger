import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/ids.dart';
import '../../data/api/api_client.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../add_tx/picker_field.dart';
import '../assets/asset_widgets.dart';
import '../widgets/widgets.dart';
import 'perk_providers.dart';
import 'perk_widgets.dart';

/// 平台被多少东西引用：挂在它下面的会员（含归档的）、要去它那领的权益。和服务端 409 的口径一样。
({int memberships, int benefits}) platformUsage(LedgerData data, String id) => (
  memberships: data.memberships.where((m) => m.platformId == id).length,
  benefits: data.benefits.where((b) => b.claimPlatformId == id).length,
);

/// 平台管理（`/assets/platforms`，会员权益 tab 溢出菜单进来）：改名、别名、归档、合并、删除。
class PlatformsPage extends ConsumerWidget {
  const PlatformsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ledger = ref.watch(ledgerProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('平台管理'),
        actions: [
          IconButton(
            tooltip: '新建平台',
            icon: const Icon(Icons.add),
            onPressed: () => context.push('/assets/platforms/new'),
          ),
        ],
      ),
      body: AsyncValueView<LedgerData>(
        value: ledger,
        onRetry: () => ref.invalidate(ledgerProvider),
        data: (data) {
          if (data.platforms.isEmpty) {
            return const EmptyState(
              title: '还没有平台',
              message: '记会员卡、写「在哪领」时顺手就建好了。',
              icon: Icons.storefront_outlined,
            );
          }
          final active = data.activePlatforms;
          final archived = data.platforms.where((p) => p.archived).toList();
          return LayoutBuilder(
            builder: (context, box) => ListView(
              padding: readableInsets(box.maxWidth, maxWidth: 720).copyWith(bottom: 96),
              children: [
                for (final p in active) _PlatformTile(data: data, platform: p),
                if (archived.isNotEmpty) ...[
                  const SizedBox(height: LedgerLayout.groupGap),
                  const SectionHeader('已归档'),
                  for (final p in archived) _PlatformTile(data: data, platform: p),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _PlatformTile extends StatelessWidget {
  const _PlatformTile({required this.data, required this.platform});

  final LedgerData data;
  final PerkPlatform platform;

  @override
  Widget build(BuildContext context) {
    final used = platformUsage(data, platform.id);
    return ListTile(
      key: ValueKey('platform-${platform.id}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding, vertical: 4),
      leading: PlatformAvatar(platform, muted: platform.archived),
      title: Text(platform.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          '${used.memberships} 张卡 · ${used.benefits} 项在这领',
          if (platform.aliases.isNotEmpty) '也叫 ${platform.aliases.join('、')}',
        ].join('\n'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => context.push('/assets/platforms/${platform.id}/edit'),
    );
  }
}

/// 新建 / 编辑平台。编辑时还能归档、并入别的平台、删除（有引用时服务端 409，把原因原样说出来）。
class PlatformFormPage extends ConsumerStatefulWidget {
  const PlatformFormPage({super.key, this.id});

  final String? id;

  @override
  ConsumerState<PlatformFormPage> createState() => _PlatformFormPageState();
}

class _PlatformFormPageState extends ConsumerState<PlatformFormPage> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _alias = TextEditingController();
  final TextEditingController _url = TextEditingController();
  final TextEditingController _note = TextEditingController();
  List<String> _aliases = [];
  String _kind = 'other';
  bool _bound = false;
  bool _busy = false;
  String? _error;

  /// 合并的幂等键，和目标绑在一起：回应丢了再并入同一个平台只并一次；换了目标就是另一次合并，换一个键
  /// （服务端只认 clientId，沿用旧键会把上一次的结果回放成「已并入」新目标）。
  String? _mergeTargetId;
  String _mergeClientId = newClientId();

  bool get _editing => widget.id != null;

  @override
  void dispose() {
    for (final c in [_name, _alias, _url, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  void _bind(PerkPlatform p) {
    if (_bound) return;
    _bound = true;
    _name.text = p.name;
    _url.text = p.url ?? '';
    _note.text = p.note ?? '';
    _aliases = [...p.aliases];
    _kind = p.kind;
  }

  /// 把输入框里的别名加进列表；填错时行内说一句、返回假。
  bool _addAlias() {
    final a = _alias.text.trim();
    if (a.isEmpty) return true;
    final dup = _aliases.any((x) => perkNameKey(x) == perkNameKey(a));
    if (a.length > 30) {
      setState(() => _error = '每个别名最多 30 个字');
      return false;
    }
    if (!dup && _aliases.length >= 20) {
      setState(() => _error = '别名最多 20 个');
      return false;
    }
    setState(() {
      if (!dup) _aliases.add(a);
      _alias.clear();
      _error = null;
    });
    return true;
  }

  /// [writeError] 为真：请求带着幂等键（合并），没等到回应时要说清「再点一次也不会重复」。
  Future<void> _run(Future<void> Function() action, {bool writeError = false}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = writeError ? describeWriteError(error) : describeError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _leave(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    context.canPop() ? context.pop() : context.go('/assets/platforms');
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (perkNameKey(name).isEmpty) return setState(() => _error = '名称里至少要有一个字或字母');
    // 别名框里写了还没点「加上」：照样算进去，不悄悄丢掉。
    if (!_addAlias()) return;
    final url = _url.text.trim();
    if (url.isNotEmpty && !RegExp(r'^https?://\S+$', caseSensitive: false).hasMatch(url)) {
      return setState(() => _error = '链接要以 http:// 或 https:// 开头');
    }
    final note = _note.text.trim();
    final body = {
      'name': name,
      'kind': _kind,
      'aliases': _aliases,
      'url': url.isEmpty ? null : url,
      'note': note.isEmpty ? null : note,
    };
    await _run(() async {
      final repo = ref.read(perksRepoProvider);
      if (_editing) {
        await repo.updatePlatform(widget.id!, body);
      } else {
        await repo.createPlatform(body);
      }
      if (mounted) _leave(_editing ? '已保存' : '建好了');
    });
  }

  Future<void> _merge(LedgerData data, PerkPlatform source) async {
    final targets = [
      for (final p in data.platforms)
        if (p.id != source.id) p,
    ];
    if (targets.isEmpty) return setState(() => _error = '没有别的平台可以并入');
    final target = await showModalBottomSheet<PerkPlatform>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 0, LedgerLayout.pagePadding, 8),
            child: Text('把「${source.name}」并入哪个平台？', style: Theme.of(context).textTheme.titleMedium),
          ),
          for (final p in targets)
            ListTile(
              key: ValueKey('merge-target-${p.id}'),
              title: Text(p.name),
              trailing: p.archived ? const Text('已归档') : null,
              onTap: () => Navigator.of(context).pop(p),
            ),
        ],
      ),
    );
    if (target == null || !mounted) return;
    final used = platformUsage(data, source.id);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('把「${source.name}」并入「${target.name}」？'),
        content: Text(
          '「${source.name}」下的 ${used.memberships} 张卡、${used.benefits} 项领取地都改到「${target.name}」，'
          '「${source.name}」记成「${target.name}」的别名，然后删掉「${source.name}」。',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('算了')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('合并')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (_mergeTargetId != target.id) {
      _mergeTargetId = target.id;
      _mergeClientId = newClientId();
    }
    final clientId = _mergeClientId;
    await _run(() async {
      final merged = await ref.read(perksRepoProvider).mergePlatform(source.id, targetId: target.id, clientId: clientId);
      if (mounted) _leave('已并入「${merged.name}」');
    }, writeError: true);
  }

  Future<void> _delete(PerkPlatform p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删掉「${p.name}」？'),
        content: const Text('只有没有卡挂着、也没有权益要去它那领的平台才能删；删不掉时可以归档或并入别的平台。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('算了')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('删掉')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _run(() async {
      try {
        await ref.read(perksRepoProvider).deletePlatform(p.id);
        if (mounted) _leave('已删掉');
      } on ApiException catch (e) {
        // 409 platform_in_use：服务端的话里已经带着引用数和出路（归档 / 并入）。
        if (e.code != 'platform_in_use') rethrow;
        if (mounted) setState(() => _error = e.message);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final data = ref.watch(ledgerProvider).valueOrNull;
    final platform = _editing ? data?.platform(widget.id) : null;
    if (platform != null) _bind(platform);
    final title = _editing ? '编辑平台' : '新建平台';
    if (data == null) {
      return Scaffold(appBar: AppBar(title: Text(title)), body: const SkeletonList(rows: 5));
    }
    if (_editing && platform == null) {
      return Scaffold(appBar: AppBar(title: Text(title)), body: const InlineError(message: '这个平台已经不在了（可能被并到别的平台了）。'));
    }
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: LayoutBuilder(
        builder: (context, box) => ListView(
          padding: readableInsets(box.maxWidth, maxWidth: 720).copyWith(bottom: LedgerLayout.groupGap),
          children: [
            PickerField(
              label: '名称',
              topGap: LedgerLayout.pagePadding,
              child: TextField(
                key: const ValueKey('platform-name'),
                controller: _name,
                decoration: const InputDecoration(hintText: '例如「淘宝」「优酷」「招商银行」'),
              ),
            ),
            PickerField(
              label: '类型',
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final e in PerkPlatform.kindLabels.entries)
                    ChoiceChip(
                      key: ValueKey('platform-kind-${e.key}'),
                      selected: _kind == e.key,
                      onSelected: (_) => setState(() => _kind = e.key),
                      label: Text(e.value),
                    ),
                ],
              ),
            ),
            PickerField(
              label: '别名（选填）',
              trailing: Text('搜索和 AI 导入时认得出', style: theme.textTheme.bodySmall),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_aliases.isNotEmpty)
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final a in _aliases)
                          InputChip(
                            key: ValueKey('platform-alias-$a'),
                            label: Text(a),
                            onDeleted: () => setState(() => _aliases.remove(a)),
                          ),
                      ],
                    ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const ValueKey('platform-alias-input'),
                          controller: _alias,
                          onSubmitted: (_) => _addAlias(),
                          decoration: const InputDecoration(hintText: '例如「天猫」「Tmall」'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton(key: const ValueKey('platform-alias-add'), onPressed: _addAlias, child: const Text('加上')),
                    ],
                  ),
                ],
              ),
            ),
            PickerField(
              label: '网址（选填）',
              child: TextField(
                key: const ValueKey('platform-url'),
                controller: _url,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(hintText: 'https://…'),
              ),
            ),
            PickerField(
              label: '备注（选填）',
              child: TextField(key: const ValueKey('platform-note'), controller: _note, maxLines: 2),
            ),
            const SizedBox(height: LedgerLayout.itemGap),
            FormSubmit(label: _editing ? '保存' : '建好了', busy: _busy, error: _error, onPressed: _save),
            if (platform != null) ...[
              const SizedBox(height: LedgerLayout.groupGap),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton(
                      key: const ValueKey('platform-merge'),
                      onPressed: _busy ? null : () => _merge(data, platform),
                      child: const Text('并入其他平台…'),
                    ),
                    FilledButton.tonal(
                      key: const ValueKey('platform-archive'),
                      onPressed: _busy
                          ? null
                          : () => _run(() async {
                              await ref.read(perksRepoProvider).updatePlatform(platform.id, {'archived': !platform.archived});
                              if (mounted) _leave(platform.archived ? '已取消归档' : '已归档：选平台时不再列出');
                            }),
                      child: Text(platform.archived ? '取消归档' : '归档'),
                    ),
                    OutlinedButton(
                      key: const ValueKey('platform-delete'),
                      onPressed: _busy ? null : () => _delete(platform),
                      child: const Text('删除'),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
