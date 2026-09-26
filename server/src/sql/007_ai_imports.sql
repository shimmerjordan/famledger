-- AI 导入（spec §2「007」）。ai_imports 只在服务端用，不同步、不进 /changes：
--   · extract 结束时写一行记下用量（用户最后没导入也有记录）；模型输出坏得一条都救不回来时记成 failed（token 已经花了）；
--   · apply 回传 importId，服务端核对是本人发起的再落库，状态改 applied，undo 里记下撤销要用的东西（P5 的撤销读它）；
--   · 行保留 90 天，写入时顺手清理（modules/asset_import.js）。
-- status：extracted | failed | applied | undone（不写 CHECK，和别的枚举一样）。summary / undo 是 JSON 文本。
CREATE TABLE ai_imports(id TEXT PRIMARY KEY, member_id TEXT NOT NULL, created_at TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'extracted', source_kind TEXT NOT NULL, source_url TEXT,
  provider_id TEXT, model TEXT, usage_in INTEGER NOT NULL DEFAULT 0, usage_out INTEGER NOT NULL DEFAULT 0,
  summary TEXT NOT NULL DEFAULT '{}', undo TEXT, applied_at TEXT, undone_at TEXT);
CREATE INDEX idx_ai_imports_created ON ai_imports(created_at);
CREATE INDEX idx_ai_imports_member ON ai_imports(member_id, created_at);

-- 导入的物品和会员、权益一样记来源：{src, importId, ev, unverified:[字段名]}（lib/perks_schema.js originOf）。
-- ALTER 不动 seq：老缓存里的行没有这一列，App 的 Asset.fromJson 缺字段按 {} 兜底，不用全量重拉。
ALTER TABLE assets ADD COLUMN origin TEXT NOT NULL DEFAULT '{}';
