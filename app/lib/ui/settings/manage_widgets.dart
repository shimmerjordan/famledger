import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/colors.dart';
import '../widgets/widgets.dart';

/// 设置各页共用的小零件：编辑弹层、颜色/图标/emoji 选择、破坏性确认。
///
/// 只服务 `lib/ui/settings/` 内部，不往 `ui/widgets/` 里塞（那是全局组件的地方）。

/// 打开一个编辑表单。编辑一律用底部弹层，对话框只留给破坏性确认（DESIGN.md）。
Future<T?> showManageSheet<T>(BuildContext context, WidgetBuilder builder) =>
    showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: builder,
    );

/// 编辑弹层的外壳：标题 + 表单 + 行内错误 + 底部一行操作。
class ManageSheet extends StatelessWidget {
  const ManageSheet({
    super.key,
    required this.title,
    required this.children,
    required this.onSubmit,
    this.submitLabel = '保存',
    this.busy = false,
    this.error,
    this.secondaryLabel,
    this.onSecondary,
    this.secondaryDestructive = true,
  });

  final String title;
  final List<Widget> children;

  /// 为空表示只读（非管理员看成员资料就是这样）。
  final VoidCallback? onSubmit;
  final String submitLabel;
  final bool busy;

  /// 提交失败时的一句中文，显示在按钮上方。
  final String? error;

  /// 左下角的次要操作（一般是「归档」「删除」）。
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  /// 次要操作是不是破坏性的（决定要不要用 error 色）。「取消归档」就不是。
  final bool secondaryDestructive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = this.error;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          LedgerLayout.pagePadding,
          0,
          LedgerLayout.pagePadding,
          LedgerLayout.pagePadding,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: LedgerLayout.pagePadding),
            ...children,
            if (error != null) ...[
              const SizedBox(height: LedgerLayout.itemGap),
              Text(
                error,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: LedgerLayout.groupGap),
            Row(
              children: [
                if (secondaryLabel != null && onSecondary != null)
                  TextButton(
                    onPressed: busy ? null : onSecondary,
                    style: TextButton.styleFrom(
                      foregroundColor: secondaryDestructive
                          ? theme.colorScheme.error
                          : null,
                    ),
                    child: Text(secondaryLabel!),
                  ),
                const Spacer(),
                TextButton(
                  onPressed: busy ? null : () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                if (onSubmit != null)
                  FilledButton(
                    onPressed: busy ? null : onSubmit,
                    child: Text(busy ? '保存中…' : submitLabel),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 表单里的一小块：标签 + 控件。
class ManageField extends StatelessWidget {
  const ManageField({super.key, required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: LedgerLayout.pagePadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

/// 下拉选择（成员、父类别、规则目标……）。`null` 是合法值，标签由调用方给。
class ManagePicker<T> extends StatelessWidget {
  const ManagePicker({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final T? value;

  /// `(value, label)` 列表，第一项通常是「不指定」。
  final List<(T?, String)> options;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) => ManageField(
    label: label,
    child: DropdownButtonFormField<T?>(
      value: options.any((o) => o.$1 == value) ? value : options.first.$1,
      isExpanded: true,
      decoration: const InputDecoration(isDense: true),
      items: [
        for (final (v, text) in options)
          DropdownMenuItem<T?>(value: v, child: Text(text)),
      ],
      onChanged: onChanged,
    ),
  );
}

/// 12 色盘选择（基金/账户/类别/成员共用同一套身份色）。
class ManageColorPicker extends StatelessWidget {
  const ManageColorPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.allowAuto = true,
  });

  /// `#rrggbb`，null = 跟随顺序自动取色。
  final String? value;
  final ValueChanged<String?> onChanged;

  /// 给不给「自动」那一格。成员编辑时不给 —— 服务端存的成员颜色一定是具体色，
  /// 发 null 会被 400 挡回来，摆一个存不进去的选项等于骗人。
  final bool allowAuto;

  @override
  Widget build(BuildContext context) {
    final palette = LedgerColors.of(context).fundPalette;
    final selected = hexColor(value);
    return ManageField(
      label: '颜色',
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          if (allowAuto)
            _Swatch(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              selected: selected == null,
              auto: true,
              onTap: () => onChanged(null),
            ),
          for (final color in palette)
            _Swatch(
              color: color,
              selected: selected != null && colorHex(color) == colorHex(selected),
              onTap: () => onChanged(colorHex(color)),
            ),
        ],
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.color,
    required this.selected,
    required this.onTap,
    this.auto = false,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  /// 「自动」那一格画一条斜杠，不让它伪装成一个真的颜色。
  final bool auto;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    button: true,
    label: auto ? '自动配色' : '颜色 ${colorHex(color)}',
    child: InkResponse(
      onTap: onTap,
      radius: 24,
      child: SizedBox(
        width: 48,
        height: 48,
        child: Center(
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: auto ? Colors.transparent : color,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected
                    ? Theme.of(context).colorScheme.onSurface
                    : color.withValues(alpha: 0.5),
                width: selected ? 2 : 1,
              ),
            ),
            child: auto
                ? Icon(Icons.auto_awesome, size: 14, color: color)
                : (selected
                      ? const Icon(Icons.check, size: 16, color: Colors.white)
                      : null),
          ),
        ),
      ),
    ),
  );
}

/// 图标选择：就是 [kCategoryIcons] 那一套名字，服务端存名字。
class ManageIconPicker extends StatelessWidget {
  const ManageIconPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.color,
  });

  final String? value;
  final ValueChanged<String> onChanged;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ManageField(
      label: '图标',
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final name in kCategoryIcons.keys)
            Semantics(
              selected: name == value,
              button: true,
              child: InkResponse(
                onTap: () => onChanged(name),
                radius: 24,
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Center(
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: name == value
                            ? (color ?? scheme.primary).withValues(alpha: 0.16)
                            : null,
                        border: Border.all(
                          color: name == value
                              ? (color ?? scheme.primary)
                              : scheme.outlineVariant,
                        ),
                      ),
                      child: Icon(
                        kCategoryIcons[name],
                        size: 18,
                        color: name == value
                            ? (color ?? scheme.primary)
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 成员头像用的 emoji。24 个够一家人挑，不做全量 emoji 键盘。
const List<String> kAvatarEmojis = [
  '🙂', '😀', '😎', '🤓', '🥳', '😺',
  '👩', '👨', '👵', '👴', '👧', '👦',
  '👩‍🍳', '👨‍💻', '👩‍🏫', '👨‍🔧', '🧑‍🌾', '🧑‍⚕️',
  '🐶', '🐱', '🐼', '🦊', '🌻', '⭐',
];

class ManageEmojiPicker extends StatelessWidget {
  const ManageEmojiPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.allowClear = true,
  });

  final String? value;
  final ValueChanged<String?> onChanged;

  /// 再点一次能不能取消选择。编辑已有成员时不行 —— 服务端的 PATCH
  /// 把 `avatarEmoji: null` 当「不改」，清不掉，别给一个假的开关。
  final bool allowClear;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ManageField(
      label: '头像',
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final emoji in kAvatarEmojis)
            Semantics(
              selected: emoji == value,
              button: true,
              child: InkResponse(
                onTap: () => onChanged(
                  emoji == value && allowClear ? null : emoji,
                ),
                radius: 24,
                child: Container(
                  width: 48,
                  height: 48,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: emoji == value
                        ? scheme.primary.withValues(alpha: 0.16)
                        : null,
                  ),
                  child: Text(emoji, style: const TextStyle(fontSize: 22)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 圆形头像：有 emoji 用 emoji，没有就用名字首字，底色是成员身份色。
class ManageAvatar extends StatelessWidget {
  const ManageAvatar({
    super.key,
    required this.name,
    this.emoji,
    this.color,
    this.size = 40,
    this.dimmed = false,
  });

  final String name;
  final String? emoji;
  final Color? color;
  final double size;

  /// 已归档的成员画淡一点。
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = color ?? theme.colorScheme.primary;
    return Opacity(
      opacity: dimmed ? 0.5 : 1,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: tint.withValues(alpha: 0.16),
          shape: BoxShape.circle,
        ),
        child: Text(
          emoji ?? (name.isEmpty ? '?' : name.characters.first),
          style: theme.textTheme.titleMedium,
        ),
      ),
    );
  }
}

/// 破坏性确认（归档/删除）。只有这类操作才配用对话框。
Future<bool> confirmDestructive(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = '继续',
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// 成功了给一条 Snackbar（只用于瞬时反馈），失败在原地行内报错。
void manageToast(BuildContext context, String message) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

/// 「已归档」这种状态标签。
class ManageTag extends StatelessWidget {
  const ManageTag(this.label, {super.key, this.color});

  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = color ?? theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(LedgerShapes.chip),
      ),
      child: Text(
        label,
        style: theme.textTheme.bodySmall?.copyWith(color: tint),
      ),
    );
  }
}
