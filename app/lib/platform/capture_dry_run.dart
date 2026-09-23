import '../capture/parser.dart';
import '../capture/pipeline.dart';
import '../data/models/models.dart';
import '../data/repos/ledger_repo.dart';
import 'capture_adapters.dart';
import 'file_capture_store.dart';

/// 设置页「测试解析」的结果：解析要素 + 管线会怎么记。
class CaptureDryRun {
  const CaptureDryRun({required this.payment, required this.outcome});

  final ParsedPayment payment;
  final CaptureOutcome outcome;
}

/// 用内存存储 + 假接口跑一遍完整管线：不落盘、不去重、不打服务端、不学习。
///
/// 模型从 [modelSource]（真实存储）拷一份出来用，所以看到的分类结果与后台一致。
Future<CaptureDryRun> dryRunCapture({
  required RawNotification notification,
  required LedgerData ledger,
  required CaptureSettings settings,
  required String memberId,
  CaptureStore? modelSource,
}) async {
  final store = MemoryCaptureStore();
  if (modelSource != null) {
    for (final key in const [kCategoryModelKey, kFundModelKey]) {
      final json = await modelSource.loadModel(key);
      if (json != null) await store.saveModel(key, json);
    }
  }
  final pipeline = await buildPipeline(
    store: store,
    api: const _DryRunApi(),
    ledger: ledger,
    settings: settings.copyWith(aiTrigger: 'off'),
    memberId: memberId,
  );
  final outcome = await pipeline.handle(notification);
  return CaptureDryRun(payment: const NotificationParser().parse(notification), outcome: outcome);
}

class _DryRunApi implements CaptureApi {
  const _DryRunApi();

  @override
  Future<CaptureApiResult> createTransaction(Map<String, dynamic> body) async =>
      const CaptureApiResult(id: 'dry-run');

  @override
  Future<void> patchTransaction(String id, Map<String, dynamic> patch) async {}

  @override
  Future<void> confirmTransaction(String id) async {}

  @override
  Future<void> deleteTransaction(String id) async {}

  @override
  Future<void> learn(List<LearnSample> samples) async {}

  @override
  Future<Map<String, dynamic>?> aiClassify(Map<String, dynamic> input) async => null;
}
