import 'dart:convert';

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

/// 预设选完自动填地址与模型，密钥只写不读。「高级」里是渠道的 extra：附加请求参数（requestExtras，服务端只收白名单里的键，
/// 比如给 Qwen3 关掉思考 `{"enable_thinking": false}`）和 AI 导入单次最多输出多少 token（importMaxTokens，空 = 默认 12000）。
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
  late final TextEditingController _extras = TextEditingController(
    text: (widget.provider?.requestExtras ?? const {}).isEmpty ? '' : jsonEncode(widget.provider!.requestExtras),
  );
  late final TextEditingController _importMax = TextEditingController(
    text: widget.provider?.importMaxTokens?.toString() ?? '',
  );

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
    _extras.dispose();
    _importMax.dispose();
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

  /// 「高级」两栏 → 新的 extra（原来 extra 里别的键原样留着，比如以后的 vision）；填错回 null 并把原因写进 [_error]。
  Map<String, dynamic>? _readExtra() {
    final extra = Map<String, dynamic>.of(widget.provider?.extra ?? const {});
    final raw = _extras.text.trim();
    if (raw.isEmpty) {
      extra.remove('requestExtras');
    } else {
      Object? parsed;
      try {
        parsed = jsonDecode(raw);
      } catch (_) {
        parsed = null;
      }
      if (parsed is! Map) {
        setState(() => _error = '附加请求参数要写成 JSON 对象，比如 {"enable_thinking": false}');
        return null;
      }
      extra['requestExtras'] = Map<String, dynamic>.from(parsed);
    }
    final maxText = _importMax.text.trim();
    if (maxText.isEmpty) {
      extra.remove('importMaxTokens');
    } else {
      final n = int.tryParse(maxText);
      if (n == null || n < 256 || n > 64000) {
        setState(() => _error = '导入最多输出填 256 到 64000 之间的整数，留空用默认 12000');
        return null;
      }
      extra['importMaxTokens'] = n;
    }
    return extra;
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    final baseUrl = _baseUrl.text.trim();
    final model = _model.text.trim();
    if (name.isEmpty || baseUrl.isEmpty || model.isEmpty) {
      setState(() => _error = '名称、地址、模型都要填。');
      return;
    }
    final extra = _readExtra();
    if (extra == null) return;
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
          extra: extra.isEmpty ? null : extra,
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
          extra: extra,
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
        ExpansionTile(
          key: const ValueKey('ai-provider-advanced'),
          tilePadding: EdgeInsets.zero,
          shape: const Border(),
          collapsedShape: const Border(),
          initiallyExpanded: _extras.text.isNotEmpty || _importMax.text.isNotEmpty,
          title: const Text('高级'),
          subtitle: const Text('附加请求参数、导入的输出上限'),
          children: [
            ManageField(
              label: '附加请求参数（JSON）',
              child: TextField(
                key: const ValueKey('ai-provider-extras'),
                controller: _extras,
                autocorrect: false,
                maxLines: 3,
                minLines: 1,
                decoration: const InputDecoration(
                  hintText: '{"enable_thinking": false}',
                  helperText: '只收 temperature、top_p、enable_thinking、thinking 等常用参数',
                ),
              ),
            ),
            ManageField(
              label: '导入最多输出（token）',
              child: TextField(
                key: const ValueKey('ai-provider-import-max'),
                controller: _importMax,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(hintText: '12000', helperText: '模型说「超过上限」时调小；留空用默认'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
