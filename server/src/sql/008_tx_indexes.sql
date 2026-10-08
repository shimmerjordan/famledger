-- 账单筛选（类别、成员、账户）常按这几列查，之前只有 fund_id 有索引。都带 occurred_at：筛选完还要按时间倒序翻页。
-- 不给 status 建索引：几乎每条查询都带 status = 'confirmed'，建了之后规划器会放着 idx_tx_occurred 不用
--（test/charge_hints.test.js 钉着那条计划），而「待确认」计数本来就小。
CREATE INDEX IF NOT EXISTS idx_tx_category ON transactions(category_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_tx_member ON transactions(member_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_tx_account ON transactions(account_id, occurred_at DESC);
