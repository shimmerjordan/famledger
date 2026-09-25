import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/providers.dart';
import '../../data/repos/perks_repo.dart';

final perksRepoProvider = Provider<PerksRepo>(
  (ref) => PerksRepo(
    api: ref.watch(apiProvider),
    ledger: ref.watch(ledgerRepoProvider),
  ),
);

/// 「全部」视图怎么分组（spec §5）：按会员，或按领取平台（回答「什么会员要去哪个平台领」）。
enum PerkGrouping { byMembership, byClaimPlatform }

/// 切到物品再切回来还记得。
final perkGroupingProvider = StateProvider<PerkGrouping>((ref) => PerkGrouping.byMembership);

/// 宽屏（≥ 840）右栏正在看的那张卡；null = 默认看列表里第一张（PerksTab 画出来后会把它写回这里）。
final selectedMembershipProvider = StateProvider<String?>((ref) => null);

/// 打开权益的领取链接（外部浏览器 / 对应 App）；测试里换成假的。
final perkUrlOpenerProvider = Provider<Future<bool> Function(Uri)>(
  (ref) =>
      (uri) => launchUrl(uri, mode: LaunchMode.externalApplication),
);
