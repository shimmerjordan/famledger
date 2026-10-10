-- 理财分品类（lib/invest.js）：定期、活期、结构性存款、保险存单……不再一律按「代码 × 单价」记。
-- kind 决定估值方式：unit（份额×价格）/ deposit（本金+年化+到期）/ balance（手动更新的当前金额）。
-- 老行按 market 推：场外基金 → fund，其余 → stock。不动 seq：客户端缓存里的老行没有 kind，
-- fromJson 按同一条规则推出来，两边一致，不用全量重拉。

ALTER TABLE holdings ADD COLUMN kind TEXT NOT NULL DEFAULT 'stock';
UPDATE holdings SET kind = 'fund' WHERE market = 'fund';
ALTER TABLE holdings ADD COLUMN institution TEXT;
-- 年化收益率 ×1e6：2.15% → 21500。结构性存款的保底和最高各一个。
ALTER TABLE holdings ADD COLUMN rate_e6 INTEGER;
ALTER TABLE holdings ADD COLUMN rate_max_e6 INTEGER;
ALTER TABLE holdings ADD COLUMN matures_on TEXT;
-- balance 类（活期、银行理财、保险存单、其他）的当前金额与更新日期。
ALTER TABLE holdings ADD COLUMN value_cents INTEGER;
ALTER TABLE holdings ADD COLUMN value_on TEXT;

-- 债务：借出（别人欠我）、借入（我欠别人）、人情。余额不存在这里：每笔债务背后有一个
-- kind = 'debt' 的内部账户，余额 = 它的期初 + 流水（借出为正、借入为负），跟普通账户同一套算法。
-- 钱经真账户走的就是普通转账；不记流水的收回/追加改内部账户的期初，并在 memo_log 里留一行。
CREATE TABLE debts(id TEXT PRIMARY KEY, account_id TEXT,
  direction TEXT NOT NULL CHECK(direction IN ('lend','borrow')),
  kind TEXT NOT NULL DEFAULT 'loan', counterparty TEXT NOT NULL,
  amount_cents INTEGER NOT NULL DEFAULT 0, started_on TEXT NOT NULL, due_on TEXT,
  counted INTEGER NOT NULL DEFAULT 1, member_id TEXT, note TEXT, memo_log TEXT NOT NULL DEFAULT '[]',
  sort_order INTEGER NOT NULL DEFAULT 0, archived INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT, seq INTEGER NOT NULL);
CREATE INDEX idx_debts_seq ON debts(seq);
CREATE INDEX idx_debts_account ON debts(account_id);
