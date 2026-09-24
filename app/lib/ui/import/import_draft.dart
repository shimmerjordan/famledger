import 'package:flutter/foundation.dart';

import '../../data/repos/import_repo.dart';

/// 预览页上的可改状态：勾了哪些、每行改成了什么类别/基金。
class ImportDraft extends ChangeNotifier {
  ImportDraft(this.preview)
    : _included = [
        for (final r in preview.rows)
          r.importable && !r.exists && !r.isDuplicate,
      ],
      _categoryIds = [for (final r in preview.rows) r.categoryId],
      _fundIds = [for (final r in preview.rows) r.fundId];

  final ImportPreview preview;
  final List<bool> _included;
  final List<String?> _categoryIds;
  final List<String?> _fundIds;

  List<ImportRow> get rows => preview.rows;

  bool selectable(int i) => rows[i].importable;
  bool included(int i) => _included[i];
  String? categoryId(int i) => _categoryIds[i];
  String? fundId(int i) => _fundIds[i];
  bool categoryChanged(int i) => _categoryIds[i] != rows[i].categoryId;
  bool fundChanged(int i) => _fundIds[i] != rows[i].fundId;

  void setIncluded(Iterable<int> indices, bool value) {
    var changed = false;
    for (final i in indices) {
      if (!selectable(i) || _included[i] == value) continue;
      _included[i] = value;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  void toggle(int i) => setIncluded([i], !_included[i]);

  /// 类别分收支，只改同方向的行：批量入库不查方向，挂错了支出会记进收入类别。
  /// 返回实际改了几行。
  int setCategory(Iterable<int> indices, String? id, {required String kind}) {
    var n = 0;
    for (final i in indices) {
      if (!selectable(i)) continue;
      if (id != null && rows[i].type != kind) continue;
      _categoryIds[i] = id;
      n++;
    }
    if (n > 0) notifyListeners();
    return n;
  }

  int setFund(Iterable<int> indices, String? id) {
    var n = 0;
    for (final i in indices) {
      if (!selectable(i)) continue;
      _fundIds[i] = id;
      n++;
    }
    if (n > 0) notifyListeners();
    return n;
  }

  Iterable<int> get includedIndices sync* {
    for (var i = 0; i < rows.length; i++) {
      if (_included[i]) yield i;
    }
  }

  int get includedCount => includedIndices.length;

  int _sum(String type) => includedIndices
      .where((i) => rows[i].type == type)
      .fold(0, (sum, i) => sum + (rows[i].amountCents ?? 0));

  int get expenseCents => _sum('expense');
  int get incomeCents => _sum('income');

  int count(bool Function(ImportRow row) test) => rows.where(test).length;

  List<ImportItem> items() => [
    for (final i in includedIndices)
      ImportItem(
        row: rows[i],
        categoryId: _categoryIds[i],
        fundId: _fundIds[i],
        categoryChanged: categoryChanged(i),
        fundChanged: fundChanged(i),
      ),
  ];
}
