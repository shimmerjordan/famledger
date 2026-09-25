import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../core/ids.dart';
import '../../core/money.dart';
import '../../data/api/api_client.dart';
import '../../data/models/models.dart';
import '../../data/repos/ledger_repo.dart';
import '../assets/asset_providers.dart';
import '../assets/asset_widgets.dart';
import '../widgets/widgets.dart';
import 'perk_providers.dart';

// 会员权益的几个动作（spec §5）：一键打卡（snackbar 撤销；年卡类权益打完卡顺手「在优酷建会员卡」）、
// 长按打卡（记多份、改日期、改价值、本期跳过）、「续了」「停了」、删一条打卡记录 —— 都能在 snackbar 里撤销。
// 本期视图、首页「会员权益」段、会员详情共用。

/// 「今天」：本地日历上的这一天（UTC 零点，perk_math 的口径）。
DateTime perkToday(WidgetRef ref) => localDay(ref.read(assetClockProvider)());

/// 要不要在打卡后给「在优酷建会员卡」（spec §5）：年卡类（kind=subscription）、去别的平台领、还没建过由它带出的卡。
/// 返回那个领取平台的 id；不给返回 null。
String? derivedPlatformFor(LedgerData data, Benefit benefit, {Benefit? parent}) {
  final m = data.membership(benefit.membershipId);
  if (m == null || benefit.kind != 'subscription') return null;
  final platformId = effectiveClaimPlatformId(benefit, m, parent);
  if (platformId == m.platformId) return null;
  if (data.memberships.any((x) => x.sourceBenefitId == benefit.id)) return null;
  return platformId;
}

/// 打一次卡：记 [count] 份 [kind]（claim / use / skip）在 [on] 那天（默认今天）。成功后 snackbar「领了：优酷年卡」带「撤销」；
/// 年卡类权益再附一个「在优酷建会员卡」（预填平台、来源权益、本期实付 0）。失败说一句，不确定送到没有时记下 clientId，
/// 再点沿用它（服务端认得出，不会记两条）。请求还在路上时同一项（N 选 1 是整组）再点直接忽略，按钮上转圈。
Future<BenefitEvent?> checkInPerk(
  BuildContext context,
  WidgetRef ref, {
  required LedgerData data,
  required Benefit benefit,
  Benefit? parent,
  required String kind,
  int count = 1,
  DateTime? on,
  int? valueCents,
}) async {
  // 先拿到这几样：打完卡列表一刷新，这一行可能就挪走（卸载）了，提示照样要出来。
  final messenger = ScaffoldMessenger.of(context);
  final router = GoRouter.maybeOf(context);
  final repo = ref.read(perksRepoProvider);
  final retry = ref.read(perkRetryIdsProvider);
  final busy = ref.read(perkBusyProvider.notifier);
  final now = ref.read(assetClockProvider)();
  final busyKey = perkEventBusyKey(benefit, parent: parent);
  if (!busy.start(busyKey)) return null;
  final day = Dates.isoDate(on ?? localDay(now));
  // 键带上这次记的全部内容：回应丢了之后改记别的（长按记 ×2、换了日子）是另一次打卡，不能被当成重发吞掉。
  final retryKey = '${benefit.id}/$kind/$count/$day/${valueCents ?? ''}';
  final clientId = retry.of(retryKey, now) ?? newClientId();
  final body = <String, dynamic>{
    'clientId': clientId,
    'benefitId': benefit.id,
    'kind': kind,
    'count': count,
    'occurredOn': day,
  };
  putIfNotNull(body, 'valueCents', valueCents);
  final BenefitEvent event;
  try {
    event = await repo.createBenefitEvent(body);
  } catch (error) {
    if (error is ApiException && error.maybeSent) {
      retry.remember(retryKey, clientId, now);
    } else {
      retry.forget(retryKey);
    }
    _showError(messenger, describeWriteError(error));
    return null;
  } finally {
    busy.done(busyKey);
  }
  retry.forget(retryKey);

  final platformId = kind == 'skip' ? null : derivedPlatformFor(data, benefit, parent: parent);
  final what = kind == 'skip' ? '本期跳过：${benefit.name}' : '${perkActionLabel(kind)}：${benefit.name}${count > 1 ? ' ×$count' : ''}';
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: platformId == null || router == null
          ? Text(what)
          : Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                Text(what),
                TextButton(
                  key: const ValueKey('snack-derived-card'),
                  onPressed: () {
                    messenger.hideCurrentSnackBar();
                    router.push('/assets/memberships/new?platformId=$platformId&sourceBenefitId=${benefit.id}&termPaid=0');
                  },
                  child: Text('在${platformLabel(data.platform(platformId))}建会员卡'),
                ),
              ],
            ),
      action: SnackBarAction(
        label: '撤销',
        onPressed: () async {
          try {
            await repo.deleteBenefitEvent(event.id);
            messenger.showSnackBar(const SnackBar(content: Text('已撤销')));
          } catch (error) {
            _showError(messenger, '没撤销成功：${describeError(error)}');
          }
        },
      ),
    ),
  );
  return event;
}

/// 失败的那句先把上一条（多半是刚才那次成功的「撤销」提示，要挂好几秒）收掉再出：不然排在后面，
/// 用户以为这一下没反应，又点一次。
void _showError(ScaffoldMessengerState messenger, String message) {
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(SnackBar(content: Text(message)));
}

/// 一键动作的请求还在路上：按钮里转个小圈（和待确认的「确认」一样）。
class PerkBusySpinner extends StatelessWidget {
  const PerkBusySpinner({super.key});

  @override
  Widget build(BuildContext context) =>
      const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, semanticsLabel: '正在记'));
}

/// 长按打卡弹层选好的样子。
class CheckInChoice {
  const CheckInChoice({required this.kind, required this.count, required this.day, this.valueCents});

  final String kind;
  final int count;
  final DateTime day;
  final int? valueCents;
}

/// 长按：记多份、改日期、改价值、本期跳过（spec §5）。[kind] 是大按钮会记的那种；claim_use 可以在弹层里改成领 / 用。
Future<void> showCheckInSheet(
  BuildContext context,
  WidgetRef ref, {
  required LedgerData data,
  required Benefit benefit,
  Benefit? parent,
  required String kind,
}) async {
  final choice = await showModalBottomSheet<CheckInChoice>(
    context: context,
    isScrollControlled: true,
    builder: (context) => CheckInSheet(
      benefit: benefit,
      parent: parent,
      kind: kind,
      today: ref.read(assetClockProvider)(),
    ),
  );
  if (choice == null || !context.mounted) return;
  await checkInPerk(
    context,
    ref,
    data: data,
    benefit: benefit,
    parent: parent,
    kind: choice.kind,
    count: choice.count,
    on: DateTime.utc(choice.day.year, choice.day.month, choice.day.day),
    valueCents: choice.valueCents,
  );
}

class CheckInSheet extends StatefulWidget {
  const CheckInSheet({super.key, required this.benefit, this.parent, required this.kind, required this.today});

  final Benefit benefit;
  final Benefit? parent;
  final String kind;

  /// 本地的「现在」：日期最晚到这天。
  final DateTime today;

  @override
  State<CheckInSheet> createState() => _CheckInSheetState();
}

class _CheckInSheetState extends State<CheckInSheet> {
  final TextEditingController _count = TextEditingController(text: '1');
  final TextEditingController _value = TextEditingController();
  late DateTime _day = DateTime(widget.today.year, widget.today.month, widget.today.day);
  late String _kind = widget.kind;
  String? _error;

  @override
  void dispose() {
    _count.dispose();
    _value.dispose();
    super.dispose();
  }

  Future<void> _pickDay() async {
    final picked = await pickPastDay(context, initial: _day, help: '哪天领 / 用的');
    if (picked != null) setState(() => _day = picked);
  }

  void _submit({bool skip = false}) {
    if (skip) {
      Navigator.of(context).pop(CheckInChoice(kind: 'skip', count: 1, day: _day));
      return;
    }
    final count = int.tryParse(_count.text.trim());
    if (count == null || count < 1 || count > 999) return setState(() => _error = '份数填 1 到 999');
    final value = parseMoneyField(_value.text);
    if (value == -1) return setState(() => _error = '这次的价值填得不对，例如 5');
    Navigator.of(context).pop(CheckInChoice(kind: _kind, count: count, day: _day, valueCents: value));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unit = perkUnitValue(widget.benefit, parent: widget.parent);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(LedgerLayout.pagePadding, LedgerLayout.pagePadding, LedgerLayout.pagePadding, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.benefit.name, style: theme.textTheme.titleMedium),
              const SizedBox(height: LedgerLayout.itemGap),
              if (widget.benefit.flow == Benefit.flowClaimUse) ...[
                SegmentedButton<String>(
                  key: const ValueKey('check-in-kind'),
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'claim', label: Text('领了')),
                    ButtonSegment(value: 'use', label: Text('用了')),
                  ],
                  selected: {_kind},
                  onSelectionChanged: (s) => setState(() => _kind = s.first),
                ),
                const SizedBox(height: LedgerLayout.itemGap),
              ],
              TextField(
                key: const ValueKey('check-in-count'),
                controller: _count,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '几份', suffixText: '份'),
              ),
              const SizedBox(height: LedgerLayout.itemGap),
              DayButton(day: _day, onPressed: _pickDay),
              const SizedBox(height: LedgerLayout.itemGap),
              TextField(
                key: const ValueKey('check-in-value'),
                controller: _value,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: '这次值多少（选填）',
                  prefixText: '¥ ',
                  hintText: unit.known ? Money.plain(unit.cents) : '不填按估值 / 面值',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: LedgerLayout.itemGap),
              FilledButton(
                key: const ValueKey('check-in-save'),
                onPressed: _submit,
                child: Text('记上：${perkActionLabel(_kind)}'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                key: const ValueKey('check-in-skip'),
                onPressed: () => _submit(skip: true),
                child: const Text('本期跳过'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「续了」：按 [renewPlan] 续一期（续一期还在今天之前的一期期往后推），snackbar「已续到 2026-10-15」带「撤销」
/// （撤销 = 把到期日、本期开始、本期实付、试用改回去）。回应丢了再点沿用同一个 clientId，不会续两期；请求还在路上时
/// 这张卡的「续了」「停了」再点都忽略。
///
/// 到期日总是算好了发过去（服务端只在「新到期日晚于它手上的到期日」时才续）：两台设备、两个家人各点一次「续了」，
/// 后到的那台本地还是旧的到期日，服务端回 400 `invalid_expiresOn`，这里说一句「已经续过了」再同步，不会续出两期。
/// 免年费（上一期实付 0）、派生卡（大会员带出来的）续下一期多半还是这样，本期实付照原样带上，不让服务端清空成按续费价算。
Future<void> renewNow(BuildContext context, WidgetRef ref, Membership m) async {
  final messenger = ScaffoldMessenger.of(context);
  final repo = ref.read(perksRepoProvider);
  final now = ref.read(assetClockProvider)();
  final plan = renewPlan(m, localDay(now));
  if (plan == null) {
    _showError(messenger, '一次性或不收费的卡没有下一期，不用续费');
    return;
  }
  final busy = ref.read(perkBusyProvider.notifier);
  final busyKey = perkCardBusyKey(m.id);
  if (!busy.start(busyKey)) return;
  final retry = ref.read(perkRetryIdsProvider);
  final retryKey = 'renew/${m.id}/${Dates.isoDate(plan)}';
  final clientId = retry.of(retryKey, now) ?? newClientId();
  final body = <String, dynamic>{'clientId': clientId, 'expiresOn': Dates.isoDate(plan)};
  if (!m.isTrial && (m.sourceBenefitId != null || m.termPaidCents == 0)) putIfNotNull(body, 'paidCents', m.termPaidCents);
  final before = <String, dynamic>{
    'expiresOn': m.expiresOn,
    'termStartOn': m.termStartOn,
    'termPaidCents': m.termPaidCents,
    'isTrial': m.isTrial,
  };
  final Membership next;
  try {
    next = await repo.renewMembership(m.id, body);
  } catch (error) {
    if (error is ApiException && error.maybeSent) {
      retry.remember(retryKey, clientId, now);
    } else {
      retry.forget(retryKey);
    }
    if (error is ApiException && error.code == 'invalid_expiresOn') {
      _showError(messenger, '「${m.title}」已经续过了（可能是别的设备或家人刚点的），这就刷新');
      await repo.refresh();
    } else {
      _showError(messenger, describeWriteError(error));
    }
    return;
  } finally {
    busy.done(busyKey);
  }
  retry.forget(retryKey);
  // 年付的续一期就跨年了：写全日期。
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(next.expiresOn == null ? '已续费：${m.title}' : '已续到 ${next.expiresOn}：${m.title}'),
      action: SnackBarAction(
        label: '撤销',
        onPressed: () async {
          try {
            await repo.updateMembership(m.id, before);
            messenger.showSnackBar(const SnackBar(content: Text('已撤销')));
          } catch (error) {
            _showError(messenger, '没撤销成功：${describeError(error)}');
          }
        },
      ),
    ),
  );
}

/// 「停了」：不再续费、不再持有 = 自动续费改成「不续费」并归档（不进本期、不提醒，回本历史留着）。能撤销。
/// 一次性、不收费的卡过期后这个按钮叫「归档」，做的是同一件事。
Future<void> stopMembership(BuildContext context, WidgetRef ref, Membership m) async {
  final messenger = ScaffoldMessenger.of(context);
  final repo = ref.read(perksRepoProvider);
  final busy = ref.read(perkBusyProvider.notifier);
  final busyKey = perkCardBusyKey(m.id);
  if (!busy.start(busyKey)) return;
  try {
    await repo.updateMembership(m.id, {'autoRenew': 'no', 'archived': true});
  } catch (error) {
    _showError(messenger, describeError(error));
    return;
  } finally {
    busy.done(busyKey);
  }
  final renewable = renewPeriodMonths.containsKey(m.feePeriod);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(renewable ? '已停：「${m.title}」收进已归档' : '已归档：「${m.title}」'),
      action: SnackBarAction(
        label: '撤销',
        onPressed: () async {
          try {
            await repo.updateMembership(m.id, {'autoRenew': m.autoRenew, 'archived': false});
            messenger.showSnackBar(const SnackBar(content: Text('已撤销')));
          } catch (error) {
            _showError(messenger, '没撤销成功：${describeError(error)}');
          }
        },
      ),
    ),
  );
}

/// 删一条打卡记录（会员详情的历史里）。撤销 = 照原样再记一条（新的 id）。
Future<void> deleteCheckIn(BuildContext context, WidgetRef ref, BenefitEvent e) async {
  final messenger = ScaffoldMessenger.of(context);
  final repo = ref.read(perksRepoProvider);
  try {
    await repo.deleteBenefitEvent(e.id);
  } catch (error) {
    _showError(messenger, describeError(error));
    return;
  }
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: const Text('已删掉这条打卡'),
      action: SnackBarAction(
        label: '撤销',
        onPressed: () async {
          final body = <String, dynamic>{
            'clientId': newClientId(),
            'benefitId': e.benefitId,
            'kind': e.kind,
            'count': e.count,
            'occurredOn': e.occurredOn,
          };
          putIfNotNull(body, 'valueCents', e.valueCents);
          putIfNotNull(body, 'memberId', e.memberId);
          putIfNotNull(body, 'note', e.note);
          try {
            await repo.createBenefitEvent(body);
            messenger.showSnackBar(const SnackBar(content: Text('已恢复')));
          } catch (error) {
            _showError(messenger, '没恢复成功：${describeError(error)}');
          }
        },
      ),
    ),
  );
}
