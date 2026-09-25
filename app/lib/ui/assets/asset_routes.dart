import 'package:go_router/go_router.dart';

import '../perks/benefit_form_page.dart';
import '../perks/membership_detail_page.dart';
import '../perks/membership_form_page.dart';
import '../perks/platforms_page.dart';
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
    initialTab: switch (state.uri.queryParameters['tab']) {
      'invest' => AssetsPage.investTab,
      'perks' => AssetsPage.perksTab,
      _ => 0,
    },
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
    // 会员权益（P2）：会员卡、权益、平台管理。
    GoRoute(
      path: 'memberships/new',
      builder: (context, state) => MembershipFormPage(
        initialPlatformId: state.uri.queryParameters['platformId'],
        initialSourceBenefitId: state.uri.queryParameters['sourceBenefitId'],
      ),
    ),
    GoRoute(
      path: 'memberships/:id',
      builder: (context, state) => MembershipDetailPage(state.pathParameters['id']!),
      routes: [
        GoRoute(
          path: 'edit',
          builder: (context, state) => MembershipFormPage(id: state.pathParameters['id']),
        ),
        GoRoute(
          path: 'benefits/new',
          builder: (context, state) => BenefitFormPage(
            membershipId: state.pathParameters['id'],
            parentId: state.uri.queryParameters['parentId'],
          ),
        ),
      ],
    ),
    GoRoute(
      path: 'benefits/:id/edit',
      builder: (context, state) => BenefitFormPage(id: state.pathParameters['id']),
    ),
    GoRoute(
      path: 'platforms',
      builder: (context, state) => const PlatformsPage(),
      routes: [
        GoRoute(path: 'new', builder: (context, state) => const PlatformFormPage()),
        GoRoute(
          path: ':id/edit',
          builder: (context, state) => PlatformFormPage(id: state.pathParameters['id']),
        ),
      ],
    ),
  ],
);
