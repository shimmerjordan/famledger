import '../capture/capture_types.dart';
import '../capture/classifier.dart';
import '../capture/pipeline.dart';
import '../data/models/models.dart';
import '../data/repos/ledger_repo.dart';

/// 数据层模型 → 管线的轻量类型（`lib/capture` 刻意不依赖 `lib/data`，桥在这里）。

List<ClassifierCandidate> categoryCandidates(Iterable<Category> categories) => [
  for (final c in categories)
    if (!c.archived) ClassifierCandidate(id: c.id, name: c.name),
];

List<ClassifierCandidate> fundCandidates(Iterable<Fund> funds) => [
  for (final f in funds)
    if (!f.archived) ClassifierCandidate(id: f.id, name: f.name),
];

List<CaptureAccount> captureAccounts(Iterable<Account> accounts) => [
  for (final a in accounts)
    if (!a.archived)
      CaptureAccount(id: a.id, name: a.name, kind: a.kind, matchHints: a.matchHints),
];

List<CaptureRule> captureRules(Iterable<Rule> rules) => [
  for (final r in rules)
    CaptureRule(
      id: r.id,
      priority: r.priority,
      field: r.field,
      op: r.op,
      pattern: r.pattern,
      categoryId: r.categoryId,
      fundId: r.fundId,
      accountId: r.accountId,
      memberId: r.memberId,
      enabled: r.enabled,
    ),
];

/// 设置里的默认基金 → 标了默认的基金 → 第一个在用的基金。
String? resolveDefaultFundId(LedgerData ledger, CaptureSettings settings) {
  final active = ledger.activeFunds;
  final configured = settings.defaultFundId;
  if (configured != null && active.any((f) => f.id == configured)) return configured;
  for (final f in active) {
    if (f.isDefault) return f.id;
  }
  return active.isEmpty ? null : active.first.id;
}

/// 设置里的默认账户（必须还在用），否则不指定。
String? resolveDefaultAccountId(LedgerData ledger, CaptureSettings settings) {
  final configured = settings.defaultAccountId;
  if (configured == null) return null;
  return ledger.activeAccounts.any((a) => a.id == configured) ? configured : null;
}

CapturePipelineConfig pipelineConfig({
  required String memberId,
  required CaptureSettings settings,
}) => CapturePipelineConfig(
  memberId: memberId,
  threshold: settings.autoConfirmThreshold.clamp(0.0, 1.0),
  aiFallback: settings.llmFallback,
);

/// 用一份主数据 + 家庭设置装配管线（模型来自 [store]，没有就种子训练并落盘）。
Future<CapturePipeline> buildPipeline({
  required CaptureStore store,
  required CaptureApi api,
  required LedgerData ledger,
  required CaptureSettings settings,
  required String memberId,
  DateTime Function()? now,
}) => CapturePipeline.bootstrap(
  store: store,
  api: api,
  config: pipelineConfig(memberId: memberId, settings: settings),
  categories: categoryCandidates(ledger.categories),
  funds: fundCandidates(ledger.funds),
  accounts: captureAccounts(ledger.accounts),
  rules: captureRules(ledger.rules),
  defaultFundId: resolveDefaultFundId(ledger, settings),
  defaultAccountId: resolveDefaultAccountId(ledger, settings),
  now: now,
);
