import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../capture/parser.dart';
import '../../capture/pipeline.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../../platform/capture_channel.dart';
import '../../platform/capture_dry_run.dart';
import '../../platform/capture_providers.dart';
import '../../platform/file_capture_store.dart';
import '../../platform/share_import.dart';
import '../widgets/widgets.dart';
import 'capture_apps_sheet.dart';
import 'capture_widgets.dart';

/// 自动记账：权限状态、允许的应用、识别参数、测试解析、最近捕获。
///
/// Android 之外只剩识别参数与测试解析（iOS 走分享/快捷指令，网页版没有自动记账）。
class CapturePage extends ConsumerStatefulWidget {
  const CapturePage({super.key});

  @override
  ConsumerState<CapturePage> createState() => _CapturePageState();
}

/// 「测试解析」可选的来源。
class _DrySource {
  const _DrySource(this.label, this.package, this.title);

  final String label;
  final String package;
  final String title;

  static const List<_DrySource> all = [
    _DrySource('支付宝', 'com.eg.android.AlipayGphone', '支付宝'),
    _DrySource('微信支付', 'com.tencent.mm', '微信支付'),
    _DrySource('云闪付', 'com.unionpay', '云闪付'),
    _DrySource('银行短信', 'com.android.mms', '95555'),
    _DrySource('银行 App', 'cmb.pb', '招商银行'),
    _DrySource('其他应用', 'com.example.other', '通知'),
  ];
}

class _CapturePageState extends ConsumerState<CapturePage> with WidgetsBindingObserver {
  final TextEditingController _dryText = TextEditingController();
  _DrySource _drySource = _DrySource.all.first;
  CaptureDryRun? _dryResult;
  bool _dryBusy = false;

  /// iOS「从剪贴板导入」的结果。
  CaptureOutcome? _clipboardOutcome;
  String? _clipboardTxId;
  bool _importing = false;

  /// 拖动滑条时的临时值；松手后 PATCH，成功前一直显示它。
  double? _threshold;
  bool _savingSettings = false;
  String? _settingsError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dryText.dispose();
    super.dispose();
  }

  /// 从系统设置页回来要重新查一遍权限。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshStatus();
  }

  void _refreshStatus() {
    ref.invalidate(listenerEnabledProvider);
    ref.invalidate(notificationPermissionProvider);
    ref.invalidate(allowedPackagesProvider);
    ref.invalidate(recentCapturesProvider);
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // ------------------------------------------------------------ 动作

  Future<void> _patchCapture(Map<String, dynamic> patch) async {
    setState(() {
      _savingSettings = true;
      _settingsError = null;
    });
    try {
      await ref.read(settingsProvider.notifier).patch({'capture': patch});
    } catch (e) {
      if (mounted) setState(() => _settingsError = '没改成：${describeError(e)}');
    } finally {
      if (mounted) {
        setState(() {
          _savingSettings = false;
          _threshold = null;
        });
      }
    }
  }

  Future<void> _editAllowed(List<String> current) async {
    final platform = ref.read(capturePlatformProvider);
    final installed = await ref.read(installedAppsProvider.future);
    if (!mounted) return;
    final picked = await showAllowedAppsSheet(context, selected: current, installed: installed);
    if (picked == null) return;
    await platform.setAllowedPackages(picked);
    ref.invalidate(allowedPackagesProvider);
  }

  Future<void> _runDryRun() async {
    final text = _dryText.text.trim();
    if (text.isEmpty) return;
    setState(() => _dryBusy = true);
    try {
      final ledger = ref.read(ledgerProvider).valueOrNull ?? const LedgerData();
      final settings = ref.read(settingsProvider).valueOrNull?.capture ?? const CaptureSettings();
      final memberId = ref.read(sessionProvider)?.me.id ?? '';
      LocalCaptureStore? store;
      try {
        store = await ref.read(captureStoreProvider.future);
      } catch (_) {
        // 存储打不开就用种子模型解析
      }
      final result = await dryRunCapture(
        notification: RawNotification(
          packageName: _drySource.package,
          title: _drySource.title,
          text: text,
          postedAt: DateTime.now(),
        ),
        ledger: ledger,
        settings: settings,
        memberId: memberId,
        modelSource: store,
      );
      if (mounted) setState(() => _dryResult = result);
    } catch (e) {
      _toast('解析失败：$e');
    } finally {
      if (mounted) setState(() => _dryBusy = false);
    }
  }

  /// iOS：把剪贴板里的文字喂给管线（Task 14b 的分享导入服务）。
  Future<void> _importClipboard() async {
    setState(() => _importing = true);
    try {
      final outcome = await ref.read(shareImportProvider).importFromClipboard();
      if (!mounted) return;
      if (outcome == null) {
        _toast('剪贴板是空的');
        return;
      }
      String? txId;
      final captureId = outcome.captureId;
      if (captureId != null) {
        try {
          final store = await ref.read(captureStoreProvider.future);
          txId = (await store.loadCapture(captureId))?.transactionId;
        } catch (_) {
          // 打不开存储就只显示结论，不给「打开」
        }
      }
      if (mounted) {
        setState(() {
          _clipboardOutcome = outcome;
          _clipboardTxId = txId;
        });
      }
    } catch (e) {
      _toast('导入失败：$e');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _sendTestNotification() async {
    final ok = await ref
        .read(capturePlatformProvider)
        .postTestNotification('支付宝', '你有一笔35.00元的支出，来自美团');
    _toast(ok ? '已发出测试通知，几秒后看通知栏' : '只有调试构建能发测试通知');
  }

  // ------------------------------------------------------------ 界面

  @override
  Widget build(BuildContext context) {
    final platform = ref.watch(capturePlatformProvider);
    final supported = platform.isSupported;
    final isAdmin = ref.watch(sessionProvider)?.me.isAdmin ?? false;
    final settings = ref.watch(settingsProvider);
    final ledger = ref.watch(ledgerProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(
        title: const Text('自动记账'),
        actions: [
          if (supported)
            IconButton(
              tooltip: '重新检查',
              icon: const Icon(Icons.refresh),
              onPressed: _refreshStatus,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          if (!supported) ...[
            CapturePlatformNotice(isWeb: kIsWeb),
            if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) ...[
              const SizedBox(height: LedgerLayout.groupGap),
              _iosImportSection(),
            ],
            const SizedBox(height: LedgerLayout.groupGap),
          ] else ...[
            const SectionHeader('权限'),
            _listenerTile(platform),
            _notificationTile(platform),
            _miuiTile(platform),
            const SizedBox(height: LedgerLayout.groupGap),
            _allowedSection(),
            const SizedBox(height: LedgerLayout.groupGap),
          ],
          const SectionHeader('识别'),
          _recognitionSection(settings, ledger, isAdmin),
          const SizedBox(height: LedgerLayout.groupGap),
          const SectionHeader('测试解析'),
          _dryRunSection(ledger),
          if (supported) ...[
            const SizedBox(height: LedgerLayout.groupGap),
            _recentSection(),
            if (kDebugMode) ...[
              const SizedBox(height: LedgerLayout.groupGap),
              const SectionHeader('调试'),
              ListTile(
                leading: const Icon(Icons.bug_report_outlined),
                title: const Text('发送测试通知'),
                subtitle: const Text('从本机发一条假的支付宝支出通知，走一遍完整管线'),
                trailing: const Icon(Icons.chevron_right, size: 20),
                onTap: _sendTestNotification,
              ),
            ],
          ],
        ],
      ),
    );
  }

  /// iOS 没有通知监听，入口是分享扩展 / 快捷指令 / 剪贴板。
  Widget _iosImportSection() {
    final theme = Theme.of(context);
    final outcome = _clipboardOutcome;
    final txId = _clipboardTxId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader('导入'),
        ListTile(
          leading: const Icon(Icons.content_paste_go_outlined),
          title: const Text('从剪贴板导入'),
          subtitle: const Text('先复制支付通知或短信里的文字，再点这里'),
          trailing: _importing
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.chevron_right, size: 20),
          onTap: _importing ? null : _importClipboard,
        ),
        if (outcome != null)
          Container(
            margin: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 4, LedgerLayout.pagePadding, 8),
            padding: const EdgeInsets.all(LedgerLayout.pagePadding),
            decoration: BoxDecoration(
              color: LedgerColors.of(context).surface2,
              borderRadius: BorderRadius.circular(LedgerShapes.card),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    DecisionChip(outcome.decision.name),
                    const SizedBox(width: 8),
                    Expanded(child: Text(outcome.title, style: theme.textTheme.titleMedium)),
                  ],
                ),
                const SizedBox(height: 4),
                Text(outcome.body, style: theme.textTheme.bodySmall),
                if (txId != null) ...[
                  const SizedBox(height: LedgerLayout.itemGap),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.tonal(
                      onPressed: () => context.push('/transactions/$txId'),
                      child: const Text('打开'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ListTile(
          leading: const Icon(Icons.ios_share_outlined),
          title: const Text('分享扩展与快捷指令'),
          subtitle: Text.rich(
            TextSpan(
              children: [
                const TextSpan(text: '在支付 App 的分享面板里选「家账」，或用快捷指令「记一笔」把文字送进来；配置步骤见 '),
                TextSpan(
                  text: 'docs/ios.md',
                  style: TextStyle(
                    color: theme.colorScheme.primary,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ],
            ),
          ),
          onTap: () => _toast('说明在仓库的 docs/ios.md'),
        ),
      ],
    );
  }

  Widget _listenerTile(CapturePlatform platform) {
    final enabled = ref.watch(listenerEnabledProvider);
    final ok = enabled.valueOrNull ?? false;
    return CaptureStatusTile(
      title: '通知使用权',
      pending: enabled.isLoading && !enabled.hasValue,
      ok: ok,
      subtitle: ok ? '已开启 · 家账会读取下面允许的应用发出的通知' : '未开启 · 系统还不允许家账读取支付通知',
      actionLabel: '去开启',
      onAction: platform.openListenerSettings,
    );
  }

  Widget _notificationTile(CapturePlatform platform) {
    final permission = ref.watch(notificationPermissionProvider).valueOrNull;
    if (permission == null || permission == NotificationPermission.notRequired) {
      return const SizedBox.shrink();
    }
    final ok = permission == NotificationPermission.granted;
    return CaptureStatusTile(
      title: '通知权限',
      ok: ok,
      subtitle: ok ? '已允许 · 记账结果会以通知形式出现' : '未允许 · 看不到记账结果和「正确 / 修改」按钮',
      actionLabel: '允许',
      onAction: platform.requestNotificationPermission,
    );
  }

  Widget _miuiTile(CapturePlatform platform) {
    final device = ref.watch(deviceInfoProvider).valueOrNull;
    if (device == null || !device.isMiui) return const SizedBox.shrink();
    return ListTile(
      leading: const Icon(Icons.battery_saver_outlined),
      title: const Text('后台保活（MIUI）'),
      subtitle: const Text('允许「自启动」，省电策略选「无限制」，否则系统会悄悄停掉监听'),
      trailing: FilledButton.tonal(
        onPressed: () async {
          final opened = await platform.openAutoStartSettings();
          if (opened == 'app_details') _toast('没找到 MIUI 的自启动页，已打开应用详情');
        },
        child: const Text('去设置'),
      ),
    );
  }

  Widget _allowedSection() {
    final allowed = ref.watch(allowedPackagesProvider).valueOrNull ?? const <String>[];
    final apps = ref.watch(installedAppsProvider).valueOrNull ?? const <InstalledApp>[];
    final labels = {for (final a in apps) a.package: a.label};
    // 装了的排前面，其余按名字；没装的淡一点，免得一排「招商银行 / 建设银行…」看着像都在用。
    final sorted = [...allowed]..sort((a, b) {
      final ia = labels.containsKey(a) ? 0 : 1;
      final ib = labels.containsKey(b) ? 0 : 1;
      if (ia != ib) return ia - ib;
      return appLabelFor(a, labels).compareTo(appLabelFor(b, labels));
    });
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          '允许的应用',
          actionLabel: '编辑',
          onAction: () => _editAllowed(allowed),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
          child: allowed.isEmpty
              ? Text('还没有允许任何应用，自动记账不会读取任何通知。', style: theme.textTheme.bodyMedium)
              : Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final pkg in sorted)
                      Chip(
                        label: Text(
                          appLabelFor(pkg, labels),
                          style: labels.containsKey(pkg)
                              ? null
                              : TextStyle(color: theme.colorScheme.onSurfaceVariant),
                        ),
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 8, LedgerLayout.pagePadding, 0),
          child: Text(
            allowed.any((p) => !labels.containsKey(p))
                ? '只有这些应用发出的通知会被读取；灰色的是这台手机上还没装的。'
                : '只有这些应用发出的通知会被读取；其余一律不看。',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  Widget _recognitionSection(AsyncValue<Settings> settings, LedgerData? ledger, bool isAdmin) {
    final theme = Theme.of(context);
    final capture = settings.valueOrNull?.capture ?? const CaptureSettings();
    final threshold = _threshold ?? capture.autoConfirmThreshold.clamp(0.5, 0.95);
    final canEdit = isAdmin && !_savingSettings;
    final funds = ledger?.activeFunds ?? const <Fund>[];
    final accounts = ledger?.activeAccounts ?? const <Account>[];
    final fundValue = funds.any((f) => f.id == capture.defaultFundId) ? capture.defaultFundId : null;
    final accountValue =
        accounts.any((a) => a.id == capture.defaultAccountId) ? capture.defaultAccountId : null;
    final error = _settingsError;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          title: const Text('自动确认阈值'),
          subtitle: const Text('置信度达到这个值就直接入账，否则进「待确认」'),
          trailing: Text('${(threshold * 100).round()}%', style: theme.textTheme.titleMedium),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
          child: Slider(
            value: threshold,
            min: 0.5,
            max: 0.95,
            divisions: 9,
            label: '${(threshold * 100).round()}%',
            onChanged: canEdit ? (v) => setState(() => _threshold = v) : null,
            onChangeEnd: canEdit
                ? (v) => _patchCapture({'autoConfirmThreshold': double.parse(v.toStringAsFixed(2))})
                : null,
          ),
        ),
        ListTile(
          title: const Text('默认基金'),
          subtitle: const Text('模型拿不准归哪个基金时用它'),
          trailing: DropdownButton<String?>(
            value: fundValue,
            hint: const Text('自动'),
            underline: const SizedBox.shrink(),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('自动')),
              for (final f in funds) DropdownMenuItem<String?>(value: f.id, child: Text(f.name)),
            ],
            onChanged: canEdit ? (v) => _patchCapture({'defaultFundId': v}) : null,
          ),
        ),
        ListTile(
          title: const Text('默认账户'),
          subtitle: const Text('卡尾号、包名都对不上时用它'),
          trailing: DropdownButton<String?>(
            value: accountValue,
            hint: const Text('不指定'),
            underline: const SizedBox.shrink(),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('不指定')),
              for (final a in accounts) DropdownMenuItem<String?>(value: a.id, child: Text(a.name)),
            ],
            onChanged: canEdit ? (v) => _patchCapture({'defaultAccountId': v}) : null,
          ),
        ),
        SwitchListTile(
          title: const Text('AI 兜底'),
          subtitle: const Text('置信度不够时，让 AI 渠道再判一次类别与基金'),
          value: capture.llmFallback,
          onChanged: canEdit ? (v) => _patchCapture({'llmFallback': v}) : null,
        ),
        if (!isAdmin)
          Padding(
            padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 4, LedgerLayout.pagePadding, 0),
            child: Text('只有管理员能改识别设置。', style: theme.textTheme.bodySmall),
          ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 4, LedgerLayout.pagePadding, 0),
            child: Text(error, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error)),
          ),
      ],
    );
  }

  Widget _dryRunSection(LedgerData? ledger) {
    final result = _dryResult;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<_DrySource>(
                value: _drySource,
                decoration: const InputDecoration(labelText: '来源'),
                items: [
                  for (final s in _DrySource.all) DropdownMenuItem(value: s, child: Text(s.label)),
                ],
                onChanged: (v) => setState(() => _drySource = v ?? _drySource),
              ),
              const SizedBox(height: LedgerLayout.itemGap),
              TextField(
                controller: _dryText,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: '通知正文',
                  hintText: '粘贴一条支付通知，比如：你有一笔35.00元的支出，来自美团',
                ),
              ),
              const SizedBox(height: LedgerLayout.itemGap),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonal(
                  onPressed: _dryBusy ? null : _runDryRun,
                  child: const Text('解析'),
                ),
              ),
            ],
          ),
        ),
        if (result != null) ...[
          const SizedBox(height: LedgerLayout.itemGap),
          DryRunResultPanel(result: result, ledger: ledger),
        ],
      ],
    );
  }

  Widget _recentSection() {
    final recent = ref.watch(recentCapturesProvider);
    final apps = ref.watch(installedAppsProvider).valueOrNull ?? const <InstalledApp>[];
    final labels = {for (final a in apps) a.package: a.label};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          '最近捕获',
          actionLabel: (recent.valueOrNull?.isNotEmpty ?? false) ? '清空' : null,
          onAction: () async {
            final store = await ref.read(captureStoreProvider.future);
            await store.clearRecent();
            ref.invalidate(recentCapturesProvider);
          },
        ),
        AsyncValueView(
          value: recent,
          loading: const SkeletonList(rows: 3),
          onRetry: () => ref.invalidate(recentCapturesProvider),
          data: (entries) {
            if (entries.isEmpty) {
              return const EmptyState(
                compact: true,
                title: '还没有捕获记录',
                message: '开启通知使用权后，支付通知一到就会出现在这里。',
              );
            }
            return Column(
              children: [
                for (final e in entries)
                  CaptureRecentTile(
                    entry: e,
                    appLabel: appLabelFor(e.package, labels),
                    onTap: e.transactionId == null
                        ? null
                        : () => context.push('/transactions/${e.transactionId}'),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}
