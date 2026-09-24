-- 投资持仓。份额与价格都存 ×10000 的整数：基金份额常见 2 位小数、净值 4 位，浮点累加几次就对不上账。
-- cost_cents 是移动平均后的当前持仓总成本，只由加仓/减仓接口改；realized_cents 是历次减仓的已实现盈亏之和。

CREATE TABLE holdings(id TEXT PRIMARY KEY, name TEXT NOT NULL, code TEXT,
  market TEXT NOT NULL DEFAULT 'other' CHECK(market IN ('fund','sh','sz','bj','other')),
  quantity_e4 INTEGER NOT NULL DEFAULT 0, cost_cents INTEGER NOT NULL DEFAULT 0, price_e4 INTEGER, prev_close_e4 INTEGER,
  price_source TEXT NOT NULL DEFAULT 'manual' CHECK(price_source IN ('auto','manual')), price_at TEXT,
  opened_on TEXT NOT NULL, account_id TEXT, realized_cents INTEGER NOT NULL DEFAULT 0, note TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0, archived INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT, seq INTEGER NOT NULL);
