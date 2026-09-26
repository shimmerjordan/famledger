import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../assets/asset_providers.dart';
import 'perk_actions.dart';
import 'perk_providers.dart';

/// 会员权益 tab「要处理」里的一条扣费线索（spec §5）：「腾讯视频：已看到 9/21 扣 ¥25.00 → 续到 10/20」，
/// 右边「续上」（只关联那笔流水、不另记账，能撤销）和 ✕「不是这笔」（记在本机，和「知道了」一样）。
/// 点行本身打开那张卡。请求还在路上时「续上」转圈、再点不做事（和「续了」占同一个键）。
///
/// 这一句不截断（扣了多少、续到哪天就是用户点「续上」之前要看的）：窄屏、大字号时两个按钮挪到第二行，
/// 把整行宽度留给文字；第一次出现时淡入（和它替掉的那条提醒之间不硬切）。
class ChargeHintTile extends ConsumerWidget {
  const ChargeHintTile({super.key, required this.hint, required this.data, this.onOpen});

  final ChargeHint hint;
  final LedgerData data;

  /// 打开一张卡；不给就推会员详情页。
  final void Function(String membershipId)? onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = data.membership(hint.membershipId);
    if (m == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final busy = ref.watch(perkBusyProvider).contains(perkCardBusyKey(m.id));
    final where = hint.merchant.isEmpty ? '' : '${hint.merchant} · ';
    final buttons = <Widget>[
      // 不真的置灰：置灰的按钮不接点击，这一下会漏到整行上去打开卡片（和「续了」一样）。
      TextButton(
        key: ValueKey('charge-renew-${m.id}'),
        onPressed: () => renewNow(context, ref, m, charge: hint),
        child: busy ? const PerkBusySpinner() : const Text('续上'),
      ),
      IconButton(
        key: ValueKey('charge-dismiss-${m.id}'),
        tooltip: '不是这笔',
        icon: const Icon(Icons.close, size: 20),
        onPressed: () => ref.read(perkDismissedProvider.notifier).dismiss(hint.key, ref.read(assetClockProvider)()),
      ),
    ];
    return PerkAppear(
      key: ValueKey('charge-hint-${m.id}'),
      child: LayoutBuilder(
        builder: (context, box) {
          // 按钮放右边时文字只剩「整行 − 图标 − 两个按钮」那么宽：字号放大到放不下十几个字就挪到第二行。
          final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
          final stacked = box.maxWidth < 360 * scale;
          return ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
            leading: const Icon(Icons.receipt_long_outlined),
            title: Text('${m.title}：${chargeHintLine(hint, perkToday(ref))}', key: ValueKey('charge-line-${m.id}')),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('$where续上只关联这笔流水，不另记账', style: theme.textTheme.bodySmall),
                if (stacked) OverflowBar(alignment: MainAxisAlignment.end, children: buttons),
              ],
            ),
            trailing: stacked ? null : Row(mainAxisSize: MainAxisSize.min, children: buttons),
            onTap: () => onOpen != null ? onOpen!(m.id) : context.push('/assets/memberships/${m.id}'),
          );
        },
      ),
    );
  }
}

/// 列表里新出现的一行：高度从 0 长开、同时淡入（DESIGN.md「列表项增删用 size+fade」）；系统关了动画就直接出现。
/// 只在第一次挂上时动一次，之后重建不再动。
class PerkAppear extends StatefulWidget {
  const PerkAppear({super.key, required this.child});

  final Widget child;

  @override
  State<PerkAppear> createState() => _PerkAppearState();
}

class _PerkAppearState extends State<PerkAppear> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 200));
  late final Animation<double> _curve = CurvedAnimation(parent: _controller, curve: Easing.emphasizedDecelerate);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller.isDismissed) {
      MediaQuery.disableAnimationsOf(context) ? _controller.value = 1 : _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizeTransition(
    sizeFactor: _curve,
    axisAlignment: -1,
    child: FadeTransition(opacity: _curve, child: widget.child),
  );
}
