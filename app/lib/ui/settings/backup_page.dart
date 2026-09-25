import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../data/models/models.dart';
import '../../data/repos/backup_repo.dart';
import '../widgets/widgets.dart';

/// WebDAV 备份：配置、定时、加密、立即备份、远端列表与恢复、导出到本机。
class BackupPage extends ConsumerStatefulWidget {
  const BackupPage({super.key});

  @override
  ConsumerState<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends ConsumerState<BackupPage> {
  final TextEditingController _url = TextEditingController();
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _remoteDir = TextEditingController();
  final TextEditingController _passphrase = TextEditingController();
  final TextEditingController _keep = TextEditingController(text: '14');

  bool _seeded = false;
  bool _scheduleEnabled = false;
  int _hour = 3;
  bool _encryptionEnabled = false;

  bool _saving = false;
  bool _testing = false;
  bool _running = false;
  bool _exporting = false;
  String? _restoring;

  String? _formError;
  String? _saveNote;
  String? _testMessage;
  bool _testOk = false;
  String? _actionMessage;
  String? _actionError;

  @override
  void dispose() {
    _url.dispose();
    _username.dispose();
    _password.dispose();
    _remoteDir.dispose();
    _passphrase.dispose();
    _keep.dispose();
    super.dispose();
  }

  void _seed(BackupConfig config) {
    _url.text = config.webdav.url;
    _username.text = config.webdav.username;
    _remoteDir.text = config.webdav.remoteDir;
    _password.clear();
    _passphrase.clear();
    _scheduleEnabled = config.schedule.enabled;
    _hour = config.schedule.hour;
    _keep.text = '${config.schedule.keep}';
    _encryptionEnabled = config.encryption.enabled;
  }

  /// 只在第一次拿到配置时回填表单，别把用户正在改的内容覆盖掉。
  void _seedOnce(BackupConfig config) {
    if (_seeded) return;
    _seeded = true;
    _seed(config);
  }

  Future<void> _save() async {
    final keep = int.tryParse(_keep.text.trim());
    if (keep == null || keep < 1) {
      setState(() => _formError = '保留份数要是个大于 0 的整数。');
      return;
    }
    if (_encryptionEnabled &&
        _passphrase.text.isEmpty &&
        !(ref.read(backupConfigProvider).valueOrNull?.encryption.hasPassphrase ?? false)) {
      setState(() => _formError = '开启加密必须先设一个密语（至少 8 个字符）。');
      return;
    }
    setState(() {
      _saving = true;
      _formError = null;
      _saveNote = null;
    });
    try {
      final updated = await ref.read(backupRepoProvider).saveConfig(
        url: _url.text.trim(),
        username: _username.text.trim(),
        password: _password.text,
        remoteDir: _remoteDir.text.trim(),
        scheduleEnabled: _scheduleEnabled,
        hour: _hour,
        keep: keep,
        encryptionEnabled: _encryptionEnabled,
        passphrase: _passphrase.text,
      );
      if (!mounted) return;
      setState(() {
        _seed(updated);
        _saveNote = '已保存';
      });
      ref.invalidate(backupConfigProvider);
    } catch (e) {
      if (mounted) setState(() => _formError = describeError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 测的是表单里现在填的值（没点「保存设置」也行）；口令框留空时，
  /// 只有地址还在同一台服务器上才沿用已保存的口令（见 [BackupRepo.test]）。
  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testMessage = null;
    });
    try {
      final result = await ref.read(backupRepoProvider).test(
        url: _url.text.trim(),
        username: _username.text.trim(),
        password: _password.text,
        remoteDir: _remoteDir.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _testOk = result.ok;
        _testMessage = result.message.isEmpty
            ? (result.ok ? '连上了。' : '没连上，服务端没说原因。')
            : result.message;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _testOk = false;
          _testMessage = describeError(e);
        });
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _runNow() async {
    setState(() {
      _running = true;
      _actionMessage = null;
      _actionError = null;
    });
    try {
      final result = await ref.read(backupRepoProvider).run();
      if (!mounted) return;
      setState(() {
        _actionMessage = '已备份 ${result.name} · ${formatBytes(result.bytes)} · '
            '用时 ${(result.tookMs / 1000).toStringAsFixed(1)} 秒';
      });
      ref.invalidate(backupListProvider);
      ref.invalidate(backupStatusProvider);
      ref.invalidate(backupConfigProvider);
    } catch (e) {
      if (mounted) setState(() => _actionError = describeError(e));
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _export() async {
    setState(() {
      _exporting = true;
      _actionMessage = null;
      _actionError = null;
    });
    try {
      final repo = ref.read(backupRepoProvider);
      final snapshot = await repo.export();
      await repo.shareExport(snapshot);
      if (!mounted) return;
      setState(() {
        _actionMessage = '已导出 ${snapshot.filename} · ${formatBytes(snapshot.size)}';
      });
    } catch (e) {
      if (mounted) setState(() => _actionError = describeError(e));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _restore(BackupItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('用「${item.name}」覆盖现在的数据？'),
        content: const Text(
          '恢复会把服务器上的数据库换成这份备份，这之后记的账会消失。\n\n'
          '覆盖前服务器会先把当前数据库另存成 pre-restore-*.db 放在数据目录里，'
          '万一恢复错了还能找回来。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认恢复'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() {
      _restoring = item.name;
      _actionMessage = null;
      _actionError = null;
    });
    try {
      final result = await ref.read(backupRepoProvider).restore(item.name);
      if (!mounted) return;
      setState(() {
        _actionMessage = '已从 ${result.restoredFrom} 恢复'
            '${result.preRestoreCopy.isEmpty ? '' : '，旧数据留在 ${result.preRestoreCopy}'}';
      });
      ref.invalidate(backupStatusProvider);
      ref.invalidate(backupListProvider);
      // 备份配置就住在被换掉的那个库的 meta 表里，得按恢复出来的库重填表单。
      // 光把 _seeded 置回 false 不够：`AsyncValueView` 的 skipLoadingOnRefresh
      // 会先拿旧值再回调一次 data，那一次就把「只回填一次」的名额用掉了 ——
      // 所以这里自己等新配置到手再填。
      _seeded = false;
      ref.invalidate(backupConfigProvider);
      try {
        final fresh = await ref.read(backupConfigProvider.future);
        if (mounted) setState(() => _seed(fresh));
      } catch (_) {
        // 配置没拉回来不影响「恢复成功」这件事，页面上还有重试。
      }
      // 服务端数据库整个换了，本地缓存必须全量重来。
      try {
        await ref.read(ledgerProvider.notifier).sync(full: true);
      } catch (_) {
        // 同步失败不影响「恢复成功」这件事，下拉刷新会再试。
      }
    } catch (e) {
      if (mounted) setState(() => _actionError = describeError(e));
    } finally {
      if (mounted) setState(() => _restoring = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(sessionProvider)?.me.isAdmin ?? false;
    if (!isAdmin) {
      return Scaffold(
        appBar: AppBar(title: const Text('备份与恢复')),
        body: const EmptyState(
          icon: Icons.lock_outline,
          title: '只有管理员能配置备份',
          message: '找家里的管理员去「设置 → 备份与恢复」里设。',
        ),
      );
    }

    final config = ref.watch(backupConfigProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('备份与恢复')),
      body: AsyncValueView<BackupConfig>(
        value: config,
        onRetry: () => ref.invalidate(backupConfigProvider),
        loading: const SkeletonList(rows: 4),
        data: (data) {
          _seedOnce(data);
          return ListView(
            padding: const EdgeInsets.only(bottom: 40),
            children: [
              ..._webdavSection(data),
              ..._scheduleSection(),
              ..._encryptionSection(data),
              ..._saveRow(),
              ..._actionsSection(),
              ..._listSection(),
              ..._statusSection(data),
            ],
          );
        },
      ),
    );
  }

  // —— WebDAV ——

  List<Widget> _webdavSection(BackupConfig config) {
    final theme = Theme.of(context);
    return [
      const SectionHeader('WebDAV'),
      Padding(
        padding: const EdgeInsets.fromLTRB(
          LedgerLayout.pagePadding,
          0,
          LedgerLayout.pagePadding,
          0,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '坚果云、群晖、Nextcloud 之类都行。每天一份数据库快照传上去。',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: LedgerLayout.itemGap),
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '地址',
                hintText: 'https://dav.jianguoyun.com/dav/',
              ),
            ),
            const SizedBox(height: LedgerLayout.itemGap),
            TextField(
              controller: _username,
              autocorrect: false,
              decoration: const InputDecoration(labelText: '用户名'),
            ),
            const SizedBox(height: LedgerLayout.itemGap),
            TextField(
              controller: _password,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: '口令',
                helperText: config.webdav.hasPassword ? '已保存，不填则保持不变' : '应用密码/授权码',
              ),
            ),
            const SizedBox(height: LedgerLayout.itemGap),
            TextField(
              controller: _remoteDir,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '远端目录',
                hintText: '/famledger',
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                SizedBox(
                  height: 48,
                  child: OutlinedButton(
                    onPressed: _testing ? null : _test,
                    child: Text(_testing ? '测试中…' : '测试连接'),
                  ),
                ),
                const SizedBox(width: 12),
                if (_testMessage != null)
                  Expanded(
                    child: Text(
                      _testMessage!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _testOk
                            ? LedgerColors.of(context).income
                            : theme.colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: LedgerLayout.groupGap),
    ];
  }

  // —— 定时 ——

  List<Widget> _scheduleSection() => [
    const SectionHeader('定时备份'),
    SwitchListTile(
      contentPadding: const EdgeInsets.symmetric(
        horizontal: LedgerLayout.pagePadding,
      ),
      value: _scheduleEnabled,
      onChanged: (v) => setState(() => _scheduleEnabled = v),
      title: const Text('每天自动备份'),
      subtitle: const Text('服务器到点自己跑，手机不用开着'),
    ),
    Padding(
      padding: const EdgeInsets.fromLTRB(
        LedgerLayout.pagePadding,
        8,
        LedgerLayout.pagePadding,
        0,
      ),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<int>(
              value: _hour,
              decoration: const InputDecoration(labelText: '时间'),
              items: [
                for (var h = 0; h < 24; h++)
                  DropdownMenuItem(
                    value: h,
                    child: Text('${h.toString().padLeft(2, '0')}:00'),
                  ),
              ],
              onChanged: _scheduleEnabled
                  ? (v) => setState(() => _hour = v ?? _hour)
                  : null,
            ),
          ),
          const SizedBox(width: LedgerLayout.itemGap),
          Expanded(
            child: TextField(
              controller: _keep,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: '保留份数',
                helperText: '多出来的旧备份自动删',
              ),
            ),
          ),
        ],
      ),
    ),
    const SizedBox(height: LedgerLayout.groupGap),
  ];

  // —— 加密 ——

  List<Widget> _encryptionSection(BackupConfig config) => [
    const SectionHeader('加密'),
    SwitchListTile(
      contentPadding: const EdgeInsets.symmetric(
        horizontal: LedgerLayout.pagePadding,
      ),
      value: _encryptionEnabled,
      onChanged: (v) => setState(() => _encryptionEnabled = v),
      title: const Text('加密备份文件'),
      subtitle: const Text('传到网盘上的文件别人打不开；密语丢了这些备份也就废了'),
    ),
    Padding(
      padding: const EdgeInsets.fromLTRB(
        LedgerLayout.pagePadding,
        8,
        LedgerLayout.pagePadding,
        0,
      ),
      child: TextField(
        controller: _passphrase,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        enabled: _encryptionEnabled,
        decoration: InputDecoration(
          labelText: '密语',
          helperText: config.encryption.hasPassphrase
              ? '已保存，不填则保持不变'
              : '至少 8 个字符，自己记住',
        ),
      ),
    ),
    const SizedBox(height: LedgerLayout.groupGap),
  ];

  List<Widget> _saveRow() {
    final theme = Theme.of(context);
    return [
      Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LedgerLayout.pagePadding,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_formError != null) ...[
              Text(
                _formError!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
              const SizedBox(height: 8),
            ],
            SizedBox(
              height: 48,
              width: double.infinity,
              child: FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? '保存中…' : '保存设置'),
              ),
            ),
            if (_saveNote != null) ...[
              const SizedBox(height: 8),
              Text(
                _saveNote!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: LedgerColors.of(context).income,
                ),
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: LedgerLayout.groupGap),
    ];
  }

  // —— 手动操作 ——

  List<Widget> _actionsSection() {
    final theme = Theme.of(context);
    final ledger = LedgerColors.of(context);
    return [
      const SectionHeader('手动'),
      Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LedgerLayout.pagePadding,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 48,
                    child: FilledButton.tonalIcon(
                      onPressed: _running ? null : _runNow,
                      icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                      label: Text(_running ? '备份中…' : '立即备份'),
                    ),
                  ),
                ),
                const SizedBox(width: LedgerLayout.itemGap),
                Expanded(
                  child: SizedBox(
                    height: 48,
                    child: OutlinedButton.icon(
                      onPressed: _exporting ? null : _export,
                      icon: const Icon(Icons.download_outlined, size: 18),
                      label: Text(_exporting ? '导出中…' : '导出到本机'),
                    ),
                  ),
                ),
              ],
            ),
            if (_running || _exporting || _restoring != null) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
            ],
            if (_actionMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                _actionMessage!,
                style: theme.textTheme.bodyMedium?.copyWith(color: ledger.income),
              ),
            ],
            if (_actionError != null) ...[
              const SizedBox(height: 12),
              Text(
                _actionError!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: LedgerLayout.groupGap),
    ];
  }

  // —— 远端列表 ——

  List<Widget> _listSection() {
    final theme = Theme.of(context);
    final items = ref.watch(backupListProvider);
    return [
      SectionHeader(
        '远端备份',
        actionLabel: '刷新',
        onAction: () => ref.invalidate(backupListProvider),
      ),
      AsyncValueView<List<BackupItem>>(
        value: items,
        onRetry: () => ref.invalidate(backupListProvider),
        loading: const SkeletonList(rows: 3),
        data: (list) => list.isEmpty
            ? const EmptyState(
                compact: true,
                title: '远端还没有备份',
                message: '填好 WebDAV 后点「立即备份」试一次。',
              )
            : Column(
                children: [
                  for (final item in list)
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: LedgerLayout.pagePadding,
                      ),
                      title: Row(
                        children: [
                          if (item.encrypted) ...[
                            const Icon(Icons.lock_outline, size: 14),
                            const SizedBox(width: 4),
                          ],
                          Flexible(
                            child: Text(
                              item.name,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                        ],
                      ),
                      subtitle: Text(
                        '${formatBytes(item.bytes)}'
                        '${item.modifiedAt == null ? '' : ' · ${Dates.dateTimeLabel(item.modifiedAt!.toLocal())}'}',
                        style: theme.textTheme.bodySmall,
                      ),
                      trailing: TextButton(
                        onPressed: _restoring != null ? null : () => _restore(item),
                        child: Text(_restoring == item.name ? '恢复中…' : '恢复'),
                      ),
                    ),
                ],
              ),
      ),
      const SizedBox(height: LedgerLayout.groupGap),
    ];
  }

  // —— 状态 ——

  List<Widget> _statusSection(BackupConfig config) {
    final theme = Theme.of(context);
    final status = ref.watch(backupStatusProvider);
    return [
      const SectionHeader('状态'),
      AsyncValueView<BackupStatus>(
        value: status,
        onRetry: () => ref.invalidate(backupStatusProvider),
        loading: const SkeletonList(rows: 2),
        data: (data) {
          final next = data.nextRun ?? config.nextRun;
          return Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: LedgerLayout.pagePadding,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  data.running ? '正在备份…' : '上次：${_runLabel(data.lastRun)}',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  next == null
                      ? '没开定时备份'
                      : '下次：${Dates.dateTimeLabel(next.toLocal())}',
                  style: theme.textTheme.bodySmall,
                ),
                if (data.history.length > 1) ...[
                  const SizedBox(height: LedgerLayout.itemGap),
                  Text('最近几次', style: theme.textTheme.bodySmall),
                  const SizedBox(height: 4),
                  for (final run in data.history.take(5))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Text(
                        _runLabel(run),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: run.ok == false
                              ? theme.colorScheme.error
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ],
            ),
          );
        },
      ),
    ];
  }

  static String _runLabel(BackupRun? run) {
    if (run == null) return '还没备份过';
    final at = run.at;
    final when = at == null ? '' : '${Dates.dateTimeLabel(at.toLocal())} · ';
    if (run.running) return '$when进行中';
    if (run.ok == true) {
      final size = run.bytes == null ? '' : ' · ${formatBytes(run.bytes!)}';
      return '$when成功${run.name == null ? '' : ' · ${run.name}'}$size';
    }
    return '$when失败${run.message == null ? '' : ' · ${run.message}'}';
  }
}
