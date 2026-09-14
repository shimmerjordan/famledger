import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/colors.dart';
import '../../core/dates.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../widgets/widgets.dart';
import 'account_form.dart';
import 'manage_widgets.dart';

/// 账户管理：钱「在哪」。按类型分组，右侧是当前余额。
class AccountsPage extends ConsumerStatefulWidget {
  const AccountsPage({super.key});

  @override
  ConsumerState<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends ConsumerState<AccountsPage> {
  bool _reordering = false;
  String? _error;

  /// 拖动后先按用户拖的顺序显示（乐观更新），写成功了就清掉、以服务端为准；
  /// 写失败就摆回上一个顺序。null = 直接用 ledger 里的顺序。
  List<String>? _order;

  /// 应用本地顺序：ledger 里新出现的账户排在后面，消失的自动掉队。
  List<Account> _orderedActive(LedgerData data) {
    final active = data.activeAccounts;
    final order = _order;
    if (order == null) return active;
    final byId = {for (final a in active) a.id: a};
    final out = <Account>[];
    for (final id in order) {
      final account = byId.remove(id);
      if (account != null) out.add(account);
    }
    return out..addAll(byId.values);
  }

  void _onReorder(LedgerData data, int from, int to) {
    final next = [..._orderedActive(data)];
    final item = next.removeAt(from);
    next.insert(from < to ? to - 1 : to, item);
    final previous = _order;
    setState(() {
      _order = [for (final a in next) a.id];
      _error = null;
    });
    _saveOrder(data, next, previous);
  }

  Future<void> _saveOrder(
    LedgerData data,
    List<Account> ordered,
    List<String>? previous,
  ) async {
    // 服务端是按提交的 ids 下标写 sort_order 的，只发一部分就会和没动过的行
    // 撞号（记账页的账户顺序会跟着乱）—— 所以发全量，归档的接在后面。
    final ids = [
      for (final account in ordered) account.id,
      for (final account in data.accounts)
        if (account.archived) account.id,
    ];
    try {
      await ref.read(ledgerRepoProvider).reorder('accounts', ids);
      if (mounted) setState(() => _order = null);
    } catch (e) {
      // 这里要兜住一切：repo.reorder 里还跟着一次 sync()，离线时它自己也会抛。
      if (!mounted) return;
      setState(() {
        _order = previous;
        _error = '顺序没存上：${describeError(e)}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ledger = ref.watch(ledgerProvider);
    final stats = ref.watch(statsProvider(Dates.currentMonth()));

    return Scaffold(
      appBar: AppBar(
        title: const Text('账户'),
        actions: [
          if ((ledger.valueOrNull?.activeAccounts.length ?? 0) > 1)
            TextButton(
              onPressed: () => setState(() => _reordering = !_reordering),
              child: Text(_reordering ? '完成' : '排序'),
            ),
        ],
      ),
      floatingActionButton: _reordering
          ? null
          : FloatingActionButton.extended(
              onPressed: () => showAccountForm(context),
              icon: const Icon(Icons.add),
              label: const Text('添加账户'),
            ),
      body: AsyncValueView<LedgerData>(
        value: ledger,
        onRetry: () => ref.read(ledgerProvider.notifier).sync(),
        data: (data) {
          if (data.accounts.isEmpty) {
            return EmptyState(
              title: '还没有账户',
              message: '先把常用的那张卡、支付宝和微信加进来，记账时才好选。',
              icon: Icons.account_balance_wallet_outlined,
              actionLabel: '添加账户',
              onAction: () => showAccountForm(context),
            );
          }
          final error = _error;
          if (_reordering) {
            return Column(
              children: [
                if (error != null) InlineError(message: error),
                Expanded(child: _reorderList(data)),
              ],
            );
          }
          return _groupedList(data, stats.valueOrNull, error);
        },
      ),
    );
  }

  Widget _reorderList(LedgerData data) {
    final ordered = _orderedActive(data);
    return ReorderableListView.builder(
      padding: const EdgeInsets.only(bottom: 32),
      buildDefaultDragHandles: false,
      itemCount: ordered.length,
      onReorder: (from, to) => _onReorder(data, from, to),
      itemBuilder: (context, index) {
        final account = ordered[index];
        return ListTile(
          key: ValueKey(account.id),
          leading: _accountIcon(context, account, index),
          title: Text(account.name),
          subtitle: Text(account.kindLabel),
          trailing: ReorderableDragStartListener(
            index: index,
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Icon(Icons.drag_handle),
            ),
          ),
        );
      },
    );
  }

  Widget _groupedList(LedgerData data, StatsOverview? stats, String? error) {
    final archived = data.accounts.where((a) => a.archived).toList();
    final ordered = _orderedActive(data);
    final indexOf = {
      for (var i = 0; i < data.accounts.length; i++) data.accounts[i].id: i,
    };

    return ListView(
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        if (error != null) InlineError(message: error),
        for (final kind in Account.kinds)
          ..._kindGroup(
            data: data,
            ordered: ordered,
            stats: stats,
            indexOf: indexOf,
            kind: kind,
          ),
        if (archived.isNotEmpty) ...[
          const SizedBox(height: LedgerLayout.groupGap),
          const SectionHeader('已归档'),
          for (final account in archived)
            _AccountTile(
              account: account,
              owner: data.member(account.ownerMemberId)?.label,
              balanceCents: stats?.accountBalance(account.id),
              index: indexOf[account.id] ?? 0,
              onTap: () => showAccountForm(context, account: account),
            ),
        ],
      ],
    );
  }

  List<Widget> _kindGroup({
    required LedgerData data,
    required List<Account> ordered,
    required StatsOverview? stats,
    required Map<String, int> indexOf,
    required String kind,
  }) {
    final accounts = ordered.where((a) => a.kind == kind).toList();
    if (accounts.isEmpty) return const [];
    final total = stats == null
        ? null
        : accounts.fold<int>(0, (sum, a) => sum + stats.accountBalance(a.id));
    return [
      const SizedBox(height: LedgerLayout.itemGap),
      SectionHeader(
        Account.kindLabels[kind] ?? kind,
        trailing: total == null
            ? null
            : MoneyText(total, size: MoneySize.small, muted: true),
      ),
      for (final account in accounts)
        _AccountTile(
          account: account,
          owner: data.member(account.ownerMemberId)?.label,
          balanceCents: stats?.accountBalance(account.id),
          index: indexOf[account.id] ?? 0,
          onTap: () => showAccountForm(context, account: account),
        ),
    ];
  }
}

Widget _accountIcon(BuildContext context, Account account, int index) {
  final color =
      hexColor(account.color) ?? LedgerColors.of(context).fundColor(index);
  return CategoryIcon(
    account.icon ?? _kindIcons[account.kind],
    background: true,
    color: color,
  );
}

/// 没自定义图标时按类型给个像样的默认值。
const Map<String, String> _kindIcons = {
  'cash': 'wallet',
  'bank': 'account_balance',
  'alipay': 'currency_yen',
  'wechat': 'payments',
  'credit': 'credit_card',
  'invest': 'trending_up',
  'other': 'more_horiz',
};

class _AccountTile extends StatelessWidget {
  const _AccountTile({
    required this.account,
    required this.owner,
    required this.balanceCents,
    required this.index,
    required this.onTap,
  });

  final Account account;
  final String? owner;

  /// null = 统计还没回来，画骨架。
  final int? balanceCents;
  final int index;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hints = [
      if (owner != null) owner!,
      ..._hintLabels(account),
    ].join(' · ');

    return ListTile(
      leading: _accountIcon(context, account, index),
      title: Row(
        children: [
          Flexible(child: Text(account.name, overflow: TextOverflow.ellipsis)),
          if (account.archived) ...[
            const SizedBox(width: 8),
            const ManageTag('已归档'),
          ],
        ],
      ),
      subtitle: Text(
        hints.isEmpty ? '家庭共用' : hints,
        style: theme.textTheme.bodySmall,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: balanceCents == null
          ? const Skeleton(width: 64, height: 16)
          : MoneyText(balanceCents!),
      onTap: onTap,
    );
  }
}

List<String> _hintLabels(Account account) {
  final labels = <String>[];
  final tails = account.matchHints['cardTails'];
  if (tails is List && tails.isNotEmpty) {
    labels.add('尾号 ${tails.map((e) => '$e').join('/')}');
  }
  final keywords = account.matchHints['keywords'];
  if (keywords is List && keywords.isNotEmpty) {
    labels.add('${keywords.first}');
  }
  return labels;
}
