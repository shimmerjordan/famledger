import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/repos/session_repo.dart';
import '../widgets/async_value_view.dart';
import 'auth_scaffold.dart';

/// 第一步：告诉 App 你的服务器在哪。
class ConnectPage extends ConsumerStatefulWidget {
  const ConnectPage({super.key});

  @override
  ConsumerState<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends ConsumerState<ConnectPage> {
  final TextEditingController _url = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final stored = ref.read(sessionProvider.notifier).storedBaseUrl;
    // Web 看板一般和后端同源，先替用户填好。
    _url.text = stored ?? (kIsWeb ? Uri.base.origin : '');
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session = ref.read(sessionProvider.notifier);
      await session.connect(_url.text);
      if (!mounted) return;
      context.go(session.needsSetup ? '/setup' : '/login');
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AuthScaffold(
      title: '连接你的家账服务器',
      subtitle: '填一次就好，之后这台设备会记住它。',
      footer: Text(
        '会检查 ${SessionRepo.normalizeUrl(_url.text).isEmpty ? '该地址' : '${SessionRepo.normalizeUrl(_url.text)}/healthz'} 是否可达。',
        style: theme.textTheme.bodySmall,
        textAlign: TextAlign.center,
      ),
      children: [
        TextField(
          controller: _url,
          autofocus: true,
          keyboardType: TextInputType.url,
          autocorrect: false,
          textInputAction: TextInputAction.go,
          // 底下那行「会检查 …」跟着输入走，不然填完还显示旧地址。
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _submit(),
          decoration: const InputDecoration(
            labelText: '服务器地址',
            hintText: 'ledger.example.com',
            prefixIcon: Icon(Icons.dns_outlined),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '不写 https:// 也行，内网地址会自动按 http 连、自动补 ${SessionRepo.defaultPort} 端口；'
          '公网域名（一般走反代）保持 https，端口不动。',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 20),
        FormError(_error),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('连接'),
        ),
      ],
    );
  }
}
