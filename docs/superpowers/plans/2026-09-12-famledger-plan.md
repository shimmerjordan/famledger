# famledger 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **本仓库规则：任何任务都不得执行 `git commit` / `git push`**（用户未授权）；「提交」步骤一律替换为「运行测试并报告」。

**Goal:** 交付可部署到 NAS 的家庭账本：零依赖 Node 后端 + Flutter（Android/iOS/Web）客户端 + Android 通知自动记账 + WebDAV 备份 + 多渠道 AI 分析。

**Architecture:** 服务端权威（SQLite via `node:sqlite`），客户端 JSON 缓存 + 离线 outbox；自动记账的解析/分类模型只在 Dart 写一份，Android 原生监听服务通过 headless Flutter 引擎调用它；AI 与备份全部在服务端完成，密钥不下发。

**Tech Stack:** Node 24（`node:sqlite`, `node:test`, 零 npm 依赖）；Flutter 3.32 / Dart 3.8（riverpod, go_router, http, fl_chart, shared_preferences, flutter_secure_storage, path_provider, intl, uuid, app_links, flutter_local_notifications）；Kotlin（NotificationListenerService）；Swift（Share Extension，仅代码）；Docker（node:24-bookworm-slim）。

**Spec:** `docs/superpowers/specs/2026-09-12-famledger-design.md`（API 契约在 §4.1，管线在 §6，视觉在 `DESIGN.md`）。

## Global Constraints

- 服务端：Node ≥ 22.13；**零第三方依赖**；金额一律整数分（`*Cents`）；时间 ISO-8601 字符串；错误体 `{error:{code,message}}`；所有路由前缀 `/api/v1`。
- 客户端：Flutter 3.32.1 / Dart 3.8.1 已装；**不用 build_runner/codegen**；UI 文案简体中文；Material 3；遵守 `DESIGN.md` 的 token；金额显示 `MoneyText`（tabular figures，`−¥1,234.56` / `+¥…`）。
- 不 commit、不 push；不改动 `priv/` 下其他项目。
- 测试：服务端 `cd server && npm test`（`node --test`）；客户端 `cd app && flutter test`；两者在任务结束时必须全绿。
- 数据库 schema **只在 Task 1 的迁移文件里定义一次**，后续任务不得改表结构（需要新列 = 回到 Task 1 补，并通知协调者）。

## File Structure

```
famledger/
├─ PRODUCT.md · DESIGN.md · README.md · CHANGELOG.md · .gitignore · .dockerignore
├─ docs/superpowers/{specs,plans}/
├─ server/
│  ├─ package.json                  {"scripts":{"start":"node src/server.js","test":"node --test --test-force-exit test/*.test.js"}}
│  ├─ src/server.js                 启动、cfg、模块挂载、静态、healthz
│  ├─ src/lib/router.js             Router(add/match/dispatch)、readBody、sendJson、sendError、HttpError
│  ├─ src/lib/db.js                 openDb(dataDir) → {db, tx(fn), nextSeq(), now()}；runMigrations
│  ├─ src/lib/auth.js               hashPassword/verifyPassword(scrypt)、signToken/verifyToken(HMAC)、requireAuth(role)
│  ├─ src/lib/secret.js             loadOrCreateSecret(dataDir)、encrypt/decrypt(AES-256-GCM)
│  ├─ src/lib/ratelimit.js          RateLimiter（照 explore_journal）
│  ├─ src/lib/clientip.js           clientIp(req, trustProxy)：CF-Connecting-IP > XFF[0] > socket
│  ├─ src/lib/log.js                level 日志
│  ├─ src/lib/sse.js                openSse(res) → {send(event,data), close()}
│  ├─ src/lib/webdav.js             WebDavClient{propfind,mkcolp,put,get,delete}
│  ├─ src/lib/validate.js           小型校验器：str/int/enum/bool/optional
│  ├─ src/sql/001_init.sql          全部表 + 索引
│  ├─ src/modules/{setup,auth,members,accounts,funds,categories,budgets,rules,transactions,stats,changes,settings,model,ai,backup,static}.js
│  ├─ src/modules/ai_providers.js   上游适配：anthropicStream/openaiStream → 统一 delta 流；presets
│  ├─ src/modules/ai_prompts.js     提示词模板（中文）
│  ├─ src/modules/seed.js           默认类别 / 基金模板 / NB 种子
│  └─ test/{helpers,auth,ledger,transactions,stats,changes,model,ai,backup,static}.test.js
├─ app/                               flutter create --org com.famledger --project-name famledger
│  ├─ pubspec.yaml
│  ├─ lib/main.dart                  runApp(ProviderScope(FamLedgerApp))
│  ├─ lib/app/{router.dart,theme.dart,providers.dart,shell.dart}
│  ├─ lib/core/{money.dart,dates.dart,ids.dart,result.dart}
│  ├─ lib/data/models/{member,account,fund,category,transaction,budget,rule,stats,ai_provider,backup_config,settings}.dart
│  ├─ lib/data/api/{api_client.dart,api_exception.dart,sse_client.dart,endpoints.dart}
│  ├─ lib/data/local/{secure_prefs.dart,local_store.dart,outbox.dart}
│  ├─ lib/data/repos/{session_repo,ledger_repo,transactions_repo,stats_repo,model_repo,ai_repo,backup_repo,settings_repo}.dart
│  ├─ lib/capture/{normalizer,source_profiles,parser,naive_bayes,seed_dataset,classifier,quick_reply,pipeline,headless_main}.dart
│  ├─ lib/platform/{capture_channel.dart,share_import.dart}
│  ├─ lib/ui/{auth,home,transactions,add_tx,funds,analysis,ai,settings,widgets}/…
│  ├─ android/app/src/main/kotlin/com/famledger/app/{MainActivity.kt,capture/*.kt}
│  ├─ ios/ShareExtension/*  ios/Runner/AppDelegate.swift
│  └─ test/{core,data,capture,ui}/…
├─ deploy/{Dockerfile,Dockerfile.full,docker-compose.yml,docker-compose.build.yml,cloudflared-ingress.example.yml}
├─ scripts/{build-web.sh,dev.sh,e2e-android.sh}
└─ .github/workflows/{test.yml,build.yml}
```

---

## Task 1: 服务端骨架、schema、基础库

**Files:** Create `server/package.json`, `server/src/server.js`, `server/src/lib/{router,db,auth,secret,ratelimit,clientip,log,sse,validate}.js`, `server/src/sql/001_init.sql`, `server/src/modules/{seed,setup,auth,members,settings,static}.js`, `server/test/{helpers,auth,static}.test.js`, `.gitignore`, `.dockerignore`.

**Interfaces（后续任务依赖）：**
```js
// lib/router.js
class Router { add(method, pattern, handler, {maxBody, auth:'none'|'member'|'admin'}) ; dispatch(req,res) }
// handler(req, res, ctx) ctx = {params, query, body(JSON 已解析), member?, deviceId?, ip}
function sendJson(res, status, obj); class HttpError extends Error {constructor(status, code, message)}
// lib/db.js
function openDb(dataDir) → { db /*DatabaseSync*/, tx(fn), nextSeq() /*int*/, now() /*ISO*/, close(), reopen() }
// lib/auth.js
hashPassword(pw)→string; verifyPassword(pw, hash)→bool; signToken(secret,{sub,tid,exp})→string; verifyToken(secret,token)→payload|null
// lib/secret.js
loadOrCreateSecret(dataDir)→Buffer(32); encrypt(secret, plaintext)→'enc:v1:<b64>'; decrypt(secret, enc)→string
// lib/sse.js
openSse(res)→{send(event, obj), close()}
// modules 约定
module.exports = (ctx /* {cfg, db, secret, log} */) => ({ name, routes:[{method, pattern, handler, auth, maxBody}], start?(), stop?() })
```

**Schema（001_init.sql，全部表一次定义）：**
```sql
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
```
`meta.change_seq` 初始 0；`nextSeq()` 在事务里 `UPDATE meta SET value=value+1 … RETURNING value`。

**Steps:**
- [ ] 写 `test/helpers.js`：`startServer(env)` 用 `child_process.spawn` 起 `src/server.js`（随机端口、临时 DATA_DIR、`WEB_ROOT` 指向临时目录）、`api(base).call(method, path, {token, body})` 返回 `{status, json}`。
- [ ] 写 `test/auth.test.js` 失败用例：① 空库 `GET /api/v1/setup/status` → `needsSetup:true`；② `POST /setup` 建 admin 返回 token；再次 `POST /setup` → 409；③ `POST /auth/login` 错口令 401、对口令 200；④ `GET /auth/me` 无 token 401、有 token 返回 member；⑤ `POST /auth/logout` 后同 token 401；⑥ 登录连打 11 次第 11 次 429（`LOGIN_PER_MIN=10`）；⑦ admin 建 member（`POST /members`）、member 角色调 `POST /members` → 403；⑧ `GET /settings` 默认 `currency:'CNY'`，`PATCH /settings {capture:{autoConfirmThreshold:0.8}}` 生效。
- [ ] 实现 lib + modules（setup/auth/members/settings），`SETUP_TOKEN` 非空时 `POST /setup` 需 header `x-setup-token`。setup 同时调用 `seed.seedDefaults(db)` 写默认类别与一个「家庭公共基金」（is_default=1，color `#c36a4f`）与一个「现金」账户。
- [ ] `static.js`：`WEB_ROOT` 存在 `index.html` 时服务静态（`index.html`/`flutter_service_worker.js`/`version.json` → `Cache-Control: no-cache`；其余 `public, max-age=31536000, immutable`；未知路径且非 `/api` → `index.html`）；不存在时 `/` 返回一段说明 HTML（「Web 产物未构建，见 README」）。`test/static.test.js`：临时 WEB_ROOT 放 `index.html` + `main.dart.js`，验证三种路径与缓存头，以及 `/api/v1/nope` → 404 JSON。
- [ ] 运行 `npm test` 全绿。

## Task 2: 账本主数据 + 流水 + 查重 + 同步游标

**Files:** Create `server/src/modules/{accounts,funds,categories,budgets,rules,transactions,changes}.js`, `server/src/lib/crud.js`（通用软删 CRUD 工厂）, `server/test/{ledger,transactions,changes}.test.js`。

**Interfaces:**
```js
// lib/crud.js
makeCrud({ table, resource, fields:{name:{type:'string',required:true,max:64}, ...}, listOrder:'sort_order ASC, created_at ASC', toJson(row), fromBody(body,isPatch) })
// → routes: GET /<resource>?archived=1  POST  PATCH /:id  DELETE /:id(软删: deleted_at=now, seq=nextSeq)  PUT /<resource>/reorder {ids}
// transactions.js 导出 detectDuplicate(db, {type, amountCents, occurredAt, excludeId}) → row|null （±180s, source∈notification|share 的新纪录才调用）
```
JSON 字段用 camelCase（`amountCents`），DB 用 snake_case；`toJson` 统一转换；`tags`/`matchHints` JSON 解析。

**Tests（写在先）：**
- ledger：账户 CRUD + 软删后列表不含、`?archived=1` 含归档；基金 `GET /funds/templates` ≥ 6 条且含 `宠物基金`；类别 `POST` kind 非法 → 400；`PUT /funds/reorder`；预算 `PUT /budgets {scope:'fund',refId,month:'*',amountCents:50000}` 后 `GET /budgets?month=2026-09` 返回它，再 `PUT` 精确月 `2026-09` 覆盖默认；规则 CRUD。
- transactions：`POST` 支出（带 clientId）→ 201；同 clientId 再 POST → 200 且同 id；`GET ?fundId=` 过滤；游标分页 limit=2 三条数据两页；`PATCH` 改金额；`DELETE` 后 `GET /:id` 404；`POST /:id/confirm` pending→confirmed；`batch` 混合 created/exists/error；查重：source=notification 同金额 2 分钟内第二笔 → `status:'duplicate'`、`duplicateOfId`、响应 `duplicate:true`；source=manual 不查重；转账只填 fund 对合法、fund 对与 account 对都空 → 400。
- changes：`GET /changes?since=0` 返回全部实体；写一笔后 `since=上次 next` 只返回新行；软删行含 `deletedAt`；`limit=1` 时 `more:true`。

## Task 3: 统计

**Files:** Create `server/src/modules/stats.js`, `server/test/stats.test.js`。
- 口径：余额 = initial + Σ(收入) − Σ(支出) ± 转账；只算 `status='confirmed'` 且 `deleted_at IS NULL`（pending 不计入余额，但 `pendingCount` 报出）。信用卡账户余额为负计入 `liabilitiesCents`。月份边界用 `occurred_at` 的 `YYYY-MM` 前缀（服务器 TZ）。
- Tests：造 2 账户（现金 100000 初始、信用卡 0）、2 基金、3 类别、若干流水（含 pending、软删、拨款、跨月），断言 overview 各聚合值；trend 12 个月长度、缺月补 0；`stats/fund/:id` 的 `byCategory` 与 `recent`；`stats/calendar` 天数聚合。

## Task 4: 共享 NB 模型端点

**Files:** Create `server/src/modules/model.js`, `server/src/lib/nb.js`, `server/test/model.test.js`。
- `lib/nb.js`（与 Dart 实现保持**同一序列化格式**）：
```js
// {version:int, classes:{[label]:{docs:int, tokens:int, counts:{[token]:int}}}, vocab:int, totalDocs:int}
tokenize(text, extras=[]) // 字符 1-gram + 2-gram（去空白/标点，全角转半角，小写）+ extras（如 'm:美团' 'dir:expense' 'ch:alipay' 'amt:b3' 'h:12' 'wd:5'）
learn(model, tokens, label); predict(model, tokens) → [{label, p}] 按 p 降序（拉普拉斯平滑 α=1，log 域；空模型返回 []）
```
- 端点：`GET /model` 为空时返回由 `seed.js` 种子训练的模型；`POST /model/learn` 累加并 `version++`；`DELETE /model` 重置。
- Tests：learn 三条样本后 predict top 正确；序列化往返；端点 version 单调；重置后与种子相同。

## Task 5: AI 渠道

**Files:** Create `server/src/modules/{ai,ai_providers,ai_prompts}.js`, `server/test/ai.test.js`（内嵌假 Anthropic/OpenAI 上游 http 服务器）。
- presets：`[{key:'cc-trans',name:'cc-trans（自建 Anthropic 反代）',kind:'anthropic',baseUrl:'http://<host>:8787',model:'claude-sonnet-5'}, {key:'siliconflow',kind:'openai',baseUrl:'https://api.siliconflow.cn/v1',model:'Qwen/Qwen3-32B'}, deepseek(https://api.deepseek.com/v1, deepseek-chat), moonshot(https://api.moonshot.cn/v1, kimi-k2-0711-preview), zhipu(https://open.bigmodel.cn/api/paas/v4, glm-4.5), openai(https://api.openai.com/v1, gpt-5-mini), anthropic(https://api.anthropic.com, claude-sonnet-5), ollama(http://host.docker.internal:11434/v1, qwen3:8b)]`。
- anthropic：`POST {baseUrl}/v1/messages`，headers `x-api-key`, `anthropic-version: 2023-06-01`, `content-type`；body `{model, max_tokens:2048, system, messages, stream:true}`；解析 SSE：`content_block_delta` → `delta.text`；`message_stop` 结束；`usage` 累计。
- openai：`POST {baseUrl}/chat/completions`（baseUrl 已含 `/v1`），`Authorization: Bearer`；`{model, messages:[{role:'system'},...], stream:true}`；`data: [DONE]`；`choices[0].delta.content`。
- 统一：`streamChat(provider, {system, messages}, onDelta) → {text, usage}`；非流式 `complete()` 用于 classify/test。
- 上下文：`buildFinanceContext(db, month)` 生成中文文本块（本月总览、各基金余额/预算/目标、类别 Top8、近 6 月趋势、成员支出）。
- 报告落 `ai_reports`；apiKey 加密存储；`PATCH` 时 `apiKey:''` 表示不改。
- Tests：假上游按 kind 回放固定分片；`POST /ai/chat` 收到 `delta` 事件拼接等于假上游文本、`done` 事件含 usage；`report` 后 `GET /ai/reports?month=` 有一条；`classify` 假上游回 `{"categoryId":"c1","fundId":"f1","confidence":0.9}` → 200 解析；假上游 500 → SSE `error` 事件；providers 列表不含明文 key 且 `hasKey:true`。

## Task 6: WebDAV 备份

**Files:** Create `server/src/lib/webdav.js`, `server/src/modules/backup.js`, `server/test/backup.test.js`（内嵌假 WebDAV 服务器：内存 Map，支持 OPTIONS/PROPFIND(Depth 1, 返回 207 multistatus XML)/MKCOL/PUT/GET/DELETE，Basic 鉴权）。
- 快照：`db.exec("VACUUM INTO ?")` 到临时文件 → `zlib.gzipSync` → 可选加密（`FLBK1|salt16|nonce12|ct|tag16`，`crypto.scryptSync(pass, salt, 32, {N:32768,r:8,p:1})`）→ `PUT {remoteDir}/famledger-YYYYMMDD-HHMMSS.db.gz[.enc]` + `PUT 同名.json` manifest `{app:'famledger', formatVersion:1, createdAt, bytes, sha256, encrypted, schemaVersion}`。
- 保留：列出目录、按名字时间戳排序、删除超出 `keep` 的最旧（同时删 manifest）。
- 调度：`setInterval` 每分钟检查一次，`schedule.enabled && 当前小时 == hour && 今天未跑`（`meta.backup_last_day`）。
- 恢复：下载 → 解密/解压 → 写临时文件 → `PRAGMA integrity_check` == ok → `ctx.dbHandle.close()` → 当前库复制为 `pre-restore-<ts>.db` → 替换 → `reopen()`。导出/导入端点同此路径。
- Tests：test 端点对错口令 401 → `{ok:false}`；run 后假服务器有 2 个对象且 manifest sha256 匹配；keep=2 跑 3 次剩 2 组；加密后文件头 `FLBK1`、restore 后数据一致（先写一笔、备份、改数据、restore、数据回到备份时刻）；export 返回 gzip 魔数 `1f8b`。

## Task 7: Docker 与脚本

**Files:** Create `deploy/{Dockerfile,Dockerfile.full,docker-compose.yml,docker-compose.build.yml,cloudflared-ingress.example.yml}`, `scripts/{build-web.sh,dev.sh}`, `CHANGELOG.md`（`## 0.1.0`）。
- `Dockerfile`（context = 仓库根）：`FROM node:24-bookworm-slim`；`apt-get install -y --no-install-recommends curl tzdata`；`COPY server/ /app/server/`；`COPY app/build/web/ /web/`（不存在时由 `scripts/build-web.sh` 先产出；仓库放 `app/build/web/.gitkeep`）；`USER node`；`ENV PORT=48090 DATA_DIR=/data WEB_ROOT=/web TRUST_PROXY=1 NODE_ENV=production`；`VOLUME /data`；`HEALTHCHECK curl -fsS http://127.0.0.1:48090/healthz`；`CMD ["node","/app/server/src/server.js"]`。
- `Dockerfile.full`：stage1 `ghcr.io/cirruslabs/flutter:3.32.1` → `flutter build web --release`；stage2 同上 COPY --from。
- compose：端口 `${FL_PORT:-48090}:48090`，卷 `${FL_DATA_PATH:-fldata}:/data`，环境 `TZ`、`TRUST_PROXY`、`SETUP_TOKEN`。
- 验证：`docker build -f deploy/Dockerfile -t famledger:dev .` 成功；起容器 `curl /healthz` = ok；`/api/v1/setup/status` JSON。

## Task 8: Flutter 基础层（模型、API、缓存、outbox、主题、外壳、连接/登录）

**Files:** `cd app && flutter create --org com.famledger --project-name famledger --platforms android,ios,web .`；Create `lib/main.dart`, `lib/app/{router,theme,providers,shell}.dart`, `lib/core/*`, `lib/data/models/*`, `lib/data/api/*`, `lib/data/local/*`, `lib/data/repos/{session_repo,ledger_repo,transactions_repo,stats_repo,settings_repo}.dart`, `lib/ui/auth/{connect_page,login_page,setup_page}.dart`, `lib/ui/widgets/{money_text,fund_dot,category_icon,empty_state,skeleton,section_header,async_value_view}.dart`, `test/core/money_test.dart`, `test/data/{models_test,outbox_test,api_client_test}.dart`。

**Interfaces（后续 UI 任务依赖）：**
```dart
// core/money.dart
class Money { static String format(int cents, {bool signed=false, bool showSymbol=true}); static int parse(String s); }  // 123456 → '¥1,234.56'; signed: '−¥…' / '+¥…'（U+2212）
// data/api/api_client.dart
class ApiClient { ApiClient({required String baseUrl, String? token, http.Client? inner});
  Future<Map<String,dynamic>> get(String path, {Map<String,String>? query}); Future<Map<String,dynamic>> post(String path, Object? body);
  Future<Map<String,dynamic>> patch(...); Future<void> delete(String path); Stream<SseEvent> sse(String path, Object? body); }
class ApiException implements Exception { final int status; final String code; final String message; }
// data/local/local_store.dart  —— JSON 文件缓存（web 用 shared_preferences）
class LocalStore { Future<T?> read<T>(String key); Future<void> write(String key, Object json); Future<void> remove(String key); }
// data/local/outbox.dart
class Outbox { Future<void> enqueue(OutboxItem item); Future<List<OutboxItem>> pending(); Future<void> markDone(String clientId); }
class OutboxItem { final String clientId; final String op; /* create|patch|delete|confirm|learn */ final Map<String,dynamic> payload; final DateTime queuedAt; }
// data/repos/session_repo.dart
class SessionRepo { Future<Session?> restore(); Future<void> connect(String baseUrl); Future<void> setup(...); Future<void> login(String u, String p); Future<void> logout(); }
class Session { final String baseUrl; final String token; final Member me; final String deviceId; }
// data/repos/ledger_repo.dart —— 主数据缓存 + changes 增量
class LedgerRepo { Future<void> sync(); List<Fund> funds; List<Account> accounts; List<Category> categories; List<Member> members; List<Rule> rules; Stream<void> get changes; CRUD 方法各一 }
// data/repos/transactions_repo.dart
class TransactionsRepo { Future<TxPage> list(TxFilter f, {String? cursor}); Future<Transaction> create(TransactionDraft d); Future<Transaction> update(String id, Map<String,dynamic> patch); Future<void> delete(String id); Future<void> confirm(String id); Future<void> flushOutbox(); }
// app/providers.dart：sessionProvider, apiProvider, ledgerProvider, transactionsRepoProvider, statsProvider(month), settingsProvider, connectivity-free：flush 在每次 API 成功后触发
// app/router.dart 路径：/connect /setup /login /home /transactions /transactions/new /transactions/:id /funds /funds/new /funds/:id /analysis /ai/chat /ai/report /settings /settings/{members,accounts,categories,budgets,rules,capture,ai,backup,server,about}
// app/shell.dart：AdaptiveShell(child)：<600 NavigationBar+FAB；600-839 NavigationRail；≥840 Rail(extended)+ 右侧栏 slot
```
- 主题：按 DESIGN.md 手写 `ColorScheme`（light/dark）与 `TextTheme`（tabular figures 的 `moneyStyle`）。
- 连接流程：`/connect` 输入 URL（自动补 `https://`，Web 上默认同源且可改）→ `GET /healthz` + `/setup/status` → 需初始化 → `/setup`；否则 `/login`。会话存 `flutter_secure_storage`（Web 落 localStorage 即可）。
- Tests：Money 格式化/解析 8 例；模型 fromJson/toJson 往返；Outbox 幂等（同 clientId 入队两次只剩一条）；ApiClient 用 `MockClient` 断言 header `Authorization: Bearer` 与错误映射为 `ApiException(code)`。
- 验证：`flutter analyze` 0 error；`flutter test` 绿；`flutter build web --release` 成功。

## Task 9: 核心页面（首页、账单、记一笔、基金）

**Files:** Create `lib/ui/home/{home_page,fund_carousel,pending_captures_card,month_summary,recent_list}.dart`, `lib/ui/transactions/{transactions_page,tx_filter_sheet,tx_tile,tx_detail_page}.dart`, `lib/ui/add_tx/{add_tx_page,amount_keypad,category_grid,fund_picker,account_picker,member_picker}.dart`, `lib/ui/funds/{funds_page,fund_form_page,fund_detail_page,fund_template_sheet,allocate_sheet}.dart`, `test/ui/{add_tx_test,tx_tile_test}.dart`（widget tests）。
- 首页数据：`GET /stats/overview?month=`；基金卡片显示余额、目标进度（`targetCents`）或月预算进度；待确认列表 = `GET /transactions?status=pending&limit=5`，行内「确认」「修改」。
- 账单：`ListView` 按日分组头（日期 + 当日支出/收入合计）、无限滚动游标、筛选底部弹层、搜索框；滑动删除 + Snackbar 撤销（撤销 = 重新 `create` 同 clientId? 不：服务端软删无法恢复 → 改为二次确认删除，不做撤销）。
- 记一笔：金额键盘（0-9 . ⌫ 、快捷 +/−）、类型分段控件、类别网格（按 kind 过滤）、基金芯片、账户、成员、日期时间、商户、备注；「保存」→ `TransactionsRepo.create`，离线时入 outbox 并提示「已离线保存」。转账模式：账户对 / 基金对 两组可选，至少一组。
- 基金：列表（余额、进度条、本月支出）；新建走模板弹层；详情：余额、目标/预算、`stats/fund/:id` 类别构成（fl_chart 环形）、近 6 月趋势（柱状）、流水、「拨款」弹层（fund→fund 转账）、编辑/归档。
- Widget tests：记一笔页输入 `35.5` 显示 `¥35.50`，未选基金点保存出现校验提示；`TxTile` 支出显示 `−¥35.50`（含 U+2212）。

## Task 10: 分析、设置各页

**Files:** Create `lib/ui/analysis/{analysis_page,trend_chart,category_donut,member_bars}.dart`, `lib/ui/settings/{settings_page,members_page,member_form,accounts_page,account_form,categories_page,category_form,budgets_page,rules_page,rule_form,server_page,about_page}.dart`。
- 分析：月份选择器；趋势（12 月柱状，收入/支出双色）；类别环形 + 列表（占比、金额、环比）；成员横条；基金占比。图表色用基金/类别色，其他用 DESIGN.md 12 色盘。
- 设置页分组列表：家庭（成员/账户/类别/预算/识别规则）、自动记账（Task 12 的页面入口）、AI 渠道（Task 11）、备份（Task 11）、服务器与账号（改地址=退出重连、改密码、登出）、关于（版本、开源许可）。
- 校验：非 admin 隐藏成员管理写操作。

## Task 11: AI 与备份的客户端页面

**Files:** Create `lib/data/repos/{ai_repo,backup_repo}.dart`, `lib/data/models/{ai_provider,backup_config}.dart`(若 Task 8 未建), `lib/ui/ai/{ai_chat_page,ai_report_page,message_bubble}.dart`, `lib/ui/settings/{ai_providers_page,ai_provider_form,backup_page}.dart`, `test/data/sse_client_test.dart`。
- SSE 客户端：`http.Client().send(StreamedRequest)` 逐行解析 `event:`/`data:`，产出 `SseEvent(event, data)`；网络断开抛 `ApiException('network')`。
- 对话页：消息列表 + 输入框 + 流式渲染（简单 Markdown：粗体、列表、标题即可，自写轻量渲染或 `flutter_markdown` 兼容包——优先自写以免依赖过期）；上下文月份选择；「生成本月报告」进入报告页流式显示并可查看历史报告。
- 渠道页：列表（默认标记、测试按钮 → 显示延迟与样例）、表单（预设下拉自动填 baseUrl/model、apiKey 密文输入、cc-trans 提示「填 cct- 令牌」）。
- 备份页：WebDAV 表单（URL/用户名/口令/远端目录）、测试连接、定时（开关/小时/保留份数）、加密（开关/密语）、「立即备份」、远端列表（大小/时间/加密标记/「恢复」二次确认）、导出到本机（Web 直接下载；移动端 `share_plus`）。
- Test：SSE 解析器对分片边界（一个 chunk 含 1.5 条事件）正确。

## Task 12: 自动记账 Dart 管线（纯 Dart，可与 8–11 并行）

**Files:** Create `lib/capture/{normalizer,source_profiles,parser,naive_bayes,seed_dataset,classifier,quick_reply,pipeline}.dart`, `test/capture/{normalizer_test,parser_test,naive_bayes_test,classifier_test,quick_reply_test,pipeline_test}.dart`, `test/capture/fixtures/notifications.json`（≥ 40 条样本：支付宝 12、微信 12、云闪付 4、银行短信 10、噪声 6 如「红包」「花呗账单提醒」「验证码」）。

**Interfaces（Task 13 依赖）：**
```dart
class RawNotification { final String packageName, title, text, bigText; final DateTime postedAt; }
class ParsedPayment { final int? amountCents; final PayDirection direction; /* expense|income|transfer|unknown */ final String merchant; final String channel; /* alipay|wechat|unionpay|bank_sms|unknown */ final String? cardTail; final DateTime occurredAt; final double parseConfidence; final bool isPayment; /* false = 噪声，直接丢弃 */ }
class NotificationParser { ParsedPayment parse(RawNotification n); }
class NaiveBayes { /* 与 server/src/lib/nb.js 相同的 JSON 格式 */ factory NaiveBayes.fromJson(Map); Map toJson(); void learn(List<String> tokens, String label); List<Prediction> predict(List<String> tokens); static List<String> tokenize(String text, List<String> extras); }
class ClassifierCandidate { final String id, name; final List<String> aliases; }
class ClassifyInput { final ParsedPayment payment; final String rawText; final String? memberId; }
class ClassifyResult { final String? categoryId, fundId, accountId; final double confidence; final String reason; /* 'rule:<id>'|'nb'|'default' */ }
class Classifier { Classifier({required NaiveBayes categoryModel, required NaiveBayes fundModel, required List<Rule> rules, required List<ClassifierCandidate> categories, funds, required List<Account> accounts, String? defaultFundId, String? defaultAccountId});
  ClassifyResult classify(ClassifyInput i); void learn(ClassifyInput i, {String? categoryId, String? fundId}); }
class QuickReplyInterpreter { QuickReplyPatch interpret(String text, {required List<ClassifierCandidate> funds, categories}); }
class QuickReplyPatch { final String? fundId, categoryId, note; final int? amountCents; final String? type; }
class CapturePipeline { Future<CaptureOutcome> handle(RawNotification n); Future<void> applyQuickReply(String captureId, String text); Future<void> confirm(String captureId); Future<void> undo(String captureId); }
class CaptureOutcome { final CaptureDecision decision; /* recorded|pending|duplicate|ignored */ final TransactionDraft? draft; final String title, body; /* 结果通知文案 */ final String? captureId; }
```
- 解析规则要点：金额正则 `(?:¥|￥|人民币|RMB)?\s*(\d{1,3}(?:,\d{3})*|\d+)(?:\.(\d{1,2}))?\s*元?`，优先带货币符号/「元」的匹配，排除「余额」「可用」「积分」「验证码」附近的数字；方向关键词见 spec §6；商户抽取：「向(.+?)付款」「收款方[:：](.+)」「商户[:：](.+)」「在(.+?)消费」等，兜底取 title 去掉 App 名。
- 阈值：`confidence = min(parseConfidence, topP)`；`topP` 由 NB 后验；有规则命中 → 1.0。
- 金额桶 extras：`amt:b0`(<10) `b1`(<50) `b2`(<200) `b3`(<1000) `b4`(≥1000)。
- Pipeline 依赖注入接口：`CaptureStore`（读写 pending capture、dedupe 哈希、模型 JSON）、`CaptureApi`（创建/patch/confirm/删除流水、`/model/learn`、可选 `/ai/classify`）。测试用假实现。
- Tests：fixtures 全量：噪声 `isPayment=false`；支付类金额与方向 100% 正确；商户抽取 ≥ 80% 命中期望；NB 学习 5 例后 predict 正确；快捷回复「宠物」→ fundId=宠物基金、「35」→ 3500 分、「收入」→ type income、「给猫买粮」→ note；pipeline：同一通知两次 → 第二次 `duplicate`；置信度低 → `pending`。

## Task 13: Android 原生监听 + headless 引擎 + 结果通知 + 设置页 + 真机端到端

**Files:** Create `android/app/src/main/kotlin/com/famledger/app/{MainActivity.kt, capture/CaptureListenerService.kt, capture/HeadlessEngine.kt, capture/ResultNotifier.kt, capture/ActionReceiver.kt, capture/CapturePlugin.kt, capture/CapturePrefs.kt}`, Modify `android/app/src/main/AndroidManifest.xml`, `android/app/build.gradle.kts`（minSdk 24, `applicationId com.famledger.app`）, Create `lib/capture/headless_main.dart`, `lib/platform/capture_channel.dart`, `lib/ui/settings/capture_page.dart`, `scripts/e2e-android.sh`。

**MethodChannel 契约（`com.famledger/capture`）：**
```
Dart→Native: isListenerEnabled()→bool; openListenerSettings(); openAutoStartSettings()(MIUI 跳转，失败回落到应用详情); getAllowedPackages()→[String]; setAllowedPackages([String]); getInstalledApps()→[{package,label}]; postTestNotification(title,text)(自家渠道，仅调试); headlessReady()(headless 引擎就绪信号)
Native→Dart(headless): onNotification({id, package, title, text, bigText, postedAt}) → 返回 {decision, title, body, captureId, actions:[confirm|edit|undo]}; onAction({captureId, action:'confirm'|'undo'|'reply', text?}) → {title, body}
Native→Dart(main): onOpenCapture(captureId)  (点击通知 → 打开 /transactions/:id)
```
- `HeadlessEngine`：单例；`FlutterEngine(context)` + `DartExecutor.DartEntrypoint(FlutterInjector.instance().flutterLoader().findAppBundlePath(), "captureMain")`；`GeneratedPluginRegistrant.registerWith(engine)`；就绪前事件入队；空闲 10 分钟销毁引擎。
- `CaptureListenerService.onNotificationPosted`：过滤包名（`CapturePrefs` 存 allowed set；debug 构建默认加 `com.android.shell`）、跳过 `FLAG_GROUP_SUMMARY`、跳过自家包名；取 `EXTRA_TITLE/EXTRA_TEXT/EXTRA_BIG_TEXT`；调 `HeadlessEngine.dispatch`。
- `ResultNotifier`：渠道 `capture_results`（IMPORTANCE_DEFAULT）；动作：正确（PendingIntent→ActionReceiver）、修改…（`RemoteInput` key `reply`）、撤销；contentIntent 深链 `famledger://capture/<captureId>`。回复后更新同一通知为「已更新：…」。
- 设置页：监听权限状态卡片（未开 → 按钮跳转）、MIUI 自启动引导、允许应用（多选，可搜索）、置信阈值滑条、默认基金/账户、AI 兜底开关、「测试解析」输入框（粘贴文本 → 显示解析结果）、最近捕获日志（本地 50 条）。
- `scripts/e2e-android.sh`：`flutter build apk --debug` → `adb install -r` → `adb shell cmd notification allow_listener com.famledger.app/.capture.CaptureListenerService` → `adb shell cmd notification post -t '支付宝' fam1 '你有一笔35.00元的支出，来自美团'` → 轮询 `GET /transactions?source=notification`。
- 验证：真机执行脚本，后端出现该流水；截图结果通知（`adb exec-out screencap`）。

## Task 14: iOS 分享扩展与快捷指令（仅代码）+ 剪贴板导入

**Files:** Create `ios/ShareExtension/{ShareViewController.swift,Info.plist,ShareExtension.entitlements}`, Modify `ios/Runner/AppDelegate.swift`, `ios/Runner/Info.plist`（URL scheme `famledger`，App Group `group.com.famledger.app`），`ios/Runner/Runner.entitlements`；Create `lib/platform/share_import.dart`（`app_links` 监听 `famledger://capture?text=`、iOS MethodChannel `com.famledger/share` 读取 App Group 里的待处理文本），`lib/ui/settings/capture_page.dart` iOS 分支（说明 + 「从剪贴板导入」）。
- 主 App 收到文本 → `CapturePipeline.handle` 同一管线 → 结果用 `flutter_local_notifications` 展示，动作含文本输入（iOS `DarwinNotificationAction.text`）。
- 文档 `docs/ios.md`：Xcode 里添加 Share Extension target 的手工步骤（因无法在 Linux 生成 pbxproj 变更），App Group、Bundle ID、签名。
- 验证：`flutter analyze` 通过；Swift 只做人工审阅。

## Task 15: CI、README、最终验证

**Files:** Create `.github/workflows/test.yml`（push/PR：server `npm test`；`flutter analyze`、`flutter test`），`.github/workflows/build.yml`（workflow_dispatch：`flutter build web` → `docker buildx` 双架构推 GHCR `ghcr.io/<owner>/famledger`；`flutter build apk --release` 上传 artifact），`README.md`（部署三步、Cloudflare ingress、首启向导、自动记账权限（MIUI）、AI 渠道预设（cc-trans 令牌）、WebDAV（坚果云示例）、开发与测试命令、架构图、已知限制：iOS 无法读他人通知）。
- 最终验证清单：`npm test` 绿；`flutter analyze`/`flutter test` 绿；`flutter build web` + Docker 镜像 build + 容器冒烟（setup → login → 建流水 → overview）；APK 真机安装 + 通知端到端。

## Self-Review

- Spec 覆盖：§1–§9 → Task 1–15 一一对应；§10 不做项无任务；§11 里程碑顺序 = 任务顺序。
- 类型一致：`amountCents`/`occurredAt`/`clientId`/`captureId` 全文统一；NB JSON 格式 Dart/Node 同源（Task 4 与 12 都写明）。
- 无占位：所有任务给出文件、接口与测试断言；代码体由实现者按接口填写。
