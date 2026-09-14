/// 领域模型总出口：`import 'package:famledger/data/models/models.dart';`
library;

import 'category.dart';

export 'account.dart';
export 'ai.dart';
export 'backup.dart';
export 'budget.dart';
export 'category.dart';
export 'fund.dart';
export 'json_utils.dart';
export 'member.dart';
export 'rule.dart';
export 'settings.dart';
export 'stats.dart';
export 'transaction.dart';

/// `package:flutter/material.dart` 也导出一个叫 `Category` 的注解类，
/// 在 widget 文件里同时 import 两者会产生歧义 —— UI 层请用这个别名。
typedef TxCategory = Category;
