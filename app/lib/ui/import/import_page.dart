import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/repos/import_repo.dart';
import '../widgets/widgets.dart';
import 'import_layout.dart';
import 'import_providers.dart';

/// 导入账单的入口：选表格文件、粘贴文字、下载模板。
class ImportPage extends ConsumerStatefulWidget {
  const ImportPage({super.key});

  @override
  ConsumerState<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends ConsumerState<ImportPage> {
  bool _reading = false;
  String? _error;

  Future<void> _pick() async {
    setState(() => _error = null);
    final PickedImportFile? file;
    try {
      file = await ref.read(importFilePickerProvider)();
    } catch (e) {
      if (mounted) setState(() => _error = '打不开文件：${describeError(e)}');
      return;
    }
    if (file == null || !mounted) return;

    final name = file.name;
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    if (!kImportExtensions.contains(ext)) {
      setState(() => _error = '只认 csv 和 xlsx，「$name」不行');
      return;
    }
    if (!ImportRepo.fits(name, file.bytes.length)) {
      setState(() => _error = '文件太大了，最多 6MB，拆成几个再导');
      return;
    }

    setState(() => _reading = true);
    final ImportPreview preview;
    try {
      preview = await ref
          .read(importRepoProvider)
          .preview(filename: name, bytes: file.bytes);
    } catch (e) {
      if (mounted) {
        setState(() {
          _reading = false;
          _error = describeError(e);
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() => _reading = false);
    if (preview.rows.isEmpty) {
      setState(() => _error = '认出是${preview.sourceLabel}，但里面一笔交易都没有');
      return;
    }
    // 读的时候人已经走到别处去了（比如网页上改了地址），就别把核对页硬叠上去。
    if (ModalRoute.of(context)?.isCurrent == false) return;
    ref.read(pendingImportPreviewProvider.notifier).state = preview;
    context.push('/import/preview');
  }

  Future<void> _downloadTemplate() async {
    final uri = ref.read(apiProvider).uri('/import/template.csv');
    var ok = false;
    try {
      ok = await ref.read(importUrlOpenerProvider)(uri);
    } catch (_) {
      ok = false;
    }
    if (!ok && mounted) {
      setState(() => _error = '打不开下载链接，可以在浏览器里访问 $uri');
    }
  }

  @override
  Widget build(BuildContext context) {
    // 选文件页压在核对页底下，要替核对页把传过去的预览留住。
    ref.watch(pendingImportPreviewProvider);
    final theme = Theme.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final side = importPagePad(width) + importGutter(width, 720);
    final error = _error;

    return Scaffold(
      appBar: AppBar(title: const Text('导入账单')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(side, 8, side, 32),
        children: [
          Text('从表格导入', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            '支付宝、微信导出的账单，或者按模板填好的表格，csv 和 xlsx 都行。'
            '先预览，核对完再导入。',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: LedgerLayout.itemGap),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              key: const ValueKey('import-pick'),
              onPressed: _reading ? null : _pick,
              icon: _reading
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.upload_file_outlined),
              label: Text(_reading ? '正在读…' : '选文件'),
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: LedgerLayout.itemGap),
            Text(
              error,
              key: const ValueKey('import-error'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: LedgerLayout.groupGap),
          Text('粘贴文字', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            '把付款短信、通知粘进来，一段一笔，跟自动记账一样识别。',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: LedgerLayout.itemGap),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _reading ? null : () => context.push('/import/paste'),
              icon: const Icon(Icons.content_paste_outlined),
              label: const Text('粘贴导入'),
            ),
          ),
          const SizedBox(height: LedgerLayout.groupGap),
          Text('通用模板', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            '从别的记账软件搬过来？按模板一行一笔填好：日期、收支、金额，'
            '类别、基金、账户写名字就行。',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _reading ? null : _downloadTemplate,
              icon: const Icon(Icons.download_outlined),
              label: const Text('下载模板'),
            ),
          ),
          const SizedBox(height: LedgerLayout.groupGap),
          Divider(color: theme.colorScheme.outlineVariant),
          const SizedBox(height: LedgerLayout.itemGap),
          Text(
            '账单从哪来',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          const _HowTo(app: '支付宝', steps: '账单 → 右上角「…」→ 开具交易流水证明 → 用于个人对账'),
          const _HowTo(
            app: '微信',
            steps: '我 → 服务 → 钱包 → 账单 → 常见问题 → 下载账单 → 用于个人对账',
          ),
          const SizedBox(height: 4),
          Text(
            '账单会发到邮箱，是个带密码的压缩包，解压后选里面的文件。',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _HowTo extends StatelessWidget {
  const _HowTo({required this.app, required this.steps});

  final String app;
  final String steps;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: '$app：', style: theme.textTheme.titleSmall),
            TextSpan(text: steps),
          ],
        ),
        style: theme.textTheme.bodyMedium,
      ),
    );
  }
}
