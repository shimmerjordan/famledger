'use strict';

// Household defaults. Exports an object (not a module factory), so the module
// loader skips it — it is a helper other modules call, not a set of routes.
//
// `seedDefaults` is idempotent per table: it only fills a table that is still
// empty, so a household that deleted every category does not get them back on
// the next restart.

const crypto = require('node:crypto');

/** The app's 12-colour palette. Categories, funds and members all pick from it. */
const PALETTE = [
  '#c36a4f', '#b07a20', '#8b8c27', '#4a9a5e',
  '#009d82', '#009ba3', '#1292c0', '#5a86ce',
  '#8678c9', '#a66db3', '#bb6690', '#c3656f',
];

// `icon` values are Material Symbols names — the Flutter client maps them
// straight to an IconData, so they must stay valid icon identifiers.
const DEFAULT_CATEGORIES = [
  { name: '餐饮', kind: 'expense', icon: 'restaurant', color: '#c36a4f' },
  { name: '交通', kind: 'expense', icon: 'directions_bus', color: '#1292c0' },
  { name: '购物', kind: 'expense', icon: 'shopping_bag', color: '#bb6690' },
  { name: '居家', kind: 'expense', icon: 'home', color: '#b07a20' },
  { name: '水电', kind: 'expense', icon: 'bolt', color: '#8b8c27' },
  { name: '通讯', kind: 'expense', icon: 'phone_android', color: '#009ba3' },
  { name: '医疗', kind: 'expense', icon: 'medical_services', color: '#c3656f' },
  { name: '教育', kind: 'expense', icon: 'school', color: '#5a86ce' },
  { name: '育儿', kind: 'expense', icon: 'child_care', color: '#a66db3' },
  { name: '宠物', kind: 'expense', icon: 'pets', color: '#4a9a5e' },
  { name: '娱乐', kind: 'expense', icon: 'sports_esports', color: '#8678c9' },
  { name: '人情', kind: 'expense', icon: 'redeem', color: '#bb6690' },
  { name: '旅行', kind: 'expense', icon: 'flight', color: '#009d82' },
  { name: '保险', kind: 'expense', icon: 'shield', color: '#5a86ce' },
  { name: '其他', kind: 'expense', icon: 'more_horiz', color: '#8b8c27' },
  { name: '工资', kind: 'income', icon: 'payments', color: '#4a9a5e' },
  { name: '奖金', kind: 'income', icon: 'emoji_events', color: '#b07a20' },
  { name: '理财', kind: 'income', icon: 'trending_up', color: '#009d82' },
  { name: '退款', kind: 'income', icon: 'undo', color: '#1292c0' },
  { name: '转账收入', kind: 'income', icon: 'swap_horiz', color: '#8678c9' },
  { name: '其他', kind: 'income', icon: 'more_horiz', color: '#8b8c27' },
];

/** Offered by `GET /funds/templates` — a starting point, not a constraint. */
const FUND_TEMPLATES = [
  { key: 'allowance', name: '个人零花', kind: 'personal', icon: 'wallet', color: '#8678c9', description: '每人自己的可自由支配预算，超支只影响自己。' },
  { key: 'household', name: '家庭公共基金', kind: 'shared', icon: 'home', color: '#c36a4f', description: '吃饭、水电、日用品等全家共同开销。' },
  { key: 'retirement', name: '养老储备', kind: 'reserve', icon: 'elderly', color: '#009d82', description: '长期只进不出的养老金，尽量不动用。' },
  { key: 'childcare', name: '育儿基金', kind: 'goal', icon: 'child_care', color: '#a66db3', description: '教育、兴趣班、奶粉尿布等孩子相关支出。' },
  { key: 'pet', name: '宠物基金', kind: 'goal', icon: 'pets', color: '#4a9a5e', description: '猫粮狗粮、疫苗、洗澡、看病。' },
  { key: 'emergency', name: '应急金', kind: 'reserve', icon: 'health_and_safety', color: '#c3656f', description: '3~6 个月生活费，只在真出事时动用。' },
  { key: 'travel', name: '旅行基金', kind: 'goal', icon: 'flight', color: '#1292c0', description: '为下一次旅行按月攒钱。' },
  { key: 'loan', name: '房贷车贷还款金', kind: 'reserve', icon: 'account_balance', color: '#b07a20', description: '每月固定划入，专款专用于还贷。' },
];

const SQL_CATEGORY =
  'INSERT INTO categories(id, name, kind, parent_id, icon, color, sort_order, archived, created_at, updated_at, seq)' +
  ' VALUES(?, ?, ?, NULL, ?, ?, ?, 0, ?, ?, ?)';
const SQL_FUND =
  'INSERT INTO funds(id, name, kind, owner_member_id, icon, color, target_cents, monthly_budget_cents, description,' +
  ' sort_order, archived, is_default, created_at, updated_at, seq) VALUES(?, ?, ?, NULL, ?, ?, NULL, NULL, ?, 0, 0, ?, ?, ?, ?)';
const SQL_ACCOUNT =
  'INSERT INTO accounts(id, name, kind, owner_member_id, initial_balance_cents, currency, icon, color, sort_order,' +
  " archived, match_hints, created_at, updated_at, seq) VALUES(?, ?, ?, NULL, 0, ?, ?, ?, 0, 0, '{}', ?, ?, ?)";

/**
 * Fill an empty household with the defaults every family starts from.
 * @param {object} db handle from lib/db.js
 * @param {{adminId?: string|null}} [opts] the admin created by POST /setup
 * @returns {{categories:number, funds:number, accounts:number}} rows inserted
 */
function seedDefaults(db, { adminId = null } = {}) {
  return db.tx(() => {
    const now = db.now();
    const currency = db.meta('currency', 'CNY');
    const out = { categories: 0, funds: 0, accounts: 0 };
    const empty = (table) => !db.get(`SELECT 1 AS ok FROM ${table} LIMIT 1`);

    if (empty('categories')) {
      DEFAULT_CATEGORIES.forEach((c, i) => {
        db.run(SQL_CATEGORY, crypto.randomUUID(), c.name, c.kind, c.icon, c.color, i, now, now, db.nextSeq());
        out.categories++;
      });
    }

    if (empty('funds')) {
      const t = FUND_TEMPLATES.find((f) => f.key === 'household');
      db.run(SQL_FUND, crypto.randomUUID(), t.name, t.kind, t.icon, t.color, t.description, 1, now, now, db.nextSeq());
      out.funds++;
    }

    if (empty('accounts')) {
      db.run(SQL_ACCOUNT, crypto.randomUUID(), '现金', 'cash', currency, 'payments', '#4a9a5e', now, now, db.nextSeq());
      out.accounts++;
    }

    if (out.categories || out.funds || out.accounts) {
      db.run('INSERT INTO activity(member_id, action, entity, entity_id, at) VALUES(?, ?, ?, NULL, ?)',
        adminId, 'seed', 'household', now);
    }
    return out;
  });
}

// ── 自动记账的朴素贝叶斯种子样本（spec §6）────────────────────────────────
// 「商户/关键词文本 → 类别名」。手机端首启用同一份训练本地模型，服务端
// `model` 表为空时也用它训练出共享模型，两边的分类结果因此天然一致。
//
// 这里存的是**类别名**；服务端把它映射成本家庭 `categories` 行的 id 再训练
// （同名时支出类别优先，因为「其他」支出/收入各有一个）。名字对不上的条目
// 直接跳过，所以用户改名或删掉某个默认类别都不会让首启崩掉。
const NB_SEED_TEXTS = {
  餐饮: [
    '美团外卖 订单支付', '饿了么 外卖订单', '肯德基 KFC', '麦当劳', '星巴克咖啡', '瑞幸咖啡',
    '海底捞火锅', '沙县小吃', '兰州拉面', '蜜雪冰城 奶茶', '公司食堂 刷卡消费', '早餐包子豆浆',
    '烧烤夜宵', '必胜客 披萨', '美团买菜 生鲜', '喜茶 奶茶店', '面馆 午饭', '外卖午餐',
  ],
  交通: [
    '滴滴出行 行程费用', '滴滴快车', '高德打车', '地铁乘车码 扣费', '公交车 刷卡', '出租车车费',
    '中国石化 加油', '中国石油 加油站', '12306 铁路购票', '停车场 停车费', '高速公路 通行费 ETC',
    '共享单车 骑行费', '哈啰单车', '洗车 汽车保养', '汽车年检', '滴滴代驾',
  ],
  购物: [
    '淘宝 订单支付', '天猫超市', '京东商城 订单', '拼多多 订单', '唯品会', '抖音商城 下单',
    '优衣库 服装', '屈臣氏', '山姆会员商店', '永辉超市 购物', '大润发 超市', '小米商城 数码',
    '苹果官网 Apple Store', '化妆品 护肤品', '鞋帽箱包', '网购日用品',
  ],
  居家: [
    '小区物业费', '家政保洁 钟点工', '宜家家居 IKEA', '小米有品 家居', '五金建材 装修',
    '家具城 沙发', '房租 月租', '搬家公司', '日用百货 纸巾洗衣液', '开锁换锁 维修',
    '空调清洗 家电维修', '窗帘定制',
  ],
  水电: [
    '国家电网 电费', '电力公司 电费缴纳', '自来水公司 水费', '水费缴纳', '燃气费 天然气',
    '中国燃气 充值', '暖气费 供暖', '物业代收 水电费', '水电煤缴费', '阶梯电价 扣费',
  ],
  通讯: [
    '中国移动 话费充值', '中国联通 话费', '中国电信 套餐费', '宽带续费 网费', '手机话费自动充值',
    '流量包 购买', '固话月租', '移动营业厅缴费', '腾讯王卡 月租',
  ],
  医疗: [
    '人民医院 挂号费', '医院门诊缴费', '药店 买药', '老百姓大药房', '益丰大药房', '体检中心 年度体检',
    '牙科诊所 洗牙', '社区医院 输液', '疫苗接种费', '住院费 押金', '中医推拿 理疗', '眼镜店 配镜',
  ],
  教育: [
    '学费 缴纳', '新东方 培训班', '网课 在线课程', '书店 买书', '当当网 图书', '得到 知识付费',
    '驾校 学费', '考试报名费', '文具 笔记本', '英语培训 报班', '研究生学费', '学而思 课程',
  ],
  育儿: [
    '奶粉 婴幼儿', '纸尿裤 尿不湿', '幼儿园 保育费', '儿童乐园 门票', '早教中心 课程',
    '儿童玩具', '童装 宝宝衣服', '婴儿推车 安全座椅', '辅食 米粉', '儿童绘本', '小天才 儿童手表',
  ],
  宠物: [
    '猫粮 购买', '狗粮 购买', '宠物医院 看病', '猫砂 除臭', '宠物洗澡 美容', '疫苗驱虫 宠物',
    '宠物用品店', '宠物寄养 托管', '猫零食 冻干', '狗狗牵引绳',
  ],
  娱乐: [
    '电影票 淘票票', '猫眼电影 购票', '腾讯视频 会员', '爱奇艺 VIP 会员', '网易云音乐 黑胶会员',
    'KTV 唱歌', '游戏充值 点券', 'Steam 游戏', '健身房 年卡', '密室逃脱 剧本杀', '演唱会门票',
    '网吧 上网', '游乐园 门票',
  ],
  人情: [
    '微信红包 发出', '随礼 份子钱', '婚礼 礼金', '生日礼物', '孝敬父母 生活费', '压岁钱 红包',
    '探病 慰问金', '同事凑份子', '满月酒 贺礼', '朋友聚会 AA',
  ],
  旅行: [
    '携程 机票预订', '酒店住宿 房费', '火车票 高铁', '去哪儿旅行', '飞猪 旅行', '景区门票',
    '旅行社 跟团游', '民宿 预订', '航空公司 值机选座', '签证费 办理', '租车 自驾游',
  ],
  保险: [
    '平安保险 保费', '中国人寿 保费', '太平洋保险 扣款', '车险 续保', '医疗险 保费',
    '重疾险 年缴', '意外险 投保', '社保 个人缴纳', '住房公积金 缴纳', '宠物险 保费',
  ],
  其他: [
    '手续费 扣除', '快递费 运费', '交通违章 罚款', '公益捐款', '服务费', '杂项支出',
    '账户管理费', '工本费',
  ],
  工资: [
    '工资 代发', '薪资入账 工资', '公司发工资', '月薪 发放', '劳务报酬 到账', '工资条 实发',
    '代发工资 银行入账',
  ],
  奖金: [
    '年终奖 到账', '季度奖金', '绩效奖金 发放', '项目奖金', '全勤奖', '开门红 奖励', '提成 奖金',
  ],
  理财: [
    '余额宝 收益', '基金分红 到账', '股票分红', '银行利息 结息', '定期存款 到期利息',
    '理财产品 收益', '零钱通 收益', '国债利息',
  ],
  退款: [
    '淘宝 退款到账', '订单退款', '退票 退款', '退货退款 成功', '商家退款', '机票改签 退款',
    '取消订单 原路退回',
  ],
  转账收入: [
    '微信转账 收入', '支付宝转账 到账', '银行卡 转入', '他人转账 收款', '亲属转账',
    '收款到账 通知', '朋友还钱 转账',
  ],
};

/** Flat `{text, category}` list — what the classifier trains on. */
const NB_SEED = Object.entries(NB_SEED_TEXTS).flatMap(([category, texts]) =>
  texts.map((text) => ({ text, category })),
);

module.exports = { seedDefaults, FUND_TEMPLATES, DEFAULT_CATEGORIES, PALETTE, NB_SEED };

