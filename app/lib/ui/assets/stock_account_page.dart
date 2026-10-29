import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../core/ids.dart';
import '../../core/money.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../add_tx/account_picker.dart';
import '../add_tx/picker_field.dart';
import '../settings/account_form.dart';
import '../transactions/tx_providers.dart';
import '../transactions/tx_tile.dart';
import '../widgets/widgets.dart';
import 'asset_providers.dart';
import 'asset_widgets.dart';

/// 某个账户最近的流水（股票账户详情的「最近流水」）：同步到新数据就重取。
final accountTransactionsProvider = FutureProvider.autoDispose.family<List<Transaction>, String>((ref, accountId) async {
  ref.watch(ledgerProvider.select((l) => l.valueOrNull?.seq));
  final page = await ref.watch(transactionsRepoProvider).list(TxFilter(accountId: accountId, limit: 20));
  return page.items;
});

/// 股票账户详情：市值（照券商 App 填）、投入（转进去的本金）、浮盈；只有三个动作 —— 更新市值、转入、转出；
/// 下面是历次市值和最近流水。股票不逐只记，整户就这一个数。
class StockAccountPage extends ConsumerStatefulWidget {
  const StockAccountPage(this.id, {super.key});

  final String id;

  @override
  ConsumerState<StockAccountPage> createState() => _StockAccountPageState();
}

class _StockAccountPageState extends ConsumerState<StockAccountPage> {
  /// 去账单页只看这个账户（账单是底部 tab，要 go）。
  void _showTransactions(Account a) {
    ref.read(txFilterProvider.notifier).state = TxFilter(accountId: a.id, limit: TxListController.pageSize);
    context.go('/transactions');
  }

  @override
  Widget build(BuildContext context) {
    final ledger = ref.watch(ledgerProvider).valueOrNull;
    if (ledger == null) {
      return Scaffold(appBar: AppBar(title: const Text('股票账户')), body: const SkeletonList(rows: 5));
    }
    final a = ledger.account(widget.id);
    if (a == null) {
      return Scaffold(appBar: AppBar(title: const Text('股票账户')), body: const InlineError(message: '这个账户已经不在了。'));
    }
    final theme = Theme.of(context);
    final overview = ref.watch(statsProvider(Dates.currentMonth())).valueOrNull;
    final now = ref.watch(assetClockProvider)();
    final m = stockAccountMetrics(a, overview?.balanceOf(a.id), now);
    final gain = m.gainCents;

    return Scaffold(
      appBar: AppBar(
        title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            key: const ValueKey('stock-edit'),
            tooltip: '编辑账户',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => showAccountForm(context, account: a),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(statsProvider);
          ref.invalidate(accountTransactionsProvider);
          await ref.read(ledgerProvider.notifier).sync();
        },
        child: LayoutBuilder(
          builder: (context, box) => ListView(
            padding: readableInsets(box.maxWidth, maxWidth: 720).copyWith(bottom: 96),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  LedgerLayout.pagePadding,
                  LedgerLayout.pagePadding,
                  LedgerLayout.pagePadding,
                  LedgerLayout.groupGap,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(m.unvalued ? '投入（还没填市值）' : '市值', style: theme.textTheme.bodySmall),
                        if (m.stale) ...[const SizedBox(width: 8), const TagLabel('该更新了', tone: TagTone.warning)],
                      ],
                    ),
                    const SizedBox(height: 2),
                    MultiCurrencyAmount(m.marketCents, currency: a.currency, size: MoneySize.display),
                    const SizedBox(height: LedgerLayout.itemGap),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _Cell(label: '投入', child: MultiCurrencyAmount(m.investedCents, currency: a.currency)),
                        ),
                        Expanded(
                          child: _Cell(
                            label: '浮盈',
                            // 金额和收益率放不下一行（窄屏、右栏）就折到下一行，别溢出。
                            child: gain == null
                                ? Text('—', style: theme.textTheme.bodyLarge)
                                : Wrap(
                                    spacing: 4,
                                    crossAxisAlignment: WrapCrossAlignment.center,
                                    children: [
                                      MultiCurrencyAmount(gain, currency: a.currency, signed: true),
                                      if (m.gainRate != null) _Rate(m.gainRate!),
                                    ],
                                  ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      m.valuedOn == null ? '照券商 App 填一个市值，浮盈就有了；投入 = 转进去的本金' : '市值 ${_md(m.valuedOn!)} 更新 · 投入 = 转进去的本金',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonal(
                      key: const ValueKey('stock-set-value'),
                      onPressed: () => showStockValueSheet(context, a),
                      child: const Text('更新市值'),
                    ),
                    OutlinedButton(
                      key: const ValueKey('stock-transfer-in'),
                      onPressed: () => showStockTransferSheet(context, a, into: true),
                      child: const Text('转入'),
                    ),
                    OutlinedButton(
                      key: const ValueKey('stock-transfer-out'),
                      onPressed: () => showStockTransferSheet(context, a, into: false),
                      child: const Text('转出'),
                    ),
                    TextButton.icon(
                      key: const ValueKey('stock-transactions'),
                      onPressed: () => _showTransactions(a),
                      icon: const Icon(Icons.receipt_long_outlined, size: 18),
                      label: const Text('看流水'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: LedgerLayout.groupGap),
              const SectionHeader('历次市值'),
              _ValueLog(account: a),
              const SizedBox(height: LedgerLayout.groupGap),
              const SectionHeader('最近流水'),
              _Recent(account: a, ledger: ledger),
            ],
          ),
        ),
      ),
    );
  }
}

/// `9月20日`：详情页里不要「周日」这种尾巴，和理财行一致。
String _md(DateTime d) => '${d.month}月${d.day}日';

class _Cell extends StatelessWidget {
  const _Cell({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 2),
      child,
    ],
  );
}

/// 收益率：正数用收入色带 +，负数只带 −（同金额，不靠红绿）。
class _Rate extends StatelessWidget {
  const _Rate(this.rate);

  final double rate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = formatRate(rate);
    return Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        color: rate > 0 && text != '0.00%' ? LedgerColors.of(context).income : theme.colorScheme.onSurfaceVariant,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// 历次市值，新的在前；每行带和上一次的差。
class _ValueLog extends StatelessWidget {
  const _ValueLog({required this.account});

  final Account account;

  static String _dayText(String on) {
    final day = localDate(on);
    return day == null ? on : _md(day);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final log = account.valueLog;
    if (log.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
        child: Text('还没填过市值', style: theme.textTheme.bodySmall),
      );
    }
    return Column(
      children: [
        for (var i = log.length - 1; i >= 0; i--)
          ListTile(
            key: ValueKey('stock-value-${log[i].on}'),
            contentPadding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
            leading: const AssetAvatar(Icons.show_chart),
            title: MultiCurrencyAmount(log[i].valueCents, currency: account.currency),
            subtitle: Text(_dayText(log[i].on), style: theme.textTheme.bodySmall),
            trailing: i == 0
                ? null
                : MultiCurrencyAmount(
                    log[i].valueCents - log[i - 1].valueCents,
                    currency: account.currency,
                    signed: true,
                    size: MoneySize.small,
                  ),
          ),
      ],
    );
  }
}

/// 最近的转入转出。
class _Recent extends ConsumerWidget {
  const _Recent({required this.account, required this.ledger});

  final Account account;
  final LedgerData ledger;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final txs = ref.watch(accountTransactionsProvider(account.id));
    final items = txs.valueOrNull;
    if (items == null) return const SkeletonList(rows: 2);
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
        child: Text('还没有转入转出', style: theme.textTheme.bodySmall),
      );
    }
    return Column(
      children: [
        for (final tx in items)
          TxTile(tx: tx, ledger: ledger, onTap: () => context.push('/transactions/${tx.id}')),
      ],
    );
  }
}

/// 更新市值：现在值多少、哪天的数 → `PATCH /accounts/:id {valueCents, valueOn}`。成功返回 true。
Future<bool?> showStockValueSheet(BuildContext context, Account account) => showModalBottomSheet<bool>(
  useRootNavigator: true,
  context: context,
  isScrollControlled: true,
  builder: (context) => _ValueSheet(account: account),
);

class _ValueSheet extends ConsumerStatefulWidget {
  const _ValueSheet({required this.account});

  final Account account;

  @override
  ConsumerState<_ValueSheet> createState() => _ValueSheetState();
}

class _ValueSheetState extends ConsumerState<_ValueSheet> {
  late final TextEditingController _amount = TextEditingController(
    text: widget.account.valueCents == null ? '' : Money.input(widget.account.valueCents!),
  );
  late DateTime _day = _today();
  bool _busy = false;
  String? _error;

  DateTime _today() {
    final now = ref.read(assetClockProvider)();
    return DateTime(now.year, now.month, now.day);
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final cents = parseMoneyField(_amount.text);
    if (cents == null || cents < 0) {
      setState(() => _error = '填一下现在的总市值，例如 52000');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(ledgerRepoProvider).updateAccount(widget.account.id, {
        'valueCents': cents,
        'valueOn': Dates.isoDate(_day),
      });
      refreshNetWorth(ref);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('市值更新为 ${Money.format(cents, currency: widget.account.currency)}')),
      );
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = describeError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: LedgerLayout.pagePadding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader('更新市值 · ${widget.account.name}'),
            PickerField(
              label: '现在值多少',
              topGap: 0,
              trailing: Text('照券商 App 上的总市值', style: Theme.of(context).textTheme.bodySmall),
              child: TextField(
                key: const ValueKey('stock-value-amount'),
                controller: _amount,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(prefixText: '${Money.symbolFor(widget.account.currency).trim()} ', hintText: '52000'),
              ),
            ),
            PickerField(
              label: '哪天的数',
              child: DayButton(
                key: const ValueKey('stock-value-day'),
                day: _day,
                onPressed: () async {
                  final picked = await pickPastDay(context, initial: _day, help: '市值是哪天的');
                  if (picked != null) setState(() => _day = picked);
                },
              ),
            ),
            FormSubmit(key: const ValueKey('stock-value-submit'), label: '更新', busy: _busy, error: _error, onPressed: _submit),
          ],
        ),
      ),
    ),
  );
}

/// 转入（[into] 为真：别的账户 → 这个股票账户）/ 转出：记一笔普通转账。成功返回 true。
Future<bool?> showStockTransferSheet(BuildContext context, Account account, {required bool into}) =>
    showModalBottomSheet<bool>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      builder: (context) => _TransferSheet(account: account, into: into),
    );

class _TransferSheet extends ConsumerStatefulWidget {
  const _TransferSheet({required this.account, required this.into});

  final Account account;
  final bool into;

  @override
  ConsumerState<_TransferSheet> createState() => _TransferSheetState();
}

class _TransferSheetState extends ConsumerState<_TransferSheet> {
  final TextEditingController _amount = TextEditingController();
  final TextEditingController _note = TextEditingController();
  late DateTime _day = _today();
  String? _counterId;
  bool _busy = false;
  String? _error;

  /// 幂等键：弹层开着期间的每次重试都沿用它，回应丢了再点也只记一笔。
  final String _clientId = newClientId();

  DateTime _today() {
    final now = ref.read(assetClockProvider)();
    return DateTime(now.year, now.month, now.day);
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit(List<Account> accounts) async {
    final cents = parseMoneyField(_amount.text);
    if (cents == null || cents <= 0) {
      setState(() => _error = '多少钱？例如 10000');
      return;
    }
    final counter = _counterId;
    if (counter == null) {
      setState(() => _error = widget.into ? '钱从哪个账户转进来？' : '转到哪个账户？');
      return;
    }
    final a = widget.account;
    final counterName = accounts.where((x) => x.id == counter).firstOrNull?.name ?? '账户';
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(transactionsRepoProvider).create(
        TransactionDraft(
          clientId: _clientId,
          type: Transaction.typeTransfer,
          amountCents: cents,
          occurredAt: DateTime(_day.year, _day.month, _day.day, 12),
          currency: a.currency,
          accountId: widget.into ? counter : a.id,
          toAccountId: widget.into ? a.id : counter,
          merchant: widget.into ? '转入 ${a.name}' : '转出到 $counterName',
          note: _note.text.trim().isEmpty ? null : _note.text.trim(),
        ),
      );
      refreshMoneyViews(ref);
      refreshNetWorth(ref);
      // 详情页的「最近流水」盯的是同步序号，记一笔不走同步，得自己刷。
      ref.invalidate(accountTransactionsProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已记一笔转账：${widget.into ? '转入' : '转出'} ${Money.format(cents, currency: a.currency)}')),
      );
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = describeWriteError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.account;
    final theme = Theme.of(context);
    final accounts = [
      for (final x in ref.watch(ledgerProvider).valueOrNull?.activeAccounts ?? const <Account>[])
        if (x.id != a.id && x.currency.toUpperCase() == a.currency.toUpperCase()) x,
    ];
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: LedgerLayout.pagePadding),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionHeader('${widget.into ? '转入' : '转出'} · ${a.name}'),
              PickerField(
                label: '多少',
                topGap: 0,
                trailing: Text('记成转账，不算支出', style: theme.textTheme.bodySmall),
                child: TextField(
                  key: const ValueKey('stock-transfer-amount'),
                  controller: _amount,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(prefixText: '${Money.symbolFor(a.currency).trim()} ', hintText: '10000'),
                ),
              ),
              PickerField(
                label: '哪天',
                child: DayButton(
                  key: const ValueKey('stock-transfer-day'),
                  day: _day,
                  onPressed: () async {
                    final picked = await pickPastDay(context, initial: _day, help: '哪天转的');
                    if (picked != null) setState(() => _day = picked);
                  },
                ),
              ),
              PickerField(
                label: widget.into ? '钱从哪个账户转进来' : '转到哪个账户',
                child: AccountPicker(
                  keyPrefix: 'stock-transfer-account',
                  accounts: accounts,
                  selectedId: _counterId,
                  emptyHint: '还没有同币种的账户',
                  onSelected: (id) => setState(() => _counterId = id),
                ),
              ),
              PickerField(
                label: '备注（选填）',
                child: TextField(
                  key: const ValueKey('stock-transfer-note'),
                  controller: _note,
                  decoration: const InputDecoration(hintText: '例如「追加投入」「卖股提现」'),
                ),
              ),
              FormSubmit(
                key: const ValueKey('stock-transfer-submit'),
                label: widget.into ? '转入' : '转出',
                busy: _busy,
                error: _error,
                onPressed: () => _submit(accounts),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
