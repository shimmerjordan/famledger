# famledger（家账）

[![测试](https://github.com/shimmerjordan/famledger/actions/workflows/test.yml/badge.svg)](https://github.com/shimmerjordan/famledger/actions/workflows/test.yml)
[![最新发布](https://img.shields.io/github/v/release/shimmerjordan/famledger?sort=semver&label=%E6%9C%80%E6%96%B0%E5%8F%91%E5%B8%83)](https://github.com/shimmerjordan/famledger/releases/latest)
[![许可](https://img.shields.io/github/license/shimmerjordan/famledger)](LICENSE)

自托管的家庭账本：**一个容器、一个端口（48090）、一个 SQLite 文件**。钱按「账户 × 基金模块」两层记，手机端监听支付通知自动入账、在通知栏一键纠正，数据定时加密备份到 WebDAV 网盘，接 cc-trans / 硅基流动等 AI 渠道出月报和建议。Android、iOS、Web 看板共用同一份 Flutter 代码。

```
   手机 App（Android / iOS）              公网出口          NAS 单容器 :48090
   ──────────────────────────                              ────────────────────────────────
   Flutter UI（一份代码）                                   Node 24 单进程 · 零 npm 依赖
   data/     REST + SSE ───────▶  Cloudflare Tunnel ───▶   /              Web 看板（静态）
   capture/  解析器 + 朴素贝叶斯                            /api/v1/*      JSON
   本地缓存 + outbox（clientId 幂等）                       /api/v1/ai/*   SSE ──▶ AI 渠道
                                                           backup 调度    ──▶ WebDAV 网盘
   Android 原生                                             node:sqlite    /data/famledger.db
   NotificationListenerService                                             /data/secret.key
     → headless Flutter 引擎（同一份解析器）
     → 结果通知：正确 / 修改… / 撤销       浏览器 ────────▶ 同一个端口，同一份 Flutter 代码
```

**数据权威在服务端**：手机只做「读缓存 + 写 outbox」，离线照记，联网后按 `clientId` 幂等补交，不做双向合并。金额一律整数「分」。

---

## 一、三步部署

### 方式 A：拉 GHCR 镜像（推荐）

```bash
# 在仓库根目录
docker compose -f deploy/docker-compose.yml up -d
docker compose -f deploy/docker-compose.yml logs -f
```

浏览器打开 `http://<NAS 内网 IP>:48090/`，进首启向导。升级：

```bash
docker compose -f deploy/docker-compose.yml pull
docker compose -f deploy/docker-compose.yml up -d
```

镜像 `ghcr.io/shimmerjordan/famledger`，双架构（amd64 / arm64），tag 有 `latest`、`<版本号>`、`sha-<短提交号>`。

> 镜像由「构建与发布」流水线**手动触发**才会推上去（见第十节）。第一次发布之前 GHCR 上是空的，包还没设成 public 时 `docker pull` 会报 `denied` / `unauthorized`——这两种情况都先用下面的方式 B 本地构建。

### 方式 B：本地构建（改了代码 / 不想用 GHCR）

```bash
./scripts/build-web.sh                                          # 先出 Flutter Web 产物
docker compose -f deploy/docker-compose.build.yml up -d --build
```

**顺序别反**：`deploy/Dockerfile` 只是 `COPY app/build/web/`，没跑过 `build-web.sh` 也能构建出镜像，但打开首页看到的是「Web 产物未构建」说明页而不是看板。机器上没装 Flutter，就把 `deploy/docker-compose.build.yml` 里的 `dockerfile:` 换成 `deploy/Dockerfile.full`（多阶段，第一阶段自带 Flutter 3.32.1，首次十几分钟）。

### 数据目录

容器里 `/data` 放两个东西：`famledger.db`（SQLite，WAL，另有 `-wal`/`-shm` 伴生文件）和 `secret.key`（0600，首启自动生成）。

- **不配**（默认）→ Docker 命名卷 `fldata`，零宿主配置，属主继承镜像里的 `node`（UID 1000），直接就能写。
- **配成绝对路径** → bind mount，数据落在你自己的目录里（NAS 上通常这么选）：

```bash
mkdir -p /volume1/docker/famledger/data
chown -R 1000:1000 /volume1/docker/famledger/data     # bind mount 不继承镜像属主，挂上来是 root:root
FL_DATA_PATH=/volume1/docker/famledger/data docker compose -f deploy/docker-compose.yml up -d
```

漏了 `chown` 的表现是容器起来几秒就退，日志里是 `EACCES: open '/data/secret.key'`。

> 只用**本地文件系统**。别把 `/data` 指向 NFS/SMB——网络挂载上 POSIX 锁不可靠，SQLite 在那上面有把库写坏的真实风险。异地备份用应用内的 WebDAV 功能。
>
> `secret.key` 是令牌签名与 AI/WebDAV 凭据加密的根。**它要和数据库一起备份**：只有 `.db` 而没有它，恢复后全家要重新登录，库里加密的凭据全成乱码。

---

## 二、Cloudflare Tunnel（公网访问）

家宽运营商普遍封入方向的 80 / 443 / 8080，所以端口一律走高位 48090，公网访问靠隧道（出方向 443，不受入方向封禁影响）。**别把端口配回 80/443**，那是白折腾。

这台 NAS 上的隧道（`nas-adan`）是**本地 `config.yml` + 通配符 DNS** 模式，加一个服务只需要把 `deploy/cloudflared-ingress.example.yml` 里那段 ingress 粘到 `~/.cloudflared/config.yml` 的 ingress 列表里（**放在 catch-all 之前**），然后重启：

```bash
sudo systemctl restart cloudflared      # 或 docker restart cloudflared
```

不用去面板点 Public hostname，不用加 DNS 记录，**更不要**给这个隧道塞 `TUNNEL_TOKEN`——那会把它切成面板托管模式，本地 `config.yml` 直接失效，现有的一堆 hostname 会一起掉线。

要点（完整注释见 `deploy/cloudflared-ingress.example.yml`）：

- `service: http://localhost:48090`——同一个端口既是看板也是 API，不用分两条 ingress。
- `originRequest.keepAliveTimeout: 90s`——AI 月报/对话是 SSE 长连接，回源空闲超时放宽一点。
- 容器里 `TRUST_PROXY=1`，限流靠 cloudflared 带下来的 `CF-Connecting-IP`，这一段不用额外配。
- 路由器上**不需要**做任何端口映射。

---

## 三、首启向导

1. 打开看板（`http://<内网 IP>:48090/` 或隧道域名）。Web 端会把服务器地址预填成同源；手机 App 首次启动要手填 `http://<内网 IP>:48090`，App 会校验 `/healthz` 与 `/api/v1/setup/status`。
2. 服务端没有任何成员时 `needsSetup: true`，向导要你填：家庭名称、用户名（2–32 字符，可以是中文）、口令（≥ 6 位）、显示名。
3. 提交后自动种一套默认数据：21 个中文类别（15 支出 + 6 收入）、1 个「家庭公共基金」、1 个「现金」账户。第一个成员就是 admin。
4. 有成员之后 `/api/v1/setup` 自动关闭（再调是 409），后续一律走登录页。

**加成员**：设置（我的）→ 成员 → 新建。只有 admin 能建/改/归档成员和重置口令；成员角色分 `admin` / `member`。

**SETUP_TOKEN（可选）**：一个还没初始化的实例挂到公网上，谁先打开谁就是管理员。**先暴露、后初始化**的话务必设一个：

```bash
openssl rand -hex 16                     # 生成一个，填进 compose 的 SETUP_TOKEN
```

设了之后，初始化请求必须带上这个令牌，**两条通道等价**：`x-setup-token` 请求头，或 JSON 体里的 `setupToken` 字段。App / 看板的初始化页多出一个「初始化令牌」输入框，走的是请求体那条；命令行用请求头更顺手：

```bash
curl -sS -X POST http://127.0.0.1:48090/api/v1/setup \
  -H 'content-type: application/json' \
  -H "x-setup-token: $SETUP_TOKEN" \
  -d '{"householdName":"我家","username":"adan","password":"换成你的口令","displayName":"阿丹"}'
```

两边都不对（或都没带）一律 403，且响应时间不暴露是哪条通道匹配上的。初始化完成后这个变量就不再起作用，可以留着。

健康检查与状态：

```bash
curl -fsS http://127.0.0.1:48090/healthz                  # → ok
curl -fsS http://127.0.0.1:48090/api/v1/setup/status      # → {"needsSetup":true}
```

---

## 四、环境变量

服务端读的（`server/src/server.js`、`modules/ai.js`）：

| 变量 | 默认 | 说明 |
|---|---|---|
| `TZ` | `Asia/Shanghai`（镜像内） | **必须设对**。统计按自然月切，时区错了「本月支出」「月报」就是错的；镜像里装了 `tzdata`，缺它 Node 会静默回落 UTC |
| `TRUST_PROXY` | `1`（镜像内） | **反代/隧道后面必须是 1**：限流按客户端 IP 分桶（`CF-Connecting-IP` > `X-Forwarded-For` 首个），不开的话看到的永远是反代自己，全世界共用一个桶 = 没有限流。**直接把端口暴露在局域网、前面没有任何反代时设 0**，否则谁都能伪造 `X-Forwarded-For` 绕过限流 |
| `PORT` | `48090` | 容器内别改——镜像的 `HEALTHCHECK` 探的就是 48090。换宿主端口用 `FL_PORT` |
| `HOST` | `0.0.0.0` | 监听地址 |
| `DATA_DIR` | `/data`（镜像）/ `./data`（源码） | `famledger.db` + `secret.key` 落这里 |
| `WEB_ROOT` | `/web` | Flutter Web 产物目录。里面没有 `index.html` 时发一个说明页，API 照常工作 |
| `SETUP_TOKEN` | 空 | 首次初始化口令。空 = 不加锁；设了则初始化要带 `x-setup-token` 头或请求体的 `setupToken` 字段 |
| `SETUP_PER_MIN` | `5` | 每 IP 每分钟的初始化尝试次数（挡住对 `SETUP_TOKEN` 的爆破） |
| `LOGIN_PER_MIN` | `10` | 每 IP 每分钟的登录尝试次数 |
| `AI_PER_MIN` | `30` | 每**成员**每分钟的 AI 请求次数。按成员分桶而不是按 IP——全家在同一个公网出口后面，按 IP 会互相挤掉。超了 `429 rate_limited` |
| `AI_MAX_STREAMS` | `4` | 同时在跑的上游**流**条数（月报/对话是 SSE）。超了 `503 ai_busy`，名额在请求结束时归还 |
| `CORS_ORIGINS` | 空 | 只有把看板单独部署到另一个域名时才需要（App 和看板默认同源）。逗号分隔，`*` 也认 |
| `LOG_LEVEL` | `info` | `debug` 会打请求行与耗时。`rawText` 之类的敏感内容任何级别都只记长度 |

> `SETUP_PER_MIN` / `LOGIN_PER_MIN` / `AI_PER_MIN` / `AI_MAX_STREAMS` 填 `0` 或非法值会被**忽略并回落默认**，免得一个手滑的 0 把全家锁在门外（或者把 AI 关到谁都用不了）。

compose 层面的（只在 `deploy/docker-compose*.yml` 里用）：

| 变量 | 默认 | 说明 |
|---|---|---|
| `FL_PORT` | `48090` | 宿主端口。被占了改这个，容器内那侧别动 |
| `FL_DATA_PATH` | `fldata` | 不设 = 同名命名卷；设成绝对路径 = bind mount（记得 `chown -R 1000:1000`） |

`BACKUP_TICK_MS` 只给测试用（覆盖 60 秒的备份调度 tick），生产别设。

---

## 五、资金模型：账户 × 基金

两层正交，这是整个产品的地基：

- **账户**＝钱**物理**在哪：现金 / 银行卡 / 支付宝 / 微信 / 信用卡 / 投资 / 其他（`cash` `bank` `alipay` `wechat` `credit` `invest` `other`）。余额 = 期初金额 + Σ 流水。
- **基金模块**＝钱**逻辑**归谁、干什么：个人零花、家庭公共基金、养老储备、育儿基金、宠物基金、应急金、旅行基金、房贷车贷还款金（8 个内置模板，也可自建）。余额 = Σ 流水。

每笔流水**恰好归一个基金**：

| 类型 | 账户侧 | 基金侧 |
|---|---|---|
| 支出 | `accountId` − | `fundId` − |
| 收入 | `accountId` + | `fundId` + |
| 转账 | `accountId` → `toAccountId` | `fundId` → `toFundId` |

转账的「账户对」和「基金对」**各自可选、互相正交**。所以：

- **转账**（钱从卡挪到支付宝）＝只填账户对，基金余额不动。
- **拨款**（从家庭公共基金划 500 给宠物基金）＝只填基金对，**账户余额不动**——钱还在那张卡里，只是改了归属。

只有账户回答不了「宠物还能花多少」，只有信封（YNAB 式）又对不上银行余额；两层一起才能同时回答「卡里有多少」和「这个模块还剩多少」。

预算按基金或按类别设，`month` 填 `YYYY-MM` 是那一个月，填 `*` 是每月默认（精确月份优先）。币种默认 CNY，v1 不做多币种换算。

---

## 六、自动记账

### Android（全自动）

装 APK（GitHub Release 的 `famledger-<版本>.apk`，或本机 `cd app && flutter build apk --release`），然后在 **设置 → 自动记账** 里把四件事办齐：

1. **通知使用权**：设置 → 通知与控制中心 → 通知使用权 → 允许「家账」。页面上的「去开启」在 Android 11+ 直达本应用那一页。命令行等价物：
   ```bash
   adb shell cmd notification allow_listener com.famledger.app/com.famledger.app.capture.CaptureListenerService
   ```
2. **通知权限**（Android 13+）：在设置页点「允许」，否则结果通知发不出来（流水照记）。
3. **MIUI 自启动 + 省电无限制**：MIUI 会在应用被划掉或长时间后台后停掉通知监听服务，**表现为监听开关还是开的但收不到通知**。设置页「后台保活（MIUI）→ 去设置」会依次尝试：安全中心自启动管理 → 电量与性能的应用省电策略（选「无限制」）→ 应用详情。建议同时在最近任务里给「家账」加锁。
4. **允许的应用**：默认放行支付宝（`com.eg.android.AlipayGphone`）、微信（`com.tencent.mm`）、云闪付（`com.unionpay`）、四个主流短信 App（小米 / AOSP / Google 信息 / 三星）和十个银行 App（招行、建行、工行、中行、农行、交行、邮储、浦发、民生、平安）。设置页里可增删；调试构建额外放行 `com.android.shell`，供 `adb shell cmd notification post` 做端到端测试。

**识别与阈值**：通知文本 → 归一化 → 10 分钟窗口查重 → 按来源画像抽取（金额 / 方向 / 商户 / 渠道 / 卡尾号）→ 用户规则 → 朴素贝叶斯（字符 n-gram）预测类别与基金。置信度 ≥ 阈值（默认 **0.75**，设置页 0.5–0.95 可调）直接入账，低于阈值落「待确认」，在首页卡片里处理。可选「AI 兜底」（默认关）：低置信度时调 `/ai/classify` 再决定。

**结果通知**：标题 `支付宝 −¥35.00 · 餐饮 → 家庭公共基金`，正文 `92% 可信 · 美团外卖 · 点击修改`（没到阈值的多一个「待确认」）。三个动作：**正确 / 修改… / 撤销**；点通知本身直接打开这笔流水。

**「修改…」的快捷回复语法**：直接在通知栏输入框里打字，**按空格或标点分段**，每段各自认领：

```
宠物 35 给猫买粮
└基金  └金额  └备注
```

- 纯数字段（可带 `¥`、千分位、`元` / `块`）→ 改金额；
- 命中基金名或别名 → 改基金（**基金优先于类别**，所以「宠物」先理解成宠物基金）；
- 命中类别名 → 改类别；
- 「收入 / 支出 / 转账」→ 改方向；
- 其余拼成备注。

分段是刻意的：整句扫描会把「给猫买2袋粮」误改成 2 元，而快捷回复改完就直接确认落库，错了没人拦。每次纠正都会喂给本地模型并 `POST /model/learn` 同步给全家。

### iOS（半自动）

iOS 没有读取其他 App 通知的接口，**这是系统硬限制，不是没做**。三条入口：分享扩展（在账单/短信里选中文字或截图 → 分享 → 发送到家账）、快捷指令 / Siri（可配合「个人自动化」，比如收到指定号码短信时运行）、App 内「从剪贴板导入」。三条入口共用同一套 Dart 解析管线，行为与 Android 一致。

首次构建需要在 Xcode 里做一次性手工步骤（App Group、Share Extension target、URL Scheme、签名），全部写在 **[`docs/ios.md`](docs/ios.md)** 里。本机没有 Xcode，iOS 原生代码**只写了代码，未做编译验证**。

### 已知的坑：第三方通知转发/清理类 App

手机上如果装了通知转发器（短信转发器、MacroDroid、Tasker、AutoNotification 之类，它们本身也是通知监听器），它可能把家账的结果通知**转发走并取消掉**——三个按钮就看不到了。真机实测过一例：`cn.ppps.forwarder` 在通知入队约 250 ms 后以 `reason=10`（`REASON_LISTENER_CANCEL`）取消并转发到了飞书。

这种情况下**流水已经正常入账**，去首页「待确认」或账单页处理即可。想确认是谁干的：

```bash
adb logcat -b events | grep notification_canceled     # reason 10 = 其他通知监听器取消的
```

对策是在那个转发器的规则里把 `com.famledger.app` 加进白名单/排除列表。

---

## 七、AI 渠道

设置 → **AI 渠道** → 新建（admin）。两种协议一个出口：`anthropic`（`POST {baseUrl}/v1/messages`，`x-api-key`）和 `openai`（`POST {baseUrl}/chat/completions`，`Authorization: Bearer`，`baseUrl` 自带 `/v1`）。八个预设一键填表：

| 预设 | 协议 | baseUrl 默认值 | 模型默认值 | 密钥 |
|---|---|---|---|---|
| cc-trans（自建 Anthropic 反代） | `anthropic` | `http://nas:8787` | `claude-sonnet-5` | 填 cc-trans 下发的 **`cct-` 客户端令牌**；地址改成你自己的 cc-trans 服务 |
| 硅基流动 | `openai` | `https://api.siliconflow.cn/v1` | `Qwen/Qwen3-32B` | 控制台「API 密钥」，`sk-` 开头 |
| DeepSeek 深度求索 | `openai` | `https://api.deepseek.com/v1` | `deepseek-chat` | platform.deepseek.com → API keys |
| 月之暗面 Kimi | `openai` | `https://api.moonshot.cn/v1` | `kimi-k2-0711-preview` | platform.moonshot.cn → API Key 管理 |
| 智谱 GLM | `openai` | `https://open.bigmodel.cn/api/paas/v4` | `glm-4.5` | bigmodel.cn 控制台 → API Keys |
| OpenAI 官方 | `openai` | `https://api.openai.com/v1` | `gpt-5-mini` | 需要能直连，国内一般要走反代 |
| Anthropic 官方 | `anthropic` | `https://api.anthropic.com` | `claude-sonnet-5` | 同上 |
| Ollama（本机模型） | `openai` | `http://host.docker.internal:11434/v1` | `qwen3:8b` | 不需要密钥；容器里必须用 `host.docker.internal` 才找得到宿主机 |

建完点「测试」跑一次非流式往返，回 `{ok, model, latencyMs, sample}`。用法：分析页的 **AI 月报**（流式生成，落库可回看）和 **问 AI** 对话。

三条红线：

- **密钥只存服务端**，AES-256-GCM 加密落库（密钥是 `DATA_DIR/secret.key`），接口只回 `hasKey` 和尾 4 位，手机与浏览器永远拿不到明文，错误消息里也擦掉。
- **模型不直接碰库**：服务端先把本月概览、近半年趋势、预算达成率、基金目标进度算好，拼成中文塞进 system 提示词。
- **客户端一断，上游那条请求立刻 abort**，不给别人白烧 token。

限流是账单保护，不是性能调优：`AI_PER_MIN`（默认 30，按成员）、`AI_MAX_STREAMS`（默认 4，同时在跑的流）。

---

## 八、WebDAV 备份

设置 → **备份与恢复**（admin）。

**填地址**。坚果云为例：

| 字段 | 值 |
|---|---|
| 服务器地址 | `https://dav.jianguoyun.com/dav/` |
| 用户名 | 你的坚果云登录邮箱 |
| 密码 | **应用密码**（坚果云网页版 → 账户信息 → 安全选项 → 添加应用密码），**不是**你的登录密码 |
| 远程目录 | 默认 `/famledger` |

填完点「测试」，再点「立即备份」验证一次。

**定时**：开关 + 整点小时（默认 **3 点**）+ 保留份数（默认 **14**）。到点跑一次，失败当天最多重试 3 次、间隔 10 分钟；成功后把超出保留份数的旧快照连同 manifest 一起删掉。

**快照怎么做的**：`VACUUM INTO` 取一份一致性快照（不停写也不锁库）→ gzip →（可选）AES-256-GCM 加密 → PUT 成 `famledger-YYYYMMDD-HHMMSS.db.gz[.enc]`（本地时区），外加同名 `.json` manifest（字节数、sha256、schema 版本）。

**加密与密语**：勾了加密就要设一个密语，用 scrypt 派生密钥。

> **密语丢了备份就废了。** 没有找回途径，服务端存的是加密后的密语（只为了跑定时任务），不是明文。另外**恢复用的是当前配置里的密语**——换过密语之后，用旧密语加密的历史快照解不开。

**恢复**：列出网盘上的快照 → 选一个 → 下载 → 核对 manifest 的 sha256 → 解密 → gunzip → 用独立连接跑 `PRAGMA integrity_check`，**只有通过的文件才有资格换库**。换库前先把当前活库拷成 `DATA_DIR/pre-restore-<时间戳>.db`（恢复错了还能退回来），换库过程是「关库 → 改名 → 重开并跑迁移」，**服务进程不重启**。

**手动导出 / 导入**：不想配网盘就用导出（下载一个 gzip 快照）和导入（上传一个，admin，上限 200 MB）。

再说一遍：快照里**只有数据库**。`DATA_DIR/secret.key` 要自己单独收好。

---

## 九、Web 看板

- 同一份 Flutter 代码的 Web 构建，由后端**同一个端口**发出（`/`），不用另起前端服务，也就没有跨域问题（所以 `CORS_ORIGINS` 默认空）。
- 宽度 ≥ 840 dp 自动切成导航轨 + 双栏看板形态；窄屏就是手机那套底部导航。
- 首次打开的连接页已经把服务器地址预填成当前源，直接下一步即可。
- 升级镜像后浏览器**下一次打开**就换到新版：`index.html`、`flutter_bootstrap.js`、`flutter_service_worker.js`、`version.json` 一律 `no-cache, must-revalidate`，其余带 hash 的内容寻址资源长缓存一年。
- 打开看到「Web 产物未构建」说明页 = 镜像里 `/web` 没有 `index.html`，通常是本地构建时忘了先跑 `./scripts/build-web.sh`。

---

## 十、开发与测试

后端零第三方依赖，Node ≥ 22.13（镜像里是 24）：

```bash
cd server && npm test          # node --test，当前 160 条全绿，约 10 秒
```

App（Flutter 3.32.x）：

```bash
cd app
flutter pub get
flutter analyze
flutter test
flutter build web --release    # dart2js 编译门禁，analyze 抓不到的依赖/SDK 不兼容只有这步会炸
```

脚本：

```bash
./scripts/dev.sh                        # 本机跑服务端（前台，Ctrl-C 停），数据落 server/data/
PORT=48099 ./scripts/dev.sh             # 换端口
WEB_ROOT=/dev/null ./scripts/dev.sh     # 只要 API，不发静态
./scripts/build-web.sh                  # 构建 Flutter Web 产物到 app/build/web
./scripts/e2e-android.sh                # Android 真机端到端（见下）
./scripts/version.sh                    # 打印 CHANGELOG.md 里的版本号
```

`scripts/dev.sh` 的数据目录（`server/data/`）和容器里的 `/data` **是两份**，随便删，但别混用——那边的 `secret.key` 换了会把全家踢下线。手机端调试把 App 的服务器地址填 `http://<本机内网 IP>:48090`（Android 模拟器用 `10.0.2.2`）。

**Android 真机端到端**（连好设备即可，脚本自己构建、安装、起临时服务端、收尾）：

```bash
./scripts/e2e-android.sh
SKIP_BUILD=1 REPLY_TEXT=旅行 OUT=/tmp/fl-e2e ./scripts/e2e-android.sh   # 复用已有 APK，换快捷回复目标
```

它跑的是：起服务端 → 初始化家庭 → `adb reverse` → 广播登录 → 放行通知监听 → 发一条假支付宝通知 → 轮询服务端直到出现这笔流水 → 广播快捷回复 → 校验基金被改对。截图落在 `app/build/e2e-android/`（可用 `OUT=` 改）。脚本只碰自家应用，不卸载、不动其他应用。

可疑的镜像可以在容器里自证（`server/test/` 也在镜像内）：

```bash
docker exec famledger sh -c 'cd /app/server && node --test test/*.test.js'
```

### CI

- **`.github/workflows/test.yml`（测试）**——push / PR 自动跑，也被发布流水线 `workflow_call` 复用。三个 job：`server`（`npm test`）、`app`（`flutter analyze` + `flutter test` + `flutter build web --release`）、`docker`（`docker build -f deploy/Dockerfile .` → 起容器 → 轮询 `/healthz` 到 `ok` → 冒烟 `/api/v1/setup/status`）。
- **`.github/workflows/build.yml`（构建与发布）**——**只能手动触发**：Actions → 构建与发布 → Run workflow。版本号取自 `CHANGELOG.md`（`scripts/version.sh`，可用 `version` 输入覆盖）→ 先跑一遍 test.yml 当门禁 → 推 GHCR 双架构镜像（`latest` / `<版本号>` / `sha-<短提交号>`）+ 出 release APK → 建 GitHub Release 并挂上 APK。`publish` 取消勾选 = 镜像和 APK 照编照验，但不推 GHCR、不建 Release。**每次运行**（不论是否真的发布）都会额外跑一个 `docs` job，把「这个版本怎么部署 / 怎么装 / 怎么用」写进**这次 Actions 运行自己的 Summary 页面**（`$GITHUB_STEP_SUMMARY`）——验证性构建也能预览部署说明，不用等 Release 页面或翻整份 README。

门禁自动化、发布手动化：push 只回答「代码是好的吗」，发布回答「现在要发出去吗」，后者该由人按下按钮。不需要任何 secrets（`GITHUB_TOKEN` 是自动提供的）。

---

## 十一、已知限制与后续计划

**iOS**

- 读不到其他 App 的通知（系统硬限制），没有 Android 那条全自动路径，只有分享扩展 / 快捷指令 / 剪贴板三条半自动入口。
- iOS 原生代码**未在本机编译验证**（没有 Xcode），首次构建要按 `docs/ios.md` §3 做一次性手工步骤，§7 列出了重点要看的 API 风险点。
- 免费个人 Apple ID 不支持 App Groups：分享扩展仍可用（正文走 URL 参数，超过 1500 字符会截断），快捷指令会明确报「保存失败」。

**Android**

- 第三方通知转发/清理类 App 会吞掉结果通知（见第六节），流水不受影响。
- Release APK 目前签的是 **debug 密钥**，能侧载、能跑，但没有覆盖安装的跨签名保证，也不适合上架应用商店。要生产签名得另配 keystore。
- 基金分类器冷启动会「赢者全拿」：第一次用快捷回复改基金后，基金模型里只有那一个类，接下来几笔都会落到它。手动改几笔、让模型见到第二个类就正常了。

**服务端 / 部署**

- 数据目录必须在本地文件系统（SQLite + 网络挂载 = 坏库风险）。
- 单租户：一次部署 = 一个家庭；没有公开注册。

**v1 明确不做**：多币种换算、附件/发票图片、投资持仓行情、导入第三方账单文件（`source=import` 已预留）、服务器推送到手机、公开注册、多家庭多租户。

---

版本变更见 [`CHANGELOG.md`](CHANGELOG.md)；设计与 API 契约见 [`docs/superpowers/specs/2026-09-12-famledger-design.md`](docs/superpowers/specs/2026-09-12-famledger-design.md)；产品定位与视觉规则见 [`PRODUCT.md`](PRODUCT.md) 与 [`DESIGN.md`](DESIGN.md)。
