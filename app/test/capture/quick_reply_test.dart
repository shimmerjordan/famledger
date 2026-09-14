import 'package:famledger/capture/classifier.dart';
import 'package:famledger/capture/quick_reply.dart';
import 'package:flutter_test/flutter_test.dart';

const _funds = <ClassifierCandidate>[
  ClassifierCandidate(id: 'fund-public', name: '家庭公共基金', aliases: <String>['公共']),
  ClassifierCandidate(id: 'fund-pet', name: '宠物基金', aliases: <String>['猫主子']),
  ClassifierCandidate(id: 'fund-travel', name: '旅行基金'),
];

const _categories = <ClassifierCandidate>[
  ClassifierCandidate(id: 'cat-food', name: '餐饮', aliases: <String>['吃饭']),
  ClassifierCandidate(id: 'cat-pet', name: '宠物'),
  ClassifierCandidate(id: 'cat-traffic', name: '交通'),
];

QuickReplyPatch _interpret(String text) => const QuickReplyInterpreter()
    .interpret(text, funds: _funds, categories: _categories);

void main() {
  group('QuickReplyInterpreter', () {
    test('基金名前缀「宠物」→ 宠物基金', () {
      final p = _interpret('宠物');
      expect(p.fundId, 'fund-pet');
      expect(p.categoryId, isNull);
      expect(p.note, isNull);
    });

    test('基金全名与别名', () {
      expect(_interpret('旅行基金').fundId, 'fund-travel');
      expect(_interpret('猫主子').fundId, 'fund-pet');
      expect(_interpret('公共').fundId, 'fund-public');
    });

    test('整条回复是数字，或数字带钱的标记 → 改金额', () {
      expect(_interpret('35').amountCents, 3500);
      expect(_interpret('35.5').amountCents, 3550);
      expect(_interpret(' 35 ').amountCents, 3500);
      expect(_interpret('¥12.34').amountCents, 1234);
      expect(_interpret('12元').amountCents, 1200);
      expect(_interpret('1,299').amountCents, 129900);
      expect(_interpret('改成 88 元').amountCents, 8800); // 被拆开的「元」会被吃掉
    });

    test('没有独立数字段时不当金额（改完是直接确认落库的）', () {
      for (final text in <String>[
        '给猫买2袋粮',
        '9月12日的午饭',
        '买了3个',
        '备注-3',
      ]) {
        final p = _interpret(text);
        expect(p.amountCents, isNull, reason: text);
        expect(p.note, text, reason: text);
      }
    });

    test('「收入」→ type income，「支出」/「转账」同理', () {
      expect(_interpret('收入').type, 'income');
      expect(_interpret('支出').type, 'expense');
      expect(_interpret('转账').type, 'transfer');
      expect(_interpret('收入').note, isNull);
    });

    test('其余文本 → 备注', () {
      final p = _interpret('给猫买粮');
      expect(p.note, '给猫买粮');
      expect(p.fundId, isNull);
      expect(p.amountCents, isNull);
      expect(p.type, isNull);
    });

    test('类别名命中 → categoryId', () {
      expect(_interpret('餐饮').categoryId, 'cat-food');
      expect(_interpret('吃饭').categoryId, 'cat-food');
    });

    test('基金优先于同名类别', () {
      final p = _interpret('宠物');
      expect(p.fundId, 'fund-pet');
      expect(p.categoryId, isNull);
    });

    test('混合输入：基金 + 金额 + 备注', () {
      for (final text in <String>['宠物 35 给猫买粮', '宠物 35元 给猫买粮']) {
        final p = _interpret(text);
        expect(p.fundId, 'fund-pet', reason: text);
        expect(p.amountCents, 3500, reason: text);
        expect(p.note, '给猫买粮', reason: text);
      }
    });

    test('分段切法：千分位不被逗号切开，中文标点是分隔符', () {
      expect(_interpret('1,299').amountCents, 129900);
      expect(_interpret('宠物，35，给猫买粮').note, '给猫买粮');
      expect(_interpret('宠物，35，给猫买粮').amountCents, 3500);
    });

    test('混合输入：类别 + 方向 + 备注', () {
      final p = _interpret('交通 收入 报销的打车费');
      expect(p.categoryId, 'cat-traffic');
      expect(p.type, 'income');
      expect(p.note, '报销的打车费');
    });

    test('空文本 → 空补丁', () {
      final p = _interpret('   ');
      expect(p.isEmpty, isTrue);
      expect(p.note, isNull);
    });

    test('isEmpty 只在毫无修改时为真', () {
      expect(_interpret('宠物').isEmpty, isFalse);
      expect(_interpret('随便写点什么').isEmpty, isFalse);
    });

    test('金额为 0 不识别为金额', () {
      expect(_interpret('0').amountCents, isNull);
      expect(_interpret('0元').amountCents, isNull);
    });
  });
}
