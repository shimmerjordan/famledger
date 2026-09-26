import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/models/models.dart';
import '../../data/repos/asset_import_repo.dart';
import 'perk_import_draft.dart';

final assetImportRepoProvider = Provider<AssetImportRepo>(
  (ref) => AssetImportRepo(api: ref.watch(apiProvider), ledger: ref.watch(ledgerRepoProvider)),
);

/// 识别完的草稿从输入页交给预览页（spec §6：autoDispose 的 StateProvider，不走路由 extra —— 网页上 extra 会被塞进
/// 浏览器历史，对象序列化不了）。离开导入这几页就丢掉。
final pendingPerkImportProvider = StateProvider.autoDispose<PerkImportDraft?>((ref) => null);

/// 导入页的地址：识别范围预选 [want]；[membershipId] = 会员详情的「AI 补充权益」（识别出的权益都归到这张卡）。
String perkImportLocation({ImportWant want = ImportWant.auto, String? membershipId}) {
  final q = <String, String>{
    if (want != ImportWant.auto) 'want': want.wire,
    'membership': ?membershipId,
  };
  return Uri(path: '/assets/import', queryParameters: q.isEmpty ? null : q).toString();
}
