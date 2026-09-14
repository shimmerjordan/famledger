import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../core/money.dart';
import '../../data/repos/transactions_repo.dart';
import '../widgets/async_value_view.dart';

/// 服务器与账号：地址、当前成员、改密码、切服务器、退出登录。
class ServerPage extends ConsumerStatefulWidget {
  const ServerPage({super.key});

  @override
  ConsumerState<ServerPage> createState() => _ServerPageState();
}

class _ServerPageState extends ConsumerState<ServerPage> {
  int? _pending;
  bool _busy = false;
  List<OutboxFailure> _failed = const [];
  bool _showFailed = false;

  /// 读本地队列 / 清被拒记录出了错：一句说明 + 对应的重试动作，行内显示
  /// （initState 里没法弹 SnackBar，而且这种错要一直看得见，直到重试成功）。
  ({String message, Future<void> Function() retry})? _problem;

  @override
  void initState() {
    super.initState();
    _loadPending();
  }

  Future<void> _loadPending() async {
    final repo = ref.read(transactionsRepoProvider);
    try {
      final count = await repo.pendingCount();
      final failed = await repo.loadFailed();
      if (!mounted) return;
      setState(() {
        _pending = count;
        _failed = failed;
        _problem = null;
      });
    } catch (e) {
      // 本地存储读不出来：不能装作「都同步完了」，也不能让整页崩掉。
      if (!mounted) return;
      setState(
        () => _problem = (message: describeError(e), retry: _loadPending),
      );
    }
  }

  Future<void> _clearFailed() async {
    try {
      await ref.read(transactionsRepoProvider).clearFailed();
      if (!mounted) return;
      setState(() {
        _failed = const [];
        _showFailed = false;
        _problem = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _problem = (message: describeError(e), retry: _clearFailed),
      );
    }
  }

  /// 「待上传」那一行的副标题：读不出来要说出来，别装作没事。
  String _pendingLabel() {
    final pending = _pending;
    if (pending == null) {
      return _problem == null ? '正在读取本地队列…' : '本地队列没读出来';
    }
    return pending == 0 ? '都同步完了' : '还有 $pending 条离线记录没发出去';
  }

  Future<void> _flush() async {
    setState(() => _busy = true);
    try {
      await ref.read(transactionsRepoProvider).flushOutbox();
      await _loadPending();
      if (mounted) _toast('已尝试上传');
    } catch (e) {
      if (mounted) _toast(describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  Future<void> _changePassword() async {
    final oldPassword = TextEditingController();
    final newPassword = TextEditingController();
    final confirm = TextEditingController();
    final messenger = ScaffoldMessenger.of(context);

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('修改密码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: oldPassword,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(labelText: '当前密码'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: newPassword,
              obscureText: true,
              decoration: const InputDecoration(labelText: '新密码'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: confirm,
              obscureText: true,
              decoration: const InputDecoration(labelText: '再输一次'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    );

    if (ok != true) return;
    if (newPassword.text.length < 6) {
      messenger.showSnackBar(const SnackBar(content: Text('新密码至少 6 位。')));
      return;
    }
    if (newPassword.text != confirm.text) {
      messenger.showSnackBar(const SnackBar(content: Text('两次输入的新密码不一样。')));
      return;
    }
    try {
      await ref.read(sessionProvider.notifier).changePassword(
        oldPassword: oldPassword.text,
        newPassword: newPassword.text,
      );
      messenger.showSnackBar(const SnackBar(content: Text('密码已更新')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(describeError(e))));
    }
  }

  Future<void> _logout({required String goTo}) async {
    final router = GoRouter.of(context);
    await ref.read(sessionProvider.notifier).logout();
    router.go(goTo);
  }

  Future<bool> _confirm(String title, String message) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('继续'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = ref.watch(sessionProvider);
    final pending = _pending ?? 0;

    return Scaffold(
      appBar: AppBar(title: const Text('服务器与账号')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('服务器地址'),
            subtitle: Text(session?.baseUrl ?? '未连接'),
          ),
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: const Text('当前成员'),
            subtitle: Text(
              session == null
                  ? '未登录'
                  : '${session.me.label} · @${session.me.username}'
                        '${session.me.isAdmin ? ' · 管理员' : ''}',
            ),
          ),
          ListTile(
            leading: const Icon(Icons.cloud_upload_outlined),
            title: const Text('待上传'),
            subtitle: Text(_pendingLabel()),
            trailing: pending == 0
                ? null
                : TextButton(
                    onPressed: _busy ? null : _flush,
                    child: const Text('立即上传'),
                  ),
          ),
          if (_problem != null)
            InlineError(
              message: _problem!.message,
              onRetry: _problem!.retry,
              padding: const EdgeInsets.fromLTRB(
                LedgerLayout.pagePadding + 40,
                0,
                LedgerLayout.pagePadding,
                8,
              ),
            ),
          if (_failed.isNotEmpty) ...[
            ListTile(
              leading: Icon(
                Icons.error_outline,
                color: theme.colorScheme.error,
              ),
              title: Text(
                '${_failed.length} 条未能上传',
                style: TextStyle(color: theme.colorScheme.error),
              ),
              subtitle: const Text('服务端没有收下，需要你确认后重新记一笔'),
              trailing: TextButton(
                onPressed: () => setState(() => _showFailed = !_showFailed),
                child: Text(_showFailed ? '收起' : '查看详情'),
              ),
            ),
            if (_showFailed) ...[
              for (final failure in _failed) _FailedRow(failure: failure),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  LedgerLayout.pagePadding,
                  0,
                  LedgerLayout.pagePadding,
                  8,
                ),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: _clearFailed,
                    child: const Text('清除'),
                  ),
                ),
              ),
            ],
          ],
          const Divider(height: LedgerLayout.groupGap),
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: const Text('修改密码'),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: _changePassword,
          ),
          ListTile(
            leading: const Icon(Icons.swap_horiz),
            title: const Text('切换服务器'),
            subtitle: const Text('会退出当前登录，并回到连接向导'),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () async {
              if (await _confirm('切换服务器？', '当前账号会退出登录，本地缓存会清空。')) {
                await _logout(goTo: '/connect');
              }
            },
          ),
          ListTile(
            leading: Icon(Icons.logout, color: theme.colorScheme.error),
            title: Text(
              '退出登录',
              style: TextStyle(color: theme.colorScheme.error),
            ),
            onTap: () async {
              if (pending > 0 &&
                  !await _confirm('还有 $pending 条没上传', '退出登录会清掉这些离线记录，确定吗？')) {
                return;
              }
              await _logout(goTo: '/login');
            },
          ),
        ],
      ),
    );
  }
}

/// 一条「服务端没收」的记录：什么时候、多少钱、为什么被拒。
class _FailedRow extends StatelessWidget {
  const _FailedRow({required this.failure});

  final OutboxFailure failure;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cents = failure.payload['amountCents'];
    final amount = cents is num ? Money.format(cents.toInt()) : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LedgerLayout.pagePadding + 40,
        0,
        LedgerLayout.pagePadding,
        12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  Dates.dateTimeLabel(failure.at),
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              if (amount != null)
                Text(amount, style: theme.textTheme.bodyMedium),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '${failure.message}（${failure.code}）',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
          Text(
            failure.clientId,
            style: theme.textTheme.bodySmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
