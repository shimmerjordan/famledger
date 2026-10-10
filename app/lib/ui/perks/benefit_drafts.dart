import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/page_frame.dart';
import '../../app/providers.dart';
import '../../core/ids.dart';
import '../../core/money.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import 'benefit_form_page.dart';

/// 还没存的一项权益：建卡时顺带的权益、建「N 选 1」时顺带的选项。存卡（存「N 选 1」）时整批一起发给服务端
/// （`POST /memberships` 的 `benefits`、`POST /benefits` 的 `options`），同一个事务里建好 —— 不用建完再去详情里一项项补。
class BenefitDraft {
  BenefitDraft({String? key, required this.body, this.options = const []}) : key = key ?? newClientId();

  /// 在列表里认它（改、删），不发给服务端。
  final String key;

  /// `POST /benefits` 的字段（不含 membershipId / parentId / clientId，那些由父请求定）。
  final Map<String, dynamic> body;

  /// 「N 选 1」顺带的选项；别的类型永远是空的。
  final List<BenefitDraft> options;

  String get name => body['name'] as String? ?? '';
  bool get isChoice => body['kind'] == Benefit.kindChoice;

  /// 当成一条权益来看（额度、类型的说法，表单回填都按它）。
  Benefit get preview => Benefit.fromJson({...body, 'id': key, 'membershipId': ''});

  /// 发给服务端的样子：「N 选 1」带上选项。
  Map<String, dynamic> toJson() => {
    ...body,
    if (isChoice && options.isNotEmpty) 'options': [for (final o in options) o.toJson()],
  };

  BenefitDraft copyWith({Map<String, dynamic>? body, List<BenefitDraft>? options}) =>
      BenefitDraft(key: key, body: body ?? this.body, options: options ?? this.options);
}

/// 草稿挂在哪：卡叫什么、会员本平台是哪个（「在哪领」默认跟它）；编辑选项时再带上它的「N 选 1」。
class BenefitDraftScope {
  const BenefitDraftScope({required this.cardTitle, this.homePlatformId, this.parentName, this.parentClaimPlatformId});

  /// 卡名还没填时是「这张卡」。
  final String cardTitle;
  final String? homePlatformId;

  /// 不为 null = 这是「N 选 1」的一个选项（还没起名时是「这个 N 选 1」）。
  final String? parentName;
  final String? parentClaimPlatformId;

  bool get option => parentName != null;
}

/// 打开草稿表单（同一张权益表单，「加好了」不连服务端，把填的东西交回来）；点返回 = 不加，回 null。
/// 宽屏照样带着左边的导航轨（[PageFrame]），和别的整屏页一样。
Future<BenefitDraft?> editBenefitDraft(BuildContext context, {required BenefitDraftScope scope, BenefitDraft? initial}) {
  String location;
  try {
    location = GoRouterState.of(context).uri.toString();
  } catch (_) {
    location = '/assets';
  }
  return Navigator.of(context, rootNavigator: true).push<BenefitDraft>(
    MaterialPageRoute(
      builder: (_) => PageFrame(location: location, child: BenefitFormPage.draft(scope: scope, initial: initial)),
    ),
  );
}

/// 一行草稿的副标题：「N 选 1 · 每年 1 次 · 2 个选项」「券 · 每月 4 次」；选项写在哪领、面值。
String benefitDraftSummary(LedgerData? ledger, BenefitDraft d, {required bool option}) {
  final b = d.preview;
  if (option) {
    final parts = [
      if (b.kind != 'other') b.kindLabel,
      if (b.claimPlatformId != null) '在${platformLabel(ledger?.platform(b.claimPlatformId))}领',
      if (b.faceValueCents != null) '面值 ${Money.format(b.faceValueCents!)}',
    ];
    return parts.isEmpty ? '点开能补在哪领、面值、限制' : parts.join(' · ');
  }
  if (b.isChoice) {
    final n = d.options.length;
    return 'N 选 1 · ${quotaLabel(b.quota)} · ${n == 0 ? '还没加选项' : '$n 个选项'}';
  }
  return '${b.kindLabel} · ${quotaLabel(b.quota)}';
}

/// 表单里的草稿列表：每行点开改、右边去掉；底下「加一项权益」。[quickAdd] 为真（选项）时多一个输入框：
/// 打名字回车就加一个（选项大多只有名字），要补在哪领、面值再点开那一行。
class BenefitDraftList extends ConsumerStatefulWidget {
  const BenefitDraftList({
    super.key,
    required this.drafts,
    required this.onChanged,
    required this.scope,
    required this.keyPrefix,
    this.quickAdd = false,
    this.enabled = true,
  });

  final List<BenefitDraft> drafts;
  final ValueChanged<List<BenefitDraft>> onChanged;

  /// 每次打开草稿表单时现取（卡名、平台在外面随时会改）。
  final BenefitDraftScope Function() scope;

  /// 控件 key 的前缀：`<prefix>-add`、`<prefix>-0`、`<prefix>-remove-0`、`<prefix>-quick`。
  final String keyPrefix;
  final bool quickAdd;

  /// 外面那张表单在存的时候为 false：不让再点开、增删（存完会离开这一页，中途点开的草稿会被一起关掉）。
  final bool enabled;

  @override
  ConsumerState<BenefitDraftList> createState() => _BenefitDraftListState();
}

class _BenefitDraftListState extends ConsumerState<BenefitDraftList> {
  final TextEditingController _quick = TextEditingController();
  final FocusNode _quickFocus = FocusNode();

  String get _noun => widget.quickAdd ? '选项' : '权益';

  @override
  void dispose() {
    _quick.dispose();
    _quickFocus.dispose();
    super.dispose();
  }

  Future<void> _edit(int? index) async {
    final initial = index == null ? null : widget.drafts[index];
    final result = await editBenefitDraft(context, scope: widget.scope(), initial: initial);
    if (result == null || !mounted) return;
    final next = [...widget.drafts];
    if (index == null) {
      next.add(result);
    } else {
      next[index] = result;
    }
    widget.onChanged(next);
  }

  void _addQuick() {
    final name = _quick.text.trim();
    if (name.isEmpty) return;
    widget.onChanged([...widget.drafts, BenefitDraft(body: {'name': name, 'kind': 'other'})]);
    _quick.clear();
    // 接着打下一个：焦点留在框里。
    _quickFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ledger = ref.watch(ledgerProvider).valueOrNull;
    final prefix = widget.keyPrefix;
    final tooMany = widget.drafts.length >= (widget.quickAdd ? 30 : 50);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < widget.drafts.length; i++)
          ListTile(
            key: ValueKey('$prefix-$i'),
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            enabled: widget.enabled,
            onTap: () => _edit(i),
            title: Text(widget.drafts[i].name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              benefitDraftSummary(ledger, widget.drafts[i], option: widget.quickAdd),
              style: theme.textTheme.bodySmall,
            ),
            trailing: IconButton(
              key: ValueKey('$prefix-remove-$i'),
              tooltip: '去掉这个$_noun',
              icon: const Icon(Icons.close),
              onPressed: widget.enabled ? () => widget.onChanged([...widget.drafts]..removeAt(i)) : null,
            ),
          ),
        if (widget.quickAdd && !tooMany)
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: ValueKey('$prefix-quick'),
                  controller: _quick,
                  focusNode: _quickFocus,
                  enabled: widget.enabled,
                  // 和服务端一样最多 60 个字：超了等存卡时才报错就晚了。
                  inputFormatters: [LengthLimitingTextInputFormatter(60)],
                  textInputAction: TextInputAction.done,
                  // 用 onEditingComplete 而不是 onSubmitted：给了它，回车就不会先把焦点收走（网页上收走再要回来
                  // 会丢掉接着打的字），连着打几个选项名字不用每次再点一下框。
                  onEditingComplete: _addQuick,
                  decoration: const InputDecoration(hintText: '选项名称，例如「优酷年卡」，回车加一个'),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                key: ValueKey('$prefix-quick-add'),
                tooltip: '加这个选项',
                onPressed: widget.enabled ? _addQuick : null,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        if (!tooMany)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: ValueKey('$prefix-add'),
              onPressed: widget.enabled ? () => _edit(null) : null,
              icon: const Icon(Icons.add, size: 18),
              label: Text(widget.quickAdd ? '详细填一个选项' : '加一项权益'),
            ),
          ),
        if (tooMany)
          Text(
            widget.quickAdd ? '一次最多 30 个选项，多的存好后在会员详情里加' : '一次最多 50 项，多的存好后在会员详情里加',
            style: theme.textTheme.bodySmall,
          ),
      ],
    );
  }
}
