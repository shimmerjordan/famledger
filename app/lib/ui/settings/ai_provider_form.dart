import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../data/repos/ai_repo.dart';
import '../widgets/widgets.dart';
import 'manage_widgets.dart';

/// 新建/编辑一个 AI 渠道。编辑一律用底部弹层（与设置页其余表单同一套）。
Future<void> showAiProviderForm(BuildContext context, {AiProvider? provider}) =>
    showManageSheet<void>(
      context,
      (context) => AiProviderFormSheet(provider: provider),
    );

/// 预设选完自动填地址与模型，密钥只写不读。
class AiProviderFormSheet extends ConsumerStatefulWidget {
  const AiProviderFormSheet({super.key, this.provider});

  /// null = 新建。
  final AiProvider? provider;

  /// 服务端预设 hint 为空时的兜底说明（cc-trans 是自建反代，最容易填错）。
  static const Map<String, String> fallbackHints = {
    'cc-trans': '填 cc-trans 下发的 cct- 令牌；地址为你的 cc-trans 服务，例如 http://nas:8787',
    'ollama': '本机模型不需要密钥，地址填 Ollama 的 http://localhost:11434/v1',
  };

  @override
  ConsumerState<AiProviderFormSheet> createState() => _AiProviderFormSheetState();
}

class _AiProviderFormSheetState extends ConsumerState<AiProviderFormSheet> {
  late final TextEditingController _name = TextEditingController(
    text: widget.provider?.name ?? '',
  );
  late final TextEditingController _baseUrl = TextEditingController(
    text: widget.provider?.baseUrl ?? '',
  );
  late final TextEditingController _model = TextEditingController(
    text: widget.provider?.model ?? '',
  );
  final TextEditingController _apiKey = TextEditingController();

  late String _kind = widget.provider?.kind ?? 'openai';
  late bool _isDefault = widget.provider?.isDefault ?? false;
  String? _presetKey;
  String _hint = '';
  String? _error;
  bool _busy = false;

  bool get _isNew => widget.provider == null;

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _model.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  void _applyPreset(AiPreset preset) {
    setState(() {
      _presetKey = preset.key;
      _kind = preset.kind.isEmpty ? _kind : preset.kind;
      _baseUrl.text = preset.baseUrl;
      _model.text = preset.model;
      if (_name.text.trim().isEmpty) _name.text = preset.name;
      _hint = preset.hint.isNotEmpty
          ? preset.hint
          : (AiProviderFormSheet.fallbackHints[preset.key] ?? '');
    });
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    final baseUrl = _baseUrl.text.trim();
    final model = _model.text.trim();
    if (name.isEmpty || baseUrl.isEmpty || model.isEmpty) {
      setState(() => _error = '名称、地址、模型都要填。');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final repo = ref.read(aiRepoProvider);
    final navigator = Navigator.of(context);
    try {
      final provider = widget.provider;
      if (provider == null) {
        await repo.create(
          name: name,
          kind: _kind,
          baseUrl: baseUrl,
          apiKey: _apiKey.text.trim(),
          model: model,
          isDefault: _isDefault,
        );
      } else {
        await repo.update(
          provider.id,
          name: name,
          kind: _kind,
          baseUrl: baseUrl,
          apiKey: _apiKey.text.trim(),
          model: model,
          isDefault: _isDefault,
        );
      }
      ref.invalidate(aiProvidersProvider);
      if (mounted) navigator.pop();
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
    final presets = ref.watch(aiPresetsProvider);
    final provider = widget.provider;
    final tail = provider?.keyTail;

    return ManageSheet(
      title: _isNew ? '添加 AI 渠道' : '编辑 ${provider!.name}',
      busy: _busy,
      error: _error,
      onSubmit: _submit,
      children: [
        presets.when(
          loading: () => const Skeleton(height: 56, radius: 10),
          error: (_, _) => Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              '预设读不到，手动填地址和模型也一样能用。',
              style: theme.textTheme.bodySmall,
            ),
          ),
          data: (items) => items.isEmpty
              ? const SizedBox.shrink()
              : ManagePicker<String>(
                  label: '预设',
                  value: _presetKey,
                  options: [
                    (null, '不用预设'),
                    for (final preset in items) (preset.key, preset.name),
                  ],
                  onChanged: (key) {
                    final preset = items.where((p) => p.key == key).firstOrNull;
                    if (preset != null) _applyPreset(preset);
                  },
                ),
        ),
        if (_hint.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(_hint, style: theme.textTheme.bodySmall),
          ),
        ManageField(
          label: '名称',
          child: TextField(
            controller: _name,
            decoration: const InputDecoration(hintText: '硅基流动、家里的 cc-trans…'),
          ),
        ),
        ManageField(
          label: '协议',
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final kind in AiProvider.kinds)
                ChoiceChip(
                  label: Text(kind == 'anthropic' ? 'Anthropic' : 'OpenAI 兼容'),
                  selected: _kind == kind,
                  onSelected: (_) => setState(() => _kind = kind),
                ),
            ],
          ),
        ),
        ManageField(
          label: '接口地址',
          child: TextField(
            controller: _baseUrl,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              hintText: 'https://api.siliconflow.cn/v1',
            ),
          ),
        ),
        ManageField(
          label: '密钥',
          child: TextField(
            controller: _apiKey,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              helperText: _isNew
                  ? '只会存在你自己的服务器上，之后只看得到尾号'
                  : (provider!.hasKey && tail != null
                        ? '已保存 …$tail，留空表示不修改'
                        : '还没填过密钥'),
            ),
          ),
        ),
        ManageField(
          label: '模型',
          child: TextField(
            controller: _model,
            autocorrect: false,
            decoration: const InputDecoration(hintText: 'deepseek-chat'),
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _isDefault,
          title: const Text('设为默认渠道'),
          subtitle: const Text('问 AI 和月报默认用它'),
          onChanged: (value) => setState(() => _isDefault = value),
        ),
      ],
    );
  }
}
