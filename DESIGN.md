# Design

famledger（家账）的视觉系统。所有 Flutter 主题 token 以此为源（`app/lib/app/theme.dart`）。

## Mood

「厨房餐桌上的家庭账本——白纸黑字，一抹赭红做记号。」产品 register，色彩策略 **Restrained**：中性面 + 一个赭红强调色 ≤ 10%，基金身份色作为数据可视化的唯一「full palette」例外。

## Color (OKLCH → sRGB hex)

浅色（默认跟随系统）：

| Role | OKLCH | Hex | 用途 |
|---|---|---|---|
| bg | 1 0 0 | #ffffff | 页面底 |
| surface2 | 0.965 0.004 260 | #f2f3f6 | 导航栏/工具栏/面板（略冷的第二中性层） |
| surface3 | 0.93 0.006 260 | #e5e8ec | 输入框底、分隔块 |
| ink | 0.20 0 0 | #161616 | 正文、金额 |
| muted | 0.50 0.012 260 | #5f636a | 次要文字（对白 6.0:1） |
| outline | 0.86 0.006 260 | #cfd1d5 | 1px 边线 |
| primary | 0.58 0.15 38 | #c25430 | 主操作、选中态、FAB（白字 4.56:1） |
| primaryContainer / on | 0.94 0.04 38 / 0.32 0.10 38 | #ffe3d8 / #5b1a03 | 强调容器 |
| income | 0.54 0.11 165 | #16805e | 收入金额 `+¥`（粗体≥14sp，≥3:1） |
| incomeContainer | 0.94 0.05 165 | #cdf6e3 | 收入标签底 |
| warning / container | 0.70 0.14 75 / 0.95 0.06 75 | #d0901e / #ffeac2 | 预算接近上限、待确认 |
| error / container | 0.55 0.19 25 / 0.94 0.05 25 | #c92f33 / #ffdfda | 超预算、失败 |

深色：

| Role | OKLCH | Hex |
|---|---|---|
| bg | 0.17 0 0 | #141414 |
| surface2 | 0.22 0.004 260 | #1b1c1e |
| surface3 | 0.27 0.006 260 | #26272a |
| ink | 0.94 0 0 | #ebebeb |
| muted | 0.70 0.012 260 | #9a9fa6 |
| outline | 0.32 0.006 260 | #313336 |
| primary | 0.74 0.13 38 | #f08c6d（深底字用 ink 反色 #3a1206） |
| primaryContainer / on | 0.32 0.09 38 / 0.92 0.05 38 | #571e0b / #ffdacd |
| income / container | 0.74 0.11 165 / 0.30 0.06 165 | #5fc199 / #043726 |
| warning / container | 0.80 0.13 75 / 0.34 0.08 75 | #eeb154 / #4f3000 |
| error / container | 0.72 0.17 25 / 0.34 0.10 25 | #fd736d / #621d1c |

支出金额用 ink（不着色），只带 `−`。正负永远靠符号，不靠颜色。

基金身份色（12 色，L .62 C .12；深色用 L .74 C .11）：

| # | hue | light | dark | 建议 |
|---|---|---|---|---|
| 1 | 38 | #c36a4f | #e79277 | 家庭公共 |
| 2 | 75 | #b07a20 | #d3a056 | 养老 |
| 3 | 110 | #8b8c27 | #afb15b | |
| 4 | 150 | #4a9a5e | #76be86 | 育儿 |
| 5 | 175 | #009d82 | #51c1a7 | |
| 6 | 200 | #009ba3 | #3ebfc6 | 应急 |
| 7 | 230 | #1292c0 | #57b8e3 | 个人 A |
| 8 | 260 | #5a86ce | #82acf0 | |
| 9 | 290 | #8678c9 | #aa9fec | 个人 B |
| 10 | 320 | #a66db3 | #ca94d6 | 宠物 |
| 11 | 350 | #bb6690 | #df8db5 | 旅行 |
| 12 | 15 | #c3656f | #e88d94 | |

## Typography

一个家族：系统 sans（Android Roboto + Noto Sans CJK，iOS PingFang，Web 走 `system-ui`）。不引入展示字体。Material 3 type scale 映射：

- 金额：`headlineMedium`（28sp/600）首页合计；`titleLarge`（22sp/600）卡片余额；列表金额 `bodyLarge`（16sp/600）。全部 `FontFeature.tabularFigures()`，两位小数，千分位。
- 标题 `titleMedium`（16sp/600），正文 `bodyMedium`（14sp），辅助 `bodySmall`（12sp，muted）。
- 尺寸固定 sp，不随屏宽缩放；宽屏变的是列数与导航形态。

## Shape & Elevation

- 圆角：卡片/面板 12，按钮/输入 10，芯片 8，FAB 16。
- 不用投影表达层级，用 surface2/surface3 色阶 + 1px outline；仅 FAB 与底部弹层用 M3 默认阴影。
- 卡片仅用于「基金卡片横滑」与「待确认项」两处；其余用分组列表与分隔留白，禁止嵌套卡片、禁止左侧色条。

## Layout

- 紧凑（< 600dp）：底部 NavigationBar 5 项 + 居中偏右 FAB「记一笔」。
- 中等（600–839）：NavigationRail + 单栏。
- 展开（≥ 840，Web 看板）：NavigationRail（可展开标签）+ 双栏：左 8/12 主内容，右 4/12 侧栏（基金余额、待确认、预算）。
- 网格：4dp 基准，页边距 16（紧凑）/ 24（展开），组间 24，组内 8/12。

## Motion

- 时长 150–250ms，`Easing.emphasizedDecelerate`；页面用 fade-through，列表项增删用 size+fade。
- 无启动编排、无装饰动效。`MediaQuery.disableAnimations` 为真时一律瞬切。

## Components

- 金额输入：自绘数字键盘（大键 56dp），顶部实时格式化。
- 基金选择：横向芯片行，芯片左侧 8dp 色点 = 基金色。
- 待确认项：surface2 背景 + 置信度文字「92% 可信 · 来自支付宝」，行内两个操作「正确」「修改」。
- 空态：一句说明 + 一个主操作（如「还没有基金，先从模板建一个」）。
- 加载：骨架块，不用居中转圈。
- 错误：行内说明 + 重试；Snackbar 仅用于可撤销的成功反馈。
