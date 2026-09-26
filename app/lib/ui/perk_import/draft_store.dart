import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/local/local_store.dart';
import '../../data/models/models.dart';
import '../assets/asset_providers.dart' show assetClockProvider;
import 'perk_import_draft.dart';

/// 预览草稿的本机副本（spec §6「草稿同时存一份到本机，意外关闭后可以恢复；apply 成功后清掉」）。
/// 键 [kPerkImportDraftKey]：网页上 PrefsLocalStore 带 `fl.` 前缀，存成 `fl.perkImportDraft`；手机上是缓存目录里的一个文件。
/// 上限 [kPerkImportDraftMaxBytes]：放不下先丢原文（依据高亮没了，改动都在），还放不下就不存（并删掉旧的，免得恢复出过时的那份）。
/// 读写都包 try/catch：隐私模式、存储满了、盘坏了都只是「这次没存上 / 没得恢复」，不影响导入本身。
/// 存和清排成一条队（[_queue]）：手机上一次写要先写临时文件再改名，正在写的那次不能在「导完清掉」之后才落盘，
/// 把用完的草稿又写回来（下次进输入页就会冒出一份已经导过的「继续核对」）。
const String kPerkImportDraftKey = 'perkImportDraft';
const int kPerkImportDraftMaxBytes = 200 * 1024;

/// 读回来的一份：草稿、存的时候、勾着的项数（恢复横幅上写）。
class SavedPerkImport {
  const SavedPerkImport({required this.draft, this.savedAt});

  final PerkImportDraft draft;
  final DateTime? savedAt;
}

class PerkImportDraftStore {
  PerkImportDraftStore(this._store, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final LocalStore _store;
  final DateTime Function() _clock;

  /// 存和清按先后一个个来（前一个没做完，后一个等着）。
  Future<void> _queue = Future<void>.value();

  Future<T> _serial<T>(Future<T> Function() op) {
    final next = _queue.then((_) => op());
    _queue = next.then((_) {}, onError: (_) {});
    return next;
  }

  /// 存一份（覆盖上一份）。存上了回 true；太大、写不进去回 false。草稿的样子在调用时就定下来（后面再改的等下一次存）。
  Future<bool> save(PerkImportDraft draft) {
    Map<String, dynamic>? json;
    try {
      json = draft.toJson();
      if (_size(json) > kPerkImportDraftMaxBytes) json = draft.toJson(withSource: false);
      if (_size(json) > kPerkImportDraftMaxBytes) json = null;
    } catch (_) {
      return Future.value(false);
    }
    final snapshot = json;
    final at = _clock().toIso8601String();
    return _serial(() async {
      try {
        if (snapshot == null) {
          await _store.remove(kPerkImportDraftKey);
          return false;
        }
        await _store.write(kPerkImportDraftKey, {...snapshot, 'savedAt': at});
        return true;
      } catch (_) {
        return false;
      }
    });
  }

  /// 读上一份；没有、坏了、版本不认识都回 null（也排队：读到的是前面的存和清都做完之后的样子）。
  Future<SavedPerkImport?> load() => _serial(() async {
    try {
      final raw = await _store.read<Map<String, dynamic>>(kPerkImportDraftKey);
      if (raw == null || raw['version'] != 1) return null;
      final draft = PerkImportDraft.restore(raw);
      if (draft.importId.isEmpty) return null;
      return SavedPerkImport(draft: draft, savedAt: jsonDateOrNull(raw['savedAt']));
    } catch (_) {
      return null;
    }
  });

  /// 清掉本机那份：排在已经开始的存之后，那次写完再删。
  Future<void> clear() => _serial(() async {
    try {
      await _store.remove(kPerkImportDraftKey);
    } catch (_) {
      // 删不掉就算了：下次恢复时服务端会说这批已经导过（import_used）。
    }
  });

  static int _size(Map<String, dynamic> json) => utf8.encode(jsonEncode(json)).length;
}

final perkImportDraftStoreProvider = Provider<PerkImportDraftStore>(
  (ref) => PerkImportDraftStore(ref.watch(localStoreProvider), clock: ref.watch(assetClockProvider)),
);
