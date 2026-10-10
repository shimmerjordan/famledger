import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../app/page_frame.dart';
import '../../data/models/models.dart';
import '../debts/debt_detail_page.dart';
import '../debts/debt_form_page.dart';
import '../perk_import/perk_import_page.dart';
import '../perk_import/perk_import_preview_page.dart';
import '../perk_import/recent_imports_page.dart';
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

/// 资产 tab 各段在地址里的名字（`/assets?tab=…`）。不带 tab 时：头一次打开是第一段「基金」，
/// 之后保持当前段（见 [requestedAssetsTab]）。
const List<String> kAssetsTabNames = ['invest', 'debts', 'items', 'perks'];

/// `/assets?tab=…` 里的名字对应第几段；不认识、没给都当第一段（理财）。
int assetsTabIndexOf(String? name) {
  final index = kAssetsTabNames.indexOf(name ?? '');
  return index < 0 ? 0 : index;
}

/// 这个地址点名要资产 tab 的哪一段：`?tab=` 写了就按它；没写、但落在某一段的子页上（网页刷新到
/// 详情页、深链接进表单），垫在底下的资产页按子页归哪一段来开，返回时回到那一段；都不是就是 null ——
/// 没点名，[AssetsPage] 保持当前段（从子页返回时地址变回 `/assets`，不能因此跳回第一段）。
int? requestedAssetsTab(Uri uri) {
  final name = uri.queryParameters['tab'];
  if (name != null) return assetsTabIndexOf(name);
  final segments = uri.pathSegments; // ['assets', 'items', 'new']
  if (segments.length < 2) return null;
  return switch (segments[1]) {
    'items' => AssetsPage.itemsTab,
    'holdings' => AssetsPage.investTab,
    'debts' => AssetsPage.debtsTab,
    'memberships' || 'benefits' || 'platforms' => AssetsPage.perksTab,
    'import' => uri.queryParameters['want'] == ImportWant.items.wire ? AssetsPage.itemsTab : AssetsPage.perksTab,
    _ => null,
  };
}

/// 资产 tab 某一段的地址，比如 `assetsLocation(AssetsPage.itemsTab)` → `/assets?tab=items`。
String assetsLocation(int tab) => '/assets?tab=${kAssetsTabNames[tab]}';

/// 底部「资产」tab（外壳里的一条分支，app/router.dart）及其子页。
///
/// 子页（详情、表单、导入）要整屏盖在外壳上面、底部导航不露出来，所以每一层都挂到 [pagesOn]
/// （传 GoRouter 的根 navigator）。go_router 里没写 parentNavigatorKey 的子路由会落回 tab 自己的
/// navigator —— 孙子路由也一样，所以每一层都得写。子页仍挂在 `/assets` 下面：栈底垫着资产页，
/// 网页上刷新到详情页也有返回键、返回回到资产 tab。测试里没有外壳，[pagesOn] 不传就行。
///
/// `new` 必须排在 `:id` 前面。
GoRoute assetsTabRoute({GlobalKey<NavigatorState>? pagesOn}) {
  // 挂在根 navigator 上的整屏页带导航轨（app/page_frame.dart）；测试里没有外壳就不套。
  GoRoute page(String path, GoRouterWidgetBuilder builder, {List<RouteBase> routes = const []}) => GoRoute(
    path: path,
    parentNavigatorKey: pagesOn,
    builder: pagesOn == null
        ? builder
        : (context, state) => PageFrame(location: state.uri.toString(), child: builder(context, state)),
    routes: routes,
  );

  return GoRoute(
    path: '/assets',
    // 老地址 `/assets?tab=funds`（首页、书签、旧版通知）：基金段挪到了「我的 › 基金」。
    redirect: (context, state) =>
        state.uri.path == '/assets' && state.uri.queryParameters['tab'] == 'funds' ? '/funds' : null,
    builder: (context, state) {
      final q = state.uri.queryParameters;
      return AssetsPage(
        initialTab: requestedAssetsTab(state.uri),
        // 会员权益 tab 先打开哪一种（首页、提醒带 `view=current&scope=mine`）；不认识的值当没给。
        perksView: PerkView.values.where((v) => v.name == q['view']).firstOrNull,
        perksScope: PerkScope.values.where((v) => v.name == q['scope']).firstOrNull,
      );
    },
    routes: [
      // AI 智能导入：?want=items|virtual 预选识别范围，?membership=<id> 是会员详情的「AI 补充权益」。
      page(
        'import',
        (context, state) => PerkImportPage(
          want: ImportWant.parse(state.uri.queryParameters['want']),
          targetMembershipId: state.uri.queryParameters['membership'],
        ),
      ),
      // 预览和输入页是兄弟路由：草稿靠 pendingPerkImportProvider 交接（输入页 push 过来），网页刷新到这一页时给「去粘贴」。
      page('import/preview', (context, state) => const PerkImportPreviewRoute()),
      // 「最近的 AI 导入」：7 天内导进来的逐个撤销（会员权益 tab、物品 tab 的溢出菜单进来）。
      page('import/recent', (context, state) => const RecentImportsPage()),
      page('items/new', (context, state) => const AssetFormPage()),
      page(
        'items/:id',
        (context, state) => AssetDetailPage(state.pathParameters['id']!),
        routes: [
          page('edit', (context, state) => AssetFormPage(id: state.pathParameters['id'])),
        ],
      ),
      page('debts/new', (context, state) => const DebtFormPage()),
      page(
        'debts/:id',
        (context, state) => DebtDetailPage(state.pathParameters['id']!),
        routes: [
          page('edit', (context, state) => DebtFormPage(id: state.pathParameters['id'])),
        ],
      ),
      page('holdings/new', (context, state) => const HoldingFormPage()),
      page(
        'holdings/:id',
        (context, state) => HoldingDetailPage(state.pathParameters['id']!),
        routes: [
          page('edit', (context, state) => HoldingFormPage(id: state.pathParameters['id'])),
        ],
      ),
      // 会员权益：会员卡、权益、平台管理（「打卡后建子会员」带 platformId / sourceBenefitId / termPaid 预填）。
      page(
        'memberships/new',
        (context, state) => MembershipFormPage(
          initialPlatformId: state.uri.queryParameters['platformId'],
          initialSourceBenefitId: state.uri.queryParameters['sourceBenefitId'],
          initialTermPaidCents: int.tryParse(state.uri.queryParameters['termPaid'] ?? ''),
        ),
      ),
      page(
        'memberships/:id',
        (context, state) => MembershipDetailPage(state.pathParameters['id']!),
        routes: [
          page('edit', (context, state) => MembershipFormPage(id: state.pathParameters['id'])),
          page(
            'benefits/new',
            (context, state) => BenefitFormPage(
              membershipId: state.pathParameters['id'],
              parentId: state.uri.queryParameters['parentId'],
            ),
          ),
        ],
      ),
      page('benefits/:id/edit', (context, state) => BenefitFormPage(id: state.pathParameters['id'])),
      page(
        'platforms',
        (context, state) => const PlatformsPage(),
        routes: [
          page('new', (context, state) => const PlatformFormPage()),
          page(':id/edit', (context, state) => PlatformFormPage(id: state.pathParameters['id'])),
        ],
      ),
    ],
  );
}
