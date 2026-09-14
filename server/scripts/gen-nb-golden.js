'use strict';

// Regenerate `test/fixtures/nb_golden.json`:
//
//   node scripts/gen-nb-golden.js
//
// The fixture is the cross-language regression lock between `src/lib/nb.js` and
// `app/lib/capture/naive_bayes.dart`. Both sides load it and must reproduce the
// same tokens (exactly) and the same posteriors (to 1e-6). Regenerate it ONLY
// when a tokenizer or scoring change is deliberate and the Dart side is being
// changed with it — a diff here is the alarm, not the noise.
//
// Zero dependencies, deterministic: same inputs → byte-identical output.

const fs = require('node:fs');
const path = require('node:path');

const nb = require('../src/lib/nb');

const OUT = path.join(__dirname, '..', 'test', 'fixtures', 'nb_golden.json');

/** Appended to every string. Deliberately OOV — see `notes` below. */
const EXTRAS = ['m:美团', 'dir:expense'];

/** The model under test. Trained with `learn(tokenize(text), label)`, no extras. */
const TRAINING = [
  { text: '美团外卖 订单支付', label: '餐饮' },
  { text: '麦当劳 甜品站', label: '餐饮' },
  { text: '星巴克咖啡 拿铁', label: '餐饮' },
  { text: '滴滴出行 行程费用', label: '交通' },
  { text: '宠物医院 疫苗 260元', label: '宠物' },
  { text: '转账收入 来自张三', label: '转账收入' },
];

const STRINGS = [
  // ── the 10 the controller pinned ──────────────────────────────────────
  '美团 外卖¥35.00',
  '你在【麦当劳（北京王府井店）】消费了58.50元',
  '【招商银行】您账户1234于09月12日12:01在美团消费人民币35.00元，可用余额1,234.56元',
  '微信支付凭证 已支付￥１２０.００ 商户：星巴克☕️',
  'Apple Store 购买 AirPods Pro ¥1,899.00',
  'ＵＮＩＱＬＯ优衣库  T恤 99元',
  '转账收入200元 来自 张三',
  '宠物医院-疫苗 260元',
  '滴滴出行 早高峰 23.8 元',
  'Ｈello—World “引号” …省略号',
  // ── bank SMS ──────────────────────────────────────────────────────────
  '【工商银行】您尾号6789的储蓄卡9月12日20:15支出人民币128.00元，余额8,888.88元',
  '【建设银行】您账户9012于2026年09月12日入账工资5,000.00元',
  '【交通银行】您的信用卡账单已出，应还款2,345.67元，还款日09月25日',
  // ── WeChat / Alipay ───────────────────────────────────────────────────
  '微信支付 收款到账 12.00元',
  '你已成功向 李四 转账 500.00 元',
  '支付宝成功付款￥６６．６６ 商户 全家便利店',
  // ── English brands + emoji ────────────────────────────────────────────
  'Starbucks Coffee 星巴克 ¥38.00',
  'KFC肯德基宅急送 订单 ¥45.00 🍗',
  '中国移动 话费充值 50元 🎉',
  // ── kana (the 0x3040-0x30FF range both sides keep) ────────────────────
  'ユニクロ 优衣库 Tシャツ ¥99',
  // ── degenerate ────────────────────────────────────────────────────────
  '',
  '   ¥ . ',
];

function build() {
  const model = nb.emptyModel();
  for (const s of TRAINING) nb.learn(model, nb.tokenize(s.text), s.label);

  const tokens = STRINGS.map((s) => nb.tokenize(s, EXTRAS));
  const predictions = tokens.map((t) =>
    nb.predict(model, t).map((p) => ({ label: p.label, p: Number(p.p.toFixed(6)) })),
  );

  return {
    notes: [
      '由 scripts/gen-nb-golden.js 生成，请勿手改。',
      'server/src/lib/nb.js 与 app/lib/capture/naive_bayes.dart 都必须能复现本文件：',
      'tokens 逐项完全相等，predictions 的 p 误差 ≤ 1e-6、label 与顺序完全相等。',
      'extras 里的 m:美团 / dir:expense 故意不在训练样本里 —— 它们必须被 OOV 规则丢弃，',
      '任何一边漏了「只对词表内 token 计分」，predictions 立刻对不上。',
      'model.version 不属于跨语言契约：服务端由 /model 端点管版本（learn 不动它），',
      'Dart 端 learn 每次自增。对比模型时请只比 classes / vocab / totalDocs。',
    ],
    generator: 'scripts/gen-nb-golden.js',
    extras: EXTRAS,
    training: TRAINING,
    model,
    strings: STRINGS,
    tokens,
    predictions,
  };
}

fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, `${JSON.stringify(build(), null, 2)}\n`, 'utf8');
process.stdout.write(
  `wrote ${OUT}\n  ${STRINGS.length} strings · ${Object.keys(build().model.classes).length} classes · vocab ${build().model.vocab}\n`,
);
