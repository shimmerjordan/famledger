-- 财富板块的「每月固定进账」规则：每月 income_day 号往 income_account_id 记一笔真实的收入流水
-- （类别 income_category_id，没设就用「工资」），落在这个板块里。生成逻辑见 modules/fund_income.js。
-- 规则全空 / monthly_income_cents 为空 = 不自动进账。改规则只影响以后的月份：已经生成过的月份记在
-- fund_income_runs 里（主键 fund_id + month），永不重来 —— 用户删掉某个月那笔也不会被补回来。

ALTER TABLE funds ADD COLUMN monthly_income_cents INTEGER;
ALTER TABLE funds ADD COLUMN income_day INTEGER;
ALTER TABLE funds ADD COLUMN income_account_id TEXT;
ALTER TABLE funds ADD COLUMN income_category_id TEXT;
ALTER TABLE funds ADD COLUMN income_member_id TEXT;
ALTER TABLE funds ADD COLUMN income_start_month TEXT;

CREATE TABLE fund_income_runs(
  fund_id TEXT NOT NULL,
  month TEXT NOT NULL,
  transaction_id TEXT,
  created_at TEXT NOT NULL,
  PRIMARY KEY(fund_id, month)
);
