import 'dart:io';

import 'package:famledger/capture/source_profiles.dart';
import 'package:famledger/data/models/models.dart';
import 'package:famledger/data/repos/ledger_repo.dart';
import 'package:famledger/platform/capture_adapters.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const ledger = LedgerData(
    funds: [
      Fund(id: 'f-old', name: '旧基金', archived: true),
      Fund(id: 'f1', name: '家庭公共'),
      Fund(id: 'f2', name: '宠物', isDefault: true),
    ],
    accounts: [
      Account(id: 'a1', name: '招行储蓄卡', kind: 'bank', matchHints: {'cardTails': ['6688']}),
      Account(id: 'a-old', name: '旧卡', kind: 'bank', archived: true),
    ],
    categories: [
      Category(id: 'c1', name: '餐饮'),
      Category(id: 'c-old', name: '归档', archived: true),
      Category(id: 'c2', name: '工资', kind: 'income'),
    ],
    rules: [
      Rule(id: 'r1', priority: 5, field: 'merchant', pattern: '星巴克', categoryId: 'c1', fundId: 'f1', enabled: false),
    ],
  );

  test('类别 / 基金 / 账户只带没归档的', () {
    expect(categoryCandidates(ledger.categories).map((c) => c.id), ['c1', 'c2']);
    expect(fundCandidates(ledger.funds).map((f) => f.name), ['家庭公共', '宠物']);
    final accounts = captureAccounts(ledger.accounts);
    expect(accounts.single.id, 'a1');
    expect(accounts.single.cardTails, ['6688']);
  });

  test('规则逐字段搬过去', () {
    final rule = captureRules(ledger.rules).single;
    expect(rule.id, 'r1');
    expect(rule.priority, 5);
    expect(rule.field, 'merchant');
    expect(rule.op, 'contains');
    expect(rule.pattern, '星巴克');
    expect(rule.categoryId, 'c1');
    expect(rule.fundId, 'f1');
    expect(rule.enabled, isFalse);
  });

  test('默认基金：设置里的（还在用）→ 标了默认的 → 第一个', () {
    expect(resolveDefaultFundId(ledger, const CaptureSettings(defaultFundId: 'f1')), 'f1');
    expect(resolveDefaultFundId(ledger, const CaptureSettings(defaultFundId: 'f-old')), 'f2');
    expect(resolveDefaultFundId(ledger, const CaptureSettings()), 'f2');
    const noDefault = LedgerData(funds: [Fund(id: 'x', name: 'x')]);
    expect(resolveDefaultFundId(noDefault, const CaptureSettings()), 'x');
    expect(resolveDefaultFundId(const LedgerData(), const CaptureSettings()), isNull);
  });

  test('默认账户：归档了就当没设', () {
    expect(resolveDefaultAccountId(ledger, const CaptureSettings(defaultAccountId: 'a1')), 'a1');
    expect(resolveDefaultAccountId(ledger, const CaptureSettings(defaultAccountId: 'a-old')), isNull);
    expect(resolveDefaultAccountId(ledger, const CaptureSettings()), isNull);
  });

  test('管线配置取阈值与 AI 兜底', () {
    final config = pipelineConfig(
      memberId: 'm1',
      settings: const CaptureSettings(autoConfirmThreshold: 0.6, llmFallback: true),
    );
    expect(config.memberId, 'm1');
    expect(config.threshold, 0.6);
    expect(config.aiFallback, isTrue);
  });

  test('Kotlin CapturePrefs.DEFAULTS 与 kDefaultAllowedPackages 一致', () {
    final file = File('android/app/src/main/kotlin/com/famledger/app/capture/CapturePrefs.kt');
    expect(file.existsSync(), isTrue, reason: '测试要在 app/ 目录下跑');
    final source = file.readAsStringSync();
    final block = source.substring(source.indexOf('val DEFAULTS'), source.indexOf('private fun prefs'));
    final kotlin = RegExp(r'"([^"]+)"').allMatches(block).map((m) => m.group(1)!).toSet();
    expect(kotlin, kDefaultAllowedPackages.toSet());
  });
}
