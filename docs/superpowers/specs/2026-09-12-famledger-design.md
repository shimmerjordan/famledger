# famledger（家账）—— 家庭金融管理 App 设计文档

日期：2026-09-12　状态：已按「静默采用推荐方案」定稿，未经用户逐项审批；所有取舍附理由，便于醒来后推翻。

## 0. 一句话

一个部署在 NAS 单容器里的家庭账本：**资金按「基金模块」自定义划分**，手机端**监听支付通知、本地轻量模型自动识别**并可在通知栏一键纠正，数据 **WebDAV 备份**，接 **cc-trans / 硅基流动等 AI 渠道**做分析建议；Web 看板、Android、iOS 共用一份 Flutter 代码，后端地址可配。

## 1. 需求 → 决策对照

| 用户需求 | 决策 | 理由 / 被否掉的选项 |
|---|---|---|
| 1 单容器跑 NAS，Cloudflare 访问前端看板 + 后端 | 一个 Node 进程同时服务 `/api/*` 与 Flutter Web 静态产物；单端口 48090；镜像走 GHCR，也可本地 build | 与 explore_journal 合并镜像同思路但更简单（单进程无需 supervisord）。家宽封 80/443，走高位端口 + CF Tunnel |
| 1 Android/iOS App，后端地址可配 | Flutter 3.32 一套代码出 Android / iOS / Web；首次启动填服务器地址（Web 版默认同源） | 单独写 RN/原生 = 三套 UI。用户已有 Flutter 经验（explore_journal/poseref） |
| 2 模块化资金管理 | 两层模型：**账户**（钱物理在哪：银行卡/支付宝/微信/现金/信用卡）× **基金**（钱逻辑归谁/干什么：个人、公共、养老、育儿、宠物…）。每笔流水恰归一个基金；基金间可「拨款」 | 只有账户（随手记式）表达不了「公共基金里划 500 给宠物」；只有信封（YNAB 式）又对不上银行余额。两层正交才能同时回答「卡里有多少」和「宠物还能花多少」 |
| 3 捕获通知 + 本地轻量模型识别 + 通知栏快捷修正 | Android：原生 `NotificationListenerService` → 常驻 headless Flutter 引擎跑 Dart 解析器；模型 = 规则抽取（金额/方向/商户/渠道）+ 朴素贝叶斯字符 n-gram 分类（类别、基金），可在线学习并全家同步；结果通知带「正确 / 修改（RemoteInput 输入）/ 撤销 / 打开」。iOS 系统不开放读取他人通知 → 分享扩展 + 快捷指令 + 剪贴板导入 + 自家通知的文本输入动作 | 模型只写一遍 Dart（不在 Kotlin/Swift 各写一份）。不下载几百 MB 的端侧 LLM：支付通知是半结构化文本，规则 + NB 在 <1ms 内给出高精度，低置信度时可选走后端 AI 渠道兜底（默认关） |
| 4 WebDAV 备份 | 服务端定时把 SQLite 一致性快照 gzip（可选 AES-256-GCM）PUT 到 WebDAV；保留最近 N 份；支持列出/恢复；也可手动导出/导入 | 零依赖：WebDAV 就是 HTTP + 极简 XML；参考 repo_git backup.py 的「裸 DB 为主」思路 |
| 5 AI 分析建议，兼容 cc-trans / 硅基流动等 | 后端 `providers` 表：kind ∈ {anthropic, openai}，base_url/api_key/model 可配、预设一键填。cc-trans = anthropic kind（`/v1/messages`，x-api-key）；硅基流动/DeepSeek/月之暗面/智谱/Ollama = openai kind（`/v1/chat/completions`）。SSE 统一转成自家流格式 | 密钥只存服务端（AES-GCM 加密），手机与 Web 不接触；聚合数据由服务端算好注入提示词，不让模型直接查库 |

## 2. 总体架构

```
┌──────────── 手机 (Android / iOS) ────────────┐        ┌──────── NAS 单容器 :48090 ────────┐
│ Flutter App（UI）                             │ HTTPS  │ server/ (Node 24, 零依赖)          │
│  ├ data/api  ── REST+SSE ─────────────────────┼──CF──▶│  ├ /api/v1/*  JSON                 │
│  ├ data/local  JSON 缓存 + 离线 outbox        │        │  ├ /api/v1/ai/* SSE ──▶ cc-trans / 硅基流动…│
│  └ capture/  解析器 + NB 模型（Dart，单份）     │        │  ├ backup 调度 ──▶ WebDAV           │
│ Android 原生：NotificationListener → headless │        │  ├ node:sqlite  /data/famledger.db  │
│   Flutter 引擎 → 结果通知（RemoteInput 动作）  │        │  └ 静态：Flutter Web 看板 (/)       │
│ iOS 原生：Share Extension → URL scheme → App   │        └───────────────────────────────────┘
└──────────────────────────────────────────────┘        浏览器（Web 看板）= 同一份 Flutter 代码，响应式
```

**数据权威在服务端**（server-authoritative）。手机端只做：读缓存 + 写 outbox（离线可记账，联网后批量提交，`clientId` 幂等）。不做双向冲突合并——家庭多人多设备 + NAS 常在线，这是最省事也最不容易丢账的方案。

## 3. 领域模型（金额一律整数「分」，`currency` 默认 CNY）

- **household** 单租户（一次部署 = 一个家庭）；`settings` 表存家庭级设置。
- **members** 成员 = 登录用户 + 档案：`id, username, passwordHash(scrypt), displayName, color, avatarEmoji, role(admin|member), archived`。
- **accounts** 账户：`id, name, kind(cash|bank|alipay|wechat|credit|invest|other), ownerMemberId?, initialBalanceCents, currency, icon, color, sortOrder, archived, matchHints(JSON: 卡尾号/包名/关键字，供自动识别选账户)`。余额 = initial + Σ流水。
- **funds** 基金/模块：`id, name, kind(personal|shared|goal|reserve|custom), ownerMemberId?, icon, color, targetCents?, monthlyBudgetCents?, description, sortOrder, archived, isDefault`。余额 = Σ流水（收入 +、支出 −、拨入 +、拨出 −）。`kind` 只影响展示与模板，不限制行为。内置模板：个人零花、家庭公共基金、养老储备、育儿基金、宠物基金、应急金、旅行基金、房贷车贷还款金。
- **categories** 类别：`id, name, kind(expense|income), parentId?, icon, color, sortOrder, archived`。首次初始化种默认中文类别（餐饮/交通/购物/居家/水电/通讯/医疗/教育/育儿/宠物/娱乐/人情/旅行/保险/其他；收入：工资/奖金/理财/退款/转账收入/其他）。
- **transactions** 流水：`id, clientId(uuid, 幂等), type(expense|income|transfer), amountCents, currency, occurredAt(ISO), accountId?, toAccountId?, fundId?, toFundId?, categoryId?, memberId(谁的行为), merchant, note, tags(JSON), source(manual|notification|share|import|recurring), status(confirmed|pending|duplicate|void), confidence?, rawText?, sourceApp?, captureId?, duplicateOfId?, createdBy, createdAt, updatedAt, deletedAt?, seq`。
  - 支出：`fundId` −，`accountId` −；收入：+ +；
  - 转账：`accountId→toAccountId` 与 `fundId→toFundId` **各自可选、正交**；「拨款」= 只填 fund 对。
  - 软删除 + 全局 `seq` 供同步。
- **budgets**：`id, scope(fund|category), refId, month(YYYY-MM 或 '*' 表示每月默认), amountCents`。
- **rules** 自动识别规则：`id, priority, field(merchant|text|app), op(contains|regex), pattern, categoryId?, fundId?, accountId?, memberId?, enabled`。
- **model** 全家共享 NB 计数：`key(category|fund), json, version`。设备学习增量 `POST /model/learn` → 服务端累加计数 → 各设备拉全量。
- **ai_providers**：`id, name, kind(anthropic|openai), baseUrl, apiKeyEnc, model, isDefault, enabled, extra(JSON)`。
- **ai_reports**：`id, month, providerId, content(markdown), createdAt`。
- **devices**：`id, memberId, name, platform, tokenId, lastSeenAt` —— 登录即建，登出即吊销。
- **activity**：轻量审计 `who, what, entity, entityId, at`。

## 4. 后端 `server/`（Node ≥ 22.13，零第三方依赖）

- 结构：`src/server.js`（启动/路由挂载/静态）、`src/lib/{router,db,auth,crypto,ratelimit,log,sse,webdav,gzip,http}.js`、`src/modules/{setup,auth,members,accounts,funds,categories,transactions,budgets,rules,model,stats,changes,ai,backup,settings}.js`、`src/sql/migrations/*.sql`、`test/*.test.js`（`node --test`）。
- DB：`node:sqlite` WAL，`PRAGMA foreign_keys=ON`，迁移表 `schema_migrations`。
- 鉴权：scrypt 口令；令牌 = `base64url(json).base64url(hmac)`，30 天，`tokenId` 落 `devices` 表可吊销；`Authorization: Bearer`。登录限流 10/min/IP（`TRUST_PROXY=1` 时 IP 取 `CF-Connecting-IP` > `X-Forwarded-For` 首个）。
- 首次初始化：无用户时 `POST /api/v1/setup` 开放（可选 `SETUP_TOKEN` 环境变量加锁）；Web 首屏检测 `needsSetup` 走向导。
- 静态：`WEB_ROOT`（默认 `/web`）；SPA 回退 `index.html`；`flutter_service_worker.js` 与 `index.html` 不缓存，带 hash 资源长缓存。
- 环境变量：`PORT=48090 DATA_DIR=/data WEB_ROOT=/web TRUST_PROXY=1 TZ=Asia/Shanghai SETUP_TOKEN= CORS_ORIGINS= LOG_LEVEL=info`。`DATA_DIR/secret.key` 首启自动生成（签令牌 + 加密 API key）。

### 4.1 API 契约（`/api/v1`，JSON，错误体 `{error: {code, message}}`）

**setup/auth**
- `GET /setup/status` → `{needsSetup, householdName?}`
- `POST /setup` `{householdName, username, password, displayName}` → `{token, member}`（仅无用户时）
- `POST /auth/login` `{username, password, deviceName?, platform?}` → `{token, member, deviceId}`
- `POST /auth/logout`；`GET /auth/me` → `{member, household:{name,currency}, deviceId}`；`POST /auth/password` `{oldPassword,newPassword}`

**members**（写需 admin）`GET /members`；`POST /members` `{username,password,displayName,color,avatarEmoji,role}`；`PATCH /members/:id`；`DELETE /members/:id`（归档）；`POST /members/:id/reset-password {password}`

**accounts / funds / categories / rules / budgets**：标准 `GET`（列表，含 `archived` 可选）/ `POST` / `PATCH /:id` / `DELETE /:id`（软删）。`GET /funds/templates` 静态模板。`PUT /funds/reorder {ids[]}`（accounts/categories 同）。`GET /budgets?month=` 返回该月生效预算（`month` 精确 > `'*'` 默认）；`PUT /budgets` `{scope, refId, month, amountCents|null}`。

**transactions**
- `GET /transactions?from&to&type&fundId&accountId&categoryId&memberId&status&source&q&cursor&limit(≤200)` → `{items[], nextCursor?}`（按 occurredAt desc, id desc；cursor = base64(occurredAt|id)）
- `POST /transactions` 单条（带 `clientId` 幂等：重复返回已存在的 200）
- `POST /transactions/batch` `{items[]}` → `{results:[{clientId,id,status:'created'|'exists'|'error',error?}]}`
- `GET /transactions/:id`；`PATCH /transactions/:id`；`DELETE /transactions/:id`
- `POST /transactions/:id/confirm` → status confirmed；`POST /transactions/:id/void`
- 服务端查重：同 `type`、同 `amountCents`、`occurredAt` 相差 ≤ 3 分钟、`source` ∈ {notification, share} 的新纪录 → `status=duplicate, duplicateOfId=旧` 并在响应里标 `duplicate:true`（客户端只提示不再弹通知）。

**stats**
- `GET /stats/overview?month=YYYY-MM` → `{netWorthCents, assetsCents, liabilitiesCents, month:{expenseCents, incomeCents, byFund:[{fundId,expenseCents,incomeCents}], byCategory:[{categoryId,expenseCents}], byMember:[{memberId,expenseCents}], budgets:[{scope,refId,budgetCents,spentCents}]}, pendingCount, funds:[{fundId,balanceCents}], accounts:[{accountId,balanceCents}]}`
- `GET /stats/trend?months=12&endMonth?&fundId?&categoryId?` → `{series:[{month,expenseCents,incomeCents}]}`（`endMonth` 为 `YYYY-MM`，含；缺省当月）
- `GET /stats/fund/:id?month=` → `{balanceCents, targetCents, monthExpenseCents, monthIncomeCents, budgetCents, byCategory[], recent[]}`
- `GET /stats/calendar?month=` → `{days:[{date,expenseCents,incomeCents,count}]}`

**changes**（同步）`GET /changes?since=<seq>&limit=500` → `{since, next, more, members[], accounts[], funds[], categories[], transactions[], budgets[], rules[]}`（含软删行）。

**model**：`GET /model` → `{version, category:{classes, docCount, tokenCounts...}, fund:{...}}`；`POST /model/learn` `{samples:[{text, merchant?, categoryId?, fundId?, memberId?, hour?}]}` → `{version}`；`DELETE /model`（重置为种子）。

**ai**
- `GET /ai/providers`（apiKey 只回 `hasKey:true` 与尾 4 位）；`POST /ai/providers`；`PATCH /:id`；`DELETE /:id`；`POST /:id/test` → `{ok, model, latencyMs, sample}`；`GET /ai/presets` → 预设列表（cc-trans、硅基流动、DeepSeek、月之暗面、智谱、OpenAI、Anthropic 官方、Ollama）
- `POST /ai/chat` `{messages:[{role,content}], providerId?, context:{month?, fundIds?}}` → SSE：`event: delta {text}` … `event: done {usage}` / `event: error {message}`
- `POST /ai/report?month=&providerId?` → SSE（同上），完成后落 `ai_reports`；`GET /ai/reports?month=` → 列表
- `POST /ai/classify` `{text, merchant?, amountCents?, candidates:{categories:[{id,name}], funds:[{id,name}]}}` → `{categoryId?, fundId?, confidence, reason}`（要求模型输出 JSON，解析失败 → 400）
- 提示词：系统提示词固化「家庭理财顾问」人设 + 注入 `stats/overview` + 近 6 个月趋势 + 预算达成率 + 基金目标进度，全部中文。

**backup**
- `GET /backup/config` → `{webdav:{url,username,hasPassword,remoteDir}, schedule:{enabled,hour,keep}, encryption:{enabled,hasPassphrase}, lastRun?, nextRun?}`
- `PUT /backup/config`（password/passphrase 只写不读；空字符串 = 不改）
- `POST /backup/test` → `{ok, message}`；`POST /backup/run` → `{name, bytes, tookMs}`；`GET /backup/list` → `{items:[{name,bytes,modifiedAt,encrypted}]}`；`POST /backup/restore {name}` → 先本地留 `pre-restore-*.db` 再替换，返回 `{ok, restoredFrom}`；服务进程用「关闭 db → 替换文件 → 重开」而非重启。
- `GET /backup/export` → `application/gzip` 快照；`POST /backup/import`（multipart 或 raw gzip，admin）
- 文件名：`famledger-YYYYMMDD-HHMMSS.db.gz[.enc]` + 同名 `.json` manifest。加密：`FLBK1 | salt16 | nonce12 | ciphertext | tag16`，scrypt(N=2^15) 派生。

**settings** `GET /settings` / `PATCH /settings`：`{name, currency, capture:{defaultFundId?, defaultAccountId?, autoConfirmThreshold(0.75), llmFallback(false), allowedApps[] 服务端不管，留设备}, ui:{firstDayOfMonth(1)}}`

## 5. 客户端 `app/`（Flutter 3.32，Material 3，中文）

- 依赖（都在用户既有项目里出现过或极常见）：`flutter_riverpod`、`go_router`、`http`（不用 dio，够用）、`shared_preferences`、`flutter_secure_storage`、`path_provider`、`fl_chart`、`intl`、`uuid`、`share_plus`、`url_launcher`、`flutter_local_notifications`（仅 iOS 自家通知）、`app_links`（URL scheme）。**不用 drift/codegen**：本地只存 JSON 缓存与 outbox。
- 目录：`lib/{main.dart, app/(router,theme,providers), core/(money,dates,ids), data/(api,local,repos,models), capture/(normalizer,parser,source_profiles,naive_bayes,classifier,seed_dataset,pipeline,headless_main,quick_reply), platform/(android_capture,ios_share), ui/(shell,auth,home,transactions,add_tx,funds,analysis,ai,settings,widgets)}`。
- **自适应外壳**：宽 < 840 dp 底部导航（首页 / 账单 / 基金 / 分析 / 我的，+ 记一笔 FAB）；≥ 840 dp 导航栏轨 + 双栏看板（Web 看板形态）。
- 页面：
  - 连接向导：服务器地址（校验 `/healthz` 与 `/setup/status`）→ 初始化家庭（首次）或登录。
  - 首页：本月支出/收入/结余、**基金卡片横滑**（余额、目标进度/月预算进度）、待确认自动记账（卡片内直接「确认 / 改」）、最近流水、预算超支提醒。
  - 账单：按日分组、筛选（基金/成员/类别/来源/状态）、搜索、点开编辑、滑动删除（Snackbar 撤销）。
  - 记一笔：金额键盘 → 类型（支出/收入/转账·拨款）→ 类别网格 → 基金 → 账户 → 成员 → 日期 → 商户/备注；记住上次选择。
  - 基金：列表/网格 + 新建（模板）+ 详情（余额趋势、本月类别构成、流水、拨款、目标/预算编辑）。
  - 分析：月趋势柱状、类别环形、成员对比、基金占比；「AI 月报」按钮（流式）与「问 AI」对话。
  - 我的/设置：成员、账户、类别、预算、自动记账（Android：权限状态、允许的应用、置信阈值、AI 兜底、测试解析；iOS：分享导入说明、快捷指令）、AI 渠道（预设 + 测试）、WebDAV 备份、服务器与账号、关于。
- 主题：见 DESIGN.md。金额用 tabular figures；支出用墨色 `−¥`，收入用青绿 `+¥`；超预算用 error 色；基金各自有色（12 色可选盘）。深浅色都是一等公民，默认跟随系统。
- 同步：启动/前台/下拉 → `GET /changes?since` 增量合并到本地缓存；outbox 每次联网 flush（`batch`）；冲突不存在（服务端权威，PATCH 覆盖）。

## 6. 自动记账管线（`lib/capture/`，纯 Dart，单份）

```
通知(pkg,title,text,bigText,when)
 → normalize（全角→半角、¥/￥/元 统一、去 emoji）
 → dedupe（sha1(pkg|text|分钟) 10 分钟窗口）
 → SourceProfile.match(pkg)  ─┬─ 支付宝 / 微信支付 / 云闪付 / 银行短信(短信 App) / 通用兜底
                              └─ 抽取：amountCents、direction(expense|income|transfer|unknown)、merchant、channel、cardTail、occurredAt
 → rules（用户规则，优先级高者先命中）
 → NaiveBayes(category)  +  NaiveBayes(fund)   [特征：字符 1/2-gram、商户词、方向、渠道、金额桶、小时段、星期、成员]
 → confidence = min(parseConfidence, p_top)；≥ 阈值 → status=confirmed，否则 pending
 → 选账户：cardTail / pkg 匹配 accounts.matchHints，否则设置里的默认账户
 → 建流水（source=notification，rawText，captureId）→ outbox → POST（服务端还会查重）
 → 结果通知：「支付宝 −¥35.00 · 餐饮 → 家庭公共基金 (92%)」 动作：[正确] [修改…] [撤销] 点击→打开编辑页
 → 「修改…」RemoteInput 文本 → QuickReplyInterpreter：命中基金名/别名 → 改基金；命中类别名 → 改类别；纯数字 → 改金额；「收入/支出」→ 改方向；其余 → 备注。纠正样本 → NB.learn → POST /model/learn
```
- 种子数据：内置 ~300 条「商户关键词 → 类别」中文样本，首启训练；服务端 `model` 为空时也用同一份种子。
- 阈值默认 0.75；置信度低于阈值且开启「AI 兜底」→ 调 `/ai/classify` 再决定。
- 安卓允许监听的包默认：`com.eg.android.AlipayGphone`、`com.tencent.mm`、`com.unionpay`、系统短信 App（小米 `com.miui.mms`、`com.android.mms`、`com.google.android.apps.messaging`、三星 `com.samsung.android.messaging`）、主流银行 App 包名若干；用户可增删。Debug 构建额外允许 `com.android.shell`，供 `adb shell cmd notification post` 做端到端测试。
- 原生（Kotlin）：`CaptureListenerService`（过滤 → 交给 `HeadlessEngine`）、`HeadlessEngine`（懒启动 `FlutterEngine(entrypoint=captureMain)`，就绪前排队）、`ResultNotifier`（渠道「自动记账」，RemoteInput 动作）、`ActionReceiver`（正确/撤销/快捷回复 → 回调 Dart）、`CapturePlugin`（MethodChannel：`isEnabled/openSettings/allowedApps/…`）。MIUI 需引导「自启动 + 省电无限制」，设置页给出一键跳转。
- iOS：`ShareExtension`（接收文本/图片文字 → App Group → `famledger://capture`），`AppIntents` 快捷指令「记一笔」，App 内「从剪贴板导入」。自家结果通知带 `UNTextInputNotificationAction`。**本机无 Xcode，iOS 原生部分只写代码与文档，不做编译验证。**

## 7. 部署 `deploy/`

- `Dockerfile`：`node:24-bookworm-slim`，COPY `server/` 与预构建 `app/build/web` → `/web`；非 root（node 用户）；`HEALTHCHECK curl /healthz`；`VOLUME /data`；`EXPOSE 48090`。
- `Dockerfile.full`：多阶段，第一阶段用 `ghcr.io/cirruslabs/flutter:3.32.1` 构建 web，供没有 Flutter 的机器 `docker compose -f docker-compose.build.yml up -d --build`。
- `docker-compose.yml`（GHCR 镜像）与 `docker-compose.build.yml`（本地构建）；数据卷 `${FL_DATA_PATH:-fldata}:/data`；`TRUST_PROXY=1`。
- `deploy/cloudflared-ingress.example.yml`：一条 ingress `ledger.<域名> → http://localhost:48090`（用户的 nas-adan 隧道靠本地 config.yml + 通配符 DNS，加服务只改 ingress）。
- `.github/workflows/test.yml`（push：server `node --test`、`flutter analyze`、`flutter test`）；`build.yml`（手动：web → GHCR 双架构镜像；APK 产物）。

## 8. 安全

- 口令 scrypt；令牌可吊销；登录限流；admin/member 角色。
- API key、WebDAV 口令、备份密语：AES-256-GCM 加密落库，密钥 `DATA_DIR/secret.key`（0600）。
- 手机端：令牌与服务器地址存 `flutter_secure_storage`。
- 服务端不打印任何密钥；日志里 `rawText` 只记长度。
- 备份文件可选加密；恢复前必留本地 `pre-restore` 副本。

## 9. 测试

- server：`node --test`：鉴权/幂等/查重/统计口径/changes 游标/模型合并/AI SSE（用内嵌假上游 Anthropic 与 OpenAI 服务器）/备份（内嵌假 WebDAV 服务器：PROPFIND/MKCOL/PUT/GET/DELETE）/恢复。
- app：`flutter test`：解析器（≥ 40 条真实风格通知样本）、NB 学习与置信度、快捷回复解释器、金额格式化、outbox 幂等、模型序列化。
- 集成：本机 `flutter build web` → 服务端 serve → curl；`flutter build apk --debug` → 真机安装 → `adb shell cmd notification allow_listener` → `cmd notification post` 假支付通知 → 查服务端流水。Docker 镜像本地 build + 起容器冒烟。

## 10. 明确不做（v1）

多币种换算、附件/发票图片、投资持仓行情、导入第三方账单文件（预留 `source=import`）、推送服务器→手机、公开注册、多家庭多租户。

## 11. 里程碑

M1 服务端核心 + 测试 → M2 Flutter 核心页面 + Web 构建 + Docker → M3 自动记账管线 + Android 原生 + 真机端到端 → M4 WebDAV 备份 → M5 AI 渠道/月报/对话/兜底 → M6 iOS 分享扩展（代码）+ CI + README。
