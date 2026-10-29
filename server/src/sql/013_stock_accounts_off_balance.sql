-- 股票账户 + 流水「不计入账户余额」。
--
-- accounts.kind 多一种 'stock'（股票账户）：不挂持仓，整户记一个「当前市值」。余额（期初 + 流水）= 投入的本金，
-- value_cents = 市值（空 = 还没填过，按投入算），value_on = 哪天的数，value_log = 历次市值 [{on, valueCents}]（老的在前，
-- 同一天覆盖，最多 200 条）。浮盈 = 市值 − 余额。口径见 modules/stats.js 文件头。
--
-- transactions.off_balance = 1 的流水不进真账户的余额（账单导入进来、余额靠账户校准的那种），但照常进收支统计、板块余额、
-- 预算；债务内部账户（kind = 'debt'）那一侧照常算。见 lib/stats_sql.js 的 deltaMap。

ALTER TABLE accounts ADD COLUMN value_cents INTEGER;
ALTER TABLE accounts ADD COLUMN value_on TEXT;
ALTER TABLE accounts ADD COLUMN value_log TEXT NOT NULL DEFAULT '[]';
ALTER TABLE transactions ADD COLUMN off_balance INTEGER NOT NULL DEFAULT 0;
