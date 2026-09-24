import 'package:go_router/go_router.dart';

import 'asset_detail_page.dart';
import 'asset_form_page.dart';
import 'assets_page.dart';
import 'holding_detail_page.dart';
import 'holding_form_page.dart';

/// `/assets` 及其子页。资产不占底部导航：入口在首页卡片和「我的」。
///
/// `new` 必须排在 `:id` 前面。
GoRoute assetsRoute() => GoRoute(
  path: '/assets',
  builder: (context, state) => AssetsPage(
    initialTab: state.uri.queryParameters['tab'] == 'invest'
        ? AssetsPage.investTab
        : 0,
  ),
  routes: [
    GoRoute(
      path: 'items/new',
      builder: (context, state) => const AssetFormPage(),
    ),
    GoRoute(
      path: 'items/:id',
      builder: (context, state) => AssetDetailPage(state.pathParameters['id']!),
      routes: [
        GoRoute(
          path: 'edit',
          builder: (context, state) =>
              AssetFormPage(id: state.pathParameters['id']),
        ),
      ],
    ),
    GoRoute(
      path: 'holdings/new',
      builder: (context, state) => const HoldingFormPage(),
    ),
    GoRoute(
      path: 'holdings/:id',
      builder: (context, state) =>
          HoldingDetailPage(state.pathParameters['id']!),
      routes: [
        GoRoute(
          path: 'edit',
          builder: (context, state) =>
              HoldingFormPage(id: state.pathParameters['id']),
        ),
      ],
    ),
  ],
);
