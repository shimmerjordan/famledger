'use strict';

// AI 导入里和原文打交道的纯函数（spec §4「日志」、§6）：发给模型前的脱敏、超长时挑段落、依据核对的位置。

const test = require('node:test');
const assert = require('node:assert/strict');

const { redactPii } = require('../src/lib/redact');
const { pickParagraphs, locateEvidence, mentions, PICK_LIMIT } = require('../src/lib/perk_import_text');

test('脱敏：手机号打码（中间四位），卡号只留尾号；日期、金额、短数字不动', () => {
  const r = redactPii('收货人 王小明 13912345678，备用 139-1234-5678；卡号 6222 0212 3456 7890 123；订单编号 2026092021140512345；下单 2026-09-20 21:14 实付 8999.00，淘气值 1000');
  assert.equal(
    r.text,
    '收货人 王小明 139****5678，备用 139****5678；卡号 **** 0123；订单编号 **** 2345；下单 2026-09-20 21:14 实付 8999.00，淘气值 1000',
  );
  assert.deepEqual([r.phones, r.cards], [2, 2]);
  assert.equal(redactPii('有效期 2026-09-20 2026-12-31').text, '有效期 2026-09-20 2026-12-31', '两个日期挨着不是卡号');
  assert.equal(redactPii('100138123456789').text, '**** 6789', '15 位连续数字按卡号，不在里面找手机号');
});

test('挑段落：不超过上限原样；超了按关键词密度挑、放不下的跳过、按原顺序拼回去；没有换行就截断', () => {
  assert.deepEqual(pickParagraphs('短短一段'), { text: '短短一段', picked: false, kept: 1, total: 1 });
  assert.equal(PICK_LIMIT, 12000);
  const noise = '今天天气不错，出门散步。'.repeat(40); // 480 字，没有关键词
  const perks = '88VIP 权益：每月 4 张券，领取后有效期 30 天；年卡自动续费。';
  const order = '订单 实付 ¥899 商品 耳机 1 件 下单 2026-03-08';
  const text = [noise, perks, noise, order, noise].join('\n\n');
  const p = pickParagraphs(text, perks.length + order.length + 2);
  assert.equal(p.text, `${perks}\n\n${order}`);
  assert.deepEqual([p.picked, p.kept], [true, 2]);
  assert.ok(p.total > 5, '比上限还长的噪声段被切成了几块参与挑选');
  const flat = pickParagraphs('会'.repeat(30), 10);
  assert.deepEqual([flat.text.length, flat.picked], [10, true]);
});

test('挑段落：「短标题 + 一大段正文（段内只有单个换行）」不会只剩标题 —— 超长的段按行切开再挑', () => {
  const body = Array.from({ length: 700 }, (_, i) => `第 ${i + 1} 项：每月领取 4 张券，有效期 30 天`).join('\n');
  const text = `淘宝 88VIP 权益说明\n\n${body}`;
  assert.ok(text.length > PICK_LIMIT);
  const p = pickParagraphs(text);
  assert.equal(p.picked, true);
  assert.ok(p.text.length > PICK_LIMIT * 0.9 && p.text.length <= PICK_LIMIT, `发出去 ${p.text.length} 字`);
  assert.ok(p.text.includes('第 1 项：每月领取 4 张券'), '正文进来了');
  const oneLine = pickParagraphs(`标题\n\n${'会员权益'.repeat(4000)}`);
  assert.ok(oneLine.text.length > PICK_LIMIT * 0.9, '一行就超长的也按上限切块挑进来');
});

test('依据核对：全角半角、空白、标点不计较，回原文下标；太短或找不到是 null', () => {
  const src = '权益一：优酷视频年卡，开通后去优酷 App「我的-会员中心」领取。\n权益二：饿了么超级会员年卡';
  const span = locateEvidence('优酷视频年卡,开通后去优酷app 「我的 会员中心」领取', src);
  assert.equal(src.slice(span[0], span[1]), '优酷视频年卡，开通后去优酷 App「我的-会员中心」领取');
  assert.deepEqual(locateEvidence('饿了么超级会员年卡', src), [src.indexOf('饿了么'), src.length]);
  assert.equal(locateEvidence('每月一张五十元代金券', src), null);
  assert.equal(locateEvidence('卡', src), null, '一个字的依据不算数');
  assert.equal(mentions(src, 'QQ音乐'), false);
  assert.equal(mentions(src, '优 酷'), true);
});

test('提示词：两个虚构示例、「只抽写明的」、识别范围；已有名字各最多 80 个；指定卡时写明归到它', () => {
  const { buildImportPrompt, EXAMPLE_NAMES, IMPORT_MAX_TOKENS, ITEM_PRESETS } = require('../src/lib/perk_import_prompt');
  assert.equal(IMPORT_MAX_TOKENS, 12000);
  assert.deepEqual(Object.keys(ITEM_PRESETS), ['apple', 'android_pc', 'lens', 'ev', 'bike', 'fashion_bag', 'watch', 'keep_value'], '照抄 App 的 kValuationPresets');
  const platforms = Array.from({ length: 100 }, (_, i) => `平台${i}`);
  const p = buildImportPrompt({ want: 'items', existing: { platforms, memberships: [{ name: '88VIP', platform: '淘宝' }] } });
  assert.match(p.system, /只抽材料里写明的内容；没写的字段填 null/);
  assert.match(p.system, /示例一（虚构）/);
  assert.match(p.system, /示例二（虚构）/);
  for (const name of ['星河视频', '声澜 Z3 降噪耳机']) assert.ok(EXAMPLE_NAMES.includes(name));
  const user = p.user('材料原文');
  assert.match(user, /这次只抽 item/);
  assert.ok(user.includes('平台79') && !user.includes('平台80'), '已有平台最多 80 个');
  assert.match(user, /88VIP（淘宝）/);
  assert.ok(user.endsWith('<<<\n材料原文\n>>>'));
  const target = buildImportPrompt({ want: 'virtual', target: { name: '88VIP', platform: '淘宝' } }).user('x');
  assert.match(target, /归到已有的会员卡「88VIP」（淘宝）/);
  assert.match(target, /只抽平台、会员卡和权益/);
});
