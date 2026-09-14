import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// 自绘金额键盘：大键 56dp（DESIGN.md），右侧一条到底的「保存」。
///
/// 不用系统数字键盘：记账时手指在屏幕下半区，按键要大、位置要固定。
class AmountKeypad extends StatelessWidget {
  const AmountKeypad({
    super.key,
    required this.onDigit,
    required this.onBackspace,
    required this.onClear,
    required this.onSave,
    this.saveLabel = '保存',
    this.busy = false,
  });

  /// 0–9 与小数点。
  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;

  /// 长按退格 = 清空。
  final VoidCallback onClear;
  final VoidCallback onSave;
  final String saveLabel;

  /// 正在保存：只锁保存键，避免重复提交。
  final bool busy;

  /// 一排键 60dp（去掉 2dp 内边距后净高 56 = DESIGN.md 的下限）。
  static const double rowHeight = 60;

  static const List<List<String>> _rows = [
    ['7', '8', '9'],
    ['4', '5', '6'],
    ['1', '2', '3'],
    ['.', '0', '⌫'],
  ];

  @override
  Widget build(BuildContext context) {
    final ledger = LedgerColors.of(context);
    return Material(
      color: ledger.surface2,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(8),
          // 键盘挂在 Column 底部（高度不受约束），所以自己把高度定死。
          child: SizedBox(
            height: rowHeight * _rows.length,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Column(
                    children: [
                      for (final row in _rows)
                        Expanded(
                          child: Row(
                            children: [
                              for (final key in row)
                                Expanded(
                                  child: _Key(
                                    value: key,
                                    onTap: key == '⌫'
                                        ? onBackspace
                                        : () => onDigit(key),
                                    onLongPress: key == '⌫' ? onClear : null,
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 96,
                  child: FilledButton(
                    key: const ValueKey('save-tx'),
                    onPressed: busy ? null : onSave,
                    style: FilledButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(
                          LedgerShapes.control,
                        ),
                      ),
                    ),
                    child: busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(saveLabel),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({required this.value, required this.onTap, this.onLongPress});

  final String value;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(2),
      child: InkWell(
        key: ValueKey('key-$value'),
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(LedgerShapes.control),
        child: Center(
          child: value == '⌫'
              ? Icon(
                  Icons.backspace_outlined,
                  size: 22,
                  color: theme.colorScheme.onSurface,
                )
              : Text(value, style: theme.textTheme.headlineSmall),
        ),
      ),
    );
  }
}
