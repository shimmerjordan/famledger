-- 物品资产。只存事实（买价、日期、状态），持有天数、日均这些派生数在客户端算，免得两边口径分叉。
-- category 不加 CHECK：取值表以后要加一项时，SQLite 改不了约束只能重建整张表，校验放在 modules/assets.js。

CREATE TABLE assets(id TEXT PRIMARY KEY, name TEXT NOT NULL, category TEXT NOT NULL DEFAULT 'other', icon TEXT,
  price_cents INTEGER NOT NULL, purchased_on TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'in_use' CHECK(status IN ('in_use','idle','retired','sold')),
  ended_on TEXT, sale_cents INTEGER, expected_days INTEGER, note TEXT,
  member_id TEXT, transaction_id TEXT, sale_transaction_id TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0, archived INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT, seq INTEGER NOT NULL);
CREATE INDEX idx_assets_seq ON assets(seq);
