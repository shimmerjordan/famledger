# iOS 原生部分：分享扩展 / 快捷指令 / URL Scheme

iOS 不让第三方 App 读别的 App 的通知，所以没有 Android 那种全自动记账，只有三条半自动入口，共用解析管线 `lib/capture/`：**分享扩展**（选中文字或截图 → 分享 →「发送到家账」）、**快捷指令 / Siri**（「用家账记一笔」）、**App 内「从剪贴板导入」**（纯 Dart，已实现）。

> 开发机是 Linux：Swift 代码**没编译验证过**，`app/ios/Runner.xcodeproj/project.pbxproj` **没改**。第 3 节必须在 Xcode 里手工做一次；编译报错先看第 6 节。路径都相对仓库根，Flutter 工程在 `app/`。

## 1. 已交付的文件
- **ShareExtension target**：`app/ios/ShareExtension/ShareViewController.swift`（读文本/网址/截图 OCR → 写 App Group → 唤起主 App）、`app/ios/ShareExtension/Info.plist`（`NSExtension` 配置）、`app/ios/ShareExtension/ShareExtension.entitlements`
- **Runner target**：`app/ios/Runner/AppDelegate.swift`（MethodChannel + `PendingShareStore`）、`app/ios/Runner/ShortcutIntents.swift`（AppIntents「记一笔」iOS 16+，AppShortcutsProvider iOS 16.4+）、`app/ios/Runner/Info.plist`（`CFBundleURLTypes`、`FlutterDeepLinkingEnabled=false`、显示名「家账」）、`app/ios/Runner/Runner.entitlements`

## 2. 契约（改一边必须同步另一边）
| 项 | 值 |
| --- | --- |
| 主 App Bundle ID | `com.famledger.app`（同 Android `applicationId`） |
| 扩展 Bundle ID | `com.famledger.app.ShareExtension` |
| App Group | `group.com.famledger.app`；可用性用 `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:) != nil` 判断，不能用 `UserDefaults` 写后读回来判断 |
| URL Scheme | `famledger`；iOS 深链全交给 Dart 的 `app_links`，`AppDelegate` 不要重写 `open url`（格式见下） |
| MethodChannel | `com.famledger/share`：`takePending` 读并清空 / `peekPending` 只读 / `clearPending` 只清，返回已解析的 `List<Map>` |
| 存储 | `UserDefaults(suiteName: "group.com.famledger.app")`，键 `pendingShares`，值是 JSON 数组字符串（最多 20 条，丢最旧）；每条 `text`、`source`（`share` / `shortcut`）、`receivedAt`（ISO8601 UTC，`Z` 结尾） |
| `text=` 规则 | ≤ 1500 字符总是带；超长且已写进 App Group 不带；超长且写不进去截断到 1500 再带 |
| Dart 消费（已实现，`app/lib/platform/share_import.dart`） | 深链 / 冷启动 / 回前台都先 `takePending`；URL 带 `text=` 以 URL 为准，丢掉 store 里相同的副本 |

```
famledger://capture?source=share|shortcut|clipboard[&text=<urlencoded 文本>]
famledger://capture/<captureId>     ← 打开详情；iOS 不产生，Dart 要能区分
```

## 3. Xcode 一次性步骤
### 3.0 准备（仓库里没有 `app/ios/Podfile`，不能直接 `pod install`）
```bash
cd app
flutter pub get
flutter build ios --config-only --no-codesign   # ① 生成 ios/Podfile 与 ios/Flutter/Generated.xcconfig
$EDITOR ios/Podfile                              # ② # platform :ios, '12.0'  →  platform :ios, '13.0'
cd ios && pod install                            # ③ 以后改了 pubspec.yaml 里的插件依赖，重复 ①③
open Runner.xcworkspace                          # 是 .xcworkspace，不是 .xcodeproj
```

### 3.1 Runner：Bundle ID、最低版本、App Group
- `Runner` → Build Settings：`Product Bundle Identifier` 从 `com.famledger.famledger` 改成 **`com.famledger.app`**；`iOS Deployment Target` 从 `12.0` 改成 **`13.0`**。
- `RunnerTests` → `Product Bundle Identifier` 改成 **`com.famledger.app.RunnerTests`**。
- `app/ios/Flutter/AppFrameworkInfo.plist` 的 `MinimumOSVersion` 改成 `13.0`（Podfile 漏改的话补上并重跑 `pod install`）。
- `Runner` → Signing & Capabilities → **+ Capability** → **App Groups** → 勾选 **`group.com.famledger.app`**。
- Debug 和 Release 的 `Code Signing Entitlements` 都指向仓库已有的 `Runner/Runner.entitlements`；Xcode 另建了文件（如 `Runner/RunnerDebug.entitlements`）就指回来并删掉多余的。

### 3.2 新建 Share Extension target
1. 模板会覆盖仓库里的三份文件，先在仓库根挪走：`mv app/ios/ShareExtension /tmp/ShareExtension.ours`
2. File → New → **Target…** → iOS → **Share Extension**：Product Name **`ShareExtension`**（必须一致），Language **Swift**，Embed in Application **`Runner`**。
3. 弹出 “Activate ShareExtension scheme?” 选 **Cancel**，否则 `flutter run` 会选错 scheme。
4. 删掉模板的 **`MainInterface.storyboard`**（Move to Trash），再覆盖回我们的文件：

```bash
cp /tmp/ShareExtension.ours/ShareViewController.swift app/ios/ShareExtension/ShareViewController.swift
cp /tmp/ShareExtension.ours/Info.plist               app/ios/ShareExtension/Info.plist
cp /tmp/ShareExtension.ours/ShareExtension.entitlements app/ios/ShareExtension/ShareExtension.entitlements
```

5. File → **Add Files to "Runner"…** 加入 `ShareExtension.entitlements`（Target Membership 不勾）。
6. `ShareExtension` target → Build Settings：

| 设置 | 值 |
| --- | --- |
| `Product Bundle Identifier` | `com.famledger.app.ShareExtension` |
| `iOS Deployment Target` | `13.0` |
| `Info.plist File` | `ShareExtension/Info.plist` |
| `Generate Info.plist File` (`GENERATE_INFOPLIST_FILE`) | **`NO`**（Xcode 15+ 默认 YES） |
| `Code Signing Entitlements` | `ShareExtension/ShareExtension.entitlements` |
| `Marketing Version` / `Current Project Version` | `$(FLUTTER_BUILD_NAME)` / `$(FLUTTER_BUILD_NUMBER)` |

7. PROJECT → Info → Configurations：`ShareExtension` 的 Debug 和 Release 都选 **`Flutter/Generated.xcconfig`**。不要选 `Flutter/Debug.xcconfig` / `Flutter/Release.xcconfig`，会把 Pods 链进扩展。也可以把版本写死 `1.0.0` / `1`，但必须和主 App 完全一致。
8. `Info.plist` 里不能有 `NSExtensionMainStoryboard`，只留 `NSExtensionPrincipalClass = $(PRODUCT_MODULE_NAME).ShareViewController`。
9. Signing & Capabilities → **+ Capability → App Groups** → 勾选同一个 `group.com.famledger.app`；Build Phases 不要链接 `Flutter.framework` / Pods。

### 3.3 Runner 收尾：快捷指令、URL Scheme、签名
- File → Add Files to "Runner"… → 选 `app/ios/Runner/ShortcutIntents.swift`，Target Membership 只勾 **Runner**（它依赖 `AppDelegate.swift` 里的 `PendingShareStore`）。部署目标 13.0 也能编，iOS 16 以下只是没有快捷指令。
- 确认 `Runner/Info.plist`（Xcode → Runner → Info → URL Types）：URL Schemes `famledger`，Identifier `com.famledger.app`，Role `Editor`；另有 `FlutterDeepLinkingEnabled` = `NO`（Boolean）。
- Runner 和 ShareExtension **两个 target** 都要选 Team，自动签名会注册 App ID 和 App Group。免费 Apple ID 见第 5 节。

### 3.4 构建
```bash
cd app
flutter run -d <device-id>                      # 扩展作为嵌入 target 一起编译
flutter build ipa --export-method development   # 或者打 ipa
```

## 4. 怎么测
- **分享扩展**：备忘录 / 短信 / 支付宝账单里选中文字 → 分享 →「发送到家账」（首次要在「更多」里启用）→ 显示「正在发送到家账…」后自动关闭，唤起主 App，App 内以 SnackBar 显示导入结果。截图走 Vision OCR（中文+英文），网页链接取 `absoluteString`。
- **快捷指令**：「快捷指令」App 搜「家账」→ 操作「记一笔」，运行后提示「已发送到家账，请打开 App 确认」并打开 App；对 Siri 说「用家账记一笔」也行。它走 `openAppWhenRun`，不产生深链，靠回前台时的 `takePending()` 消费。
- **排查**：分享面板里没有扩展 → 删掉 App 重装；点了没唤起主 App → 内容已在 App Group，手动打开主 App 照样导入。

## 5. 已知限制
- **免费个人 Apple ID 不支持 App Groups**（报 "Personal development teams do not support the App Groups capability"）。后果：
  - 主 App 与扩展无法共享 `UserDefaults`；
  - 分享扩展：正文走 URL 参数 `text=`，照常可用，但超过 1500 字符（如长截图 OCR）会被截断；
  - 快捷指令（`RecordTransactionIntent`）：没有 URL 兜底，会回答「保存失败，请检查 App Group 配置」；
  - 要完整功能需要付费开发者账号（$99/年）。
- 中文 OCR 需要 iOS 14+（iOS 13 只识别英文，不报错）；没有 iOS CI，GitHub Actions 不构建 iOS。
- 导入结果的 iOS 本地通知（带操作按钮）还没做，将来用 `flutter_local_notifications` 在 Dart 侧做，不需要 Swift。

## 6. API 风险点（首次编译重点看）
1. **`openURL:` responder chain**（`ShareViewController.openViaResponderChain`）：非官方路径，失效时回落 `extensionContext?.open(_:completionHandler:)`；两条都失败也不丢数据。
2. **`AppIntent.description`**：写的是 `static var description: IntentDescription? = IntentDescription("…")`，SDK 报类型不符就删掉 `: IntentDescription?`。
3. **`AppShortcut(intent:phrases:shortTitle:systemImageName:)`**：需要 Xcode 14.3（iOS 16.4 SDK），所以 `FamledgerAppShortcuts` 标 `@available(iOS 16.4, *)`；老 Xcode 改用 `AppShortcut(intent:phrases:)` 并降回 16.0。
4. **短语必须含 `\(.applicationName)`**，不能改成纯中文短语。
5. **`VNRecognizeTextRequest.results`**：各 SDK 类型标注不同，代码用 `as? [VNRecognizedTextObservation] ?? []` 两种都兼容。
6. **Swift 版本**：`SWIFT_VERSION = 5.0`；切 Swift 6 严格并发时，`ShareViewController.collectSharedText` 里的 `pieces` / `finished` 要改成 actor 或 `nonisolated(unsafe)`。
7. **`AppDelegate.registerShareChannel()`**：依赖 `window?.rootViewController` 是 `FlutterViewController`；迁到 `UIScene` 生命周期要跟着改，注册失败会 `NSLog` 一行。
