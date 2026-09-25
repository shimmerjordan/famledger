'use strict';

// 提示词与「财务上下文」。**导出对象 → 装载器跳过它**。
//
// 模型不查库：所有数字都由服务端在这里算好、拼成一段中文塞进 system。这样
//   · 密钥与数据都不出服务端，模型只看见聚合结果（没有单笔备注、没有原始通知文本）；
//   · 上下文长度可控（硬上限 6000 字），换任何模型都不会因为超长而炸。
//
//   buildFinanceContext(db, month) → string
//   SYSTEM_PROMPT / REPORT_PROMPT(month) / CLASSIFY_SYSTEM / CLASSIFY_PROMPT(input, candidates)

const stats = require('./stats');

const MAX_CONTEXT_CHARS = 6000;
const TOP_CATEGORIES = 8;
const TREND_MONTHS = 6;

/** 分 → `¥1,234.56`（负数是 `-¥1.00`）。不依赖 ICU。 */
function formatMoney(cents) {
  const n = Math.round(Number(cents) || 0);
  const abs = Math.abs(n);
  const yuan = String(Math.floor(abs / 100)).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return `${n < 0 ? '-' : ''}¥${yuan}.${String(abs % 100).padStart(2, '0')}`;
}

/** 带正负号的金额，给「结余」这种要一眼看出方向的地方。 */
const signed = (cents) => ((Number(cents) || 0) > 0 ? `+${formatMoney(cents)}` : formatMoney(cents));

const pct = (part, whole) => (Number(whole) > 0 ? `${Math.round((Number(part) / Number(whole)) * 100)}%` : '—');

function nameMap(db, table, column = 'name') {
  const map = new Map();
  for (const r of db.all(`SELECT id, ${column} AS n FROM ${table} WHERE deleted_at IS NULL`)) map.set(r.id, r.n);
  return map;
}

/**
 * 注入给模型的账本快照。中文、紧凑、只有聚合数字。
 * @param {object} db lib/db.js 的句柄
 * @param {string} [month] `YYYY-MM`
 * @returns {string}
 */
function buildFinanceContext(db, month = stats.currentMonth()) {
  const household = db.meta('household_name', '') || '这个家庭';
  const currency = db.meta('currency', 'CNY');
  const ov = stats.computeOverview(db, month);
  const series = stats.computeTrend(db, { months: TREND_MONTHS, endMonth: month }).series;
  const prev = series.length >= 2 ? series[series.length - 2] : null;

  const fundRows = db.all(
    'SELECT id, name, target_cents, monthly_budget_cents FROM funds WHERE deleted_at IS NULL ORDER BY sort_order, created_at',
  );
  const categories = nameMap(db, 'categories');
  const members = nameMap(db, 'members', 'display_name');
  const balance = new Map(ov.funds.map((f) => [f.fundId, f.balanceCents]));
  const budget = new Map(ov.month.budgets.map((b) => [`${b.scope}/${b.refId}`, b]));
  const fundMonth = new Map(ov.month.byFund.map((f) => [f.fundId, f]));

  const L = [];
  L.push(`【家庭】${household} · 记账币种 ${currency} · 统计月份 ${month}（金额单位：元）`);
  L.push(
    `【本月总览】支出 ${formatMoney(ov.month.expenseCents)}；收入 ${formatMoney(ov.month.incomeCents)}；` +
      `结余 ${signed(ov.month.incomeCents - ov.month.expenseCents)}；待确认流水 ${ov.pendingCount} 笔`,
  );
  L.push(
    `【净资产】${formatMoney(ov.netWorthCents)}（资产 ${formatMoney(ov.assetsCents)} / 负债 ${formatMoney(ov.liabilitiesCents)}）`,
  );
  // 实物估值（spec §3）：计入额跟着家庭设置的全局开关走，关着就是 ¥0.00。没有在用的物品就不写这一行。
  const physical = ov.physical;
  if (physical && physical.count > 0) {
    L.push(`【实物估值】${formatMoney(physical.valueCents)}（计入 ${formatMoney(physical.counted ? physical.includedCents : 0)}）`);
  }

  if (prev) {
    const d = ov.month.expenseCents - prev.expenseCents;
    const how = prev.expenseCents > 0 ? `${d >= 0 ? '+' : '-'}${pct(Math.abs(d), prev.expenseCents)}` : '上月没有支出';
    L.push(
      `【环比】上月（${prev.month}）支出 ${formatMoney(prev.expenseCents)} → 本月 ${formatMoney(ov.month.expenseCents)}（${how}）；` +
        `上月收入 ${formatMoney(prev.incomeCents)}`,
    );
  }

  L.push('【各基金】余额 · 本月收支 · 月预算 · 目标');
  for (const f of fundRows) {
    const bits = [`余额 ${formatMoney(balance.get(f.id) || 0)}`];
    const m = fundMonth.get(f.id);
    bits.push(`本月支出 ${formatMoney(m ? m.expenseCents : 0)}`);
    if (m && m.incomeCents) bits.push(`本月收入 ${formatMoney(m.incomeCents)}`);
    const b = budget.get(`fund/${f.id}`);
    const budgetCents = b ? b.budgetCents : f.monthly_budget_cents;
    if (budgetCents != null) {
      const spent = b ? b.spentCents : m ? m.expenseCents : 0;
      bits.push(`月预算 ${formatMoney(budgetCents)}（已用 ${pct(spent, budgetCents)}${spent > budgetCents ? '，已超支' : ''}）`);
    }
    if (f.target_cents != null) {
      bits.push(`目标 ${formatMoney(f.target_cents)}（进度 ${pct(balance.get(f.id) || 0, f.target_cents)}）`);
    }
    L.push(`- ${f.name}：${bits.join('；')}`);
  }

  const top = [...ov.month.byCategory].sort((a, b) => b.expenseCents - a.expenseCents).slice(0, TOP_CATEGORIES);
  if (top.length) {
    L.push(`【本月支出类别 Top${top.length}】`);
    top.forEach((c, i) => {
      L.push(`${i + 1}. ${categories.get(c.categoryId) || '未分类'} ${formatMoney(c.expenseCents)}（占 ${pct(c.expenseCents, ov.month.expenseCents)}）`);
    });
  } else {
    L.push('【本月支出类别】本月还没有支出');
  }

  const byMember = [...ov.month.byMember].sort((a, b) => b.expenseCents - a.expenseCents);
  if (byMember.length) {
    L.push(`【成员支出】${byMember.map((m) => `${members.get(m.memberId) || '未知成员'} ${formatMoney(m.expenseCents)}`).join('；')}`);
  }

  L.push(`【近 ${series.length} 个月】${series.map((s) => `${s.month} 支 ${formatMoney(s.expenseCents)} / 收 ${formatMoney(s.incomeCents)}`).join('；')}`);

  const text = L.join('\n');
  if (text.length <= MAX_CONTEXT_CHARS) return text;
  const keep = text.lastIndexOf('\n', MAX_CONTEXT_CHARS - 24);
  return `${text.slice(0, keep > 0 ? keep : MAX_CONTEXT_CHARS - 24)}\n…（上下文过长，已截断）`;
}

const SYSTEM_PROMPT = [
  '你是这个家庭账本的家庭理财顾问。说话直接、简短、像个同住的明白人，不说教、不灌鸡汤、不用「亲」之类的客套。',
  '规则：',
  '1. 只用下面给出的账本数据说话。数据里没有的，就说「账本里没有这项数据」，绝对不要编造金额、笔数或时间。',
  '2. 所有金额单位是元，按「¥1,234.56」的写法；涨跌要给出具体数字或百分比。',
  '3. 每次回答最后给最多 3 条可执行的建议，每条一句话，能落到具体基金、类别或金额上。',
  '4. 全程简体中文。不要输出表格以外的大段排版，手机屏幕很窄。',
  '',
  '以下是这个家庭的账本数据：',
].join('\n');

/** 月报的用户消息。结构固定，客户端按 Markdown 渲染。 */
function REPORT_PROMPT(month) {
  return [
    `请基于上面的账本数据，写一份 ${month} 的家庭月度理财报告，用 Markdown，二级标题固定为下面四个、顺序不变：`,
    '',
    '## 本月概览',
    '## 各基金',
    '## 值得注意',
    '## 下月建议',
    '',
    `要求：「本月概览」用两三句话交代 ${month} 的支出、收入、结余和环比；「各基金」每个基金一行，点出余额、预算使用与目标进度；`,
    '「值得注意」写 1~3 条异常（超预算、某类别激增、待确认流水堆积等），没有异常就明说没有；「下月建议」给正好 3 条可执行建议。',
    '不要重复罗列所有原始数字，不要编造账本里没有的东西，全文控制在 600 字以内。',
  ].join('\n');
}

const CLASSIFY_SYSTEM =
  '你是一个中文记账分类器。你只输出一个 JSON 对象，不输出任何解释、前后缀或代码块。id 必须原样来自候选列表，拿不准就填 null。';

/**
 * 分类的用户消息。
 * @param {{text:string, merchant?:string|null, amountCents?:number|null}} input
 * @param {{categories:{id:string,name:string}[], funds:{id:string,name:string}[]}} candidates
 */
function CLASSIFY_PROMPT(input, candidates) {
  const cats = (candidates.categories || []).map((c) => `- ${c.id}\t${c.name}`).join('\n') || '（无）';
  const funds = (candidates.funds || []).map((f) => `- ${f.id}\t${f.name}`).join('\n') || '（无）';
  const lines = [`流水文本：${input.text}`];
  if (input.merchant) lines.push(`商户：${input.merchant}`);
  if (input.amountCents != null) lines.push(`金额：${formatMoney(input.amountCents)}`);
  return [
    '给下面这笔支付流水挑一个类别和一个基金。',
    '',
    ...lines,
    '',
    '可选类别（id 与名称，只能选其中一个 id）：',
    cats,
    '',
    '可选基金（id 与名称，只能选其中一个 id）：',
    funds,
    '',
    '只输出这个 JSON，一行，不要代码块：',
    '{"categoryId":"候选类别 id 或 null","fundId":"候选基金 id 或 null","confidence":0 到 1 之间的小数,"reason":"20 字以内的理由"}',
  ].join('\n');
}

module.exports = {
  MAX_CONTEXT_CHARS,
  buildFinanceContext,
  formatMoney,
  SYSTEM_PROMPT,
  REPORT_PROMPT,
  CLASSIFY_SYSTEM,
  CLASSIFY_PROMPT,
};
