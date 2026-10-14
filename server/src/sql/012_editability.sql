-- 手动微调。算出来的数也要能改：
--
-- funds.opening_balances：板块的期初余额，按币种 `{"CNY": 120000, "USD": -500}`（分）。板块余额 = 期初 + 流水，
-- 和账户的 initial_balance_cents 同一个意思；「校准余额」就是把差额加进这里，不多记一笔流水、不进收支统计。
--
-- fx_rates.manual：1 = 手填的汇率。自动抓取不覆盖它，直到用户点「恢复自动」（删掉这一行）。

ALTER TABLE funds ADD COLUMN opening_balances TEXT NOT NULL DEFAULT '{}';
ALTER TABLE fx_rates ADD COLUMN manual INTEGER NOT NULL DEFAULT 0;
