import 'package:go_router/go_router.dart';

import '../../data/models/models.dart';
import '../perk_import/perk_import_page.dart';
import '../perk_import/perk_import_preview_page.dart';
import '../perks/benefit_form_page.dart';
import '../perks/membership_detail_page.dart';
import '../perks/membership_form_page.dart';
import '../perks/perk_providers.dart';
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
  builder: (context, state) {
    final q = state.uri.queryParameters;
    return AssetsPage(
      initialTab: switch (q['tab']) {
        'invest' => AssetsPage.investTab,
        'perks' => AssetsPage.perksTab,
        _ => 0,
      },
      // 会员权益 tab 先打开哪一种（首页、提醒带 `view=current&scope=mine`）；不认识的值当没给。
      perksView: PerkView.values.where((v) => v.name == q['view']).firstOrNull,
      perksScope: PerkScope.values.where((v) => v.name == q['scope']).firstOrNull,
    );
  },
  routes: [
    // AI 智能导入：?want=items|virtual 预选识别范围，?membership=<id> 是会员详情的「AI 补充权益」。
    GoRoute(
      path: 'import',
      builder: (context, state) => PerkImportPage(
        want: ImportWant.parse(state.uri.queryParameters['want']),
        targetMembershipId: state.uri.queryParameters['membership'],
      ),
    ),
    // 预览和输入页是兄弟路由：草稿靠 pendingPerkImportProvider 交接（输入页 push 过来），网页刷新到这一页时给「去粘贴」。
    GoRoute(path: 'import/preview', builder: (context, state) => const PerkImportPreviewRoute()),
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
    // 会员权益：会员卡、权益、平台管理（「打卡后建子会员」带 platformId / sourceBenefitId / termPaid 预填）。
    GoRoute(
      path: 'memberships/new',
      builder: (context, state) => MembershipFormPage(
        initialPlatformId: state.uri.queryParameters['platformId'],
        initialSourceBenefitId: state.uri.queryParameters['sourceBenefitId'],
        initialTermPaidCents: int.tryParse(state.uri.queryParameters['termPaid'] ?? ''),
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
