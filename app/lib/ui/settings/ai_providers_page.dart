import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/models/models.dart';
import '../../data/repos/ai_repo.dart';
import '../widgets/widgets.dart';
import 'ai_provider_form.dart';

/// AI 渠道列表：默认标记、启停、测试（给延迟和一句样例）、增删改。
class AiProvidersPage extends ConsumerStatefulWidget {
  const AiProvidersPage({super.key});

  @override
  ConsumerState<AiProvidersPage> createState() => _AiProvidersPageState();
}

class _AiProvidersPageState extends ConsumerState<AiProvidersPage> {
  final Map<String, AiProviderTest> _results = {};
  final Map<String, String> _failures = {};
  final Set<String> _testing = {};
  final Set<String> _busy = {};

  Future<void> _openForm([AiProvider? provider]) =>
      showAiProviderForm(context, provider: provider);

  Future<void> _test(AiProvider provider) async {
    setState(() {
      _testing.add(provider.id);
      _failures.remove(provider.id);
      _results.remove(provider.id);
    });
    try {
      final result = await ref.read(aiRepoProvider).test(provider.id);
      if (!mounted) return;
      setState(() {
        _testing.remove(provider.id);
        if (result.ok) {
          _results[provider.id] = result;
        } else {
          _failures[provider.id] = result.message.isEmpty ? '没通，服务端没说原因。' : result.message;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing.remove(provider.id);
        _failures[provider.id] = describeError(e);
      });
    }
  }

  Future<void> _toggle(AiProvider provider, bool enabled) async {
    setState(() => _busy.add(provider.id));
    try {
      await ref.read(aiRepoProvider).update(provider.id, enabled: enabled);
      ref.invalidate(aiProvidersProvider);
    } catch (e) {
      if (mounted) setState(() => _failures[provider.id] = describeError(e));
    } finally {
      if (mounted) setState(() => _busy.remove(provider.id));
    }
  }

  Future<void> _setDefault(AiProvider provider) async {
    try {
      await ref.read(aiRepoProvider).update(provider.id, isDefault: true);
      ref.invalidate(aiProvidersProvider);
    } catch (e) {
      if (mounted) setState(() => _failures[provider.id] = describeError(e));
    }
  }

  Future<void> _delete(AiProvider provider) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除「${provider.name}」？'),
        content: const Text('密钥会一起删掉，之后要用得重新填一遍。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(aiRepoProvider).remove(provider.id);
      ref.invalidate(aiProvidersProvider);
    } catch (e) {
      if (mounted) setState(() => _failures[provider.id] = describeError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isAdmin = ref.watch(sessionProvider)?.me.isAdmin ?? false;
    final providers = ref.watch(aiProvidersProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 渠道'),
        actions: [
          if (isAdmin)
            IconButton(
              tooltip: '新建渠道',
              onPressed: _openForm,
              icon: const Icon(Icons.add),
            ),
        ],
      ),
      body: AsyncValueView<List<AiProvider>>(
        value: providers,
        onRetry: () => ref.invalidate(aiProvidersProvider),
        loading: const SkeletonList(rows: 3),
        data: (items) => ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                LedgerLayout.pagePadding,
                8,
                LedgerLayout.pagePadding,
                8,
              ),
              child: Text(
                isAdmin
                    ? '问 AI 与月报用这里配的渠道。密钥只存在你自己的服务器上，加密保存。'
                    : '渠道配置由管理员维护。',
                style: theme.textTheme.bodySmall,
              ),
            ),
            if (items.isEmpty)
              EmptyState(
                icon: Icons.smart_toy_outlined,
                title: '还没有 AI 渠道',
                message: '加一个才能用「问 AI」和月报。自建 cc-trans、硅基流动、DeepSeek 都行。',
                actionLabel: isAdmin ? '新建渠道' : null,
                onAction: isAdmin ? _openForm : null,
              )
            else
              for (final provider in items) _row(theme, provider, isAdmin),
          ],
        ),
      ),
    );
  }

  Widget _row(ThemeData theme, AiProvider provider, bool isAdmin) {
    final ledger = LedgerColors.of(context);
    final result = _results[provider.id];
    final failure = _failures[provider.id];
    final testing = _testing.contains(provider.id);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LedgerLayout.pagePadding,
        4,
        LedgerLayout.pagePadding,
        4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: isAdmin ? () => _openForm(provider) : null,
                  borderRadius: BorderRadius.circular(LedgerShapes.control),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                provider.name,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleMedium,
                              ),
                            ),
                            if (provider.isDefault) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primaryContainer,
                                  borderRadius: BorderRadius.circular(LedgerShapes.chip),
                                ),
                                child: Text(
                                  '默认',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onPrimaryContainer,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _subtitle(provider),
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (isAdmin) ...[
                Switch(
                  value: provider.enabled,
                  onChanged: _busy.contains(provider.id)
                      ? null
                      : (v) => _toggle(provider, v),
                ),
                PopupMenuButton<String>(
                  tooltip: '更多',
                  onSelected: (value) => switch (value) {
                    'edit' => _openForm(provider),
                    'default' => _setDefault(provider),
                    _ => _delete(provider),
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(value: 'edit', child: Text('编辑')),
                    if (!provider.isDefault)
                      const PopupMenuItem(value: 'default', child: Text('设为默认')),
                    const PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
              ] else
                Text(
                  provider.enabled ? '已启用' : '已停用',
                  style: theme.textTheme.bodySmall,
                ),
            ],
          ),
          if (isAdmin)
            Row(
              children: [
                TextButton(
                  onPressed: testing ? null : () => _test(provider),
                  child: Text(testing ? '测试中…' : '测试'),
                ),
                const SizedBox(width: 8),
                if (result != null)
                  Expanded(
                    child: Text(
                      '通了 · ${result.latencyMs}ms'
                      '${result.sample.isEmpty ? '' : ' · 它说「${result.sample}」'}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: ledger.income,
                      ),
                    ),
                  )
                else if (failure != null)
                  Expanded(
                    child: Text(
                      failure,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
              ],
            )
          else
            const SizedBox(height: 8),
          const Divider(height: 1),
        ],
      ),
    );
  }

  static String _subtitle(AiProvider provider) {
    final kind = provider.kind == 'anthropic' ? 'Anthropic' : 'OpenAI 兼容';
    final key = provider.hasKey
        ? '密钥 …${provider.keyTail ?? '已存'}'
        : '还没填密钥';
    final model = provider.model.isEmpty ? '未设模型' : provider.model;
    return '$kind · $model · $key';
  }
}
