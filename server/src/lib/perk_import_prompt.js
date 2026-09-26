'use strict';

// AI 导入的提示词（spec §6「抽取管线」）。模型只看这里拼出来的东西：
//   · system：输出格式（单个对象、records 扁平、末尾 done:true 哨兵）、字段口径、「只抽写明的内容，没写就填 null」，
//     外加两个**虚构**的 few-shot 示例（一个会员权益、一个订单物品）；
//   · user：账本里已有的平台和卡的名字（各最多 80 个，名字一致时照抄）、识别范围、归到哪张卡，最后是材料原文。
//
//   buildImportPrompt({want, existing:{platforms, memberships}, target}) → { system, user(text), userForImages(n) }
//       userForImages(n)：截图模式的文字部分（图片块由调用方放在它前面）：同样的已有名字、识别范围，外加「第几块」的说明，
//       要求每条带 "img"（出自第几块，从 1 开始）；长截图切成的相邻块有重叠，重叠处的同一条只写一次。
//   continueNote(records) → string   续写一次时附在原来那条 user 消息后面：「已经收到这些记录，不要再写」的名单（最多 200 条）
//   EXAMPLE_NAMES   示例里出现的名字：依据查不到又和它们同名的记录标「疑似照抄示例」
//   IMPORT_MAX_TOKENS 单次输出上限默认值（渠道 extra.importMaxTokens 可以覆盖）

const IMPORT_MAX_TOKENS = 12000;
const MAX_EXISTING = 80;
const CONTINUE_MAX_NAMES = 200;

/** 物品预设的封闭名单（照抄 App 的 kValuationPresets：key → 能用在哪些类别）。spec §2：预设只写在客户端，这里只认键。 */
const ITEM_PRESETS = {
  apple: ['digital'],
  android_pc: ['digital'],
  lens: ['digital'],
  ev: ['vehicle'],
  bike: ['vehicle', 'sports'],
  fashion_bag: ['luxury'],
  watch: ['luxury', 'jewelry'],
  keep_value: ['luxury', 'jewelry'],
};

const EXAMPLE_1_SOURCE =
  '星河视频 SVIP 年卡 ¥198/年，自动续费。权益：每月 2 张观影券（星河视频 App「我的-卡券」领取）；' +
  '青柠外卖超级会员月卡 1 张，开通后去青柠外卖 App 领取；以下三选一：云帆书城月卡、声澜音乐月卡。';
const EXAMPLE_1_OUTPUT = {
  records: [
    { t: 'platform', name: '星河视频', kind: 'video', ev: '星河视频 SVIP', conf: 0.95 },
    {
      t: 'membership', name: 'SVIP', platform: '星河视频', tier: null, kind: 'membership', fee: 198, feePeriod: 'year',
      termStartOn: null, expiresOn: null, autoRenew: 'yes', isTrial: false, ev: 'SVIP 年卡 ¥198/年，自动续费', conf: 0.9,
    },
    {
      t: 'benefit', name: '观影券', membership: 'SVIP', kind: 'coupon', claimPlatform: null, claimHow: '星河视频 App「我的-卡券」',
      flow: 'claim', quota: [{ p: 'month', n: 2 }], anchor: 'calendar', faceValue: null, validFrom: null, validUntil: null,
      validRule: null, limits: [], ev: '每月 2 张观影券', conf: 0.9,
    },
    {
      t: 'benefit', name: '青柠外卖超级会员月卡', membership: 'SVIP', kind: 'subscription', claimPlatform: '青柠外卖',
      claimHow: '开通后去青柠外卖 App 领取', flow: 'claim', quota: [{ p: 'term', n: 1 }], anchor: 'term', faceValue: null,
      validFrom: null, validUntil: null, validRule: null, limits: [], ev: '青柠外卖超级会员月卡 1 张', conf: 0.85,
    },
    {
      t: 'benefit', name: '云帆书城月卡', membership: 'SVIP', kind: 'subscription', claimPlatform: '云帆书城',
      choice: { group: '三选一', pick: 1 }, flow: 'claim', quota: [{ p: 'term', n: 1 }], anchor: 'term', ev: '三选一：云帆书城月卡', conf: 0.8,
    },
    {
      t: 'benefit', name: '声澜音乐月卡', membership: 'SVIP', kind: 'subscription', claimPlatform: '声澜音乐',
      choice: { group: '三选一', pick: 1 }, flow: 'claim', quota: [{ p: 'term', n: 1 }], anchor: 'term', ev: '声澜音乐月卡', conf: 0.8,
    },
  ],
  done: true,
};
const EXAMPLE_2_SOURCE = '订单详情　声澜 Z3 降噪耳机 × 1　实付 ¥899.00　下单时间 2026-03-08 20:15';
const EXAMPLE_2_OUTPUT = {
  records: [
    { t: 'item', name: '声澜 Z3 降噪耳机', category: 'digital', preset: null, price: 899, purchasedOn: '2026-03-08', ev: '声澜 Z3 降噪耳机 × 1　实付 ¥899.00', conf: 0.9 },
  ],
  done: true,
};

/** 示例里出现过的平台、卡、权益、物品名。 */
const EXAMPLE_NAMES = [
  ...new Set([...EXAMPLE_1_OUTPUT.records, ...EXAMPLE_2_OUTPUT.records].map((r) => r.name).concat(['星河视频', '青柠外卖', '云帆书城', '声澜音乐'])),
];

const SYSTEM = [
  '你是家庭账本的「会员权益 / 物品」抽取器：从用户给的材料里抽出平台、会员卡、权益和买的东西。只输出一个 JSON 对象，不要解释，不要代码块。',
  '规则：',
  '1. 只抽材料里写明的内容；没写的字段填 null。不要凭常识补权益，也不要估算价值。',
  '2. 输出格式：{"records":[…],"done":true}。records 扁平排列，一条一个对象；全部写完后一定写 "done":true。',
  '3. 每条都带 "t"（platform / membership / benefit / item）、"ev"（材料里的原话，30 字以内，照抄不改写）、"conf"（0 到 1，你有多确定）。',
  '4. 父子关系用名字引用：membership 的 "platform" 写平台名；benefit 的 "membership" 写会员卡名，"claimPlatform" 写去哪个平台领（就在会员卡本平台领填 null）。',
  '5. 金额一律用元（数字，不带单位）；日期写 YYYY-MM-DD，材料没写年份就填 null；只说「领取后 30 天内有效」这种相对期限的，原话放进 "validRule"，不要自己算日期。',
  '6. membership 的字段：name、platform、tier（档位）、kind（membership/subscription/credit_card/bundle/other）、fee（续费价）、feePeriod（month/quarter/year/once/none）、termStartOn、expiresOn、autoRenew（yes/no/unknown）、isTrial。',
  '7. benefit 的字段：name、membership、kind（subscription/coupon/discount/cashback/points/service/lounge/shipping/insurance/other）、claimPlatform、claimHow（领取路径原话）、claimUrl、' +
    'flow（领到手就算写 claim，如年卡、券；用一次算写 use，如贵宾厅、体检；先领再用写 claim_use，如每月领的红包）、' +
    'quota（次数上限列表，如 [{"p":"month","n":4}]，p 取 day/week/month/quarter/year/term（会籍期内）/total（总共），不限次写 []）、' +
    'anchor（按自然月、年算写 calendar；按开卡日、会员期算写 term）、faceValue（单次面值，元）、validFrom、validUntil、validRule、' +
    'limits（限制条件原话，[{"type":"min_spend|scope|channel|holder|device|time|region|stacking|other","text":"…"}]）。' +
    '几选一的权益每个选项各写一条，带 "choice":{"group":"组名","pick":能选几个}。',
  '8. item（买的东西）只写 name、category、preset、price、purchasedOn：category 只能是 digital/appliance/furniture/clothing/vehicle/luxury/jewelry/sports/other；' +
    `preset 只能从 ${Object.keys(ITEM_PRESETS).join('/')} 里挑，都不像就填 null；不要估值。`,
  '',
  '示例一（虚构）材料：',
  EXAMPLE_1_SOURCE,
  '示例一输出：',
  JSON.stringify(EXAMPLE_1_OUTPUT),
  '',
  '示例二（虚构）材料：',
  EXAMPLE_2_SOURCE,
  '示例二输出：',
  JSON.stringify(EXAMPLE_2_OUTPUT),
  '',
  '示例里的名字是编的，不要出现在你的输出里，除非材料里真的写了。',
].join('\n');

const WANT_LINE = {
  auto: '这次会员权益和买的东西都要抽。',
  virtual: '这次只抽平台、会员卡和权益，不要 item。',
  items: '这次只抽 item（买的东西），不要 platform、membership、benefit。',
};

/**
 * @param {{want?:'auto'|'virtual'|'items', existing?:{platforms?:string[], memberships?:{name:string, platform:string}[]},
 *          target?:{name:string, platform:string}|null}} opts
 * @returns {{system:string, user:(text:string)=>string, userForImages:(n:number)=>string}}
 */
function buildImportPrompt({ want = 'auto', existing = {}, target = null } = {}) {
  const platforms = (existing.platforms || []).slice(0, MAX_EXISTING);
  const cards = (existing.memberships || []).slice(0, MAX_EXISTING);
  const head = [WANT_LINE[want] || WANT_LINE.auto];
  if (platforms.length) head.push(`账本里已有的平台（名字一样时照抄这个写法）：${platforms.join('、')}`);
  if (cards.length) head.push(`账本里已有的会员卡：${cards.map((c) => `${c.name}（${c.platform}）`).join('、')}`);
  if (target) {
    head.push(`这些权益都归到已有的会员卡「${target.name}」（${target.platform}）：benefit 的 membership 一律写「${target.name}」，不用再写这张卡和它的平台。`);
  }
  return {
    system: SYSTEM,
    user: (text) => [...head, '', '材料如下（手机号和卡号已打码）：', '<<<', text, '>>>'].join('\n'),
    userForImages: (n) => [
      ...head,
      '',
      `材料是上面按顺序附的 ${n} 张截图（第 1 块 … 第 ${n} 块）。长截图是切成几块发的，相邻两块有一小段重叠，重叠处的同一条只写一次。`,
      '每条记录多写一个 "img"：它出自第几块（从 1 开始的数字）；"ev" 照抄图里的原字。',
    ].join('\n'),
  };
}

/** 续写一次的附言：已经收到的记录（类型：名字（所属））逐行列出，要求从没写过的接着写、格式不变、最后写哨兵。 */
function continueNote(records) {
  const clip = (s) => (typeof s === 'string' && s.trim() ? s.trim().slice(0, 40) : null);
  const lines = records.slice(0, CONTINUE_MAX_NAMES).map((r) => {
    const owner = clip(r && r.membership) || clip(r && r.platform);
    return `- ${clip(r && r.t) || '?'}：${clip(r && r.name) || '（没写名字）'}${owner ? `（${owner}）` : ''}`;
  });
  return [
    '上一次的输出写到一半被截断了。下面这些记录已经收到，不要再写：',
    ...lines,
    '从还没写过的记录接着写，格式不变：{"records":[…],"done":true}；全部写完一定写 "done":true。',
  ].join('\n');
}

module.exports = { IMPORT_MAX_TOKENS, MAX_EXISTING, CONTINUE_MAX_NAMES, ITEM_PRESETS, EXAMPLE_NAMES, buildImportPrompt, continueNote };
