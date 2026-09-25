import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/shell.dart';
import '../../app/theme.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../assets/asset_providers.dart';
import '../assets/asset_widgets.dart';
import '../widgets/widgets.dart';
import 'membership_detail_page.dart';
import 'perk_providers.dart';
import 'perk_widgets.dart';

/// 会员权益 tab 的「全部」视图（spec §5）：按会员看每张卡有哪些权益，或按领取平台看「去哪领什么」。
/// 归档的卡收在底部。宽屏（≥ 840）左边列表、右边会员详情。
///
/// 「本期」分段、我/全家过滤、一键打卡在 P3 加在这一页的顶上。
class PerksTab extends ConsumerStatefulWidget {
  const PerksTab({super.key});

  @override
  ConsumerState<PerksTab> createState() => _PerksTabState();
}

class _PerksTabState extends ConsumerState<PerksTab> {
  Object? _syncError;

  /// 画完这一帧再写（build 里不能改 provider）。
  void _pin(String? id) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final selected = ref.read(selectedMembershipProvider.notifier);
      if (selected.state != id) selected.state = id;
    });
  }

  Future<void> _refresh() async {
    Object? error;
    try {
      await ref.read(ledgerProvider.notifier).sync();
      if (mounted) refreshNetWorth(ref);
    } catch (e) {
      error = e;
    }
    if (mounted) setState(() => _syncError = error);
  }

  @override
  Widget build(BuildContext context) {
    final ledger = ref.watch(ledgerProvider);
    final wide = widthClassOf(context) == WidthClass.expanded;
    final banner = SyncErrorBanner(error: _syncError, onRetry: _refresh);

    return RefreshIndicator(
      onRefresh: _refresh,
      child: AsyncValueView<LedgerData>(
        value: ledger,
        loading: ListView(children: const [SkeletonList(rows: 5)]),
        onRetry: () => ref.invalidate(ledgerProvider),
        data: (data) {
          if (data.memberships.isEmpty) {
            return ListView(
              children: [
                banner,
                const SizedBox(height: 40),
                EmptyState(
                  title: '还没记会员卡',
                  message: '88VIP、京东 PLUS、信用卡……记下它有哪些权益、要去哪个平台领。',
                  icon: Icons.card_membership_outlined,
                  actionLabel: '记一张',
                  onAction: () => context.push('/assets/memberships/new'),
                ),
              ],
            );
          }
          final active = groupByMembership(
            memberships: data.memberships,
            benefits: data.benefits,
            platforms: data.platforms,
          );
          final selected = ref.watch(selectedMembershipProvider);
          final shown = wide
              ? (data.membership(selected) != null ? selected : (active.isEmpty ? null : active.first.membership.id))
              : null;
          // 右栏实际画的那张写回去：不然默认看第一张时一归档它，第一张就换成了别的卡，右栏跟着跳走
          // （同一个位置的「归档」按钮已经属于另一张卡了）。
          if (wide && shown != selected) _pin(shown);
          final list = _PerksList(
            data: data,
            active: active,
            banner: banner,
            wide: wide,
            selectedId: shown,
          );
          if (!wide) return list;
          return AdaptiveTwoPane(
            main: list,
            side: shown == null
                ? const EmptyState(title: '选一张卡看详情', compact: true)
                : MembershipDetailView(
                    key: ValueKey('perks-side-$shown'),
                    id: shown,
                    embedded: true,
                    // 删完回到「默认看第一张」；右栏那时多半已经换掉了，这里只在 tab 还在时动。
                    onDeleted: () {
                      if (mounted) ref.read(selectedMembershipProvider.notifier).state = null;
                    },
                  ),
          );
        },
      ),
    );
  }
}

class _PerksList extends ConsumerWidget {
  const _PerksList({
    required this.data,
    required this.active,
    required this.banner,
    required this.wide,
    required this.selectedId,
  });

  final LedgerData data;
  final List<MembershipGroup> active;
  final Widget banner;
  final bool wide;
  final String? selectedId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final grouping = ref.watch(perkGroupingProvider);
    final now = ref.watch(assetClockProvider)();
    final archived = groupByMembership(
      memberships: data.memberships,
      benefits: data.benefits,
      platforms: data.platforms,
      archived: true,
    );
    void open(String id) {
      if (wide) {
        ref.read(selectedMembershipProvider.notifier).state = id;
      } else {
        context.push('/assets/memberships/$id');
      }
    }

    return LayoutBuilder(
      builder: (context, box) => ListView(
        padding: (wide ? EdgeInsets.zero : readableInsets(box.maxWidth)).copyWith(bottom: 96),
        children: [
          banner,
          Padding(
            padding: const EdgeInsets.fromLTRB(
              LedgerLayout.pagePadding,
              LedgerLayout.itemGap,
              LedgerLayout.pagePadding,
              LedgerLayout.itemGap,
            ),
            child: SegmentedButton<PerkGrouping>(
              key: const ValueKey('perk-grouping'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: PerkGrouping.byMembership, label: Text('按会员')),
                ButtonSegment(value: PerkGrouping.byClaimPlatform, label: Text('按领取平台')),
              ],
              selected: {grouping},
              onSelectionChanged: (s) => ref.read(perkGroupingProvider.notifier).state = s.first,
            ),
          ),
          if (grouping == PerkGrouping.byMembership) ...[
            if (active.isEmpty)
              const EmptyState(title: '在用的卡都归档了', message: '归档的卡在下面，点开能取消归档。', compact: true),
            for (final g in active) ...[
              MembershipTile(
                data: data,
                group: g,
                now: now,
                selected: g.membership.id == selectedId,
                onTap: () => open(g.membership.id),
              ),
              for (final node in g.benefits)
                BenefitTile(data: data, node: node, membership: g.membership, indent: 72),
              const SizedBox(height: LedgerLayout.itemGap),
            ],
          ] else
            ..._byPlatform(context, open),
          if (archived.isNotEmpty)
            ExpansionTile(
              key: const ValueKey('perks-archived'),
              shape: const Border(),
              collapsedShape: const Border(),
              tilePadding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
              expansionAnimationStyle: MediaQuery.disableAnimationsOf(context)
                  ? AnimationStyle.noAnimation
                  : AnimationStyle(duration: const Duration(milliseconds: 200), curve: Easing.emphasizedDecelerate),
              title: Text('已归档 · ${archived.length} 张'),
              subtitle: const Text('不再持有的卡：不进本期、不提醒'),
              children: [
                for (final g in archived)
                  MembershipTile(
                    data: data,
                    group: g,
                    now: now,
                    selected: g.membership.id == selectedId,
                    onTap: () => open(g.membership.id),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  /// 按领取平台：组头「优酷 · 3 项」，每行写来自哪张卡；点一行打开那张卡。
  List<Widget> _byPlatform(BuildContext context, void Function(String id) open) {
    final theme = Theme.of(context);
    final groups = groupByClaimPlatform(memberships: data.memberships, benefits: data.benefits, platforms: data.platforms);
    if (groups.isEmpty) {
      return const [EmptyState(title: '还没记权益', message: '到会员详情里给卡加上权益，这里就按领取平台排好。', compact: true)];
    }
    return [
      for (final g in groups) ...[
        SectionHeader(
          '${platformLabel(g.platform)} · ${g.entries.length} 项',
          key: ValueKey('claim-group-${g.platformId}'),
        ),
        for (final e in g.entries)
          ListTile(
            key: ValueKey('claim-entry-${e.benefit.id}'),
            contentPadding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
            onTap: () => open(e.membership.id),
            title: Text(e.benefit.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: e.benefit.claimUrl == null ? null : ClaimLinkButton(e.benefit.claimUrl!, key: ValueKey('claim-link-${e.benefit.id}')),
            subtitle: Text(
              [
                '来自 ${e.membership.title}',
                if (e.parent != null) '「${e.parent!.name}」的选项',
                quotaLabel((e.parent ?? e.benefit).quota),
                if (e.benefit.claimHow != null) e.benefit.claimHow!,
              ].join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
        const SizedBox(height: LedgerLayout.itemGap),
      ],
    ];
  }
}

/// 一张卡：平台头像、名字 · 档位、平台 · 持有人 · 几项权益 · 到期，右边续费价。
class MembershipTile extends StatelessWidget {
  const MembershipTile({
    super.key,
    required this.data,
    required this.group,
    required this.now,
    required this.onTap,
    this.selected = false,
  });

  final LedgerData data;
  final MembershipGroup group;
  final DateTime now;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = group.membership;
    final fee = feeLabel(m);
    return ListTile(
      key: ValueKey('membership-${m.id}'),
      selected: selected,
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding, vertical: 4),
      leading: PlatformAvatar(group.platform, muted: m.archived),
      title: Text(m.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium),
      subtitle: Text(
        [
          platformLabel(group.platform),
          holderLabel(data, m),
          '${group.itemCount} 项权益',
          expiryLabel(m, now),
        ].join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      trailing: fee == null ? null : PerkMoneyText(fee),
    );
  }
}
