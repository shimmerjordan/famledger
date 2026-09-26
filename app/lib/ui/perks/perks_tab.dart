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
import '../perk_import/perk_import_providers.dart';
import '../widgets/widgets.dart';
import 'membership_detail_page.dart';
import 'perk_progress.dart';
import 'perk_providers.dart';
import 'perk_widgets.dart';
import 'perks_current_view.dart';

/// 会员权益 tab（spec §5）：顶上「本期 | 全部」分段和「我 / 全家」过滤（上次的选择记在本机）。
/// 「本期」见 perks_current_view.dart；「全部」按会员看每张卡有哪些权益（带到期进度和回本条），
/// 或按领取平台看「去哪领什么」，归档的卡收在底部。宽屏（≥ 840）左边列表、右边会员详情。
class PerksTab extends ConsumerStatefulWidget {
  const PerksTab({super.key, this.view, this.scope, this.onPrefsTouched});

  /// 从首页、提醒点进来时先打开哪一种（`/assets?tab=perks&view=current&scope=mine`，见 perk_alert_tile.dart
  /// 的 perkAgendaLocation）：盖在本机记的选择上，但不写回去；用户一动分段就以用户选的为准，[onPrefsTouched]
  /// 让资产页忘掉这两个参数（切到别的 tab 再切回来也不再盖）。
  final PerkView? view;
  final PerkScope? scope;
  final VoidCallback? onPrefsTouched;

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

  /// 用户动了分段：以这一次看到的样子为底记进本机，不再盖首页带来的参数。
  void _setPrefs(PerkViewPrefs next) {
    widget.onPrefsTouched?.call();
    ref.read(perkViewPrefsProvider.notifier).set(next);
  }

  /// 打开一张卡：宽屏换右栏，手机推详情页。
  void _open(String id, bool wide) {
    if (wide) {
      ref.read(selectedMembershipProvider.notifier).state = id;
    } else {
      context.push('/assets/memberships/$id');
    }
  }

  @override
  Widget build(BuildContext context) {
    final ledger = ref.watch(ledgerProvider);
    final wide = widthClassOf(context) == WidthClass.expanded;
    final banner = SyncErrorBanner(error: _syncError, onRetry: _refresh);
    final prefs = ref.watch(perkViewPrefsProvider).copyWith(view: widget.view, scope: widget.scope);
    final me = ref.watch(perkMeProvider);
    // 没登录（不知道「我」是谁）时按全家看，也不给「我 / 全家」。
    final memberId = prefs.scope == PerkScope.mine ? me : null;

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
                  message: '88VIP、京东 PLUS、信用卡……把权益说明粘进来，AI 帮你拆成卡和权益、记下要去哪个平台领。',
                  icon: Icons.card_membership_outlined,
                  actionLabel: '智能导入',
                  onAction: () => context.push(perkImportLocation(want: ImportWant.virtual)),
                ),
                Center(
                  child: TextButton(
                    key: const ValueKey('perks-empty-manual'),
                    onPressed: () => context.push('/assets/memberships/new'),
                    child: const Text('手动记一张'),
                  ),
                ),
              ],
            );
          }
          final cards = [
            for (final m in data.memberships)
              if (memberId == null || m.memberId == null || m.memberId == memberId) m,
          ];
          final active = groupByMembership(
            memberships: cards,
            benefits: data.benefits,
            platforms: data.platforms,
          );
          final selected = ref.watch(selectedMembershipProvider);
          // 右栏只画「我 / 全家」过滤后还在的卡：切到「我」时不能还停在爸爸的卡上。
          final shown = wide
              ? (cards.any((m) => m.id == selected) ? selected : (active.isEmpty ? null : active.first.membership.id))
              : null;
          // 右栏实际画的那张写回去：不然默认看第一张时一归档它，第一张就换成了别的卡，右栏跟着跳走
          // （同一个位置的「归档」按钮已经属于另一张卡了）。
          if (wide && shown != selected) _pin(shown);
          final header = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [banner, _PerkTopBar(prefs: prefs, showScope: me != null, onChanged: _setPrefs)],
          );
          final list = prefs.view == PerkView.current
              ? PerksCurrentView(
                  data: data,
                  header: header,
                  memberId: memberId,
                  wide: wide,
                  onOpen: (id) => _open(id, wide),
                )
              : _PerksList(
                  data: data,
                  cards: cards,
                  active: active,
                  // 「我」名下一张在用的都没有，但全家还有：别说成「都归档了」。
                  filteredOut: memberId != null && active.isEmpty && data.memberships.any((m) => !m.archived),
                  header: header,
                  wide: wide,
                  selectedId: shown,
                  prefs: prefs,
                  onPrefsChanged: _setPrefs,
                  onOpen: (id) => _open(id, wide),
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

/// 顶上一行：「本期 | 全部」，登录了再加「我 / 全家」。选了就记进本机。
class _PerkTopBar extends StatelessWidget {
  const _PerkTopBar({required this.prefs, required this.showScope, required this.onChanged});

  final PerkViewPrefs prefs;
  final bool showScope;
  final ValueChanged<PerkViewPrefs> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, LedgerLayout.itemGap, LedgerLayout.pagePadding, 0),
      child: Wrap(
        spacing: LedgerLayout.itemGap,
        runSpacing: 8,
        children: [
          SegmentedButton<PerkView>(
            key: const ValueKey('perk-view'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: PerkView.current, label: Text('本期', key: ValueKey('perk-view-current'))),
              ButtonSegment(value: PerkView.all, label: Text('全部', key: ValueKey('perk-view-all'))),
            ],
            selected: {prefs.view},
            onSelectionChanged: (s) => onChanged(prefs.copyWith(view: s.first)),
          ),
          if (showScope)
            SegmentedButton<PerkScope>(
              key: const ValueKey('perk-scope'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: PerkScope.mine, label: Text('我', key: ValueKey('perk-scope-mine'))),
                ButtonSegment(value: PerkScope.family, label: Text('全家', key: ValueKey('perk-scope-family'))),
              ],
              selected: {prefs.scope},
              onSelectionChanged: (s) => onChanged(prefs.copyWith(scope: s.first)),
            ),
        ],
      ),
    );
  }
}

class _PerksList extends ConsumerWidget {
  const _PerksList({
    required this.data,
    required this.cards,
    required this.active,
    required this.filteredOut,
    required this.header,
    required this.wide,
    required this.selectedId,
    required this.prefs,
    required this.onPrefsChanged,
    required this.onOpen,
  });

  final LedgerData data;

  /// 「我 / 全家」过滤后的卡（含归档的）。
  final List<Membership> cards;
  final List<MembershipGroup> active;

  /// 在用的卡全被「我」滤掉了（全家还有）。
  final bool filteredOut;
  final Widget header;
  final bool wide;
  final String? selectedId;
  final PerkViewPrefs prefs;
  final ValueChanged<PerkViewPrefs> onPrefsChanged;
  final void Function(String id) onOpen;

  PerkGrouping get grouping => prefs.grouping;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(assetClockProvider)();
    final archived = groupByMembership(
      memberships: cards,
      benefits: data.benefits,
      platforms: data.platforms,
      archived: true,
    );
    return LayoutBuilder(
      builder: (context, box) => ListView(
        padding: (wide ? EdgeInsets.zero : readableInsets(box.maxWidth)).copyWith(bottom: 96),
        children: [
          header,
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
              onSelectionChanged: (s) => onPrefsChanged(prefs.copyWith(grouping: s.first)),
            ),
          ),
          if (grouping == PerkGrouping.byMembership) ...[
            if (active.isEmpty)
              filteredOut
                  ? const EmptyState(title: '你名下还没有卡', message: '家人的卡切到「全家」看。', compact: true)
                  : const EmptyState(title: '在用的卡都归档了', message: '归档的卡在下面，点开能取消归档。', compact: true),
            for (final g in active) ...[
              MembershipTile(
                data: data,
                group: g,
                now: now,
                selected: g.membership.id == selectedId,
                onTap: () => onOpen(g.membership.id),
              ),
              for (final node in g.benefits)
                BenefitTile(data: data, node: node, membership: g.membership, indent: 72),
              const SizedBox(height: LedgerLayout.itemGap),
            ],
          ] else
            ..._byPlatform(context, onOpen),
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
                    onTap: () => onOpen(g.membership.id),
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
    final groups = groupByClaimPlatform(memberships: cards, benefits: data.benefits, platforms: data.platforms);
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

/// 一张卡：平台头像、名字 · 档位、平台 · 持有人 · 几项权益 · 到期，右边续费价；
/// 下面一根回本条，竖刻度是本期时间过了几成（免费、没填费用的卡只有时间刻度，见 [PaybackBar]）。
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
    final payback = data.paybackOf(m, localDay(now));
    final line = Text(
      [
        platformLabel(group.platform),
        holderLabel(data, m),
        '${group.itemCount} 项权益',
        expiryLabel(m, now),
      ].join(' · '),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodySmall,
    );
    return ListTile(
      key: ValueKey('membership-${m.id}'),
      selected: selected,
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding, vertical: 4),
      leading: PlatformAvatar(group.platform, muted: m.archived),
      title: Text(m.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium),
      subtitle: paybackBarShown(payback)
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                line,
                const SizedBox(height: 6),
                PaybackBar(payback, key: ValueKey('payback-${m.id}')),
              ],
            )
          : line,
      trailing: fee == null ? null : PerkMoneyText(fee),
    );
  }
}
