import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../data/models/models.dart';
import '../add_tx/picker_field.dart';
import '../widgets/widgets.dart';
import 'import_undo.dart' show ImportNote;

/// 导入页的「网址」分段（spec §6「网址」）：填地址 → 抓取（服务端抓、防内网）→ 正文放进可编辑的框里，删掉没用的再识别
/// （按文字识别，带上 sourceUrl）。要登录、正文太短、PDF、抓不到时说清楚，给「改用截图 / 改用粘贴」一键切过去（整个分段
/// 只画一排）。抓取中（最多 10 秒）地址框下面写着「正在抓取…」，上一次的结果已经收起。
/// 状态都在输入页（切到别的分段再回来，抓到的正文还在），这里只画。
class UrlPane extends StatelessWidget {
  const UrlPane({
    super.key,
    required this.url,
    required this.text,
    required this.page,
    required this.fetching,
    this.error,
    required this.onFetch,
    required this.onUseImage,
    required this.onUsePaste,
    required this.onTextChanged,
  });

  final TextEditingController url;

  /// 抓到的正文（可以改）。
  final TextEditingController text;
  final FetchedPage? page;
  final bool fetching;

  /// 抓取失败的说明（服务端给的：被拦、超时、打不开……）。
  final String? error;
  final VoidCallback onFetch;
  final VoidCallback onUseImage;
  final VoidCallback onUsePaste;
  final ValueChanged<String> onTextChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = page;
    final degraded = p?.hint != null;
    final pad = const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, LedgerLayout.itemGap, LedgerLayout.pagePadding, 0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PickerField(
          label: '网页地址',
          topGap: LedgerLayout.itemGap,
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('import-url'),
                  controller: url,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.go,
                  autocorrect: false,
                  onSubmitted: (_) => fetching ? null : onFetch(),
                  decoration: const InputDecoration(hintText: 'https://…'),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                key: const ValueKey('import-fetch'),
                onPressed: fetching ? null : onFetch,
                child: fetching
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, semanticsLabel: '正在抓取'))
                    : const Text('抓取'),
              ),
            ],
          ),
        ),
        if (fetching)
          Padding(
            padding: pad,
            child: Text('正在抓取网页…（最多 10 秒）', key: const ValueKey('import-fetching'), style: theme.textTheme.bodyMedium),
          )
        else if (p == null && error == null)
          Padding(
            padding: pad,
            child: Text(
              '会员页大多要登录或靠脚本加载，抓不到的话截图或复制粘贴更准。抓到的正文先给你看、能改，确认了才发给 AI。',
              style: theme.textTheme.bodySmall,
            ),
          ),
        if (error case final message?)
          InlineError(key: const ValueKey('import-fetch-error'), message: message, padding: pad),
        if (p != null) ...[
          Padding(
            padding: pad,
            child: Text(
              [
                if (p.title.isNotEmpty) '抓到「${p.title}」' else '抓到了',
                // 抓到的多半没用（登录页、太短、PDF）时不催人「删掉没用的再识别」，下面的说明会劝人换方式。
                '${p.text.length} 字${p.text.isEmpty || degraded ? '' : '，先删掉没用的再识别'}',
              ].join('，'),
              key: const ValueKey('import-fetch-summary'),
              style: theme.textTheme.bodyMedium,
            ),
          ),
          if (p.truncated)
            ImportNote('正文超过 $importMaxChars 字，只留了前 $importMaxChars 字。', key: const ValueKey('import-url-truncated'), padding: pad),
          if (degraded)
            ImportNote(p.message ?? '没抓到多少内容。', key: const ValueKey('import-fetch-hint'), padding: pad),
        ],
        // 抓不到、抓到的没用：一排「改用截图 / 改用粘贴」，整个分段只画一次（两处都画会出现两个同 key 的按钮行）。
        if (error != null || degraded) _fallback(context),
        if (p != null) ...[
          if (p.text.isNotEmpty)
            PickerField(
              label: '抓到的正文（可以改）',
              child: TextField(
                key: const ValueKey('import-url-text'),
                controller: text,
                minLines: 6,
                maxLines: 14,
                maxLength: importMaxChars,
                onChanged: onTextChanged,
              ),
            ),
        ],
      ],
    );
  }

  /// 抓不到、抓到的没用时的一键切换。
  Widget _fallback(BuildContext context) => Padding(
    key: const ValueKey('import-url-fallback'),
    padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 8, LedgerLayout.pagePadding, 0),
    child: Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilledButton.tonal(key: const ValueKey('import-url-to-image'), onPressed: onUseImage, child: const Text('改用截图')),
        OutlinedButton(key: const ValueKey('import-url-to-paste'), onPressed: onUsePaste, child: const Text('改用粘贴')),
      ],
    ),
  );
}
