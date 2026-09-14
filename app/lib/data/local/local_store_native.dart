import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'local_store.dart';

/// 移动/桌面端：JSON 文件缓存；目录拿不到就退回 shared_preferences。
Future<LocalStore> openDefaultStore() async {
  try {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/cache');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return FileLocalStore(dir);
  } catch (_) {
    return PrefsLocalStore(await SharedPreferences.getInstance());
  }
}

/// 一个 key 一个文件，写入用临时文件 rename，避免写一半断电留下坏 JSON。
class FileLocalStore implements LocalStore {
  FileLocalStore(this.dir);

  final Directory dir;

  File _file(String key) => File('${dir.path}/${key.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_')}.json');

  @override
  Future<T?> read<T>(String key) async {
    final file = _file(key);
    if (!file.existsSync()) return null;
    try {
      final value = jsonDecode(await file.readAsString());
      return value is T ? value : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String key, Object json) async {
    final file = _file(key);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(json), flush: true);
    await tmp.rename(file.path);
  }

  @override
  Future<void> remove(String key) async {
    final file = _file(key);
    if (file.existsSync()) await file.delete();
  }

  @override
  Future<void> clear() async {
    if (!dir.existsSync()) return;
    for (final f in dir.listSync().whereType<File>()) {
      await f.delete();
    }
  }
}
