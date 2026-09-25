import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../core/money.dart';
import '../../data/api/api_client.dart';
import '../../data/models/models.dart';
import '../widgets/widgets.dart';
import 'asset_widgets.dart';

/// 折叠时那行小字：「账户 ¥… · 投资（账户外）¥… · 实物计入 ¥…」，总开关关着时末段写「不含实物」。
///
/// 几段加起来就是净资产。「投资（账户外）」是账户余额以外的那部分：挂了账户的持仓成本早就以
/// 转账进了账户余额，只补浮盈；没挂账户的整份市值（口径在 stats.js）。所以它不是持仓市值，
/// 明细里另外说。「实物计入」是计入额，不是物品页的估值合计。
///
/// 没有持仓影响时不写投资，没有在用的物品（或老服务端没给 physical）时不写实物。
String netWorthBreakdown(StatsOverview o) {
  final p = o.physical;
  final invest = o.investNetCents;
  return [
    '账户 ${Money.format(o.accountsNetCents)}',
    if (invest != 0) '投资（账户外）${Money.format(invest)}',
    if (p != null && p.count > 0)
      p.counted ? '实物计入 ${Money.format(p.includedCents)}' : '不含实物',
  ].join(' · ');
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
    final overview = stats.valueOrNull;
    final retry = stats.isLoading ? null : () => ref.invalidate(statsProvider(month));
    final Widget body;
    if (overview != null) {
      body = _content(
        context,
        overview,
        canEdit: canEdit,
        month: month,
        stale: stats.hasError ? _reason(stats.error!) : null,
        onRetry: retry,
      );
    } else if (stats.hasError) {
      body = _StripError(reason: _reason(stats.error!), onRetry: retry);
    } else {
      body = const _StripSkeleton();
    }
    return LayoutBuilder(
      builder: (context, box) => Padding(
        padding: readableInsets(box.maxWidth),
        child: body,
      ),
    );
  }

  Widget _content(
    BuildContext context,
    StatsOverview o, {
    required bool canEdit,
    required String month,
    required String? stale,
    required VoidCallback? onRetry,
  }) {
    final theme = Theme.of(context);
    final details = _expanded
        ? _details(context, o, canEdit: canEdit, month: month)
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
              LedgerLayout.itemGap,
              LedgerLayout.pagePadding,
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
                      MoneyText(o.netWorthCents, size: MoneySize.title),
                      const SizedBox(height: 2),
                      Text(
                        netWorthBreakdown(o),
                        key: const ValueKey('net-worth-breakdown'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
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

  Widget _details(
    BuildContext context,
    StatsOverview o, {
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
    // 市值 − 账户外那部分 = 挂了账户的持仓成本（已经在账户余额里）。
    final market = o.investMarketCents;
    final costInAccounts = market == null ? 0 : market - o.investNetCents;
    return Column(
      key: const ValueKey('net-worth-details'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InfoRow('账户', MoneyText(o.accountsNetCents)),
        InfoRow('投资（账户外）', MoneyText(o.investNetCents)),
        if (market != null && costInAccounts > 0)
          Padding(
            key: const ValueKey('net-worth-invest-note'),
            padding: hintPadding,
            child: Text(
              '持仓市值 ${Money.format(market)}；挂了账户的持仓成本 '
              '${Money.format(costInAccounts)} 已在账户余额里，这里不再算',
              style: theme.textTheme.bodySmall,
            ),
          ),
        if (p != null) ...[
          InfoRow('实物估值', MoneyText(p.valueCents)),
          InfoRow(p.counted ? '其中计入净资产' : '打开开关后计入', MoneyText(p.includedCents)),
          SwitchListTile(
            key: const ValueKey('net-worth-switch'),
            value: _pending ?? p.counted,
            onChanged: canEdit && !_saving ? (v) => _setCounted(month, v) : null,
            title: const Text('实物计入净资产'),
            subtitle: const Text('数码、出行、箱包/奢侈品、首饰按类别计入，其余不计；单件在物品里改'),
          ),
          if (!canEdit)
            Padding(
              padding: hintPadding,
              child: Text('只有管理员能改这个开关。', style: theme.textTheme.bodySmall),
            ),
          if (_error != null)
            Padding(
              padding: hintPadding,
              child: Text(
                _error!,
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
              ),
            ),
        ],
      ],
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
