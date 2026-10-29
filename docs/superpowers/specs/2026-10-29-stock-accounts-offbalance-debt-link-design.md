# 设计：股票账户汇总、流水不计余额、债务关联流水、会话过期回登录（2026-10-29）

状态：实施中。用户离线，本文里标「**我定的**」的口径是实施者的决定，用户事后可改。

## 背景与目的

用户提出五条：

1. 理财里的股票不要一只一只记（买卖都要新增一条，记录多了难看），**按股票账户汇总**，股票的持有都算在股票账户里。
2. 会影响资产的流水（比如借款）记了账之后，**不要再从资产里扣一次**；其它地方也查一遍有没有重复计算。
3. 兼容支付宝、微信的个人对账单导入；并且**能设置这些流水影响不影响资产总量**——出了问题一条条对太麻烦，直接管控银行余额更方便。
4. 令牌过期要**自动回到登录页**，现在只能手动。
5. 审查代码，顺手修缺陷、优化 UI。

成功的样子：股票只在「股票账户」上记一个总市值，转入转出就是普通转账；导入的账单默认不动余额、余额靠账户校准；一笔钱在流水里记过，建债务 / 收回时直接「选那笔」而不是再记一笔；令牌一失效 App 自己回到登录页并说明原因。

## 非目标

- 不接券商接口、不自动拉股票账户市值（用户自己照着券商 App 填）。
- 不改板块（funds）的口径：不计入账户余额的流水照样进板块余额和收支统计。
- 不做「信用卡还款记成支出」的自动纠错，只在文档里写清怎么记。

## 一、股票账户（按账户汇总）

### 模型

账户 `kind` 多一种 **`stock`（股票账户）**。它和 `invest` 一样不算现金流；区别是**不挂持仓**，整个账户记一个「当前市值」。

- 余额（`initial_balance_cents + Σ流水`）= **投入**：转进去多少本金、转出来多少。新建时的「初始余额」= 开始记之前已经投进去的本金。
- `value_cents`（可空）= **当前市值**，用户照券商 App 填；`value_on` = 哪天的数。空 = 还没填过市值，按投入算。
- `value_log` = 历次市值 `[{on, valueCents}]`，老的在前，同一天覆盖，最多留 200 条。
- 浮盈 = 市值 − 投入。
- 持仓（holdings）**不能挂在 `stock` 账户上**（holdings.js 只认 `invest`，不改）。

迁移 `013_stock_accounts_off_balance.sql`：

```sql
ALTER TABLE accounts ADD COLUMN value_cents INTEGER;
ALTER TABLE accounts ADD COLUMN value_on TEXT;
ALTER TABLE accounts ADD COLUMN value_log TEXT NOT NULL DEFAULT '[]';
ALTER TABLE transactions ADD COLUMN off_balance INTEGER NOT NULL DEFAULT 0;
```

### 接口（server/src/modules/accounts.js）

- `KINDS` 加 `'stock'`。
- `POST /accounts`、`PATCH /accounts/:id` 收：
  - `valueCents`：整数 ≥ 0，或 `null`（清掉市值，回到按投入算；`value_on` 一起清，`value_log` 保留）。**只有结果 kind 是 `stock` 的账户收**；别的类型传了 → 400 `invalid_valueCents`「只有股票账户记市值」。
  - `valueOn`：`YYYY-MM-DD`，不能晚于今天，默认今天；只在给了 `valueCents` 时有意义，单独给 → 400 `invalid_valueOn`（和 holdings 的 valueOn 规则一致）。
  - kind 从 `stock` 改成别的 → `value_cents`、`value_on` 置空（log 保留）。
  - 写入市值时 `value_log` 追加 / 覆盖同一天那条。
- JSON 输出多 `valueCents`、`valueOn`、`valueLog`（数组）。`accounts.js` 现在是纯 `makeCrud`，它的 `toJson` 只解析 `fields` 里声明为 json 的列，`value_log` 不在 `fields` 里 → 要给 `makeCrud` 传自定义 `toJson: (row) => rowToJson(row, { bools: ['archived'], json: ['match_hints', 'value_log'] })`；`GET /changes` 的 accounts 配置同样加 `json: ['match_hints', 'value_log']`。
- 债务的内部账户（kind=debt）照旧不收这些字段。

### 统计（server/src/modules/stats.js computeOverview）

账户循环里 `kind === 'stock'` 和 `invest` 一样：`investAccountsCents += bal`（不进 cashCents）。另外，查询要带 `value_cents`：

- 有市值：`net = value − balance`（原生币），`investNetCents += net`、`assetsCents += net`、`investMarketCents += value`、`investCostCents += balance`；按币种的桶同理（`investNetCents / investMarketCents / investCostCents / assetsCents`）。
- 没市值：只有 `investAccountsCents`（等于按投入算，不多算也不少算）。
- `investByKind` 里累一条 `kind: 'stock'`：`valueCents += value ?? balance`，`costCents += balance`，`count++`（和老的逐只股票持仓合在同一个 kind 下；不要求分开）。
- 文件头的口径注释补第 4 条：「股票账户按整户市值记，浮盈 = 市值 − 账户余额」。

### 合并老持仓：`POST /accounts/:id/absorb`

把逐只记的持仓并进一个股票账户，一次事务：

- 请求 `{ holdingIds: string[]（1..200）, valueCents?: int ≥ 0, valueOn?: day, clientId?: string }`。
- 账户必须存在、未删、`kind === 'stock'`（否则 400 `invalid_accountId`「只能并进股票账户」）。
- 每只持仓：存在、未删、未归档（否则 400 `invalid_holdingIds` 说明是哪只）；币种和账户相同（否则 400 `currency_mismatch`，复用 `requireSameCurrency` 的措辞）。
- 钱怎么走：
  - 挂着**活的**投资账户且 `cost_cents > 0` → 经 `ctx.createTransaction` 记一笔转账 投资账户 → 股票账户，金额 `cost_cents`，`occurredAt` 今天中午（`noonOf(today())` 的写法照 holdings.js），merchant「移仓 <持仓名>」。
  - 没挂账户（或挂的账户已删）且 `cost_cents > 0` → 股票账户 `initial_balance_cents += cost_cents`（这笔成本以前没进任何账户的余额；现在作为投入记在股票账户上）。
  - 之后把持仓 `archived = 1`（份额、成本、已实现盈亏原样留着，quantity 不动），`seq` 更新。
- 给了 `valueCents` 就按上面 PATCH 的规则写市值（`valueOn` 默认今天）。
- 响应 200 `{ account, holdings: [...归档后的行], transactions: [...记下的转账] }`；`clientId` 幂等（scope `account.absorb`，回放带 `replayed: true`）。
- 活动日志：`logActivity(action: 'absorb', entity: 'account')`。

### 客户端

- `Account`：`kinds` 加 `'stock'`（标签「股票账户」，放在「投资」后面）；新字段 `valueCents`、`valueOn`、`valueLog`（`List<AccountValue>{on, valueCents}`）；getter `isStock`、`isInvestLike`（invest 或 stock）。`toJson` 带上它们（本地缓存要存）。
- 账户表单（`ui/settings/account_form.dart`）：
  - 类型芯片多「股票账户」，选中时在类型下面一句说明「只记整户市值，不逐只记股票；转进转出的钱记成转账」。
  - 选 `stock` 时多一栏「当前市值」（新建、编辑都有）+ 日期按钮（默认今天，`pickPastDay`）；留空 = 不填市值。编辑时预填现有市值和日期。
  - 「初始余额」的 helper 在 `stock` 时写「开始记之前已经投进去的本金」。
  - 提交：`valueCents` 只在 stock 且用户填了（或清空了原有的 → 发 null）时带上；`valueOn` 跟着。
- 账户页（`accounts_page.dart`）：`_kindIcons['stock'] = 'show_chart'`；股票账户的 trailing 显示市值（`valueCents ?? balance`），副标题多「投入 X」；`account_picker.dart` 的图标表同样加。
- 理财 tab（`ui/assets/invest_tab.dart`）：
  - 顶上小结「理财估值」= 持仓估值 + Σ股票账户市值（`valueCents ?? balance`，按币种）；「浮动收益」加 Σ（市值 − 投入）；收益率只在单币种时算。新增纯函数 `summarizeStockAccounts(accounts, balanceOf)`（放 `asset_math.dart`）给这里和首页用。
  - 列表第一段「股票账户」（有 `stock` 账户时才出）：每行左图标 `show_chart`，标题账户名，副标题「投入 ¥X · 10月20日 更新」（没填市值写「按投入算 · 填一下市值」），右侧市值 + 浮盈（带率）；市值超过 31 天没更新挂「该更新了」黄标（复用 `valueStaleAfter`、`warningTags`）。点开 → 股票账户详情页；宽屏嵌右栏（`selectedStockAccountProvider`，和持仓共用一个右栏：选中项用 `('account', id)` / `('holding', id)` 区分，或者单独一个 provider 二选一——实施者定）。
  - 持仓部分**去掉品类组头**（用户说理财里不需要分组）：持仓平铺，每行副标题第一段写品类名（「基金 · 持有 N 天 · 日均 …」）；「已结清」仍收在最后。`_KindHeader` 删掉。
  - 还有逐只记的 `kind == stock` 持仓时，列表顶上一条提示（surface2 背景、一句话 + 按钮）：「股票可以按账户汇总记了」「合并到股票账户」→ 合并 sheet：选一个股票账户（没有就「新建股票账户」弹账户表单）、列出要并的持仓（默认勾全部股票持仓，可勾别的品类）、市值预填 Σ市值（有价格的那些；可改）、日期今天 → `POST /accounts/:id/absorb`；成功后 `refreshMoneyViews` + ledger sync。
  - 空态：没持仓也没股票账户才显示；文案加「股票账户」；「添加理财」按钮旁（或空态里）多一个「新建股票账户」入口（弹账户表单，kind 预设 stock）。宽屏顶栏的「添加持仓」按钮改成菜单：「记一笔理财」「新建股票账户」。
- 股票账户详情页（新文件 `ui/assets/stock_account_page.dart`，路由 `/assets/accounts/:id`，挂在 `asset_routes.dart` 的理财段下、`parentNavigatorKey: rootKey`）：
  - 顶部：「市值」大数字（`MoneySize.display`，没市值时显示投入并标「按投入算」）；下面两格「投入」「浮盈」（带率）；日期「10月20日 更新」。
  - 动作：「更新市值」（实心，sheet：金额 + 日期）、「转入」「转出」（sheet：金额、日期、对方账户（同币种、非债务账户）、备注 → `transactionsRepo.create` 一笔转账，merchant「转入 <账户名>」/「转出 <账户名>」）、「编辑账户」（账户表单）、「看流水」（账单页按账户筛选，做法同账户表单）。
  - 「市值记录」：`valueLog` 新的在前，每行日期 + 市值 + 和上一次的差；「最近流水」：该账户的流水列表（做法同 `debt_detail_page.dart` 的 `debtTransactionsProvider`）。
- 首页「资产」里的「理财」格（`ui/home/assets_card.dart`）：估值和浮动加上股票账户。
- `HoldingsRepo` 加 `absorbHoldings(accountId, {holdingIds, valueCents, valueOn, clientId})`，返回后把账户、持仓落本地（`LedgerRepo` 新增公开的 `putAccount`，和现有的 `putHolding` 一样走 `_put`）。

## 二、债务：流水记过就不再扣一次

### 问题

借出 / 借入 / 收回 / 还款的钱常常已经被自动记账或导入记成一笔支出 / 收入了。现在建债务或点「收回」时勾「同时记一笔」会再记一笔转账，账户就被扣两次；不勾的话那笔支出留在月支出里，也不对。

### 服务端（modules/debts.js、modules/transactions.js）

`POST /debts` 的 `recordTransaction` 多一种写法 **`{ transactionId }`**（和 `{ accountId }` 二选一，都给 → 400 `invalid_recordTransaction`）。`POST /debts/:id/settle` 现在只收**顶层** `accountId`（没有 `recordTransaction` 对象），所以它加一个**顶层 `transactionId`**，和 `accountId` 二选一（都给 → 400 `invalid_transactionId`）；老的 `accountId` 写法原样保留。

转换时流水的 `off_balance` **不动**：导入进来的账单默认不计入真账户余额，转成债务往来后依旧不动真账户，但债务内部账户那一侧照常算（口径见第三节）——这正是用户要的：真账户余额靠校准，债务还剩多少靠往来。

把已有的那笔流水**转成这笔债务的往来**，不新记：

- 借款类（kind ≠ favor）：
  - `effect > 0`（借出起始 / 再借出、我欠别人还款）：流水必须是 **支出**（`type = 'expense'`）且有 `account_id` → 改成 `transfer`，`account_id` 不变、`to_account_id` = 内部账户。
  - `effect < 0`（借出收回、借入起始 / 再借入）：流水必须是 **收入** 且有 `account_id` → 改成 `transfer`，`account_id` = 内部账户、`to_account_id` = 原账户。
  - 改的时候：`category_id = null`、`fund_id = null`、`to_fund_id = null`（借出不是花钱，板块余额回去）；金额、日期、商户、备注、状态、`off_balance` 都不动。
- 人情（favor）：流水必须是同方向的支出 / 收入（`effect > 0` → 支出，`effect < 0` → 收入），**不改**它，只当「钱那一边已经记过」：期初照改、备忘 `recorded: true`。
- 校验（都是 400）：
  - `invalid_transactionId`：流水不存在 / 已删 / 状态是 duplicate、void / 已经是转账 / 没有账户。
  - `amount_mismatch`：流水金额 ≠ `amountCents`：「那笔流水是 ¥X，和这里填的 ¥Y 不一样；改一边再试」。
  - `currency_mismatch`：流水币种 ≠ 债务币种（复用 `requireSameCurrency` 的口吻）。
  - 流水的账户是另一笔债务的内部账户 → `invalid_transactionId`。
- `transactions.js` 导出 `ctx.updateTransaction(id, body, reqCtx)`：用同一套 `normalize` + `writeCols` + `logActivity`，不走 HTTP（和 `ctx.createTransaction` 一个风格）。注意 normalize 对 transfer 要求板块成对：这里显式传 `fundId: null, toFundId: null, categoryId: null`。
- 新建时 `settledCents` 和 `transactionId` 并用：起始那笔走转换，已收回的部分按「不记流水」处理（改期初 + 备忘「之前已收回 / 之前已还」）。
- 响应的 `transactions` 带转换后的那笔。幂等照旧（clientId）。

### 客户端

- `DebtsRepo.create` / `move` 多 `transactionId` 参数（和 `accountId` 二选一）：`create` 发 `recordTransaction: {transactionId}`，`move` 发顶层 `transactionId`。
- 债务表单（`debt_form_page.dart`）与收回 / 再借 sheet（`debt_move_sheet.dart`）：「同时记一笔」打开时，账户选择器上面多一行 `SwitchListTile`「这笔钱已经记过流水了」（副标题「自动记账 / 导入的那笔，选它就不会再扣一次」）。打开后账户选择器换成「选流水」按钮 → `showPickTransactionSheet`（新文件 `ui/transactions/pick_tx_sheet.dart`）：拉最近 100 笔（`TxFilter(type: 支出或收入按规则定, limit: 100)`），金额等于表单金额的排最前并标「金额一样」，顶部一个搜索框按商户 / 备注过滤；选中后表单显示摘要行（TxTile 简版，可点换一笔）。提交带 `transactionId`，金额栏预填那笔的金额并锁定（改金额就得换流水）。
- 流水详情（`tx_detail_page.dart`）：支出 / 收入、有账户、已确认 → 多一段「债务」（放在「来源」上面）：
  - 「关联到已有债务」：sheet 列出未结清、同币种的债务，每行写出会发生什么（支出：借出的债务 →「再借给 张三」（add）；借入的债务 →「还 李四」（settle）。收入：借入的债务 →「又借了 李四的」（add）；借出的债务 →「张三还回来」（settle））→ `POST /debts/:id/settle`，`recordTransaction: {transactionId}`、`amountCents = 这笔金额`、`occurredOn = 这笔日期`。成功后 `refreshMoneyViews`、`invalidate txDetailProvider`，SnackBar「已记成 …，这笔流水变成了转账」。
  - 「记成一笔新债务」：`context.push('/assets/debts/new?txId=<id>')`；债务表单读 `txId`：取那笔流水，预填金额（锁定）、日期、方向（支出 → 借出；收入 → 借入）、币种，并直接进入「已记过流水」模式（摘要行显示那笔）。
  - 已经是转账的流水不出这一段。
- 修一个顺手看到的 bug：`debt_move_sheet.dart` 的金额框前缀写死 `¥`，改成 `Money.symbolFor(debt.currency)`。

### 其它重复计算的核对（文档）

在 `DESIGN.md`「算出来的数也能改」旁边加一节「一笔钱只记一次」，写清：

- 买基金 / 存定期 / 转进股票账户 = 转账，不是支出；只有卖出盈亏是收入 / 支出。
- 借出 / 借入 / 收回 / 还款 = 真账户和债务内部账户之间的转账；钱已经在流水里时**选那笔**，别再记。
- 还信用卡 = 转账（借记卡 → 信用卡），记成支出会重复。
- 板块的「每月固定进账」开了就别再手记工资。
- 导入的账单「不计入账户余额」时，余额以账户里校准的为准。

## 三、流水「不计入账户余额」+ 导入

### 口径（**我定的**）

`transactions.off_balance = 1` 的流水：

- **不进真账户的余额**（`stats_sql.deltaMap` 的 `account` 侧两段子查询各 `JOIN accounts a ON a.id = <account_id / to_account_id>`，条件 `AND (t.off_balance = 0 OR a.kind = 'debt')`）——于是不进总览里的真账户余额、现金流、资产 / 负债、净资产；账户「现在余额」校准也自然不算它。
- **债务内部账户（kind = debt）那一侧照常算**：一笔不计余额的流水转成债务往来（第二节）后，真账户仍不动（它的余额是校准出来的，已经反映了这笔钱进出），内部账户记上「还剩多少」。这样净资产 = 校准后的真账户 + 应收 − 应付，不多不少；`debts.js` 的 `balanceOf`、`over_settle` 校验走同一个 `deltaMap`，不用另写。
- `test/off_balance.test.js` 要钉这一条：不计余额的支出关联成借出 → 真账户余额不变、内部账户 +A、月支出 −A、净资产 +A（应收冒出来了）。
- **照常进**：月支出 / 收入、按类别 / 成员 / 板块的聚合、板块余额（`fundBalancesByCurrency` 不动）、预算、趋势、日历、AI 上下文。
- `fund` 侧的 deltaMap 不受影响（现在没人用 fund 侧，加个参数或按 side 判断都行）。

### 接口

- `POST /transactions`、`/batch` 的每项、`PATCH /transactions/:id`：收 `offBalance`（布尔；缺省新建 false、PATCH 沿用）。
- `POST /transactions/bulk`：`BULK_FIELDS` 加 `offBalance`。
- JSON 输出 `offBalance`（布尔）：transactions.js、stats.js、debts.js、holdings.js 的 `txJson` 和 changes.js 的 transactions 配置都加 `bools: ['off_balance']`。
- `GET /transactions` 筛选加 `offBalance=1|0`（可选，列表页「不计余额」筛选用；实施简单就做）。

### 导入（客户端）

- 核对页（`import_preview_page.dart`）底栏「训练」那一行上面加一行开关「**计入账户余额**」：
  - 默认：支付宝 / 微信账单 **关**（不计入），通用模板 **开**；本机记住上次选择（`localStoreProvider`，键 `import.countInBalance`），下次按上次的。
  - 关着时副标题「这批流水只进收支统计，不改账户余额；余额在账户里直接校准」；开着时「会加减对应账户的余额」。
  - `ImportItem.toBatchJson` 带 `offBalance: !countInBalance`；结果页一句「这批不计入账户余额」提醒。
- 导入页（`import_page.dart`）说明文字加一句：导入的账单可以选「不计入账户余额」。
- 「我的 › 智能与数据」加入口「导入账单」→ `/import`（账单页右上角的入口保留）。

### 流水的显示与修改

- `Transaction` / `TransactionDraft` 加 `offBalance`（默认 false，`toJson` 只在 true 时写）。
- 流水详情：有账户的流水多一段「账户余额」（`_section`，key `balance`）：摘要「计入」/「不计入」，展开是一个 `SwitchListTile`「计入账户余额」+ 一句说明；保存时随 PATCH 带 `offBalance`。
- 列表行（`tx_tile.dart`）金额下面挂小标「不计余额」（`TxStatusBadge` 加一个 `offBalance` 样式，中性色）；网页表格（`tx_table.dart`）同样标。
- 多选：账单页批量操作加「计入余额 / 不计入余额」两项（`tx_bulk_dialogs.dart` 简单确认弹窗 → `bulk(ids, patch: {offBalance})`）。

## 四、令牌过期自动回登录

- `ApiClient` 加 `void Function()? onUnauthorized`：`_send` 和 `sse` 里服务端回 **401、这次请求带了 token、且错误码不是 `invalid_credentials`** 时调一次（登录失败、改密码时旧密码错也是 401，不算过期）。
下面的 `expire`、`dropSession`、`lastNotice`、`sessionNoticeProvider` 都是**新增**的，现在不存在：

- `providers.dart` 的 `apiProvider`：`client.onUnauthorized = () => ref.read(sessionProvider.notifier).expire('登录已过期，请重新登录')`。`import_repo.dart` 的上传客户端接同一个回调。
- `capture_runtime.dart` 里建的客户端：它跑在独立的后台引擎（`capture/headless_main.dart`）里，拿不到主应用的 Riverpod 容器，所以 401 时只调它自己那个 `SessionRepo` 的 `dropSession()`（删安全存储里的会话、停止再用这个令牌）；主应用下一次请求撞上 401、或下次启动 `restore()` 时自然回登录页。不做跨引擎通知。
- 新增 `SessionController.expire(String reason)`：`state == null` 直接返回（并发的几个 401 只处理一次）；否则 `_repo.dropSession()`（新增：只删安全存储里的会话，**不**清本地缓存——outbox 里排着的账要等重新登录后再发，`TransactionsRepo.definitiveStatuses` 本来就不含 401），`state = null`，`sessionNoticeProvider.state = reason`。路由现有的 `_SessionRefresh` 会把人送到 `/login`（记住了服务器地址）。
- `SessionRepo.restore()`：解析令牌第一段（base64url JSON）的 `exp`，已过期就不恢复会话（删掉并返回 null，新增 `lastNotice = '登录已过期，请重新登录'`，`SessionController.build()` 把它搬进 `sessionNoticeProvider`），启动时直接停在登录页，不用等第一个请求 401。
- 新增 `sessionNoticeProvider = StateProvider<String?>`；登录页（`login_page.dart`）顶部显示它那句（`FormError` 样式或一行中性提示），登录成功后清空。
- 不改服务端。

## 五、审查与 UI

- 实施完成后跑一轮代码审查（code-review 子代理，看整个 diff），确认的缺陷当场修。
- 顺手修的：`debt_move_sheet` 的 ¥ 前缀；理财列表去组头；股票账户、导入开关、债务关联这三处新 UI 都走 DESIGN.md 的既有组件（`PickerField`、`SegmentSummary`、`TagLabel`、`FormSubmit`、`ReadableListView`、`FormColumns`）。

## 测试

- 服务端（`server/test/`）：
  - `stock_accounts.test.js`：建 stock 账户 + 市值 → 总览 `investAccountsCents / investNetCents / investMarketCents / netWorthCents / byCurrency / investByKind` 手算；`valueCents` 在非 stock 账户 400；改 kind 清市值；`value_log` 同一天覆盖、最多 200；`/changes` 带 `valueLog`；absorb：挂账户的记转账、没挂的改期初、归档、币种不同 400、幂等回放。
  - `off_balance.test.js`：`offBalance` 的流水不进账户余额但进月支出 / 板块余额 / 预算；PATCH 翻转后余额跟着变；bulk 改；batch 带；`/changes` 输出布尔；账户校准不算它。
  - `debt_link.test.js`：借出起始关联一笔支出 → 那笔变成转账、月支出减少、账户只扣一次、净资产不变；收回关联一笔收入；借入 / 还款两个方向；人情关联不改流水、备忘 `recorded`；金额不等 400 `amount_mismatch`；已是转账 / 已删 400；币种不同 400；`transactionId` 和 `accountId` 都给 400。
  - 现有套件全绿（`npm test`）。
- 客户端（`app/test/`）：
  - 模型：`Account` 新字段来回；`summarizeStockAccounts`；`Transaction.offBalance`。
  - widget：账户表单股票类型 + 市值栏；理财 tab 股票账户段、无组头、提示卡 + 合并 sheet；股票账户详情页三个动作；导入核对页开关（默认值、记忆、提交体）；流水详情「账户余额」段与「债务」段；债务表单 / 收回 sheet 的「选流水」；`ApiClient.onUnauthorized`；路由：401 后回登录页并显示提示；`restore()` 过期令牌不恢复。
  - `flutter analyze` 无告警，`TZ=UTC flutter test` 全绿。

## 文档

- `CHANGELOG.md` `[1.3.1]` 下加四块：股票账户、不计入账户余额与导入开关、债务关联流水、登录过期自动回登录；接口变更列清楚。
- `DESIGN.md`：加「股票账户」「一笔钱只记一次」「不计入账户余额」三段；理财列表不再按品类分组。
- `README.md`：功能一节加股票账户、导入开关；导入一节加一句。

## 留给实施者的

- 宽屏右栏「股票账户 / 持仓」二选一的状态怎么存。
- 合并 sheet 里「新建股票账户」的流程（弹账户表单后回到 sheet 自动选中）。
- `pick_tx_sheet` 的筛选细节（只列支出 / 收入、未删、已确认、有账户、同币种）。
