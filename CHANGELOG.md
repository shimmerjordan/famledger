# 更新日志

本项目的版本号是给人看的：`0.x` 阶段接口可能在小版本之间变，数据库迁移始终向前兼容
（`schema_migrations` 只增不减，升级镜像即可，不需要手工改库）。

## 0.1.0 — 2026-09-13

首个可用版本。一个容器、一个端口（48090）、一个 SQLite 文件（`/data/famledger.db`），
手机与 Web 看板共用一份 Flutter 代码。

- **服务端**：Node 24、**零第三方依赖**、单进程。`src/modules/*.js` 按「导出是不是函数」
  自动装载，加接口不用改 `server.js`：`setup` `auth` `members` `accounts` `funds`
  `categories` `transactions` `budgets` `rules` `model` `stats` `changes` `ai` `backup`
  `settings` `static` 十六个模块。`node:sqlite`（WAL、外键开）+ `schema_migrations`
  向前兼容迁移。`node --test` 160 条全绿。
- **账本**：账户（现金/银行卡/支付宝/微信/信用卡/投资）× 基金模块两层正交模型；支出、
  收入、转账/拨款；类别树与默认中文类别（首启种 21 个 + 一个「家庭公共基金」+ 一个
  「现金」账户）；成员、预算（按基金或类别、可设每月默认）；`clientId` 幂等 + 批量提交；
  服务端查重（同额同类 3 分钟内的自动记账判重复）；流水软删除 + 全局 `seq` 增量同步；
  金额一律整数「分」；`occurredAt` 存客户端给的带偏移本地时间，服务端不做时区换算。
- **基金模块**：个人零花、家庭公共、养老储备、育儿、宠物、应急金、旅行、房贷车贷还款金
  八个模板；余额、目标进度、月预算进度；基金间拨款不影响账户余额。
- **App 页面**（Flutter 3.32，Material 3，一份代码出三端）：连接向导 / 初始化 / 登录；
  首页（本月收支、基金卡片横滑、待确认自动记账、最近流水）；账单（按日分组、多维筛选、
  搜索）；记一笔（金额键盘 → 类型 → 类别 → 基金 → 账户 → 成员，记住上次选择）；基金
  （列表、模板新建、详情、拨款）；分析（月趋势、类别环形、成员对比 + AI 入口）；我的
  （成员 / 账户 / 类别 / 预算 / 自动记账 / 识别规则 / AI 渠道 / 备份与恢复 / 服务器与
  账号 / 关于）。自适应外壳：< 840 dp 底部导航，≥ 840 dp 导航轨 + 双栏。
- **自动记账管线**（纯 Dart 一份，三端共用）：归一化 → 10 分钟窗口查重 → 支付宝/微信/
  云闪付/银行短信/通用五套来源画像抽取（金额、方向、商户、渠道、卡尾号）→ 用户规则 →
  朴素贝叶斯（字符 n-gram）预测类别与基金 → 置信度低于阈值（默认 0.75）转待确认 →
  离线补传。320 条中文种子样本首启训练，54 条真实风格通知样本做回归。
- **Android 原生**：`NotificationListenerService` → 常驻 headless Flutter 引擎跑同一份
  Dart 管线；结果通知带「正确 / 修改…（`RemoteInput` 直接在通知栏输入）/ 撤销」，快捷
  回复按空格分段解释（`宠物 35 给猫买粮` = 改基金 + 改金额 + 记备注），纠正样本回灌模型
  并经 `POST /model/learn` 全家同步；`famledger://` 深链；MIUI 自启动/省电设置一键跳转；
  `scripts/e2e-android.sh` 全自动真机端到端，已在小米 MIUI 14 / Android 13 上跑通。
- **iOS**：分享扩展、快捷指令 / Siri、剪贴板导入三条半自动入口（系统读不到别的 App 的
  通知，没有全自动路径）。**本轮只出代码，未做编译验证**；Xcode 一次性手工步骤与 API
  风险点写在 `docs/ios.md`。
- **WebDAV 备份**：`VACUUM INTO` 取一致性快照 → gzip →（可选）AES-256-GCM 加密 → PUT 到
  WebDAV，保留最近 N 份（默认每天 3 点、留 14 份）；恢复要先过 manifest 的 sha256 与
  `PRAGMA integrity_check`，换库前留一份本地 `pre-restore` 副本，整个过程不重启进程。
  也可手动导出/导入。
- **AI 分析**：`anthropic` 与 `openai` 两种渠道（cc-trans、硅基流动、DeepSeek、月之暗面、
  智谱、OpenAI、Anthropic、Ollama 八个预设一键填），统一转成自家 SSE 流；月报与「问 AI」
  对话；聚合数据由服务端算好注入提示词，模型不直接碰库；API key AES-256-GCM 加密落库，
  手机与浏览器不接触明文；按成员限流 `AI_PER_MIN`（默认 30）与并发流上限
  `AI_MAX_STREAMS`（默认 4），客户端一断就 abort 上游。
- **Web 看板**：同一份 Flutter 代码的 Web 构建，≥ 840 dp 自动切双栏看板形态；由后端同端口
  发出，无需另起前端服务。
- **部署**：`node:24-bookworm-slim` 单进程镜像（非 root、`HEALTHCHECK`、`VOLUME /data`），
  GHCR 拉取或本地构建两套 compose，`Dockerfile.full` 供没装 Flutter 的机器多阶段自构建，
  以及一条 Cloudflare Tunnel ingress 示例（家宽封 80/443，端口一律走高位）。
- **CI**：`test.yml`（push / PR 自动跑：server `npm test`、`flutter analyze` + `test` +
  `build web`、`docker build` 起容器冒烟 `/healthz` 与 `/api/v1/setup/status`）；
  `build.yml` **只能手动触发**（版本号取自本文件 → 复用 test.yml 当门禁 → GHCR 双架构
  镜像 `latest` / `<版本号>` / `sha-<短提交号>` + release APK → GitHub Release），每次
  运行都额外生成一份「怎么部署/怎么装/怎么用」的说明写进这次运行自己的 Actions Summary
  页面（不论是否勾选真的发布）。
- **安全**：scrypt 口令、可吊销令牌（30 天，`devices` 表）、登录与初始化限流、
  admin/member 角色、首次初始化可用 `SETUP_TOKEN` 加锁（`x-setup-token` 请求头与请求体的
  `setupToken` 字段等价，两条通道都认）；`DATA_DIR/secret.key`（0600）
  首启自动生成，是所有加密与签名的根，备份务必带上它。
- **已知限制**：iOS 原生未编译验证；release APK 目前签的是 debug 密钥（只能侧载）；
  第三方通知转发类 App 会吞掉 Android 的结果通知。详见 README。
