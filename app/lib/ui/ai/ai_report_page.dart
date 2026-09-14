import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../data/models/models.dart';
import '../../data/repos/ai_repo.dart';
import '../widgets/widgets.dart';
import 'ai_controls.dart';
import 'simple_markdown.dart';

/// AI 月报：选月份 → 流式生成 → 落库，历史报告随时翻回来看。
class AiReportPage extends ConsumerStatefulWidget {
  const AiReportPage({super.key});

  @override
  ConsumerState<AiReportPage> createState() => _AiReportPageState();
}

class _AiReportPageState extends ConsumerState<AiReportPage> {
  String _month = Dates.currentMonth();
  String? _providerId;
  StreamSubscription<String>? _sub;
  String _text = '';
  String? _error;

  bool get _isStreaming => _sub != null;

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _generate() {
    if (_isStreaming) return;
    setState(() {
      _text = '';
      _error = null;
    });
    final stream = ref.read(aiRepoProvider).report(_month, providerId: _providerId);
    _sub = stream.listen(
      (delta) => setState(() => _text += delta),
      onError: (Object error) {
        if (!mounted) return;
        setState(() {
          _error = describeError(error);
          _sub = null;
        });
      },
      onDone: () {
        if (!mounted) return;
        setState(() => _sub = null);
        // 服务端已经把这份报告落库了，刷一下历史列表。
        ref.invalidate(aiReportsProvider(_month));
      },
      cancelOnError: true,
    );
  }

  void _stop() {
    _sub?.cancel();
    setState(() => _sub = null);
  }

  /// 换月份：正在生成的是上个月的报告，必须停掉再清空，
  /// 否则迟到的 delta 会接着写到新月份的标题下面。
  void _changeMonth(String month) {
    if (month == _month) return;
    _sub?.cancel();
    setState(() {
      _sub = null;
      _month = month;
      _text = '';
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reports = ref.watch(aiReportsProvider(_month));
    final isCurrent = _month == Dates.currentMonth();

    return Scaffold(
      appBar: AppBar(title: const Text('AI 月报')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: LedgerLayout.pagePadding,
            ),
            child: Row(
              children: [
                AiMonthChip(month: _month, onChanged: _changeMonth),
                const SizedBox(width: 8),
                Flexible(
                  child: AiProviderChip(
                    providerId: _providerId,
                    onChanged: (id) => setState(() => _providerId = id),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              LedgerLayout.pagePadding,
              8,
              LedgerLayout.pagePadding,
              0,
            ),
            child: SizedBox(
              height: 48,
              width: double.infinity,
              child: _isStreaming
                  ? OutlinedButton.icon(
                      onPressed: _stop,
                      icon: const Icon(Icons.stop, size: 18),
                      label: const Text('停止生成'),
                    )
                  : FilledButton.icon(
                      onPressed: _generate,
                      icon: const Icon(Icons.auto_awesome, size: 18),
                      label: Text(
                        isCurrent ? '生成本月报告' : '生成${Dates.monthLabel(_month)}报告',
                      ),
                    ),
            ),
          ),
          if (_error != null)
            InlineError(
              message: _error!,
              onRetry: _generate,
              padding: const EdgeInsets.fromLTRB(
                LedgerLayout.pagePadding,
                16,
                LedgerLayout.pagePadding,
                0,
              ),
            ),
          if (_text.isNotEmpty || _isStreaming) ...[
            const SizedBox(height: LedgerLayout.groupGap),
            SectionHeader('${Dates.monthLabel(_month)}报告'),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: LedgerLayout.pagePadding,
              ),
              child: SimpleMarkdown(_text, caret: _isStreaming),
            ),
          ],
          const SizedBox(height: LedgerLayout.groupGap),
          const SectionHeader('历史报告'),
          AsyncValueView<List<AiReport>>(
            value: reports,
            onRetry: () => ref.invalidate(aiReportsProvider(_month)),
            loading: const SkeletonList(rows: 2),
            data: (items) => items.isEmpty
                ? EmptyState(
                    compact: true,
                    title: '${Dates.monthLabel(_month)}还没有生成过报告',
                    message: '点上面的按钮生成一份，之后随时能翻回来看。',
                  )
                : Column(
                    children: [
                      for (final report in items)
                        Theme(
                          // 展开面板自带的分隔线会在深色下发灰，交给我们自己的 Divider。
                          data: theme.copyWith(dividerColor: Colors.transparent),
                          child: ExpansionTile(
                            title: Text(
                              report.createdAt == null
                                  ? Dates.monthLabel(report.month)
                                  : Dates.dateTimeLabel(
                                      report.createdAt!.toLocal(),
                                    ),
                              style: theme.textTheme.titleMedium,
                            ),
                            subtitle: Text(
                              _preview(report.content),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall,
                            ),
                            childrenPadding: const EdgeInsets.fromLTRB(
                              LedgerLayout.pagePadding,
                              0,
                              LedgerLayout.pagePadding,
                              16,
                            ),
                            expandedCrossAxisAlignment: CrossAxisAlignment.start,
                            children: [SimpleMarkdown(report.content)],
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  /// 折叠时给一行摘要：去掉 Markdown 记号的第一句话。
  static String _preview(String content) {
    for (final line in content.split('\n')) {
      final text = line
          .replaceAll(RegExp(r'^[#>\-*\s]+'), '')
          .replaceAll('**', '')
          .trim();
      if (text.isNotEmpty) return text;
    }
    return '（空报告）';
  }
}
