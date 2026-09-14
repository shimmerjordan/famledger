import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/providers.dart';
import 'app/router.dart';
import 'app/theme.dart';
import 'data/local/local_store.dart';
import 'data/local/secure_store.dart';
import 'data/repos/session_repo.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 会话先恢复好，路由的 redirect 才能是同步判断，启动不闪屏。
  final store = await LocalStore.open();
  final secure = await SecureStore.open();
  final sessionRepo = SessionRepo(secure: secure);
  await sessionRepo.restore();

  runApp(
    ProviderScope(
      overrides: [
        localStoreProvider.overrideWithValue(store),
        secureStoreProvider.overrideWithValue(secure),
        sessionRepoProvider.overrideWithValue(sessionRepo),
      ],
      child: const FamLedgerApp(),
    ),
  );
}

class FamLedgerApp extends ConsumerWidget {
  const FamLedgerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp.router(
    title: '家账',
    debugShowCheckedModeBanner: false,
    theme: lightTheme,
    darkTheme: darkTheme,
    themeMode: ThemeMode.system,
    routerConfig: ref.watch(routerProvider),
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
  );
}
