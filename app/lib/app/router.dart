import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../ui/add_tx/add_tx_page.dart';
import '../ui/ai/ai_chat_page.dart';
import '../ui/ai/ai_report_page.dart';
import '../ui/analysis/analysis_page.dart';
import '../ui/auth/connect_page.dart';
import '../ui/auth/login_page.dart';
import '../ui/auth/setup_page.dart';
import '../ui/funds/fund_detail_page.dart';
import '../ui/funds/fund_form_page.dart';
import '../ui/funds/funds_page.dart';
import '../ui/home/home_page.dart';
import '../ui/settings/about_page.dart';
import '../ui/settings/accounts_page.dart';
import '../ui/settings/ai_providers_page.dart';
import '../ui/settings/backup_page.dart';
import '../ui/settings/budgets_page.dart';
import '../ui/settings/capture_page.dart';
import '../ui/settings/categories_page.dart';
import '../ui/settings/members_page.dart';
import '../ui/settings/rules_page.dart';
import '../ui/settings/server_page.dart';
import '../ui/settings/settings_page.dart';
import '../ui/transactions/transactions_page.dart';
import '../data/repos/session_repo.dart';
import '../ui/transactions/tx_detail_page.dart';
import 'providers.dart';
import 'shell.dart';
import 'startup.dart';

/// 没登录时只能待在这三页里。
const Set<String> kAuthRoutes = {'/connect', '/setup', '/login'};

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _SessionRefresh(ref);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: '/home',
    refreshListenable: refresh,
    redirect: (context, state) {
      final session = ref.read(sessionProvider);
      final location = state.matchedLocation;
      final isAuthRoute = kAuthRoutes.contains(location);

      if (session == null) {
        if (isAuthRoute) return null;
        // 连过服务器就直接去登录，否则从头走连接向导。
        final server = ref.read(sessionProvider.notifier).storedBaseUrl;
        return (server == null || server.isEmpty) ? '/connect' : '/login';
      }
      return isAuthRoute ? '/home' : null;
    },
    routes: [
      GoRoute(path: '/connect', builder: (context, state) => const ConnectPage()),
      GoRoute(path: '/setup', builder: (context, state) => const SetupPage()),
      GoRoute(path: '/login', builder: (context, state) => const LoginPage()),

      // 五个 Tab 各自一条分支，切 Tab 不丢滚动位置。
      // 外壳外面包一层 StartupWiring：登录后的外壳一挂上，平台接线（原生打开
      // 捕获详情、iOS 分享导入）就活了，不必等用户进某个设置页。
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            StartupWiring(child: AdaptiveShell(navigationShell: navigationShell)),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/home', builder: (context, state) => const HomePage()),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/transactions',
                builder: (context, state) => const TransactionsPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/funds', builder: (context, state) => const FundsPage()),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/analysis',
                builder: (context, state) => const AnalysisPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/settings',
                builder: (context, state) => const SettingsPage(),
              ),
            ],
          ),
        ],
      ),

      // 详情/表单是整屏，压在外壳之上。`/new` 必须排在 `/:id` 前面。
      GoRoute(
        path: '/transactions/new',
        builder: (context, state) => const AddTxPage(),
      ),
      GoRoute(
        path: '/transactions/:id',
        builder: (context, state) => TxDetailPage(state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/funds/new',
        builder: (context, state) => const FundFormPage(),
      ),
      GoRoute(
        path: '/funds/:id',
        builder: (context, state) => FundDetailPage(state.pathParameters['id']!),
        routes: [
          GoRoute(
            path: 'edit',
            builder: (context, state) =>
                FundFormPage(id: state.pathParameters['id']),
          ),
        ],
      ),
      GoRoute(path: '/ai/chat', builder: (context, state) => const AiChatPage()),
      GoRoute(path: '/ai/report', builder: (context, state) => const AiReportPage()),
      GoRoute(
        path: '/settings/members',
        builder: (context, state) => const MembersPage(),
      ),
      GoRoute(
        path: '/settings/accounts',
        builder: (context, state) => const AccountsPage(),
      ),
      GoRoute(
        path: '/settings/categories',
        builder: (context, state) => const CategoriesPage(),
      ),
      GoRoute(
        path: '/settings/budgets',
        builder: (context, state) => const BudgetsPage(),
      ),
      GoRoute(
        path: '/settings/rules',
        builder: (context, state) => const RulesPage(),
      ),
      GoRoute(
        path: '/settings/capture',
        builder: (context, state) => const CapturePage(),
      ),
      GoRoute(
        path: '/settings/ai',
        builder: (context, state) => const AiProvidersPage(),
      ),
      GoRoute(
        path: '/settings/backup',
        builder: (context, state) => const BackupPage(),
      ),
      GoRoute(
        path: '/settings/server',
        builder: (context, state) => const ServerPage(),
      ),
      GoRoute(
        path: '/settings/about',
        builder: (context, state) => const AboutPage(),
      ),
    ],
    errorBuilder: (context, state) => _RouteNotFound(location: state.uri.toString()),
  );
});

/// 登录状态一变就让路由重新判一次 redirect。
class _SessionRefresh extends ChangeNotifier {
  _SessionRefresh(Ref ref) {
    ref.listen<Session?>(sessionProvider, (previous, next) {
      if (previous?.token != next?.token) notifyListeners();
    });
  }
}

class _RouteNotFound extends StatelessWidget {
  const _RouteNotFound({required this.location});

  final String location;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('走错地方了')),
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('没有这个页面：$location'),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => context.go('/home'),
            child: const Text('回首页'),
          ),
        ],
      ),
    ),
  );
}
