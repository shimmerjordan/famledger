import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/colors.dart';
import '../../data/models/models.dart';
import '../widgets/widgets.dart';
import 'manage_widgets.dart';

/// 新建/编辑成员。只有管理员会走到这里（列表页已经把入口藏了）。
Future<void> showMemberForm(BuildContext context, {Member? member}) =>
    showManageSheet<void>(
      context,
      (context) => MemberFormSheet(member: member),
    );

class MemberFormSheet extends ConsumerStatefulWidget {
  const MemberFormSheet({super.key, this.member});

  final Member? member;

  @override
  ConsumerState<MemberFormSheet> createState() => _MemberFormSheetState();
}

class _MemberFormSheetState extends ConsumerState<MemberFormSheet> {
  late final TextEditingController _username = TextEditingController(
    text: widget.member?.username ?? '',
  );
  late final TextEditingController _displayName = TextEditingController(
    text: widget.member?.displayName ?? '',
  );
  late final TextEditingController _password = TextEditingController();

  late String? _color = widget.member?.color;
  late String? _emoji = widget.member?.avatarEmoji;
  late String _role = widget.member?.role ?? 'member';

  bool _busy = false;
  String? _error;

  bool get _isNew => widget.member == null;

  @override
  void dispose() {
    _username.dispose();
    _displayName.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final username = _username.text.trim();
    final displayName = _displayName.text.trim();
    if (_isNew && username.isEmpty) {
      setState(() => _error = '用户名不能为空，家人用它登录。');
      return;
    }
    if (displayName.isEmpty) {
      setState(() => _error = '给这位家人起个称呼，列表里显示的是它。');
      return;
    }
    if (_isNew && _password.text.length < 6) {
      setState(() => _error = '初始密码至少 6 位。');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    final navigator = Navigator.of(context);
    final repo = ref.read(ledgerRepoProvider);
    try {
      if (_isNew) {
        await repo.createMember({
          'username': username,
          'password': _password.text,
          'displayName': displayName,
          'color': _color,
          'avatarEmoji': _emoji,
          'role': _role,
        });
      } else {
        // 服务端的 PATCH 对这两个字段很挑：`color: null` 会被 400 挡回来
        // （members.js 里 color 是 required），`avatarEmoji: null` 则被当成
        // 「不改」。两个都没值时干脆不发，别拿一个存不进去的请求去撞墙。
        final patch = <String, dynamic>{
          'displayName': displayName,
          'role': _role,
        };
        if (_color != null) patch['color'] = _color;
        if (_emoji != null) patch['avatarEmoji'] = _emoji;
        await repo.updateMember(widget.member!.id, patch);
      }
      navigator.pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = describeError(e);
        });
      }
    }
  }

  Future<void> _resetPassword() async {
    final member = widget.member;
    if (member == null) return;
    final controller = TextEditingController();
    try {
      // 长度在对话框里就校验：关掉了才说「太短，没改」是在耍人。
      final password = await showDialog<String>(
        context: context,
        builder: (context) {
          String? error;
          return StatefulBuilder(
            builder: (context, setDialogState) {
              void submit() {
                if (controller.text.length < 6) {
                  setDialogState(() => error = '密码至少 6 位');
                  return;
                }
                Navigator.of(context).pop(controller.text);
              }

              return AlertDialog(
                title: Text('重置 ${member.label} 的密码'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('对方下次登录要用新密码，旧密码立刻失效。'),
                    const SizedBox(height: 12),
                    TextField(
                      controller: controller,
                      autofocus: true,
                      obscureText: true,
                      onSubmitted: (_) => submit(),
                      decoration: InputDecoration(
                        labelText: '新密码（至少 6 位）',
                        errorText: error,
                      ),
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  FilledButton(onPressed: submit, child: const Text('重置')),
                ],
              );
            },
          );
        },
      );
      if (password == null || !mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      try {
        await ref.read(ledgerRepoProvider).resetMemberPassword(
          member.id,
          password,
        );
        messenger.showSnackBar(const SnackBar(content: Text('密码已重置')));
      } catch (e) {
        if (mounted) setState(() => _error = describeError(e));
      }
    } finally {
      controller.dispose();
    }
  }

  /// 归档/取消归档都走 `PATCH {archived}`，这样两个方向是同一条路。
  Future<void> _setArchived(bool archived) async {
    final member = widget.member;
    if (member == null) return;
    if (archived) {
      final ok = await confirmDestructive(
        context,
        title: '归档 ${member.label}？',
        message: '归档后 TA 不能再登录，已有的流水与统计都保留，随时可以取消归档。',
        confirmLabel: '归档',
      );
      if (!ok || !mounted) return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final navigator = Navigator.of(context);
    try {
      await ref.read(ledgerRepoProvider).updateMember(member.id, {
        'archived': archived,
      });
      navigator.pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = describeError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(sessionProvider)?.me;
    final isSelf = me != null && me.id == widget.member?.id;

    return ManageSheet(
      title: _isNew ? '添加成员' : '编辑成员',
      busy: _busy,
      error: _error,
      onSubmit: _submit,
      secondaryLabel: _isNew || isSelf
          ? null
          : (widget.member!.archived ? '取消归档' : '归档'),
      onSecondary: _isNew || isSelf
          ? null
          : () => _setArchived(!widget.member!.archived),
      secondaryDestructive: !(widget.member?.archived ?? false),
      children: [
        if (_isNew) ...[
          ManageField(
            label: '用户名',
            child: TextField(
              controller: _username,
              autofocus: true,
              decoration: const InputDecoration(hintText: '登录用，建议用拼音'),
            ),
          ),
          ManageField(
            label: '初始密码',
            child: TextField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(hintText: '至少 6 位，之后 TA 可以自己改'),
            ),
          ),
        ] else
          ManageField(
            label: '用户名',
            child: Text(
              '@${widget.member!.username}',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ),
        ManageField(
          label: '称呼',
          child: TextField(
            controller: _displayName,
            decoration: const InputDecoration(hintText: '妈妈、爸爸、外婆…'),
          ),
        ),
        ManageEmojiPicker(
          value: _emoji,
          // 编辑时不给「再点一次取消」：服务端 PATCH 清不掉头像。
          allowClear: _isNew,
          onChanged: (value) => setState(() => _emoji = value),
        ),
        ManageColorPicker(
          value: _color,
          // 同理，编辑时不给「自动」：成员颜色在服务端一定是具体色。
          allowAuto: _isNew,
          onChanged: (value) => setState(() => _color = value),
        ),
        ManageField(
          label: '角色',
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'member', label: Text('成员')),
              ButtonSegment(value: 'admin', label: Text('管理员')),
            ],
            selected: {_role},
            onSelectionChanged: isSelf
                ? null
                : (value) => setState(() => _role = value.first),
          ),
        ),
        if (isSelf)
          Text(
            '这是你自己：角色与归档只能由别的管理员改。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        if (!_isNew) ...[
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _resetPassword,
              icon: const Icon(Icons.key_outlined, size: 18),
              label: const Text('重置密码'),
            ),
          ),
        ],
      ],
    );
  }
}

/// 成员行的头像（把颜色解析收在一处）。
ManageAvatar memberAvatar(Member member, {double size = 40}) => ManageAvatar(
  name: member.label,
  emoji: member.avatarEmoji,
  color: hexColor(member.color),
  size: size,
  dimmed: member.archived,
);
