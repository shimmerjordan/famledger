import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../data/models/models.dart';
import '../../data/repos/ai_repo.dart';
import '../widgets/widgets.dart';
import 'ai_controls.dart';
import 'message_bubble.dart';

/// 问 AI：带上「哪个月」的上下文和账本数据，流式回答。
class AiChatPage extends ConsumerStatefulWidget {
  const AiChatPage({super.key});

  /// 空态里给的三个例子，照着改就知道能问什么。
  static const List<String> examples = [
    '这个月钱主要花在哪儿？',
    '哪个基金快超预算了？',
    '和上个月比，多花了什么？',
  ];

  @override
  ConsumerState<AiChatPage> createState() => _AiChatPageState();
}

class _AiChatPageState extends ConsumerState<AiChatPage> {
  final List<AiChatMessage> _messages = [];
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  String _month = Dates.currentMonth();
  String? _providerId;
  StreamSubscription<String>? _sub;
  String _streaming = '';

  bool get _isStreaming => _sub != null;

  @override
  void dispose() {
    _sub?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _submit([String? preset]) {
    final text = (preset ?? _input.text).trim();
    if (text.isEmpty || _isStreaming) return;
    _input.clear();
    setState(() => _messages.add(AiChatMessage.user(text)));
    _run();
  }

  /// 重试：把上一条失败提示去掉，用同样的上下文再问一次。
  void _retry() {
    setState(() {
      while (_messages.isNotEmpty && _messages.last.error) {
        _messages.removeLast();
      }
    });
    if (_messages.isEmpty) return;
    _run();
  }

  void _run() {
    final history = _messages.where((m) => !m.error).toList();
    setState(() => _streaming = '');
    _scrollToBottom(animate: true);
    final stream = ref
        .read(aiRepoProvider)
        .chat(history, providerId: _providerId, month: _month);
    _sub = stream.listen(
      (delta) {
        setState(() => _streaming += delta);
        _scrollToBottom();
      },
      onError: (Object error) {
        if (!mounted) return;
        setState(() {
          if (_streaming.isNotEmpty) {
            _messages.add(AiChatMessage.assistant(_streaming));
          }
          _streaming = '';
          _sub = null;
          _messages.add(
            AiChatMessage('assistant', describeError(error), error: true),
          );
        });
        _scrollToBottom(animate: true);
      },
      onDone: () {
        if (!mounted) return;
        setState(() {
          if (_streaming.isNotEmpty) {
            _messages.add(AiChatMessage.assistant(_streaming));
          }
          _streaming = '';
          _sub = null;
        });
        _scrollToBottom(animate: true);
      },
      cancelOnError: true,
    );
  }

  /// 停止：已经吐出来的那段留着，别白等。
  void _stop() {
    _sub?.cancel();
    setState(() {
      if (_streaming.isNotEmpty) {
        _messages.add(AiChatMessage.assistant(_streaming));
      }
      _streaming = '';
      _sub = null;
    });
  }

  /// 换上下文月份：正在生成的那段是按旧月份的数据算的，先停下来，
  /// 已经吐出来的留在对话里（跟按「停止」一样），迟到的 delta 不再续写。
  void _changeMonth(String month) {
    if (month == _month) return;
    if (_isStreaming) _stop();
    setState(() => _month = month);
  }

  void _clear() {
    _sub?.cancel();
    setState(() {
      _messages.clear();
      _streaming = '';
      _sub = null;
    });
  }

  void _scrollToBottom({bool animate = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if (animate && !MediaQuery.disableAnimationsOf(context)) {
        _scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 200),
          curve: Easing.emphasizedDecelerate,
        );
      } else {
        _scroll.jumpTo(target);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ledger = LedgerColors.of(context);
    final hasContent = _messages.isNotEmpty || _streaming.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('问 AI'),
        actions: [
          IconButton(
            tooltip: '月报',
            onPressed: () => context.push('/ai/report'),
            icon: const Icon(Icons.article_outlined),
          ),
          if (hasContent)
            IconButton(
              tooltip: '新对话',
              onPressed: _clear,
              icon: const Icon(Icons.add_comment_outlined),
            ),
        ],
      ),
      body: Column(
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
          const Divider(height: 1),
          Expanded(
            child: hasContent ? _list() : _empty(context),
          ),
          _composer(theme, ledger),
        ],
      ),
    );
  }

  Widget _list() => ListView.builder(
    controller: _scroll,
    padding: const EdgeInsets.fromLTRB(
      LedgerLayout.pagePadding,
      12,
      LedgerLayout.pagePadding,
      12,
    ),
    itemCount: _messages.length + (_isStreaming ? 1 : 0),
    itemBuilder: (context, index) {
      if (index >= _messages.length) {
        return MessageBubble(
          message: AiChatMessage.assistant(_streaming),
          streaming: true,
        );
      }
      final message = _messages[index];
      final isLastError = message.error && index == _messages.length - 1;
      return MessageBubble(
        message: message,
        onRetry: isLastError ? _retry : null,
      );
    },
  );

  Widget _empty(BuildContext context) => ListView(
    padding: const EdgeInsets.only(bottom: 24),
    children: [
      EmptyState(
        icon: Icons.auto_awesome_outlined,
        title: '问点什么',
        message: '它看得到${Dates.monthLabel(_month)}的收支、基金余额和预算，'
            '可以让它帮你找花超的地方、解释某个数字，或者给下个月的建议。',
      ),
      Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LedgerLayout.pagePadding,
        ),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final example in AiChatPage.examples)
              ActionChip(
                label: Text(example),
                onPressed: () => _submit(example),
              ),
          ],
        ),
      ),
    ],
  );

  Widget _composer(ThemeData theme, LedgerColors ledger) => Container(
    decoration: BoxDecoration(
      color: ledger.surface2,
      border: Border(top: BorderSide(color: theme.colorScheme.outline)),
    ),
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 8, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _submit(),
                decoration: const InputDecoration(
                  hintText: '问问这个月的账…',
                  border: InputBorder.none,
                  filled: false,
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 48,
              height: 48,
              child: _isStreaming
                  ? IconButton.filledTonal(
                      tooltip: '停止',
                      onPressed: _stop,
                      icon: const Icon(Icons.stop),
                    )
                  : IconButton.filled(
                      tooltip: '发送',
                      onPressed: _submit,
                      icon: const Icon(Icons.arrow_upward),
                    ),
            ),
          ],
        ),
      ),
    ),
  );
}
