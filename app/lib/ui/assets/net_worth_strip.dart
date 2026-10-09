import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../core/money.dart';
import '../../data/api/api_client.dart';
import '../../data/models/models.dart';
import '../widgets/widgets.dart';

/// 「现金流」：账户净额——现金、银行卡、支付宝这些账户的余额合计，信用卡欠款（负余额）已经减掉。
/// 就是服务端 overview 里 accounts 的和，这里只是给它一个说得出口的名字。
int cashFlowCents(StatsOverview o) => o.accountsNetCents;

/// 目标、储备两类基金（旅行、应急、养老这种专款）里攒着的钱：正余额之和。
/// 超支（负余额）的钱早从账户里花出去、账户净额里已经减掉，这里不再减一次。
int reservedCents(StatsOverview o, Iterable<Fund> funds) {
  final saving = {
    for (final f in funds)
      if (Fund.savingKinds.contains(f.kind)) f.id,
  };
  var sum = 0;
  for (final b in o.funds) {
    if (b.balanceCents > 0 && saving.contains(b.fundId)) sum += b.balanceCents;
  }
  return sum;
}

/// 「可支配现金流」= 现金流 − 专款里攒着的钱：真能随便花的部分。
int disposableCents(StatsOverview o, Iterable<Fund> funds) =>
    cashFlowCents(o) - reservedCents(o, funds);

/// 折叠时那行小字：「现金流 ¥… · 可支配 ¥… · 投资（账户外）¥… · 实物计入 ¥…」，
/// 总开关关着时末段写「不含实物」。
///
/// 现金流、投资、实物计入加起来就是净资产（可支配是现金流的一部分，不另外加）。
/// 「投资（账户外）」是账户余额以外的那部分：挂了账户的持仓成本早就以转账进了账户余额，
/// 只补浮盈；没挂账户的整份市值（口径在 stats.js）。所以它不是持仓市值，明细里另外说。
/// 「实物计入」是计入额，不是物品页的估值合计。
///
/// 没有专款攒着钱时可支配就等于现金流，不重复写；没有持仓影响时不写投资；
/// 没有在用的物品（或老服务端没给 physical）时不写实物。
String netWorthBreakdown(StatsOverview o, {int reservedCents = 0}) {
  final p = o.physical;
  final invest = o.investNetCents;
  final cash = cashFlowCents(o);
  return [
    '现金流 ${Money.format(cash)}',
    if (reservedCents > 0) '可支配 ${Money.format(cash - reservedCents)}',
    if (invest != 0) '投资（账户外）${Money.format(invest)}',
    if (p != null && p.count > 0)
      p.counted ? '实物计入 ${Money.format(p.includedCents)}' : '不含实物',
  ].join(' · ');
}

/// 总览里的一项：名目、数、一句说明口径的副标题。宽屏排成一行格子，窄屏展开后一行一项。
class _Figure {
  const _Figure({
    required this.key,
    required this.label,
    required this.cents,
    required this.note,
  });

  final String key;
  final String label;
  final int cents;
  final String note;
}

/// 净资产的几段，按「现金流 → 可支配 → 投资 → 实物」排：先说手头有多少钱、多少能动，再说别的。
List<_Figure> _figures(StatsOverview o, int reserved) {
  final cash = cashFlowCents(o);
  final invest = o.investNetCents;
  final market = o.investMarketCents;
  // 市值 − 账户外那部分 = 挂了账户的持仓成本（已经在账户余额里）。
  final costInAccounts = market == null ? 0 : market - invest;
  final p = o.physical;
  return [
    _Figure(key: 'cash', label: '现金流', cents: cash, note: '账户余额合计，已减信用卡欠款'),
    _Figure(
      key: 'disposable',
      label: '可支配现金流',
      cents: cash - reserved,
      note: reserved > 0 ? '已扣目标、储备基金攒着的 ${Money.format(reserved)}' : '目标、储备基金没攒着钱，和现金流一样',
    ),
    if (invest != 0 || (market ?? 0) > 0)
      _Figure(
        key: 'invest',
        label: '投资（账户外）',
        cents: invest,
        note: market == null
            ? '账户余额以外的那部分'
            : costInAccounts > 0
            ? '市值 ${Money.format(market)}，成本 ${Money.format(costInAccounts)} 已在账户里'
            : '持仓没挂账户，整份市值都算',
      ),
    if (p != null && p.count > 0)
      p.counted
          ? _Figure(
              key: 'physical',
              label: '实物计入',
              cents: p.includedCents,
              note: '估值 ${Money.format(p.valueCents)}，按类别计入',
            )
          : _Figure(
              key: 'physical',
              label: '实物估值',
              cents: p.valueCents,
              note: '不计入净资产，打开开关后计入 ${Money.format(p.includedCents)}',
            ),
  ];
}

/// 净资产格子下面那句：它由哪几段加起来。
String _netWorthNote(List<_Figure> figures) {
  final parts = [
    for (final f in figures)
      if (f.key == 'cash') '现金流'
      else if (f.key == 'invest') '投资'
      else if (f.key == 'physical' && f.label == '实物计入') '实物计入',
  ];
  return parts.length == 1 ? '只有账户里的钱' : parts.join(' + ');
}

/// 总览取不到的原因，说短一点：断网就说「连不上服务器」，不把异常原文糊上来。
String _reason(Object error) =>
    error is ApiException && error.isNetwork ? '连不上服务器' : describeError(error);

/// 资产页 Tab 上方的净资产总览（spec §5）：一行总数 + 分项，点一下展开明细，里面有
/// 「实物计入净资产」的全局开关。这是 App 第一次展示净资产；首页不放这个大数字。
///
/// 数字全用服务端 `GET /stats/overview`（口径在 stats.js，这里不再算一遍）。本地数据一同步
/// （[LedgerData.seq] 变了：物品、持仓、账户有改动）就重取，改完估值这一行不会停在旧数上；
/// 下拉刷新时也重取（[refreshNetWorth]）。统计不做本地缓存，所以离线时这里只有一行
/// 「暂时算不出来」和重试，下面的物品、投资照常看；取到过又刷新失败，就留着旧数字、旁边说一声。
class NetWorthStrip extends ConsumerStatefulWidget {
  const NetWorthStrip({super.key});

  @override
  ConsumerState<NetWorthStrip> createState() => _NetWorthStripState();
}

class _NetWorthStripState extends ConsumerState<NetWorthStrip> {
  bool _expanded = false;
  bool _saving = false;

  /// 开关刚改成的值，新的总览还没取回来：开关先翻过去，不然 PATCH 完、总览回来前看着像没生效。
  bool? _pending;
  String? _error;

  Future<void> _setCounted(String month, bool value) async {
    setState(() {
      _saving = true;
      _pending = value;
      _error = null;
    });
    try {
      await ref.read(settingsProvider.notifier).patch({
        'assets': {'netWorthIncludesPhysical': value},
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _pending = null;
          _error = describeError(error);
        });
      }
      return;
    }
    if (!mounted) return;
    // 各月的总览都含净资产，全作废；当月这份等它回来再放开开关，数字和开关一起翻。
    ref.invalidate(statsProvider);
    try {
      await ref.read(statsProvider(month).future);
    } catch (_) {
      // 没取回来：旧数字旁边有「没刷新上」和重试；设置已经存上了，开关照新值显示。
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final month = Dates.currentMonth();
    ref.listen<int?>(
      ledgerProvider.select((ledger) => ledger.valueOrNull?.seq),
      (previous, next) {
        if (previous != null && next != null && previous != next) {
          ref.invalidate(statsProvider(month));
        }
      },
    );
    // 新总览到了，开关改回跟着它走（watch 本来就会重画，不用 setState）。重取途中 Riverpod 给的
    // 也是带旧值的 AsyncData（isLoading 为真），得等它真回来。
    ref.listen<AsyncValue<StatsOverview>>(statsProvider(month), (_, next) {
      if (next.hasValue && !next.isLoading && !next.hasError) _pending = null;
    });
    final stats = ref.watch(statsProvider(month));
    final canEdit = ref.watch(sessionProvider)?.me.isAdmin ?? false;
    // 「可支配」要知道哪些基金是目标/储备：基金本身在主数据里，余额在总览里。
    final funds = ref.watch(ledgerProvider.select((ledger) => ledger.valueOrNull?.funds)) ?? const <Fund>[];
    final overview = stats.valueOrNull;
    final retry = stats.isLoading ? null : () => ref.invalidate(statsProvider(month));
    // 这一条和下面的 Tab、四段一样宽：宽屏上分项排成一行格子铺满，不像整屏页那样收窄居中——
    // 不然「净资产」缩在中间、两边空着，和铺满的列表、右栏对不齐。
    return LayoutBuilder(
      builder: (context, box) {
        final wide = LedgerLayout.isExpanded(box.maxWidth);
        if (overview != null) {
          return _content(
            context,
            overview,
            wide: wide,
            reserved: reservedCents(overview, funds),
            canEdit: canEdit,
            month: month,
            stale: stats.hasError ? _reason(stats.error!) : null,
            onRetry: retry,
          );
        }
        if (stats.hasError) return _StripError(reason: _reason(stats.error!), onRetry: retry);
        return const _StripSkeleton();
      },
    );
  }

  Widget _content(
    BuildContext context,
    StatsOverview o, {
    required bool wide,
    required int reserved,
    required bool canEdit,
    required String month,
    required String? stale,
    required VoidCallback? onRetry,
  }) {
    final theme = Theme.of(context);
    final figures = _figures(o, reserved);
    final details = _expanded
        ? _details(context, o, figures, wide: wide, canEdit: canEdit, month: month)
        : const SizedBox(width: double.infinity);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          key: const ValueKey('net-worth-strip'),
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              LedgerLayout.pagePadding,
              8,
              LedgerLayout.pagePadding,
              8,
            ),
            child: Row(
              children: [
                Expanded(
                  child: wide ? _cells(context, o, figures) : _compactHead(context, o, reserved),
                ),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  semanticLabel: _expanded ? '收起明细' : '展开明细',
                ),
              ],
            ),
          ),
        ),
        if (stale != null)
          Padding(
            key: const ValueKey('net-worth-stale'),
            padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, 0, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '没刷新上（$stale），先显示之前的数',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                TextButton(onPressed: onRetry, child: const Text('重试')),
              ],
            ),
          ),
        // DESIGN.md：系统关了动画就瞬切 —— 直接换，不套 AnimatedSize（零时长的 AnimatedSize
        // 会在布局途中通知重排，Flutter 直接报错）。
        if (MediaQuery.disableAnimationsOf(context))
          details
        else
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Easing.emphasizedDecelerate,
            alignment: Alignment.topCenter,
            child: details,
          ),
      ],
    );
  }

  /// 窄屏折叠时两行就够：「净资产 ¥…」一行，分项一行（放不下就省略，展开有明细）。
  /// 这一条压在四段上面，它每多一行，下面的列表就少露一行。
  Widget _compactHead(BuildContext context, StatsOverview o, int reserved) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text('净资产', style: theme.textTheme.bodySmall),
            const SizedBox(width: 8),
            Flexible(child: MoneyText(o.netWorthCents, size: MoneySize.title)),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          netWorthBreakdown(o, reservedCents: reserved),
          key: const ValueKey('net-worth-breakdown'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }

  /// 宽屏：净资产和它的几段排成一行格子，每格「名目 / 数 / 一句口径」，不用展开就知道每个数是什么。
  /// 顶对齐：名目一行、数一行，像一张表；口径一两行不等，放在下面各自收尾。
  Widget _cells(BuildContext context, StatsOverview o, List<_Figure> figures) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        flex: 5,
        child: _Cell(
          key: const ValueKey('net-worth-figure-total'),
          label: '净资产',
          value: MoneyText(o.netWorthCents, size: MoneySize.title),
          note: _netWorthNote(figures),
        ),
      ),
      for (final f in figures)
        Expanded(
          flex: 4,
          child: _Cell(
            key: ValueKey('net-worth-figure-${f.key}'),
            label: f.label,
            value: MoneyText(f.cents),
            note: f.note,
          ),
        ),
    ],
  );

  Widget _details(
    BuildContext context,
    StatsOverview o,
    List<_Figure> figures, {
    required bool wide,
    required bool canEdit,
    required String month,
  }) {
    final theme = Theme.of(context);
    final p = o.physical;
    const hintPadding = EdgeInsets.fromLTRB(
      LedgerLayout.pagePadding,
      0,
      LedgerLayout.pagePadding,
      LedgerLayout.itemGap,
    );
    const manage = Padding(
      padding: EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding - 12),
      child: _ManageAccounts(),
    );
    final ValueChanged<bool>? onSwitch = p != null && canEdit && !_saving ? (v) => _setCounted(month, v) : null;
    final switchOn = p == null ? false : _pending ?? p.counted;
    return Column(
      key: const ValueKey('net-worth-details'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (wide)
          // 格子里已经把每段说清了，展开只剩两个动作：管账户、开关实物。两端对齐：
          // 「管理账户」顶左，开关连着它的说明顶右，中间不夹一块悬空的文字。
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              manage,
              if (p != null) Flexible(child: _InlineSwitch(value: switchOn, onChanged: onSwitch)),
            ],
          )
        else ...[
          for (final f in figures) ...[
            _FigureRow(f),
            if (f.key == 'cash') manage,
          ],
          if (p != null)
            SwitchListTile(
              key: const ValueKey('net-worth-switch'),
              value: switchOn,
              onChanged: onSwitch,
              title: const Text(_InlineSwitch.title),
              subtitle: const Text(_InlineSwitch.subtitle),
            ),
        ],
        if (p != null && !canEdit)
          Padding(
            padding: hintPadding,
            child: Text('只有管理员能改这个开关。', style: theme.textTheme.bodySmall),
          ),
        if (p != null && _error != null)
          Padding(
            padding: hintPadding,
            child: Text(
              _error!,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
            ),
          ),
      ],
    );
  }
}

/// 宽屏那一行里的一格：名目 / 数 / 一句口径（最多两行）。
class _Cell extends StatelessWidget {
  const _Cell({super.key, required this.label, required this.value, required this.note});

  final String label;
  final Widget value;
  final String note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: LedgerLayout.pagePadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.bodySmall),
          const SizedBox(height: 2),
          value,
          const SizedBox(height: 2),
          Text(note, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// 宽屏展开后右边那个开关：说明紧挨着开关（不是 SwitchListTile 那种说明在左、开关在最右、
/// 中间空半屏），整块可点。
class _InlineSwitch extends StatelessWidget {
  const _InlineSwitch({required this.value, required this.onChanged});

  static const String title = '实物计入净资产';
  static const String subtitle = '数码、出行、箱包/奢侈品、首饰按类别计入，其余不计；单件在物品里改';

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onChanged != null;
    return InkWell(
      onTap: enabled ? () => onChanged!(!value) : null,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.bodyLarge),
                  Text(subtitle, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Switch(key: const ValueKey('net-worth-switch'), value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
  }
}

/// 窄屏展开后的一行：左边名目和一句口径，右边数。
class _FigureRow extends StatelessWidget {
  const _FigureRow(this.figure);

  final _Figure figure;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      key: ValueKey('net-worth-figure-${figure.key}'),
      padding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  figure.label,
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 2),
                Text(figure.note, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: LedgerLayout.pagePadding),
          MoneyText(figure.cents),
        ],
      ),
    );
  }
}

/// 总览一次都没取到（离线、服务器出错）：和折叠态差不多高的一行，留着「净资产」标签、
/// 说清是什么没取到，行内一个重试；不用通用的大块报错，免得像整页都坏了。
class _StripError extends StatelessWidget {
  const _StripError({required this.reason, required this.onRetry});

  final String reason;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      key: const ValueKey('net-worth-error'),
      padding: const EdgeInsets.fromLTRB(
        LedgerLayout.pagePadding,
        LedgerLayout.itemGap,
        8,
        LedgerLayout.itemGap,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('净资产', style: theme.textTheme.bodySmall),
                const SizedBox(height: 2),
                Text('暂时算不出来：$reason', style: theme.textTheme.bodyMedium),
                // 总览取不到时明细展不开，账户入口也得在这里（「我的」里已经没有了）。
                const _ManageAccounts(),
              ],
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

class _StripSkeleton extends StatelessWidget {
  const _StripSkeleton();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(LedgerLayout.pagePadding),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Skeleton(width: 48, height: 12),
        SizedBox(height: 8),
        Skeleton(width: 160, height: 24),
        SizedBox(height: 8),
        Skeleton(width: 220, height: 12),
      ],
    ),
  );
}

/// 账户（银行卡、现金、支付宝……）的入口从「我的」挪到了净资产这里：余额本来就是净资产的第一项。
/// 展开的明细里有一个；总览取不到、明细展不开时，出错那一行里也有一个。
class _ManageAccounts extends StatelessWidget {
  const _ManageAccounts();

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton.icon(
      key: const ValueKey('net-worth-accounts'),
      onPressed: () => context.push('/settings/accounts'),
      icon: const Icon(Icons.account_balance_wallet_outlined, size: 18),
      label: const Text('管理账户'),
    ),
  );
}
