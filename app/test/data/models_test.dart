import 'package:famledger/core/dates.dart';
import 'package:famledger/data/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Member', () {
    test('fromJson/toJson 往返', () {
      final json = {
        'id': 'm1',
        'username': 'mama',
        'displayName': '妈妈',
        'color': '#c25430',
        'avatarEmoji': '🌸',
        'role': 'admin',
        'archived': false,
      };
      expect(Member.fromJson(json).toJson(), json);
      expect(Member.fromJson(json).isAdmin, isTrue);
    });
  });

  group('Account', () {
    test('fromJson/toJson 往返（含 matchHints）', () {
      final json = {
        'id': 'a1',
        'name': '招商卡',
        'kind': 'bank',
        'ownerMemberId': 'm1',
        'initialBalanceCents': 100000,
        'currency': 'CNY',
        'icon': 'credit_card',
        'color': '#1292c0',
        'sortOrder': 3,
        'archived': false,
        'matchHints': {
          'last4': ['6688'],
          'keywords': ['招商银行'],
        },
      };
      final a = Account.fromJson(json);
      expect(a.matchHints['last4'], ['6688']);
      expect(a.toJson(), json);
    });

    test('缺省字段有默认值', () {
      final a = Account.fromJson({'id': 'a2', 'name': '现金', 'kind': 'cash'});
      expect(a.initialBalanceCents, 0);
      expect(a.currency, 'CNY');
      expect(a.archived, isFalse);
      expect(a.matchHints, isEmpty);
    });
  });

  group('Fund', () {
    test('fromJson/toJson 往返', () {
      final json = {
        'id': 'f1',
        'name': '家庭公共',
        'kind': 'shared',
        'ownerMemberId': 'm1',
        'icon': 'home',
        'color': '#c36a4f',
        'targetCents': 500000,
        'monthlyBudgetCents': 200000,
        'description': '日常开销',
        'sortOrder': 1,
        'archived': false,
        'isDefault': true,
      };
      expect(Fund.fromJson(json).toJson(), json);
    });
  });

  group('Category', () {
    test('fromJson/toJson 往返', () {
      final json = {
        'id': 'c1',
        'name': '餐饮',
        'kind': 'expense',
        'parentId': 'c0',
        'icon': 'restaurant',
        'color': '#b07a20',
        'sortOrder': 0,
        'archived': false,
      };
      expect(Category.fromJson(json).toJson(), json);
    });
  });

  group('Transaction', () {
    final full = {
      'id': 't1',
      'clientId': '9f5b0c2e-0000-4000-8000-000000000001',
      'type': 'expense',
      'amountCents': 3250,
      'currency': 'CNY',
      'occurredAt': Dates.isoLocal(DateTime.utc(2026, 9, 12, 4, 30)),
      'accountId': 'a1',
      'toAccountId': 'a2',
      'fundId': 'f1',
      'toFundId': 'f2',
      'categoryId': 'c1',
      'memberId': 'm1',
      'merchant': '肯德基',
      'note': '午饭',
      'tags': ['外食'],
      'source': 'notification',
      'status': 'pending',
      'confidence': 0.92,
      'rawText': '支付宝支付 32.50 元',
      'sourceApp': 'com.eg.android.AlipayGphone',
      'captureId': 'cap1',
      'duplicateOfId': 't0',
      'createdBy': 'm1',
      'createdAt': Dates.isoLocal(DateTime.utc(2026, 9, 12, 4, 30, 1)),
      'updatedAt': Dates.isoLocal(DateTime.utc(2026, 9, 12, 4, 30, 2)),
      'deletedAt': Dates.isoLocal(DateTime.utc(2026, 9, 12, 4, 30, 3)),
      'seq': 42,
    };

    test('fromJson/toJson 往返（全字段）', () {
      final tx = Transaction.fromJson(full);
      expect(tx.occurredAt.toUtc().hour, 4);
      expect(tx.isDeleted, isTrue);
      expect(tx.toJson(), full);
    });

    test('时刻一律落成本地时间，UI 不用到处 toLocal()', () {
      final instant = DateTime.utc(2026, 9, 4, 17);
      final tx = Transaction.fromJson({
        'id': 't1',
        'clientId': 'c1',
        'type': 'expense',
        'amountCents': 100,
        // 服务端发的是「本地墙上时间 + 偏移」，解析出来默认是 UTC 实例。
        'occurredAt': Dates.isoLocal(instant),
      });
      expect(tx.occurredAt.isUtc, isFalse);
      expect(tx.occurredAt.isAtSameMomentAs(instant), isTrue);
      // 钟点就是本机墙上的钟点（时区无关的断言）。
      expect(tx.occurredAt.hour, instant.toLocal().hour);
      expect(tx.dayKey, Dates.isoDate(instant.toLocal()));
    });

    test('+08:00 的串不会被当成 UTC 存进缓存', () {
      final tx = Transaction.fromJson({
        'id': 't1',
        'clientId': 'c1',
        'type': 'expense',
        'amountCents': 100,
        'occurredAt': '2026-09-05T01:00:00+08:00',
      });
      final expected = DateTime.parse('2026-09-05T01:00:00+08:00').toLocal();
      expect(tx.occurredAt.hour, expected.hour);
      expect(tx.occurredAt.day, expected.day);
      // 缓存里回写的也带偏移，再读一次还是同一时刻。
      expect(
        Transaction.fromJson(tx.toJson()).occurredAt.isAtSameMomentAs(tx.occurredAt),
        isTrue,
      );
    });

    test('最小字段与默认值', () {
      final tx = Transaction.fromJson({
        'id': 't2',
        'clientId': 'cid2',
        'type': 'income',
        'amountCents': 100,
        'occurredAt': '2026-09-12T04:30:00.000Z',
      });
      expect(tx.currency, 'CNY');
      expect(tx.status, 'confirmed');
      expect(tx.source, 'manual');
      expect(tx.tags, isEmpty);
      expect(tx.isDeleted, isFalse);
      expect(tx.pendingSync, isFalse);
      expect(tx.toJson().containsKey('note'), isFalse);
    });

    test('pendingSync 是客户端字段，只在为真时序列化', () {
      final tx = Transaction.fromJson(full).copyWith(pendingSync: true);
      expect(tx.toJson()['pendingSync'], true);
      expect(Transaction.fromJson(tx.toJson()).pendingSync, isTrue);
    });

    test('signedAmountCents 支出为负、收入为正', () {
      final expense = Transaction.fromJson(full);
      expect(expense.signedAmountCents, -3250);
      final income = expense.copyWith(type: 'income');
      expect(income.signedAmountCents, 3250);
    });
  });

  group('TransactionDraft', () {
    test('toJson 含 clientId 且忽略空字段', () {
      final draft = TransactionDraft(
        clientId: 'cid-1',
        type: 'expense',
        amountCents: 1999,
        occurredAt: DateTime.utc(2026, 9, 12, 4, 30),
        fundId: 'f1',
        categoryId: 'c1',
        merchant: '便利店',
      );
      expect(draft.toJson(), {
        'clientId': 'cid-1',
        'type': 'expense',
        'amountCents': 1999,
        'currency': 'CNY',
        'occurredAt': Dates.isoLocal(DateTime.utc(2026, 9, 12, 4, 30)),
        'fundId': 'f1',
        'categoryId': 'c1',
        'merchant': '便利店',
        'source': 'manual',
        'status': 'confirmed',
        'tags': <String>[],
      });
    });

    test('toOptimisticTransaction 生成带 pendingSync 的本地流水', () {
      final draft = TransactionDraft(
        clientId: 'cid-2',
        type: 'expense',
        amountCents: 500,
        occurredAt: DateTime.utc(2026, 9, 12),
      );
      final tx = draft.toOptimisticTransaction();
      expect(tx.id, 'cid-2');
      expect(tx.pendingSync, isTrue);
      expect(tx.amountCents, 500);
    });
  });

  group('TxFilter', () {
    test('toQuery 只输出非空项', () {
      final f = TxFilter(
        from: DateTime.utc(2026, 9, 1),
        to: DateTime.utc(2026, 9, 30),
        type: 'expense',
        fundId: 'f1',
        q: '肯德基',
        limit: 50,
      );
      final q = f.toQuery();
      expect(q['from'], '2026-09-01');
      expect(q['to'], '2026-09-30');
      expect(q['type'], 'expense');
      expect(q['fundId'], 'f1');
      expect(q['q'], '肯德基');
      expect(q['limit'], '50');
      expect(q.containsKey('accountId'), isFalse);
    });

    test('空筛选器 isEmpty', () {
      expect(const TxFilter().isEmpty, isTrue);
      expect(const TxFilter(fundId: 'f1').isEmpty, isFalse);
    });
  });

  group('TxPage', () {
    test('fromJson 解析 items 与 nextCursor', () {
      final page = TxPage.fromJson({
        'items': [
          {
            'id': 't1',
            'clientId': 'c1',
            'type': 'expense',
            'amountCents': 100,
            'occurredAt': '2026-09-12T04:30:00.000Z',
          },
        ],
        'nextCursor': 'abc',
      });
      expect(page.items, hasLength(1));
      expect(page.nextCursor, 'abc');
      expect(page.hasMore, isTrue);
    });
  });

  group('Budget & Rule', () {
    test('Budget 往返', () {
      final json = {
        'id': 'b1',
        'scope': 'fund',
        'refId': 'f1',
        'month': '2026-09',
        'amountCents': 300000,
      };
      expect(Budget.fromJson(json).toJson(), json);
    });

    test('Rule 往返', () {
      final json = {
        'id': 'r1',
        'priority': 10,
        'field': 'merchant',
        'op': 'contains',
        'pattern': '肯德基',
        'categoryId': 'c1',
        'fundId': 'f1',
        'accountId': 'a1',
        'memberId': 'm1',
        'enabled': true,
      };
      expect(Rule.fromJson(json).toJson(), json);
    });
  });

  group('Stats', () {
    test('StatsOverview 解析嵌套结构', () {
      final o = StatsOverview.fromJson({
        'netWorthCents': 1000000,
        'assetsCents': 1200000,
        'liabilitiesCents': 200000,
        'month': {
          'expenseCents': 320000,
          'incomeCents': 900000,
          'byFund': [
            {'fundId': 'f1', 'expenseCents': 120000, 'incomeCents': 0},
          ],
          'byCategory': [
            {'categoryId': 'c1', 'expenseCents': 80000},
          ],
          'byMember': [
            {'memberId': 'm1', 'expenseCents': 200000},
          ],
          'budgets': [
            {
              'scope': 'fund',
              'refId': 'f1',
              'budgetCents': 200000,
              'spentCents': 120000,
            },
          ],
        },
        'pendingCount': 2,
        'funds': [
          {'fundId': 'f1', 'balanceCents': 500000},
        ],
        'accounts': [
          {'accountId': 'a1', 'balanceCents': 700000},
        ],
      });
      expect(o.netWorthCents, 1000000);
      expect(o.month.expenseCents, 320000);
      expect(o.month.byFund.single.fundId, 'f1');
      expect(o.month.budgets.single.ratio, closeTo(0.6, 1e-9));
      expect(o.pendingCount, 2);
      expect(o.fundBalance('f1'), 500000);
      expect(o.accountBalance('a1'), 700000);
      expect(o.fundBalance('nope'), 0);
    });

    test('TrendSeries 解析', () {
      final t = TrendSeries.fromJson({
        'series': [
          {'month': '2026-08', 'expenseCents': 100, 'incomeCents': 200},
          {'month': '2026-09', 'expenseCents': 300, 'incomeCents': 400},
        ],
      });
      expect(t.series, hasLength(2));
      expect(t.series.last.month, '2026-09');
      expect(t.maxCents, 400);
    });

    test('FundStats 解析', () {
      final s = FundStats.fromJson({
        'balanceCents': 123400,
        'targetCents': 500000,
        'monthExpenseCents': 20000,
        'monthIncomeCents': 0,
        'budgetCents': 30000,
        'byCategory': [
          {'categoryId': 'c1', 'expenseCents': 15000},
        ],
        'recent': [
          {
            'id': 't1',
            'clientId': 'c1',
            'type': 'expense',
            'amountCents': 100,
            'occurredAt': '2026-09-12T04:30:00.000Z',
          },
        ],
      });
      expect(s.balanceCents, 123400);
      expect(s.byCategory.single.expenseCents, 15000);
      expect(s.recent.single.id, 't1');
      expect(s.targetProgress, closeTo(0.2468, 1e-4));
    });
  });

  group('Settings', () {
    test('往返与默认值', () {
      final json = {
        'name': '我们家',
        'currency': 'CNY',
        'capture': {
          'defaultFundId': 'f1',
          'defaultAccountId': 'a1',
          'autoConfirmThreshold': 0.75,
          'llmFallback': false,
          'allowedApps': ['com.tencent.mm'],
        },
        'ui': {'firstDayOfMonth': 1},
      };
      final s = Settings.fromJson(json);
      expect(s.capture.autoConfirmThreshold, 0.75);
      expect(s.ui.firstDayOfMonth, 1);
      expect(s.toJson(), json);

      final empty = Settings.fromJson({});
      expect(empty.currency, 'CNY');
      expect(empty.capture.autoConfirmThreshold, 0.75);
      expect(empty.capture.allowedApps, isEmpty);
      expect(empty.ui.firstDayOfMonth, 1);
    });
  });

  group('AiProvider & BackupConfig', () {
    test('AiProvider 往返（密钥只读尾号）', () {
      final json = {
        'id': 'p1',
        'name': 'cc-trans',
        'kind': 'anthropic',
        'baseUrl': 'https://example.com',
        'model': 'claude-sonnet',
        'isDefault': true,
        'enabled': true,
        'hasKey': true,
        'keyTail': '9f3c',
        'extra': <String, dynamic>{},
      };
      expect(AiProvider.fromJson(json).toJson(), json);
    });

    test('BackupConfig 解析嵌套', () {
      final c = BackupConfig.fromJson({
        'webdav': {
          'url': 'https://dav.example.com',
          'username': 'u',
          'hasPassword': true,
          'remoteDir': '/famledger',
        },
        'schedule': {'enabled': true, 'hour': 3, 'keep': 14},
        'encryption': {'enabled': true, 'hasPassphrase': true},
        'lastRun': '2026-09-11T19:00:00.000Z',
      });
      expect(c.webdav.url, 'https://dav.example.com');
      expect(c.webdav.hasPassword, isTrue);
      expect(c.schedule.hour, 3);
      expect(c.encryption.enabled, isTrue);
      expect(c.lastRun, isNotNull);
    });
  });
}
