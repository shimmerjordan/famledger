import 'package:famledger/capture/capture_types.dart';
import 'package:famledger/capture/classifier.dart';
import 'package:famledger/capture/naive_bayes.dart';
import 'package:famledger/capture/parser.dart';
import 'package:famledger/capture/seed_dataset.dart';
import 'package:flutter_test/flutter_test.dart';

List<ClassifierCandidate> _categories() => kSeedCategoryNames
    .map((n) => ClassifierCandidate(id: 'cat-$n', name: n))
    .toList();

final _funds = <ClassifierCandidate>[
  const ClassifierCandidate(id: 'fund-public', name: '家庭公共基金'),
  const ClassifierCandidate(
      id: 'fund-pet', name: '宠物基金', aliases: <String>['宠物', '猫主子']),
];

ParsedPayment _payment({
  String merchant = '美团',
  PayDirection direction = PayDirection.expense,
  String channel = 'alipay',
  int amountCents = 3500,
  String? cardTail,
  String sourceApp = 'com.eg.android.AlipayGphone',
  double parseConfidence = 0.92,
}) =>
    ParsedPayment(
      amountCents: amountCents,
      direction: direction,
      merchant: merchant,
      channel: channel,
      cardTail: cardTail,
      occurredAt: DateTime(2026, 9, 12, 12, 30),
      parseConfidence: parseConfidence,
      isPayment: true,
      sourceApp: sourceApp,
    );

Classifier _classifier({
  List<CaptureRule> rules = const <CaptureRule>[],
  List<CaptureAccount> accounts = const <CaptureAccount>[],
  NaiveBayes? categoryModel,
  NaiveBayes? fundModel,
  String? defaultFundId = 'fund-public',
  String? defaultAccountId = 'acc-default',
}) =>
    Classifier(
      categoryModel: categoryModel ?? NaiveBayes.empty(),
      fundModel: fundModel ?? NaiveBayes.empty(),
      rules: rules,
      categories: _categories(),
      funds: _funds,
      accounts: accounts,
      defaultFundId: defaultFundId,
      defaultAccountId: defaultAccountId,
    );

void main() {
  group('种子数据集', () {
    test('至少 300 条且类别齐全', () {
      expect(kCaptureSeedSamples.length, greaterThanOrEqualTo(300));
      expect(kSeedCategoryNames.length, greaterThanOrEqualTo(20));
      for (final name in <String>[
        '餐饮', '交通', '购物', '居家', '水电', '通讯', '医疗', '教育', '育儿',
        '宠物', '娱乐', '人情', '旅行', '保险', '其他',
        '工资', '奖金', '理财', '退款', '转账收入',
      ]) {
        expect(kSeedCategoryNames, contains(name));
        expect(
          kCaptureSeedSamples.where((s) => s.category == name).length,
          greaterThanOrEqualTo(10),
          reason: '$name 样本数',
        );
      }
    });

    test('样本类别全部在类别名单内，且不含 id', () {
      for (final s in kCaptureSeedSamples) {
        expect(kSeedCategoryNames, contains(s.category));
        expect(s.text.trim(), isNotEmpty);
      }
    });

    test('种子训练把类别名映射成候选 id', () {
      final model = NaiveBayes.empty();
      trainSeedCategoryModel(model, _categories());
      expect(model.totalDocs, kCaptureSeedSamples.length);
      final preds = model.predict(NaiveBayes.tokenize('美团外卖'));
      expect(preds.first.label, 'cat-餐饮');
    });

    test('候选别名也能匹配种子类别名', () {
      final model = NaiveBayes.empty();
      trainSeedCategoryModel(model, <ClassifierCandidate>[
        const ClassifierCandidate(
            id: 'c1', name: '吃饭', aliases: <String>['餐饮']),
      ]);
      expect(model.totalDocs,
          kCaptureSeedSamples.where((s) => s.category == '餐饮').length);
      expect(model.predict(NaiveBayes.tokenize('肯德基')).first.label, 'c1');
    });
  });

  group('规则优先', () {
    test('命中规则 → 规则字段满信，整体仍受 parseConfidence 限制', () {
      final c = _classifier(rules: <CaptureRule>[
        const CaptureRule(
          id: 'r1',
          priority: 10,
          field: 'merchant',
          op: 'contains',
          pattern: '美团',
          categoryId: 'cat-餐饮',
          fundId: 'fund-public',
        ),
      ]);
      final r = c.classify(ClassifyInput(
          payment: _payment(), rawText: '你有一笔35.00元的支出，来自美团'));
      expect(r.categoryId, 'cat-餐饮');
      expect(r.fundId, 'fund-public');
      // 类别与基金都由规则钉死（各 1.0），整体取 min(parseConfidence, 1, 1)
      expect(r.confidence, 0.92);
      expect(r.reason, 'rule:r1');
    });

    test('优先级高的规则先命中', () {
      final c = _classifier(rules: <CaptureRule>[
        const CaptureRule(
            id: 'low',
            priority: 1,
            field: 'text',
            op: 'contains',
            pattern: '美团',
            categoryId: 'cat-其他'),
        const CaptureRule(
            id: 'high',
            priority: 99,
            field: 'text',
            op: 'contains',
            pattern: '美团',
            categoryId: 'cat-餐饮'),
      ]);
      final r = c.classify(
          ClassifyInput(payment: _payment(), rawText: '来自美团'));
      expect(r.categoryId, 'cat-餐饮');
      expect(r.reason, 'rule:high');
    });

    test('regex 规则与 app 字段', () {
      final c = _classifier(rules: <CaptureRule>[
        const CaptureRule(
            id: 'rx',
            priority: 5,
            field: 'text',
            op: 'regex',
            pattern: r'地铁|公交',
            categoryId: 'cat-交通'),
        const CaptureRule(
            id: 'app',
            priority: 1,
            field: 'app',
            op: 'contains',
            pattern: 'com.unionpay',
            accountId: 'acc-union'),
      ]);
      expect(
        c
            .classify(ClassifyInput(
                payment: _payment(merchant: ''), rawText: '地铁乘车码扣费 3.00元'))
            .categoryId,
        'cat-交通',
      );
      expect(
        c
            .classify(ClassifyInput(
                payment: _payment(sourceApp: 'com.unionpay'),
                rawText: '消费128.00元'))
            .accountId,
        'acc-union',
      );
    });

    test('只指定账户的规则不会把低置信的类别抬过阈值（逐字段置信度）', () {
      final model = NaiveBayes.empty();
      trainSeedCategoryModel(model, _categories());
      final c = _classifier(
        categoryModel: model,
        rules: <CaptureRule>[
          const CaptureRule(
            id: 'acc-only',
            priority: 10,
            field: 'app',
            op: 'contains',
            pattern: 'com.eg.android.AlipayGphone',
            accountId: 'acc-alipay',
          ),
        ],
      );
      final r = c.classify(ClassifyInput(
          payment: _payment(merchant: '美团'), rawText: '你有一笔35.00元的支出，来自美团'));
      expect(r.accountId, 'acc-alipay');
      expect(r.categoryId, 'cat-餐饮');
      expect(r.confidence, lessThan(0.75), reason: '类别仍然来自低后验的模型');
      expect(r.reason, 'rule:acc-only+nb');
    });

    test('规则钉死类别时才是满信', () {
      final model = NaiveBayes.empty();
      trainSeedCategoryModel(model, _categories());
      final c = _classifier(
        categoryModel: model,
        rules: <CaptureRule>[
          const CaptureRule(
            id: 'cat-rule',
            priority: 10,
            field: 'merchant',
            op: 'contains',
            pattern: '美团',
            categoryId: 'cat-餐饮',
          ),
        ],
      );
      final r = c.classify(ClassifyInput(
          payment: _payment(merchant: '美团'), rawText: '来自美团'));
      expect(r.confidence, 0.92, reason: 'min(parseConfidence, 1.0, 1.0)');
      expect(r.reason, 'rule:cat-rule');
    });

    test('基金模型给出低后验时也会拉低整体置信度', () {
      final categoryModel = NaiveBayes.empty();
      trainSeedCategoryModel(categoryModel, _categories());
      final fundModel = NaiveBayes.empty();
      fundModel.learn(NaiveBayes.tokenize('滴滴出行'), 'fund-public');
      fundModel.learn(NaiveBayes.tokenize('滴滴出行'), 'fund-pet');
      final c = _classifier(
          categoryModel: categoryModel, fundModel: fundModel);
      final r = c.classify(ClassifyInput(
          payment: _payment(merchant: '滴滴出行'),
          rawText: '交易成功 ¥45.00 商户：滴滴出行'));
      expect(r.confidence, lessThanOrEqualTo(0.5), reason: '两个基金五五开');
    });

    test('停用的规则不参与匹配', () {
      final c = _classifier(rules: <CaptureRule>[
        const CaptureRule(
            id: 'off',
            priority: 10,
            field: 'merchant',
            op: 'contains',
            pattern: '美团',
            categoryId: 'cat-餐饮',
            enabled: false),
      ]);
      final r = c.classify(
          ClassifyInput(payment: _payment(), rawText: '来自美团'));
      expect(r.reason, isNot(startsWith('rule:')));
    });
  });

  group('朴素贝叶斯分类', () {
    test('confidence = min(parseConfidence, topP)，reason=nb', () {
      final model = NaiveBayes.empty();
      trainSeedCategoryModel(model, _categories());
      final c = _classifier(categoryModel: model);
      final r = c.classify(ClassifyInput(
        payment: _payment(merchant: '滴滴出行', parseConfidence: 0.92),
        rawText: '交易成功 ¥45.00 商户：滴滴出行',
      ));
      expect(r.categoryId, 'cat-交通');
      expect(r.reason, 'nb');
      // topP≈0.99 → 取 parseConfidence
      expect(r.confidence, 0.92);

      final low = c.classify(ClassifyInput(
        payment: _payment(merchant: '滴滴出行', parseConfidence: 0.3),
        rawText: '交易成功 ¥45.00 商户：滴滴出行',
      ));
      expect(low.confidence, 0.3);
    });

    test('短商户在种子模型下证据不足 → 置信度低（等用户确认后再学）', () {
      final model = NaiveBayes.empty();
      trainSeedCategoryModel(model, _categories());
      final c = _classifier(categoryModel: model);
      final input = ClassifyInput(
          payment: _payment(merchant: '美团'), rawText: '你有一笔35.00元的支出，来自美团');
      final r = c.classify(input);
      expect(r.categoryId, 'cat-餐饮'); // 方向对
      expect(r.confidence, lessThan(0.75)); // 但不足以自动入账
      // 用户确认一次后，同一商户+场景立刻变得笃定
      c.learn(input, categoryId: 'cat-餐饮');
      expect(c.classify(input).confidence, greaterThan(0.9));
    });

    test('空模型 → reason=default，confidence=0，回落默认基金/账户', () {
      final c = _classifier();
      final r = c.classify(
          ClassifyInput(payment: _payment(), rawText: '来自美团'));
      expect(r.categoryId, isNull);
      expect(r.reason, 'default');
      expect(r.confidence, 0.0);
      expect(r.fundId, 'fund-public');
      expect(r.accountId, 'acc-default');
    });

    test('基金模型可独立预测', () {
      final fundModel = NaiveBayes.empty();
      for (var i = 0; i < 5; i++) {
        fundModel.learn(NaiveBayes.tokenize('宠物医院猫粮'), 'fund-pet');
        fundModel.learn(NaiveBayes.tokenize('美团外卖'), 'fund-public');
      }
      final c = _classifier(fundModel: fundModel);
      final r = c.classify(ClassifyInput(
          payment: _payment(merchant: '宠物医院'), rawText: '宠物医院消费200.00元'));
      expect(r.fundId, 'fund-pet');
    });

    test('learn 之后分类结果随之改变', () {
      final model = NaiveBayes.empty();
      trainSeedCategoryModel(model, _categories());
      final c = _classifier(categoryModel: model);
      final input = ClassifyInput(
          payment: _payment(merchant: '张记杂货'), rawText: '向张记杂货付款12.00元');
      // 基金模型要有两个类别才可信（单类模型是常量分类器）
      c.learn(
          ClassifyInput(payment: _payment(merchant: '滴滴出行'), rawText: '滴滴出行'),
          fundId: 'fund-public');
      c.learn(
          ClassifyInput(payment: _payment(merchant: '滴滴出行'), rawText: '滴滴出行'),
          fundId: 'fund-public');
      for (var i = 0; i < 8; i++) {
        c.learn(input, categoryId: 'cat-宠物', fundId: 'fund-pet');
      }
      final r = c.classify(input);
      expect(r.categoryId, 'cat-宠物');
      expect(r.fundId, 'fund-pet');
    });
  });

  group('薄模型不可信（真机：一次纠正后基金模型只剩一个类别）', () {
    ClassifyInput input() => ClassifyInput(
        payment: _payment(merchant: '滴滴出行'),
        rawText: '交易成功 ¥45.00 商户：滴滴出行');

    test('单类基金模型 → 用默认基金，置信度 ≤ 0.5', () {
      final categoryModel = NaiveBayes.empty();
      trainSeedCategoryModel(categoryModel, _categories());
      final fundModel = NaiveBayes.empty();
      // 用户改过一次「宠物基金」，模型从此对任何输入都返回 p=1.0
      fundModel.learn(NaiveBayes.tokenize('宠物医院'), 'fund-pet');
      expect(fundModel.predict(NaiveBayes.tokenize('滴滴出行')).first.p, 1.0);
      expect(fundModel.isReliable, isFalse);

      final c =
          _classifier(categoryModel: categoryModel, fundModel: fundModel);
      final r = c.classify(input());
      expect(r.fundId, 'fund-public', reason: '不能跟着单类模型走');
      expect(r.confidence, lessThanOrEqualTo(kThinModelConfidenceCap));
      expect(r.reason, 'nb', reason: '类别仍来自可信的类别模型');
    });

    test('样本不足（2 类但只有 2 条）也不可信', () {
      final fundModel = NaiveBayes.empty();
      fundModel.learn(NaiveBayes.tokenize('宠物医院'), 'fund-pet');
      fundModel.learn(NaiveBayes.tokenize('滴滴出行'), 'fund-travel');
      expect(fundModel.classCount, 2);
      expect(fundModel.totalDocs, 2);
      expect(fundModel.isReliable, isFalse);

      final categoryModel = NaiveBayes.empty();
      trainSeedCategoryModel(categoryModel, _categories());
      final r = _classifier(categoryModel: categoryModel, fundModel: fundModel)
          .classify(input());
      expect(r.fundId, 'fund-public');
      expect(r.confidence, lessThanOrEqualTo(kThinModelConfidenceCap));
    });

    test('两个类别 + 足够样本 → 正常用后验', () {
      final categoryModel = NaiveBayes.empty();
      trainSeedCategoryModel(categoryModel, _categories());
      final fundModel = NaiveBayes.empty();
      fundModel.learn(NaiveBayes.tokenize('滴滴出行'), 'fund-travel');
      fundModel.learn(NaiveBayes.tokenize('滴滴出行'), 'fund-travel');
      fundModel.learn(NaiveBayes.tokenize('宠物医院猫粮'), 'fund-pet');
      expect(fundModel.isReliable, isTrue);

      final r = _classifier(categoryModel: categoryModel, fundModel: fundModel)
          .classify(input());
      expect(r.fundId, 'fund-travel');
      expect(r.confidence, greaterThan(kThinModelConfidenceCap));
    });

    test('单基金家庭：薄模型指向的就是默认基金 → 不压低置信度', () {
      final categoryModel = NaiveBayes.empty();
      trainSeedCategoryModel(categoryModel, _categories());
      final fundModel = NaiveBayes.empty();
      fundModel.learn(NaiveBayes.tokenize('滴滴出行'), 'fund-public');
      expect(fundModel.isReliable, isFalse);

      final r = _classifier(categoryModel: categoryModel, fundModel: fundModel)
          .classify(input());
      expect(r.fundId, 'fund-public');
      expect(r.confidence, 0.92, reason: '结果和默认值一样，没什么可问用户的');
    });

    test('空基金模型仍然直接用默认基金（不是「不可信」，是「还没学过」）', () {
      final categoryModel = NaiveBayes.empty();
      trainSeedCategoryModel(categoryModel, _categories());
      final r = _classifier(categoryModel: categoryModel).classify(input());
      expect(r.fundId, 'fund-public');
      expect(r.confidence, 0.92);
    });

    test('薄类别模型 → 不给类别，整条进待确认', () {
      final categoryModel = NaiveBayes.empty();
      categoryModel.learn(NaiveBayes.tokenize('滴滴出行'), 'cat-交通');
      expect(categoryModel.predict(NaiveBayes.tokenize('宠物医院')).first.p, 1.0);

      final r = _classifier(categoryModel: categoryModel).classify(input());
      expect(r.categoryId, isNull);
      expect(r.confidence, 0.0);
      expect(r.reason, 'default');
    });

    test('规则仍然压得住薄模型', () {
      final categoryModel = NaiveBayes.empty();
      categoryModel.learn(NaiveBayes.tokenize('宠物医院'), 'cat-宠物');
      final c = _classifier(
        categoryModel: categoryModel,
        rules: <CaptureRule>[
          const CaptureRule(
              id: 'r-taxi',
              priority: 5,
              field: 'merchant',
              op: 'contains',
              pattern: '滴滴',
              categoryId: 'cat-交通'),
        ],
      );
      final r = c.classify(input());
      expect(r.categoryId, 'cat-交通');
      expect(r.confidence, 0.92);
      expect(r.reason, 'rule:r-taxi');
    });
  });

  group('账户匹配', () {
    final accounts = <CaptureAccount>[
      const CaptureAccount(
        id: 'acc-cmb',
        name: '招行信用卡',
        kind: 'credit',
        matchHints: <String, dynamic>{
          'cardTails': <String>['1234'],
          'keywords': <String>['招商银行'],
        },
      ),
      const CaptureAccount(
        id: 'acc-alipay',
        name: '支付宝余额',
        kind: 'wallet',
        matchHints: <String, dynamic>{
          'packages': <String>['com.eg.android.AlipayGphone'],
        },
      ),
    ];

    test('卡尾号优先', () {
      final c = _classifier(accounts: accounts);
      final r = c.classify(ClassifyInput(
        payment: _payment(cardTail: '1234', sourceApp: 'com.miui.mms'),
        rawText: '【招商银行】您尾号1234的信用卡消费35.00元',
      ));
      expect(r.accountId, 'acc-cmb');
    });

    test('关键词次之', () {
      final c = _classifier(accounts: accounts);
      final r = c.classify(ClassifyInput(
        payment: _payment(sourceApp: 'com.miui.mms'),
        rawText: '【招商银行】消费35.00元',
      ));
      expect(r.accountId, 'acc-cmb');
    });

    test('包名兜底', () {
      final c = _classifier(accounts: accounts);
      final r = c.classify(ClassifyInput(
          payment: _payment(), rawText: '你有一笔35.00元的支出，来自美团'));
      expect(r.accountId, 'acc-alipay');
    });

    test('都不匹配用默认账户', () {
      final c = _classifier(accounts: accounts);
      final r = c.classify(ClassifyInput(
          payment: _payment(sourceApp: 'com.foo'), rawText: '消费35.00元'));
      expect(r.accountId, 'acc-default');
    });
  });

  group('特征抽取', () {
    test('extras 覆盖商户/方向/渠道/金额桶/小时/星期/成员', () {
      final extras = Classifier.featureExtras(ClassifyInput(
        payment: _payment(amountCents: 3500),
        rawText: '来自美团',
        memberId: 'm1',
      ));
      expect(extras, contains('m:美团'));
      expect(extras, contains('dir:expense'));
      expect(extras, contains('ch:alipay'));
      expect(extras, contains('amt:b1'));
      expect(extras, contains('h:12'));
      expect(extras, contains('wd:6'));
      expect(extras, contains('mem:m1'));
    });

    test('空值与 unknown 不产生特征 token（与服务端 extrasFor 一致）', () {
      final extras = Classifier.featureExtras(ClassifyInput(
        payment: _payment(
          merchant: '',
          direction: PayDirection.unknown,
          channel: 'unknown',
        ),
        rawText: '交易 ¥15.00',
      ));
      expect(extras.any((e) => e.startsWith('ch:')), isFalse);
      expect(extras.any((e) => e.startsWith('dir:')), isFalse);
      expect(extras.any((e) => e.startsWith('m:')), isFalse);
      expect(extras.any((e) => e.startsWith('mem:')), isFalse);
      // 金额桶/小时/星期恒有
      expect(extras.where((e) => e.startsWith('amt:')), hasLength(1));
      expect(extras.where((e) => e.startsWith('h:')), hasLength(1));
      expect(extras.where((e) => e.startsWith('wd:')), hasLength(1));
    });

    test('CaptureFeatures 的 JSON 就是 /model/learn 的字段', () {
      final features = CaptureFeatures.of(ClassifyInput(
        payment: _payment(amountCents: 3500),
        rawText: '来自美团',
        memberId: 'm1',
      ));
      expect(features.toJson(), <String, dynamic>{
        'merchant': '美团',
        'direction': 'expense',
        'channel': 'alipay',
        'amountCents': 3500,
        'hour': 12,
        'weekday': 6,
        'memberId': 'm1',
      });
      final bare = CaptureFeatures.of(ClassifyInput(
        payment: _payment(
            merchant: '', direction: PayDirection.unknown, channel: 'unknown'),
        rawText: '',
      ));
      expect(bare.toJson().containsKey('channel'), isFalse);
      expect(bare.toJson().containsKey('direction'), isFalse);
      expect(CaptureFeatures.fromJson(features.toJson()).extras,
          features.extras);
    });

    test('金额桶边界', () {
      String bucket(int cents) => Classifier.featureExtras(ClassifyInput(
            payment: _payment(amountCents: cents),
            rawText: '',
          )).firstWhere((e) => e.startsWith('amt:'));
      expect(bucket(999), 'amt:b0');
      expect(bucket(1000), 'amt:b1');
      expect(bucket(4999), 'amt:b1');
      expect(bucket(5000), 'amt:b2');
      expect(bucket(19999), 'amt:b2');
      expect(bucket(20000), 'amt:b3');
      expect(bucket(99999), 'amt:b3');
      expect(bucket(100000), 'amt:b4');
    });
  });
}
