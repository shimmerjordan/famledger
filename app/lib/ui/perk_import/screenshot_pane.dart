import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../add_tx/picker_field.dart';
import 'import_undo.dart' show ImportNote;
import 'screenshots.dart';

/// 输入页「截图」分段的内容（spec §6「截图」）：选图按钮、切片缩略图（每片可删）、合计几片多大、挡住发送的原因、处理不了的图。
/// 状态都在输入页（[PerkImportPage]），这里只画。
class ScreenshotPane extends StatelessWidget {
  const ScreenshotPane({
    super.key,
    required this.sourceCount,
    required this.batch,
    required this.preparing,
    required this.onPick,
    required this.onRemove,
    required this.onClear,
    this.note,
    this.progress,
  });

  /// 已经选了几张原图（最多 [kMaxScreenshots]）。
  final int sourceCount;
  final ScreenshotBatch batch;
  final bool preparing;
  final VoidCallback onPick;
  final ValueChanged<ScreenshotSlice> onRemove;
  final VoidCallback onClear;

  /// 「一次最多 6 张，只加了前 N 张」这类一次性的提示。
  final String? note;

  /// 处理中：(处理完几张, 一共几张)；还没报过是 null。
  final (int, int)? progress;

  static String mb(int bytes) => (bytes / 1024 / 1024).toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final full = sourceCount >= kMaxScreenshots;
    final slices = batch.slices;
    final warnings = [
      if (batch.overCount) '切出了 ${slices.length} 片，一次最多 $kMaxSlices 片：删掉 ${slices.length - kMaxSlices} 片再开始（长图里不要的部分可以删）。',
      if (batch.overBytes) '图片合计 ${mb(batch.totalBytes)}MB，太大了（最多约 ${mb(kSlicesTotalBytes)}MB），删掉几片再开始。',
      ...batch.failed,
      ?note,
    ];
    return PickerField(
      label: '会员权益页或订单的截图',
      topGap: LedgerLayout.itemGap,
      // 处理中也能清空：一轮很慢（几张长图、网页上编码和界面同一个线程）时可以放弃，旧的那轮结果作废。
      trailing: sourceCount == 0 ? null : TextButton(key: const ValueKey('shots-clear'), onPressed: onClear, child: const Text('清空')),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FilledButton.tonalIcon(
            key: const ValueKey('import-pick-shots'),
            onPressed: full || preparing ? null : onPick,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: Text(sourceCount == 0 ? '选截图' : (full ? '最多 $kMaxScreenshots 张' : '再加几张')),
          ),
          const SizedBox(height: 8),
          Text(
            '长截图会自动切成几片，一次最多发 $kMaxSlices 片。截图里的手机号、卡号不会自动打码，不想发给模型的部分，删掉那一片。',
            style: theme.textTheme.bodySmall,
          ),
          if (preparing) ...[
            const SizedBox(height: LedgerLayout.itemGap),
            const LinearProgressIndicator(key: ValueKey('shots-preparing')),
            const SizedBox(height: 4),
            Text(
              switch (progress) {
                (final done, final total) when total > 0 => '正在切图、压缩：第 ${done < total ? done + 1 : total}/$total 张…',
                _ => '正在切图、压缩…',
              },
              key: const ValueKey('shots-progress'),
              style: theme.textTheme.bodySmall,
            ),
          ] else if (slices.isNotEmpty) ...[
            const SizedBox(height: LedgerLayout.itemGap),
            Text(
              '${slices.length} 片 · 约 ${mb(batch.totalBytes)}MB',
              key: const ValueKey('shots-summary'),
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [for (final s in slices) _SliceThumb(slice: s, onRemove: () => onRemove(s))],
            ),
          ],
          for (final w in warnings) ImportNote(w)
        ],
      ),
    );
  }
}

class _SliceThumb extends StatelessWidget {
  const _SliceThumb({required this.slice, required this.onRemove});

  final ScreenshotSlice slice;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = slice.count > 1 ? '图 ${slice.source + 1} · ${slice.index + 1}/${slice.count}' : '图 ${slice.source + 1}';
    return SizedBox(
      key: ValueKey('shot-${slice.id}'),
      width: 96,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(LedgerShapes.control),
                child: Image.memory(slice.png, width: 96, height: 144, fit: BoxFit.cover, gaplessPlayback: true),
              ),
              Positioned(
                top: 0,
                right: 0,
                child: IconButton(
                  key: ValueKey('shot-remove-${slice.id}'),
                  tooltip: '删掉这一片',
                  style: IconButton.styleFrom(backgroundColor: theme.colorScheme.surface.withValues(alpha: 0.85)),
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: onRemove,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(label, style: theme.textTheme.labelSmall),
        ],
      ),
    );
  }
}
