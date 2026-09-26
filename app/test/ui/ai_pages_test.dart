import 'dart:async';
import 'dart:convert';

import 'package:famledger/app/providers.dart';
import 'package:famledger/app/theme.dart';
import 'package:famledger/core/dates.dart';
import 'package:famledger/data/api/api_client.dart';
import 'package:famledger/data/local/local_store.dart';
import 'package:famledger/data/local/secure_store.dart';
import 'package:famledger/data/models/models.dart';
import 'package:famledger/data/repos/ai_repo.dart';
import 'package:famledger/data/repos/backup_repo.dart';
import 'package:famledger/data/repos/session_repo.dart';
import 'package:famledger/ui/ai/ai_controls.dart';
import 'package:famledger/ui/ai/ai_report_page.dart';
import 'package:famledger/ui/ai/ai_chat_page.dart';
import 'package:famledger/ui/ai/simple_markdown.dart';
import 'package:famledger/ui/settings/ai_provider_form.dart';
import 'package:famledger/ui/settings/ai_providers_page.dart';
import 'package:famledger/ui/settings/backup_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 假的 AI 仓库：对话走测试自己控制的流，渠道/预设给固定几条。
class FakeAiRepo extends AiRepo {
  FakeAiRepo({
    this.chatStream,
    this.providerList = const [],
    this.presetList = const [],
    this.testResult,
    this.reportStream,
    this.reportList = const [],
    this.visionResult,
  }) : super(
         ApiClient(
           baseUrl: 'https://x.dev',
           inner: MockClient((_) async => http.Response('{}', 200)),
         ),
       );

  final Stream<String>? chatStream;
  final List<AiProvider> providerList;
  final List<AiPreset> presetList;
  final AiProviderTest? testResult;
  final Stream<String>? reportStream;
  final List<AiReport> reportList;

  /// 看图探测回什么；带着 provider 时，之后的渠道列表换成它（像服务端写进了 extra.vision）。
  final AiVisionTest? visionResult;
  late List<AiProvider> _providers = [...providerList];
  final List<String> visionTested = [];

  List<AiChatMessage> lastMessages = const [];
  String? lastMonth;
  String? lastReportMonth;

  @override
  Stream<String> chat(
    List<AiChatMessage> messages, {
    String? providerId,
    String? month,
  }) {
    lastMessages = messages;
    lastMonth = month;
    return chatStream ?? const Stream<String>.empty();
  }

  @override
  Stream<String> report(String month, {String? providerId}) {
    lastReportMonth = month;
    return reportStream ?? const Stream<String>.empty();
  }

  @override
  Future<List<AiReport>> reports({String? month}) async => reportList;

  @override
  Future<List<AiProvider>> providers() async => _providers;

  @override
  Future<AiVisionTest> testVision(String id) async {
    visionTested.add(id);
    final result = visionResult ?? const AiVisionTest();
    final updated = result.provider;
    if (updated != null) _providers = [for (final p in _providers) p.id == updated.id ? updated : p];
    return result;
  }

  @override
  Future<List<AiPreset>> presets() async => presetList;

  @override
  Future<AiProviderTest> test(String id) async =>
      testResult ?? const AiProviderTest(ok: true);
}

Widget wrap(Widget child, {List<Override> overrides = const []}) => ProviderScope(
  overrides: overrides,
  child: MaterialApp(theme: buildTheme(Brightness.light), home: child),
);

/// 假的备份仓库：不碰网络，只回固定的配置/列表/状态。
class FakeBackupRepo extends BackupRepo {
  FakeBackupRepo({
    required this.config_,
    this.items = const [],
    this.status_,
    this.configAfterRestore,
  }) : super(
        ApiClient(
          baseUrl: 'https://x.dev',
          inner: MockClient((_) async => http.Response('{}', 200)),
        ),
      );

  final BackupConfig config_;
  final List<BackupItem> items;
  final BackupStatus? status_;

  /// 恢复之后服务端那边的配置（配置本身也住在被换掉的那个库里）。
  final BackupConfig? configAfterRestore;

  String? restored;

  /// 最近一次「测试连接」收到的表单值。
  Map<String, String>? tested;

  @override
  Future<BackupTestResult> test({
    required String url,
    required String username,
    required String password,
    required String remoteDir,
  }) async {
    tested = {'url': url, 'username': username, 'password': password, 'remoteDir': remoteDir};
    return const BackupTestResult(ok: true, message: '连接成功：/famledger 下已有 0 个备份');
  }

  @override
  Future<BackupConfig> config() async =>
      restored == null ? config_ : (configAfterRestore ?? config_);

  @override
  Future<List<BackupItem>> list() async => items;

  @override
  Future<BackupStatus> status() async => status_ ?? const BackupStatus();

  @override
  Future<BackupRestoreResult> restore(String name) async {
    restored = name;
    return BackupRestoreResult(
      ok: true,
      restoredFrom: name,
      preRestoreCopy: 'pre-restore-20260913-101500.db',
    );
  }
}

/// 带一个已登录成员的容器（渠道页与备份页都要看角色）。
Future<ProviderContainer> boot({
  String role = 'admin',
  List<Override> overrides = const [],
}) async {
  final secure = MemorySecureStore();
  secure.data[SessionRepo.baseUrlKey] = 'https://x.dev';
  secure.data[SessionRepo.sessionKey] = jsonEncode({
    'baseUrl': 'https://x.dev',
    'token': 'tok',
    'deviceId': 'dev',
    'me': {'id': 'm1', 'username': 'mama', 'displayName': '妈妈', 'role': role},
  });
  final session = SessionRepo(secure: secure);
  await session.restore();
  return ProviderContainer(
    overrides: [
      localStoreProvider.overrideWithValue(MemoryLocalStore()),
      secureStoreProvider.overrideWithValue(secure),
      sessionRepoProvider.overrideWithValue(session),
      ...overrides,
    ],
  );
}

Future<void> pumpIn(
  WidgetTester tester,
  ProviderContainer container,
  Widget home,
) async {
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: buildTheme(Brightness.light), home: home),
    ),
  );
}

void main() {
  group('问 AI', () {
    testWidgets('空态说清楚能问什么，并给三个例子', (tester) async {
      final repo = FakeAiRepo();
      await tester.pumpWidget(
        wrap(const AiChatPage(), overrides: [aiRepoProvider.overrideWithValue(repo)]),
      );
      await tester.pump();

      expect(find.text('问点什么'), findsOneWidget);
      for (final example in AiChatPage.examples) {
        expect(find.text(example), findsOneWidget);
      }
    });

    testWidgets('两段 delta 拼成一条回答，流式时有停止按钮', (tester) async {
      final controller = StreamController<String>();
      addTearDown(() async {
        if (!controller.isClosed) await controller.close();
      });
      final repo = FakeAiRepo(chatStream: controller.stream);
      await tester.pumpWidget(
        wrap(const AiChatPage(), overrides: [aiRepoProvider.overrideWithValue(repo)]),
      );
      await tester.pump();

      await tester.tap(find.text(AiChatPage.examples.first));
      await tester.pump();

      // 问题以「自己说的」出现，并带上了月份上下文。
      expect(find.text(AiChatPage.examples.first), findsOneWidget);
      expect(repo.lastMessages.single.content, AiChatPage.examples.first);
      expect(repo.lastMonth, isNotNull);

      controller.add('本月支出 3,210 元，');
      await tester.pump();
      expect(find.textContaining('本月支出 3,210 元，'), findsOneWidget);
      expect(find.byTooltip('停止'), findsOneWidget);

      controller.add('比上月少 8%。');
      await controller.close();
      await tester.pump();
      await tester.pump();

      expect(find.text('本月支出 3,210 元，比上月少 8%。'), findsOneWidget);
      expect(find.byTooltip('停止'), findsNothing);
      expect(find.byTooltip('发送'), findsOneWidget);
    });

    testWidgets('回答到一半换上下文月份 → 停在当场，后面的 delta 不再续写', (tester) async {
      final controller = StreamController<String>();
      addTearDown(() async {
        if (!controller.isClosed) await controller.close();
      });
      final repo = FakeAiRepo(chatStream: controller.stream);
      await tester.pumpWidget(
        wrap(const AiChatPage(), overrides: [aiRepoProvider.overrideWithValue(repo)]),
      );
      await tester.pump();

      await tester.tap(find.text(AiChatPage.examples.first));
      await tester.pump();
      controller.add('这个月主要花在餐饮，');
      await tester.pump();

      final previous = Dates.shiftMonth(Dates.currentMonth(), -1);
      await tester.tap(find.byType(AiMonthChip));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text(Dates.monthLabel(previous)).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      controller.add('这段是旧月份的续写');
      await tester.pump();

      expect(find.textContaining('这段是旧月份的续写'), findsNothing);
      expect(find.text('这个月主要花在餐饮，'), findsOneWidget, reason: '已经说出口的留着');
      expect(find.byTooltip('停止'), findsNothing);
    });

    testWidgets('出错时行内说明 + 重试', (tester) async {
      final repo = FakeAiRepo(
        chatStream: Stream<String>.error(
          const ApiException(0, 'ai_error', '渠道余额不足'),
        ),
      );
      await tester.pumpWidget(
        wrap(const AiChatPage(), overrides: [aiRepoProvider.overrideWithValue(repo)]),
      );
      await tester.pump();

      await tester.tap(find.text(AiChatPage.examples.last));
      await tester.pump();
      await tester.pump();

      expect(find.text('渠道余额不足'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });
  });

  group('渠道表单', () {
    testWidgets('选预设自动填地址、模型，并给出 cc-trans 的填法提示', (tester) async {
      final repo = FakeAiRepo(
        presetList: const [
          AiPreset(
            key: 'cc-trans',
            name: 'cc-trans（自建反代）',
            kind: 'anthropic',
            baseUrl: 'http://nas:8787',
            model: 'claude-sonnet-4',
          ),
          AiPreset(
            key: 'siliconflow',
            name: '硅基流动',
            baseUrl: 'https://api.siliconflow.cn/v1',
            model: 'deepseek-ai/DeepSeek-V3',
          ),
        ],
      );
      await tester.pumpWidget(
        wrap(
          const Scaffold(body: AiProviderFormSheet()),
          overrides: [aiRepoProvider.overrideWithValue(repo)],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButton<String?>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('cc-trans（自建反代）').last);
      await tester.pumpAndSettle();

      // 弹层里的输入框顺序：名称 / 接口地址 / 密钥 / 模型。
      final baseUrl = tester.widget<TextField>(find.byType(TextField).at(1));
      final model = tester.widget<TextField>(find.byType(TextField).at(3));
      expect(baseUrl.controller?.text, 'http://nas:8787');
      expect(model.controller?.text, 'claude-sonnet-4');
      expect(
        find.text(AiProviderFormSheet.fallbackHints['cc-trans']!),
        findsOneWidget,
      );
    });

    testWidgets('编辑已有渠道时密钥框写明已保存的尾号', (tester) async {
      final repo = FakeAiRepo();
      await tester.pumpWidget(
        wrap(
          const Scaffold(
            body: AiProviderFormSheet(
              provider: AiProvider(
                id: 'p1',
                name: '硅基流动',
                baseUrl: 'https://api.siliconflow.cn/v1',
                model: 'deepseek-ai/DeepSeek-V3',
                hasKey: true,
                keyTail: '3f9a',
              ),
            ),
          ),
          overrides: [aiRepoProvider.overrideWithValue(repo)],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('已保存 …3f9a，留空表示不修改'), findsOneWidget);
    });

    testWidgets('「高级」：附加请求参数和导入输出上限写进 extra，原来别的键留着；不是 JSON 对象就行内说、不发请求', (tester) async {
      final seen = <http.Request>[];
      final repo = AiRepo(
        ApiClient(
          baseUrl: 'https://x.dev',
          inner: MockClient((req) async {
            seen.add(req);
            final body = req.url.path.endsWith('/ai/presets')
                ? {'items': <Object>[]}
                : {
                    'provider': {'id': 'p1', 'name': '硅基流动'},
                  };
            return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
          }),
        ),
      );
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        wrap(
          const Scaffold(
            body: AiProviderFormSheet(
              provider: AiProvider(
                id: 'p1',
                name: '硅基流动',
                baseUrl: 'https://api.siliconflow.cn/v1',
                model: 'Qwen/Qwen3-32B',
                hasKey: true,
                keyTail: '3f9a',
                extra: {
                  'vision': true,
                  'requestExtras': {'temperature': 0.3},
                },
              ),
            ),
          ),
          overrides: [aiRepoProvider.overrideWithValue(repo)],
        ),
      );
      await tester.pumpAndSettle();
      final extras = find.byKey(const ValueKey('ai-provider-extras'));
      expect(extras, findsOneWidget, reason: '有值时「高级」默认展开');
      expect(tester.widget<TextField>(extras).controller!.text, '{"temperature":0.3}');

      await tester.enterText(extras, 'enable_thinking=false');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('附加请求参数要写成 JSON 对象，比如 {"enable_thinking": false}'), findsOneWidget);
      expect(seen.where((r) => r.method == 'PATCH'), isEmpty);

      await tester.enterText(extras, '{"enable_thinking": false}');
      await tester.enterText(find.byKey(const ValueKey('ai-provider-import-max')), '8000');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      final patch = seen.lastWhere((r) => r.method == 'PATCH');
      expect(patch.url.path, '/api/v1/ai/providers/p1');
      expect((jsonDecode(patch.body) as Map)['extra'], {
        'vision': true,
        'requestExtras': {'enable_thinking': false},
        'importMaxTokens': 8000,
      });
    });
  });

  group('渠道列表', () {
    testWidgets('默认渠道有标记，测试按钮给出延迟与样例', (tester) async {
      final repo = FakeAiRepo(
        providerList: const [
          AiProvider(
            id: 'p1',
            name: '硅基流动',
            baseUrl: 'https://api.siliconflow.cn/v1',
            model: 'deepseek-ai/DeepSeek-V3',
            isDefault: true,
            hasKey: true,
            keyTail: '3f9a',
          ),
        ],
        testResult: const AiProviderTest(
          ok: true,
          model: 'deepseek-ai/DeepSeek-V3',
          latencyMs: 321,
          sample: '你好，我在。',
        ),
      );
      await pumpIn(
        tester,
        await boot(overrides: [aiRepoProvider.overrideWithValue(repo)]),
        const AiProvidersPage(),
      );
      await tester.pumpAndSettle();

      expect(find.text('硅基流动'), findsOneWidget);
      expect(find.text('默认'), findsOneWidget);
      expect(find.textContaining('密钥 …3f9a'), findsOneWidget);

      await tester.tap(find.text('测试'));
      await tester.pumpAndSettle();

      expect(find.textContaining('321ms'), findsOneWidget);
      expect(find.textContaining('你好，我在。'), findsOneWidget);
    });

    testWidgets('非管理员只看不改：没有开关、没有「测试」，一句话说明为什么', (tester) async {
      final repo = FakeAiRepo(
        providerList: const [
          AiProvider(
            id: 'p1',
            name: '硅基流动',
            model: 'deepseek-ai/DeepSeek-V3',
            isDefault: true,
            hasKey: true,
            keyTail: '3f9a',
          ),
        ],
      );
      await pumpIn(
        tester,
        await boot(
          role: 'member',
          overrides: [aiRepoProvider.overrideWithValue(repo)],
        ),
        const AiProvidersPage(),
      );
      await tester.pumpAndSettle();

      expect(find.text('硅基流动'), findsOneWidget);
      expect(find.text('渠道配置由管理员维护。'), findsOneWidget);
      expect(find.text('已启用'), findsOneWidget);
      // `POST /ai/providers/:id/test` 是 admin-only，普通成员按下去只会拿到 403。
      expect(find.text('测试'), findsNothing);
      expect(find.byType(Switch), findsNothing);
      expect(find.byIcon(Icons.add), findsNothing);
    });
  });

  group('看图探测', () {
    const blind = AiProvider(id: 'p1', name: 'DeepSeek', model: 'deepseek-chat', hasKey: true, isDefault: true);

    testWidgets('测过的渠道名字旁边写「支持看图 / 看不了图」，没测过的不写；普通成员也看得到标记、没有「测看图」', (tester) async {
      final repo = FakeAiRepo(providerList: const [
        AiProvider(id: 'a', name: 'cc-trans', model: 'claude-sonnet-5', hasKey: true, extra: {'vision': true}),
        AiProvider(id: 'b', name: 'DeepSeek', model: 'deepseek-chat', hasKey: true, extra: {'vision': false}),
        AiProvider(id: 'c', name: '硅基流动', model: 'Qwen/Qwen3-32B', hasKey: true),
      ]);
      await pumpIn(tester, await boot(role: 'member', overrides: [aiRepoProvider.overrideWithValue(repo)]), const AiProvidersPage());
      await tester.pumpAndSettle();
      expect(find.text('支持看图'), findsOneWidget);
      expect(find.text('看不了图'), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-vision-tag')), findsNWidgets(2));
      expect(find.text('测看图'), findsNothing);
    });

    testWidgets('管理员点「测看图」→ 测出能看图：写一句结果，名字旁边出现「支持看图」', (tester) async {
      final repo = FakeAiRepo(
        providerList: const [blind],
        visionResult: const AiVisionTest(
          vision: true,
          sample: '红色',
          latencyMs: 210,
          provider: AiProvider(id: 'p1', name: 'DeepSeek', model: 'deepseek-chat', hasKey: true, isDefault: true, extra: {'vision': true}),
        ),
      );
      await pumpIn(tester, await boot(overrides: [aiRepoProvider.overrideWithValue(repo)]), const AiProvidersPage());
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ai-vision-tag')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('ai-vision-test-p1')));
      await tester.pumpAndSettle();
      expect(repo.visionTested, ['p1']);
      expect(find.text('支持看图 · 210ms'), findsOneWidget, reason: '结果和「测试」的结果放同一个位置，叫法和标签一致');
      expect(find.text('支持看图'), findsOneWidget);
    });

    testWidgets('测出看不了图：结果写原因（正文色，不是报错色），名字旁边变成「看不了图」；再点「测试」，看图的结果让位', (tester) async {
      final repo = FakeAiRepo(
        providerList: const [blind],
        visionResult: const AiVisionTest(
          vision: false,
          sample: '蓝色',
          message: '它说「蓝色」，看起来没看到图',
          provider: AiProvider(id: 'p1', name: 'DeepSeek', model: 'deepseek-chat', hasKey: true, isDefault: true, extra: {'vision': false}),
        ),
      );
      await pumpIn(tester, await boot(overrides: [aiRepoProvider.overrideWithValue(repo)]), const AiProvidersPage());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ai-vision-test-p1')));
      await tester.pumpAndSettle();
      final note = tester.widget<Text>(find.byKey(const ValueKey('ai-vision-note-p1')));
      expect(note.data, '看不了图：它说「蓝色」，看起来没看到图');
      final context = tester.element(find.byKey(const ValueKey('ai-vision-note-p1')));
      expect(note.style?.color, Theme.of(context).colorScheme.onSurface);
      expect(find.text('看不了图'), findsOneWidget, reason: '名字旁边的标记');
      await tester.tap(find.text('测试'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ai-vision-note-p1')), findsNothing, reason: '一个位置只放最近那次的结果');
      expect(find.textContaining('通了'), findsOneWidget);
    });

    for (final width in [400.0, 800.0, 1400.0]) {
      testWidgets('宽 $width、字号 1.5 倍：两种标记、默认标记和看图结果都不溢出', (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        tester.platformDispatcher.textScaleFactorTestValue = 1.5;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final repo = FakeAiRepo(
          providerList: const [
            AiProvider(id: 'a', name: '家里自建的 cc-trans 反向代理', model: 'claude-sonnet-5', hasKey: true, isDefault: true, extra: {'vision': true}),
            AiProvider(id: 'b', name: 'DeepSeek', model: 'deepseek-chat', hasKey: true, extra: {'vision': false}),
          ],
          visionResult: const AiVisionTest(message: '上游返回 500：fake is unhappy，过一会儿再测一次看看'),
        );
        await pumpIn(tester, await boot(overrides: [aiRepoProvider.overrideWithValue(repo)]), const AiProvidersPage());
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('ai-vision-test-b')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('ai-vision-note-b')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('判断不了（连不上、没回答）：写原因，标记不变', (tester) async {
      final repo = FakeAiRepo(providerList: const [blind], visionResult: const AiVisionTest(message: '上游返回 500：fake is unhappy'));
      await pumpIn(tester, await boot(overrides: [aiRepoProvider.overrideWithValue(repo)]), const AiProvidersPage());
      await tester.pumpAndSettle();
      await tester.tap(find.text('测看图'));
      await tester.pumpAndSettle();
      expect(find.text('上游返回 500：fake is unhappy'), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-vision-tag')), findsNothing);
    });
  });

  group('AI 月报', () {
    testWidgets('历史报告的时间按本地时区显示，不是服务端的 UTC', (tester) async {
      final createdAt = DateTime.utc(2026, 9, 30, 20, 5);
      final repo = FakeAiRepo(
        reportList: [
          AiReport(
            id: 'r1',
            month: '2026-09',
            content: '# 九月月报\n\n本月支出 3,210 元。',
            createdAt: createdAt,
          ),
        ],
      );
      await tester.pumpWidget(
        wrap(
          const AiReportPage(),
          overrides: [aiRepoProvider.overrideWithValue(repo)],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(Dates.dateTimeLabel(createdAt.toLocal())), findsOneWidget);
      if (DateTime.now().timeZoneOffset != Duration.zero) {
        expect(
          find.text(Dates.dateTimeLabel(createdAt)),
          findsNothing,
          reason: '直接读 UTC 的小时会差出一个时区（东八区差 8 小时、还会串到前一天）',
        );
      }
    });

    testWidgets('生成到一半换月份 → 掐掉旧月份的流，迟到的内容不再往下写', (tester) async {
      final controller = StreamController<String>();
      addTearDown(() async {
        if (!controller.isClosed) await controller.close();
      });
      final repo = FakeAiRepo(reportStream: controller.stream);
      await tester.pumpWidget(
        wrap(
          const AiReportPage(),
          overrides: [aiRepoProvider.overrideWithValue(repo)],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('生成本月报告'));
      await tester.pump();
      controller.add('九月：支出 3,210 元。');
      await tester.pump();
      expect(find.textContaining('九月：支出 3,210 元。'), findsOneWidget);

      final previous = Dates.shiftMonth(Dates.currentMonth(), -1);
      await tester.tap(find.byType(AiMonthChip));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text(Dates.monthLabel(previous)).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      controller.add('八月：这段属于上一次请求');
      await tester.pump();

      expect(find.textContaining('九月：支出 3,210 元。'), findsNothing);
      expect(find.textContaining('八月：这段属于上一次请求'), findsNothing);
      expect(find.text('生成${Dates.monthLabel(previous)}报告'), findsOneWidget);
    });
  });

  group('轻量 Markdown', () {
    testWidgets('标题加粗、列表带记号、行内代码不带反引号', (tester) async {
      await tester.pumpWidget(
        wrap(
          const Scaffold(
            body: SimpleMarkdown(
              '## 九月小结\n\n本月**超支** 320 元。\n\n- 餐饮 1,200 元\n'
              '- 交通 300 元\n\n1. 少点外卖\n\n用 `basicStats` 看细项。',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('九月小结'), findsOneWidget);
      expect(find.text('本月超支 320 元。'), findsOneWidget);
      expect(find.text('餐饮 1,200 元'), findsOneWidget);
      expect(find.text('·'), findsNWidgets(2));
      expect(find.text('1.'), findsOneWidget);
      expect(find.text('用 basicStats 看细项。'), findsOneWidget);
    });
  });

  group('备份页', () {
    const config = BackupConfig(
      webdav: WebdavConfig(
        url: 'https://dav.jianguoyun.com/dav',
        username: 'mama@example.com',
        hasPassword: true,
        remoteDir: '/famledger',
      ),
      schedule: BackupSchedule(enabled: true, hour: 3, keep: 14),
      encryption: BackupEncryption(enabled: true, hasPassphrase: true),
    );

    testWidgets('回填表单，口令写明「不填则保持不变」，远端列表带锁与大小', (tester) async {
      tester.view.physicalSize = const Size(400, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repo = FakeBackupRepo(
        config_: config,
        items: [
          BackupItem(
            name: 'famledger-20260913-030000.db.gz.enc',
            bytes: 1258291,
            modifiedAt: DateTime.now(),
            encrypted: true,
          ),
        ],
      );
      await pumpIn(
        tester,
        await boot(overrides: [backupRepoProvider.overrideWithValue(repo)]),
        const BackupPage(),
      );
      await tester.pumpAndSettle();

      final url = tester.widget<TextField>(
        find.ancestor(of: find.text('地址'), matching: find.byType(TextField)),
      );
      expect(url.controller?.text, 'https://dav.jianguoyun.com/dav');
      expect(find.text('已保存，不填则保持不变'), findsNWidgets(2));
      expect(find.text('famledger-20260913-030000.db.gz.enc'), findsOneWidget);
      expect(find.textContaining('1.2 MB'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    });

    testWidgets('测试连接用表单里现在填的值，不用先保存；口令框留空就传空', (tester) async {
      tester.view.physicalSize = const Size(400, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repo = FakeBackupRepo(config_: config);
      await pumpIn(
        tester,
        await boot(overrides: [backupRepoProvider.overrideWithValue(repo)]),
        const BackupPage(),
      );
      await tester.pumpAndSettle();

      // 改了地址和远端目录，不点「保存设置」直接测
      await tester.enterText(
        find.ancestor(of: find.text('地址'), matching: find.byType(TextField)),
        '  https://nas-webdav.example.com/Web/  ',
      );
      await tester.enterText(
        find.ancestor(of: find.text('远端目录'), matching: find.byType(TextField)),
        '/fam',
      );
      await tester.tap(find.text('测试连接'));
      await tester.pumpAndSettle();

      expect(repo.tested, {
        'url': 'https://nas-webdav.example.com/Web/',
        'username': 'mama@example.com',
        'password': '',
        'remoteDir': '/fam',
      });
      expect(find.text('连接成功：/famledger 下已有 0 个备份'), findsOneWidget);

      // 这次填了口令就一起带上
      await tester.enterText(
        find.ancestor(of: find.text('口令'), matching: find.byType(TextField)),
        'app-pass',
      );
      await tester.tap(find.text('测试连接'));
      await tester.pumpAndSettle();
      expect(repo.tested?['password'], 'app-pass');
    });

    testWidgets('恢复前先说清楚会留一份 pre-restore 副本', (tester) async {
      tester.view.physicalSize = const Size(400, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repo = FakeBackupRepo(
        config_: config,
        items: [
          const BackupItem(name: 'famledger-20260913-030000.db.gz', bytes: 1024),
        ],
      );
      await pumpIn(
        tester,
        await boot(overrides: [backupRepoProvider.overrideWithValue(repo)]),
        const BackupPage(),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('恢复'));
      await tester.pumpAndSettle();

      expect(find.textContaining('pre-restore-*.db'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(repo.restored, isNull);
    });

    testWidgets('恢复成功后表单按恢复出来的那个库重填', (tester) async {
      tester.view.physicalSize = const Size(400, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repo = FakeBackupRepo(
        config_: config,
        items: [
          const BackupItem(name: 'famledger-20260913-030000.db.gz', bytes: 1024),
        ],
        configAfterRestore: const BackupConfig(
          webdav: WebdavConfig(
            url: 'https://dav.other.com/dav',
            username: 'baba@example.com',
            hasPassword: true,
            remoteDir: '/old-famledger',
          ),
          schedule: BackupSchedule(enabled: false, hour: 5, keep: 7),
          encryption: BackupEncryption(),
        ),
      );
      await pumpIn(
        tester,
        await boot(overrides: [backupRepoProvider.overrideWithValue(repo)]),
        const BackupPage(),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('恢复'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认恢复'));
      await tester.pumpAndSettle();

      expect(repo.restored, 'famledger-20260913-030000.db.gz');
      expect(find.textContaining('pre-restore-20260913-101500.db'), findsOneWidget);
      final url = tester.widget<TextField>(
        find.ancestor(of: find.text('地址'), matching: find.byType(TextField)),
      );
      expect(
        url.controller?.text,
        'https://dav.other.com/dav',
        reason: '备份配置就存在被换掉的那个库里，表单得跟着换',
      );
    });

    testWidgets('不是管理员就直说「只有管理员能配置备份」', (tester) async {
      final repo = FakeBackupRepo(config_: config);
      await pumpIn(
        tester,
        await boot(
          role: 'member',
          overrides: [backupRepoProvider.overrideWithValue(repo)],
        ),
        const BackupPage(),
      );
      await tester.pumpAndSettle();

      expect(find.text('只有管理员能配置备份'), findsOneWidget);
      expect(find.text('保存设置'), findsNothing);
    });
  });
}
