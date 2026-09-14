import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// 轻量 Markdown 渲染：标题、粗体、行内代码、无序/有序列表、代码块、分隔线。
///
/// 自己写而不是引第三方包 —— 模型输出的花样就这几种，多一个依赖不如多二百行。
/// 流式渲染时把 [caret] 打开，最后一段末尾会跟一个闪动的光标。
class SimpleMarkdown extends StatelessWidget {
  const SimpleMarkdown(
    this.text, {
    super.key,
    this.caret = false,
    this.selectable = true,
    this.baseStyle,
  });

  final String text;

  /// 还在流式输出：末尾显示光标。
  final bool caret;
  final bool selectable;
  final TextStyle? baseStyle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ledger = LedgerColors.of(context);
    final base =
        baseStyle ??
        (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(height: 1.55);
    final blocks = _parseMarkdown(text);

    final children = <Widget>[];
    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      final isLast = i == blocks.length - 1;
      if (i > 0) {
        children.add(SizedBox(height: block.kind == _Kind.heading ? 16 : 8));
      }
      children.add(
        _blockWidget(context, block, base, ledger, caret && isLast),
      );
    }
    if (children.isEmpty && caret) {
      children.add(const _Caret());
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  Widget _blockWidget(
    BuildContext context,
    _Block block,
    TextStyle base,
    LedgerColors ledger,
    bool withCaret,
  ) {
    final theme = Theme.of(context);
    switch (block.kind) {
      case _Kind.divider:
        return const Divider(height: 16);
      case _Kind.code:
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: ledger.surface3,
            borderRadius: BorderRadius.circular(LedgerShapes.chip),
          ),
          child: Text(
            block.text,
            style: base.copyWith(fontFamily: 'monospace', fontSize: 13, height: 1.45),
          ),
        );
      case _Kind.heading:
        final style = switch (block.level) {
          1 => theme.textTheme.titleLarge,
          2 => theme.textTheme.titleMedium,
          _ => base.copyWith(fontWeight: FontWeight.w600),
        };
        return _text(context, block.text, style ?? base, ledger, withCaret);
      case _Kind.bullet:
      case _Kind.numbered:
        return Padding(
          padding: const EdgeInsets.only(left: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: block.kind == _Kind.bullet ? 16 : 26,
                child: Text(
                  block.kind == _Kind.bullet ? '·' : block.marker,
                  style: base.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
              Expanded(child: _text(context, block.text, base, ledger, withCaret)),
            ],
          ),
        );
      case _Kind.paragraph:
        return _text(context, block.text, base, ledger, withCaret);
    }
  }

  Widget _text(
    BuildContext context,
    String raw,
    TextStyle style,
    LedgerColors ledger,
    bool withCaret,
  ) {
    final spans = inlineSpans(raw, style, ledger.surface3);
    if (withCaret) {
      spans.add(
        const WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _Caret(),
        ),
      );
    }
    final span = TextSpan(style: style, children: spans);
    return selectable ? SelectableText.rich(span) : Text.rich(span);
  }
}

/// 输出中的光标：一个会呼吸的小竖块（系统关掉动画时就是静止的）。
class _Caret extends StatefulWidget {
  const _Caret();

  @override
  State<_Caret> createState() => _CaretState();
}

class _CaretState extends State<_Caret> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
      _controller.value = 1;
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 2),
    child: FadeTransition(
      opacity: _controller.drive(Tween(begin: 0.25, end: 1)),
      child: Container(
        width: 7,
        height: 15,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    ),
  );
}

enum _Kind { paragraph, heading, bullet, numbered, code, divider }

class _Block {
  const _Block(this.kind, this.text, {this.level = 0, this.marker = ''});

  final _Kind kind;
  final String text;
  final int level;
  final String marker;
}

final RegExp _headingRe = RegExp(r'^(#{1,6})\s+(.*)$');
final RegExp _bulletRe = RegExp(r'^\s*[-*•]\s+(.*)$');
final RegExp _numberedRe = RegExp(r'^\s*(\d{1,3})[.、)]\s+(.*)$');
final RegExp _dividerRe = RegExp(r'^\s*(-{3,}|\*{3,}|_{3,})\s*$');

/// 把 Markdown 文本切成块。
List<_Block> _parseMarkdown(String text) {
  final blocks = <_Block>[];
  final paragraph = <String>[];
  final code = <String>[];
  var inCode = false;

  void flushParagraph() {
    if (paragraph.isEmpty) return;
    blocks.add(_Block(_Kind.paragraph, paragraph.join('\n')));
    paragraph.clear();
  }

  for (final line in text.split('\n')) {
    if (line.trimLeft().startsWith('```')) {
      if (inCode) {
        blocks.add(_Block(_Kind.code, code.join('\n')));
        code.clear();
        inCode = false;
      } else {
        flushParagraph();
        inCode = true;
      }
      continue;
    }
    if (inCode) {
      code.add(line);
      continue;
    }
    if (line.trim().isEmpty) {
      flushParagraph();
      continue;
    }
    if (_dividerRe.hasMatch(line)) {
      flushParagraph();
      blocks.add(const _Block(_Kind.divider, ''));
      continue;
    }
    final heading = _headingRe.firstMatch(line);
    if (heading != null) {
      flushParagraph();
      blocks.add(
        _Block(_Kind.heading, heading.group(2)!.trim(), level: heading.group(1)!.length),
      );
      continue;
    }
    final bullet = _bulletRe.firstMatch(line);
    if (bullet != null) {
      flushParagraph();
      blocks.add(_Block(_Kind.bullet, bullet.group(1)!.trim()));
      continue;
    }
    final numbered = _numberedRe.firstMatch(line);
    if (numbered != null) {
      flushParagraph();
      blocks.add(
        _Block(
          _Kind.numbered,
          numbered.group(2)!.trim(),
          marker: '${numbered.group(1)}.',
        ),
      );
      continue;
    }
    paragraph.add(line.trimRight());
  }
  if (inCode && code.isNotEmpty) blocks.add(_Block(_Kind.code, code.join('\n')));
  flushParagraph();
  return blocks;
}

/// 行内：`**粗体**` 与 `` `代码` ``，其余原样。
List<InlineSpan> inlineSpans(String text, TextStyle base, Color codeBackground) {
  final spans = <InlineSpan>[];
  final buffer = StringBuffer();

  void flush() {
    if (buffer.isEmpty) return;
    spans.add(TextSpan(text: buffer.toString()));
    buffer.clear();
  }

  var i = 0;
  while (i < text.length) {
    if (text.startsWith('**', i)) {
      final end = text.indexOf('**', i + 2);
      if (end > i + 2) {
        flush();
        spans.add(
          TextSpan(
            text: text.substring(i + 2, end),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        );
        i = end + 2;
        continue;
      }
    }
    if (text[i] == '`') {
      final end = text.indexOf('`', i + 1);
      if (end > i + 1) {
        flush();
        spans.add(
          TextSpan(
            text: text.substring(i + 1, end),
            style: base.copyWith(
              fontFamily: 'monospace',
              fontSize: (base.fontSize ?? 14) - 1,
              backgroundColor: codeBackground,
            ),
          ),
        );
        i = end + 1;
        continue;
      }
    }
    buffer.write(text[i]);
    i++;
  }
  flush();
  return spans;
}
