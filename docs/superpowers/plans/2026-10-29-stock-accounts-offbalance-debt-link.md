# 实施计划：股票账户、流水不计余额、债务关联流水、会话过期（2026-10-29）

设计见 `docs/superpowers/specs/2026-10-29-stock-accounts-offbalance-debt-link-design.md`。每个任务由一个前台子代理完成；并发最多 3 个；改一处存一处。**不 commit、不 push**（用户未授权）。

## 第一批（服务端 + 会话过期，三条并行）

### T1 服务端：股票账户
- 迁移 `013_stock_accounts_off_balance.sql`（两张表的列都在这一份里；T2 不再建迁移文件）。
- `accounts.js`：`stock` kind、`valueCents / valueOn / valueLog`、kind 改走清市值、`POST /accounts/:id/absorb`（幂等 scope `account.absorb`）。
- `stats.js`：股票账户进理财分项与 `investByKind`；口径注释。
- `changes.js`：accounts 的 `value_log`。
- 测试 `test/stock_accounts.test.js`；跑 `npm test` 全绿。

### T2 服务端：不计入余额 + 债务关联流水
- `transactions.js`：`offBalance` 收 / 出（`txJson` bools）、`BULK_FIELDS`、列表筛选 `offBalance`；`ctx.updateTransaction`。
- `stats_sql.deltaMap`：account 侧排除 `off_balance = 1`。
- stats.js / debts.js / holdings.js 的 `txJson`、changes.js 的 transactions 配置加 bools。
- `debts.js`：`recordTransaction.transactionId`（create / settle），校验与转换。
- 测试 `test/off_balance.test.js`、`test/debt_link.test.js`；`npm test` 全绿。
- 注意：迁移文件由 T1 建；T2 若先跑到，先自己把 `013` 建出来（内容按设计），T1 看到已有就不重建。

### T3 客户端：会话过期
- `ApiClient.onUnauthorized`；`apiProvider` / `import_repo` / `capture_runtime` 接上。
- `SessionController.expire`、`SessionRepo.dropSession` / `restore()` 看 `exp`、`sessionNoticeProvider`、登录页提示。
- 测试：`api_client_test`、`session_repo_test`、`router_test`（或 `login_page_test`）。`flutter analyze`、相关测试绿。

## 第二批（客户端功能，三条并行；依赖第一批的接口）

### T4 客户端：股票账户
- `Account` 模型、账户表单、账户页 / 选择器图标、理财 tab（股票账户段、去组头、提示卡 + 合并 sheet、空态与入口）、股票账户详情页与路由、首页理财格、`HoldingsRepo.absorbHoldings`、`asset_math.summarizeStockAccounts`。
- 测试：模型、`assets_invest_test` 扩展、新页面测试、`settings_manage_test` 账户表单。

### T5 客户端：不计入余额 + 导入
- `Transaction` / `TransactionDraft.offBalance`、导入核对页开关（默认 + 记忆）、结果页提示、导入页文案、「我的」入口、流水详情「账户余额」段、列表 / 表格小标、批量操作。
- 测试：`import_preview_test`、`tx_tile_test`、`tx_table_test`、流水详情测试、模型测试。

### T6 客户端：债务关联流水
- `DebtsRepo` 的 `transactionId`；`pick_tx_sheet`；债务表单与收回 sheet 的「已记过流水」；流水详情「债务」段；`/assets/debts/new?txId=`；`debt_move_sheet` 币种前缀。
- 测试：`assets_debts_test` 扩展、流水详情测试。

## 第三批（收尾）

### T7 文档
- CHANGELOG、DESIGN、README 按设计更新（中文）。

### T8 审查与全量验证
- code-review 子代理看整个 diff；确认的缺陷修掉。
- `cd server && npm test`；`cd app && flutter analyze && TZ=UTC flutter test`。
- 起隔离实例（`PORT=48190 DATA_DIR=<scratchpad>/audit/data`）做一次冒烟：建股票账户、导入一份账单（不计余额）、建债务关联流水、令牌失效回登录。
