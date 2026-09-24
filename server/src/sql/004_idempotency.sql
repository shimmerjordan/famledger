-- 一次请求既改状态又建流水的接口（开仓、加减仓、记物品、卖物品）靠客户端给的 client_id 做幂等：
-- 请求其实落库了、回应丢在路上时，App 原样重发只拿回第一次的结果，不会把份额和流水再改一遍。
-- 这张表只在服务端用，不同步、不进 /changes；过期的行由 lib/idempotency.js 写入时顺手清掉。
-- ref_id 是第一次写到的那行（持仓/物品）；response 是需要原样回放的响应体（交易的流水只能这样找回来）。

CREATE TABLE idempotency(scope TEXT NOT NULL, client_id TEXT NOT NULL, ref_id TEXT NOT NULL, response TEXT,
  created_at TEXT NOT NULL, PRIMARY KEY(scope, client_id));
CREATE INDEX idx_idempotency_created ON idempotency(created_at);
