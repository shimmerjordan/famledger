-- 会员权益（spec §2「006」）：平台 → 会员/卡 → 权益，外加打卡事件。四张表一次建齐，P3 做打卡时不用再迁移。
-- 和 002 一样不写 CHECK（取值表在 lib/perks_schema.js）；三态用文本（auto_renew），不用可空 bool ——
-- rowToJson 会把 null 变成 false。JSON 列（aliases / quota / limits / origin / pay_pattern）存文本。
-- 引用列不加外键：软删的行还留在表里，引用是否存活由各模块在写入时查。

-- 平台（淘宝、优酷、招行信用卡中心……）。存活行之间「规范化名」唯一，规范化在 JS 里现算，不落列。
CREATE TABLE platforms(id TEXT PRIMARY KEY, name TEXT NOT NULL, aliases TEXT NOT NULL DEFAULT '[]',
  kind TEXT NOT NULL DEFAULT 'other', icon TEXT, color TEXT, url TEXT, note TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0, archived INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT, seq INTEGER NOT NULL);
CREATE INDEX idx_platforms_seq ON platforms(seq);

-- 会员/卡。source_benefit_id：派生会员是哪条权益带出来的（88VIP 的「优酷年卡」→ 优酷平台下的这张卡）。
-- term_paid_cents 为 NULL 表示本期按 fee_cents 算；pay_pattern / last_charge_tx_id 给扣费线索（P6/P7）预留。
CREATE TABLE memberships(id TEXT PRIMARY KEY, platform_id TEXT NOT NULL, source_benefit_id TEXT,
  name TEXT NOT NULL, tier TEXT, kind TEXT NOT NULL DEFAULT 'membership', member_id TEXT, account_id TEXT,
  fee_cents INTEGER, fee_period TEXT NOT NULL DEFAULT 'year', term_paid_cents INTEGER,
  term_start_on TEXT, expires_on TEXT, auto_renew TEXT NOT NULL DEFAULT 'unknown',
  is_trial INTEGER NOT NULL DEFAULT 0, remind_days INTEGER,
  pay_pattern TEXT, last_charge_tx_id TEXT, origin TEXT NOT NULL DEFAULT '{}', note TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0, archived INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT, seq INTEGER NOT NULL);
CREATE INDEX idx_memberships_seq ON memberships(seq);
CREATE INDEX idx_memberships_platform ON memberships(platform_id);

-- 权益。parent_id 只给 N 选 1 的选项用（父权益 kind='choice'，只允许一层）；
-- claim_platform_id 为 NULL 表示在会员本平台领。以后做发放批次/账单日起算只需 ADD COLUMN（anchor_on、grant_ttl_days）。
CREATE TABLE benefits(id TEXT PRIMARY KEY, membership_id TEXT NOT NULL, parent_id TEXT, name TEXT NOT NULL,
  kind TEXT NOT NULL DEFAULT 'other', claim_platform_id TEXT, claim_how TEXT, claim_url TEXT,
  flow TEXT NOT NULL DEFAULT 'claim', quota TEXT NOT NULL DEFAULT '[]', anchor TEXT NOT NULL DEFAULT 'calendar',
  valid_from TEXT, valid_until TEXT, face_value_cents INTEGER, my_value_cents INTEGER,
  limits TEXT NOT NULL DEFAULT '[]', remind INTEGER NOT NULL DEFAULT 1, origin TEXT NOT NULL DEFAULT '{}', note TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0, archived INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT, seq INTEGER NOT NULL);
CREATE INDEX idx_benefits_seq ON benefits(seq);
CREATE INDEX idx_benefits_membership ON benefits(membership_id);
CREATE INDEX idx_benefits_claim_platform ON benefits(claim_platform_id);

-- 打卡事件（接口在 P3）。不存 period_key：事件属于哪一期按当前规则现算。没有 sort_order / archived。
CREATE TABLE benefit_events(id TEXT PRIMARY KEY, benefit_id TEXT NOT NULL, kind TEXT NOT NULL,
  occurred_on TEXT NOT NULL, count INTEGER NOT NULL DEFAULT 1, value_cents INTEGER, member_id TEXT, note TEXT,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT, seq INTEGER NOT NULL);
CREATE INDEX idx_benefit_events_seq ON benefit_events(seq);
CREATE INDEX idx_benefit_events_benefit ON benefit_events(benefit_id, occurred_on);
