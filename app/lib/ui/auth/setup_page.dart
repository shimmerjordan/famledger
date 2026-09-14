import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../widgets/async_value_view.dart';
import 'auth_scaffold.dart';

/// 服务器上还没有任何用户时的第一次初始化。
class SetupPage extends ConsumerStatefulWidget {
  const SetupPage({super.key});

  @override
  ConsumerState<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends ConsumerState<SetupPage> {
  final _household = TextEditingController();
  final _displayName = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _setupToken = TextEditingController();

  bool _busy = false;
  bool _needToken = false;
  String? _error;

  @override
  void dispose() {
    _household.dispose();
    _displayName.dispose();
    _username.dispose();
    _password.dispose();
    _confirm.dispose();
    _setupToken.dispose();
    super.dispose();
  }

  String? _validate() {
    if (_household.text.trim().isEmpty) return '给这个家起个名字吧。';
    if (_displayName.text.trim().isEmpty) return '填一下家里人怎么称呼你。';
    if (_username.text.trim().length < 2) return '用户名至少 2 个字符。';
    if (_password.text.length < 6) return '密码至少 6 位。';
    if (_password.text != _confirm.text) return '两次输入的密码不一样。';
    return null;
  }

  Future<void> _submit() async {
    if (_busy) return;
    final invalid = _validate();
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(sessionProvider.notifier).setup(
        householdName: _household.text.trim(),
        username: _username.text.trim(),
        password: _password.text,
        displayName: _displayName.text.trim(),
        setupToken: _setupToken.text.trim(),
      );
      if (mounted) context.go('/home');
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AuthScaffold(
    title: '建立你们家的账本',
    subtitle: '这是第一位成员，也是管理员。之后可以在「我的 · 成员」里加人。',
    footer: TextButton(
      onPressed: () => context.go('/connect'),
      child: const Text('换个服务器'),
    ),
    children: [
      TextField(
        controller: _household,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: '家庭名称',
          hintText: '例如：我们家',
          prefixIcon: Icon(Icons.home_outlined),
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _displayName,
        decoration: const InputDecoration(
          labelText: '你的称呼',
          hintText: '例如：爸爸',
          prefixIcon: Icon(Icons.person_outline),
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _username,
        autocorrect: false,
        decoration: const InputDecoration(
          labelText: '登录用户名',
          prefixIcon: Icon(Icons.badge_outlined),
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _password,
        obscureText: true,
        decoration: const InputDecoration(
          labelText: '密码',
          prefixIcon: Icon(Icons.lock_outline),
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _confirm,
        obscureText: true,
        textInputAction: TextInputAction.go,
        onSubmitted: (_) => _submit(),
        decoration: const InputDecoration(
          labelText: '再输一次密码',
          prefixIcon: Icon(Icons.lock_outline),
        ),
      ),
      if (_needToken) ...[
        const SizedBox(height: 12),
        TextField(
          controller: _setupToken,
          decoration: const InputDecoration(
            labelText: '初始化口令',
            helperText: '服务端设了 SETUP_TOKEN 时才需要',
            prefixIcon: Icon(Icons.key_outlined),
          ),
        ),
      ] else
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => setState(() => _needToken = true),
            child: const Text('服务端设了初始化口令？'),
          ),
        ),
      const SizedBox(height: 12),
      FormError(_error),
      FilledButton(
        onPressed: _busy ? null : _submit,
        child: _busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('创建家庭'),
      ),
    ],
  );
}
