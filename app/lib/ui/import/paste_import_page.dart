import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../capture/pipeline.dart' show CaptureDecision, CaptureOutcome;
import '../../core/dates.dart';
import '../../platform/share_import.dart';
import '../widgets/widgets.dart';
import 'import_layout.dart';
import 'import_providers.dart';

/// 粘贴导入：空行分开的每一段当一笔，走自动记账同一条管线。
class PasteImportPage extends ConsumerStatefulWidget {
  const PasteImportPage({super.key});

  @override
  ConsumerState<PasteImportPage> createState() => _PasteImportPageState();
}

class _PasteImportPageState extends ConsumerState<PasteImportPage> {
  final TextEditingController _text = TextEditingController();
  bool _busy = false;
  String? _error;
  List<PastedEntry>? _results;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _pasteClipboard() async {
    String? text;
    try {
      text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } catch (_) {
      // 火狐压根不给网页读剪贴板，别的浏览器用户点了「拒绝」也是这样：不是空的，是读不到。
      if (mounted) {
        setState(
          () => _error = kIsWeb
              ? '浏览器不让读剪贴板，直接在框里按 Ctrl+V（手机上长按粘贴）'
              : '读不到剪贴板，直接在框里长按粘贴',
        );
      }
      return;
    }
    if (!mounted) return;
    if (text == null || text.trim().isEmpty) {
      setState(() => _error = '剪贴板是空的');
      return;
    }
    final current = _text.text.trimRight();
    _text.text = current.isEmpty ? text : '$current\n\n$text';
    setState(() => _error = null);
  }

  Future<void> _run() async {
    if (ShareImportService.splitPasted(_text.text).isEmpty) {
      setState(() => _error = '先粘点东西进来');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final results = await ref
          .read(shareImportProvider)
          .importPasted(_text.text);
      if (!mounted) return;
      if (results.any(_landed)) refreshAfterImport(ref);
      setState(() => _results = results);
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static bool _landed(PastedEntry e) =>
      e.outcome.captureId != null && !e.outcome.offline;

  Future<void> _resend() async {
    final before = _results;
    if (before == null) return;
    setState(() => _busy = true);
    try {
      final after = await ref.read(shareImportProvider).resendPasted(before);
      if (!mounted) return;
      if (after.where(_landed).length > before.where(_landed).length) {
        refreshAfterImport(ref);
      }
      setState(() => _results = after);
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final side = importPagePad(width) + importGutter(width, 720);
    final results = _results;
    final error = _error;
    final offline = results?.where((e) => e.outcome.offline).length ?? 0;

    return Scaffold(
      appBar: AppBar(title: const Text('粘贴导入')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(side, 8, side, 32),
        children: [
          Text(
            '把付款短信、通知粘在下面，多笔之间空一行。认得准的直接记下，'
            '拿不准的放进首页「待确认」。没写日期的按今天记。',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: LedgerLayout.itemGap),
          TextField(
            key: const ValueKey('paste-text'),
            controller: _text,
            minLines: 6,
            maxLines: 14,
            keyboardType: TextInputType.multiline,
            decoration: const InputDecoration(
              hintText: '你有一笔35.00元的支出，来自美团\n\n您尾号1234的卡消费58.00元',
            ),
          ),
          const SizedBox(height: 8),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _text,
            builder: (context, value, _) {
              final n = ShareImportService.splitPasted(value.text).length;
              return Text(
                n == 0 ? '还没有内容' : '分成了 $n 段，一段记一笔',
                style: theme.textTheme.bodySmall,
              );
            },
          ),
          if (error != null) ...[
            const SizedBox(height: 8),
            Text(
              error,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: LedgerLayout.itemGap),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton.icon(
                onPressed: _busy ? null : _pasteClipboard,
                icon: const Icon(Icons.content_paste_outlined),
                label: const Text('从剪贴板粘贴'),
              ),
              FilledButton(
                key: const ValueKey('paste-run'),
                onPressed: _busy ? null : _run,
                child: Text(_busy ? '正在识别…' : '识别并记账'),
              ),
            ],
          ),
          if (results != null) ...[
            const SizedBox(height: LedgerLayout.groupGap),
            _ResultHeader(results: results),
            if (offline > 0) ...[
              const SizedBox(height: 8),
              Text(
                '没送到的还没记上，网络好了点「重发」。',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  key: const ValueKey('paste-resend'),
                  onPressed: _busy ? null : _resend,
                  icon: const Icon(Icons.refresh),
                  label: Text(_busy ? '正在重发…' : '重发没送到的 $offline 笔'),
                ),
              ),
            ],
            const SizedBox(height: 4),
            for (final entry in results) _EntryTile(entry: entry),
            const SizedBox(height: LedgerLayout.itemGap),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                onPressed: () => context.go('/transactions'),
                child: const Text('去看账单'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ResultHeader extends StatelessWidget {
  const _ResultHeader({required this.results});

  final List<PastedEntry> results;

  @override
  Widget build(BuildContext context) {
    int count(CaptureDecision d) => results
        .where((e) => e.outcome.decision == d && !e.outcome.offline)
        .length;
    final offline = results.where((e) => e.outcome.offline).length;
    final parts = [
      if (count(CaptureDecision.recorded) > 0)
        '记下 ${count(CaptureDecision.recorded)} 笔',
      if (count(CaptureDecision.pending) > 0)
        '${count(CaptureDecision.pending)} 笔待确认',
      if (offline > 0) '$offline 笔没送到',
      if (count(CaptureDecision.duplicate) > 0)
        '${count(CaptureDecision.duplicate)} 笔重复',
      if (count(CaptureDecision.ignored) > 0)
        '${count(CaptureDecision.ignored)} 段没认出来',
    ];
    return SectionHeader(
      parts.isEmpty ? '没有结果' : parts.join('，'),
      padding: EdgeInsets.zero,
    );
  }
}

/// 管线给的正文是写给系统通知的，末尾的「点击修改 / 点击打开处理」说的是点那条通知。
/// 这一页上换成这里真能做的事：送到了的点这一行打开那笔流水；服务端拒收的只能手动补。
String pastedEntryBody(CaptureOutcome outcome, {required bool canOpen}) {
  const notificationActions = {'点击修改', '点击打开处理'};
  final parts = outcome.body
      .split(' · ')
      .where((p) => p.isNotEmpty && !notificationActions.contains(p))
      .toList();
  if (canOpen) {
    parts.add('点这一行修改');
  } else if (outcome.decision == CaptureDecision.pending &&
      outcome.captureId != null &&
      !outcome.offline) {
    // 待确认却没有流水 id = 服务端 4xx 拒收了，首页「待确认」里也不会有它。
    parts.add('没记上，要手动记一笔');
  }
  return parts.join(' · ');
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry});

  final PastedEntry entry;

  static bool _hasDate(CaptureOutcome outcome) =>
      outcome.decision == CaptureDecision.recorded ||
      outcome.decision == CaptureDecision.pending;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = LedgerColors.of(context);
    final outcome = entry.outcome;
    final draft = outcome.draft;
    final txId = outcome.offline ? null : outcome.transactionId;
    final body = pastedEntryBody(outcome, canOpen: txId != null);
    final (icon, color) = switch (outcome.decision) {
      _ when outcome.offline => (
        Icons.cloud_off_outlined,
        theme.colorScheme.error,
      ),
      CaptureDecision.recorded => (Icons.check_circle_outline, colors.income),
      CaptureDecision.pending => (Icons.help_outline, colors.warning),
      CaptureDecision.duplicate => (
        Icons.content_copy_outlined,
        theme.colorScheme.onSurfaceVariant,
      ),
      CaptureDecision.ignored => (
        Icons.block_outlined,
        theme.colorScheme.onSurfaceVariant,
      ),
    };
    final tile = Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 20, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(outcome.title, style: theme.textTheme.bodyLarge),
                if (outcome.offline)
                  Text(
                    '没送到服务器，还没记上',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  )
                else if (body.isNotEmpty)
                  Text(body, style: theme.textTheme.bodySmall),
                if (draft != null && _hasDate(outcome))
                  Text(
                    '日期：${Dates.dateTimeLabel(draft.occurredAt)}',
                    style: theme.textTheme.bodySmall,
                  ),
                const SizedBox(height: 2),
                Text(
                  entry.text.replaceAll('\n', ' '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (txId != null)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 8),
              child: Icon(
                Icons.chevron_right,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
    if (txId == null) return tile;
    return InkWell(
      key: ValueKey('paste-entry-${outcome.captureId ?? txId}'),
      onTap: () => context.push('/transactions/$txId'),
      borderRadius: BorderRadius.circular(LedgerShapes.control),
      child: tile,
    );
  }
}
