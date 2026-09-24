import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/providers.dart';
import '../../data/repos/import_repo.dart';
import '../transactions/tx_providers.dart';

class PickedImportFile {
  const PickedImportFile({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

typedef ImportFilePicker = Future<PickedImportFile?> Function();

const List<String> kImportExtensions = ['csv', 'xlsx'];

/// 网页上拿不到路径，只能要字节。
final importFilePickerProvider = Provider<ImportFilePicker>(
  (ref) => () async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: kImportExtensions,
      withData: true,
    );
    final file = result == null || result.files.isEmpty
        ? null
        : result.files.first;
    final bytes = file?.bytes;
    if (file == null || bytes == null) return null;
    return PickedImportFile(name: file.name, bytes: bytes);
  },
);

final importUrlOpenerProvider = Provider<Future<bool> Function(Uri)>(
  (ref) =>
      (uri) => launchUrl(uri, mode: LaunchMode.externalApplication),
);

/// 预览结果从选文件页交给预览页。不走路由的 extra：网页上 extra 会被塞进浏览器
/// 历史，对象序列化不了会直接报错。
///
/// autoDispose：离开导入这几页就丢掉，免得浏览器后退回核对页又把导过的那批摆出来。
final pendingImportPreviewProvider = StateProvider.autoDispose<ImportPreview?>(
  (ref) => null,
);

void refreshAfterImport(WidgetRef ref) {
  ref.invalidate(txListProvider);
  ref.invalidate(recentTxProvider);
  ref.invalidate(pendingTxProvider);
  ref.invalidate(statsProvider);
}
