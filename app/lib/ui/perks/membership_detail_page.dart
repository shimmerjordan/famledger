import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/money.dart';
import '../../data/api/api_client.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../assets/asset_providers.dart';
import '../assets/asset_widgets.dart';
import '../widgets/widgets.dart';
import 'perk_providers.dart';
import 'perk_widgets.dart';

/// 会员详情（`/assets/memberships/:id`）：头部信息、权益列表（「去优酷领」、限制条件、有效期、面值、领取链接）、
/// 收起来的「已归档」权益、加权益、编辑、归档、删除。回本卡、本期进度、历史打卡在 P3；「AI 补充权益」在 P4。
class MembershipDetailPage extends ConsumerWidget {
  const MembershipDetailPage(this.id, {super.key});

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = ref.watch(ledgerProvider).valueOrNull?.membership(id);
    return Scaffold(
      appBar: AppBar(
        title: Text(m?.title ?? '会员', maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (m != null)
            IconButton(
              tooltip: '编辑',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => context.push('/assets/memberships/$id/edit'),
            ),
        ],
      ),
      body: MembershipDetailView(
        id: id,
        onDeleted: () {
          if (!context.mounted) return;
          context.canPop() ? context.pop() : context.go('/assets?tab=perks');
        },
      ),
    );
  }
}

/// 会员详情的内容：手机上是整页，宽屏是会员权益 tab 的右栏（[embedded]，顶上自带一行名字和「编辑」）。
class MembershipDetailView extends ConsumerStatefulWidget {
  const MembershipDetailView({super.key, required this.id, required this.onDeleted, this.embedded = false});

  final String id;
  final VoidCallback onDeleted;
  final bool embedded;

  @override
  ConsumerState<MembershipDetailView> createState() => _MembershipDetailViewState();
}

class _MembershipDetailViewState extends ConsumerState<MembershipDetailView> {
  bool _busy = false;
  String? _error;

  /// 删掉时本地先拿掉、同步完才退出去，这中间照旧画删之前的样子，不闪「已经不在了」。
  bool _deleting = false;
  Membership? _last;

  Future<void> _archive(Membership m) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    // 先拿到 messenger：宽屏右栏里这一栏可能在请求途中被换掉，提示照样要出来。
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(perksRepoProvider).updateMembership(m.id, {'archived': !m.archived});
      messenger.showSnackBar(
        SnackBar(content: Text(m.archived ? '已取消归档' : '已归档：不进本期、不提醒')),
      );
    } catch (error) {
      if (mounted) setState(() => _error = describeError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// [what] 是「它名下的 2 项权益」这种说法；null = 本地看它名下没有权益。
  Future<bool> _confirmDelete(Membership m, String? what, {bool changed = false}) async {
    final message = what == null
        ? '删掉后找不回来。'
        : '${changed ? '别的设备刚给它加了权益。' : ''}$what和打卡记录会一起删掉；'
              '由这些权益带出来的别的卡会留着，只是不再关联。';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删掉「${m.title}」？'),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('算了')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('删掉')),
        ],
      ),
    );
    return ok == true;
  }

  /// 删卡时连带删掉的权益，和页面上「权益 · N 项」同一个数法（N 选 1 本身不算、算它的选项），
  /// 收在「已归档」里的另外说。只剩空的 N 选 1 分组时不报数。
  static String? _benefitsPhrase(LedgerData data, Membership m) {
    final rows = data.benefits.where((b) => b.membershipId == m.id).length;
    if (rows == 0) return null;
    final items = perkItemCount(benefitTree(m.id, data.benefits));
    final archived = perkItemCount(archivedBenefitTree(m.id, data.benefits));
    final parts = [if (items > 0) '$items 项权益', if (archived > 0) '$archived 项已归档的权益'];
    return parts.isEmpty ? '它名下的权益' : '它名下的 ${parts.join('、')}';
  }

  Future<void> _delete(LedgerData data, Membership m) async {
    final rows = data.benefits.where((b) => b.membershipId == m.id).length;
    if (!await _confirmDelete(m, _benefitsPhrase(data, m)) || !mounted) return;
    setState(() {
      _busy = true;
      _deleting = true;
      _error = null;
    });
    final repo = ref.read(perksRepoProvider);
    // 宽屏右栏里删掉这张卡，列表一更新这一栏就被换掉了（卸载）；提示和 onDeleted 不能因此丢掉。
    final messenger = ScaffoldMessenger.of(context);
    final onDeleted = widget.onDeleted;
    try {
      try {
        await repo.deleteMembership(m.id, cascade: rows > 0);
      } on ApiException catch (e) {
        // 本地以为没有权益、服务端却有（别的设备刚加的）：按服务端的数再问一次，不静默删掉。
        if (e.code != 'has_children' || !mounted) rethrow;
        final n = e.details['benefits'] is int ? e.details['benefits'] as int : 1;
        if (!await _confirmDelete(m, '它名下的 $n 项权益（含选项）', changed: true)) {
          if (mounted) {
            setState(() {
              _busy = false;
              _deleting = false;
            });
          }
          return;
        }
        await repo.deleteMembership(m.id, cascade: true);
      }
      messenger.showSnackBar(const SnackBar(content: Text('已删掉')));
      onDeleted();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _deleting = false;
        _error = describeError(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(ledgerProvider).valueOrNull;
    final live = data?.membership(widget.id);
    if (live != null) _last = live;
    final m = live ?? (_deleting ? _last : null);
    if (data == null) return const SkeletonList(rows: 5);
    if (m == null) return const InlineError(message: '这张卡已经不在了。');
    final now = ref.watch(assetClockProvider)();
    final platform = data.platform(m.platformId);
    final tree = benefitTree(m.id, data.benefits);
    final archivedTree = archivedBenefitTree(m.id, data.benefits);
    final theme = Theme.of(context);

    return LayoutBuilder(
      builder: (context, box) => ListView(
        padding: (widget.embedded ? EdgeInsets.zero : readableInsets(box.maxWidth, maxWidth: 720)).copyWith(bottom: 96),
        children: [
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding, vertical: 8),
            leading: PlatformAvatar(platform, muted: m.archived),
            title: Text(m.title, style: theme.textTheme.titleMedium),
            subtitle: Text('${platformLabel(platform)} · ${m.kindLabel}${m.archived ? ' · 已归档' : ''}'),
            trailing: widget.embedded
                ? IconButton(
                    tooltip: '编辑',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => context.push('/assets/memberships/${m.id}/edit'),
                  )
                : null,
          ),
          ..._info(context, data, m, now),
          const SizedBox(height: LedgerLayout.groupGap),
          SectionHeader(
            '权益 · ${perkItemCount(tree)} 项',
            actionLabel: '加一项',
            onAction: () => context.push('/assets/memberships/${m.id}/benefits/new'),
          ),
          if (tree.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
              child: Text('还没记权益：年卡、券、贵宾厅……每一样记一项，写清去哪领。', style: theme.textTheme.bodySmall),
            ),
          for (final node in tree) ...[
            BenefitTile(data: data, node: node, membership: m, detailed: true),
            if (node.benefit.isChoice)
              Padding(
                padding: const EdgeInsets.only(left: LedgerLayout.pagePadding),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: ValueKey('add-option-${node.benefit.id}'),
                    onPressed: () => context.push('/assets/memberships/${m.id}/benefits/new?parentId=${node.benefit.id}'),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('加一个选项'),
                  ),
                ),
              ),
          ],
          if (archivedTree.isNotEmpty)
            ExpansionTile(
              key: const ValueKey('benefits-archived'),
              shape: const Border(),
              collapsedShape: const Border(),
              tilePadding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
              expansionAnimationStyle: MediaQuery.disableAnimationsOf(context)
                  ? AnimationStyle.noAnimation
                  : AnimationStyle(duration: const Duration(milliseconds: 200), curve: Easing.emphasizedDecelerate),
              title: Text('已归档 · ${perkItemCount(archivedTree)} 项'),
              subtitle: const Text('不在列表和本期里显示；点开一项能取消归档'),
              children: [
                for (final node in archivedTree) BenefitTile(data: data, node: node, membership: m, detailed: true),
              ],
            ),
          const SizedBox(height: LedgerLayout.groupGap),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonal(
                  key: const ValueKey('membership-archive'),
                  onPressed: _busy ? null : () => _archive(m),
                  child: Text(m.archived ? '取消归档' : '归档'),
                ),
                OutlinedButton(
                  key: const ValueKey('membership-delete'),
                  onPressed: _busy ? null : () => _delete(data, m),
                  child: const Text('删除'),
                ),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, LedgerLayout.itemGap, LedgerLayout.pagePadding, 0),
              child: Text(_error!, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error)),
            ),
        ],
      ),
    );
  }

  List<Widget> _info(BuildContext context, LedgerData data, Membership m, DateTime now) {
    final fee = feeLabel(m);
    final term = switch ((m.termStartOn, m.expiresOn)) {
      (null, null) => null,
      (final from?, null) => '$from 起',
      (null, final until?) => '至 $until',
      (final from?, final until?) => '$from 至 $until',
    };
    final source = data.benefit(m.sourceBenefitId);
    final sourceCard = source == null ? null : data.membership(source.membershipId);
    final remind = switch (m.remindDays) {
      null => '默认',
      0 => '不提醒',
      final d => '提前 $d 天',
    };
    return [
      InfoRow('持有人', InfoText(holderLabel(data, m))),
      InfoRow('到期', InfoText(expiryLabel(m, now))),
      if (term != null) InfoRow('本期', InfoText(term)),
      if (fee != null) InfoRow('续费价', PerkMoneyText(fee)),
      if (m.termPaidCents != null)
        InfoRow('本期实付', PerkMoneyText(m.termPaidCents == 0 ? '免费' : Money.format(m.termPaidCents!))),
      InfoRow('续费', InfoText(Membership.autoRenewLabels[m.autoRenew] ?? '不确定')),
      if (m.isTrial) const InfoRow('试用', InfoText('试用中')),
      InfoRow('到期提醒', InfoText(remind)),
      if (m.kind == 'credit_card' && m.accountId != null)
        InfoRow('关联账户', InfoText(data.account(m.accountId)?.name ?? '账户已删除')),
      if (source != null)
        InfoRow(
          '来自',
          TextButton(
            key: const ValueKey('membership-source'),
            // 宽屏右栏里就地换成那张卡，不盖一整页上来。
            onPressed: sourceCard == null
                ? null
                : () => widget.embedded
                      ? ref.read(selectedMembershipProvider.notifier).state = sourceCard.id
                      : context.push('/assets/memberships/${sourceCard.id}'),
            child: Text('${sourceCard?.title ?? '已删除的卡'} · ${source.name}'),
          ),
        ),
      if (m.note != null) InfoRow('备注', InfoText(m.note!)),
    ];
  }
}
