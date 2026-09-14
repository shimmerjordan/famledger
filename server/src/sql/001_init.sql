-- famledger initial schema. Money is always an integer number of 分 (cents).
-- Every user-visible row carries a monotonic `seq` (from meta.change_seq) and
-- a `deleted_at` tombstone so `GET /changes?since=` can ship a delta.

CREATE TABLE schema_migrations(version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL);

CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);           -- change_seq, household_name, currency, settings(json)

CREATE TABLE members(id TEXT PRIMARY KEY, username TEXT UNIQUE NOT NULL, password_hash TEXT NOT NULL, display_name TEXT NOT NULL,
  color TEXT NOT NULL DEFAULT '#1292c0', avatar_emoji TEXT NOT NULL DEFAULT '🙂', role TEXT NOT NULL CHECK(role IN ('admin','member')),
  archived INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT, seq INTEGER NOT NULL);

CREATE TABLE devices(id TEXT PRIMARY KEY, member_id TEXT NOT NULL REFERENCES members(id), name TEXT, platform TEXT, token_id TEXT UNIQUE NOT NULL,
  created_at TEXT NOT NULL, last_seen_at TEXT NOT NULL, revoked_at TEXT);

CREATE TABLE accounts(id TEXT PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL, owner_member_id TEXT, initial_balance_cents INTEGER NOT NULL DEFAULT 0,
  currency TEXT NOT NULL DEFAULT 'CNY', icon TEXT, color TEXT, sort_order INTEGER NOT NULL DEFAULT 0, archived INTEGER NOT NULL DEFAULT 0,
  match_hints TEXT NOT NULL DEFAULT '{}', created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT, seq INTEGER NOT NULL);

CREATE TABLE funds(id TEXT PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL, owner_member_id TEXT, icon TEXT, color TEXT NOT NULL,
  target_cents INTEGER, monthly_budget_cents INTEGER, description TEXT, sort_order INTEGER NOT NULL DEFAULT 0, archived INTEGER NOT NULL DEFAULT 0,
  is_default INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT, seq INTEGER NOT NULL);

CREATE TABLE categories(id TEXT PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('expense','income')), parent_id TEXT, icon TEXT, color TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0, archived INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT, seq INTEGER NOT NULL);

CREATE TABLE transactions(id TEXT PRIMARY KEY, client_id TEXT UNIQUE, type TEXT NOT NULL CHECK(type IN ('expense','income','transfer')),
  amount_cents INTEGER NOT NULL CHECK(amount_cents >= 0), currency TEXT NOT NULL DEFAULT 'CNY', occurred_at TEXT NOT NULL,
  account_id TEXT, to_account_id TEXT, fund_id TEXT, to_fund_id TEXT, category_id TEXT, member_id TEXT NOT NULL,
  merchant TEXT NOT NULL DEFAULT '', note TEXT NOT NULL DEFAULT '', tags TEXT NOT NULL DEFAULT '[]',
  source TEXT NOT NULL DEFAULT 'manual', status TEXT NOT NULL DEFAULT 'confirmed', confidence REAL, raw_text TEXT, source_app TEXT,
  capture_id TEXT, duplicate_of_id TEXT, created_by TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT, seq INTEGER NOT NULL);
CREATE INDEX idx_tx_occurred ON transactions(occurred_at DESC, id DESC);
CREATE INDEX idx_tx_fund ON transactions(fund_id, occurred_at);
CREATE INDEX idx_tx_seq ON transactions(seq);
CREATE INDEX idx_tx_dedupe ON transactions(type, amount_cents, occurred_at);

CREATE TABLE budgets(id TEXT PRIMARY KEY, scope TEXT NOT NULL CHECK(scope IN ('fund','category')), ref_id TEXT NOT NULL, month TEXT NOT NULL,
  amount_cents INTEGER NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT, seq INTEGER NOT NULL, UNIQUE(scope, ref_id, month));

CREATE TABLE rules(id TEXT PRIMARY KEY, priority INTEGER NOT NULL DEFAULT 100, field TEXT NOT NULL, op TEXT NOT NULL, pattern TEXT NOT NULL,
  category_id TEXT, fund_id TEXT, account_id TEXT, member_id TEXT, enabled INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT, seq INTEGER NOT NULL);

CREATE TABLE model(key TEXT PRIMARY KEY, json TEXT NOT NULL, version INTEGER NOT NULL, updated_at TEXT NOT NULL);

CREATE TABLE ai_providers(id TEXT PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('anthropic','openai')), base_url TEXT NOT NULL,
  api_key_enc TEXT, model TEXT NOT NULL, is_default INTEGER NOT NULL DEFAULT 0, enabled INTEGER NOT NULL DEFAULT 1, extra TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL);

CREATE TABLE ai_reports(id TEXT PRIMARY KEY, month TEXT NOT NULL, provider_id TEXT, content TEXT NOT NULL, created_at TEXT NOT NULL);

CREATE TABLE backup_runs(id TEXT PRIMARY KEY, started_at TEXT NOT NULL, finished_at TEXT, ok INTEGER, name TEXT, bytes INTEGER, message TEXT);

CREATE TABLE activity(id INTEGER PRIMARY KEY AUTOINCREMENT, member_id TEXT, action TEXT NOT NULL, entity TEXT NOT NULL, entity_id TEXT, at TEXT NOT NULL);

-- The global change counter every writable row stamps itself with.
INSERT INTO meta(key, value) VALUES('change_seq', '0');
