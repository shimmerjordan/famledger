import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/models/json_utils.dart';

/// 上一次记这种类型的账时选了什么。按 `type` 分开记：
/// 发工资用的基金和买菜用的基金通常不是一个。
class AddTxChoice {
  const AddTxChoice({this.fundId, this.accountId, this.categoryId, this.memberId});

  final String? fundId;
  final String? accountId;
  final String? categoryId;
  final String? memberId;

  static const AddTxChoice empty = AddTxChoice();

  AddTxChoice merge({
    String? fundId,
    String? accountId,
    String? categoryId,
    String? memberId,
  }) => AddTxChoice(
    fundId: fundId ?? this.fundId,
    accountId: accountId ?? this.accountId,
    categoryId: categoryId ?? this.categoryId,
    memberId: memberId ?? this.memberId,
  );

  factory AddTxChoice.fromJson(Map<String, dynamic> json) => AddTxChoice(
    fundId: jsonStringOrNull(json['fundId']),
    accountId: jsonStringOrNull(json['accountId']),
    categoryId: jsonStringOrNull(json['categoryId']),
    memberId: jsonStringOrNull(json['memberId']),
  );

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
    putIfNotNull(json, 'fundId', fundId);
    putIfNotNull(json, 'accountId', accountId);
    putIfNotNull(json, 'categoryId', categoryId);
    putIfNotNull(json, 'memberId', memberId);
    return json;
  }
}

class AddTxMemory {
  const AddTxMemory(this.byType);

  final Map<String, AddTxChoice> byType;

  static const AddTxMemory empty = AddTxMemory({});

  AddTxChoice forType(String type) => byType[type] ?? AddTxChoice.empty;

  Map<String, dynamic> toJson() => {
    for (final entry in byType.entries) entry.key: entry.value.toJson(),
  };

  factory AddTxMemory.fromJson(Map<String, dynamic> json) => AddTxMemory({
    for (final entry in json.entries)
      if (entry.value is Map<String, dynamic>)
        entry.key: AddTxChoice.fromJson(entry.value as Map<String, dynamic>),
  });
}

/// 记一笔页的「上次选择」。异步读盘，读到之前先给空的，页面照样能开。
final addTxMemoryProvider =
    NotifierProvider<AddTxMemoryController, AddTxMemory>(
      AddTxMemoryController.new,
    );

class AddTxMemoryController extends Notifier<AddTxMemory> {
  static const String storeKey = 'ui.addTx.lastChoice';

  @override
  AddTxMemory build() {
    // 读盘是异步的，但页面不能等：先给空的，读到了再刷一次。
    unawaited(_load());
    return AddTxMemory.empty;
  }

  Future<void> _load() async {
    try {
      final raw = await ref
          .read(localStoreProvider)
          .read<Map<String, dynamic>>(storeKey);
      if (raw != null) state = AddTxMemory.fromJson(raw);
    } catch (_) {
      // 没有本地存储（测试里没 override）也不影响记账。
    }
  }

  Future<void> remember(
    String type, {
    String? fundId,
    String? accountId,
    String? categoryId,
    String? memberId,
  }) async {
    final next = {
      ...state.byType,
      type: state.forType(type).merge(
        fundId: fundId,
        accountId: accountId,
        categoryId: categoryId,
        memberId: memberId,
      ),
    };
    state = AddTxMemory(next);
    try {
      await ref.read(localStoreProvider).write(storeKey, state.toJson());
    } catch (_) {
      // 存不下就下次重新选，不值得打断用户。
    }
  }
}
