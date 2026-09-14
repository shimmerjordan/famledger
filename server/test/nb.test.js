'use strict';

// lib/nb.js — pure unit tests. No server, no database.
//
// This file is the executable half of the format contract with the Dart
// implementation (`app/lib/capture/naive_bayes.dart`): every expectation here
// is a literal the Dart port must reproduce character for character.

const test = require('node:test');
const assert = require('node:assert/strict');

const nb = require('../src/lib/nb');

// ① tokenizer ------------------------------------------------------------
test('① tokenize：1-gram + 2-gram，去空白/标点/符号，全角转半角', () => {
  // '美团 外卖¥35.00' → 归一化 '美团外卖3500'
  assert.deepEqual(nb.normalize('美团 外卖¥35.00'), '美团外卖3500');
  const t = nb.tokenize('美团 外卖¥35.00');
  assert.deepEqual(t, [
    // 1-gram
    '美', '团', '外', '卖', '3', '5', '0', '0',
    // 2-gram
    '美团', '团外', '外卖', '卖3', '35', '50', '00',
  ]);
  assert.ok(t.includes('美'), '必须含单字 1-gram');
  assert.ok(t.includes('美团'), '必须含相邻 2-gram');
  for (const tok of t) {
    assert.ok(!/[\s\p{P}\p{S}]/u.test(tok), `token ${JSON.stringify(tok)} 含空白或标点`);
  }
});

test('① tokenize：全角→半角、大写→小写、控制/变体字符不留残渣', () => {
  assert.equal(nb.normalize('ＡＢｃ－Ｄ　１２３'), 'abcd123');
  assert.equal(nb.normalize('滴滴出行 ￥18.5'), '滴滴出行185');
  assert.equal(nb.normalize('【工商银行】您尾号1234的卡'), '工商银行您尾号1234的卡');
  // ☕ 是符号(So)，其后的 U+FE0F 变体选择符是 Mn —— 两者都不得留下。
  assert.equal(nb.normalize('咖啡☕️x'), '咖啡x');
  assert.equal(nb.normalize('a_b'), 'ab');
  assert.equal(nb.normalize(''), '');
  assert.deepEqual(nb.tokenize('   ¥ . '), []);
});

test('① tokenize：单字符文本只有 1-gram；重复字符保留重复（多项式计数）', () => {
  assert.deepEqual(nb.tokenize('餐'), ['餐']);
  assert.deepEqual(nb.tokenize('aaa'), ['a', 'a', 'a', 'aa', 'aa']);
});

test('① tokenize：extras 原样追加在末尾', () => {
  const t = nb.tokenize('外卖', ['m:美团', 'dir:expense', 'ch:alipay', 'amt:b3', 'h:12', 'wd:5', 'mem:u1']);
  assert.deepEqual(t, ['外', '卖', '外卖', 'm:美团', 'dir:expense', 'ch:alipay', 'amt:b3', 'h:12', 'wd:5', 'mem:u1']);
  // extras 不走归一化：冒号、大小写、空格一律原样保留。
  assert.deepEqual(nb.tokenize('', ['m:7-ELEVEN 便利店']), ['m:7-ELEVEN 便利店']);
});

test('① extrasFor / amountBucket：顺序与分桶边界固定', () => {
  assert.deepEqual(
    nb.extrasFor({
      merchant: '美团', direction: 'expense', channel: 'alipay',
      amountCents: 3500, hour: 12, weekday: 5, memberId: 'u1',
    }),
    ['m:美团', 'dir:expense', 'ch:alipay', 'amt:b1', 'h:12', 'wd:5', 'mem:u1'],
  );
  assert.deepEqual(nb.extrasFor({ direction: 'income' }), ['dir:income']);
  assert.deepEqual(nb.extrasFor({}), []);
  assert.deepEqual(nb.extrasFor({ hour: 0, amountCents: 0 }), ['amt:b0', 'h:0']);
  assert.equal(nb.amountBucket(0), 0);
  assert.equal(nb.amountBucket(999), 0);
  assert.equal(nb.amountBucket(1000), 1);
  assert.equal(nb.amountBucket(4999), 1);
  assert.equal(nb.amountBucket(5000), 2);
  assert.equal(nb.amountBucket(19999), 2);
  assert.equal(nb.amountBucket(20000), 3);
  assert.equal(nb.amountBucket(99999), 3);
  assert.equal(nb.amountBucket(100000), 4);
  assert.equal(nb.amountBucket(123456789), 4);
});

// ② learn ----------------------------------------------------------------
test('② emptyModel + learn：docs/tokens/counts/totalDocs/vocab 全部按定义累加', () => {
  const m = nb.emptyModel();
  assert.deepEqual(JSON.parse(JSON.stringify(m)), { version: 1, classes: {}, vocab: 0, totalDocs: 0 });

  nb.learn(m, ['a', 'b', 'a'], 'X');
  assert.equal(m.classes.X.docs, 1);
  assert.equal(m.classes.X.tokens, 3);
  assert.deepEqual({ ...m.classes.X.counts }, { a: 2, b: 1 });
  assert.equal(m.totalDocs, 1);
  assert.equal(m.vocab, 2);

  nb.learn(m, ['b', 'c'], 'Y');
  assert.equal(m.totalDocs, 2);
  assert.equal(m.vocab, 3, 'vocab 是全体类别 token 的并集大小，b 不重复计');
  assert.equal(m.vocab, nb.vocabOf(m));

  // 空文档没有任何证据，连先验都不该动（Dart 参考实现在这里直接 return）。
  nb.learn(m, [], 'Y');
  assert.equal(m.classes.Y.docs, 1, '空样本不得计入 docs');
  assert.equal(m.classes.Y.tokens, 2);
  assert.equal(m.totalDocs, 2, '空样本不得计入 totalDocs');
  assert.equal(m.vocab, 3);
  // 连类别都不该被凭空创建出来
  nb.learn(m, [], '从没见过的类');
  assert.deepEqual(Object.keys(m.classes).sort(), ['X', 'Y']);
});

test('② learn：label 叫 __proto__ 也打不穿原型链', () => {
  const m = nb.emptyModel();
  nb.learn(m, nb.tokenize('abc'), '__proto__');
  nb.learn(m, nb.tokenize('xyz'), 'constructor');
  nb.learn(m, nb.tokenize('def'), 'toString');

  // 最关键的一条：全进程的 Object.prototype 必须干净
  assert.equal(Object.prototype.docs, undefined, 'Object.prototype 被写脏了');
  assert.equal(Object.prototype.tokens, undefined, 'Object.prototype 被写脏了');
  assert.equal(({}).docs, undefined);

  // 而且它们就是三个普普通通的类别
  assert.deepEqual(Object.keys(m.classes).sort(), ['__proto__', 'constructor', 'toString']);
  assert.equal(m.totalDocs, 3);
  assert.equal(m.vocab, nb.vocabOf(m));
  assert.equal(m.classes['__proto__'].docs, 1);

  // JSON 往返不会把 __proto__ 那一类吞掉
  const back = nb.parse(JSON.stringify(m));
  assert.deepEqual(Object.keys(back.classes).sort(), ['__proto__', 'constructor', 'toString']);
  assert.equal(back.classes['__proto__'].docs, 1);
  const top = nb.predict(m, nb.tokenize('abc'))[0];
  assert.equal(top.label, '__proto__');
  assert.ok(Number.isFinite(top.p));

  // merge 进一个手工搭的、带原型的 target 也不行
  const target = { version: 1, classes: {}, vocab: 0, totalDocs: 0 };
  nb.merge(target, m);
  assert.equal(Object.prototype.docs, undefined);
  assert.deepEqual(Object.keys(target.classes).sort(), ['__proto__', 'constructor', 'toString']);
  assert.equal(target.vocab, nb.vocabOf(target));
});

test('② learn：token 名撞上 Object.prototype 也不会串味', () => {
  const m = nb.emptyModel();
  nb.learn(m, ['__proto__', 'constructor', 'toString'], 'X');
  // 注意：字面量 `{__proto__: 1}` 是在设原型，不是自有属性，所以按 entries 断言。
  assert.deepEqual(Object.entries(m.classes.X.counts).sort(), [['__proto__', 1], ['constructor', 1], ['toString', 1]]);
  assert.equal(m.vocab, 3);
  const [top] = nb.predict(m, ['constructor']);
  assert.ok(Number.isFinite(top.p), 'p 必须是有限数，不能是 NaN');
});

// ③ predict --------------------------------------------------------------
test('③ 学 3 条样本后 predict 的 top 正确，且概率降序、和为 1', () => {
  const m = nb.emptyModel();
  nb.learn(m, nb.tokenize('美团外卖'), '餐饮');
  nb.learn(m, nb.tokenize('滴滴出行'), '交通');
  nb.learn(m, nb.tokenize('肯德基宅急送'), '餐饮');

  const p = nb.predict(m, nb.tokenize('美团外卖 30元'));
  assert.equal(p[0].label, '餐饮');
  assert.deepEqual(p.map((x) => x.label).sort(), ['交通', '餐饮']);
  for (let i = 1; i < p.length; i++) assert.ok(p[i - 1].p >= p[i].p, '必须按 p 降序');
  const sum = p.reduce((s, x) => s + x.p, 0);
  assert.ok(Math.abs(sum - 1) < 1e-12, `softmax 和应为 1，实得 ${sum}`);
  assert.ok(p[0].p > 0.5);

  assert.equal(nb.predict(m, nb.tokenize('滴滴打车'))[0].label, '交通');
});

test('③ 空模型 / 无类别 → []；未知 token 不会让概率变成 NaN', () => {
  assert.deepEqual(nb.predict(nb.emptyModel(), nb.tokenize('美团')), []);
  assert.deepEqual(nb.predict({ version: 1, classes: {}, vocab: 0, totalDocs: 0 }, ['a']), []);

  const m = nb.emptyModel();
  nb.learn(m, ['a'], 'X');
  nb.learn(m, ['b'], 'Y');
  const p = nb.predict(m, ['zzz', 'qqq']);
  assert.equal(p.length, 2);
  for (const x of p) assert.ok(Number.isFinite(x.p) && x.p > 0);
  assert.ok(Math.abs(p.reduce((s, x) => s + x.p, 0) - 1) < 1e-12);
});

test('③ p 相同时按 label 升序，保证跨语言实现输出同序', () => {
  const m = nb.emptyModel();
  nb.learn(m, ['a'], 'b类');
  nb.learn(m, ['a'], 'a类');
  const p = nb.predict(m, ['a']);
  assert.equal(p[0].p, p[1].p);
  assert.deepEqual(p.map((x) => x.label), ['a类', 'b类']);
});

// ④ 序列化往返 ------------------------------------------------------------
test('④ JSON 往返：字段齐全、预测逐位相同', () => {
  const m = nb.emptyModel();
  nb.learn(m, nb.tokenize('星巴克拿铁', ['ch:alipay', 'amt:b1']), '餐饮');
  nb.learn(m, nb.tokenize('地铁二号线', ['ch:unionpay']), '交通');

  const text = JSON.stringify(m);
  const back = nb.parse(text);
  assert.deepEqual(Object.keys(JSON.parse(text)).sort(), ['classes', 'totalDocs', 'version', 'vocab']);
  assert.equal(back.version, m.version);
  assert.equal(back.totalDocs, m.totalDocs);
  assert.equal(back.vocab, m.vocab);
  assert.deepEqual(JSON.parse(JSON.stringify(back)), JSON.parse(text));

  const q = nb.tokenize('星巴克');
  assert.deepEqual(nb.predict(back, q), nb.predict(m, q));

  // parse 也吃已解析的对象与垃圾输入
  assert.deepEqual(JSON.parse(JSON.stringify(nb.parse(JSON.parse(text)))), JSON.parse(text));
  assert.deepEqual(nb.parse('not json'), nb.emptyModel());
  assert.deepEqual(nb.parse(null), nb.emptyModel());
  assert.deepEqual(nb.parse('{"classes":{"X":{"docs":"x"}}}'), nb.emptyModel());
});

// ⑤ merge ----------------------------------------------------------------
test('⑤ merge：counts / docs / tokens / totalDocs 相加，vocab 取并集', () => {
  const a = nb.emptyModel();
  nb.learn(a, ['x', 'y'], 'A');

  const b = nb.emptyModel();
  nb.learn(b, ['y', 'z'], 'A');
  nb.learn(b, ['w'], 'B');

  const out = nb.merge(a, b);
  assert.equal(out, a, 'merge 就地改写 target 并返回它');
  assert.equal(a.classes.A.docs, 2);
  assert.equal(a.classes.A.tokens, 4);
  assert.deepEqual({ ...a.classes.A.counts }, { x: 1, y: 2, z: 1 });
  assert.deepEqual({ ...a.classes.B.counts }, { w: 1 });
  assert.equal(a.classes.B.docs, 1);
  assert.equal(a.totalDocs, 3);
  assert.equal(a.vocab, 4);
  assert.equal(a.vocab, nb.vocabOf(a));
  assert.equal(a.version, 1, 'merge 不碰 version，版本号归调用方管');

  // merge 等价于把同样的样本逐条 learn 进去
  const direct = nb.emptyModel();
  nb.learn(direct, ['x', 'y'], 'A');
  nb.learn(direct, ['y', 'z'], 'A');
  nb.learn(direct, ['w'], 'B');
  assert.deepEqual(JSON.parse(JSON.stringify(a)), JSON.parse(JSON.stringify(direct)));

  // delta 不被改动
  assert.equal(b.classes.A.docs, 1);
  assert.equal(b.totalDocs, 2);
});

// ⑥ OOV ------------------------------------------------------------------
test('⑥ predict 只对词表内的 token 计分，词表外的一律丢弃', () => {
  const m = nb.emptyModel();
  nb.learn(m, nb.tokenize('美团外卖'), '餐饮');
  nb.learn(m, nb.tokenize('滴滴出行'), '交通');

  const base = nb.predict(m, nb.tokenize('美团'));
  // 掺进一堆模型从没见过的 token，概率必须一位不差
  const noisy = nb.predict(m, [...nb.tokenize('美团'), 'zzz', 'qqq', '§', 'dir:expense', 'mem:u1']);
  assert.deepEqual(noisy, base, '词表外 token 不得影响任何一个后验概率');

  // 顺序无关：OOV 插在中间也一样
  assert.deepEqual(nb.predict(m, ['zzz', ...nb.tokenize('美团'), 'qqq']), base);

  // 全是 OOV → 退回纯先验
  const oov = nb.predict(m, ['zzz', 'qqq']);
  const prior = nb.predict(m, []);
  assert.deepEqual(oov, prior);
});

test('⑥ 长文本不再因为「类别 token 少」而跑偏（OOV 规则要挡住的就是这个）', () => {
  const m = nb.emptyModel();
  // 「餐饮」样本多、token 多；「转账收入」样本少、token 少
  for (const t of ['美团外卖', '肯德基', '麦当劳', '星巴克咖啡', '海底捞火锅']) nb.learn(m, nb.tokenize(t), '餐饮');
  nb.learn(m, nb.tokenize('转账'), '转账收入');

  const long = '你在【麦当劳（北京王府井店）】消费了58.50元，交易流水号 20260912120100888';
  assert.equal(nb.predict(m, nb.tokenize(long))[0].label, '餐饮');
});

test('⑥ 计分用的是实时并集大小，存量 vocab 字段写错也不影响预测', () => {
  const m = nb.emptyModel();
  nb.learn(m, nb.tokenize('美团外卖'), '餐饮');
  nb.learn(m, nb.tokenize('滴滴出行'), '交通');
  const good = nb.predict(m, nb.tokenize('美团'));

  const tampered = nb.parse(JSON.stringify({ ...m, vocab: 999999 }));
  assert.equal(tampered.vocab, 999999, 'parse 原样保留写错的 vocab');
  assert.deepEqual(nb.predict(tampered, nb.tokenize('美团')), good);
});
