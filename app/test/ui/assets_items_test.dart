import 'dart:convert';

import 'package:famledger/core/dates.dart';
import 'package:famledger/ui/assets/sell_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assets_harness.dart';

/// iPhone：9/1 买、打算用 1095 天；洗衣机：闲置；旧手机：卖掉了。
AssetsBackend itemsBackend() => AssetsBackend(
  assets: [
    assetJson('a1', expectedDays: 1095, transactionId: 'tx-old'),
    assetJson(
      'a2',
      name: '洗衣机',
      category: 'appliance',
      price: 320000,
      purchasedOn: '2026-01-01',
      status: 'idle',
      sort: 1,
    ),
    assetJson(
      'a3',
      name: '旧手机',
      price: 300000,
      purchasedOn: '2026-01-01',
      status: 'sold',
      endedOn: '2026-09-10',
      saleCents: 80000,
      sort: 2,
    ),
  ],
);

double topOf(WidgetTester tester, String text) =>
    tester.getTopLeft(find.text(text)).dy;

void main() {
  group('物品列表', () {
    testWidgets('卡片：名称、已用天数、每天多少钱、状态；汇总只算在用和闲置', (tester) async {
      await pumpAssetsAt(tester, bootAssets(itemsBackend()), '/assets');

      expect(find.text('iPhone 16'), findsOneWidget);
      expect(find.text('已用 23 / 1095 天'), findsOneWidget);
      expect(find.text('¥260.83/天', findRichText: true), findsOneWidget); // 5999 / 23

      expect(find.text('洗衣机'), findsOneWidget);
      expect(find.text('已用 266 天'), findsOneWidget);
      expect(find.text('¥12.03/天', findRichText: true), findsOneWidget);
      expect(find.text('闲置'), findsOneWidget);

      // 卖掉的收在后面，天数停在卖出那天：(3000 − 800) / 253。
      expect(find.text('已退役 · 已卖出'), findsOneWidget);
      expect(find.text('用了 253 天'), findsOneWidget);
      expect(find.text('¥8.70/天', findRichText: true), findsOneWidget);
      expect(find.text('已卖出'), findsOneWidget);
      expect(topOf(tester, '旧手机'), greaterThan(topOf(tester, '洗衣机')));

      expect(find.text('每天花费'), findsOneWidget);
      expect(find.text('¥272.86/天', findRichText: true), findsOneWidget);
      expect(find.text('在用和闲置 2 件 · 原价合计 ¥9,199.00'), findsOneWidget);

      // 估值（这几行没有估值字段 = 老数据，按类别自动算）：数码每年打七五折，家电 8 年匀速降到 5%。
      expect(find.text('估值 ¥5,895.88 · −2%'), findsOneWidget);
      expect(find.text('估值 ¥2,924.11 · −9%'), findsOneWidget);
      expect(find.text('估值 ¥8,819.99 · 已折旧 ¥379.01'), findsOneWidget);
      // 卖掉的估值归零、退出汇总：那一行不写估值。
      expect(find.textContaining('估值 ¥'), findsNWidgets(3));
    });

    testWidgets('排序：按估值（和按价格不一样时看得出来）', (tester) async {
      final backend = AssetsBackend(
        assets: [
          assetJson('a1'),
          // 过了 8 年的冰箱：估值停在原价的 5%。
          assetJson(
            'a4',
            name: '老冰箱',
            category: 'appliance',
            price: 700000,
            purchasedOn: '2016-01-01',
            sort: 1,
          ),
        ],
      );
      await pumpAssetsAt(tester, bootAssets(backend), '/assets');
      expect(find.text('估值 ¥350.00 · −95%'), findsOneWidget);

      await tester.tap(find.text('按价格'));
      await settle(tester);
      expect(topOf(tester, '老冰箱'), lessThan(topOf(tester, 'iPhone 16')));

      await tester.tap(find.text('按估值'));
      await settle(tester);
      expect(topOf(tester, 'iPhone 16'), lessThan(topOf(tester, '老冰箱')));
    });

    testWidgets('手动估值高过原价：行里写「+20% 未实现」，汇总写「比原价高」', (tester) async {
      final backend = AssetsBackend(
        assets: [
          assetJson(
            'a9',
            name: '金镯子',
            category: 'jewelry',
            price: 1000000,
            purchasedOn: '2020-05-01',
            manualValueCents: 1200000,
            manualValueOn: '2025-08-01',
          ),
        ],
      );
      await pumpAssetsAt(tester, bootAssets(backend), '/assets');
      expect(find.text('估值 ¥12,000.00 · +20% 未实现'), findsOneWidget);
      expect(find.text('估值 ¥12,000.00 · 比原价高 ¥2,000.00'), findsOneWidget);
    });

    testWidgets('排序：默认按日均，切到按天数/按价格', (tester) async {
      await pumpAssetsAt(tester, bootAssets(itemsBackend()), '/assets');

      expect(topOf(tester, 'iPhone 16'), lessThan(topOf(tester, '洗衣机')));

      await tester.tap(find.text('按天数'));
      await settle(tester);
      expect(topOf(tester, '洗衣机'), lessThan(topOf(tester, 'iPhone 16')));

      await tester.tap(find.text('按价格'));
      await settle(tester);
      expect(topOf(tester, 'iPhone 16'), lessThan(topOf(tester, '洗衣机')));
    });

    testWidgets('一件都没有：说一句并给「记一件」', (tester) async {
      await pumpAssetsAt(tester, bootAssets(AssetsBackend()), '/assets');

      expect(find.text('还没记物品'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '记一件'), findsOneWidget);
    });
  });

  group('新建物品', () {
    testWidgets('「同时记一笔支出」默认开：选账户/类别，基金缺省给默认基金；存完列表里就有', (
      tester,
    ) async {
      final backend = AssetsBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets');

      await tester.tap(find.byTooltip('记一件物品'));
      await settle(tester);
      expect(find.text('记一件物品'), findsOneWidget);

      final record = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('asset-record')),
      );
      expect(record.value, isTrue);
      expect(find.text('从哪个账户付的'), findsOneWidget);
      expect(find.text('基金'), findsOneWidget);
      expect(find.text('类别'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('asset-name')), 'MacBook');
      await tester.enterText(find.byKey(const ValueKey('asset-price')), '12999.5');
      await tester.tap(find.byKey(const ValueKey('asset-category-digital')));
      await tester.tap(find.text('3 年'));
      await tester.pump();
      await tapVisible(tester, find.byKey(const ValueKey('account-bank')));
      await tapVisible(tester, find.byKey(const ValueKey('category-c1')));
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));

      expect(backend.lastBody('POST', '/assets'), {
        'name': 'MacBook',
        'category': 'digital',
        'priceCents': 1299950,
        // 默认买入日期取资产页的时钟（测试里固定在 2026-09-23），和估值同一个「今天」。
        'purchasedOn': '2026-09-23',
        'expectedDays': 1095,
        'recordTransaction': {
          'accountId': 'bank',
          'fundId': 'f1',
          'categoryId': 'c1',
        },
        // 幂等键：回应丢了再点保存，服务端认得出是同一次。
        'clientId': isA<String>(),
      });
      // 回到列表，写完同步过，新的这件已经在了。
      expect(find.text('记一件物品'), findsNothing);
      expect(find.text('MacBook'), findsOneWidget);
      expect(find.text('记好了，也记了一笔支出'), findsOneWidget);
    });

    testWidgets('关掉「同时记一笔支出」：选账户那些收起来，请求里也不带', (tester) async {
      final backend = AssetsBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/items/new');

      await tester.enterText(find.byKey(const ValueKey('asset-name')), '沙发');
      await tester.enterText(find.byKey(const ValueKey('asset-price')), '3000');
      await tapVisible(tester, find.byKey(const ValueKey('asset-record')));
      expect(find.text('从哪个账户付的'), findsNothing);

      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      final body = backend.lastBody('POST', '/assets');
      expect(body.containsKey('recordTransaction'), isFalse);
      expect(body['category'], 'digital');
      expect(find.text('沙发'), findsOneWidget);
    });

    testWidgets('没名字、买价填错：行内说清楚，不发请求', (tester) async {
      final backend = AssetsBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/items/new');

      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      expect(find.text('给它起个名字'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('asset-name')), '台灯');
      await tester.enterText(find.byKey(const ValueKey('asset-price')), '12a');
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      expect(find.text('买价填得不对，例如 5999'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('asset-price')), '99');
      await tester.enterText(find.byKey(const ValueKey('asset-expected')), '0');
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      expect(find.text('打算用多少天填个整数，例如 1095'), findsOneWidget);
      expect(backend.requests('POST', '/assets'), isEmpty);
    });

    testWidgets('保存的回应丢了：说不确定记上没有；再点沿用同一个 clientId，不多出一件', (tester) async {
      final backend = AssetsBackend()..dropResponseNext.add('POST /assets');
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/items/new');

      await tester.enterText(find.byKey(const ValueKey('asset-name')), '台灯');
      await tester.enterText(find.byKey(const ValueKey('asset-price')), '99');
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      expect(find.text('没等到服务器回应，不确定记上没有。再点一次也不会重复记。'), findsOneWidget);
      expect(find.text('记一件物品'), findsOneWidget);

      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));
      final sent = backend.requests('POST', '/assets');
      expect(sent, hasLength(2));
      expect(
        sent.map((r) => (jsonDecode(r.body) as Map)['clientId']).toSet(),
        hasLength(1),
      );
      expect(backend.assets, hasLength(1));
      expect(find.text('记一件物品'), findsNothing);
      expect(find.text('台灯'), findsOneWidget);
    });

    testWidgets('服务端拒了：错误写在按钮上面，表单留着', (tester) async {
      final backend = AssetsBackend()
        ..failNext['POST /assets'] = (400, 'invalid', 'purchasedOn 不能晚于今天');
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/items/new');

      await tester.enterText(find.byKey(const ValueKey('asset-name')), '台灯');
      await tester.enterText(find.byKey(const ValueKey('asset-price')), '99');
      await tapVisible(tester, find.widgetWithText(FilledButton, '记好了'));

      expect(find.text('purchasedOn 不能晚于今天'), findsOneWidget);
      expect(find.text('记一件物品'), findsOneWidget);
    });
  });

  testWidgets('编辑：带出原值，保存发 PATCH，不再问要不要记账', (tester) async {
    final backend = itemsBackend();
    await pumpAssetsAt(tester, bootAssets(backend), '/assets/items/a1/edit');

    expect(find.text('编辑物品'), findsOneWidget);
    expect(find.byKey(const ValueKey('asset-record')), findsNothing);
    final name = tester.widget<TextField>(find.byKey(const ValueKey('asset-name')));
    expect(name.controller!.text, 'iPhone 16');

    await tester.enterText(find.byKey(const ValueKey('asset-name')), 'iPhone 16 Pro');
    await tester.enterText(find.byKey(const ValueKey('asset-expected')), '');
    await tapVisible(tester, find.widgetWithText(FilledButton, '保存'));

    expect(backend.lastBody('PATCH', '/assets/a1'), {
      'name': 'iPhone 16 Pro',
      'category': 'digital',
      'priceCents': 599900,
      'purchasedOn': '2026-09-01',
      'expectedDays': null,
      'note': null,
      // 估值段没动：照原样把六个字段带上（编辑一律全量，null 就是清掉）。
      'valuationMethod': 'auto',
      'rateBp': null,
      'residualBp': null,
      'manualValueCents': null,
      'manualValueOn': null,
      'netWorth': 'auto',
    });
    expect(find.text('iPhone 16 Pro'), findsWidgets);
  });

  group('物品详情', () {
    testWidgets('每天花费、目标日均与进度、买入那笔流水', (tester) async {
      await pumpAssetsAt(tester, bootAssets(itemsBackend()), '/assets/items/a1');

      expect(find.text('每天花费'), findsOneWidget);
      expect(find.text('¥260.83/天', findRichText: true), findsOneWidget);
      expect(find.text('用到预期 2% · 用满时 ¥5.48/天'), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, closeTo(23 / 1095, 1e-9));
      expect(find.text('买入那笔支出'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '标记闲置'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, '退役'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, '卖出'), findsOneWidget);
    });

    testWidgets('标记闲置 → 恢复在用', (tester) async {
      final backend = itemsBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/items/a1');

      await tapVisible(tester, find.widgetWithText(FilledButton, '标记闲置'));
      expect(backend.lastBody('PATCH', '/assets/a1'), {'status': 'idle'});
      expect(find.text('数码 · 闲置'), findsOneWidget);

      await tapVisible(tester, find.widgetWithText(FilledButton, '恢复在用'));
      expect(backend.lastBody('PATCH', '/assets/a1'), {'status': 'in_use'});
      expect(find.text('数码 · 在用'), findsOneWidget);
    });

    testWidgets('退役：选个日子，天数停在那天', (tester) async {
      final backend = itemsBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/items/a1');

      await tapVisible(tester, find.widgetWithText(OutlinedButton, '退役'));
      await tester.tap(find.text('OK'));
      await settle(tester);

      final body = backend.lastBody('PATCH', '/assets/a1');
      expect(body['status'], 'retired');
      expect(body['endedOn'], Dates.isoDate(DateTime.now()));
      expect(find.text('数码 · 已退役'), findsOneWidget);
      expect(find.text('平均每天花了'), findsOneWidget);
    });

    testWidgets('卖出：填价、默认记一笔收入并选账户；卖完详情变成已卖出', (tester) async {
      final backend = itemsBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/items/a1');

      await tapVisible(tester, find.widgetWithText(OutlinedButton, '卖出'));
      final sheet = find.byType(SellSheet);
      expect(sheet, findsOneWidget);
      final record = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('sell-record')),
      );
      expect(record.value, isTrue);
      expect(find.text('收到哪个账户'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('sell-price')), '4000');
      await tester.pump();
      await tapVisible(tester, find.byKey(const ValueKey('account-wx')));
      await tapVisible(
        tester,
        find.descendant(of: sheet, matching: find.widgetWithText(FilledButton, '卖出')),
      );

      expect(backend.lastBody('POST', '/assets/a1/sell'), {
        'saleCents': 400000,
        'endedOn': '2026-09-23',
        'recordTransaction': {'accountId': 'wx', 'fundId': 'f1'},
        'clientId': isA<String>(),
      });
      expect(find.byType(SellSheet), findsNothing);
      expect(find.text('数码 · 已卖出'), findsOneWidget);
      expect(find.text('卖出价'), findsOneWidget);
      expect(find.text('卖出那笔收入'), findsOneWidget);
      // (5999 − 4000) / 23
      expect(find.text('¥86.91/天', findRichText: true), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '撤销卖出'), findsOneWidget);
    });

    testWidgets('卖出价为 0（送人了）：不记收入', (tester) async {
      final backend = itemsBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/items/a1');

      await tapVisible(tester, find.widgetWithText(OutlinedButton, '卖出'));
      await tester.enterText(find.byKey(const ValueKey('sell-price')), '0');
      await tester.pump();
      expect(find.text('卖出价是 0，不用记账'), findsOneWidget);
      await tapVisible(
        tester,
        find.descendant(
          of: find.byType(SellSheet),
          matching: find.widgetWithText(FilledButton, '卖出'),
        ),
      );
      final body = backend.lastBody('POST', '/assets/a1/sell');
      expect(body.containsKey('recordTransaction'), isFalse);
      expect(body['saleCents'], 0);
    });

    testWidgets('卖得比买得贵：日均为负并说一句', (tester) async {
      final backend = AssetsBackend(
        assets: [
          assetJson(
            'a1',
            name: '限量球鞋',
            category: 'clothing',
            price: 100000,
            status: 'sold',
            endedOn: '2026-09-10',
            saleCents: 150000,
          ),
        ],
      );
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/items/a1');

      expect(find.text('−¥50.00/天', findRichText: true), findsOneWidget); // −500 / 10 天
      expect(find.text('卖得比买得贵，这件是赚的'), findsOneWidget);
    });

    testWidgets('撤销卖出被 409 拦下：把服务端的话原样说出来', (tester) async {
      final backend = itemsBackend()
        ..failNext['PATCH /assets/a3'] = (
          409,
          'sale_recorded',
          '卖出时记过一笔收入，先把那笔删掉再改回来',
        );
      await pumpAssetsAt(tester, bootAssets(backend), '/assets/items/a3');

      await tapVisible(tester, find.widgetWithText(FilledButton, '撤销卖出'));
      expect(find.text('卖出时记过一笔收入，先把那笔删掉再改回来'), findsOneWidget);
      expect(find.text('数码 · 已卖出'), findsOneWidget);
    });

    testWidgets('删除：二次确认，删完回列表且不见了', (tester) async {
      final backend = itemsBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets');
      await tapVisible(tester, find.text('洗衣机'));
      expect(find.text('家电 · 闲置'), findsOneWidget);

      await tester.tap(find.byTooltip('删除'));
      await settle(tester);
      expect(find.text('删掉「洗衣机」？'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '删掉'));
      await settle(tester);

      expect(backend.requests('DELETE', '/assets/a2'), hasLength(1));
      expect(find.text('每天花费'), findsOneWidget);
      expect(find.text('洗衣机'), findsNothing);
      expect(find.text('iPhone 16'), findsOneWidget);
    });

    testWidgets('删除后退场那几帧还是原来的详情，不闪「已经不在了」', (tester) async {
      final backend = itemsBackend();
      await pumpAssetsAt(tester, bootAssets(backend), '/assets');
      await tapVisible(tester, find.text('iPhone 16'));

      await tester.tap(find.byTooltip('删除'));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, '删掉'));
      var flashed = false;
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (find.text('这件物品已经不在了。').evaluate().isNotEmpty) flashed = true;
      }
      await settle(tester);

      expect(backend.requests('DELETE', '/assets/a1'), hasLength(1));
      expect(flashed, isFalse);
      expect(find.text('iPhone 16'), findsNothing);
      expect(find.text('每天花费'), findsOneWidget);
    });
  });

  group('三种宽度都不溢出', () {
    for (final size in kWidths) {
      final w = size.width.toInt();

      testWidgets('列表 @$w', (tester) async {
        await pumpAssetsAt(tester, bootAssets(itemsBackend()), '/assets', size: size);
        expect(find.text('iPhone 16'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('空列表 @$w', (tester) async {
        await pumpAssetsAt(tester, bootAssets(AssetsBackend()), '/assets', size: size);
        expect(find.text('还没记物品'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('新建表单 @$w', (tester) async {
        await pumpAssetsAt(
          tester,
          bootAssets(AssetsBackend()),
          '/assets/items/new',
          size: size,
        );
        expect(find.text('记一件物品'), findsOneWidget);
        await tester.drag(find.byType(ListView).first, const Offset(0, -2000));
        await settle(tester);
        expect(tester.takeException(), isNull);
      });

      testWidgets('详情 + 卖出弹层 @$w', (tester) async {
        await pumpAssetsAt(
          tester,
          bootAssets(itemsBackend()),
          '/assets/items/a1',
          size: size,
        );
        expect(find.text('每天花费'), findsOneWidget);
        await tapVisible(tester, find.widgetWithText(OutlinedButton, '卖出'));
        expect(find.byType(SellSheet), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
