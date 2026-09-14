# iOS 原生部分：分享扩展 / 快捷指令 / URL Scheme

> **⚠️ 先读这一段**
>
> 本仓库的开发机是 Linux，**没有 Xcode**，因此：
>
> 1. **`app/ios/Runner.xcodeproj/project.pbxproj` 没有被修改**（盲改 pbxproj 极易把工程改坏）。
>    「新建 ShareExtension target」「把 `ShortcutIntents.swift` 加进 Runner target」「设置 entitlements 路径」
>    这些都是**必须在 Xcode 里手工做一次**的操作，步骤见下文第 3 节。
> 2. **所有 Swift 代码都没有编译验证过**，只做了人工审阅。第一次在 Xcode 里构建时如遇编译错误，
>    优先怀疑第 7 节「已知的 API 风险点」里列的几处。
> 3. 本文里出现的路径都相对仓库根目录；Flutter 工程在 `app/`。

---

## 1. 已交付的文件

| 文件 | 归属 target | 说明 |
| --- | --- | --- |
| `app/ios/ShareExtension/ShareViewController.swift` | ShareExtension | 分享扩展主体：读文本/网址/图片 OCR → 写 App Group → 唤起主 App |
| `app/ios/ShareExtension/Info.plist` | ShareExtension | `NSExtension` 配置（share-services + 激活规则 + 主类） |
| `app/ios/ShareExtension/ShareExtension.entitlements` | ShareExtension | App Group `group.com.famledger.app` |
| `app/ios/Runner/Runner.entitlements` | Runner | 同一个 App Group（新建文件） |
| `app/ios/Runner/Info.plist` | Runner | 新增 `CFBundleURLTypes`（scheme `famledger`）、`FlutterDeepLinkingEnabled=false`；显示名改为「家账」 |
| `app/ios/Runner/AppDelegate.swift` | Runner | 新增 MethodChannel `com.famledger/share` + `PendingShareStore` |
| `app/ios/Runner/ShortcutIntents.swift` | Runner | AppIntents「记一笔」(iOS 16+) + AppShortcutsProvider（iOS **16.4**+，见 7.3） |

未改动：`Runner.xcodeproj/project.pbxproj`、任何 Dart / Android 文件（`Podfile` 本来就还不存在，见 3.0）。

## 2. 契约（改任何一边都要同步另一边）

**标识符**

| 项 | 值 |
| --- | --- |
| 主 App Bundle ID | `com.famledger.app`（与 Android `applicationId` 一致） |
| 扩展 Bundle ID | `com.famledger.app.ShareExtension` |
| App Group | `group.com.famledger.app` |
| URL Scheme | `famledger` |
| MethodChannel | `com.famledger/share` |

**深链**

```
famledger://capture?source=share|shortcut|clipboard[&text=<urlencoded 文本>]
famledger://capture/<captureId>     ← Android 结果通知点击用的，iOS 不产生，但 Dart 侧解析时要区分
```

扩展**同时**走两条路，谁先到都不丢：

| 情况 | 写 App Group | 深链 `text=` |
| --- | --- | --- |
| 文本 ≤ 1500 字符（绝大多数） | ✅ 写 | ✅ **总是**带上完整文本 |
| 文本 > 1500 字符且 App Group 可用 | ✅ 写 | ❌ 不带（太长，走 `takePending()` 取完整版） |
| 文本 > 1500 字符且 App Group 不可用（免费个人证书，见 6.2） | ❌ 写不了 | ⚠️ 截断到 1500 字符带上（有损总好过全丢） |

- App Group 是否可用用
  `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:) != nil` 判断。
  **不能**用「写进 `UserDefaults(suiteName:)` 再读回来」探测 —— 没有权限时该初始化器**照样返回对象**，
  同进程内写完也读得回来，探测永远是「成功」，兜底就永远不会触发。
- Dart 侧规则：**`text=` 存在就以它为准**，但**每次都要照样 `takePending()` 把 store 清空并去重**，
  详见 8.3（只认 URL 不清 store，那份副本会在下一次 `takePending()` 时被重复导入）。

**App Group 存储格式**（`UserDefaults(suiteName: "group.com.famledger.app")`）

- key：`pendingShares`
- value：**JSON 数组字符串**，最多 20 条（超出丢最旧的）：

```json
[{"text": "支付宝 支出 35.00 元 美团", "source": "share", "receivedAt": "2026-09-13T04:05:06Z"}]
```

- `source` ∈ `share`（分享扩展）/ `shortcut`（快捷指令）。`receivedAt` 是 ISO8601（UTC，`Z` 结尾）。
- MethodChannel 返回的是**已经解析好的数组**（`List<Map>`），Dart 侧不需要再 `jsonDecode`。

**MethodChannel `com.famledger/share` 方法**

| 方法 | 返回 | 说明 |
| --- | --- | --- |
| `takePending` | `List<Map>` | 读取并清空（主 App 消费用这个） |
| `peekPending` | `List<Map>` | 读取不清空（调试/设置页展示用） |
| `clearPending` | `null` | 只清空 |

**深链的处理方式（两端不一样，别搞混）**

- 深链本身由 **`app_links` 插件**处理（它自动接管 `application(_:open:options:)`）。
  `AppDelegate` 里**没有**重写 `open url`，不要再加，否则会重复触发。
- `Runner/Info.plist` 里设了 **`FlutterDeepLinkingEnabled = false`**，与 Android
  `AndroidManifest.xml` 的 `flutter_deeplinking_enabled=false` 对齐：
  关掉 Flutter 引擎自带的「深链 → 路由」转发，否则 `famledger://capture?source=share`
  会被原样当成路由推给 go_router（变成匹配不上的 `/capture`），与 Dart 的 `app_links` 监听重复一次。
- Android 侧是 `MainActivity`（`DeepLinks.routeFor`）**原生**把深链翻译成 go_router 路径；
  iOS 侧没有原生翻译，全部交给 Dart 的 `app_links` 监听（见 8.1）。

---

## 3. Xcode 手工步骤（一次性）

### 3.0 准备

⚠️ 仓库里**没有 `app/ios/Podfile`**（Flutter 按需生成），所以**不能上来就 `pod install`**，会直接报
`No Podfile found`。正确顺序：

```bash
cd app
flutter pub get

# ① 生成 ios/Podfile 与 ios/Flutter/Generated.xcconfig（只更新工程配置，不真的构建）
flutter build ios --config-only --no-codesign

# ② 把生成的 Podfile 顶部的 platform 打开并改成 13.0：
#    # platform :ios, '12.0'   →   platform :ios, '13.0'
$EDITOR ios/Podfile

# ③ 这时才能装 Pods
cd ios && pod install

open Runner.xcworkspace   # 注意是 .xcworkspace，不是 .xcodeproj
```

> 以后改了 `pubspec.yaml` 里的插件依赖，重复 ①③ 即可（Podfile 不会被覆盖）。

### 3.1 统一 Bundle ID 与最低系统版本

Xcode → 选中 `Runner` 工程 → TARGETS：

1. `Runner` → Build Settings → `Product Bundle Identifier`：
   `com.famledger.famledger` → **`com.famledger.app`**。
2. `RunnerTests` → 同项改为 **`com.famledger.app.RunnerTests`**。
3. `Runner` → Build Settings → `iOS Deployment Target`：`12.0` → **`13.0`**
   （`ShareViewController` 用到 `.systemBackground`、`UIActivityIndicatorView.Style.medium`、Vision 文本识别，都需要 iOS 13）。
4. 同步把 `app/ios/Flutter/AppFrameworkInfo.plist` 里的 `MinimumOSVersion` 从 `12.0` 改成 `13.0`
   （`Podfile` 的 `platform :ios, '13.0'` 在 3.0 的第 ② 步已经改过；当时漏了的话现在补上并重跑 `pod install`）。

### 3.2 给 Runner 加 App Group

1. `Runner` target → Signing & Capabilities → 左上角 **+ Capability** → **App Groups**。
2. 点 `+` 新增 / 勾选 **`group.com.famledger.app`**。
3. Xcode 会自动把 `CODE_SIGN_ENTITLEMENTS` 指到 `Runner/Runner.entitlements`。
   仓库里**已经有这份文件**，内容就是这个 App Group：
   - 如果 Xcode 识别到了已有文件，直接在上面追加/勾选即可；
   - 如果 Xcode 新建了另一个文件（例如 `Runner/RunnerDebug.entitlements`），
     把 Build Settings 里 Debug/Release 两个配置的 `Code Signing Entitlements` 都指回 `Runner/Runner.entitlements`，
     并删掉多余的文件。

### 3.3 新建 Share Extension target

⚠️ Xcode 的模板会在 `app/ios/ShareExtension/` 下生成同名文件，**会覆盖我们仓库里的三份**。
建议顺序：先把我们那三份文件临时挪走 → 让 Xcode 生成 → 再覆盖回去。

```bash
# 以下命令都在仓库根目录执行
mv app/ios/ShareExtension /tmp/ShareExtension.ours
```

1. Xcode → File → New → **Target…** → iOS → **Share Extension**。
2. 填写：
   - Product Name：**`ShareExtension`**（必须一致，`$(PRODUCT_MODULE_NAME)` 会用到）
   - Language：**Swift**
   - Project：`Runner`，Embed in Application：**`Runner`**
3. 弹出 “Activate ShareExtension scheme?” → 选 **Cancel**（保持 Runner 为当前 scheme，否则 `flutter run` 会选错 scheme）。
4. 在 Xcode 里把模板生成的 **`MainInterface.storyboard`** 删掉（Move to Trash）。
5. 用我们的文件覆盖模板文件：

```bash
cp /tmp/ShareExtension.ours/ShareViewController.swift app/ios/ShareExtension/ShareViewController.swift
cp /tmp/ShareExtension.ours/Info.plist               app/ios/ShareExtension/Info.plist
cp /tmp/ShareExtension.ours/ShareExtension.entitlements app/ios/ShareExtension/ShareExtension.entitlements
```

6. 在 Xcode 里 File → **Add Files to "Runner"…** 把 `ShareExtension.entitlements` 加进工程
   （Target Membership 不用勾，它只需要被 Build Settings 引用）。
7. `ShareExtension` target → Build Settings 确认/设置：

| 设置 | 值 |
| --- | --- |
| `Product Bundle Identifier` | `com.famledger.app.ShareExtension` |
| `iOS Deployment Target` | `13.0` |
| `Info.plist File` | `ShareExtension/Info.plist` |
| `Generate Info.plist File` (`GENERATE_INFOPLIST_FILE`) | **`NO`**（Xcode 15+ 默认 YES，会和手写 plist 打架） |
| `Code Signing Entitlements` | `ShareExtension/ShareExtension.entitlements` |
| `Marketing Version` | `$(FLUTTER_BUILD_NAME)` |
| `Current Project Version` | `$(FLUTTER_BUILD_NUMBER)` |

   为了让上面两个 `$(FLUTTER_*)` 变量能解析，把 `ShareExtension` target 的
   **Base Configuration（Debug 和 Release 都要）设为 `Flutter/Generated.xcconfig`**
   （在 PROJECT → Info → Configurations 里给该 target 选）。
   ⚠️ 不要选 `Flutter/Debug.xcconfig` / `Flutter/Release.xcconfig` —— `pod install` 之后它们会 include
   `Pods-Runner` 的配置，会把主 App 的所有 Pod 链进扩展。
   如果嫌麻烦，也可以直接写死 `1.0.0` / `1`，但**必须和主 App 版本号完全一致**，否则安装/上传会被拒。

8. 确认 `Info.plist` 里**没有** `NSExtensionMainStoryboard` 这个 key（有的话删掉），
   只保留 `NSExtensionPrincipalClass = $(PRODUCT_MODULE_NAME).ShareViewController`。
9. `ShareExtension` target → Signing & Capabilities → **+ Capability → App Groups** → 勾选 `group.com.famledger.app`
   （必须和主 App 是同一个 group）。
10. `ShareExtension` target → Build Phases → 确认没有链接 `Flutter.framework` / Pods（模板默认就没有，不要手工加）。

### 3.4 把 ShortcutIntents.swift 加进 Runner target

File → Add Files to "Runner"… → 选 `app/ios/Runner/ShortcutIntents.swift`
→ Target Membership 只勾 **Runner**（不要勾 ShareExtension；它依赖 `AppDelegate.swift` 里的 `PendingShareStore`）。

> `AppIntents` 部分整体有 `@available(iOS 16.0, *)` + `#if canImport(AppIntents)` 双重保护，
> 部署目标 13.0 也能编译，只是在 iOS 16 以下不会出现快捷指令。

### 3.5 确认 URL Scheme

`Runner/Info.plist` 里已经写好（也可在 Xcode → Runner → Info → URL Types 里看到）：

- URL Schemes：`famledger`
- Identifier：`com.famledger.app`
- Role：`Editor`

同时确认 `FlutterDeepLinkingEnabled` = `NO`（Boolean）也在 `Runner/Info.plist` 里 —— 原因见第 2 节。

### 3.6 签名

- Signing & Capabilities → Team 选自己的开发者账号；Runner 和 ShareExtension **两个 target 都要选**。
- 两个 Bundle ID 都要能被 Team 签（自动签名会自己去注册 App ID 和 App Group）。
- 真机自测（sideload）用个人 Apple ID 也能装，但见 6.2 的 App Groups 限制。

### 3.7 构建

```bash
cd app
flutter run -d <device-id>          # 会构建 Runner scheme，扩展作为嵌入 target 一起编译
# 或
flutter build ipa --export-method development
```

---

## 4. 怎么测

### 4.1 分享扩展

1. 打开「备忘录」/「短信」/「支付宝账单详情」，选中一段文字 → 分享 →（首次需要在「更多」里启用）**「发送到家账」**。
2. 扩展会显示「正在发送到家账…」→ 自动关闭 → 主 App 被唤起。
3. 主 App 进到「待确认」列表，能看到这条解析结果（Dart 侧完成后才有这一步，见第 8 节）。
4. 分享一张**账单截图**：扩展会跑 Vision OCR（中文+英文），把识别出来的多行文本合并后送进管线。
5. 分享一个**网页链接**：走 `public.url`，取 `absoluteString`。

### 4.2 快捷指令 / Siri

1. 「快捷指令」App → 搜索「家账」→ 应该能看到操作 **「记一笔」**。
2. 新建一个快捷指令：文本 → 「记一笔」→ 运行，应提示「已发送到家账，请打开 App 确认」并打开 App。
3. 对 Siri 说「用家账记一笔」也能触发（短语里的应用名取系统里的 App 显示名）。

> ⚠️ 快捷指令走的是 `openAppWhenRun`，**不会**产生 `famledger://` 深链。
> 所以 Dart 侧必须在「App 回到前台」时也调一次 `takePending()`（见第 8 节）。

### 4.3 不打开 Xcode 也能看到的验证点

- 扩展没出现在分享面板：多半是 `NSExtensionActivationRule` 没生效或 App 没重装，删掉 App 重装一次。
- 扩展出现但点了没反应：见 7.1（responder chain 唤起主 App 的限制），此时内容其实**已经写进 App Group**，
  手动打开主 App 也会被消费掉，不会丢。

---

## 5. 本地结果通知（Dart 侧实现，这里只记方案）

iOS 没有 Android 那套「通知动作 + RemoteInput」，等价物是 `UNNotificationCategory` + `UNTextInputNotificationAction`。
`flutter_local_notifications` 已经封装好，全部在 Dart 侧做，**不需要再写 Swift**：

```dart
const category = DarwinNotificationCategory(
  'capture_result',
  actions: [
    DarwinNotificationAction.plain('confirm', '正确'),
    DarwinNotificationAction.text('edit', '修改…', buttonTitle: '发送',
        placeholder: '类别 / 基金 / 金额'),
    DarwinNotificationAction.plain('undo', '撤销',
        options: {DarwinNotificationActionOption.destructive}),
  ],
  options: {DarwinNotificationCategoryOption.hiddenPreviewShowTitle},
);
```

- `DarwinInitializationSettings(notificationCategories: [category])`，发通知时
  `DarwinNotificationDetails(categoryIdentifier: 'capture_result')`。
- 首次需要 `requestPermissions(alert: true, badge: true, sound: true)`。
- 回调里 `response.actionId` / `response.input` 与 Android 的 `QuickReplyInterpreter` 复用同一套逻辑。

---

## 6. 已知限制

### 6.1 iOS 读不到别的 App 的通知（这是硬限制，不是没做）

iOS 没有 `NotificationListenerService` 的等价物，第三方 App **无法读取其他 App 的通知**
（`UNUserNotificationCenter.getDeliveredNotifications` 只能拿到**自己**发的）。
所以 Android 上「支付宝一弹通知就自动记账」的全自动路径在 iOS 上**不可能实现**。iOS 端只有三条半自动入口：

1. **分享扩展**：在账单/短信里选中文字或截图 → 分享 → 「发送到家账」；
2. **快捷指令 / Siri**：「用家账记一笔 …」，也可以配合「个人自动化」（比如收到指定号码短信时运行）半自动化；
3. **App 内「从剪贴板导入」**：复制一段账单文字后回到 App 一键导入（Dart 侧实现）。

解析管线（`lib/capture/`）三条入口完全共用，行为和 Android 一致。

### 6.2 免费个人 Apple ID 不支持 App Groups

Xcode 的 Personal Team（免费账号）**不能启用 App Groups capability**（会报
"Personal development teams do not support the App Groups capability"）。此时：

- 主 App 与扩展无法共享 `UserDefaults`；
- 代码里的探测是
  `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.famledger.app") != nil`
  （没权限时为 nil），据此走兜底；
- **分享扩展**：常规长度的文本本来就带在 `famledger://capture?...&text=` 里，所以照常可用；
  只有超过 1500 字符的内容（长截图 OCR）会被截断。
- **快捷指令**（`RecordTransactionIntent`）：没有 URL 兜底，此时 `PendingShareStore.append` 返回 false，
  会明确回答「保存失败，请检查 App Group 配置」，不会假装成功。
- 要完整功能就需要付费开发者账号（$99/年）。

### 6.3 其它

- 图片 OCR 的中文识别需要 **iOS 14+**（Vision 的中文模型是 revision 2 才有）；iOS 13 上只会识别英文，不报错。
- 扩展里 `UIApplication` 不可用，唤起主 App 用的是 responder chain 上的 `openURL:` 私有路径，
  Apple 从未正式支持，未来系统版本可能失效 —— 失效时内容仍在 App Group 里，用户手动打开 App 即可消费。
- 没有 iOS 的 CI：GitHub Actions 里只跑 server 测试、`flutter analyze/test` 和 Android 构建。

---

## 7. 已知的 API 风险点（Linux 上无法编译，第一次构建时重点看这里）

1. **`openURL:` responder chain**（`ShareViewController.openViaResponderChain`）：
   iOS 18 上仍然可用，但若某天失效，`extensionContext?.open(_:completionHandler:)` 是回落分支
   （官方只保证 Today Widget 可用，分享扩展上是「能用就用」）。两条都失败也不丢数据。
2. **`AppIntent.description`**：本仓库写的是
   `static var description: IntentDescription? = IntentDescription("…")`。
   如果 SDK 里该要求不是可选类型导致报错，把 `: IntentDescription?` 这个类型标注删掉即可。
3. **`AppShortcut(intent:phrases:shortTitle:systemImageName:)`**：`shortTitle` / `systemImageName`
   是 Xcode 14.3（iOS 16.4 SDK）才有的初始化器，所以 `FamledgerAppShortcuts` 标的是
   **`@available(iOS 16.4, *)`**（`RecordTransactionIntent` 本身仍是 16.0）。
   用更老的 Xcode 就改成两参的 `AppShortcut(intent:phrases:)` 并把标注降回 16.0。
   实际影响：iOS 16.0–16.3 的设备在「快捷指令」App 里仍能搜到并使用「记一笔」这个**操作**，
   只是没有系统预置的 App Shortcut（免配置的 Siri 短语）。
4. **短语必须包含 `\(.applicationName)`**：AppIntents 的编译期/运行期校验会强制要求，不要改成纯中文短语。
5. **`VNRecognizeTextRequest.results`** 在不同 SDK 里类型标注不同（`[Any]?` / `[VNObservation]?`），
   代码里用的 `as? [VNRecognizedTextObservation] ?? []` 两种都兼容。
6. **Swift 版本**：工程是 `SWIFT_VERSION = 5.0`。若日后切到 Swift 6 严格并发，
   `ShareViewController.collectSharedText` 里跨闭包捕获的可变量（`pieces` / `finished`）需要改写成 actor 或 `nonisolated(unsafe)`。
7. `AppDelegate.registerShareChannel()` 依赖 `window?.rootViewController` 已经是 `FlutterViewController`
   （Flutter 模板用 `Main.storyboard`，在 `didFinishLaunchingWithOptions` 之前就建好了，所以成立）。
   若以后迁移到 `UIScene` 生命周期，这段要跟着改；注册失败时会 `NSLog` 一行，别当成无声失败。

---
## 8. 后续 Dart 任务（Task 14b，本任务不做，这里把接口钉死）

### 8.1 深链在两端的分工（别搞混）

- **Android**：`MainActivity` 用 `DeepLinks.routeFor()` **原生**把 `famledger://` 翻成 go_router 路径
  （冷启动 `getInitialRoute()`，热启动 `engine.navigationChannel.pushRouteInformation(route)`），
  manifest 里 `flutter_deeplinking_enabled=false` 关掉了引擎自带的转发。
- **iOS**：`AppDelegate` **不做**任何深链翻译，`Info.plist` 同样设了 `FlutterDeepLinkingEnabled=false`，
  所以 iOS 上**必须**由 Dart 的 `app_links` 监听来接管全部 `famledger://`：
  - `famledger://capture?source=…[&text=…]` → 导入分支（本节 8.2–8.4）；
  - `famledger://capture/<captureId>[?tx=<id>]` → 打开流水详情（和 Android `DeepLinks.routeFor` 同语义，
    没有 `tx` 就回首页看待确认）。iOS 暂时不产生这种链接（本地通知点击走 flutter_local_notifications 回调），
    但 Dart 的解析要能区分，别把它当成待导入文本。

### 8.2 `app/lib/platform/share_import.dart`（新建）

```dart
const _channel = MethodChannel('com.famledger/share');

class PendingShare {
  final String text;          // 分享 / 快捷指令传来的原文
  final String source;        // share | shortcut | clipboard
  final DateTime receivedAt;  // 原生给的是 ISO8601 UTC 字符串
}

Future<List<PendingShare>> takePendingShares();  // invokeMethod('takePending')，读完即清
Future<List<PendingShare>> peekPendingShares();  // 'peekPending'，设置页排查用
Future<void> clearPendingShares();               // 'clearPending'
```

- 只在 `Platform.isIOS` 调用；其它平台直接返回空列表，并兜住 `MissingPluginException`。
- 通道返回的是**已解析好的** `List<Map>`（每项 `text`/`source`/`receivedAt`），不需要再 `jsonDecode`。
- `app_links`：`AppLinks().uriLinkStream` + 冷启动 `getInitialLink()`，匹配 `scheme == 'famledger'`。

### 8.3 消费顺序与去重（务必按这个来）

每次触发（深链到达 / 冷启动 / 从后台恢复）都执行：

1. **先** `takePendingShares()`（读完即清），拿到 store 里的全部条目；
2. 若本次是深链且带 `text=`：**以 URL 里的 text 为准**导入这一条，
   并把第 1 步结果里 `text` 完全相同的那条**丢掉**（那就是扩展刚写进去的同一份副本），其余条目照常导入；
3. 若深链不带 `text=`（超长内容）或压根没有深链（快捷指令 `openAppWhenRun` 只是把 App 打开）：
   第 1 步拿到的**全部**导入。

> **为什么 URL 带了 text 也要 drain**：扩展在 ≤1500 字符时是「既写 App Group 又把 text 放进 URL」的双保险
> （深链被系统拦掉时不丢内容）。只认 URL、不清 store 的话，那份副本会一直躺着，
> 下次快捷指令唤起 App 时被 `takePending()` 一起带出来 → 重复记账。

- **前台恢复也要跑一遍**：快捷指令用 `openAppWhenRun` 打开 App，**不产生深链**；
  用 `AppLifecycleListener` / `didChangeAppLifecycleState == resumed` 再调一次，冷启动首帧后也调一次。

### 8.4 喂给管线的真实 API（注意：不是 `handle(text, source:)`）

`CapturePipeline.handle` 只接受 `RawNotification`（定义在 `lib/capture/parser.dart`），**没有 `source` 参数**：

```dart
final outcome = await pipeline.handle(RawNotification(
  packageName: 'ios.share',      // 或 ios.shortcut / ios.clipboard
  title: '',                     // iOS 这三条入口没有「通知标题」，留空
  text: shared.text,
  bigText: '',                   // 长文本也可以放这里，RawNotification.body 会取更完整的那个
  postedAt: shared.receivedAt.toLocal(),
));
```

- `packageName` 没在 `SourceProfile.all` 里登记时，`SourceProfile.forPackage()` 回落到 `generic` 档
  （`lib/capture/source_profiles.dart`），正是我们要的「通用兜底解析」。
  想让来源显示得好看，应该去 `source_profiles.dart` 给 `ios.share` / `ios.shortcut` / `ios.clipboard`
  登记中文 `displayName`，**而不是**去改 `handle` 的签名。
- 管线自带去重：`captureHash(packageName, normalizedText)` + `config.dedupeWindow`（默认 10 分钟）。
  所以三条入口各自**固定一个 packageName 别乱换**，这层才能作为 8.3 之外的第二道保险。
- `postedAt` 用 `receivedAt`（ISO8601 UTC 字符串 → `DateTime.parse(...).toLocal()`）。
- 返回的 `CaptureOutcome` 按 Android 的做法交给 `flutter_local_notifications` 出结果通知（见第 5 节）。

### 8.5 `app/lib/ui/settings/capture_page.dart`（iOS 分支）

- 文案：说明 iOS 无法读取其它 App 的通知（引用 6.1），列出三条入口（分享扩展 / 快捷指令 / 剪贴板）；
- 「从剪贴板导入」按钮：`Clipboard.getData(Clipboard.kTextPlain)` →
  同一个 `pipeline.handle(RawNotification(packageName: 'ios.clipboard', …))`；
- 建议再放一个用 `peekPendingShares()` 的「还有 N 条未消费 / 立即导入」，
  排查 App Group 有没有打通时特别好用（免费个人证书会一直是 0，见 6.2）。
