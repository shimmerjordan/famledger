-- 多币种。accounts、transactions 早在 001 就有 currency 列；这里补齐理财、物品、债务的币种，
-- 给跨币种转账补「到账金额 / 到账币种」，并建汇率表。
--
-- 板块（funds）没有币种：一个板块能收到不同币种的钱，余额按币种分开算（stats_sql.fundBalancesByCurrency）。
-- 流水的币种跟账户走（transactions.js 强制）；两个账户币种不同的转账，转出一侧按 amount_cents / currency，
-- 转入一侧按 to_amount_cents / to_currency。同币种转账这两列为空。
--
-- 全部 NOT NULL DEFAULT 'CNY'：老行一律当人民币，客户端 fromJson 缺字段时也按 'CNY' 推断，不用全量重拉。
--
-- fx_rates：rate_e6 = 1 单位 base 兑多少 currency ×1e6（整数存）。由 modules/fx.js 抓腾讯外汇写入。

ALTER TABLE holdings ADD COLUMN currency TEXT NOT NULL DEFAULT 'CNY';
ALTER TABLE assets ADD COLUMN currency TEXT NOT NULL DEFAULT 'CNY';
ALTER TABLE debts ADD COLUMN currency TEXT NOT NULL DEFAULT 'CNY';
ALTER TABLE transactions ADD COLUMN to_amount_cents INTEGER;
ALTER TABLE transactions ADD COLUMN to_currency TEXT;

CREATE TABLE fx_rates(
  base TEXT NOT NULL,
  currency TEXT NOT NULL,
  rate_e6 INTEGER NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY(base, currency)
);
