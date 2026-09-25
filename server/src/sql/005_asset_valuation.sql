-- 物品估值（spec §2「005」）。只存用户的选择：估值方式、单件覆盖的年折率/残值、手动估值锚点、
-- 计入净资产三态；估值本身按 lib/valuation.js 现算，不落列。
-- 和 002 一样不写 CHECK（取值表在 lib/valuation.js）；三态用文本，不用可空 bool —— rowToJson 会把 null 变成 false。
-- ALTER 不动 seq：老缓存里的行没有这几列，客户端 fromJson 缺字段按 auto 兜底，不用全量重拉。

ALTER TABLE assets ADD COLUMN valuation_method TEXT NOT NULL DEFAULT 'auto';
ALTER TABLE assets ADD COLUMN rate_bp INTEGER;
ALTER TABLE assets ADD COLUMN residual_bp INTEGER;
ALTER TABLE assets ADD COLUMN manual_value_cents INTEGER;
ALTER TABLE assets ADD COLUMN manual_value_on TEXT;
ALTER TABLE assets ADD COLUMN net_worth TEXT NOT NULL DEFAULT 'auto';

-- 003 漏了持仓的 seq 索引（/changes 按 seq 翻页），顺带补上。
CREATE INDEX IF NOT EXISTS idx_holdings_seq ON holdings(seq);
